// MetalTerminalRenderer.swift
// ProSSHV2
//
// Main Metal render pipeline for the terminal emulator (spec B.8).
// Ties together FontManager, GlyphRasterizer, GlyphCache, GlyphAtlas,
// CellBuffer, TerminalUniformBuffer, and TerminalShaders.metal into
// a complete GPU-accelerated terminal renderer.
//
// Conforms to MTKViewDelegate and drives the draw loop with in-flight buffering,
// ProMotion support (120 Hz), and instanced quad rendering.

import Foundation
import Metal
import MetalKit
import QuartzCore
import AppKit
import simd

// MARK: - MetalTerminalRenderer

/// Main Metal render pipeline for the terminal emulator.
///
/// This class ties together the glyph atlas, glyph cache, cell buffer,
/// uniform buffer, and Metal shaders into a complete GPU-accelerated
/// terminal renderer. It conforms to `MTKViewDelegate` and drives the
/// draw loop with synchronized in-flight buffering and ProMotion support.
///
/// ## Draw Pipeline
/// 1. Wait on in-flight semaphore
/// 2. Acquire drawable and render pass descriptor
/// 3. Apply pending grid snapshot to the next safe cell buffer
/// 4. Update uniforms (viewport size, time, cursor phase)
/// 5. Encode render pass: pipeline state, vertex/fragment buffers, atlas texture
/// 6. Draw instanced quads (6 vertices per cell, N instances)
/// 7. Present drawable and commit
/// 8. Signal semaphore on GPU completion
///
/// ## Buffer Bindings
/// - buffer(0): CellInstance array (from CellBuffer)
/// - buffer(1): TerminalUniforms
/// - texture(0): Glyph atlas texture (page 0)
/// - texture(1): Previous-frame color texture (CRT phosphor afterglow)
final class MetalTerminalRenderer: NSObject, MTKViewDelegate {

    /// Sentinel glyph index meaning "no glyph".
    /// Must match `CellBuffer` and `TerminalShaders.metal`.
    static let noGlyphIndex: UInt32 = 0xFFFF_FFFF

    // MARK: - Metal Infrastructure (B.8.1)

    /// The Metal device.
    let device: MTLDevice

    /// Command queue for submitting render work.
    let commandQueue: MTLCommandQueue

    /// Compiled render pipeline state (vertex + fragment shaders).
    let pipelineState: MTLRenderPipelineState

    /// Compiled render pipeline state for the post-processing pass.
    let postProcessPipelineState: MTLRenderPipelineState

    // MARK: - Renderer Components

    /// Glyph texture atlas for storing rasterized glyphs.
    let glyphAtlas: GlyphAtlas

    /// LRU cache mapping GlyphKey to AtlasEntry.
    let glyphCache: GlyphCache

    /// GPU buffer for cell instance data (double-buffered).
    let cellBuffer: CellBuffer

    /// GPU buffer for per-frame uniform data.
    let uniformBuffer: TerminalUniformBuffer

    /// Font manager providing fonts and cell dimensions.
    let fontManager: FontManager

    /// Reusable glyph rasterizer for main-thread rasterization (cache pre-population, sync misses).
    let glyphRasterizer = GlyphRasterizer()

    /// Cursor animation and styling state.
    let cursorRenderer = CursorRenderer()

    /// Selection model and selected-cell projection.
    let selectionRenderer = SelectionRenderer()

    /// Rolling frame and draw-call profiler.
    let performanceMonitor = RendererPerformanceMonitor()

    // MARK: - Grid State

    /// Current grid dimensions.
    var gridColumns: Int = 80
    var gridRows: Int = 24

    /// Current cell dimensions in points.
    var cellWidth: CGFloat = 8
    var cellHeight: CGFloat = 16

    /// Store the raw (un-aligned) cell dimensions from FontManager so they
    /// can be re-aligned when the screen scale changes.
    var rawCellWidth: CGFloat = 8
    var rawCellHeight: CGFloat = 16

    /// Public read-only cell height for scroll calculations.
    var currentCellHeight: CGFloat { cellHeight }

    /// Font size used for glyph rasterization, synced from FontManager.
    var rasterFontSize: CGFloat = 14.0

    /// Font name used for glyph rasterization, synced from FontManager.
    var rasterFontName: String = "SF Mono"

