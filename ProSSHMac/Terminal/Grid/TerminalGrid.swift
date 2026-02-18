// TerminalGrid.swift
// ProSSHV2
//
// The terminal grid actor. Owns the cell buffer, cursor, scroll region,
// mode flags, and all operations the VT parser drives.
// Produces GridSnapshot values for the renderer.

import Foundation

// MARK: - TerminalGrid Actor

actor TerminalGrid {

    /// Reuse one-character ASCII strings to avoid per-character allocations
    /// in the common shell-output fast path.
    private static let asciiScalarStringCache: [String] = (0..<128).map {
        String(UnicodeScalar($0)!)
    }

    // MARK: - Dimensions

    private(set) var columns: Int
    private(set) var rows: Int

    // MARK: - Screen Buffers

    /// Primary screen buffer (normal shell output).
    private var primaryCells: [[TerminalCell]]

    /// Alternate screen buffer (for full-screen TUI apps: htop, vim, etc.).
    private var alternateCells: [[TerminalCell]]

    /// Which buffer is currently active.
    private(set) var usingAlternateBuffer: Bool = false

    // MARK: - Scrollback

    private var scrollback: ScrollbackBuffer

    /// Maximum scrollback lines.
    let maxScrollbackLines: Int

    // MARK: - Cursor

    var cursor: CursorState = CursorState()

    /// The last printed character (for REP — repeat preceding character).
    var lastPrintedChar: Character?

    // MARK: - Scroll Region

    /// Top margin of the scroll region (0-based, inclusive).
    var scrollTop: Int = 0

    /// Bottom margin of the scroll region (0-based, inclusive).
    var scrollBottom: Int

    // MARK: - Mode Flags

    var originMode: Bool = false              // DECOM
    var autoWrapMode: Bool = true             // DECAWM
    var insertMode: Bool = false              // IRM
    var applicationCursorKeys: Bool = false   // DECCKM
    var applicationKeypad: Bool = false       // DECKPAM/DECKPNM
    var bracketedPasteMode: Bool = false      // Mode 2004
    private(set) var synchronizedOutput: Bool = false // Mode 2026
    /// Snapshot captured at the moment synchronized output ended.
    /// Used by SessionManager to show the intermediate visible frame
    /// when sync-off and sync-on happen within a single data chunk.
    private(set) var syncExitSnapshot: GridSnapshot?
    var reverseVideo: Bool = false            // DECSCNM
    var mouseTracking: MouseTrackingMode = .none
    var mouseEncoding: MouseEncoding = .x10
    var focusReporting: Bool = false
    var lineFeedMode: Bool = false            // LNM — LF acts as CR+LF

    // MARK: - Character Set State

    var activeCharset: Int = 0   // 0 = G0, 1 = G1
    var g0Charset: Charset = .ascii
    var g1Charset: Charset = .ascii

    // MARK: - Tab Stops

    var tabStops: Set<Int>

    // MARK: - Window Title

    /// The window/tab title set by OSC 0/1/2.
    private(set) var windowTitle: String = ""

    /// The icon name set by OSC 1.
    private(set) var iconName: String = ""

    // MARK: - Bell

    /// Accumulated bell events since the last snapshot read.
    /// The renderer reads and resets this counter each frame.
    private(set) var pendingBellCount: Int = 0

    // MARK: - Working Directory (OSC 7)

    /// The current working directory reported by the shell via OSC 7.
    private(set) var workingDirectory: String = ""

    // MARK: - Hyperlink State (OSC 8)

    /// The currently active hyperlink URI (nil = no hyperlink).
    /// When set, all subsequently printed characters are part of this hyperlink.
    /// Stub: stored but not yet rendered differently or made clickable.
    private(set) var currentHyperlink: String?

    /// Increment the pending bell counter (called on BEL 0x07).
    func ringBell() {
        pendingBellCount += 1
    }

    /// Read and reset the pending bell counter.
    func consumeBellCount() -> Int {
        let count = pendingBellCount
        pendingBellCount = 0
        return count
    }

    // MARK: - Color Palette (256 custom colors, overridable by OSC 4)

    /// Custom color palette overrides. Key = palette index, value = (r, g, b).
    /// If an index is not in this dictionary, the default from ColorPalette is used.
    private var customPalette: [UInt8: (UInt8, UInt8, UInt8)] = [:]

    /// The cursor color set by OSC 12 (nil = use default).
    private(set) var cursorColor: (UInt8, UInt8, UInt8)?

    /// Current default foreground RGB (OSC 10 override).
    private var defaultForegroundColor: (UInt8, UInt8, UInt8) = (255, 255, 255)

    /// Current default background RGB (OSC 11 override).
    private var defaultBackgroundColor: (UInt8, UInt8, UInt8) = (0, 0, 0)

    // MARK: - Current Text Attributes (applied to next printed character)

    var currentAttributes: CellAttributes = []
    var currentFgColor: TerminalColor = .default
    var currentBgColor: TerminalColor = .default
    var currentUnderlineColor: TerminalColor = .default
    var currentUnderlineStyle: UnderlineStyle = .none

    // MARK: - Dirty Tracking

    /// Range of rows that have been modified since last snapshot.
    private var dirtyRowMin: Int = Int.max
    private var dirtyRowMax: Int = -1

    /// Whether any cell has changed since the last snapshot.
    private var hasDirtyCells: Bool = false

    /// Cached snapshot returned during synchronized output (mode 2026).
    private var lastSnapshot: GridSnapshot?

    // MARK: - Initialization

    init(columns: Int = TerminalDefaults.columns,
         rows: Int = TerminalDefaults.rows,
         maxScrollbackLines: Int = TerminalDefaults.maxScrollbackLines) {
        self.columns = columns
        self.rows = rows
        self.maxScrollbackLines = maxScrollbackLines
        self.scrollBottom = rows - 1
        self.tabStops = TerminalDefaults.defaultTabStops(columns: columns)
        self.scrollback = ScrollbackBuffer(maxLines: maxScrollbackLines)

        let blankRow = [TerminalCell](repeating: .blank, count: columns)
        self.primaryCells = [[TerminalCell]](repeating: blankRow, count: rows)
        self.alternateCells = [[TerminalCell]](repeating: blankRow, count: rows)
    }

    // MARK: - Active Buffer Access

    /// The currently active cell buffer.
    private var cells: [[TerminalCell]] {
        get { usingAlternateBuffer ? alternateCells : primaryCells }
        set {
            if usingAlternateBuffer {
                alternateCells = newValue
            } else {
                primaryCells = newValue
            }
        }
    }

    /// Mutate the active screen buffer in place (primary or alternate).
    private func withActiveCells(_ body: (inout [[TerminalCell]]) -> Void) {
        if usingAlternateBuffer {
            body(&alternateCells)
        } else {
            body(&primaryCells)
        }
    }

    // MARK: - A.6.1 Cell Read/Write

    /// Read the cell at the given position.
    func cellAt(row: Int, col: Int) -> TerminalCell? {
        guard row >= 0 && row < rows && col >= 0 && col < columns else { return nil }
        return cells[row][col]
    }

    /// Write a cell at the given position and mark it dirty.
    func setCellAt(row: Int, col: Int, cell: TerminalCell) {
        guard row >= 0 && row < rows && col >= 0 && col < columns else { return }
        var c = cell
        c.isDirty = true
        withActiveCells { buffer in
            buffer[row][col] = c
        }
        markDirty(row: row)
    }

    // MARK: - A.6.2 Cursor Movement

    /// Move cursor to absolute position (CUP / HVP — CSI H / CSI f).
    /// Parameters are 1-based from the remote side; convert to 0-based here.
    func moveCursorTo(row: Int, col: Int) {
        cursor.moveTo(
            row: row,
            col: col,
            gridRows: rows,
            gridCols: columns,
            originMode: originMode,
            scrollTop: scrollTop,
            scrollBottom: scrollBottom
        )
    }

    /// Move cursor up by `n` rows (CUU — CSI A). Does not scroll.
    func moveCursorUp(_ n: Int) {
        cursor.moveUp(n, scrollTop: scrollTop, originMode: originMode)
    }

    /// Move cursor down by `n` rows (CUD — CSI B). Does not scroll.
    func moveCursorDown(_ n: Int) {
        cursor.moveDown(n, scrollBottom: scrollBottom, gridRows: rows, originMode: originMode)
    }

    /// Move cursor forward (right) by `n` columns (CUF — CSI C).
    func moveCursorForward(_ n: Int) {
        cursor.moveForward(n, gridCols: columns)
    }

    /// Move cursor backward (left) by `n` columns (CUB — CSI D).
    func moveCursorBackward(_ n: Int) {
        cursor.moveBackward(n)
    }

    /// Move cursor to beginning of line `n` rows down (CNL — CSI E).
    func moveCursorNextLine(_ n: Int) {
        cursor.moveToNextLine(n, scrollBottom: scrollBottom, gridRows: rows, originMode: originMode)
    }

    /// Move cursor to beginning of line `n` rows up (CPL — CSI F).
    func moveCursorPreviousLine(_ n: Int) {
        cursor.moveToPreviousLine(n, scrollTop: scrollTop, originMode: originMode)
    }

    /// Set cursor column absolutely (CHA — CSI G).
    func setCursorColumn(_ col: Int) {
        cursor.setColumn(col, gridCols: columns)
    }

    /// Set cursor row absolutely (VPA — CSI d).
    func setCursorRow(_ row: Int) {
        cursor.setRow(
            row,
            gridRows: rows,
            originMode: originMode,
            scrollTop: scrollTop,
            scrollBottom: scrollBottom
        )
    }

    // MARK: - A.6.3 Print Character

    /// Print a character at the cursor position with current attributes.
    /// Handles auto-wrap, insert mode, and wide characters.
    func printCharacter(_ char: Character) {
        // If pending wrap, perform the actual wrap now
        if cursor.pendingWrap {
            performWrap()
        }

        let charStr: String
        if let scalar = char.unicodeScalars.first,
           char.unicodeScalars.count == 1,
           scalar.value < 128 {
            charStr = Self.asciiScalarStringCache[Int(scalar.value)]
        } else {
            charStr = String(char)
        }
        let isWide = char.isWideCharacter
        let row = cursor.row
        let col = cursor.col

        // In insert mode, shift existing chars right
        if insertMode {
            let shiftCount = isWide ? 2 : 1
            insertBlanks(count: shiftCount, atRow: row, col: col)
        }

        let attributes = isWide ? currentAttributes.union(.wideChar) : currentAttributes

        // Write the cell(s) in place.
        withActiveCells { buffer in
            buffer[row][col] = TerminalCell(
                graphemeCluster: charStr,
                fgColor: currentFgColor,
                bgColor: currentBgColor,
                underlineColor: currentUnderlineColor,
                attributes: attributes,
                underlineStyle: currentUnderlineStyle,
                width: isWide ? 2 : 1,
                isDirty: true
            )

            // For wide characters, write a continuation cell.
            if isWide && col + 1 < columns {
                buffer[row][col + 1] = TerminalCell(
                    graphemeCluster: "",
                    fgColor: currentFgColor,
                    bgColor: currentBgColor,
                    underlineColor: currentUnderlineColor,
                    attributes: currentAttributes,
                    underlineStyle: currentUnderlineStyle,
                    width: 0,  // continuation
                    isDirty: true
                )
            }
        }
        markDirty(row: row)

        lastPrintedChar = char

        // Advance cursor
        if isWide {
            if cursor.col + 1 < columns - 1 {
                cursor.col += 2
            } else {
                // Wide char at end — cursor goes to last col, pending wrap
                cursor.col = columns - 1
                if autoWrapMode {
                    cursor.pendingWrap = true
                }
            }
        } else {
            cursor.advanceAfterPrint(gridCols: columns, autoWrap: autoWrapMode)
        }
    }

    /// Repeat the last printed character `n` times (REP — CSI b).
    func repeatLastCharacter(_ n: Int) {
        guard let ch = lastPrintedChar else { return }
        for _ in 0..<max(n, 1) {
            printCharacter(ch)
        }
    }

    /// Perform the actual line wrap: CR + LF, scrolling if needed.
    private func performWrap() {
        // Mark the current line as wrapped
        if cursor.col < columns {
            let row = cursor.row
            let lastCol = columns - 1
            withActiveCells { buffer in
                var lastCell = buffer[row][lastCol]
                lastCell.attributes.insert(.wrapped)
                lastCell.isDirty = true
                buffer[row][lastCol] = lastCell
            }
        }

        cursor.col = 0
        cursor.pendingWrap = false

        if cursor.row == scrollBottom {
            scrollUp(lines: 1)
        } else if cursor.row < rows - 1 {
            cursor.row += 1
        }
    }

    // MARK: - A.6.4 Scroll Up/Down

    /// Scroll content up within the scroll region by `n` lines.
    /// Top lines go to scrollback (primary buffer only). Bottom lines become blank.
    func scrollUp(lines n: Int) {
        let count = max(n, 1)
        var buf = cells

        for _ in 0..<count {
            // Save the top line to scrollback (only for primary buffer)
            if !usingAlternateBuffer {
                let topRow = buf[scrollTop]
                let isWrapped = topRow.last.map { $0.attributes.contains(.wrapped) } ?? false
                scrollback.push(cells: topRow, isWrapped: isWrapped)
            }

            // Shift lines up within scroll region
            for row in scrollTop..<scrollBottom {
                buf[row] = buf[row + 1]
                markDirty(row: row)
            }

            // Clear the bottom line
            buf[scrollBottom] = makeBlankRow()
            markDirty(row: scrollBottom)
        }

        cells = buf
    }

    /// Scroll content down within the scroll region by `n` lines.
    /// Bottom lines are discarded. Top lines become blank.
    func scrollDown(lines n: Int) {
        let count = max(n, 1)
        var buf = cells

        for _ in 0..<count {
            // Shift lines down within scroll region
            for row in stride(from: scrollBottom, through: scrollTop + 1, by: -1) {
                buf[row] = buf[row - 1]
                markDirty(row: row)
            }

            // Clear the top line of the scroll region
            buf[scrollTop] = makeBlankRow()
            markDirty(row: scrollTop)
        }

        cells = buf
    }

    /// Index (IND / ESC D): move cursor down, scroll if at bottom of scroll region.
    func index() {
        if cursor.row == scrollBottom {
            scrollUp(lines: 1)
        } else if cursor.row < rows - 1 {
            cursor.row += 1
        }
    }

    /// Reverse Index (RI / ESC M): move cursor up, scroll down if at top of scroll region.
    func reverseIndex() {
        if cursor.row == scrollTop {
            scrollDown(lines: 1)
        } else if cursor.row > 0 {
            cursor.row -= 1
        }
    }

    /// Line feed: move cursor down, scroll if at bottom. Optionally CR (LNM mode).
    func lineFeed() {
        if lineFeedMode {
            cursor.col = 0
            cursor.pendingWrap = false
        }
        index()
    }

    /// Carriage return: move cursor to column 0.
    func carriageReturn() {
        cursor.col = 0
        cursor.pendingWrap = false
    }

    /// Backspace: move cursor left by 1, does not erase.
    func backspace() {
        if cursor.col > 0 {
            cursor.col -= 1
            cursor.pendingWrap = false
        }
    }

    // MARK: - A.6.5 Erase in Line (EL — CSI K)

    /// Erase in line.
    /// - 0: From cursor to end of line (inclusive)
    /// - 1: From beginning of line to cursor (inclusive)
    /// - 2: Entire line
    func eraseInLine(mode: Int) {
        let row = cursor.row

        var buf = cells
        let bgColor = currentBgColor

        switch mode {
        case 0: // Cursor to end
            for col in cursor.col..<columns {
                buf[row][col].erase(bgColor: bgColor)
            }
        case 1: // Beginning to cursor
            for col in 0...cursor.col {
                buf[row][col].erase(bgColor: bgColor)
            }
        case 2: // Entire line
            for col in 0..<columns {
                buf[row][col].erase(bgColor: bgColor)
            }
        default:
            break
        }

        cells = buf
        markDirty(row: row)
    }

    // MARK: - A.6.6 Erase in Display (ED — CSI J)

    /// Erase in display.
    /// - 0: From cursor to end of screen
    /// - 1: From beginning of screen to cursor
    /// - 2: Entire screen
    /// - 3: Entire screen + scrollback
    func eraseInDisplay(mode: Int) {
        var buf = cells
        let bgColor = currentBgColor

        switch mode {
        case 0: // Cursor to end
            // Rest of current line
            for col in cursor.col..<columns {
                buf[cursor.row][col].erase(bgColor: bgColor)
            }
            markDirty(row: cursor.row)
            // All lines below
            for row in (cursor.row + 1)..<rows {
                for col in 0..<columns {
                    buf[row][col].erase(bgColor: bgColor)
                }
                markDirty(row: row)
            }

        case 1: // Beginning to cursor
            // All lines above
            for row in 0..<cursor.row {
                for col in 0..<columns {
                    buf[row][col].erase(bgColor: bgColor)
                }
                markDirty(row: row)
            }
            // Start of current line to cursor
            for col in 0...cursor.col {
                buf[cursor.row][col].erase(bgColor: bgColor)
            }
            markDirty(row: cursor.row)

        case 2: // Entire screen
            for row in 0..<rows {
                for col in 0..<columns {
                    buf[row][col].erase(bgColor: bgColor)
                }
                markDirty(row: row)
            }

        case 3: // Entire screen + scrollback
            for row in 0..<rows {
                for col in 0..<columns {
                    buf[row][col].erase(bgColor: bgColor)
                }
                markDirty(row: row)
            }
            scrollback.clear()

        default:
            break
        }

        cells = buf
    }

    /// Erase characters at cursor position (ECH — CSI X).
    func eraseCharacters(_ n: Int) {
        let count = max(n, 1)
        var buf = cells
        let row = cursor.row
        let bgColor = currentBgColor

        for col in cursor.col..<min(cursor.col + count, columns) {
            buf[row][col].erase(bgColor: bgColor)
        }

        cells = buf
        markDirty(row: row)
    }

    // MARK: - A.6.7 Insert/Delete Characters

    /// Insert `n` blank characters at cursor position (ICH — CSI @).
    /// Shifts existing characters to the right. Characters pushed past the
    /// right edge are discarded.
    func insertCharacters(_ n: Int) {
        insertBlanks(count: max(n, 1), atRow: cursor.row, col: cursor.col)
    }

    /// Delete `n` characters at cursor position (DCH — CSI P).
    /// Shifts remaining characters left. Blank characters fill from the right.
    func deleteCharacters(_ n: Int) {
        let count = max(n, 1)
        var buf = cells
        let row = cursor.row

        // Shift left
        for col in cursor.col..<columns {
            let srcCol = col + count
            if srcCol < columns {
                buf[row][col] = buf[row][srcCol]
            } else {
                buf[row][col] = TerminalCell(bgColor: currentBgColor)
            }
            buf[row][col].isDirty = true
        }

        cells = buf
        markDirty(row: row)
    }

    /// Helper: insert blank characters at a specific position in a row.
    private func insertBlanks(count: Int, atRow row: Int, col: Int) {
        var buf = cells

        // Shift right
        for c in stride(from: columns - 1, through: col + count, by: -1) {
            buf[row][c] = buf[row][c - count]
            buf[row][c].isDirty = true
        }

        // Fill blanks
        for c in col..<min(col + count, columns) {
            buf[row][c] = TerminalCell(bgColor: currentBgColor)
        }

        cells = buf
        markDirty(row: row)
    }

    // MARK: - A.6.8 Insert/Delete Lines

    /// Insert `n` blank lines at cursor row (IL — CSI L).
    /// Lines within the scroll region shift down; bottom lines are discarded.
    func insertLines(_ n: Int) {
        let count = max(n, 1)
        var buf = cells

        // Only operates within scroll region, starting from cursor row
        let top = max(cursor.row, scrollTop)

        for _ in 0..<count {
            // Shift lines down
            for row in stride(from: scrollBottom, through: top + 1, by: -1) {
                buf[row] = buf[row - 1]
                markDirty(row: row)
            }
            buf[top] = makeBlankRow()
            markDirty(row: top)
        }

        cells = buf
        cursor.col = 0
        cursor.pendingWrap = false
    }

    /// Delete `n` lines at cursor row (DL — CSI M).
    /// Lines within the scroll region shift up; blank lines fill from the bottom.
    func deleteLines(_ n: Int) {
        let count = max(n, 1)
        var buf = cells

        let top = max(cursor.row, scrollTop)

        for _ in 0..<count {
            // Shift lines up
            for row in top..<scrollBottom {
                buf[row] = buf[row + 1]
                markDirty(row: row)
            }
            buf[scrollBottom] = makeBlankRow()
            markDirty(row: scrollBottom)
        }

        cells = buf
        cursor.col = 0
        cursor.pendingWrap = false
    }

    // MARK: - A.6.9 Scroll Region (DECSTBM — CSI r)

    /// Set the scroll region (top and bottom margins).
    /// Parameters are 1-based; converted to 0-based internally.
    /// Resets cursor to home position (respecting origin mode).
    func setScrollRegion(top: Int, bottom: Int) {
        let t = max(top, 0)
        let b = min(bottom, rows - 1)

        guard t < b else { return }

        scrollTop = t
        scrollBottom = b

        // DECSTBM resets cursor to home
        if originMode {
            cursor.moveTo(row: scrollTop, col: 0, gridRows: rows, gridCols: columns)
        } else {
            cursor.moveTo(row: 0, col: 0, gridRows: rows, gridCols: columns)
        }
    }

    /// Reset scroll region to full screen.
    func resetScrollRegion() {
        scrollTop = 0
        scrollBottom = rows - 1
    }

    // MARK: - A.6.10 Alternate Screen Buffer (Mode 1049)

    /// Switch to the alternate screen buffer.
    /// Saves cursor, clears the alternate buffer.
    func enableAlternateBuffer() {
        guard !usingAlternateBuffer else { return }

        // Save cursor for primary screen
        cursor.savedPrimary = cursor.save(
            attributes: currentAttributes,
            fgColor: currentFgColor,
            bgColor: currentBgColor,
            underlineColor: currentUnderlineColor,
            underlineStyle: currentUnderlineStyle,
            originMode: originMode,
            autoWrapMode: autoWrapMode,
            activeCharset: activeCharset,
            g0Charset: g0Charset,
            g1Charset: g1Charset
        )

        usingAlternateBuffer = true

        // Clear the alternate buffer
        let blankRow = makeBlankRow()
        alternateCells = [[TerminalCell]](repeating: blankRow, count: rows)

        // Reset cursor position
        cursor.moveTo(row: 0, col: 0, gridRows: rows, gridCols: columns)

        markAllDirty()
    }

    /// Switch back to the primary screen buffer.
    /// Restores cursor from saved state.
    func disableAlternateBuffer() {
        guard usingAlternateBuffer else { return }

        usingAlternateBuffer = false

        // The TUI app that enabled synchronized output is leaving the
        // alternate buffer — disable sync mode so snapshot() returns
        // live primary-buffer content instead of a stale cached frame.
        synchronizedOutput = false
        lastSnapshot = nil

        // Restore cursor from saved primary state
        if let saved = cursor.savedPrimary {
            cursor.restore(from: saved, gridRows: rows, gridCols: columns)
            currentAttributes = saved.attributes
            currentFgColor = saved.fgColor
            currentBgColor = saved.bgColor
            currentUnderlineColor = saved.underlineColor
            currentUnderlineStyle = saved.underlineStyle
            originMode = saved.originMode
            autoWrapMode = saved.autoWrapMode
            activeCharset = saved.activeCharset
            g0Charset = saved.g0Charset
            g1Charset = saved.g1Charset
        }

        markAllDirty()
    }

    // MARK: - A.6.11 Cursor Save/Restore (DECSC/DECRC)

    /// Save cursor and attributes (DECSC — ESC 7).
    func saveCursor() {
        let saved = cursor.save(
            attributes: currentAttributes,
            fgColor: currentFgColor,
            bgColor: currentBgColor,
            underlineColor: currentUnderlineColor,
            underlineStyle: currentUnderlineStyle,
            originMode: originMode,
            autoWrapMode: autoWrapMode,
            activeCharset: activeCharset,
            g0Charset: g0Charset,
            g1Charset: g1Charset
        )
        if usingAlternateBuffer {
            cursor.savedAlternate = saved
        } else {
            cursor.savedPrimary = saved
        }
    }

    /// Restore cursor and attributes (DECRC — ESC 8).
    func restoreCursor() {
        let saved = usingAlternateBuffer ? cursor.savedAlternate : cursor.savedPrimary
        guard let s = saved else { return }

        cursor.restore(from: s, gridRows: rows, gridCols: columns)
        currentAttributes = s.attributes
        currentFgColor = s.fgColor
        currentBgColor = s.bgColor
        currentUnderlineColor = s.underlineColor
        currentUnderlineStyle = s.underlineStyle
        originMode = s.originMode
        autoWrapMode = s.autoWrapMode
        activeCharset = s.activeCharset
        g0Charset = s.g0Charset
        g1Charset = s.g1Charset
    }

    // MARK: - A.6.12 Tab Stop Management

    /// Advance cursor to the next tab stop (HT / CHT).
    func tabForward(count: Int = 1) {
        for _ in 0..<max(count, 1) {
            cursor.advanceToTab(tabStops: tabStops, gridCols: columns)
        }
    }

    /// Move cursor to the previous tab stop (CBT — CSI Z).
    func tabBackward(count: Int = 1) {
        for _ in 0..<max(count, 1) {
            cursor.reverseToTab(tabStops: tabStops)
        }
    }

    /// Set a tab stop at the current cursor column (HTS — ESC H).
    func setTabStop() {
        tabStops.insert(cursor.col)
    }

    /// Clear tab stops (TBC — CSI g).
    /// - 0: Clear tab stop at current column
    /// - 3: Clear all tab stops
    func clearTabStop(mode: Int) {
        switch mode {
        case 0:
            tabStops.remove(cursor.col)
        case 3:
            tabStops.removeAll()
        default:
            break
        }
    }

    /// Reset tab stops to default (every 8 columns).
    func resetTabStops() {
        tabStops = TerminalDefaults.defaultTabStops(columns: columns)
    }

    // MARK: - A.6.13 Dirty Tracking

    /// Mark a specific row as dirty.
    private func markDirty(row: Int) {
        hasDirtyCells = true
        dirtyRowMin = min(dirtyRowMin, row)
        dirtyRowMax = max(dirtyRowMax, row)
    }

    /// Mark all rows as dirty (used after buffer switch, full reset, resize).
    private func markAllDirty() {
        hasDirtyCells = true
        dirtyRowMin = 0
        dirtyRowMax = rows - 1
    }

    /// Clear the dirty state after producing a snapshot.
    private func clearDirtyState() {
        hasDirtyCells = false
        dirtyRowMin = Int.max
        dirtyRowMax = -1
    }

    // MARK: - A.6.14 Grid Snapshot Generation

    /// Produce an immutable snapshot of the current grid state for the renderer.
    /// Clears dirty tracking after snapshot is taken.
    ///
    /// When synchronized output (mode 2026) is active, returns the previously
    /// cached snapshot so the renderer keeps displaying the last complete frame
    /// while the remote app is mid-update.
    func snapshot() -> GridSnapshot {
        // During synchronized output, return the cached snapshot to avoid
        // rendering partial frames. If no cached snapshot exists yet, fall
        // through and produce one normally.
        if synchronizedOutput, let cached = lastSnapshot {
            return cached
        }

        let activeCells = cells
        let hasDirtyRange = hasDirtyCells && dirtyRowMin <= dirtyRowMax
        let dirtyMin = dirtyRowMin
        let dirtyMax = dirtyRowMax

        var cellInstances = [CellInstance]()
        cellInstances.reserveCapacity(rows * columns)

        for row in 0..<rows {
            let rowIsDirty = hasDirtyRange && row >= dirtyMin && row <= dirtyMax
            for col in 0..<columns {
                let cell = activeCells[row][col]
                let isCursor = (row == cursor.row && col == cursor.col && cursor.visible)

                var flags: UInt8 = 0
                if rowIsDirty { flags |= CellInstance.flagDirty }
                if isCursor { flags |= CellInstance.flagCursor }

                // Extract the first Unicode scalar as the codepoint for glyph lookup.
                // The renderer's glyphLookup closure reads this to resolve the atlas entry.
                let codepoint: UInt32
                if let scalar = cell.graphemeCluster.unicodeScalars.first {
                    codepoint = scalar.value
                } else {
                    codepoint = 0
                }

                // boldIsBright: bold + standard color (0-7) → bright variant (8-15)
                let fgPacked: UInt32
                if TerminalDefaults.boldIsBright,
                   cell.attributes.contains(.bold),
                   case .indexed(let idx) = cell.fgColor, idx < 8 {
                    fgPacked = TerminalColor.indexed(idx + 8).packedRGBA()
                } else {
                    fgPacked = cell.fgColor.packedRGBA()
                }

                // Pack underline color (0 = use fg)
                let ulColorPacked = cell.underlineColor.packedRGBA()

                cellInstances.append(CellInstance(
                    row: UInt16(row),
                    col: UInt16(col),
                    glyphIndex: codepoint,
                    fgColor: fgPacked,
                    bgColor: cell.bgColor.packedRGBA(),
                    underlineColor: ulColorPacked,
                    attributes: cell.attributes.rawValue,
                    flags: flags,
                    underlineStyle: cell.underlineStyle.rawValue
                ))
            }
        }

        // Compute dirty range
        var dirtyRange: Range<Int>?
        if hasDirtyRange {
            let startIdx = dirtyMin * columns
            let endIdx = (dirtyMax + 1) * columns
            dirtyRange = startIdx..<endIdx
        }

        let snap = GridSnapshot(
            cells: cellInstances,
            dirtyRange: dirtyRange,
            cursorRow: cursor.row,
            cursorCol: cursor.col,
            cursorVisible: cursor.visible,
            cursorStyle: cursor.style,
            columns: columns,
            rows: rows
        )

        clearDirtyState()

        lastSnapshot = snap
        return snap
    }

    /// Produce a snapshot with scrollback lines blended in.
    /// `scrollOffset` is the number of lines scrolled back (0 = live view).
    /// When scrollOffset > 0, the top N rows show scrollback content and
    /// the remaining rows show the top portion of the visible grid.
    func snapshot(scrollOffset: Int) -> GridSnapshot {
        guard scrollOffset > 0, scrollback.count > 0 else {
            return snapshot()
        }

        let activeCells = cells

        // Clamp offset to available scrollback
        let clampedOffset = min(scrollOffset, scrollback.count)

        var cellInstances = [CellInstance]()
        cellInstances.reserveCapacity(rows * columns)

        for displayRow in 0..<rows {
            // Which logical row does this display row map to?
            // displayRow 0 is the topmost visible row.
            // scrollbackIndex = scrollback.count - clampedOffset + displayRow
            let scrollbackIndex = scrollback.count - clampedOffset + displayRow

            if scrollbackIndex < scrollback.count {
                // This row comes from scrollback
                let scrollLine = scrollback[scrollbackIndex]
                for col in 0..<columns {
                    let codepoint: UInt32
                    let fgPacked: UInt32
                    let bgPacked: UInt32
                    let attrs: UInt16

                    let ulColorPacked: UInt32
                    let ulStyle: UInt8

                    if col < scrollLine.cells.count {
                        let cell = scrollLine.cells[col]
                        if let scalar = cell.graphemeCluster.unicodeScalars.first {
                            codepoint = scalar.value
                        } else {
                            codepoint = 0
                        }
                        if TerminalDefaults.boldIsBright,
                           cell.attributes.contains(.bold),
                           case .indexed(let idx) = cell.fgColor, idx < 8 {
                            fgPacked = TerminalColor.indexed(idx + 8).packedRGBA()
                        } else {
                            fgPacked = cell.fgColor.packedRGBA()
                        }
                        bgPacked = cell.bgColor.packedRGBA()
                        attrs = cell.attributes.rawValue
                        ulColorPacked = cell.underlineColor.packedRGBA()
                        ulStyle = cell.underlineStyle.rawValue
                    } else {
                        codepoint = 0
                        fgPacked = TerminalColor.default.packedRGBA()
                        bgPacked = TerminalColor.default.packedRGBA()
                        attrs = 0
                        ulColorPacked = 0
                        ulStyle = 0
                    }

                    cellInstances.append(CellInstance(
                        row: UInt16(displayRow),
                        col: UInt16(col),
                        glyphIndex: codepoint,
                        fgColor: fgPacked,
                        bgColor: bgPacked,
                        underlineColor: ulColorPacked,
                        attributes: attrs,
                        flags: CellInstance.flagDirty,
                        underlineStyle: ulStyle
                    ))
                }
            } else {
                // This row comes from the live grid
                let gridRow = scrollbackIndex - scrollback.count
                for col in 0..<columns {
                    let cell = activeCells[gridRow][col]
                    let isCursor = (gridRow == cursor.row && col == cursor.col && cursor.visible && clampedOffset == 0)

                    var flags: UInt8 = CellInstance.flagDirty
                    if isCursor { flags |= CellInstance.flagCursor }

                    let codepoint: UInt32
                    if let scalar = cell.graphemeCluster.unicodeScalars.first {
                        codepoint = scalar.value
                    } else {
                        codepoint = 0
                    }

                    let fgPacked: UInt32
                    if TerminalDefaults.boldIsBright,
                       cell.attributes.contains(.bold),
                       case .indexed(let idx) = cell.fgColor, idx < 8 {
                        fgPacked = TerminalColor.indexed(idx + 8).packedRGBA()
                    } else {
                        fgPacked = cell.fgColor.packedRGBA()
                    }

                    cellInstances.append(CellInstance(
                        row: UInt16(displayRow),
                        col: UInt16(col),
                        glyphIndex: codepoint,
                        fgColor: fgPacked,
                        bgColor: cell.bgColor.packedRGBA(),
                        underlineColor: cell.underlineColor.packedRGBA(),
                        attributes: cell.attributes.rawValue,
                        flags: flags,
                        underlineStyle: cell.underlineStyle.rawValue
                    ))
                }
            }
        }

        return GridSnapshot(
            cells: cellInstances,
            dirtyRange: 0..<cellInstances.count,
            cursorRow: cursor.row,
            cursorCol: cursor.col,
            cursorVisible: cursor.visible && clampedOffset == 0,
            cursorStyle: cursor.style,
            columns: columns,
            rows: rows
        )
    }

    /// The number of scrollback lines available.
    var scrollbackCount: Int {
        scrollback.count
    }

    // MARK: - A.6.15 Text Extraction

    /// Extract visible rows as an array of strings (trailing whitespace trimmed).
    /// Used by the text-based fallback view, password detection, and search.
    func visibleText() -> [String] {
        let activeCells = cells

        var lines = [String]()
        lines.reserveCapacity(rows)
        for row in 0..<rows {
            var line = ""
            for col in 0..<columns {
                let cell = activeCells[row][col]
                if cell.width == 0 { continue } // skip wide-char continuation
                if cell.graphemeCluster.isEmpty {
                    line.append(" ")
                } else {
                    line.append(cell.graphemeCluster)
                }
            }
            // Trim trailing spaces with a single pass.
            if let lastNonSpace = line.lastIndex(where: { $0 != " " }) {
                lines.append(String(line[...lastNonSpace]))
            } else {
                lines.append("")
            }
        }
        return lines
    }

    // MARK: - Full Reset (RIS — ESC c)

    /// Perform a full terminal reset.
    func fullReset() {
        // Reset buffers
        let blankRow = makeBlankRow()
        primaryCells = [[TerminalCell]](repeating: blankRow, count: rows)
        alternateCells = [[TerminalCell]](repeating: blankRow, count: rows)
        usingAlternateBuffer = false

        // Reset cursor
        cursor = CursorState()

        // Reset scroll region
        scrollTop = 0
        scrollBottom = rows - 1

        // Reset modes
        originMode = false
        autoWrapMode = true
        insertMode = false
        applicationCursorKeys = false
        applicationKeypad = false
        bracketedPasteMode = false
        synchronizedOutput = false
        lastSnapshot = nil
        reverseVideo = false
        mouseTracking = .none
        mouseEncoding = .x10
        focusReporting = false
        lineFeedMode = false

        // Reset charsets
        activeCharset = 0
        g0Charset = .ascii
        g1Charset = .ascii

        // Reset tab stops
        resetTabStops()

        // Reset attributes
        currentAttributes = []
        currentFgColor = .default
        currentBgColor = .default
        currentUnderlineColor = .default
        currentUnderlineStyle = .none
        currentHyperlink = nil

        // Reset scrollback
        scrollback.clear()

        lastPrintedChar = nil

        markAllDirty()
    }

    /// Soft terminal reset (DECSTR — CSI ! p).
    func softReset() {
        cursor.visible = true
        cursor.style = .block
        cursor.pendingWrap = false

        originMode = false
        autoWrapMode = true
        insertMode = false
        applicationCursorKeys = false
        applicationKeypad = false
        reverseVideo = false

        scrollTop = 0
        scrollBottom = rows - 1

        activeCharset = 0
        g0Charset = .ascii
        g1Charset = .ascii

        currentAttributes = []
        currentFgColor = .default
        currentBgColor = .default
        currentUnderlineColor = .default
        currentUnderlineStyle = .none

        resetTabStops()

        cursor.savedPrimary = nil
        cursor.savedAlternate = nil
    }

    /// Fill screen with 'E' for alignment test (DECALN — ESC # 8).
    func screenAlignmentPattern() {
        var buf = cells
        for row in 0..<rows {
            for col in 0..<columns {
                buf[row][col] = TerminalCell(
                    graphemeCluster: "E",
                    fgColor: .default,
                    bgColor: .default,
                    attributes: [],
                    width: 1,
                    isDirty: true
                )
            }
        }
        cells = buf
        cursor.moveTo(row: 0, col: 0, gridRows: rows, gridCols: columns)
        markAllDirty()
    }

    // MARK: - Resize

    /// Resize the terminal grid with proper content reflow.
    /// Primary buffer uses GridReflow for correct unwrap/rewrap behavior.
    /// Alternate buffer uses simple resize (TUI apps redraw on SIGWINCH anyway).
    func resize(newColumns: Int, newRows: Int) {
        guard newColumns > 0 && newRows > 0 else { return }
        guard newColumns != columns || newRows != rows else { return }

        let oldColumns = columns

        // Reflow primary buffer (the one with scrollback that needs proper reflow)
        let reflowResult = GridReflow.reflow(
            screenRows: primaryCells,
            scrollback: scrollback,
            cursorRow: cursor.row,
            cursorCol: cursor.col,
            oldColumns: oldColumns,
            newColumns: newColumns,
            newRows: newRows
        )

        primaryCells = reflowResult.screenRows

        // Rebuild scrollback from reflow result
        scrollback = ScrollbackBuffer(maxLines: maxScrollbackLines)
        for line in reflowResult.scrollbackLines {
            scrollback.push(line)
        }

        // Simple resize for alternate buffer (TUI apps redraw on SIGWINCH)
        alternateCells = simpleResizeBuffer(
            alternateCells, newRows: newRows, newColumns: newColumns
        )

        // Update cursor from reflow result (only if on primary buffer)
        if !usingAlternateBuffer {
            cursor.row = reflowResult.cursorRow
            cursor.col = reflowResult.cursorCol
        } else {
            cursor.row = min(cursor.row, newRows - 1)
            cursor.col = min(cursor.col, newColumns - 1)
        }
        cursor.pendingWrap = false

        columns = newColumns
        rows = newRows

        // Adjust scroll region
        scrollTop = 0
        scrollBottom = newRows - 1

        // Reset tab stops for new width
        tabStops = TerminalDefaults.defaultTabStops(columns: newColumns)

        markAllDirty()
    }

    /// Simple buffer resize without reflow (for alternate screen buffer).
    private func simpleResizeBuffer(
        _ buffer: [[TerminalCell]],
        newRows: Int, newColumns: Int
    ) -> [[TerminalCell]] {
        var newBuf = [[TerminalCell]]()
        newBuf.reserveCapacity(newRows)

        for row in 0..<newRows {
            if row < buffer.count {
                var existingRow = buffer[row]
                if newColumns > existingRow.count {
                    existingRow.append(contentsOf:
                        [TerminalCell](repeating: .blank, count: newColumns - existingRow.count)
                    )
                } else if newColumns < existingRow.count {
                    existingRow = Array(existingRow.prefix(newColumns))
                }
                newBuf.append(existingRow)
            } else {
                newBuf.append([TerminalCell](repeating: .blank, count: newColumns))
            }
        }

        return newBuf
    }

    // MARK: - Scrollback Access

    /// The current scrollback buffer (read-only).
    var scrollbackBuffer: ScrollbackBuffer {
        scrollback
    }

    // MARK: - Mode Setters (for cross-actor access from VTParser)

    /// Set a character set designation for G0 or G1.
    func setCharset(g: Int, charset: Charset) {
        if g == 0 { g0Charset = charset }
        else { g1Charset = charset }
    }

    /// Set the active character set (0 = G0, 1 = G1).
    func setActiveCharset(_ n: Int) {
        activeCharset = n
    }

    /// Set application keypad mode.
    func setApplicationKeypad(_ enabled: Bool) {
        applicationKeypad = enabled
    }

    /// Set application cursor keys mode (DECCKM).
    func setApplicationCursorKeys(_ enabled: Bool) {
        applicationCursorKeys = enabled
    }

    /// Set insert mode (IRM).
    func setInsertMode(_ enabled: Bool) {
        insertMode = enabled
    }

    /// Set reverse video mode (DECSCNM).
    func setReverseVideo(_ enabled: Bool) {
        reverseVideo = enabled
    }

    /// Set origin mode (DECOM).
    func setOriginMode(_ enabled: Bool) {
        originMode = enabled
    }

    /// Set auto-wrap mode (DECAWM).
    func setAutoWrapMode(_ enabled: Bool) {
        autoWrapMode = enabled
    }

    /// Set bracketed paste mode.
    func setBracketedPasteMode(_ enabled: Bool) {
        bracketedPasteMode = enabled
    }

    /// Set synchronized output mode (mode 2026).
    /// When enabled, snapshot() returns the cached last-complete frame.
    /// When toggling from disabled -> enabled, captures the just-finished
    /// unsynchronized frame so SessionManager can publish it even if the
    /// parser chunk ends in sync mode.
    ///
    /// The sync-exit snapshot is critical for correctness: when a single
    /// data chunk contains ESC[?2026l (end sync) followed by drawing
    /// followed by ESC[?2026h (start sync), the SessionManager only
    /// checks sync mode AFTER the entire chunk. Without the sync-exit
    /// snapshot, the intermediate visible frame (between l and h) would
    /// never be displayed, causing stale/ghost content to persist.
    func setSynchronizedOutput(_ enabled: Bool) {
        let wasEnabled = synchronizedOutput
        guard wasEnabled != enabled else { return }

        // Transition false -> true (sync starts): if there are unsnapped
        // changes from the just-finished unsynced window, capture/publish
        // that frame now before freezing output.
        if enabled {
            if hasDirtyCells {
                let snap = snapshot()
                syncExitSnapshot = snap
            }
            synchronizedOutput = true
            return
        }

        // Transition true -> false (sync ends): resume live snapshots.
        synchronizedOutput = false
    }

    /// Consume and return the sync-exit snapshot, clearing it.
    /// Called by SessionManager after each parser feed.
    func consumeSyncExitSnapshot() -> GridSnapshot? {
        guard let snap = syncExitSnapshot else { return nil }
        syncExitSnapshot = nil
        return snap
    }

    /// Set cursor visibility (DECTCEM).
    func setCursorVisible(_ visible: Bool) {
        cursor.visible = visible
    }

    /// Set cursor blink.
    func setCursorBlink(_ enabled: Bool) {
        cursor.blinkEnabled = enabled
    }

    /// Set cursor display style (DECSCUSR).
    func setCursorStyle(_ style: CursorStyle) {
        cursor.style = style
    }

    /// Set mouse tracking mode.
    func setMouseTracking(_ mode: MouseTrackingMode) {
        mouseTracking = mode
    }

    /// Set mouse encoding.
    func setMouseEncoding(_ encoding: MouseEncoding) {
        mouseEncoding = encoding
    }

    /// Set focus reporting.
    func setFocusReporting(_ enabled: Bool) {
        focusReporting = enabled
    }

    /// Set line feed mode (LNM).
    func setLineFeedMode(_ enabled: Bool) {
        lineFeedMode = enabled
    }

    /// Set SGR attributes directly.
    func setCurrentAttributes(_ attrs: CellAttributes) {
        currentAttributes = attrs
    }

    /// Set SGR foreground color.
    func setCurrentFgColor(_ color: TerminalColor) {
        currentFgColor = color
    }

    /// Set SGR background color.
    func setCurrentBgColor(_ color: TerminalColor) {
        currentBgColor = color
    }

    /// Set SGR underline color (SGR 58/59).
    func setCurrentUnderlineColor(_ color: TerminalColor) {
        currentUnderlineColor = color
    }

    /// Set SGR underline style (from SGR 4 subparameters).
    func setCurrentUnderlineStyle(_ style: UnderlineStyle) {
        currentUnderlineStyle = style
    }

    /// Get a snapshot of the charset/mode state needed by the parser for character mapping.
    func charsetState() -> (activeCharset: Int, g0: Charset, g1: Charset) {
        (activeCharset, g0Charset, g1Charset)
    }

    /// Get the current SGR state (attributes, fg, bg, underline color, underline style).
    func sgrState() -> (attributes: CellAttributes, fg: TerminalColor, bg: TerminalColor, underlineColor: TerminalColor, underlineStyle: UnderlineStyle) {
        (currentAttributes, currentFgColor, currentBgColor, currentUnderlineColor, currentUnderlineStyle)
    }

    /// Get the current cursor position.
    func cursorPosition() -> (row: Int, col: Int) {
        (cursor.row, cursor.col)
    }

    // MARK: - Window Title (OSC 0/1/2)

    /// Set the window title (OSC 0/2).
    func setWindowTitle(_ title: String) {
        windowTitle = title
    }

    /// Set the icon name (OSC 1).
    func setIconName(_ name: String) {
        iconName = name
    }

    /// Set the current working directory (OSC 7).
    func setWorkingDirectory(_ path: String) {
        workingDirectory = path
    }

    /// Set the current hyperlink URI (OSC 8).
    /// Pass nil to end the current hyperlink.
    func setCurrentHyperlink(_ uri: String?) {
        currentHyperlink = uri
    }

    // MARK: - Color Palette (OSC 4/10/11/12)

    /// Set a custom palette color at a given index (OSC 4).
    func setPaletteColor(index: UInt8, r: UInt8, g: UInt8, b: UInt8) {
        customPalette[index] = (r, g, b)
        markAllDirty()
    }

    /// Get the current RGB for a palette index (custom or default).
    func paletteColor(index: UInt8) -> (UInt8, UInt8, UInt8) {
        if let custom = customPalette[index] {
            return custom
        }
        let rgb = ColorPalette.rgb(forIndex: index)
        return (rgb.r, rgb.g, rgb.b)
    }

    /// Reset a palette color to its default (OSC 104).
    func resetPaletteColor(index: UInt8) {
        customPalette.removeValue(forKey: index)
        markAllDirty()
    }

    /// Set the cursor color (OSC 12).
    func setCursorColor(r: UInt8, g: UInt8, b: UInt8) {
        cursorColor = (r, g, b)
    }

    /// Set the default foreground color (OSC 10).
    func setDefaultForegroundRGB(r: UInt8, g: UInt8, b: UInt8) {
        defaultForegroundColor = (r, g, b)
        markAllDirty()
    }

    /// Set the default background color (OSC 11).
    func setDefaultBackgroundRGB(r: UInt8, g: UInt8, b: UInt8) {
        defaultBackgroundColor = (r, g, b)
        markAllDirty()
    }

    /// Reset the cursor color to default (OSC 112).
    func resetCursorColor() {
        cursorColor = nil
    }

    /// Get the default foreground color RGB.
    func defaultForegroundRGB() -> (UInt8, UInt8, UInt8) {
        defaultForegroundColor
    }

    /// Get the default background color RGB.
    func defaultBackgroundRGB() -> (UInt8, UInt8, UInt8) {
        defaultBackgroundColor
    }

    // MARK: - Helpers

    /// Create a blank row with the current background color.
    private func makeBlankRow() -> [TerminalCell] {
        [TerminalCell](repeating: TerminalCell(bgColor: currentBgColor), count: columns)
    }
}

// MARK: - Character Width Detection

nonisolated extension Character {
    /// Returns true if this character is a wide (double-width) character,
    /// such as CJK ideographs, fullwidth forms, or emoji with default emoji presentation.
    /// Delegates to `CharacterWidth.isWide(_:)` for the actual classification.
    var isWideCharacter: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        return CharacterWidth.isWide(scalar)
    }
}
