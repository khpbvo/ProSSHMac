// ESCHandler.swift (VTParserActions)
// ProSSHV2
//
// Dispatches all ESC (Escape) sequences.
// Extracted from VTParser for modularity and testability.
//
// ESC sequences are: ESC <optional intermediate> <final byte>
// The final byte (0x30–0x7E) determines the action.
// Intermediates (0x20–0x2F) modify the interpretation.
//
// Supports:
// - A.15.1 DECSC/DECRC (ESC 7/8 — save/restore cursor)
// - A.15.2 IND/RI/NEL (ESC D/M/E — index, reverse index, next line)
// - A.15.3 RIS (ESC c — full reset)
// - A.15.4 HTS (ESC H — set tab stop)
// - A.15.5 DECKPAM/DECKPNM (ESC =/> — keypad modes)
// - A.15.6 Charset designation (ESC ( 0, ESC ( B, etc.)
// - A.15.7 DECALN (ESC # 8 — fill with E)

import Foundation

// MARK: - ESCHandler

/// Namespace for ESC sequence dispatch.
/// All methods are static and take the grid reference as a parameter.
nonisolated enum ESCHandler {

    // MARK: - Main Dispatch

    /// Dispatch an ESC sequence by its final byte and optional intermediates.
    /// Called from VTParser when an escDispatch action fires.
    ///
    /// - Parameters:
    ///   - byte: The final byte of the ESC sequence
    ///   - intermediates: Collected intermediate bytes (0x20–0x2F)
    ///   - grid: The terminal grid to drive
    static func dispatch(
        byte: UInt8,
        intermediates: [UInt8],
        grid: TerminalGrid,
        inputModeState: InputModeState? = nil
    ) async {
        if let intermediate = intermediates.first {
            dispatchWithIntermediate(
                intermediate: intermediate, final: byte, grid: grid
            )
        } else {
            await dispatchFinal(byte, grid: grid, inputModeState: inputModeState)
        }
    }

    // MARK: - ESC Without Intermediates

    /// Handle ESC sequences with no intermediate bytes.
    private static func dispatchFinal(
        _ byte: UInt8,
        grid: TerminalGrid,
        inputModeState: InputModeState?
    ) async {
        switch byte {

        // A.15.1 — DECSC / DECRC (Save / Restore Cursor)
        case 0x37: // ESC 7 — DECSC
            grid.saveCursor()

        case 0x38: // ESC 8 — DECRC
            grid.restoreCursor()

        // A.15.2 — IND / RI / NEL
        case 0x44: // ESC D — IND (Index: cursor down, scroll if at bottom)
            grid.index()

        case 0x4D: // ESC M — RI (Reverse Index: cursor up, scroll if at top)
            grid.reverseIndex()

        case 0x45: // ESC E — NEL (Next Line: CR + IND)
            grid.carriageReturn()
            grid.index()

        // A.15.3 — RIS (Full Reset)
        case 0x63: // ESC c — RIS
            grid.fullReset()
            await inputModeState?.applyFullReset()

        // A.15.4 — HTS (Set Tab Stop)
        case 0x48: // ESC H — HTS
            grid.setTabStop()

        // A.15.5 — DECKPAM / DECKPNM (Keypad Modes)
        case 0x3D: // ESC = — DECKPAM (Application Keypad Mode)
            grid.setApplicationKeypad(true)
            await inputModeState?.setApplicationKeypad(true)

        case 0x3E: // ESC > — DECKPNM (Normal Keypad Mode)
            grid.setApplicationKeypad(false)
            await inputModeState?.setApplicationKeypad(false)

        default:
            break // Unknown ESC sequence — ignore
        }
    }

    // MARK: - ESC With Intermediate Bytes

    /// Handle ESC sequences that have intermediate bytes.
    private static func dispatchWithIntermediate(
        intermediate: UInt8,
        final byte: UInt8,
        grid: TerminalGrid
    ) {
        switch intermediate {

        // A.15.6 — Charset Designation (ESC ( / ESC ))
        case 0x28: // ESC ( — Designate G0 character set
            CharsetHandler.designate(g: 0, designator: byte, grid: grid)

        case 0x29: // ESC ) — Designate G1 character set
            CharsetHandler.designate(g: 1, designator: byte, grid: grid)

        // A.15.7 — DECALN (ESC # 8)
        case 0x23: // ESC #
            if byte == 0x38 { // ESC # 8 — DECALN (Screen Alignment Pattern)
                grid.screenAlignmentPattern()
            }

        default:
            break // Unknown intermediate — ignore
        }
    }
}