    /// Cached CTFont variants for glyph miss rasterization.
    /// Rebuilt only when font name/size/scale changes.
    var cachedRasterFontName: String = ""
    var cachedRasterFontSize: CGFloat = 0
    var cachedRasterScale: CGFloat = 0
    var cachedRasterRegularFont: CTFont?
    var cachedRasterBoldFont: CTFont?
    var cachedRasterItalicFont: CTFont?
    var cachedRasterBoldItalicFont: CTFont?

    /// Snapshot of the four cached CTFont variants for passing to background tasks.
    /// CTFont is immutable and thread-safe but not marked Sendable, so we use @unchecked Sendable.
    var cachedRasterFontSet: RasterFontSet?

    /// Screen scale factor for Retina rendering (e.g., 2.0 on Retina displays).
    /// Glyphs are rasterized at this multiple of point dimensions for crisp text.
    var screenScale: CGFloat = 1.0

    /// Whether a new snapshot has been applied and the buffer is dirty.
    var isDirty: Bool = true

    /// Most recently received snapshot for reapplying transient overlays.
    var latestSnapshot: GridSnapshot?

    // MARK: - Cursor State (from last snapshot)

    /// Cursor row from the most recent grid snapshot.
    var cursorRow: Int = 0

    /// Cursor column from the most recent grid snapshot.
    var cursorCol: Int = 0

    /// Whether the cursor should be visible.
    var cursorVisible: Bool = true

    /// Cursor display style from the most recent grid snapshot.
    var cursorStyle: CursorStyle = .block

    /// Whether cursor blink animation is active.
    var cursorBlinkEnabled: Bool = true

    /// Optional callback when grid dimensions change due to view resize.
    var onGridSizeChange: ((Int, Int) -> Void)?

    /// Weak reference to the configured MTKView for frame rate and pause control.
    weak var configuredMTKView: MTKView?

    /// True when frame pacing should follow the active screen's native refresh
    /// rate rather than a fixed value.
    var usesNativeRefreshRate: Bool = false

    // MARK: - Smooth Scroll

    /// CPU-side physics engine for smooth scrolling.
    let smoothScrollEngine = SmoothScrollEngine()

    /// Current smooth scroll configuration.
    var smoothScrollConfiguration = SmoothScrollConfiguration.load()

    /// Optional closure providing current scrollback count for bounds clamping.
    /// Set by the view layer to bridge scrollback info from the session engine.
    var scrollbackBoundsProvider: (() -> Int)?

    // MARK: - Demand-Driven Rendering

    /// Whether any continuous animation requires the display link to stay active.
    func requiresContinuousFrames() -> Bool {
        if cursorRenderer.requiresContinuousFrames() { return true }
        if smoothScrollEngine.requiresContinuousFrames() { return true }
        if scannerConfiguration.isEnabled && isLocalSession { return true }
        if gradientConfiguration.isEnabled && gradientConfiguration.animationMode != .none { return true }
        return false
    }

    /// Request a redraw. Enables the display link for continuous animations,
    /// or triggers a single-frame `setNeedsDisplay` for one-shot updates.
    func requestFrame() {
        if requiresContinuousFrames() {
            configuredMTKView?.isPaused = false
        } else if let view = configuredMTKView {
            view.setNeedsDisplay(view.bounds)
        }
    }

    /// Feed a raw scroll delta (in points) to the smooth scroll engine.
    func scrollDelta(_ deltaPoints: CGFloat) {
        // Refresh bounds from the session engine before processing delta.
        if let maxRow = scrollbackBoundsProvider?() {
            smoothScrollEngine.setBounds(maxRow: maxRow)
        }
        smoothScrollEngine.scrollDelta(deltaPoints, cellHeight: cellHeight)
        requestFrame()
    }

    /// Jump the scroll engine to a specific row instantly (no animation).
    func scrollJumpTo(row: Int) {
        smoothScrollEngine.jumpTo(row: row)
    }

    /// Called when a direct scroll gesture begins.
    func scrollGestureBegan() {
        smoothScrollEngine.beginGesture()
        requestFrame()
    }

    /// Called when a direct scroll gesture ends.
    func scrollGestureEnded() {
        smoothScrollEngine.endGesture()
        requestFrame()
    }

    /// Called when the trackpad gesture ends — start momentum decay.
    func scrollMomentumBegan() {
        smoothScrollEngine.beginMomentum()
    }

    /// Called when the momentum phase ends — stop momentum.
    func scrollMomentumEnded() {
        smoothScrollEngine.endMomentum()
    }

    // MARK: - In-Flight Buffering (B.8.7)

    /// Semaphore with value 2 to match the double-buffered CellBuffer.
    /// Ensures we never overwrite a cell buffer still in GPU use.
    let inflightSemaphore = DispatchSemaphore(value: 2)

