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

/// Rolling performance monitor for draw loop diagnostics and Instruments signposts.
final class RendererPerformanceMonitor {

    private let sampleWindow = 240
    private let log = OSLog(subsystem: "nl.budgetsoft.ProSSHV2", category: "TerminalRenderer")

    private var cpuFrameSamplesMs: [Double] = []
    private var gpuFrameSamplesMs: [Double] = []

    private(set) var totalFrames: Int = 0
    private(set) var dropped120HzFrames: Int = 0
    private(set) var dropped60HzFrames: Int = 0
    private(set) var lastDrawCallCount: Int = 0

    @discardableResult
    func beginFrame() -> OSSignpostID {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: "TerminalFrame", signpostID: id)
        return id
    }

    func endFrame(
        signpostID: OSSignpostID,
        cpuFrameSeconds: CFTimeInterval,
        gpuFrameSeconds: CFTimeInterval?,
        drawCalls: Int
    ) {
        let cpuMs = max(0, cpuFrameSeconds * 1000.0)
        append(&cpuFrameSamplesMs, value: cpuMs)

        if let gpuFrameSeconds, gpuFrameSeconds > 0 {
            append(&gpuFrameSamplesMs, value: gpuFrameSeconds * 1000.0)
        }

        totalFrames += 1
        lastDrawCallCount = drawCalls

        if cpuMs > 8.3 {
            dropped120HzFrames += 1
        }
        if cpuMs > 16.6 {
            dropped60HzFrames += 1
        }

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

    func snapshot() -> RendererPerformanceSnapshot {
        RendererPerformanceSnapshot(
            totalFrames: totalFrames,
            averageCPUFrameMs: average(cpuFrameSamplesMs) ?? 0,
            p95CPUFrameMs: percentile(cpuFrameSamplesMs, p: 0.95) ?? 0,
            averageGPUFrameMs: average(gpuFrameSamplesMs),
            dropped120HzFrames: dropped120HzFrames,
            dropped60HzFrames: dropped60HzFrames,
            lastDrawCallCount: lastDrawCallCount
        )
    }

    private func append(_ target: inout [Double], value: Double) {
        target.append(value)
        if target.count > sampleWindow {
            target.removeFirst(target.count - sampleWindow)
        }
    }

    private func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func percentile(_ values: [Double], p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[min(max(0, rank), sorted.count - 1)]
    }
}
