// RendererStressHarness.swift
// ProSSHV2
//
// Synthetic renderer flood harness for performance validation (B.12.4).

import Foundation
import QuartzCore

/// Result of a synthetic renderer stress run.
struct RendererStressResult: Sendable {
    let framesSubmitted: Int
    let durationSeconds: Double
    let averageCPUFrameMs: Double
    let p95CPUFrameMs: Double
    let dropped120HzFrames: Int
    let dropped60HzFrames: Int
}

/// Generates high-churn terminal snapshots and submits them to the renderer.
@MainActor
enum RendererStressHarness {

    static func run(
        renderer: MetalTerminalRenderer,
        columns: Int = 240,
        rows: Int = 70,
        durationSeconds: Double = 5.0
    ) async -> RendererStressResult {
        let start = CACurrentMediaTime()
        var frames = 0

        while CACurrentMediaTime() - start < durationSeconds {
            renderer.updateSnapshot(makeFloodSnapshot(columns: columns, rows: rows, seed: frames))
            frames += 1
            await Task.yield()
        }

        let stats = renderer.performanceSnapshot
        return RendererStressResult(
            framesSubmitted: frames,
            durationSeconds: CACurrentMediaTime() - start,
            averageCPUFrameMs: stats.averageCPUFrameMs,
            p95CPUFrameMs: stats.p95CPUFrameMs,
            dropped120HzFrames: stats.dropped120HzFrames,
            dropped60HzFrames: stats.dropped60HzFrames
        )
    }

    private static func makeFloodSnapshot(columns: Int, rows: Int, seed: Int) -> GridSnapshot {
        let count = max(1, columns * rows)
        var cells: [CellInstance] = []
        cells.reserveCapacity(count)

        var state = UInt64(truncatingIfNeeded: seed) &+ 0x9E3779B97F4A7C15

        for index in 0..<count {
            state = state &* 2862933555777941757 &+ 3037000493

            let row = index / columns
            let col = index % columns
            let ch = UInt32(0x20 + (state % 95))

            let fgIndex = UInt8(truncatingIfNeeded: state >> 8)
            let bgIndex = UInt8(truncatingIfNeeded: state >> 16)

            var attributes: CellAttributes = []
            if state & 1 == 0 { attributes.insert(.bold) }
            if state & 2 == 0 { attributes.insert(.underline) }
            if state & 4 == 0 { attributes.insert(.dim) }

            cells.append(
                CellInstance(
                    row: UInt16(row),
                    col: UInt16(col),
                    glyphIndex: ch,
                    fgColor: TerminalColor.indexed(fgIndex).packedRGBA(),
                    bgColor: TerminalColor.indexed(bgIndex).packedRGBA(),
                    underlineColor: 0,
                    attributes: attributes.rawValue,
                    flags: CellInstance.flagDirty,
                    underlineStyle: 0
                )
            )
        }

        return GridSnapshot(
            cells: cells,
            dirtyRange: 0..<count,
            cursorRow: (seed / max(1, columns)) % max(1, rows),
            cursorCol: seed % max(1, columns),
            cursorVisible: true,
            cursorStyle: .block,
            columns: columns,
            rows: rows
        )
    }
}
