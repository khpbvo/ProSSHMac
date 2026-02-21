// CellBuffer.swift
// ProSSHV2
//
// CPU-to-GPU cell buffer bridge for the Metal terminal renderer.
// Converts GridSnapshot data into MTLBuffers for instanced draw calls.
// Uses double-buffering so the GPU can read buffer A while the CPU
// writes to buffer B, avoiding pipeline stalls. Supports partial
// updates (dirty ranges) and wide character handling.

import Metal
#if DEBUG
import os.signpost
#endif

// MARK: - Constants

/// Minimum buffer capacity in cells. Prevents degenerate allocations
/// for very small terminal windows.
private let kMinBufferCapacity: Int = 256

/// Stride of a single CellInstance in bytes, aligned for Metal.
private let kCellStride: Int = MemoryLayout<CellInstance>.stride

/// Sentinel glyph index meaning "no glyph".
/// This must match the shader-side `GLYPH_INDEX_NONE` constant.
private let kNoGlyphIndex: UInt32 = 0xFFFF_FFFF
#if DEBUG
private let kCellBufferSignpostLog = OSLog(subsystem: "com.prossh", category: "TerminalPerf")
#endif

// MARK: - CellBuffer

/// Manages a pair of double-buffered MTLBuffers for streaming cell instance
/// data from the CPU (GridSnapshot) to the GPU (instanced draw calls).
///
/// Ownership: the renderer owns a single `CellBuffer` instance. This class
/// is **not** thread-safe — all access must occur on the renderer's thread
/// (typically `@MainActor` or the Metal render loop).
///
/// Usage:
/// 1. Call `update(from:glyphLookup:)` each frame with the latest grid snapshot.
/// 2. Call `swapBuffers()` after the update to promote the write buffer to read.
/// 3. Pass `readBuffer` to the render encoder as the instance buffer.
final class CellBuffer {

    // MARK: - Properties

    /// The Metal device used to allocate buffers.
    private let device: MTLDevice

    /// Double-buffered MTLBuffers. Index `writeIndex` is the CPU-writable
    /// buffer; `readIndex` is the buffer the GPU reads from.
    private var buffers: [MTLBuffer?] = [nil, nil]

    /// Index into `buffers` that the CPU is currently writing to.
    private var writeIndex: Int = 0

    /// Current capacity of each buffer, measured in cells.
    private var capacity: Int = 0

    /// Number of cells in the most recent snapshot (rows * columns).
    private(set) var cellCount: Int = 0

    /// Grid dimensions from the most recent update.
    private(set) var columns: Int = 0
    private(set) var rows: Int = 0

    // MARK: - Computed Properties

    /// Index into `buffers` that the GPU should read from.
    private var readIndex: Int {
        1 - writeIndex
    }

    /// The MTLBuffer the GPU should bind for instanced rendering.
    /// Returns `nil` if no data has been uploaded yet.
    var readBuffer: MTLBuffer? {
        buffers[readIndex]
    }

    /// The MTLBuffer the CPU is currently writing to.
    private var writeBuffer: MTLBuffer? {
        buffers[writeIndex]
    }

    // MARK: - Initialization

    /// Creates a new cell buffer backed by the specified Metal device.
    ///
    /// No MTLBuffers are allocated until the first call to `update(from:glyphLookup:)`.
    ///
    /// - Parameter device: The Metal device for buffer allocation.
    init(device: MTLDevice) {
        self.device = device
    }

    // MARK: - Buffer Management

    /// Swap read and write buffers. Call this after `update(from:glyphLookup:)`
    /// completes so the GPU picks up the freshly written data on the next frame.
    func swapBuffers() {
        writeIndex = 1 - writeIndex
    }

