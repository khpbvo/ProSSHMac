// ThroughputBenchmarkRunner+Render.swift
// ProSSHMac
//
// End-to-end throughput benchmark that runs through the *real* app path with a
// real window rendering, so the result is comparable to peer emulators measured
// with rendering (see scripts/benchmark-peer-emulator.sh).
//
// This is deliberately not the same thing as `--benchmark-pty-local`. That mode
// spawns a bare LocalShellChannel and feeds the engine chunk-by-chunk; the real
// path batches chunks into 4 ms windows (SessionShellIOCoordinator), pays
// recordParsedChunk, publishes through TerminalRenderingCoordinator, and draws.
//
//   --benchmark-render            terminal visible, Metal surface attached
//   --benchmark-render-detached   same path, parked on .hosts so nothing renders
//
// The delta between the two is the cost of rendering.

import AppKit
import Foundation

extension ThroughputBenchmarkRunner {

    // MARK: - Enablement

    /// True for either render mode. Deliberately NOT folded into `isEnabled`:
    /// that flag makes `AppDependencies` bail out before the UI is wired and
    /// makes `ProSSHMacApp` skip scene-phase handling, but render mode needs the
    /// app to boot normally.
    static var isRenderBenchmarkEnabled: Bool {
        let args = ProcessInfo.processInfo.arguments
        return args.contains("--benchmark-render") || args.contains("--benchmark-render-detached")
    }

    /// True when the session runs without a Metal surface attached — the A/B
    /// baseline for attributing rendering cost.
    static var isRenderDetached: Bool {
        ProcessInfo.processInfo.arguments.contains("--benchmark-render-detached")
    }

    // MARK: - Sentinel tap

    // The real reader owns the PTY stream, so completion is detected from a tap
    // in SessionShellIOCoordinator.recordParsedChunk rather than by draining the
    // stream here.

    private static var renderSentinel: BenchmarkSentinelMatcher?
    private static var renderSentinelFound = false

    /// Called for every raw PTY chunk on the real reader path. No-op unless a
    /// render benchmark is armed.
    static func observeBenchmarkChunk(_ chunk: Data) {
        guard isRenderBenchmarkEnabled, !renderSentinelFound, renderSentinel != nil else { return }
        if renderSentinel!.consume(chunk) {
            renderSentinelFound = true
        }
    }

    // MARK: - Output

    // A rendered run must be launched through LaunchServices (`open -n`) to get a
    // real window — launching the binary directly from a shell yields a process
    // with zero windows. That detaches stdout, so everything is also written to
    // `--benchmark-out`, which the script polls. Same approach as
    // benchmark-peer-emulator.sh, which cannot capture a GUI app's stdout either.

    private static var renderOutputLines: [String] = []

