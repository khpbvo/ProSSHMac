// CSIHandler.swift
// ProSSHV2
//
// Dispatches all CSI (Control Sequence Introducer) sequences.
// Extracted from VTParser for modularity and testability.
//
// Each CSI sequence is: ESC [ <params> <intermediates> <final byte>
// The final byte (0x40–0x7E) determines the action.
// Parameters are semicolon-separated integers; missing = 0.
// Private marker '?' prefixes DEC private modes.

import Foundation

// MARK: - CSIHandler

/// Namespace for CSI sequence dispatch.
/// All methods are static and take the grid + parsed parameters.
nonisolated enum CSIHandler {

    // MARK: - Main Dispatch

    /// Dispatch a CSI sequence by its final byte.
    /// Called from VTParser when a CSI sequence is complete.
    static func dispatch(
        byte: UInt8,
        params: [[Int]],
        privateMarker: UInt8,
        intermediates: [UInt8],
        grid: TerminalGrid,
        responseHandler: (([UInt8]) async -> Void)?,
        inputModeState: InputModeState? = nil
    ) async {
        let isPrivate = privateMarker == ByteRange.questionMark

        // DECRQM: CSI ? Ps $ p — Request Mode (DEC private).
        // Must be checked before dispatchPrivateMode because that path
        // doesn't receive intermediates and would silently ignore this.
        // Claude Code uses DECRQM to verify mode 2026 (synchronized output)
        // support; without a response it may fall back to un-synced output.
        if isPrivate && !intermediates.isEmpty {
            if intermediates.first == 0x24 && byte == 0x70 {
                await handleDECRQM(
                    params: params,
                    grid: grid,
                    responseHandler: responseHandler
                )
            }
            // Any other CSI ? ... <intermediate> <final> — silently ignore.
            return
        }

        // DEC private modes: CSI ? Ps h / CSI ? Ps l
        if isPrivate {
            await dispatchPrivateMode(
                byte: byte,
                params: params,
                grid: grid,
                inputModeState: inputModeState
            )
            return
        }

        // Secondary DA: CSI > c — respond with terminal identification.
        // Applications like Claude Code, vim, and tmux query this to detect
        // terminal capabilities.
        if privateMarker == ByteRange.greaterThan && byte == 0x63 {
            let p0 = param(params, 0, default: 0, raw: true)
            if p0 == 0 {
                await responseHandler?(DeviceAttributes.secondaryResponse)
            }
            return
        }

        // Other private markers (>, <, =) from Kitty keyboard protocol,
        // xterm key modifier options, etc. — silently ignore.
        // Without this guard, sequences like CSI > 1 u (Kitty push mode)
        // would be misinterpreted as CSI u (restore cursor), and
        // CSI > 4;1 m (xterm modifier) would corrupt SGR attributes.
        if privateMarker != 0 {
            return
        }

        // CSI with intermediate bytes (e.g., CSI ! p = DECSTR, CSI Ps SP q = DECSCUSR)
        if !intermediates.isEmpty {
            await dispatchWithIntermediate(
                byte: byte,
                params: params,
                intermediates: intermediates,
                grid: grid,
                inputModeState: inputModeState
            )
            return
        }

        // Standard CSI sequences (SGR gets full params for subparameter support)
        if byte == 0x6D { // CSI m — SGR
            await SGRHandler.handle(params: params, grid: grid)
        } else {
            await dispatchStandard(
                byte: byte, params: params, grid: grid,
                responseHandler: responseHandler
            )
        }
    }

    // MARK: - A.10.1–A.10.20 Standard CSI Sequences

    private static func dispatchStandard(
        byte: UInt8,
        params: [[Int]],
        grid: TerminalGrid,
        responseHandler: (([UInt8]) async -> Void)?
    ) async {
        let p0 = param(params, 0, default: 1)
        let p0raw = param(params, 0, default: 0, raw: true)

        switch byte {

        // A.10.1 — Cursor Movement
        case 0x41: // CSI A — CUU (Cursor Up)
            await grid.moveCursorUp(p0)
        case 0x42: // CSI B — CUD (Cursor Down)
            await grid.moveCursorDown(p0)
        case 0x43: // CSI C — CUF (Cursor Forward)
            await grid.moveCursorForward(p0)
        case 0x44: // CSI D — CUB (Cursor Backward)
            await grid.moveCursorBackward(p0)

        // A.10.2 — Cursor Position (1-based → 0-based)
        case 0x48: // CSI H — CUP (Cursor Position)
            let row = param(params, 0, default: 1) - 1
            let col = param(params, 1, default: 1) - 1
            await grid.moveCursorTo(row: row, col: col)
        case 0x66: // CSI f — HVP (same as CUP)
            let row = param(params, 0, default: 1) - 1
            let col = param(params, 1, default: 1) - 1
            await grid.moveCursorTo(row: row, col: col)

        // A.10.3 — ED (Erase in Display)
        case 0x4A: // CSI J
            await grid.eraseInDisplay(mode: p0raw)

        // A.10.4 — EL (Erase in Line)
        case 0x4B: // CSI K
            await grid.eraseInLine(mode: p0raw)

        // A.10.5 — SGR (Select Graphic Rendition)
        // Handled in dispatch() with full subparameter support

        // A.10.6 — DECSTBM (Set Scroll Region)
        case 0x72: // CSI r
            let gridRows = await grid.rows
            let top = param(params, 0, default: 1) - 1
            let bottom = param(params, 1, default: gridRows) - 1
            await grid.setScrollRegion(top: top, bottom: bottom)

        // A.10.7 — IL/DL (Insert/Delete Lines)
        case 0x4C: // CSI L — IL
            await grid.insertLines(p0)
        case 0x4D: // CSI M — DL
            await grid.deleteLines(p0)

        // A.10.8 — ICH/DCH (Insert/Delete Characters)
        case 0x40: // CSI @ — ICH
            await grid.insertCharacters(p0)
        case 0x50: // CSI P — DCH
            await grid.deleteCharacters(p0)

        // A.10.9 — ECH (Erase Characters)
        case 0x58: // CSI X
            await grid.eraseCharacters(p0)

        // A.10.10 — SU/SD (Scroll Up/Down)
        case 0x53: // CSI S — SU
            await grid.scrollUp(lines: p0)
        case 0x54: // CSI T — SD
            await grid.scrollDown(lines: p0)

        // A.10.11 — VPA/CHA (Absolute Positioning)
        case 0x64: // CSI d — VPA (1-based → 0-based)
            await grid.setCursorRow(p0 - 1)
        case 0x47: // CSI G — CHA (1-based → 0-based)
            await grid.setCursorColumn(p0 - 1)

        // A.10.12 — CNL/CPL (Cursor Next/Previous Line)
        case 0x45: // CSI E — CNL
            await grid.moveCursorNextLine(p0)
        case 0x46: // CSI F — CPL
            await grid.moveCursorPreviousLine(p0)

        // A.10.13 — REP (Repeat Preceding Character)
        case 0x62: // CSI b
            await grid.repeatLastCharacter(p0)

        // A.10.14 — TBC (Tab Clear)
        case 0x67: // CSI g
            await grid.clearTabStop(mode: p0raw)

        // A.10.15 — CHT/CBT (Tab Forward/Backward)
        case 0x49: // CSI I — CHT
            await grid.tabForward(count: p0)
        case 0x5A: // CSI Z — CBT
            await grid.tabBackward(count: p0)

        // A.10.16 — DSR (Device Status Report)
        case 0x6E: // CSI n
            await handleDSR(params: params, grid: grid, responseHandler: responseHandler)

        // A.10.17 — DA (Device Attributes)
        case 0x63: // CSI c
            await handleDA(params: params, responseHandler: responseHandler)

        // A.10.18 — SM/RM (Set/Reset Mode)
        case 0x68: // CSI h — SM
            await handleSetMode(params: params, grid: grid)
        case 0x6C: // CSI l — RM
            await handleResetMode(params: params, grid: grid)

        // A.10.20 — SCP/RCP (Save/Restore Cursor Position)
        case 0x73: // CSI s — SCP
            await grid.saveCursor()
        case 0x75: // CSI u — RCP
            await grid.restoreCursor()

        default:
            break // Unknown CSI — ignore
        }
    }

    // MARK: - A.10.19 DEC Private Modes (DECSET/DECRST)

    /// Dispatch CSI ? sequences (DECSET/DECRST).
    private static func dispatchPrivateMode(
        byte: UInt8,
        params: [[Int]],
        grid: TerminalGrid,
        inputModeState: InputModeState?
    ) async {
        switch byte {
        case 0x68: // CSI ? h — DECSET
            if params.count == 1 {
                await setPrivateMode(
                    params[0].first ?? 0,
                    enabled: true,
                    grid: grid,
                    inputModeState: inputModeState
                )
                return
            }
            for group in params {
                await setPrivateMode(
                    group.first ?? 0,
                    enabled: true,
                    grid: grid,
                    inputModeState: inputModeState
                )
            }
        case 0x6C: // CSI ? l — DECRST
            if params.count == 1 {
                await setPrivateMode(
                    params[0].first ?? 0,
                    enabled: false,
                    grid: grid,
                    inputModeState: inputModeState
                )
                return
            }
            for group in params {
                await setPrivateMode(
                    group.first ?? 0,
                    enabled: false,
                    grid: grid,
                    inputModeState: inputModeState
                )
            }
        default:
            break
        }
    }

    /// Set or reset a single DEC private mode.
    private static func setPrivateMode(
        _ mode: Int,
        enabled: Bool,
        grid: TerminalGrid,
        inputModeState: InputModeState?
    ) async {
        switch mode {
        case DECPrivateMode.DECCKM:
            await grid.setApplicationCursorKeys(enabled)
            await inputModeState?.setApplicationCursorKeys(enabled)
        case DECPrivateMode.DECSCNM:
            await grid.setReverseVideo(enabled)
        case DECPrivateMode.DECOM:
            await grid.setOriginMode(enabled)
            if enabled { await grid.moveCursorTo(row: 0, col: 0) }
        case DECPrivateMode.DECAWM:
            await grid.setAutoWrapMode(enabled)
        case DECPrivateMode.cursorBlink:
            await grid.setCursorBlink(enabled)
        case DECPrivateMode.DECTCEM:
            await grid.setCursorVisible(enabled)
        case DECPrivateMode.altScreenOld, DECPrivateMode.altScreenAlt:
            if enabled { await grid.enableAlternateBuffer() }
            else { await grid.disableAlternateBuffer() }
        case DECPrivateMode.altScreen:
            if enabled { await grid.enableAlternateBuffer() }
            else { await grid.disableAlternateBuffer() }
        case DECPrivateMode.mouseX10:
            await grid.setMouseTracking(enabled ? .x10 : .none)
            await inputModeState?.setMouseTracking(enabled ? .x10 : .none)
        case DECPrivateMode.mouseButton:
            await grid.setMouseTracking(enabled ? .buttonEvent : .none)
            await inputModeState?.setMouseTracking(enabled ? .buttonEvent : .none)
        case DECPrivateMode.mouseAny:
            await grid.setMouseTracking(enabled ? .anyEvent : .none)
            await inputModeState?.setMouseTracking(enabled ? .anyEvent : .none)
        case DECPrivateMode.focusEvent:
            await grid.setFocusReporting(enabled)
        case DECPrivateMode.mouseUTF8:
            if enabled {
                await grid.setMouseEncoding(.utf8)
                await inputModeState?.setMouseEncoding(.utf8)
            } else {
                await grid.setMouseEncoding(.x10)
                await inputModeState?.setMouseEncoding(.x10)
            }
        case DECPrivateMode.mouseSGR:
            await grid.setMouseEncoding(enabled ? .sgr : .x10)
            await inputModeState?.setMouseEncoding(enabled ? .sgr : .x10)
        case DECPrivateMode.bracketedPaste:
            await grid.setBracketedPasteMode(enabled)
            await inputModeState?.setBracketedPasteMode(enabled)
        case DECPrivateMode.synchronizedOutput:
            await grid.setSynchronizedOutput(enabled)
        default:
            break
        }
    }

    // MARK: - A.10.21 DECSTR (Soft Reset)

    /// Dispatch CSI with intermediate bytes.
    private static func dispatchWithIntermediate(
        byte: UInt8,
        params: [[Int]],
        intermediates: [UInt8],
        grid: TerminalGrid,
        inputModeState: InputModeState?
    ) async {
        guard let intermediate = intermediates.first else { return }

        if intermediate == 0x21 && byte == 0x70 { // CSI ! p — DECSTR
            await grid.softReset()
            await inputModeState?.applySoftReset()
        } else if intermediate == 0x20 && byte == 0x71 { // CSI Ps SP q — DECSCUSR (cursor style)
            let p = param(params, 0, default: 0, raw: true)
            // 0/1 = blinking block, 2 = steady block,
            // 3 = blinking underline, 4 = steady underline,
            // 5 = blinking bar, 6 = steady bar
            switch p {
            case 0, 1, 2:
                await grid.setCursorStyle(.block)
                await grid.setCursorBlink(p != 2)
            case 3, 4:
                await grid.setCursorStyle(.underline)
                await grid.setCursorBlink(p == 3)
            case 5, 6:
                await grid.setCursorStyle(.bar)
                await grid.setCursorBlink(p == 5)
            default:
                break
            }
        }
    }

    // MARK: - DECRQM (Request Mode — DEC Private)

    /// Handle CSI ? Ps $ p — respond with CSI ? Ps ; Pm $ y
    /// where Pm indicates: 0=not recognized, 1=set, 2=reset.
    private static func handleDECRQM(
        params: [[Int]],
        grid: TerminalGrid,
        responseHandler: (([UInt8]) async -> Void)?
    ) async {
        let mode = param(params, 0, default: 0, raw: true)
        let pm: Int

        switch mode {
        case DECPrivateMode.DECCKM:
            pm = await grid.applicationCursorKeys ? 1 : 2
        case DECPrivateMode.DECSCNM:
            pm = await grid.reverseVideo ? 1 : 2
        case DECPrivateMode.DECOM:
            pm = await grid.originMode ? 1 : 2
        case DECPrivateMode.DECAWM:
            pm = await grid.autoWrapMode ? 1 : 2
        case DECPrivateMode.DECTCEM:
            pm = await grid.cursor.visible ? 1 : 2
        case DECPrivateMode.altScreenOld,
             DECPrivateMode.altScreenAlt,
             DECPrivateMode.altScreen:
            pm = await grid.usingAlternateBuffer ? 1 : 2
        case DECPrivateMode.bracketedPaste:
            pm = await grid.bracketedPasteMode ? 1 : 2
        case DECPrivateMode.synchronizedOutput:
            pm = await grid.synchronizedOutput ? 1 : 2
        case DECPrivateMode.focusEvent:
            pm = await grid.focusReporting ? 1 : 2
        case DECPrivateMode.mouseX10,
             DECPrivateMode.mouseButton,
             DECPrivateMode.mouseAny:
            let tracking = await grid.mouseTracking
            pm = tracking != .none ? 1 : 2
        case DECPrivateMode.mouseSGR:
            let encoding = await grid.mouseEncoding
            pm = encoding == .sgr ? 1 : 2
        default:
            pm = 0 // Not recognized
        }

        // Response: CSI ? mode ; pm $ y
        let response = "\u{1B}[?\(mode);\(pm)$y"
        await responseHandler?(Array(response.utf8))
    }

    // MARK: - A.10.16 DSR Handler

    private static func handleDSR(
        params: [[Int]],
        grid: TerminalGrid,
        responseHandler: (([UInt8]) async -> Void)?
    ) async {
        let code = param(params, 0, default: 0, raw: true)
        if code == 6 {
            // Cursor Position Report: CSI row ; col R (1-based)
            let pos = await grid.cursorPosition()
            let response = "\u{1B}[\(pos.row + 1);\(pos.col + 1)R"
            await responseHandler?(Array(response.utf8))
        }
    }

    // MARK: - A.10.17 DA Handler

    private static func handleDA(
        params: [[Int]],
        responseHandler: (([UInt8]) async -> Void)?
    ) async {
        let p0 = param(params, 0, default: 0, raw: true)
        if p0 == 0 {
            await responseHandler?(DeviceAttributes.primaryResponse)
        }
    }

    // MARK: - A.10.18 SM/RM (ANSI Modes)

    private static func handleSetMode(params: [[Int]], grid: TerminalGrid) async {
        for group in params {
            switch group.first ?? 0 {
            case ANSIMode.IRM:
                await grid.setInsertMode(true)
            case ANSIMode.LNM:
                await grid.setLineFeedMode(true)
            default:
                break
            }
        }
    }

    private static func handleResetMode(params: [[Int]], grid: TerminalGrid) async {
        for group in params {
            switch group.first ?? 0 {
            case ANSIMode.IRM:
                await grid.setInsertMode(false)
            case ANSIMode.LNM:
                await grid.setLineFeedMode(false)
            default:
                break
            }
        }
    }

    // MARK: - Parameter Helpers

    /// Get parameter at index with a default value.
    /// Extracts the first element of each subparameter group (inline flatParams).
    /// When raw is false (default), 0 is treated as "not specified" and replaced by defaultValue.
    /// When raw is true, 0 is kept as 0.
    private static func param(
        _ params: [[Int]], _ index: Int, default defaultValue: Int, raw: Bool = false
    ) -> Int {
        guard index < params.count else { return defaultValue }
        let v = params[index].first ?? 0
        if raw { return v }
        return v == 0 ? defaultValue : v
    }
}
