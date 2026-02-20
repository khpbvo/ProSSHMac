// GlyphAtlas.swift
// ProSSHV2
//
// Metal texture atlas for glyph storage.
// Manages one or more MTLTexture pages (each 2048x2048, .rgba8Unorm)
// with row-major glyph packing. The atlas is the backing store for
// rasterized glyphs — the GlyphCache maps GlyphKeys to AtlasEntry
// positions within these textures.

import Metal

// MARK: - Constants

/// Default atlas texture dimension (width and height) in pixels.
private let kAtlasPageSize: Int = 2048

/// Maximum number of atlas pages before the atlas is considered full.
private let kMaxAtlasPages: Int = 16

// MARK: - AtlasPage

/// Internal representation of a single atlas texture page.
private struct AtlasPage {
    /// The Metal texture backing this page.
    let texture: MTLTexture

    /// Page index within the atlas.
    let index: UInt8
}

// MARK: - GlyphAtlas

/// Manages a multi-page Metal texture atlas for glyph storage.
///
/// Glyphs are packed in row-major order within each page. All pages use
/// `.rgba8Unorm` pixel format so text glyphs and color emoji can coexist
/// on the same page. The shader distinguishes between them at render time.
///
/// Usage:
/// 1. Create the atlas with a Metal device and initial cell dimensions.
/// 2. Call `allocate(width:height:pixelData:)` to place a rasterized glyph.
/// 3. The returned `AtlasEntry` contains the UV coordinates for the shader.
/// 4. On font change, call `rebuild(cellWidth:cellHeight:device:)` to reset.
final class GlyphAtlas {

    // MARK: - Properties

    /// The Metal device used to create textures.
    private let device: MTLDevice

    /// Width of a single glyph cell in pixels.
    private(set) var cellWidth: Int

    /// Height of a single glyph cell in pixels.
    private(set) var cellHeight: Int

    /// All allocated atlas texture pages.
    private var pages: [AtlasPage] = []

    /// Current packing X position within the active page (pixels).
    private var nextX: Int = 0

    /// Current packing Y position within the active page (pixels).
    private var nextY: Int = 0

    /// Height of the current packing row (equals cellHeight).
    private var rowHeight: Int = 0

    /// Atlas page dimension (width = height = kAtlasPageSize).
    let pageSize: Int

    // MARK: - Initialization

    /// Creates a new glyph atlas.
    ///
    /// - Parameters:
    ///   - device: The Metal device for texture allocation.
    ///   - cellWidth: Width of a standard glyph cell in pixels.
    ///   - cellHeight: Height of a standard glyph cell in pixels.
    ///   - pageSize: Texture dimension for each atlas page (default 2048).
    init(device: MTLDevice, cellWidth: Int, cellHeight: Int, pageSize: Int = kAtlasPageSize) {
        self.device = device
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.pageSize = pageSize
        self.rowHeight = cellHeight
    }

    // MARK: - Page Management

    /// Returns the number of allocated atlas pages.
    var pageCount: Int {
        pages.count
    }

    /// Estimated memory usage (bytes) of allocated atlas textures.
    ///
    /// Uses RGBA8 layout: 4 bytes per pixel.
    var estimatedMemoryBytes: Int {
        pageCount * pageSize * pageSize * 4
    }

    /// Returns the texture for a given page index, or nil if out of range.
    ///
    /// - Parameter page: Zero-based page index.
    /// - Returns: The `MTLTexture` for that page, or nil.
    func texture(forPage page: Int) -> MTLTexture? {
        guard page >= 0, page < pages.count else { return nil }
        return pages[page].texture
    }

    /// Allocates a new atlas page texture.
    ///
    /// - Returns: The newly created `AtlasPage`, or nil if allocation fails
    ///   or the maximum page count has been reached.
    @discardableResult
    private func allocatePage() -> AtlasPage? {
        guard pages.count < kMaxAtlasPages else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: pageSize,
            height: pageSize,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }

        texture.label = "GlyphAtlas Page \(pages.count)"

