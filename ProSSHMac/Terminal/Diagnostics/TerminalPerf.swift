// TerminalPerf.swift
// ProSSHMac
//
// Runtime-gated performance instrumentation for the terminal data path:
// Instruments Points-of-Interest signposts plus in-process stage timers.
//
// Off by default. When off, `log` is `.disabled` (every `os_signpost` becomes a
// no-op) and `now()`/`record(_:since:)` return immediately after one static Bool
// check, so a shipping build pays nothing.
//
// Enable with any of:
//   --perf-signposts                                        (launch argument)
//   PROSSH_PERF_SIGNPOSTS=1                                  (environment)
//   defaults write com.prossh terminal.perf.signposts -bool true
//
// All members are explicitly `nonisolated`: SWIFT_DEFAULT_ACTOR_ISOLATION is
// MainActor, and these are called from the detached PTY reader task and from
// inside the TerminalEngine actor.

import Foundation
import Darwin
import os.signpost

enum TerminalPerf {

    // MARK: - Enablement

    nonisolated static let subsystem = "nl.budgetsoft.ProSSHMac"

    /// Resolved once, on first use.
    nonisolated static let isEnabled: Bool = {
        if TerminalSchedulingDiagnostics.isEnabled { return true }
        let info = ProcessInfo.processInfo
        if info.arguments.contains("--perf-signposts") { return true }
        if let value = info.environment["PROSSH_PERF_SIGNPOSTS"],
           value == "1" || value.lowercased() == "true" {
            return true
        }
        return UserDefaults.standard.bool(forKey: "terminal.perf.signposts")
    }()

    /// Shared Points-of-Interest log. `.disabled` when instrumentation is off, so
    /// an `os_signpost` call that forgets to check `isEnabled` is still free.
    nonisolated static let log: OSLog = isEnabled
        ? OSLog(subsystem: subsystem, category: .pointsOfInterest)
        : .disabled

    // MARK: - Stages

    /// Stages are recorded at *chunk* granularity, never per byte, so the timers
    /// themselves stay off the hot loop.
    ///
    /// Note that these stages run **concurrently** — the PTY reader is a detached
    /// task feeding an `AsyncStream` that the parser drains on the engine actor —
    /// so the recorded times overlap and do not partition wall-clock time.
    /// Several stages come in caller-side/callee-side pairs — `feedCall` around the
    /// `await` and `parse` inside the engine, `publish` around `publishEngineWait`.
    /// The difference between a pair is the actor hop and queue wait, which is the
    /// quantity the RenderCost work is chasing.
    enum Stage: Int, CaseIterable {
        case ptyRead
        case ptySanitize
        case ptyHandoff
        case chunkRecord
        case historyIndex
        case feedCall
        case batchFollowUp
        case parse
        case snapshotBuild
        case publish
        case publishEngineWait
        case publishHousekeeping
        case visibleTextScan
        case cellBufferUpdate
        case drawableWait
        case snapshotApply
        case frameEncode
        case gpuExecute
        case drawFrame

        nonisolated var label: String {
            switch self {
            case .ptyRead:             return "pty read"
            case .ptySanitize:         return "pty sanitize"
            case .ptyHandoff:          return "pty handoff"
            case .chunkRecord:         return "chunk record"
            case .historyIndex:        return "history index"
            case .feedCall:            return "feed call"
            case .batchFollowUp:       return "batch follow-up"
            case .parse:               return "parse + grid"
            case .snapshotBuild:       return "snapshot build"
            case .publish:             return "publish"
            case .publishEngineWait:   return "publish engine wait"
            case .publishHousekeeping: return "publish housekeep"
            case .visibleTextScan:     return "visible text"
            case .cellBufferUpdate:    return "cell buffer"
            case .drawableWait:        return "drawable wait"
            case .snapshotApply:       return "snapshot apply"
            case .frameEncode:         return "frame encode"
            case .gpuExecute:          return "gpu execute"
            case .drawFrame:           return "draw frame"
            }
        }
    }

    private nonisolated(unsafe) static var nanos = [UInt64](repeating: 0, count: Stage.allCases.count)
    private nonisolated(unsafe) static var calls = [UInt64](repeating: 0, count: Stage.allCases.count)
    private nonisolated(unsafe) static var bytes = [UInt64](repeating: 0, count: Stage.allCases.count)

    // Summed durations alone cannot tell an idle stage from an absent one: a reader
    // that is blocked waiting for data records almost no time, and so does a reader
    // that never ran. Tracking the first and last timestamp per stage gives each one
    // a *span*, and busy% (time / span) separates "waiting" from "working".
    private nonisolated(unsafe) static var firstAt = [UInt64](repeating: 0, count: Stage.allCases.count)
    private nonisolated(unsafe) static var lastAt = [UInt64](repeating: 0, count: Stage.allCases.count)
    private nonisolated(unsafe) static var resetAt: UInt64 = 0

    private nonisolated static let lock = NSLock()

    // MARK: - Timing

