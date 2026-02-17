// TerminalUniforms.swift
// ProSSHV2
//
// Uniform buffer management for the Metal terminal renderer (spec B.7).
// Provides a Swift-side struct matching the Metal shader's TerminalUniforms
// layout, along with a buffer manager that handles per-frame updates,
// animation time tracking, and smooth cursor blink phase calculation.

import Metal
import simd
import QuartzCore

// MARK: - TerminalUniformData

/// Swift representation of the Metal shader's `TerminalUniforms` struct.
/// Layout must match the GPU-side definition byte-for-byte. All fields use
/// SIMD types and fixed-width integers to guarantee Metal-compatible alignment.
///
/// Metal struct reference:
/// ```metal
/// struct TerminalUniforms {
///     float2 cellSize;
///     float2 viewportSize;
///     float2 atlasSize;
///     float  time;
///     float  cursorPhase;
///     float  cursorRenderRow;
///     float  cursorRenderCol;
///     uint   cursorStyle;
///     float  cursorVisible;
///     float  selectionAlpha;
///     float  dimOpacity;
///     float  glowIntensity;
///     float  crtEnabled;
///     float  scanlineOpacity;
///     float  scanlineDensity;
///     float  barrelDistortion;
///     float  phosphorBlend;
///     float  contentScale;
///     float4 selectionColor;
/// };
/// ```
struct TerminalUniformData {
    /// Pixel dimensions of one terminal cell (width, height).
    var cellSize: SIMD2<Float>

    /// Total viewport size in pixels (width, height).
    var viewportSize: SIMD2<Float>

    /// Glyph atlas texture dimensions in pixels (width, height).
    var atlasSize: SIMD2<Float>

    /// Elapsed time in seconds since rendering started. Used for animated
    /// effects such as cursor blink and glow.
    var time: Float

    /// Cursor blink phase, smoothly oscillating between 0.0 (fully hidden)
    /// and 1.0 (fully visible).
    var cursorPhase: Float

    /// Cursor row position in grid space (fractional for smooth animation).
    var cursorRenderRow: Float

    /// Cursor column position in grid space (fractional for smooth animation).
    var cursorRenderCol: Float

    /// Cursor display style: 0 = block, 1 = underline, 2 = bar.
    var cursorStyle: UInt32

    /// Whether the cursor is application-visible (DECTCEM mode 25).
    /// 1.0 = visible, 0.0 = hidden by the remote application.
    /// Distinct from cursorPhase which handles blink animation.
    var cursorVisible: Float

    /// Opacity of the selection highlight overlay (0.0 to 1.0).
    var selectionAlpha: Float

    /// Opacity multiplier for SGR dim (faint) attribute (0.0 to 1.0).
    var dimOpacity: Float

    /// Cursor glow intensity scalar (0.0 to 1.0).
    var glowIntensity: Float

    /// 1.0 when CRT post-processing is enabled, else 0.0.
    var crtEnabled: Float

    /// Scanline darkening opacity multiplier.
    var scanlineOpacity: Float

    /// Scanline frequency scalar.
    var scanlineDensity: Float

    /// Barrel warp strength in NDC.
    var barrelDistortion: Float

    /// Previous-frame phosphor contribution multiplier.
    var phosphorBlend: Float

    /// Screen scale factor for Retina rendering (1.0 = standard, 2.0 = Retina).
    /// Used by the shader to scale decoration thicknesses to maintain consistent
    /// point-size appearance regardless of pixel density.
    var contentScale: Float

    /// Selection tint color (RGB in xyz, w unused by shader).
    var selectionColor: SIMD4<Float>

    // -- Gradient Background Effect Uniforms --

    /// 1.0 when gradient background is enabled, else 0.0.
    var gradientEnabled: Float

    /// Gradient style: 0=linear, 1=radial, 2=angular, 3=diamond, 4=mesh.
    var gradientStyle: UInt32

    /// Padding to align gradientColor1 to 16-byte boundary.
    var _gradientAlignPad0: Float
    var _gradientAlignPad1: Float

    /// Primary gradient color (RGBA).
    var gradientColor1: SIMD4<Float>

    /// Secondary gradient color (RGBA).
    var gradientColor2: SIMD4<Float>

    /// Tertiary gradient color (RGBA) for multi-stop/mesh gradients.
    var gradientColor3: SIMD4<Float>

