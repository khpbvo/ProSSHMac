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
    private static let noGlyphIndex: UInt32 = 0xFFFF_FFFF

    // MARK: - Metal Infrastructure (B.8.1)

    /// The Metal device.
    private let device: MTLDevice

    /// Command queue for submitting render work.
    private let commandQueue: MTLCommandQueue

    /// Compiled render pipeline state (vertex + fragment shaders).
    private let pipelineState: MTLRenderPipelineState

    /// Compiled render pipeline state for the post-processing pass.
    private let postProcessPipelineState: MTLRenderPipelineState

    // MARK: - Renderer Components

    /// Glyph texture atlas for storing rasterized glyphs.
    private let glyphAtlas: GlyphAtlas

    /// LRU cache mapping GlyphKey to AtlasEntry.
    private let glyphCache: GlyphCache

    /// GPU buffer for cell instance data (double-buffered).
    private let cellBuffer: CellBuffer

    /// GPU buffer for per-frame uniform data.
    private let uniformBuffer: TerminalUniformBuffer

    /// Font manager providing fonts and cell dimensions.
    private let fontManager: FontManager

    /// Cursor animation and styling state.
    private let cursorRenderer = CursorRenderer()

    /// Selection model and selected-cell projection.
    private let selectionRenderer = SelectionRenderer()

    /// Rolling frame and draw-call profiler.
    private let performanceMonitor = RendererPerformanceMonitor()

    // MARK: - Grid State

    /// Current grid dimensions.
    private var gridColumns: Int = 80
    private var gridRows: Int = 24

    /// Current cell dimensions in points.
    private var cellWidth: CGFloat = 8
    private var cellHeight: CGFloat = 16

    /// Public read-only cell height for scroll calculations.
    var currentCellHeight: CGFloat { cellHeight }

    /// Font size used for glyph rasterization, synced from FontManager.
    private var rasterFontSize: CGFloat = 14.0

    /// Font name used for glyph rasterization, synced from FontManager.
    private var rasterFontName: String = "SF Mono"

    /// Screen scale factor for Retina rendering (e.g., 2.0 on Retina displays).
    /// Glyphs are rasterized at this multiple of point dimensions for crisp text.
    private var screenScale: CGFloat = 1.0

    /// Whether a new snapshot has been applied and the buffer is dirty.
    private var isDirty: Bool = true

    /// Most recently received snapshot for reapplying transient overlays.
    private var latestSnapshot: GridSnapshot?

    // MARK: - Cursor State (from last snapshot)

    /// Cursor row from the most recent grid snapshot.
    private var cursorRow: Int = 0

    /// Cursor column from the most recent grid snapshot.
    private var cursorCol: Int = 0

    /// Whether the cursor should be visible.
    private var cursorVisible: Bool = true

    /// Cursor display style from the most recent grid snapshot.
    private var cursorStyle: CursorStyle = .block

    /// Whether cursor blink animation is active.
    var cursorBlinkEnabled: Bool = true

    /// Optional callback when grid dimensions change due to view resize.
    var onGridSizeChange: ((Int, Int) -> Void)?

    /// Weak reference to the configured MTKView for frame rate and pause control.
    private weak var configuredMTKView: MTKView?

    /// True when frame pacing should follow the active screen's native refresh
    /// rate rather than a fixed value.
    private var usesNativeRefreshRate: Bool = false

    // MARK: - In-Flight Buffering (B.8.7)

    /// Semaphore with value 2 to match the double-buffered CellBuffer.
    /// Ensures we never overwrite a cell buffer still in GPU use.
    private let inflightSemaphore = DispatchSemaphore(value: 2)

    /// Latest render-ready snapshot waiting to be uploaded to the next safe
    /// writable cell buffer. Applied from the draw loop.
    private var pendingRenderSnapshot: GridSnapshot?

    /// When multiple snapshots are coalesced before a draw, per-snapshot dirty
    /// ranges are no longer reliable. Force a full upload for the next apply.
    private var forceFullUploadForPendingSnapshot: Bool = false

    // MARK: - Timing

    /// Current viewport size in pixels.
    private var viewportSize: CGSize = .zero

    // MARK: - C.2 CRT Effect

    /// Runtime CRT effect configuration (default disabled).
    private var crtConfiguration: CRTEffectConfiguration = {
        var config = CRTEffectConfiguration.default
        config.isEnabled = CRTEffect.loadEnabledFromDefaults()
        return config
    }()

    // MARK: - Gradient Background Effect

    /// Runtime gradient background configuration (default disabled).
    private var gradientConfiguration: GradientBackgroundConfiguration = GradientBackgroundConfiguration.load()

    // MARK: - Scanner (Knight Rider) Effect

    /// Runtime scanner effect configuration (default disabled).
    private var scannerConfiguration: ScannerEffectConfiguration = ScannerEffectConfiguration.load()

    /// Whether this renderer is attached to a local terminal session.
    /// Scanner effect is only active for local sessions.
    var isLocalSession: Bool = false

    /// Previous frame color texture for phosphor afterglow sampling.
    private var previousFrameTexture: MTLTexture?

    /// Offscreen scene texture used as post-processing input.
    private var postProcessTexture: MTLTexture?

    /// Black fallback texture used before a previous frame exists.
    private var crtFallbackTexture: MTLTexture?

    /// True after at least one full frame has been copied into `previousFrameTexture`.
    private var hasCapturedPreviousFrame: Bool = false

    /// Previous frame time for frame-delta aware afterglow blending.
    private var previousUniformTime: Float = 0

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

    // MARK: - Async Initialization

    /// Fetches actual cell dimensions from the FontManager actor and
    /// pre-populates the glyph cache with ASCII characters.
    private func initializeFontMetricsAndPrepopulate() async {
        let dims = await fontManager.currentCellDimensions()
        let fontSize = await fontManager.effectiveFontSize
        let fontName = await fontManager.fontName

        // Store raw dimensions for re-alignment when screen scale changes.
        self.rawCellWidth = dims.width
        self.rawCellHeight = dims.height
        self.rasterFontSize = fontSize
        self.rasterFontName = fontName

        // Pixel-align cell dimensions so the atlas slot width, shader cell
        // size, and grid layout all use the same integer-pixel values.
        // round in pixel space then convert back to points:
        //   e.g. 8.4pt × 2.0 = 16.8px → round → 17px → 17/2.0 = 8.5pt
        let scale = max(screenScale, 1.0)
        let pixelW = round(dims.width * scale)
        let pixelH = ceil(dims.height * scale)
        self.cellWidth = pixelW / scale
        self.cellHeight = pixelH / scale

        let cw = Int(pixelW)
        let ch = Int(pixelH)

        // Rebuild the atlas with the pixel-aligned cell dimensions.
        glyphAtlas.rebuild(cellWidth: cw, cellHeight: ch)

        // Clear the glyph cache — any entries cached before the atlas rebuild
        // now point to stale positions in the old atlas layout.
        glyphCache.clear()

        // Pre-populate ASCII glyphs (0x20-0x7E) across regular, bold, italic.
        glyphCache.prePopulateASCII { [weak self] key in
            guard let self else { return nil }
            return self.rasterizeAndUpload(key: key)
        }

        // Force grid recalculation with the new cell dimensions.
        recalculateGridDimensions()
        isDirty = true
    }

    // MARK: - Glyph Resolution

    /// Rasterize a glyph for the given key and upload it to the atlas.
    /// Called synchronously from the render path on cache miss.
    ///
    /// - Parameter key: The glyph key (codepoint + style).
    /// - Returns: An AtlasEntry describing the glyph's location in the atlas, or nil.
    private func rasterizeAndUpload(key: GlyphKey) -> AtlasEntry? {
        // Scale cell dimensions for Retina-quality rasterization.
        let scale = screenScale
        let cw = Int(ceil(cellWidth * scale))
        let ch = Int(ceil(cellHeight * scale))

        guard cw > 0, ch > 0 else { return nil }
        guard let scalar = Unicode.Scalar(key.codepoint) else { return nil }

        // Create a CTFont at the scaled font size for Retina-quality glyphs.
        // This avoids crossing the actor boundary in the synchronous render path.
        let scaledFontSize = rasterFontSize * scale
        let font = CTFontCreateWithName(rasterFontName as CFString, scaledFontSize, nil)

        let variantFont: CTFont
        if key.bold && key.italic {
            let traits: CTFontSymbolicTraits = [.boldTrait, .italicTrait]
            variantFont = CTFontCreateCopyWithSymbolicTraits(font, scaledFontSize, nil, traits, traits) ?? font
        } else if key.bold {
            variantFont = CTFontCreateCopyWithSymbolicTraits(font, scaledFontSize, nil, .boldTrait, .boldTrait) ?? font
        } else if key.italic {
            variantFont = CTFontCreateCopyWithSymbolicTraits(font, scaledFontSize, nil, .italicTrait, .italicTrait) ?? font
        } else {
            variantFont = font
        }

        // Font fallback: if the primary font lacks a glyph for this codepoint
        // (or the codepoint is in an emoji range where the primary font's
        // placeholder glyph is not useful), ask CoreText to resolve the best
        // system font — e.g. Apple Color Emoji for emoji, PingFang for CJK.
        let renderFont = Self.resolveRenderFont(for: scalar, primaryFont: variantFont)

        let rasterized = GlyphRasterizer.rasterize(
            codepoint: scalar,
            font: renderFont,
            cellWidth: cw,
            cellHeight: ch
        )

        guard rasterized.width > 0, rasterized.height > 0, !rasterized.pixelData.isEmpty else {
            return nil
        }

        // Upload to atlas.
        let entry = rasterized.pixelData.withUnsafeBufferPointer { ptr -> AtlasEntry? in
            guard let baseAddress = ptr.baseAddress else { return nil }
            return glyphAtlas.allocate(
                width: rasterized.width,
                height: rasterized.height,
                pixelData: baseAddress,
                bearingX: Int8(clamping: rasterized.bearingX),
                bearingY: Int8(clamping: rasterized.bearingY)
            )
        }

        return entry
    }

    // MARK: - Font Fallback for Rasterization

    /// Resolve the best font for rendering a specific Unicode scalar.
    ///
    /// For emoji codepoints, always asks CoreText for the system's preferred
    /// emoji font (Apple Color Emoji) since monospace fonts like SF Mono map
    /// emoji codepoints to placeholder "?" glyphs that pass glyph-presence
    /// checks but render incorrectly.
    ///
    /// For non-emoji codepoints, checks whether the primary font contains
    /// the glyph. If not, uses `CTFontCreateForString` to find a system
    /// fallback (e.g. PingFang for CJK, Symbols for Powerline glyphs).
    ///
    /// - Parameters:
    ///   - scalar: The Unicode scalar to render.
    ///   - primaryFont: The primary terminal font (SF Mono variant).
    /// - Returns: The best CTFont for rendering this scalar.
    private static func resolveRenderFont(
        for scalar: Unicode.Scalar,
        primaryFont: CTFont
    ) -> CTFont {
        let string = String(scalar)
        let cfString = string as CFString
        let range = CFRange(location: 0, length: CFStringGetLength(cfString))

        // For emoji codepoints, always prefer the system emoji font.
        // Monospace fonts (SF Mono, Menlo, etc.) often have placeholder glyphs
        // for emoji that pass CTFontGetGlyphsForCharacters but render as "?".
        if isEmojiRange(scalar.value) {
            let fallback = CTFontCreateForString(primaryFont, cfString, range)
            let fallbackFamily = CTFontCopyFamilyName(fallback) as String
            let primaryFamily = CTFontCopyFamilyName(primaryFont) as String
            // If CoreText found a different (emoji) font, use it.
            // If it returned the same font, there's no better option available.
            if fallbackFamily != primaryFamily {
                return fallback
            }
        }

        // For non-emoji: check if the primary font has the glyph.
        let utf16 = Array(string.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        let found = CTFontGetGlyphsForCharacters(primaryFont, utf16, &glyphs, utf16.count)

        if found && glyphs[0] != 0 {
            return primaryFont
        }

        // Primary font lacks the glyph — use CoreText system fallback.
        let fallback = CTFontCreateForString(primaryFont, cfString, range)
        return fallback
    }

    /// Check if a Unicode scalar value falls within well-known emoji ranges.
    /// These ranges should use a color emoji font rather than the monospace
    /// terminal font, which typically renders placeholders for these codepoints.
    private static func isEmojiRange(_ v: UInt32) -> Bool {
        // Miscellaneous Symbols and Pictographs + Emoticons
        if (0x1F300...0x1F64F).contains(v) { return true }
        // Transport and Map Symbols
        if (0x1F680...0x1F6FF).contains(v) { return true }
        // Supplemental Symbols and Pictographs
        if (0x1F900...0x1F9FF).contains(v) { return true }
        // Symbols and Pictographs Extended-A/B
        if (0x1FA00...0x1FAFF).contains(v) { return true }
        // Alchemical Symbols
        if (0x1F700...0x1F77F).contains(v) { return true }
        // Regional indicator symbols (flags)
        if (0x1F1E0...0x1F1FF).contains(v) { return true }
        // Miscellaneous Symbols (snowman, lightning, stars, etc.)
        if (0x2600...0x26FF).contains(v) { return true }
        // Dingbats (arrows, pencils, scissors, etc.)
        if (0x2700...0x27BF).contains(v) { return true }
        // Miscellaneous Technical (keyboard, etc.)
        if (0x2300...0x23FF).contains(v) { return true }
        // Geometric Shapes (circles, squares used as icons)
        if (0x25A0...0x25FF).contains(v) { return true }
        // Enclosed Alphanumerics / Symbols
        if (0x2460...0x24FF).contains(v) { return true }
        // Box-drawing and block elements are NOT emoji — handled by primary font
        // Variation selectors (emoji vs text presentation)
        if (0xFE00...0xFE0F).contains(v) { return true }
        // Zero-width joiner (emoji sequences)
        if v == 0x200D { return true }
        // Combining Enclosing Keycap
        if v == 0x20E3 { return true }
        // Skin tone modifiers
        if (0x1F3FB...0x1F3FF).contains(v) { return true }
        // Copyright, Registered, Trademark
        if v == 0x00A9 || v == 0x00AE || v == 0x2122 { return true }
        // Arrows supplement (used by some TUIs)
        if (0x2B05...0x2B55).contains(v) { return true }
        // Mahjong, dominos
        if (0x1F000...0x1F02F).contains(v) { return true }
        // Tags block (emoji flag sequences)
        if (0xE0020...0xE007F).contains(v) { return true }
        return false
    }

    // MARK: - Snapshot Update (B.8.4)

    /// Called when the terminal grid has new data to render.
    /// Stores the latest render-ready snapshot; the draw loop applies it on
    /// the next frame in a buffer-safe context.
    ///
    /// For each cell:
    /// 1. Look up the glyph in the cache by (codepoint, bold, italic)
    /// 2. On cache miss: rasterize with GlyphRasterizer, upload to GlyphAtlas,
    ///    insert into GlyphCache
    /// 3. Return the packed atlas position as UInt32 for the shader
    ///
    /// - Parameter snapshot: The grid snapshot to render.
    func updateSnapshot(_ snapshot: GridSnapshot) {
        latestSnapshot = snapshot
        let renderSnapshot = selectionRenderer.applySelection(to: snapshot)
        if pendingRenderSnapshot != nil {
            forceFullUploadForPendingSnapshot = true
        }
        pendingRenderSnapshot = renderSnapshot

        gridColumns = renderSnapshot.columns
        gridRows = renderSnapshot.rows

        // Store cursor state for uniform updates.
        cursorRow = renderSnapshot.cursorRow
        cursorCol = renderSnapshot.cursorCol
        cursorVisible = renderSnapshot.cursorVisible
        cursorStyle = renderSnapshot.cursorStyle
        cursorRenderer.updateTarget(
            row: renderSnapshot.cursorRow,
            col: renderSnapshot.cursorCol,
            style: renderSnapshot.cursorStyle,
            visible: renderSnapshot.cursorVisible,
            blinkEnabled: cursorBlinkEnabled
        )
        isDirty = true
    }

    private func applyPendingSnapshotIfNeeded() {
        guard let snapshot = pendingRenderSnapshot else { return }
        pendingRenderSnapshot = nil

        let snapshotToApply: GridSnapshot
        if forceFullUploadForPendingSnapshot {
            forceFullUploadForPendingSnapshot = false
            snapshotToApply = GridSnapshot(
                cells: snapshot.cells,
                dirtyRange: nil,
                cursorRow: snapshot.cursorRow,
                cursorCol: snapshot.cursorCol,
                cursorVisible: snapshot.cursorVisible,
                cursorStyle: snapshot.cursorStyle,
                columns: snapshot.columns,
                rows: snapshot.rows
            )
        } else {
            snapshotToApply = snapshot
        }

        cellBuffer.update(from: snapshotToApply) { [weak self] cell -> UInt32 in
            guard let self else { return Self.noGlyphIndex }
            return self.resolveGlyphIndex(for: cell)
        }
        cellBuffer.swapBuffers()
    }

    private func resolveGlyphIndex(for cell: CellInstance) -> UInt32 {
        let attributes = CellAttributes(rawValue: cell.attributes)
        let bold = attributes.contains(.bold)
        let italic = attributes.contains(.italic)

        // The grid snapshot stores the Unicode codepoint in glyphIndex initially.
        let codepoint = cell.glyphIndex
        let key = GlyphKey(codepoint: codepoint, bold: bold, italic: italic)

        // Look up in cache.
        if let entry = glyphCache.trackedLookup(key) {
            return packAtlasEntry(entry)
        }

        // Cache miss: rasterize and upload.
        if let entry = rasterizeAndUpload(key: key) {
            glyphCache.insert(key, entry: entry)
            return packAtlasEntry(entry)
        }

        // Rasterization failed; use no-glyph sentinel.
        return Self.noGlyphIndex
    }

    /// Pack an AtlasEntry into a UInt32 for the shader.
    /// Matches the Metal shader's decoding:
    ///   atlasX = float(glyphIndex & 0xFFFF)
    ///   atlasY = float((glyphIndex >> 16) & 0xFFFF)
    ///
    /// Layout: [y:16][x:16] — upper 16 bits = Y pixel position, lower 16 bits = X pixel position.
    private func packAtlasEntry(_ entry: AtlasEntry) -> UInt32 {
        let x = UInt32(entry.x) & 0xFFFF
        let y = UInt32(entry.y) & 0xFFFF
        return (y << 16) | x
    }

    // MARK: - MTKViewDelegate: Draw (B.8.3, B.8.4)

    /// Called each frame by the MTKView display link.
    /// Implements the full draw loop with in-flight synchronization.
    ///
    /// - Parameter view: The MTKView requesting a draw.
    func draw(in view: MTKView) {
        // Wait on in-flight semaphore before reusing cell buffers.
        _ = inflightSemaphore.wait(timeout: .distantFuture)

        // Get current drawable and render pass descriptor.
        guard let drawable = view.currentDrawable else {
            inflightSemaphore.signal()
            return
        }

        guard let drawableRenderPassDescriptor = view.currentRenderPassDescriptor else {
            inflightSemaphore.signal()
            return
        }

        // Create command buffer.
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inflightSemaphore.signal()
            return
        }
        commandBuffer.label = "TerminalFrame"

        let drawableSize = view.drawableSize
        let scannerActive = scannerConfiguration.isEnabled && isLocalSession
        let usesPostProcessing = crtConfiguration.isEnabled || gradientConfiguration.isEnabled || scannerActive
        if usesPostProcessing {
            ensurePostProcessTextures(for: drawableSize)
        }

        let postProcessingReady = usesPostProcessing &&
            postProcessTexture != nil &&
            previousFrameTexture != nil

        // Apply latest pending snapshot in a buffer-safe context.
        applyPendingSnapshotIfNeeded()

        // Update uniforms for this frame via the TerminalUniformBuffer.
        let cursorFrame = cursorRenderer.frame(at: CACurrentMediaTime())
        let frameDelta = max(0, uniformBuffer.currentTime - previousUniformTime)
        let phosphorBlend = (postProcessingReady && hasCapturedPreviousFrame)
            ? CRTEffect.phosphorBlend(
                persistence: crtConfiguration.phosphorPersistence,
                frameDeltaSeconds: frameDelta
            )
            : 0.0

        // Pass cellSize and viewportSize in pixel space for Retina-correct rendering.
        // cellSize = point dimensions × screenScale, viewportSize = drawableSize.
        // The shader uses these consistently for NDC conversion and atlas UV mapping.
        uniformBuffer.update(
            cellSize: SIMD2<Float>(Float(cellWidth * screenScale), Float(cellHeight * screenScale)),
            viewportSize: SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height)),
            atlasSize: SIMD2<Float>(Float(glyphAtlas.pageSize), Float(glyphAtlas.pageSize)),
            cursorRenderRow: cursorFrame.row,
            cursorRenderCol: cursorFrame.col,
            cursorStyle: cursorFrame.style,
            cursorVisible: cursorVisible,
            cursorBlinkEnabled: cursorBlinkEnabled,
            cursorPhaseOverride: cursorFrame.phase,
            glowIntensity: cursorFrame.glowIntensity,
            selectionAlpha: selectionRenderer.selectionAlpha,
            selectionColor: selectionRenderer.selectionColor,
            crtEnabled: postProcessingReady && crtConfiguration.isEnabled,
            scanlineOpacity: crtConfiguration.scanlineOpacity,
            scanlineDensity: crtConfiguration.scanlineDensity,
            barrelDistortion: crtConfiguration.barrelDistortion,
            phosphorBlend: phosphorBlend,
            contentScale: Float(screenScale),
            gradientConfig: gradientConfiguration,
            scannerConfig: scannerConfiguration,
            isLocalSession: isLocalSession
        )
        previousUniformTime = uniformBuffer.currentTime

        let frameStart = CACurrentMediaTime()
        let frameSignpostID = performanceMonitor.beginFrame()
        var drawCalls = 0

        if postProcessingReady, let sceneTexture = postProcessTexture {
            let sceneRenderPassDescriptor = makeSceneRenderPassDescriptor(
                texture: sceneTexture,
                clearColor: view.clearColor
            )

            guard let sceneEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: sceneRenderPassDescriptor) else {
                inflightSemaphore.signal()
                return
            }
            sceneEncoder.label = "TerminalSceneEncoder"
            drawCalls += encodeTerminalScenePass(sceneEncoder, drawableSize: drawableSize)
            sceneEncoder.endEncoding()

            guard let postEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: drawableRenderPassDescriptor) else {
                inflightSemaphore.signal()
                return
            }
            postEncoder.label = "TerminalPostProcessEncoder"

            let viewport = MTLViewport(
                originX: 0,
                originY: 0,
                width: Double(drawableSize.width),
                height: Double(drawableSize.height),
                znear: 0,
                zfar: 1
            )
            postEncoder.setViewport(viewport)

            let scissorRect = MTLScissorRect(
                x: 0,
                y: 0,
                width: Int(drawableSize.width),
                height: Int(drawableSize.height)
            )
            postEncoder.setScissorRect(scissorRect)

            postEncoder.setRenderPipelineState(postProcessPipelineState)
            postEncoder.setFragmentBuffer(uniformBuffer.buffer, offset: 0, index: 1)
            postEncoder.setFragmentTexture(sceneTexture, index: 0)
            postEncoder.setFragmentTexture(previousFrameTexture ?? crtFallbackTexture, index: 1)
            postEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            postEncoder.endEncoding()
            drawCalls += 1

            // Save scene output for phosphor history sampling on the next frame.
            if let historyTexture = previousFrameTexture,
               let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
                blitEncoder.label = "TerminalCRTFrameHistoryCopy"
                let copyWidth = min(sceneTexture.width, historyTexture.width)
                let copyHeight = min(sceneTexture.height, historyTexture.height)
                if copyWidth > 0, copyHeight > 0 {
                    blitEncoder.copy(
                        from: sceneTexture,
                        sourceSlice: 0,
                        sourceLevel: 0,
                        sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                        sourceSize: MTLSize(width: copyWidth, height: copyHeight, depth: 1),
                        to: historyTexture,
                        destinationSlice: 0,
                        destinationLevel: 0,
                        destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                    )
                    hasCapturedPreviousFrame = true
                }
                blitEncoder.endEncoding()
            }
        } else {
            guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: drawableRenderPassDescriptor) else {
                inflightSemaphore.signal()
                return
            }
            renderEncoder.label = "TerminalRenderEncoder"
            drawCalls += encodeTerminalScenePass(renderEncoder, drawableSize: drawableSize)
            renderEncoder.endEncoding()
        }

        // Present drawable.
        commandBuffer.present(drawable)

        // B.8.7: Signal semaphore when GPU work completes.
        let semaphore = inflightSemaphore
        let cpuFrameDuration = CACurrentMediaTime() - frameStart
        performanceMonitor.endFrame(
            signpostID: frameSignpostID,
            cpuFrameSeconds: cpuFrameDuration,
            gpuFrameSeconds: nil,
            drawCalls: drawCalls
        )
        commandBuffer.addCompletedHandler { _ in
            semaphore.signal()
        }

        // Commit the command buffer.
        commandBuffer.commit()

        isDirty = false
    }

    private func encodeTerminalScenePass(
        _ renderEncoder: MTLRenderCommandEncoder,
        drawableSize: CGSize
    ) -> Int {
        let viewport = MTLViewport(
            originX: 0,
            originY: 0,
            width: Double(drawableSize.width),
            height: Double(drawableSize.height),
            znear: 0,
            zfar: 1
        )
        renderEncoder.setViewport(viewport)

        let scissorRect = MTLScissorRect(
            x: 0,
            y: 0,
            width: Int(drawableSize.width),
            height: Int(drawableSize.height)
        )
        renderEncoder.setScissorRect(scissorRect)

        renderEncoder.setRenderPipelineState(pipelineState)

        if let readBuffer = cellBuffer.readBuffer {
            renderEncoder.setVertexBuffer(readBuffer, offset: 0, index: 0)
        }
        renderEncoder.setVertexBuffer(uniformBuffer.buffer, offset: 0, index: 1)
        renderEncoder.setFragmentBuffer(uniformBuffer.buffer, offset: 0, index: 1)

        if let atlasTexture = glyphAtlas.texture(forPage: 0) {
            renderEncoder.setFragmentTexture(atlasTexture, index: 0)
        }
        renderEncoder.setFragmentTexture(previousFrameTexture ?? crtFallbackTexture, index: 1)

        let instanceCount = cellBuffer.cellCount
        guard instanceCount > 0 else { return 0 }

        renderEncoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: 6,
            instanceCount: instanceCount
        )
        return 1
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
        let nativeFPS = max(30, currentScreenMaximumFPS())
        usesNativeRefreshRate = fps <= 0
        if usesNativeRefreshRate {
            view.preferredFramesPerSecond = nativeFPS
        } else {
            view.preferredFramesPerSecond = min(max(1, fps), nativeFPS)
        }
    }

    private func currentScreenMaximumFPS() -> Int {
        if let screenFPS = configuredMTKView?.window?.screen?.maximumFramesPerSecond {
            return screenFPS
        }
        if let mainFPS = NSScreen.main?.maximumFramesPerSecond {
            return mainFPS
        }
        return 60
    }

    // MARK: - Font Change

    /// Called when the font configuration changes.
    /// Rebuilds the glyph atlas, clears the cache, and re-populates ASCII glyphs.
    func handleFontChange() {
        Task { [weak self] in
            guard let self else { return }

            let dims = await fontManager.currentCellDimensions()
            let fontSize = await fontManager.effectiveFontSize
            let fontName = await fontManager.fontName

            // Store raw dimensions and pixel-align to the current screen scale.
            self.rawCellWidth = dims.width
            self.rawCellHeight = dims.height
            self.rasterFontSize = fontSize
            self.rasterFontName = fontName

            let scale = max(self.screenScale, 1.0)
            let pixelW = round(dims.width * scale)
            let pixelH = ceil(dims.height * scale)
            self.cellWidth = pixelW / scale
            self.cellHeight = pixelH / scale

            let cw = Int(pixelW)
            let ch = Int(pixelH)
            self.glyphAtlas.rebuild(cellWidth: cw, cellHeight: ch)

            // Clear the glyph cache (all entries are now invalid).
            self.glyphCache.clear()

            // Re-populate ASCII glyphs.
            self.glyphCache.prePopulateASCII { [weak self] key in
                guard let self else { return nil }
                return self.rasterizeAndUpload(key: key)
            }

            // Recalculate grid with new cell dimensions.
            self.recalculateGridDimensions()
            // Reset the uniform buffer's animation time after font change.
            self.uniformBuffer.resetTime()
            self.isDirty = true
        }
    }

    /// Updates the base terminal font size and refreshes renderer metrics.
    func setFontSize(_ size: CGFloat) {
        Task { [weak self] in
            guard let self else { return }
            await self.fontManager.setFont(size: size)
            self.handleFontChange()
        }
    }

    // MARK: - Pixel Alignment Helpers

    /// Store the raw (un-aligned) cell dimensions from FontManager so they
    /// can be re-aligned when the screen scale changes.
    private var rawCellWidth: CGFloat = 8
    private var rawCellHeight: CGFloat = 16

    /// Re-apply pixel alignment to cellWidth/cellHeight using the current
    /// screenScale. Called when the scale factor changes (e.g., window moved
    /// to a different display).
    private func reapplyPixelAlignment() {
        let scale = max(screenScale, 1.0)
        cellWidth = round(rawCellWidth * scale) / scale
        cellHeight = ceil(rawCellHeight * scale) / scale
    }

    /// Recalculate grid dimensions using the current viewport and cell sizes.
    /// Useful after cell dimensions change asynchronously (e.g., font load).
    private func recalculateGridDimensions() {
        let scale = max(screenScale, 1.0)
        let logicalWidth: CGFloat
        let logicalHeight: CGFloat
        if viewportSize.width > 0 {
            logicalWidth = viewportSize.width / scale
            logicalHeight = viewportSize.height / scale
        } else {
            return
        }

        guard cellWidth > 0, cellHeight > 0 else { return }

        let newColumns = max(1, Int(logicalWidth / cellWidth))
        let newRows = max(1, Int(logicalHeight / cellHeight))

        if newColumns != gridColumns || newRows != gridRows {
            gridColumns = newColumns
            gridRows = newRows
            cellBuffer.resize(columns: newColumns, rows: newRows)
            onGridSizeChange?(newColumns, newRows)
            isDirty = true
        }
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

    private func ensurePostProcessTextures(for drawableSize: CGSize) {
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

    private func makeCRTFrameTexture(width: Int, height: Int) -> MTLTexture? {
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

    private func makePostProcessTexture(width: Int, height: Int) -> MTLTexture? {
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

    private func makeSceneRenderPassDescriptor(
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

    private func makeCRTFallbackTexture() -> MTLTexture? {
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