    /// Latest render-ready snapshot waiting to be uploaded to the next safe
    /// writable cell buffer. Applied from the draw loop.
    var pendingRenderSnapshot: GridSnapshot?

    /// When multiple snapshots are coalesced before a draw, per-snapshot dirty
    /// ranges are no longer reliable. Force a full upload for the next apply.
    var forceFullUploadForPendingSnapshot: Bool = false

    // MARK: - Timing

    /// Current viewport size in pixels.
    var viewportSize: CGSize = .zero

    // MARK: - C.2 CRT Effect

    /// Runtime CRT effect configuration (default disabled).
    var crtConfiguration: CRTEffectConfiguration = {
        var config = CRTEffectConfiguration.default
        config.isEnabled = CRTEffect.loadEnabledFromDefaults()
        return config
    }()

    // MARK: - Gradient Background Effect

    /// Runtime gradient background configuration (default disabled).
    var gradientConfiguration: GradientBackgroundConfiguration = GradientBackgroundConfiguration.load()

    // MARK: - Solid Background Effect

    /// Runtime solid background configuration (default disabled).
    var solidBackgroundConfiguration: SolidBackgroundConfiguration = SolidBackgroundConfiguration.load()

    // MARK: - Scanner (Knight Rider) Effect

    /// Runtime scanner effect configuration (default disabled).
    var scannerConfiguration: ScannerEffectConfiguration = ScannerEffectConfiguration.load()

    /// Whether this renderer is attached to a local terminal session.
    /// Scanner effect is only active for local sessions.
    var isLocalSession: Bool = false

    // MARK: - Bloom Effect

    /// Runtime bloom effect configuration (default disabled).
    var bloomConfiguration: BloomEffectConfiguration = BloomEffectConfiguration.load()

    /// Bloom pipeline: extracts luminant pixels into bloomBrightTexture.
    var bloomBrightPipeline: MTLRenderPipelineState?

    /// Bloom pipeline: Gaussian blur pass (used for both H and V).
    var bloomBlurHPipeline: MTLRenderPipelineState?

    /// Bloom pipeline: same object as bloomBlurHPipeline; direction controlled by uniform in Phase 3.
    var bloomBlurVPipeline: MTLRenderPipelineState?

    /// Intermediate texture: bright-pass extraction output (half resolution).
    var bloomBrightTexture: MTLTexture?

    /// Intermediate texture: horizontal blur output (half resolution).
    var bloomBlurH: MTLTexture?

    /// Intermediate texture: vertical blur output / final bloom halo (half resolution).
    var bloomBlurV: MTLTexture?

    /// Previous frame color texture for phosphor afterglow sampling.
    var previousFrameTexture: MTLTexture?

    /// Offscreen scene texture used as post-processing input.
    var postProcessTexture: MTLTexture?

    /// Black fallback texture used before a previous frame exists.
    var crtFallbackTexture: MTLTexture?

    /// True after at least one full frame has been copied into `previousFrameTexture`.
    var hasCapturedPreviousFrame: Bool = false

    /// Previous frame time for frame-delta aware afterglow blending.
    var previousUniformTime: Float = 0

    /// In-flight task for applying font changes. New font updates cancel older ones.
    var fontChangeTask: Task<Void, Never>?

    /// Glyph keys that missed the cache during this draw pass; dispatched for background rasterization.
    var pendingGlyphKeys: Set<GlyphKey> = []

    /// In-flight background rasterization task; nil when idle.
    var glyphRasterTask: Task<Void, Never>?

    /// In-flight cursor blink loop task; nil when blink is inactive or view is externally paused.
    var cursorBlinkTask: Task<Void, Never>?

    // MARK: - Initialization (B.8.1, B.8.2)

