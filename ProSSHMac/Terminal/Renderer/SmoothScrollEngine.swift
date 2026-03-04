// SmoothScrollEngine.swift
// ProSSHV2
//
// CPU-side physics engine for smooth scrolling.
// Tracks scroll state, applies spring interpolation and momentum decay.
// Follows the CursorRenderer pattern: target state → interpolated render state per frame.

import Foundation

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

    private var config = SmoothScrollConfiguration.default

    // MARK: - Target State

    /// The discrete scrollback row that the terminal buffer is positioned at.
    private(set) var targetScrollRow: Int = 0

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

    // MARK: - Callback

    /// Fires when `targetScrollRow` changes by integer rows.
    /// The parameter is the signed delta (negative = scroll up, positive = scroll down).
    var onScrollLineChange: ((Int) -> Void)?

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

        // Extract integer row changes
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

    /// Advance one render frame. Returns the pixel offset to upload to the GPU.
    func frame(cellHeight: CGFloat) -> SmoothScrollFrame {
        let ch = Float(cellHeight)

        if inMomentum && config.momentumEnabled {
            // Apply velocity to render offset
            renderOffset += velocity
            // Decay velocity
            velocity *= config.friction
            // Extract integer rows during momentum
            extractIntegerRows()
            // Stop momentum when velocity is negligible
            if abs(velocity) < 0.01 {
                inMomentum = false
                velocity = 0
            }
        } else if abs(renderOffset) > snapEpsilon {
            // Spring back to zero
            renderOffset = CursorEffects.lerp(current: renderOffset, target: 0.0, factor: config.springStiffness)
            // Snap to zero when below epsilon
            if abs(renderOffset) < snapEpsilon {
                renderOffset = 0
            }
        }

        // Clamp render offset to ±1.5 rows
        renderOffset = min(max(renderOffset, -1.5), 1.5)

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
    }

    // MARK: - Internals

    /// Extract integer row changes from renderOffset and fire callback.
    private func extractIntegerRows() {
        if abs(renderOffset) >= 1.0 {
            let integerRows = Int(renderOffset)
            targetScrollRow += integerRows
            renderOffset -= Float(integerRows)
            onScrollLineChange?(integerRows)
        }
    }
}