    /// Fourth gradient color (RGBA) for mesh gradients.
    var gradientColor4: SIMD4<Float>

    /// 1.0 when using 3rd and 4th colors, else 0.0.
    var gradientUseMultipleStops: Float

    /// Gradient angle in radians.
    var gradientAngle: Float

    /// Animation mode: 0=none, 1=breathe, 2=shift, 3=wave, 4=aurora.
    var gradientAnimationMode: UInt32

    /// Animation speed multiplier.
    var gradientAnimationSpeed: Float

    /// Glow effect intensity (0.0 to 1.0).
    var gradientGlowIntensity: Float

    /// Padding to align gradientGlowColor to 16-byte boundary.
    var _gradientAlignPad2: Float
    var _gradientAlignPad3: Float
    var _gradientAlignPad4: Float

    /// Glow color (RGBA).
    var gradientGlowColor: SIMD4<Float>

    /// Glow radius as fraction of viewport.
    var gradientGlowRadius: Float

    /// Film grain / noise intensity.
    var gradientNoiseIntensity: Float

    /// Vignette darkness around edges.
    var gradientVignetteIntensity: Float

    /// How much cell backgrounds blend with gradient (0=opaque cells, 1=transparent).
    var gradientCellBlendOpacity: Float

    /// Saturation adjustment (1.0 = normal).
    var gradientSaturation: Float

    /// Brightness adjustment (0.0 = normal).
    var gradientBrightness: Float

    /// Contrast adjustment (1.0 = normal).
    var gradientContrast: Float

    /// Padding to maintain 16-byte alignment.
    var _gradientPad: Float

    // -- Scanner (Knight Rider) Effect Uniforms --

    /// 1.0 when scanner effect is enabled and session is local, else 0.0.
    var scannerEnabled: Float

    /// Sweep speed multiplier.
    var scannerSpeed: Float

    /// Glow width as fraction of username span.
    var scannerGlowWidth: Float

    /// Glow brightness intensity.
    var scannerIntensity: Float

    /// Scanner glow color (RGBA).
    var scannerColor: SIMD4<Float>

    /// Number of username characters to sweep across.
    var scannerUsernameLen: Float

    /// Trailing tail length.
    var scannerTrailLength: Float

    /// Padding to maintain 16-byte alignment.
    var _scannerPad0: Float
    var _scannerPad1: Float
}

// MARK: - TerminalUniformBuffer

/// Manages a Metal buffer containing `TerminalUniformData` for per-frame
/// upload to the GPU.
///
/// This class tracks animation time since first use and computes a smooth
/// sinusoidal cursor blink phase. It is designed to be updated on the render
/// thread each frame -- it is **not** an actor or Sendable type.
///
/// Usage:
/// 1. Create with a Metal device.
/// 2. Call `update(...)` each frame with current state.
/// 3. Pass `buffer` to the render command encoder as a vertex/fragment buffer.
final class TerminalUniformBuffer {

    // MARK: - Properties

    /// The Metal buffer backing the uniform data. Bind this to the render
    /// encoder at the appropriate buffer index.
    private(set) var buffer: MTLBuffer

    /// Timestamp of the first `update` call, used as the time origin for
    /// animation calculations. Set lazily on first update.
    private var startTime: CFTimeInterval?

    /// The current elapsed time in seconds since the first update.
    private(set) var currentTime: Float = 0

    // MARK: - Configuration

    /// Duration of one half-cycle of the cursor blink, in seconds.
    /// The full blink cycle (visible -> hidden -> visible) takes twice this value.
    /// Default: 0.53 seconds (530 ms), producing a 1.06-second full cycle.
    var blinkHalfPeriod: Float = 0.53

    /// Default opacity for the SGR dim (faint) attribute.
    /// Terminals typically render dim text at approximately 50% opacity.
    var defaultDimOpacity: Float = 0.5

    /// Default opacity for selection highlight overlays.
    var defaultSelectionAlpha: Float = 0.35

    /// Default selection color (blue-ish).
    var defaultSelectionColor: SIMD4<Float> = SIMD4<Float>(0.30, 0.50, 0.90, 1.0)

    // MARK: - Initialization