    /// Ensures both buffers are allocated with at least `requiredCapacity` cells.
    /// If the current capacity is sufficient, this is a no-op. When reallocation
    /// occurs, existing buffer contents are **not** preserved (the caller is
    /// expected to perform a full update after a resize).
    ///
    /// - Parameter requiredCapacity: Minimum number of cells each buffer must hold.
    /// - Returns: `true` if buffers were reallocated (caller must do a full update).
    @discardableResult
    private func ensureCapacity(_ requiredCapacity: Int) -> Bool {
        let aligned = max(requiredCapacity, kMinBufferCapacity)

        guard aligned > capacity else { return false }

        // Round up to next power-of-two to reduce reallocation frequency.
        let newCapacity = nextPowerOfTwo(aligned)
        let byteCount = newCapacity * kCellStride

        for i in 0..<2 {
            let buffer = device.makeBuffer(
                length: byteCount,
                options: .storageModeShared
            )
            buffer?.label = "CellBuffer[\(i)]"
            buffers[i] = buffer
        }

        capacity = newCapacity
        return true
    }

    // MARK: - Update

    /// Updates the current write buffer with cell data from a grid snapshot.
    ///
    /// For each cell in the snapshot, the `glyphLookup` closure is called to
    /// resolve the glyph atlas index. Wide characters (wideChar attribute set)
    /// are handled specially: the primary cell receives the resolved glyph index,
    /// and the continuation cell (width=0) receives glyphIndex=0 with matching
    /// foreground/background colors.
    ///
    /// If the snapshot provides a `dirtyRange`, only that contiguous range of
    /// cells is re-uploaded to the buffer, avoiding a full copy. If the grid
    /// dimensions changed since the last update, a full copy is always performed
    /// regardless of the dirty range.
    ///
    /// - Parameters:
    ///   - snapshot: The immutable grid snapshot to upload.
    ///   - glyphLookup: Closure that maps a `CellInstance` to its glyph atlas
    ///     index (UInt32). The closure receives the cell as populated by the
    ///     grid (with row, col, colors, attributes) and should return the
    ///     atlas glyph index for rendering.
    func update(from snapshot: GridSnapshot, glyphLookup: (CellInstance) -> UInt32) {
        #if DEBUG
        let signpostID = OSSignpostID(log: kCellBufferSignpostLog)
        os_signpost(.begin, log: kCellBufferSignpostLog, name: "CellBufferUpdate", signpostID: signpostID)
        defer {
            os_signpost(.end, log: kCellBufferSignpostLog, name: "CellBufferUpdate", signpostID: signpostID)
        }
        #endif

        let newCellCount = snapshot.rows * snapshot.columns
        guard newCellCount > 0 else {
            cellCount = 0
            columns = snapshot.columns
            rows = snapshot.rows
            return
        }

        // Detect dimension change — forces full update and reallocation.
        let dimensionsChanged = snapshot.columns != columns || snapshot.rows != rows
        let didReallocate = ensureCapacity(newCellCount)
        let forceFullUpdate = dimensionsChanged || didReallocate

        cellCount = newCellCount
        columns = snapshot.columns
        rows = snapshot.rows

        guard let buffer = writeBuffer else { return }
        let dst = buffer.contents().bindMemory(to: CellInstance.self, capacity: capacity)

        let updateRange: Range<Int>
        if forceFullUpdate {
            updateRange = 0..<newCellCount
        } else if let dirtyRange = snapshot.dirtyRange {
            let lower = max(0, min(dirtyRange.lowerBound, newCellCount))
            let upper = max(lower, min(dirtyRange.upperBound, newCellCount))
            updateRange = lower..<upper
        } else {
            // Nil dirty range means "unknown/whole snapshot changed".
            updateRange = 0..<newCellCount
        }

        guard !updateRange.isEmpty else { return }

        // Partial updates with double buffering require a current baseline.
        // The write buffer can be one frame behind the read buffer; if we apply
        // only a dirty range directly, stale cells from older frames remain and
        // can cause old/new frame oscillation when buffers swap.
        // Copy the current read buffer into the write buffer first so unchanged
        // cells stay in sync, then apply the dirty delta on top.
        var effectiveRange = updateRange
        if !forceFullUpdate, updateRange.count < newCellCount {
            if let read = readBuffer, read !== buffer {
                let src = read.contents().bindMemory(to: CellInstance.self, capacity: capacity)
                dst.update(from: src, count: newCellCount)
            } else {
                // No valid baseline; fall back to a full upload.
                effectiveRange = 0..<newCellCount
            }
        }

        // Copy dirty slice first, then resolve glyphs in a second pass.
        copyCells(from: snapshot, range: effectiveRange, to: dst)
        for i in effectiveRange {
            var cell = dst[i]
            let isContinuation = isContinuationCell(cell, at: i, in: snapshot)

            if isContinuation {
                // Continuation cell: no glyph, preserve colors from primary.
                cell.glyphIndex = kNoGlyphIndex
                if i > 0 {
                    let primary = snapshot.cells[i - 1]
                    cell.fgColor = primary.fgColor
                    cell.bgColor = primary.bgColor
                }
            } else if cell.glyphIndex == 0 {
                // Empty/NUL cells should not sample atlas texel (0,0).
                cell.glyphIndex = kNoGlyphIndex
            } else {
                cell.glyphIndex = glyphLookup(cell)
            }

            dst[i] = cell
        }
    }

