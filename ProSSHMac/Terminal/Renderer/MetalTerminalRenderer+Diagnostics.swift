// Extracted from MetalTerminalRenderer.swift

extension MetalTerminalRenderer {

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