    private static var renderOutputPath: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "--benchmark-out"), idx + 1 < args.count else {
            return nil
        }
        return args[idx + 1]
    }

    private static func emit(_ line: String) {
        print(line)
        renderOutputLines.append(line)
    }

    private static func flushRenderOutput() {
        guard let path = renderOutputPath else { return }
        let text = renderOutputLines.joined(separator: "\n") + "\n"
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Entry point

    static func runRenderBenchmarkIfRequested(
        sessionManager: SessionManager,
        navigationCoordinator: AppNavigationCoordinator
    ) async {
        guard isRenderBenchmarkEnabled else { return }

        let config = renderConfigurationFromArgs()
        let detached = isRenderDetached
        let label = detached ? "render-detached" : "render"

        emit("==> ProSSHMac Rendered End-to-End Benchmark")
        emit("    mode=\(label) kilobytes=\(config.kilobytes) runs=\(config.runs)")
        emit("    signposts/stage-timers: \(TerminalPerf.isEnabled ? "ENABLED" : "off")")
        emit("")

        // The window must be key and large enough to hold a real grid:
        // MetalTerminalSessionSurface.updateFPS drops an unfocused surface to
        // 30 FPS, which would silently halve the result.
        let hasKeyWindow = await prepareWindow(timeoutSeconds: 30)
        if !detached && !hasKeyWindow {
            emit("  WARNING: no usable key window — the surface may be throttled to 30 FPS")
            emit("           and this measurement should not be compared to peer emulators.")
        }
        let frame = NSApp.keyWindow?.frame ?? NSApp.windows.first?.frame ?? .zero
        emit("    window: active=\(NSApp.isActive) count=\(NSApp.windows.count)"
            + " frame=\(Int(frame.width))x\(Int(frame.height))@\(Int(frame.origin.x)),\(Int(frame.origin.y))")

        navigationCoordinator.navigate(to: detached ? .hosts : .terminal)
        try? await Task.sleep(for: .milliseconds(750))

        // One session for every run. Reopening it per run left the terminal
        // surface bound only for the first run, which made later runs measure
        // something different while looking identical.
        let session: Session
        do {
            session = try await sessionManager.openLocalSession(shellPath: "/bin/sh")
        } catch {
            emit("  ERROR: openLocalSession failed: \(error.localizedDescription)")
            flushRenderOutput()
            exit(1)
        }
        let sessionID = session.id
        await waitForQuiescence(sessionID: sessionID, sessionManager: sessionManager)

        let renderer = detached ? nil : await waitForRenderer(timeoutSeconds: 10)
        if !detached && renderer == nil {
            emit("  WARNING: no Metal renderer attached — the terminal surface never appeared,")
            emit("           so this run measures the same thing as --benchmark-render-detached.")
        }

        var sentinelResults: [Double] = []
        var settledResults: [Double] = []

        for run in 1...config.runs {
            guard let result = await runRenderScenario(
                kilobytes: config.kilobytes,
                sessionID: sessionID,
                renderer: renderer,
                sessionManager: sessionManager
            ) else {
                emit("run \(run)/\(config.runs) [\(label)] FAILED")
                continue
            }

            sentinelResults.append(result.sentinelMBps)
            settledResults.append(result.settledMBps)
            emit("run \(run)/\(config.runs) [\(label)] "
                + "\(format(result.sentinelMBps)) MB/s to sentinel, "
                + "\(format(result.settledMBps)) MB/s to settled")
            if !result.frameSummary.isEmpty {
                emit(result.frameSummary)
            }
            if let budget = result.stageBudget {
                emit(budget)
            }
        }

        await sessionManager.disconnect(sessionID: sessionID)

        emit("")
        emit("summary:")
        emit("  \(label) to sentinel avg: \(format(average(of: sentinelResults))) MB/s")
        emit("  \(label) to settled  avg: \(format(average(of: settledResults))) MB/s")
        if detached {
            emit("  (no Metal surface attached — this is the no-rendering baseline)")
        } else {
            emit("  compare against --benchmark-render-detached for the rendering delta,")
            emit("  and against ./scripts/benchmark-peer-emulator.sh for peer emulators.")
        }
        emit("")

        flushRenderOutput()
        fflush(stdout)
        fflush(stderr)
        exit(0)
    }

    // MARK: - One run

    private struct RenderRunResult {
        let sentinelMBps: Double
        let settledMBps: Double
        let frameSummary: String
        let stageBudget: String?
    }

    private static func runRenderScenario(
        kilobytes: Int,
        sessionID: UUID,
        renderer: MetalTerminalRenderer?,
        sessionManager: SessionManager
    ) async -> RenderRunResult? {
        let detached = renderer == nil
        let framesBefore = renderer?.performanceSnapshot.totalFrames ?? 0

        let sentinel = "---PROSSH_BENCH_DONE_\(UUID().uuidString)---"
        let command = makePTYBenchmarkCommand(kilobytes: kilobytes, sentinel: sentinel)
        renderSentinel = BenchmarkSentinelMatcher(sentinel: sentinel)
        renderSentinelFound = false

        let bytesBefore = sessionManager.bytesReceivedBySessionID[sessionID] ?? 0
        TerminalPerf.reset()
        let start = CFAbsoluteTimeGetCurrent()

        await sessionManager.sendRawShellInput(sessionID: sessionID, input: command)

        let found = await waitForSentinel(timeoutSeconds: 180)
        let sentinelElapsed = CFAbsoluteTimeGetCurrent() - start
        if !found {
            emit("  WARNING: sentinel not found within 180s, measurement is unreliable")
        }

        // The parser can finish well before the renderer has drawn the last
        // frames. Stopping the clock at the sentinel would make rendering look
        // free, so record a second time once the renderer has drained.
        await waitForRendererSettled(renderer)
        let settledElapsed = CFAbsoluteTimeGetCurrent() - start

        let bytesAfter = sessionManager.bytesReceivedBySessionID[sessionID] ?? 0
        let totalBytes = max(0, bytesAfter - bytesBefore)

        let budget = TerminalPerf.report(title: detached ? "render-detached" : "render",
                                         wallSeconds: settledElapsed)

        var frameSummary = ""
        if let renderer {
            let stats = renderer.performanceSnapshot
            let frames = stats.totalFrames - framesBefore
            let fps = settledElapsed > 0 ? Double(frames) / settledElapsed : 0
            let gpu = stats.averageGPUFrameMs.map { format($0) } ?? "n/a"
            frameSummary = "  frames=\(frames) fps=\(format(fps))"
                + " cpu avg=\(format(stats.averageCPUFrameMs))ms p95=\(format(stats.p95CPUFrameMs))ms"
                + " gpu avg=\(gpu)ms glyph hit=\(format(renderer.cacheHitRate * 100))%"
            if fps > 0 && fps < 35 {
                frameSummary += "\n  WARNING: ~30 fps suggests an unfocused surface — see updateFPS(isFocused:)."
            }
        }

        renderSentinel = nil

        return RenderRunResult(
            sentinelMBps: throughput(bytes: totalBytes, seconds: sentinelElapsed),
            settledMBps: throughput(bytes: totalBytes, seconds: settledElapsed),
            frameSummary: frameSummary,
            stageBudget: budget
        )
    }

    // MARK: - Waiting helpers

    /// Waits for the app's window, forces it to a usable size and position, and
    /// makes it key.
    ///
    /// Saved window state is restored before this runs and can be degenerate — on
    /// the machine this was written on it came back as 149x129 at x=-234, entirely
    /// off-screen, which leaves no terminal surface to render into and no key
    /// window to un-throttle it.
    private static func prepareWindow(timeoutSeconds: Int) async -> Bool {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        var target: NSWindow?
        for _ in 0..<(timeoutSeconds * 10) {
            target = NSApp.windows.first { $0.canBecomeKey }
            if target != nil { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let window = target else { return false }

        let frame = window.frame
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
        if frame.width < 800 || frame.height < 500 || !onScreen {
            window.setFrame(NSRect(x: 120, y: 120, width: 1280, height: 800), display: true)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        for _ in 0..<50 {
            if NSApp.keyWindow != nil { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return NSApp.keyWindow != nil
    }

    private static func waitForSentinel(timeoutSeconds: Int) async -> Bool {
        for _ in 0..<(timeoutSeconds * 200) {
            if renderSentinelFound { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return renderSentinelFound
    }

    /// Waits until the session has produced no new bytes for ~300 ms — i.e. the
    /// shell has finished starting up — so startup output is not measured.
    private static func waitForQuiescence(
        sessionID: UUID,
        sessionManager: SessionManager
    ) async {
        var lastBytes: Int64 = -1
        var stableRounds = 0
        for _ in 0..<100 {
            try? await Task.sleep(for: .milliseconds(100))
            let bytes = sessionManager.bytesReceivedBySessionID[sessionID] ?? 0
            if bytes == lastBytes {
                stableRounds += 1
                if stableRounds >= 3 { return }
            } else {
                stableRounds = 0
                lastBytes = bytes
            }
        }
    }

    /// The surface is torn down and rebuilt between runs, so the weak registry is
    /// briefly nil after a new session opens.
    private static func waitForRenderer(timeoutSeconds: Int) async -> MetalTerminalRenderer? {
        for _ in 0..<(timeoutSeconds * 10) {
            if let renderer = MetalTerminalRenderer.benchmarkInstance { return renderer }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return MetalTerminalRenderer.benchmarkInstance
    }

    /// Waits until the renderer has nothing pending and has stopped drawing.
    private static func waitForRendererSettled(_ renderer: MetalTerminalRenderer?) async {
        guard let renderer else {
            // Detached: still let any in-flight publish drain.
            try? await Task.sleep(for: .milliseconds(200))
            return
        }
        var lastFrames = -1
        var stableRounds = 0
        for _ in 0..<200 {
            try? await Task.sleep(for: .milliseconds(50))
            let frames = renderer.performanceSnapshot.totalFrames
            let idle = renderer.pendingRenderSnapshot == nil && !renderer.isDirty
            if idle && frames == lastFrames {
                stableRounds += 1
                if stableRounds >= 4 { return }
            } else {
                stableRounds = 0
                lastFrames = frames
            }
        }
    }

    // MARK: - Small helpers

    private static func throughput(bytes: Int64, seconds: Double) -> Double {
        guard seconds > 0, bytes > 0 else { return 0 }
        return Double(bytes) / seconds / 1_048_576.0
    }

    private struct RenderBenchmarkConfig {
        let kilobytes: Int
        let runs: Int
    }

    private static func renderConfigurationFromArgs() -> RenderBenchmarkConfig {
        let args = ProcessInfo.processInfo.arguments
        let bytes = max(intArg("--benchmark-bytes", args: args, defaultValue: 2 * 1_048_576), 1024)
        return RenderBenchmarkConfig(
            kilobytes: max(bytes / 1024, 1),
            runs: max(intArg("--benchmark-runs", args: args, defaultValue: 3), 1)
        )
    }
}