    private func copyCells(
        from snapshot: GridSnapshot,
        range: Range<Int>,
        to dst: UnsafeMutablePointer<CellInstance>
    ) {
        snapshot.cells.withUnsafeBufferPointer { src in
            guard let srcBase = src.baseAddress else { return }
            dst.advanced(by: range.lowerBound).update(
                from: srcBase.advanced(by: range.lowerBound),
                count: range.count
            )
        }
    }

    // MARK: - Wide Character Helpers

    /// Determines whether the cell at the given index is a continuation cell
    /// for a wide character (i.e., the second column of a double-width glyph).
    ///
    /// A continuation cell is identified by:
    /// - Not having the wideChar attribute itself (it belongs to the primary cell).
    /// - Being preceded by a cell with the wideChar attribute set.
    /// - Having a glyphIndex of 0 (set by the grid snapshot).
    ///
    /// - Parameters:
    ///   - cell: The cell instance to check.
    ///   - index: The index of the cell in the snapshot's cell array.
    ///   - snapshot: The grid snapshot containing all cells.
    /// - Returns: `true` if this cell is a wide-character continuation cell.
    private func isContinuationCell(
        _ cell: CellInstance,
        at index: Int,
        in snapshot: GridSnapshot
    ) -> Bool {
        // A continuation cell must have a predecessor and be on the same row.
        guard index > 0 else { return false }

        let previous = snapshot.cells[index - 1]
        let previousIsWide = (previous.attributes & CellAttributes.wideChar.rawValue) != 0

        // The continuation cell is on the same row as its primary, in the next column.
        guard previousIsWide, previous.row == cell.row else { return false }

        // The current cell itself should not have the wideChar attribute.
        let currentIsWide = (cell.attributes & CellAttributes.wideChar.rawValue) != 0
        return !currentIsWide
    }

    // MARK: - Resize

    /// Resizes the cell buffer for new grid dimensions.
    ///
    /// This forces reallocation of both MTLBuffers if the new cell count
    /// exceeds the current capacity. The next call to `update(from:glyphLookup:)`
    /// will perform a full (non-partial) upload because the dimensions changed.
    ///
    /// - Parameters:
    ///   - newColumns: New grid column count.
    ///   - newRows: New grid row count.
    func resize(columns newColumns: Int, rows newRows: Int) {
        let newCellCount = newColumns * newRows
        guard newCellCount > 0 else { return }
        ensureCapacity(newCellCount)
        // Do not update `columns` / `rows` here — let `update(from:glyphLookup:)`
        // detect the dimension change and perform a full update.
    }

    // MARK: - Diagnostics

    /// Returns the byte size of a single buffer (or 0 if not allocated).
    var bufferByteSize: Int {
        capacity * kCellStride
    }

    /// Returns `true` if both buffers are allocated and ready for use.
    var isReady: Bool {
        buffers[0] != nil && buffers[1] != nil
    }

    // MARK: - Private Helpers

    /// Returns the next power of two greater than or equal to `n`.
    /// For n <= 1, returns 1.
    private func nextPowerOfTwo(_ n: Int) -> Int {
        guard n > 1 else { return 1 }
        // Use bit manipulation for efficiency.
        var v = n - 1
        v |= v >> 1
        v |= v >> 2
        v |= v >> 4
        v |= v >> 8
        v |= v >> 16
        v |= v >> 32
        return v + 1
    }
}