    /// Creates a new uniform buffer.
    ///
    /// - Parameter device: The Metal device used to allocate the GPU buffer.
    /// - Returns: `nil` if the Metal buffer could not be created.
    init?(device: MTLDevice) {
        let bufferLength = MemoryLayout<TerminalUniformData>.size

        guard let metalBuffer = device.makeBuffer(
            length: bufferLength,
            options: .storageModeShared
        ) else {
            return nil
        }

        metalBuffer.label = "TerminalUniforms"
        self.buffer = metalBuffer
    }

    // MARK: - B.7.1 Uniform Buffer Update

    /// Updates all uniform fields and copies the data into the Metal buffer.
    ///
    /// Call this once per frame before encoding draw commands.
    ///
    /// - Parameters:
    ///   - cellSize: Pixel dimensions of one terminal cell (width, height).
    ///   - viewportSize: Total viewport size in pixels (width, height).
    ///   - atlasSize: Glyph atlas texture dimensions in pixels (width, height).
    ///   - cursorRenderRow: Cursor row position in grid space (fractional).
    ///   - cursorRenderCol: Cursor column position in grid space (fractional).
    ///   - cursorStyle: Cursor display style from `CursorStyle` enum.
    ///   - cursorVisible: Whether the cursor is currently visible (DECTCEM).
    ///   - cursorBlinkEnabled: Whether cursor blink animation is active.
    ///   - selectionAlpha: Selection highlight opacity, or nil to use default.
    ///   - selectionColor: Selection tint color, or nil to use default.
    ///   - dimOpacity: SGR dim attribute opacity, or nil to use default.
    ///   - crtEnabled: Enable CRT post-processing passes.
    ///   - scanlineOpacity: Scanline darkening opacity scalar.
    ///   - scanlineDensity: Scanline frequency scalar.
    ///   - barrelDistortion: Barrel distortion warp strength.
    ///   - phosphorBlend: Previous-frame phosphor blend multiplier.
    ///   - contentScale: Screen scale factor for Retina rendering (default 1.0).
    func update(
        cellSize: SIMD2<Float>,
        viewportSize: SIMD2<Float>,
        atlasSize: SIMD2<Float>,
        cursorRenderRow: Float,
        cursorRenderCol: Float,
        cursorStyle: CursorStyle,
        cursorVisible: Bool,
        cursorBlinkEnabled: Bool,
        cursorPhaseOverride: Float? = nil,
        glowIntensity: Float = 0.0,
        selectionAlpha: Float? = nil,
        selectionColor: SIMD4<Float>? = nil,
        dimOpacity: Float? = nil,
        crtEnabled: Bool = false,
        scanlineOpacity: Float = 0.0,
        scanlineDensity: Float = 0.0,
        barrelDistortion: Float = 0.0,
        phosphorBlend: Float = 0.0,
        contentScale: Float = 1.0,
        gradientConfig: GradientBackgroundConfiguration? = nil,
        scannerConfig: ScannerEffectConfiguration? = nil,
        isLocalSession: Bool = false
    ) {
        // B.7.2: Track animation time
        let now = CACurrentMediaTime()

        if startTime == nil {
            startTime = now
        }

        let elapsed = Float(now - startTime!)
        currentTime = elapsed

        // B.7.3: Calculate cursor blink phase
        let phase: Float
        if let cursorPhaseOverride {
            phase = min(1, max(0, cursorPhaseOverride))
        } else if !cursorVisible {
            phase = 0.0
        } else if !cursorBlinkEnabled {
            phase = 1.0
        } else {
            phase = computeBlinkPhase(time: elapsed)
        }

        // Resolve gradient configuration.
        let gc = gradientConfig ?? GradientBackgroundConfiguration.default

        // Resolve scanner configuration.
        let sc = scannerConfig ?? ScannerEffectConfiguration.default
        let scannerActive = sc.isEnabled && isLocalSession
        let usernameLen: Float = {
            let user = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
            return Float(user.count)
        }()

        // Assemble the uniform struct
        var uniforms = TerminalUniformData(
            cellSize: cellSize,
            viewportSize: viewportSize,
            atlasSize: atlasSize,
            time: elapsed,
            cursorPhase: phase,
            cursorRenderRow: cursorRenderRow,
            cursorRenderCol: cursorRenderCol,
            cursorStyle: UInt32(cursorStyle.rawValue),
            cursorVisible: cursorVisible ? 1.0 : 0.0,
            selectionAlpha: selectionAlpha ?? defaultSelectionAlpha,
            dimOpacity: dimOpacity ?? defaultDimOpacity,
            glowIntensity: min(1, max(0, glowIntensity)),
            crtEnabled: crtEnabled ? 1.0 : 0.0,
            scanlineOpacity: min(1, max(0, scanlineOpacity)),
            scanlineDensity: max(0, scanlineDensity),
            barrelDistortion: max(0, barrelDistortion),
            phosphorBlend: min(1, max(0, phosphorBlend)),
            contentScale: max(1, contentScale),
            selectionColor: selectionColor ?? defaultSelectionColor,
            gradientEnabled: gc.isEnabled ? 1.0 : 0.0,
            gradientStyle: UInt32(gc.style.rawValue),
            _gradientAlignPad0: 0,
            _gradientAlignPad1: 0,
            gradientColor1: SIMD4<Float>(gc.color1.red, gc.color1.green, gc.color1.blue, gc.color1.alpha),
            gradientColor2: SIMD4<Float>(gc.color2.red, gc.color2.green, gc.color2.blue, gc.color2.alpha),
            gradientColor3: SIMD4<Float>(gc.color3.red, gc.color3.green, gc.color3.blue, gc.color3.alpha),
            gradientColor4: SIMD4<Float>(gc.color4.red, gc.color4.green, gc.color4.blue, gc.color4.alpha),
            gradientUseMultipleStops: gc.useMultipleStops ? 1.0 : 0.0,
            gradientAngle: gc.angle * Float.pi / 180.0,
            gradientAnimationMode: UInt32(gc.animationMode.rawValue),
            gradientAnimationSpeed: max(0.01, gc.animationSpeed),
            gradientGlowIntensity: min(1, max(0, gc.glowIntensity)),
            _gradientAlignPad2: 0,
            _gradientAlignPad3: 0,
            _gradientAlignPad4: 0,
            gradientGlowColor: SIMD4<Float>(gc.glowColor.red, gc.glowColor.green, gc.glowColor.blue, gc.glowColor.alpha),
            gradientGlowRadius: min(2, max(0.05, gc.glowRadius)),
            gradientNoiseIntensity: min(1, max(0, gc.noiseIntensity)),
            gradientVignetteIntensity: min(1, max(0, gc.vignetteIntensity)),
            gradientCellBlendOpacity: min(1, max(0, gc.cellBlendOpacity)),
            gradientSaturation: min(3, max(0, gc.saturation)),
            gradientBrightness: min(0.5, max(-0.5, gc.brightness)),
            gradientContrast: min(3, max(0.1, gc.contrast)),
            _gradientPad: 0,
            scannerEnabled: scannerActive ? 1.0 : 0.0,
            scannerSpeed: max(0.1, sc.speed),
            scannerGlowWidth: min(0.5, max(0.02, sc.glowWidth)),
            scannerIntensity: min(3, max(0, sc.intensity)),
            scannerColor: SIMD4<Float>(sc.color.red, sc.color.green, sc.color.blue, sc.color.alpha),
            scannerUsernameLen: usernameLen,
            scannerTrailLength: min(0.5, max(0, sc.trailLength)),
            _scannerPad0: 0,
            _scannerPad1: 0
        )

        // Copy into the Metal buffer
        let size = MemoryLayout<TerminalUniformData>.size
        memcpy(buffer.contents(), &uniforms, size)
    }

    // MARK: - B.7.2 Time Tracking

    /// Resets the animation time origin to the current time.
    /// The next `update` call will report `time = 0` and begin counting up again.
    /// Useful after returning from background or reconnecting a session.
    func resetTime() {
        startTime = nil
        currentTime = 0
    }

    // MARK: - B.7.3 Cursor Blink Phase

    /// Computes a smooth sinusoidal blink phase for the cursor.
    ///
    /// The phase oscillates between 0.0 (fully hidden) and 1.0 (fully visible)
    /// using a sine wave, producing a gentle fade rather than a hard on/off toggle.
    ///
    /// Formula: `phase = (sin(time * pi / blinkHalfPeriod) + 1) / 2`
    ///
    /// - Parameter time: Elapsed time in seconds since animation start.
    /// - Returns: Blink phase value in the range [0.0, 1.0].
    private func computeBlinkPhase(time: Float) -> Float {
        let angularFrequency = Float.pi / blinkHalfPeriod
        let raw = sinf(time * angularFrequency)
        return (raw + 1.0) / 2.0
    }
}
