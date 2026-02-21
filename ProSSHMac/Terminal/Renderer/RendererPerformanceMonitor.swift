// RendererPerformanceMonitor.swift
// ProSSHV2
//
// Runtime profiling utilities for Metal terminal rendering.

import Foundation
import os.signpost

/// Snapshot of renderer frame performance.
struct RendererPerformanceSnapshot: Sendable {
    let totalFrames: Int
    let averageCPUFrameMs: Double
    let p95CPUFrameMs: Double
    let averageGPUFrameMs: Double?
    let dropped120HzFrames: Int
    let dropped60HzFrames: Int
    let lastDrawCallCount: Int
}

/// Fixed-size ring buffer for frame time samples.
/// Uses a circular index to avoid O(n) `removeFirst()` calls.
private struct RingBuffer {
    private var storage: [Double]
    private var head: Int = 0   // next write position
    private var count_: Int = 0
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        self.storage = [Double](repeating: 0.0, count: capacity)
    }

    var count: Int { count_ }
    var isEmpty: Bool { count_ == 0 }

    mutating func append(_ value: Double) {
        storage[head] = value
        head = (head + 1) % capacity
        if count_ < capacity {
            count_ += 1
        }
    }

    /// Return all stored values (oldest first) for aggregate computation.
    func toArray() -> [Double] {
        guard count_ > 0 else { return [] }
        if count_ < capacity {
            return Array(storage[0..<count_])
        }
        // Ring is full: head points to the oldest element.
        return Array(storage[head..<capacity]) + Array(storage[0..<head])
    }
}

/// Rolling performance monitor for draw loop diagnostics and Instruments signposts.
/// Thread-safe: all mutable state is protected by an unfair lock so that
/// render-thread writes and main-thread snapshot reads do not race.
final class RendererPerformanceMonitor: @unchecked Sendable {

    private let sampleWindow = 240
    private let log = OSLog(subsystem: "nl.budgetsoft.ProSSHV2", category: "TerminalRenderer")

    // Lock protecting all mutable state below.
    private let lock = NSLock()

    private var cpuFrameSamples: RingBuffer
    private var gpuFrameSamples: RingBuffer

    private var _totalFrames: Int = 0
    private var _dropped120HzFrames: Int = 0
    private var _dropped60HzFrames: Int = 0
    private var _lastDrawCallCount: Int = 0

    init() {
        cpuFrameSamples = RingBuffer(capacity: sampleWindow)
        gpuFrameSamples = RingBuffer(capacity: sampleWindow)
    }

    @discardableResult
    func beginFrame() -> OSSignpostID {
        #if DEBUG
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: "TerminalFrame", signpostID: id)
        return id
        #else
        return .invalid
        #endif
    }

    func endFrame(
        signpostID: OSSignpostID,
        cpuFrameSeconds: CFTimeInterval,
        gpuFrameSeconds: CFTimeInterval?,
        drawCalls: Int
    ) {
        let cpuMs = max(0, cpuFrameSeconds * 1000.0)

        lock.lock()
        cpuFrameSamples.append(cpuMs)

        if let gpuFrameSeconds, gpuFrameSeconds > 0 {
            gpuFrameSamples.append(gpuFrameSeconds * 1000.0)
        }

        _totalFrames += 1
        _lastDrawCallCount = drawCalls

        if cpuMs > 8.3 {
            _dropped120HzFrames += 1
        }
        if cpuMs > 16.6 {
            _dropped60HzFrames += 1
        }
        lock.unlock()

        #if DEBUG
        if signpostID != .invalid {
            os_signpost(
                .end,
                log: log,
                name: "TerminalFrame",
                signpostID: signpostID,
                "cpu_ms=%.3f draw_calls=%d",
                cpuMs,
                drawCalls
            )
        }
        #endif
    }

    func snapshot() -> RendererPerformanceSnapshot {
        lock.lock()
        let cpuValues = cpuFrameSamples.toArray()
        let gpuValues = gpuFrameSamples.toArray()
        let totalFrames = _totalFrames
        let dropped120 = _dropped120HzFrames
        let dropped60 = _dropped60HzFrames
        let drawCalls = _lastDrawCallCount
        lock.unlock()

        return RendererPerformanceSnapshot(
            totalFrames: totalFrames,
            averageCPUFrameMs: Self.average(cpuValues) ?? 0,
            p95CPUFrameMs: Self.percentile(cpuValues, p: 0.95) ?? 0,
            averageGPUFrameMs: Self.average(gpuValues),
            dropped120HzFrames: dropped120,
            dropped60HzFrames: dropped60,
            lastDrawCallCount: drawCalls
        )
    }

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func percentile(_ values: [Double], p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[min(max(0, rank), sorted.count - 1)]
    }
}