    /// Monotonic nanosecond timestamp, or 0 when instrumentation is off.
    @inline(__always)
    nonisolated static func now() -> UInt64 {
        isEnabled ? clock_gettime_nsec_np(CLOCK_UPTIME_RAW) : 0
    }

    /// Accumulate elapsed time against a stage. `start` of 0 (the disabled
    /// sentinel from `now()`) is ignored.
    @inline(__always)
    nonisolated static func record(_ stage: Stage, since start: UInt64, byteCount: Int = 0) {
        guard isEnabled, start != 0 else { return }
        let end = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let elapsed = end &- start
        let index = stage.rawValue
        lock.lock()
        nanos[index] &+= elapsed
        calls[index] &+= 1
        bytes[index] &+= UInt64(byteCount)
        if firstAt[index] == 0 || start < firstAt[index] { firstAt[index] = start }
        if end > lastAt[index] { lastAt[index] = end }
        lock.unlock()
    }

    /// Accumulate an already-measured duration against a stage. Used where the
    /// elapsed time arrives as a duration rather than a start stamp — notably GPU
    /// time, which Metal reports only in the command buffer's completion handler.
    @inline(__always)
    nonisolated static func add(_ stage: Stage, nanoseconds: UInt64, byteCount: Int = 0) {
        guard isEnabled, nanoseconds != 0 else { return }
        let index = stage.rawValue
        // The duration arrives after the fact, so the span is dated from now
        // backwards. For GPU time that is the completion handler, which is close
        // enough for a span whose unit is seconds.
        let end = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let start = end > nanoseconds ? end &- nanoseconds : end
        lock.lock()
        nanos[index] &+= nanoseconds
        calls[index] &+= 1
        bytes[index] &+= UInt64(byteCount)
        if firstAt[index] == 0 || start < firstAt[index] { firstAt[index] = start }
        if end > lastAt[index] { lastAt[index] = end }
        lock.unlock()
    }

    nonisolated static func reset() {
        TerminalSchedulingDiagnostics.reset()
        guard isEnabled else { return }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        lock.lock()
        for index in nanos.indices {
            nanos[index] = 0
            calls[index] = 0
            bytes[index] = 0
            firstAt[index] = 0
            lastAt[index] = 0
        }
        resetAt = now
        lock.unlock()
    }

    // MARK: - Reporting

    /// Formatted stage budget, or nil when instrumentation is off or nothing was
    /// recorded. `wallSeconds` is the scenario's measured wall time.
    nonisolated static func report(title: String, wallSeconds: Double) -> String? {
        guard isEnabled else { return nil }

        lock.lock()
        let nanosCopy = nanos
        let callsCopy = calls
        let bytesCopy = bytes
        let firstCopy = firstAt
        let lastCopy = lastAt
        let resetStamp = resetAt
        lock.unlock()

        guard nanosCopy.contains(where: { $0 > 0 }) else { return nil }

        let wallMs = wallSeconds * 1000.0
        var lines = ["stage budget (\(title)):"]
        lines.append(String(format: "  %-19@ %11@  %6@  %10@  %6@  %10@",
                            "stage" as NSString, "time" as NSString, "%wall" as NSString,
                            "span" as NSString, "busy" as NSString, "at" as NSString))

        for stage in Stage.allCases {
            let index = stage.rawValue
            guard callsCopy[index] > 0 else { continue }
            let ms = Double(nanosCopy[index]) / 1_000_000.0
            let pct = wallMs > 0 ? (ms / wallMs) * 100.0 : 0
            // span: first start to last end. busy: how much of that span was work.
            // A stage spanning the whole run at 1% busy is blocked, not slow.
            let spanMs = lastCopy[index] > firstCopy[index]
                ? Double(lastCopy[index] &- firstCopy[index]) / 1_000_000.0
                : 0
            let busy = spanMs > 0 ? (ms / spanMs) * 100.0 : 0
            let startMs = (resetStamp > 0 && firstCopy[index] > resetStamp)
                ? Double(firstCopy[index] &- resetStamp) / 1_000_000.0
                : 0
            var line = String(format: "  %-19@ %8.2f ms  %5.1f%%  %7.0f ms  %5.1f%%  %7.0f ms  (%llu calls",
                              stage.label as NSString, ms, pct, spanMs, busy, startMs, callsCopy[index])
            if bytesCopy[index] > 0 {
                line += String(format: ", %.2f MB", Double(bytesCopy[index]) / 1_048_576.0)
            }
            line += ")"
            lines.append(line)
        }

        lines.append(String(format: "  %-19@ %8.2f ms", "wall" as NSString, wallMs))
        lines.append("  note: PTY reader and parser run concurrently — stages overlap and")
        lines.append("        do not partition wall time. span = first start to last end,")
        lines.append("        busy = time/span, at = first start after reset.")
        if let scheduling = TerminalSchedulingDiagnostics.report() { lines.append(scheduling) }
        return lines.joined(separator: "\n")
    }
}
