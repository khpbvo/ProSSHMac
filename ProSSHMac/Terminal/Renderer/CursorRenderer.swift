// CursorRenderer.swift
// ProSSHV2
//
// Cursor animation model for the Metal terminal renderer.
// Handles cursor style state transitions, blink timing, smooth movement,
// and glow pulse intensity.

import Foundation

/// Animated cursor state used by the renderer each frame.
struct CursorRenderFrame: Sendable {
    /// Animated cursor row in grid space (0-based, fractional during lerp).
    let row: Float

    /// Animated cursor column in grid space (0-based, fractional during lerp).
    let col: Float

    /// Cursor style for this frame.
    let style: CursorStyle

    /// Cursor visibility phase in [0, 1].
    /// 0 = hidden, 1 = fully visible.
    let phase: Float

    /// Extra glow intensity scalar in [0, 1].
    let glowIntensity: Float
}

/// Cursor animation engine.
///
/// The renderer provides target row/column/style/visibility on each snapshot.
/// The engine advances once per frame and produces interpolated render state.
final class CursorRenderer {

    // MARK: - State Machine

    enum StyleState: UInt8, Sendable {
        case block
        case underline
        case bar

        init(style: CursorStyle) {
            switch style {
            case .block: self = .block
            case .underline: self = .underline
            case .bar: self = .bar
            }
        }

        var cursorStyle: CursorStyle {
            switch self {
            case .block: return .block
            case .underline: return .underline
            case .bar: return .bar
            }
        }
    }

    // MARK: - Tunables

    /// Half period of the blink waveform (530ms default).
    var blinkHalfPeriod: Float = 0.53

    /// Position interpolation factor per frame.
    var positionLerpFactor: Float = 0.35

    /// Baseline glow scalar.
    var baseGlow: Float = 0.65

    /// Pulse range added on top of the baseline glow.
    var pulseGlow: Float = 0.35

    /// Phase offset so glow pulse does not exactly match blink phase.
    var glowPhaseOffset: Float = Float.pi * 0.35

    // MARK: - Target State

    private var targetRow: Float = 0
    private var targetCol: Float = 0
    private var styleState: StyleState = .block
    private var cursorVisible: Bool = true
    private var blinkEnabled: Bool = true

    // MARK: - Render State

    private var renderRow: Float = 0
    private var renderCol: Float = 0
    private var seeded = false
    private let snapEpsilon: Float = 0.001

    // MARK: - Public API

    /// Update desired cursor state from the latest grid snapshot.
    func updateTarget(
        row: Int,
        col: Int,
        style: CursorStyle,
        visible: Bool,
        blinkEnabled: Bool
    ) {
        targetRow = Float(max(0, row))
        targetCol = Float(max(0, col))
        styleState = StyleState(style: style)
        cursorVisible = visible
        self.blinkEnabled = blinkEnabled

        if !seeded {
            renderRow = targetRow
            renderCol = targetCol
            seeded = true
        }
    }

    /// Advance one render tick and return interpolated cursor state.
    func frame(at time: CFTimeInterval) -> CursorRenderFrame {
        renderRow = CursorEffects.lerp(current: renderRow, target: targetRow, factor: positionLerpFactor)
        renderCol = CursorEffects.lerp(current: renderCol, target: targetCol, factor: positionLerpFactor)
        if abs(renderRow - targetRow) < snapEpsilon { renderRow = targetRow }
        if abs(renderCol - targetCol) < snapEpsilon { renderCol = targetCol }

        let t = Float(time)
        let phase = computeBlinkPhase(time: t)
        let glow = computeGlowIntensity(time: t, phase: phase)

        return CursorRenderFrame(
            row: renderRow,
            col: renderCol,
            style: styleState.cursorStyle,
            phase: phase,
            glowIntensity: glow
        )
    }

    /// Whether the cursor requires continuous frame updates.
    func requiresContinuousFrames() -> Bool {
        let moving = abs(renderRow - targetRow) >= snapEpsilon || abs(renderCol - targetCol) >= snapEpsilon
        return moving || (cursorVisible && blinkEnabled)
    }

    // MARK: - Internals

    private func computeBlinkPhase(time: Float) -> Float {
        CursorEffects.blinkPhase(
            time: time,
            halfPeriod: blinkHalfPeriod,
            visible: cursorVisible,
            blinkEnabled: blinkEnabled
        )
    }

    private func computeGlowIntensity(time: Float, phase: Float) -> Float {
        CursorEffects.glowIntensity(
            time: time,
            blinkPhase: phase,
            base: baseGlow,
            pulseRange: pulseGlow,
            phaseOffset: glowPhaseOffset
        )
    }
}
