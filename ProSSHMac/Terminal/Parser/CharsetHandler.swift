// CharsetHandler.swift
// ProSSHV2
//
// Handles character set designation and invocation.
//
// Supports:
// - G0/G1 charset designation via ESC ( and ESC )
// - Charset invocation via SO (0x0E → G1) and SI (0x0F → G0)
// - DEC Special Graphics character mapping (full table from VTConstants)
// - ASCII charset (passthrough)
// - UK National charset (£ for #)

import Foundation

// MARK: - CharsetHandler

/// Namespace for character set handling.
/// Manages charset designation (which set is G0/G1) and character mapping.
nonisolated enum CharsetHandler {

    // MARK: - A.12.1 Charset Designation (ESC ( and ESC ))

    /// Designate a character set for a slot (G0 or G1).
    /// Called from ESC dispatch when intermediate is '(' or ')'.
    ///
    /// - Parameters:
    ///   - g: The slot (0 = G0, 1 = G1)
    ///   - designator: The final byte selecting the charset
    ///   - grid: The terminal grid to update
    static func designate(g: Int, designator: UInt8, grid: TerminalGrid) {
        let charset: Charset
        switch designator {
        case 0x30: // '0' — DEC Special Graphics
            charset = .decSpecialGraphics
        case 0x42: // 'B' — US ASCII
            charset = .ascii
        case 0x41: // 'A' — UK National
            charset = .ukNational
        default:
            return // Unknown designator — ignore
        }
        grid.setCharset(g: g, charset: charset)
    }

    // MARK: - A.12.2 Charset Invocation (SO/SI)

    /// Invoke a character set by number (SO → G1, SI → G0).
    ///
    /// - Parameters:
    ///   - n: The charset number (0 = G0, 1 = G1)
    ///   - grid: The terminal grid to update
    static func invoke(_ n: Int, grid: TerminalGrid) {
        grid.setActiveCharset(n)
    }

    // MARK: - A.12.3 DEC Special Graphics Character Map

    /// Map an ASCII byte through the active character set.
    /// Uses the charsetState snapshot from the grid to avoid repeated actor hops.
    ///
    /// - Parameters:
    ///   - byte: The ASCII byte to map (0x00–0x7F)
    ///   - charsetState: The current charset state snapshot (activeCharset, g0, g1)
    /// - Returns: The mapped character
    static func mapCharacter(
        _ byte: UInt8,
        charsetState: (activeCharset: Int, g0: Charset, g1: Charset)
    ) -> Character {
        let charset: Charset
        switch charsetState.activeCharset {
        case 1:  charset = charsetState.g1
        default: charset = charsetState.g0
        }

        switch charset {
        case .decSpecialGraphics:
            // A.12.3 — DEC Special Graphics: map bytes 0x60–0x7E to box-drawing characters
            if byte >= 0x60 && byte <= 0x7E,
               let mapped = DECSpecialGraphics.mapCharacter(byte) {
                return mapped
            }
            // Bytes outside the graphics range pass through as ASCII
            return Character(UnicodeScalar(byte))

        case .ascii:
            // A.12.4 — ASCII charset: pure passthrough
            return Character(UnicodeScalar(byte))

        case .ukNational:
            // UK National: '#' (0x23) → '£', everything else passes through
            if byte == 0x23 {
                return "£"
            }
            return Character(UnicodeScalar(byte))
        }
    }
}
