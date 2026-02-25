// swiftlint:disable file_length
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

    // MARK: - Scanner (Knight Rider) Effect

    /// Runtime scanner effect configuration (default disabled).
    var scannerConfiguration: ScannerEffectConfiguration = ScannerEffectConfiguration.load()

    /// Whether this renderer is attached to a local terminal session.
    /// Scanner effect is only active for local sessions.
    var isLocalSession: Bool = false

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

        // Pre-populate ASCII glyphs asynchronously.
        Task { [weak self] in
            await self?.initializeFontMetricsAndPrepopulate()
        }
    }

    // MARK: - MTKViewDelegate: Resize (B.8.6)

    /// Called when the MTKView's drawable size changes (rotation, resize, etc.).
    ///
    /// - Parameters:
    ///   - view: The MTKView whose size changed.
    ///   - size: The new drawable size in pixels.
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        viewportSize = size

        if usesNativeRefreshRate {
            setPreferredFPS(0)
        }

        // Detect screen scale factor from drawable-to-bounds ratio.
        let pointSize = view.bounds.size
        let hasValidBounds = pointSize.width > 0 && pointSize.height > 0
        let newScale: CGFloat
        if hasValidBounds && size.width > 0 {
            let measuredScale = max(size.width / pointSize.width, 1.0)
            // Keep scale aligned to physical backing scales (1x/2x/3x)
            // to avoid fractional atlas/cell drift and UV misalignment.
            newScale = max(1.0, round(measuredScale))
        } else {
            // Preserve current scale during transient zero-sized layout passes.
            newScale = screenScale
        }

        // If scale changed (e.g., window moved to a different display),
        // re-align cell dimensions and rebuild the atlas at the new pixel resolution.
        if abs(newScale - screenScale) > 0.01 {
            screenScale = newScale
            // Re-align cellWidth/cellHeight to the new screen scale so the
            // atlas slot size and shader cell size are identical (integer pixels).
            reapplyPixelAlignment()
            let cw = Int(round(cellWidth * screenScale))
            let ch = Int(round(cellHeight * screenScale))
            glyphAtlas.rebuild(cellWidth: cw, cellHeight: ch)
            glyphCache.clear()
            glyphCache.prePopulateASCII { [weak self] key in
                guard let self else { return nil }
                return self.rasterizeAndUpload(key: key)
            }
            if let latestSnapshot {
                updateSnapshot(latestSnapshot)
            }
            isDirty = true
        }

        // Recalculate grid dimensions in points.
        // During early layout passes, `bounds` can briefly be zero while
        // `drawableSize` is already valid. Fall back to drawable size when needed.
        let logicalWidth = pointSize.width > 0 ? pointSize.width : (size.width / max(newScale, 1.0))
        let logicalHeight = pointSize.height > 0 ? pointSize.height : (size.height / max(newScale, 1.0))

        // cellWidth/cellHeight are pixel-aligned points from the renderer.
        if cellWidth > 0, cellHeight > 0, logicalWidth > 0, logicalHeight > 0 {
            let newColumns = max(1, Int(logicalWidth / cellWidth))
            let newRows = max(1, Int(logicalHeight / cellHeight))

            if newColumns != gridColumns || newRows != gridRows {
                gridColumns = newColumns
                gridRows = newRows

                // Notify the cell buffer of the new dimensions.
                cellBuffer.resize(columns: newColumns, rows: newRows)
                onGridSizeChange?(newColumns, newRows)
                isDirty = true
            }
        }
    }

    // MARK: - View Configuration (B.8.6)

    /// Configure an MTKView for terminal rendering.
    /// Sets up ProMotion frame rate, clear color, and pixel format.
    ///
    /// - Parameter view: The MTKView to configure.
    func configureView(_ view: MTKView) {
        view.device = device
        view.delegate = self
        view.colorPixelFormat = .bgra8Unorm
        configuredMTKView = view

        // B.8.6: ProMotion support — use native display refresh (60 Hz or 120 Hz).
        setPreferredFPS(0)

        // Dark terminal background.
        view.clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)

        // Enable display link driven rendering.
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        selectionRenderer.refreshSelectionColorFromSystemAccent()
    }

    // MARK: - Frame Rate Control (2.2.9 / 2.2.10)

    /// Pause or unpause rendering. Use for panes that are not visible
    /// (e.g. hidden behind a maximized pane or off-screen in another tab).
    func setPaused(_ paused: Bool) {
        configuredMTKView?.isPaused = paused
    }

    /// Set the preferred frames per second.
    /// Pass 0 to follow the current screen's native refresh rate.
    func setPreferredFPS(_ fps: Int) {
        guard let view = configuredMTKView else { return }
        usesNativeRefreshRate = fps <= 0
        if usesNativeRefreshRate {
            view.preferredFramesPerSecond = max(60, currentScreenMaximumFPS())
        } else {
            let nativeFPS = max(30, currentScreenMaximumFPS())
            view.preferredFramesPerSecond = min(max(1, fps), nativeFPS)
        }
    }

    func currentScreenMaximumFPS() -> Int {
        if let screenFPS = configuredMTKView?.window?.screen?.maximumFramesPerSecond {
            return screenFPS
        }
        if let mainFPS = NSScreen.main?.maximumFramesPerSecond {
            return mainFPS
        }
        return 60
    }

    // MARK: - Selection

    /// Update selection range and immediately re-project selection flags if a snapshot exists.
    func setSelection(
        start: SelectionPoint,
        end: SelectionPoint,
        type: SelectionType
    ) {
        selectionRenderer.selection = TerminalSelection(start: start, end: end, type: type)
        if let latestSnapshot {
            updateSnapshot(latestSnapshot)
        }
    }

    /// Clear active selection and re-render.
    func clearSelection() {
        selectionRenderer.clearSelection()
        if let latestSnapshot {
            updateSnapshot(latestSnapshot)
        }
    }

    /// Select all visible cells.
    func selectAll() {
        guard let snapshot = latestSnapshot, snapshot.rows > 0, snapshot.columns > 0 else { return }
        setSelection(
            start: SelectionPoint(row: 0, col: 0),
            end: SelectionPoint(row: snapshot.rows - 1, col: snapshot.columns - 1),
            type: .character
        )
    }

    /// Whether there is an active selection.
    var hasSelection: Bool {
        selectionRenderer.selection != nil
    }

    /// Extract the selected text from the latest snapshot using original Unicode codepoints.
    func selectedText() -> String? {
        guard let selection = selectionRenderer.selection,
              let snapshot = latestSnapshot else { return nil }

        let cols = snapshot.columns
        let rows = snapshot.rows
        guard cols > 0, rows > 0 else { return nil }

        // Normalize start/end ordering
        let startLinear = selection.start.row * cols + selection.start.col
        let endLinear = selection.end.row * cols + selection.end.col
        let (selStart, selEnd) = startLinear <= endLinear
            ? (selection.start, selection.end)
            : (selection.end, selection.start)

        // Expand word/line boundaries
        var expanded = TerminalSelection(start: selStart, end: selEnd, type: selection.type)
        if selection.type == .line {
            expanded.start.col = 0
            expanded.end.col = cols - 1
        }

        var result = ""
        for row in expanded.start.row...expanded.end.row {
            let left = (row == expanded.start.row) ? expanded.start.col : 0
            let right = (row == expanded.end.row) ? expanded.end.col : (cols - 1)

            var lineChars: [Character] = []
            for col in left...right {
                let idx = row * cols + col
                guard idx >= 0 && idx < snapshot.cells.count else { continue }
                let codepoint = snapshot.cells[idx].glyphIndex
                if codepoint == 0 {
                    lineChars.append(" ")
                } else if let scalar = Unicode.Scalar(codepoint) {
                    lineChars.append(Character(scalar))
                }
            }

            // Trim trailing spaces for each line
            while lineChars.last == " " { lineChars.removeLast() }
            result += String(lineChars)

            if row < expanded.end.row {
                result += "\n"
            }
        }

        return result.isEmpty ? nil : result
    }

    /// Convert a point position (in the MTKView's coordinate space) to a grid cell.
    func gridCell(at point: CGPoint) -> SelectionPoint? {
        guard cellWidth > 0, cellHeight > 0 else { return nil }
        let col = Int(point.x / cellWidth)

        // macOS NSView coordinates have origin at bottom-left (y increases upward),
        // but the terminal grid has row 0 at the top. Flip the y-coordinate.
        let scale = max(screenScale, 1.0)
        let viewHeightPoints = viewportSize.height / scale
        let flippedY = max(0, viewHeightPoints - point.y)
        let row = Int(flippedY / cellHeight)

        return SelectionPoint(row: max(0, row), col: max(0, col))
    }

    // MARK: - CRT Effect

    /// Enable or disable CRT post-processing. Persists the preference in user defaults.
    func setCRTEffectEnabled(_ enabled: Bool) {
        crtConfiguration.isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: CRTEffect.enabledDefaultsKey)
        if !enabled {
            hasCapturedPreviousFrame = false
        }
        isDirty = true
    }

    /// Apply custom CRT parameters.
    func setCRTEffectConfiguration(_ configuration: CRTEffectConfiguration) {
        crtConfiguration = configuration
        UserDefaults.standard.set(configuration.isEnabled, forKey: CRTEffect.enabledDefaultsKey)
        if !configuration.isEnabled {
            hasCapturedPreviousFrame = false
        }
        isDirty = true
    }

    /// Refresh CRT effect enabled state from persisted settings.
    func reloadCRTEffectSettings() {
        crtConfiguration.isEnabled = CRTEffect.loadEnabledFromDefaults()
        if !crtConfiguration.isEnabled {
            hasCapturedPreviousFrame = false
        }
        isDirty = true
    }

    // MARK: - Gradient Background Effect

    /// Enable or disable the gradient background effect.
    func setGradientBackgroundEnabled(_ enabled: Bool) {
        gradientConfiguration.isEnabled = enabled
        gradientConfiguration.save()
        isDirty = true
    }

    /// Apply a complete gradient background configuration.
    func setGradientBackgroundConfiguration(_ configuration: GradientBackgroundConfiguration) {
        gradientConfiguration = configuration
        gradientConfiguration.save()
        isDirty = true
    }

    /// Reload gradient background settings from persisted UserDefaults.
    func reloadGradientBackgroundSettings() {
        gradientConfiguration = GradientBackgroundConfiguration.load()
        isDirty = true
    }

    // MARK: - Scanner (Knight Rider) Effect

    /// Reload scanner effect settings from persisted UserDefaults.
    func reloadScannerEffectSettings() {
        scannerConfiguration = ScannerEffectConfiguration.load()
        isDirty = true
    }

    /// Current gradient background configuration (read-only).
    var currentGradientConfiguration: GradientBackgroundConfiguration {
        gradientConfiguration
    }

    func ensurePostProcessTextures(for drawableSize: CGSize) {
        let width = max(1, Int(drawableSize.width))
        let height = max(1, Int(drawableSize.height))

        if crtFallbackTexture == nil {
            crtFallbackTexture = makeCRTFallbackTexture()
        }

        if previousFrameTexture?.width != width || previousFrameTexture?.height != height {
            previousFrameTexture = makeCRTFrameTexture(width: width, height: height)
            hasCapturedPreviousFrame = false
        }

        if postProcessTexture?.width != width || postProcessTexture?.height != height {
            postProcessTexture = makePostProcessTexture(width: width, height: height)
        }
    }

    func makeCRTFrameTexture(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .private
        descriptor.resourceOptions = .storageModePrivate
        return device.makeTexture(descriptor: descriptor)
    }

    func makePostProcessTexture(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        descriptor.resourceOptions = .storageModePrivate
        return device.makeTexture(descriptor: descriptor)
    }

    func makeSceneRenderPassDescriptor(
        texture: MTLTexture,
        clearColor: MTLClearColor
    ) -> MTLRenderPassDescriptor {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = clearColor
        return descriptor
    }

    func makeCRTFallbackTexture() -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        descriptor.resourceOptions = .storageModeShared

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }

        var blackPixel: [UInt8] = [0, 0, 0, 255]
        blackPixel.withUnsafeMutableBytes { bytes in
            if let baseAddress = bytes.baseAddress {
                texture.replace(
                    region: MTLRegionMake2D(0, 0, 1, 1),
                    mipmapLevel: 0,
                    withBytes: baseAddress,
                    bytesPerRow: 4
                )
            }
        }
        return texture
    }

    // MARK: - Diagnostics

    /// Returns the current glyph cache hit rate (0.0 to 1.0).
    var cacheHitRate: Double {
        glyphCache.hitRate
    }

    /// Returns the number of atlas pages currently allocated.
    var atlasPageCount: Int {
        glyphAtlas.pageCount
    }

    /// Returns current atlas texture memory usage estimate in bytes.
    var atlasMemoryBytes: Int {
        glyphAtlas.estimatedMemoryBytes
    }

    /// Returns the number of entries in the glyph cache.
    var cachedGlyphCount: Int {
        glyphCache.count
    }

    /// Returns rolling renderer performance metrics.
    var performanceSnapshot: RendererPerformanceSnapshot {
        performanceMonitor.snapshot()
    }
}
