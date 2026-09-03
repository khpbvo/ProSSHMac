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
    enum Stage: Int, CaseIterable {
        case ptyRead
        case ptySanitize
        case ptyHandoff
        case parse
        case snapshotBuild
        case publish
        case cellBufferUpdate

        nonisolated var label: String {
            switch self {
            case .ptyRead:          return "pty read"
            case .ptySanitize:      return "pty sanitize"
            case .ptyHandoff:       return "pty handoff"
            case .parse:            return "parse + grid"
            case .snapshotBuild:    return "snapshot build"
            case .publish:          return "publish"
            case .cellBufferUpdate: return "cell buffer"
            }
        }
    }

    private nonisolated(unsafe) static var nanos = [UInt64](repeating: 0, count: Stage.allCases.count)
    private nonisolated(unsafe) static var calls = [UInt64](repeating: 0, count: Stage.allCases.count)
    private nonisolated(unsafe) static var bytes = [UInt64](repeating: 0, count: Stage.allCases.count)
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
        let elapsed = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- start
        let index = stage.rawValue
        lock.lock()
        nanos[index] &+= elapsed
        calls[index] &+= 1
        bytes[index] &+= UInt64(byteCount)
        lock.unlock()
    }

    nonisolated static func reset() {
        guard isEnabled else { return }
        lock.lock()
        for index in nanos.indices {
            nanos[index] = 0
            calls[index] = 0
            bytes[index] = 0
        }
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
        lock.unlock()

        guard nanosCopy.contains(where: { $0 > 0 }) else { return nil }

        let wallMs = wallSeconds * 1000.0
        var lines = ["stage budget (\(title)):"]

        for stage in Stage.allCases {
            let index = stage.rawValue
            guard callsCopy[index] > 0 else { continue }
            let ms = Double(nanosCopy[index]) / 1_000_000.0
            let pct = wallMs > 0 ? (ms / wallMs) * 100.0 : 0
            var line = String(format: "  %-16@ %9.2f ms  %5.1f%%  (%llu calls",
                              stage.label as NSString, ms, pct, callsCopy[index])
            if bytesCopy[index] > 0 {
                line += String(format: ", %.2f MB", Double(bytesCopy[index]) / 1_048_576.0)
            }
            line += ")"
            lines.append(line)
        }

        lines.append(String(format: "  %-16@ %9.2f ms", "wall" as NSString, wallMs))
        lines.append("  note: PTY reader and parser run concurrently — stages overlap and")
        lines.append("        do not partition wall time.")
        return lines.joined(separator: "\n")
    }
}
