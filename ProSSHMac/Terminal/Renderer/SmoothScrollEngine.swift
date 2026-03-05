// SmoothScrollEngine.swift
// ProSSHV2
//
// CPU-side physics engine for smooth scrolling.
// Tracks scroll state, applies spring interpolation and momentum decay.
// Follows the CursorRenderer pattern: target state → interpolated render state per frame.

import Foundation
import AppKit

// MARK: - SmoothScrollFrame

/// Animated scroll state produced each render tick.
struct SmoothScrollFrame: Sendable {
    /// Pixel offset to apply in the vertex shader (sub-row position).
    let offsetPixels: Float
    /// Whether the scroll animation is still in progress.
    let isAnimating: Bool
}

// MARK: - SmoothScrollEngine

/// CPU-side physics engine for smooth scrolling.
///
/// The engine accumulates raw scroll deltas (in points), converts them to fractional
/// row offsets, and fires `onScrollLineChange` when integer row boundaries are crossed.
/// Each render tick, `frame()` returns the sub-pixel offset for the GPU vertex shader.
/// After the trackpad releases, optional momentum decay carries the scroll velocity,
/// and spring interpolation snaps the fractional remainder back to zero.
final class SmoothScrollEngine {

    // MARK: - Configuration

    private var config: SmoothScrollConfiguration = {
        var cfg = SmoothScrollConfiguration.default
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            cfg.isEnabled = false
        }
        return cfg
    }()

    // MARK: - Target State

    /// The discrete scrollback row that the terminal buffer is positioned at.
    private(set) var targetScrollRow: Int = 0

    // MARK: - Bounds

    /// Minimum scroll row (always 0 — top of scrollback).
    private var minTargetRow: Int = 0

    /// Maximum scroll row (scrollback count). `Int.max` means unbounded.
    private var maxTargetRow: Int = Int.max

    /// Maximum rubber-band overshoot in rows beyond bounds.
    private let rubberBandLimit: Float = 0.3

    /// Spring stiffness multiplier for rubber-band snap-back (3× normal).
    private let rubberBandStiffnessMultiplier: Float = 3.0

    // MARK: - Render State

    /// Fractional offset in rows from the target position.
    /// Positive = content shifted down (mid-scroll-up animation).
    private var renderOffset: Float = 0.0

    /// Current scroll velocity in rows per frame (for momentum).
    private var velocity: Float = 0.0

    /// Whether a momentum phase is active (trackpad released with velocity).
    private var inMomentum: Bool = false

    /// Snap threshold — same as CursorRenderer.
    private let snapEpsilon: Float = 0.001

    /// Exponential moving average factor for velocity tracking.
    private let velocitySmoothing: Float = 0.3

    // MARK: - Timing

    /// Last frame timestamp for frame-rate-independent physics.
    private var lastFrameTime: Double = 0

    // MARK: - Callback

    /// Fires when `targetScrollRow` changes by integer rows.
    /// The parameter is the signed delta (negative = scroll up, positive = scroll down).
    var onScrollLineChange: ((Int) -> Void)?

    // MARK: - Bounds API

    /// Set the scroll bounds. `minRow` is always 0; `maxRow` is the scrollback count.
    func setBounds(maxRow: Int) {
        maxTargetRow = max(0, maxRow)
        minTargetRow = 0
    }

    // MARK: - Programmatic Scroll

    /// Jump instantly to a specific scroll row. Zeros velocity/offset — no animation.
    /// The caller is responsible for updating the grid snapshot.
    func jumpTo(row: Int) {
        let clampedRow = min(max(row, minTargetRow), maxTargetRow)
        // Snapshot publishes frequently re-assert the current scroll row.
        // Treat same-row sync as a no-op so in-flight smooth scrolling
        // keeps its fractional offset and momentum instead of snapping.
        guard clampedRow != targetScrollRow else { return }
        targetScrollRow = clampedRow
        renderOffset = 0
        velocity = 0
        inMomentum = false
    }

    // MARK: - Resize

    /// Reset scroll animation state on terminal resize. Zeros offset/velocity.
    func handleResize() {
        renderOffset = 0
        velocity = 0
        inMomentum = false
    }

    // MARK: - Public API

    /// Feed a raw scroll delta from NSEvent (in points, not rows).
    func scrollDelta(_ deltaPoints: CGFloat, cellHeight: CGFloat) {
        guard cellHeight > 0 else { return }

        let deltaRows = Float(deltaPoints) / Float(cellHeight)
        renderOffset += deltaRows

        // Track velocity as exponential moving average
        velocity = velocity * (1.0 - velocitySmoothing) + deltaRows * velocitySmoothing

        // Clamp velocity
        velocity = min(max(velocity, -config.maxVelocity), config.maxVelocity)

        // Extract integer row changes (with bounds clamping)
        extractIntegerRows()
    }

    /// Called when the trackpad gesture ends — start momentum if enabled.
    func beginMomentum() {
        if config.momentumEnabled {
            inMomentum = true
        }
    }

    /// Called when momentum phase ends — stop momentum.
    func endMomentum() {
        inMomentum = false
        velocity = 0
    }

    /// Advance one render frame with frame-rate-independent physics.
    /// Returns the pixel offset to upload to the GPU.
    ///
    /// - Parameters:
    ///   - cellHeight: Cell height in pixels (points × screenScale).
    ///   - time: Current frame time from `CACurrentMediaTime()`.
    func frame(cellHeight: CGFloat, time: Double) -> SmoothScrollFrame {
        let ch = Float(cellHeight)

        // Compute delta time for frame-rate independence.
        // Cap at 1/30s to prevent huge jumps after stalls.
        let dt: Float
        if lastFrameTime > 0 {
            dt = min(Float(time - lastFrameTime), 1.0 / 30.0)
        } else {
            dt = 1.0 / 60.0 // assume 60fps for first frame
        }
        lastFrameTime = time

        let atBounds = isAtBounds()

        if inMomentum && config.momentumEnabled {
            // Apply velocity to render offset
            renderOffset += velocity * dt * 60.0
            // Frame-rate-independent friction: velocity *= friction^(dt*60)
            velocity *= pow(config.friction, dt * 60.0)
            // Extract integer rows during momentum
            extractIntegerRows()
            // Stop momentum when velocity is negligible
            if abs(velocity) < 0.01 {
                inMomentum = false
                velocity = 0
            }
            // If at bounds during momentum, kill velocity to prevent fighting
            if isAtBounds() && renderOffset != 0 {
                velocity = 0
                inMomentum = false
            }
        }

        if abs(renderOffset) > snapEpsilon {
            // Spring back to zero — frame-rate-independent lerp.
            // At bounds with rubber-band overshoot, use stronger spring.
            let stiffness: Float
            if atBounds && isRubberBanding() {
                stiffness = min(config.springStiffness * rubberBandStiffnessMultiplier, 1.0)
            } else {
                stiffness = config.springStiffness
            }
            let factor = 1.0 - pow(1.0 - stiffness, dt * 60.0)
            renderOffset = renderOffset * (1.0 - factor)

            // Snap to zero when below epsilon
            if abs(renderOffset) < snapEpsilon {
                renderOffset = 0
            }
        }

        // Clamp render offset: at bounds allow ±rubberBandLimit, otherwise ±1.5 rows
        if atBounds {
            renderOffset = min(max(renderOffset, -rubberBandLimit), rubberBandLimit)
        } else {
            renderOffset = min(max(renderOffset, -1.5), 1.5)
        }

        let animating = requiresContinuousFrames()
        return SmoothScrollFrame(
            offsetPixels: renderOffset * ch,
            isAnimating: animating
        )
    }

    /// Whether continuous frame updates are needed (animation in progress).
    func requiresContinuousFrames() -> Bool {
        inMomentum || abs(renderOffset) > snapEpsilon
    }

    /// Reload configuration (call at start of each scroll gesture).
    func reloadConfiguration(_ newConfig: SmoothScrollConfiguration) {
        config = newConfig
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            config.isEnabled = false
        }
    }

    // MARK: - Internals

    /// Whether the target scroll row is at one of the bounds.
    private func isAtBounds() -> Bool {
        targetScrollRow <= minTargetRow || targetScrollRow >= maxTargetRow
    }

    /// Whether the render offset is in rubber-band territory (past bounds).
    private func isRubberBanding() -> Bool {
        if targetScrollRow <= minTargetRow && renderOffset < 0 { return true }
        if targetScrollRow >= maxTargetRow && renderOffset > 0 { return true }
        return false
    }

    /// Extract integer row changes from renderOffset and fire callback.
    /// Clamps `targetScrollRow` to `[minTargetRow, maxTargetRow]`.
    private func extractIntegerRows() {
        if abs(renderOffset) >= 1.0 {
            let integerRows = Int(renderOffset)
            let proposedTarget = targetScrollRow + integerRows

            // Clamp to bounds
            let clampedTarget = min(max(proposedTarget, minTargetRow), maxTargetRow)
            let actualDelta = clampedTarget - targetScrollRow

            if actualDelta != 0 {
                targetScrollRow = clampedTarget
                // Remove only the consumed rows from renderOffset
                renderOffset -= Float(actualDelta)
                onScrollLineChange?(actualDelta)
            } else {
                // At bounds — absorb the integer part into renderOffset (rubber-band)
                // but don't let it exceed rubberBandLimit
                renderOffset = min(max(renderOffset, -rubberBandLimit), rubberBandLimit)
            }
        }
    }
}
