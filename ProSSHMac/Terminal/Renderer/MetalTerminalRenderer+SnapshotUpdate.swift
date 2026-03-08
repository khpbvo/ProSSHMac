// Extracted from MetalTerminalRenderer.swift
import Metal
import MetalKit

extension MetalTerminalRenderer {

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
        // Reset scroll state on alt-screen buffer transitions (e.g. entering/exiting vim)
        if let prev = latestSnapshot, prev.usingAlternateBuffer != snapshot.usingAlternateBuffer {
            smoothScrollEngine.handleResize()
        }
        latestSnapshot = snapshot
        let renderSnapshot: GridSnapshot
        if selectionRenderer.needsProjection() {
            renderSnapshot = selectionRenderer.applySelection(to: snapshot)
            forceFullUploadForPendingSnapshot = true
        } else {
            renderSnapshot = snapshot
        }
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
        requestFrame()
        updateCursorBlinkLoop()
    }

    func applyPendingSnapshotIfNeeded() {
        guard let snapshot = pendingRenderSnapshot else { return }
        pendingRenderSnapshot = nil
        let shouldForceFullUpload = forceFullUploadForPendingSnapshot
        forceFullUploadForPendingSnapshot = false
        let uploadSnapshot: GridSnapshot
        if shouldForceFullUpload {
            uploadSnapshot = GridSnapshot(
                cells: snapshot.cells,
                dirtyRange: nil,
                cursorRow: snapshot.cursorRow,
                cursorCol: snapshot.cursorCol,
                cursorVisible: snapshot.cursorVisible,
                cursorStyle: snapshot.cursorStyle,
                columns: snapshot.columns,
                rows: snapshot.rows,
                usingAlternateBuffer: snapshot.usingAlternateBuffer,
                graphemeOverrides: snapshot.graphemeOverrides
            )
        } else {
            uploadSnapshot = snapshot
        }

        cellBuffer.update(from: uploadSnapshot, resolver: self)
        cellBuffer.swapBuffers()
    }
}
