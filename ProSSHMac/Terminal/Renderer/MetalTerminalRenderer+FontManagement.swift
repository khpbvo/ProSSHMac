// Extracted from MetalTerminalRenderer.swift
import Metal
import CoreText

extension MetalTerminalRenderer {

    // MARK: - Async Initialization

    /// Fetches actual cell dimensions from the FontManager actor and
    /// pre-populates the glyph cache with ASCII characters.
    func initializeFontMetricsAndPrepopulate() async {
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

    // MARK: - Font Change

    /// Called when the font configuration changes.
    /// Rebuilds the glyph atlas, clears the cache, and re-populates ASCII glyphs.
    func handleFontChange() {
        fontChangeTask?.cancel()
        fontChangeTask = Task { [weak self] in
            guard let self else { return }
            await self.reloadFontStateFromManager()
        }
    }

    /// Updates the base terminal font size and refreshes renderer metrics.
    func setFontSize(_ size: CGFloat) {
        let clamped = min(28.0, max(9.0, size))
        guard abs(clamped - rasterFontSize) > 0.01 else { return }

        fontChangeTask?.cancel()
        fontChangeTask = Task { [weak self] in
            guard let self else { return }
            await self.fontManager.setFont(size: clamped)
            guard !Task.isCancelled else { return }
            await self.reloadFontStateFromManager()
        }
    }

    /// Updates the terminal font family and refreshes renderer metrics.
    func setFontName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetName = trimmed.isEmpty ? FontManager.platformDefaultFontFamily : trimmed
        guard targetName != rasterFontName else { return }

        fontChangeTask?.cancel()
        fontChangeTask = Task { [weak self] in
            guard let self else { return }
            await self.fontManager.setFont(name: targetName)
            guard !Task.isCancelled else { return }
            await self.reloadFontStateFromManager()
        }
    }

    func reloadFontStateFromManager() async {
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
        // Re-apply the latest snapshot so the cell buffer gets updated glyph
        // atlas indices that match the rebuilt atlas. Without this, the old
        // (now-invalid) glyph positions remain in the cell buffer and the
        // terminal appears blank until the next external snapshot arrives.
        if let latestSnapshot {
            updateSnapshot(latestSnapshot)
        }
        // Reset effect history so post-processing doesn't blend stale geometry.
        self.hasCapturedPreviousFrame = false
        self.previousUniformTime = 0
        self.uniformBuffer.resetTime()
        self.isDirty = true
    }

    // MARK: - Pixel Alignment Helpers

    /// Re-apply pixel alignment to cellWidth/cellHeight using the current
    /// screenScale. Called when the scale factor changes (e.g., window moved
    /// to a different display).
    func reapplyPixelAlignment() {
        let scale = max(screenScale, 1.0)
        cellWidth = round(rawCellWidth * scale) / scale
        cellHeight = ceil(rawCellHeight * scale) / scale
    }

    /// Recalculate grid dimensions using the current viewport and cell sizes.
    /// Useful after cell dimensions change asynchronously (e.g., font load).
    func recalculateGridDimensions() {
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
}