    /// Create a MetalTerminalRenderer with a Metal device and font manager.
    ///
    /// Sets up the complete render pipeline:
    /// - Creates command queue
    /// - Loads shader library and creates pipeline state
    /// - Initializes glyph atlas, cache, cell buffer, and uniform buffer
    /// - Pre-populates ASCII glyphs into the atlas
    ///
    /// - Parameters:
    ///   - device: The Metal device to use for rendering.
    ///   - fontManager: The font manager providing fonts and cell dimensions.
    init(device: MTLDevice, fontManager: FontManager) {
        self.device = device
        self.fontManager = fontManager

        // B.8.1: Create command queue.
        guard let queue = device.makeCommandQueue() else {
            fatalError("MetalTerminalRenderer: failed to create MTLCommandQueue")
        }
        queue.label = "TerminalRenderQueue"
        self.commandQueue = queue

        // B.8.2: Load shader library and create render pipeline state.
        guard let library = device.makeDefaultLibrary() else {
            fatalError("MetalTerminalRenderer: failed to load default Metal shader library")
        }

        guard let vertexFunction = library.makeFunction(name: "terminal_vertex") else {
            fatalError("MetalTerminalRenderer: shader function 'terminal_vertex' not found")
        }

        guard let fragmentFunction = library.makeFunction(name: "terminal_fragment") else {
            fatalError("MetalTerminalRenderer: shader function 'terminal_fragment' not found")
        }
        guard let postVertexFunction = library.makeFunction(name: "terminal_post_vertex") else {
            fatalError("MetalTerminalRenderer: shader function 'terminal_post_vertex' not found")
        }
        guard let postFragmentFunction = library.makeFunction(name: "terminal_post_fragment") else {
            fatalError("MetalTerminalRenderer: shader function 'terminal_post_fragment' not found")
        }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "TerminalRenderPipeline"
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        // Enable alpha blending for glyph compositing over background.
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            self.pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            fatalError("MetalTerminalRenderer: failed to create pipeline state: \(error)")
        }

        let postPipelineDescriptor = MTLRenderPipelineDescriptor()
        postPipelineDescriptor.label = "TerminalPostProcessPipeline"
        postPipelineDescriptor.vertexFunction = postVertexFunction
        postPipelineDescriptor.fragmentFunction = postFragmentFunction
        postPipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            self.postProcessPipelineState = try device.makeRenderPipelineState(descriptor: postPipelineDescriptor)
        } catch {
            fatalError("MetalTerminalRenderer: failed to create post-process pipeline state: \(error)")
        }

        // Bloom pipelines (stub shaders in Phase 1; implemented in Phase 2–3).
        if let brightVertex = library.makeFunction(name: "bloom_bright_vertex"),
           let brightFragment = library.makeFunction(name: "bloom_bright_fragment") {
            let brightDesc = MTLRenderPipelineDescriptor()
            brightDesc.label = "BloomBrightPipeline"
            brightDesc.vertexFunction = brightVertex
            brightDesc.fragmentFunction = brightFragment
            brightDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
            self.bloomBrightPipeline = try? device.makeRenderPipelineState(descriptor: brightDesc)
        }

        if let blurVertex = library.makeFunction(name: "bloom_blur_vertex"),
           let blurFragment = library.makeFunction(name: "bloom_blur_fragment") {
            let blurDesc = MTLRenderPipelineDescriptor()
            blurDesc.label = "BloomBlurPipeline"
            blurDesc.vertexFunction = blurVertex
            blurDesc.fragmentFunction = blurFragment
            blurDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
            let blurPipeline = try? device.makeRenderPipelineState(descriptor: blurDesc)
            self.bloomBlurHPipeline = blurPipeline
            self.bloomBlurVPipeline = blurPipeline  // same pipeline; direction via uniform in Phase 3
        }

        // Initialize cell dimensions synchronously from the font manager.
        // FontManager is an actor, so we grab initial values here and update async later.
        let initialCellWidth: CGFloat = 8
        let initialCellHeight: CGFloat = 16

        self.cellWidth = initialCellWidth
        self.cellHeight = initialCellHeight

        // Create glyph atlas with initial cell dimensions.
        self.glyphAtlas = GlyphAtlas(
            device: device,
            cellWidth: Int(ceil(initialCellWidth)),
            cellHeight: Int(ceil(initialCellHeight))
        )

        // Create glyph cache (larger capacity reduces churn for CJK/emoji-heavy output).
        self.glyphCache = GlyphCache(maxCapacity: 8192)

        // Create cell buffer (lazy allocation on first update).
        self.cellBuffer = CellBuffer(device: device)

        // Create uniform buffer.
        guard let ub = TerminalUniformBuffer(device: device) else {
            fatalError("MetalTerminalRenderer: failed to allocate TerminalUniformBuffer")
        }
        self.uniformBuffer = ub

        super.init()

        // Wire eviction callback so the atlas can recycle freed regions.
        glyphCache.onEvict = { [weak self] entry in
            self?.glyphAtlas.reclaimRegion(entry: entry)
        }

        // Pre-populate ASCII glyphs asynchronously.
        Task { [weak self] in
            await self?.initializeFontMetricsAndPrepopulate()
        }
    }

}
