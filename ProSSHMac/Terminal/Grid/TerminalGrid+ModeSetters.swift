// Extracted from TerminalGrid.swift

import Foundation

extension TerminalGrid {

    // MARK: - Mode Setters (for cross-actor access from VTParser)

    /// Set a character set designation for G0 or G1.
    nonisolated func setCharset(g: Int, charset: Charset) {
        if g == 0 { g0Charset = charset }
        else { g1Charset = charset }
    }

    /// Set the active character set (0 = G0, 1 = G1).
    nonisolated func setActiveCharset(_ n: Int) {
        activeCharset = n
    }

    /// Set application keypad mode.
    nonisolated func setApplicationKeypad(_ enabled: Bool) {
        applicationKeypad = enabled
    }

    /// Set application cursor keys mode (DECCKM).
    nonisolated func setApplicationCursorKeys(_ enabled: Bool) {
        applicationCursorKeys = enabled
    }

    /// Set insert mode (IRM).
    nonisolated func setInsertMode(_ enabled: Bool) {
        insertMode = enabled
    }

    /// Set reverse video mode (DECSCNM).
    nonisolated func setReverseVideo(_ enabled: Bool) {
        reverseVideo = enabled
    }

    /// Set origin mode (DECOM).
    nonisolated func setOriginMode(_ enabled: Bool) {
        originMode = enabled
    }

    /// Set auto-wrap mode (DECAWM).
    nonisolated func setAutoWrapMode(_ enabled: Bool) {
        autoWrapMode = enabled
    }

    /// Set bracketed paste mode.
    nonisolated func setBracketedPasteMode(_ enabled: Bool) {
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
    nonisolated func setSynchronizedOutput(_ enabled: Bool) {
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
    nonisolated func consumeSyncExitSnapshot() -> GridSnapshot? {
        guard let snap = syncExitSnapshot else { return nil }
        syncExitSnapshot = nil
        return snap
    }

    /// Set cursor visibility (DECTCEM).
    nonisolated func setCursorVisible(_ visible: Bool) {
        cursor.visible = visible
    }

    /// Set cursor blink.
    nonisolated func setCursorBlink(_ enabled: Bool) {
        cursor.blinkEnabled = enabled
    }

    /// Set cursor display style (DECSCUSR).
    nonisolated func setCursorStyle(_ style: CursorStyle) {
        cursor.style = style
    }

    /// Set mouse tracking mode.
    nonisolated func setMouseTracking(_ mode: MouseTrackingMode) {
        mouseTracking = mode
    }

    /// Set mouse encoding.
    nonisolated func setMouseEncoding(_ encoding: MouseEncoding) {
        mouseEncoding = encoding
    }

    /// Set focus reporting.
    nonisolated func setFocusReporting(_ enabled: Bool) {
        focusReporting = enabled
    }

    /// Set line feed mode (LNM).
    nonisolated func setLineFeedMode(_ enabled: Bool) {
        lineFeedMode = enabled
    }

    /// Apply one DEC private mode in a single actor hop.
    /// This batches the hot parser path and avoids per-field await storms.
    nonisolated func applyDECPrivateMode(_ mode: Int, enabled: Bool) {
        switch mode {
        case DECPrivateMode.DECCKM:
            applicationCursorKeys = enabled
        case DECPrivateMode.DECSCNM:
            reverseVideo = enabled
        case DECPrivateMode.DECOM:
            originMode = enabled
            if enabled {
                moveCursorTo(row: 0, col: 0)
            }
        case DECPrivateMode.DECAWM:
            autoWrapMode = enabled
        case DECPrivateMode.cursorBlink:
            cursor.blinkEnabled = enabled
        case DECPrivateMode.DECTCEM:
            cursor.visible = enabled
        case DECPrivateMode.altScreenOld, DECPrivateMode.altScreenAlt, DECPrivateMode.altScreen:
            if enabled {
                enableAlternateBuffer()
            } else {
                disableAlternateBuffer()
            }
        case DECPrivateMode.mouseX10:
            mouseTracking = enabled ? .x10 : .none
        case DECPrivateMode.mouseButton:
            mouseTracking = enabled ? .buttonEvent : .none
        case DECPrivateMode.mouseAny:
            mouseTracking = enabled ? .anyEvent : .none
        case DECPrivateMode.focusEvent:
            focusReporting = enabled
        case DECPrivateMode.mouseUTF8:
            mouseEncoding = enabled ? .utf8 : .x10
        case DECPrivateMode.mouseSGR:
            mouseEncoding = enabled ? .sgr : .x10
        case DECPrivateMode.bracketedPaste:
            bracketedPasteMode = enabled
        case DECPrivateMode.synchronizedOutput:
            setSynchronizedOutput(enabled)
        default:
            break
        }
    }

    /// Set SGR attributes directly.
    nonisolated func setCurrentAttributes(_ attrs: CellAttributes) {
        currentAttributes = attrs
    }

    /// Set SGR foreground color.
    nonisolated func setCurrentFgColor(_ color: TerminalColor) {
        currentFgColor = color
        currentFgPacked = color.packedRGBA()
    }

    /// Set SGR background color.
    nonisolated func setCurrentBgColor(_ color: TerminalColor) {
        currentBgColor = color
        currentBgPacked = color.packedRGBA()
    }

    /// Set SGR underline color (SGR 58/59).
    nonisolated func setCurrentUnderlineColor(_ color: TerminalColor) {
        currentUnderlineColor = color
        currentUnderlinePacked = color.packedRGBA()
    }

    /// Set SGR underline style (from SGR 4 subparameters).
    nonisolated func setCurrentUnderlineStyle(_ style: UnderlineStyle) {
        currentUnderlineStyle = style
    }

    /// Get a snapshot of the charset/mode state needed by the parser for character mapping.
    nonisolated func charsetState() -> (activeCharset: Int, g0: Charset, g1: Charset) {
        (activeCharset, g0Charset, g1Charset)
    }

    /// Get the current SGR state (attributes, fg, bg, underline color, underline style).
    nonisolated func sgrState() -> (attributes: CellAttributes, fg: TerminalColor, bg: TerminalColor, underlineColor: TerminalColor, underlineStyle: UnderlineStyle) {
        (currentAttributes, currentFgColor, currentBgColor, currentUnderlineColor, currentUnderlineStyle)
    }

    /// Apply a complete SGR state in a single actor hop (replaces 5 separate set* calls).
    nonisolated func applySGRState(attributes: CellAttributes, fg: TerminalColor, bg: TerminalColor, underlineColor: TerminalColor, underlineStyle: UnderlineStyle) {
        currentAttributes = attributes
        currentFgColor = fg
        currentBgColor = bg
        currentUnderlineColor = underlineColor
        currentUnderlineStyle = underlineStyle
        invalidatePackedColors()
    }

    /// Get all input-mode flags in a single actor hop (replaces 5 separate property reads).
    nonisolated func inputModeSnapshot() -> InputModeSnapshot {
        InputModeSnapshot(
            applicationCursorKeys: applicationCursorKeys,
            applicationKeypad: applicationKeypad,
            bracketedPasteMode: bracketedPasteMode,
            mouseTracking: mouseTracking,
            mouseEncoding: mouseEncoding
        )
    }

    /// Get the current cursor position.
    nonisolated func cursorPosition() -> (row: Int, col: Int) {
        (cursor.row, cursor.col)
    }

}