        let page = AtlasPage(texture: texture, index: UInt8(pages.count))
        pages.append(page)
        return page
    }

    // MARK: - Glyph Allocation

    /// Allocates space in the atlas for a glyph, uploads pixel data, and
    /// returns an `AtlasEntry` describing its location.
    ///
    /// The glyph is placed at the next available slot using row-major packing.
    /// If the current page is full, a new page is allocated automatically.
    ///
    /// - Parameters:
    ///   - width: Width of the glyph bitmap in pixels.
    ///            For standard glyphs this is `cellWidth`; for wide glyphs, `2 * cellWidth`.
    ///   - height: Height of the glyph bitmap in pixels (typically `cellHeight`).
    ///   - pixelData: Raw pixel data in RGBA8 format. Must contain exactly
    ///                `width * height * 4` bytes.
    ///   - bearingX: Horizontal bearing offset for glyph positioning.
    ///   - bearingY: Vertical bearing offset (baseline) for glyph positioning.
    /// - Returns: An `AtlasEntry` with the glyph's location, or nil if allocation fails.
    func allocate(
        width: Int,
        height: Int,
        pixelData: UnsafeRawPointer,
        bearingX: Int8 = 0,
        bearingY: Int8 = 0
    ) -> AtlasEntry? {
        guard width > 0, height > 0 else { return nil }
        guard width <= pageSize, height <= pageSize else { return nil }

        // Ensure we have at least one page.
        if pages.isEmpty {
            guard allocatePage() != nil else { return nil }
        }

        // Try to fit the glyph in the current row of the current page.

        if nextX + width > pageSize {
            // Move to the next row and reset row height for the new row.
            nextX = 0
            nextY += rowHeight
            rowHeight = cellHeight
        }

        if nextY + height > pageSize {
            // Current page is full — allocate a new page.
            guard allocatePage() != nil else { return nil }
            nextX = 0
            nextY = 0
            rowHeight = cellHeight
        }

        let currentPageIndex = pages.count - 1
        let placedX = nextX
        let placedY = nextY

        // Upload pixel data to the atlas texture.
        uploadRegion(
            page: currentPageIndex,
            x: placedX,
            y: placedY,
            width: width,
            height: height,
            data: pixelData
        )

        // Advance the packing cursor.
        nextX += width

        // Update row height to accommodate the tallest glyph in this row.
        if height > rowHeight {
            rowHeight = height
        }

        return AtlasEntry(
            atlasPage: UInt8(currentPageIndex),
            x: UInt16(placedX),
            y: UInt16(placedY),
            width: UInt8(clamping: width),
            bearingX: bearingX,
            bearingY: bearingY
        )
    }

    // MARK: - Texture Upload

    /// Uploads raw pixel data to a specific region of an atlas page texture.
    ///
    /// Uses `MTLTexture.replace(region:mipmapLevel:withBytes:bytesPerRow:)` for
    /// the upload. The data must be in RGBA8 format (4 bytes per pixel).
    ///
    /// - Parameters:
    ///   - page: Zero-based page index.
    ///   - x: X origin of the region in pixels.
    ///   - y: Y origin of the region in pixels.
    ///   - width: Width of the region in pixels.
    ///   - height: Height of the region in pixels.
    ///   - data: Raw RGBA8 pixel data. Must contain at least `width * height * 4` bytes.
    func uploadRegion(
        page: Int,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        data: UnsafeRawPointer
    ) {
        guard let texture = texture(forPage: page) else { return }
        guard width > 0, height > 0 else { return }

        let region = MTLRegion(
            origin: MTLOrigin(x: x, y: y, z: 0),
            size: MTLSize(width: width, height: height, depth: 1)
        )

        let bytesPerPixel = 4 // RGBA8
        let bytesPerRow = width * bytesPerPixel

        texture.replace(
            region: region,
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: bytesPerRow
        )
    }

    // MARK: - Atlas Queries

    /// Returns the number of glyphs that can fit in a single atlas page
    /// at the current cell dimensions.
    var glyphsPerPage: Int {
        guard cellWidth > 0, cellHeight > 0 else { return 0 }
        let cols = pageSize / cellWidth
        let rows = pageSize / cellHeight
        return cols * rows
    }

    /// Returns the approximate number of remaining glyph slots on the
    /// current page, assuming standard (non-wide) cell width.
    var remainingSlotsOnCurrentPage: Int {
        guard cellWidth > 0, cellHeight > 0 else { return 0 }
        guard !pages.isEmpty else { return 0 }

        let cols = pageSize / cellWidth
        let rows = pageSize / cellHeight

        // Slots used in fully packed rows above the current row.
        let fullRowsAbove = nextY / cellHeight
        let slotsUsedInFullRows = fullRowsAbove * cols

        // Slots used in the current row.
        let slotsUsedInCurrentRow = nextX / cellWidth

        let totalSlots = cols * rows
        let usedSlots = slotsUsedInFullRows + slotsUsedInCurrentRow

        return max(0, totalSlots - usedSlots)
    }

    // MARK: - Clear & Rebuild

    /// Clears all packing state, resetting the cursor to the origin of the
    /// first page. Existing textures remain allocated but their contents are
    /// considered stale — the glyph cache must be invalidated separately.
    func clear() {
        nextX = 0
        nextY = 0
        rowHeight = cellHeight
        // Drop all pages except the first to reclaim memory.
        if pages.count > 1 {
            pages.removeSubrange(1...)
        }
    }

    /// Rebuilds the atlas for new cell dimensions (e.g., after a font change).
    ///
    /// This deallocates all existing atlas pages, creates a fresh first page,
    /// and resets the packing cursor. The caller must re-populate the atlas
    /// by rasterizing all needed glyphs again.
    ///
    /// - Parameters:
    ///   - cellWidth: New glyph cell width in pixels.
    ///   - cellHeight: New glyph cell height in pixels.
    func rebuild(cellWidth: Int, cellHeight: Int) {
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.rowHeight = cellHeight

        // Release all existing pages.
        pages.removeAll()

        // Reset packing cursor.
        nextX = 0
        nextY = 0

        // Allocate a fresh first page.
        allocatePage()
    }
}
