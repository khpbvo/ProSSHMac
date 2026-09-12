// Opt-in scheduling diagnostics. Thread clocks are only sampled around synchronous
// work: an async suspension could resume on a different thread and invalidate them.
import Foundation
import Darwin

nonisolated enum TerminalSchedulingDiagnostics {
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("--perf-scheduling")
        || ProcessInfo.processInfo.environment["PROSSH_PERF_SCHEDULING"] == "1"

    struct GroundSample: Sendable {
        var calls: UInt64 = 0
        var bytes: UInt64 = 0
        var cpu: UInt64 = 0
        var wall: UInt64 = 0
    }
    private static let lock = NSLock()
    private nonisolated(unsafe) static var groundByQoS: [UInt32: GroundSample] = [:]
    private nonisolated(unsafe) static var batchCount: UInt64 = 0
    private nonisolated(unsafe) static var batchBytes: UInt64 = 0
    private nonisolated(unsafe) static var maxBatch = 0
    private nonisolated(unsafe) static var smallBatches: UInt64 = 0
    private nonisolated(unsafe) static var events: [String: UInt64] = [:]

    @inline(__always)
    static func measureGround(byteCount: Int, _ work: () -> Void) {
        guard isEnabled else { work(); return }
        let qos = qos_class_self().rawValue
        let wallStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        work()
        let cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) &- cpuStart
        let wall = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- wallStart
        lock.lock()
        var sample = groundByQoS[qos, default: GroundSample()]
        sample.calls += 1
        sample.bytes += UInt64(byteCount)
        sample.cpu += cpu
        sample.wall += wall
        groundByQoS[qos] = sample
        lock.unlock()
    }

    static func recordBatch(bytes: Int) {
        guard isEnabled else { return }
        lock.lock()
        batchCount += 1
        batchBytes += UInt64(bytes)
        maxBatch = max(maxBatch, bytes)
        if bytes < 4096 { smallBatches += 1 }
        lock.unlock()
    }

    static func event(_ name: String) {
        guard isEnabled else { return }
        lock.lock()
        events[name, default: 0] += 1
        lock.unlock()
    }

    static func reset() {
        guard isEnabled else { return }
        lock.lock()
        groundByQoS.removeAll(keepingCapacity: true)
        batchCount = 0
        batchBytes = 0
        maxBatch = 0
        smallBatches = 0
        events.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    static func report() -> String? {
        guard isEnabled else { return nil }
        lock.lock()
        let ground = groundByQoS
        let count = batchCount
        let bytes = batchBytes
        let maximum = maxBatch
        let small = smallBatches
        let eventCounts = events
        lock.unlock()
        var lines = ["scheduling diagnostic (synchronous ground work only):"]
        for qos in ground.keys.sorted() {
            let s = ground[qos]!
            let cpuMs = Double(s.cpu) / 1e6
            let wallMs = Double(s.wall) / 1e6
            let ratio = s.wall > 0 ? Double(s.cpu) / Double(s.wall) * 100 : 0
            lines.append(String(format: "  qos=%u calls=%llu bytes=%llu cpu=%.2fms elapsed=%.2fms cpu/elapsed=%.1f%%",
                                qos, s.calls, s.bytes, cpuMs, wallMs, ratio))
        }
        lines.append("  batches=\(count) bytes=\(bytes) mean=\(count > 0 ? bytes / count : 0) max=\(maximum) under4K=\(small)")
        lines.append("  events: " + eventCounts.keys.sorted().map { "\($0)=\(eventCounts[$0]!)" }.joined(separator: " "))
        lines.append("  qos is the thread's requested class; overrides/CPU placement are not measured.")
        return lines.joined(separator: "\n")
    }
}
