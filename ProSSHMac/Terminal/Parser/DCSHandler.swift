// DCSHandler.swift
// ProSSHV2
//
// Handles DCS (Device Control String) sequences.
// DCS format: ESC P <params> <intermediates> <final> <data> ST
//
// DCS sequences have three lifecycle phases:
// - Hook: sequence starts, params/intermediates available
// - Put: data bytes arrive during passthrough
// - Unhook: ST received, finalize and dispatch
//
// Supports:
// - A.14.1 Passthrough mode (hook/put/unhook lifecycle)
// - A.14.2 DECRQSS (Request Status String — DCS $ q <selector> ST)

import Foundation

// MARK: - DCSHandler

/// Namespace for DCS (Device Control String) dispatch.
nonisolated enum DCSHandler {

    // MARK: - A.14.1 Passthrough Mode

    // MARK: - Parameter Compatibility

    /// Flatten subparameter groups into a simple [Int] array.
    /// DCS sequences don't use subparameters, so we just take
    /// the first element of each group.
    private static func flatParams(_ params: [[Int]]) -> [Int] {
        params.map { $0.first ?? 0 }
    }

    /// Hook: called when DCS sequence begins.
    /// Stores the parameters and intermediates for later use during unhook.
    /// Currently a no-op — actual hook handling can be added for specific DCS types.
    static func hook(
        params: [[Int]],
        intermediates: [UInt8],
        finalByte: UInt8,
        grid: TerminalGrid
    ) async {
        // DCS hook is a placeholder.
        // Specific DCS types (DECRQSS, DECSIXEL, etc.) will implement their
        // own hook logic here once needed.
    }

    /// Unhook: called when ST terminates the DCS sequence.
    /// Dispatches based on the collected intermediates and data.
    ///
    /// - Parameters:
    ///   - data: Raw bytes collected during DCS passthrough
    ///   - params: Parameters from the DCS entry (nested subparam groups)
    ///   - intermediates: Intermediate bytes from the DCS entry
    ///   - grid: The terminal grid
    ///   - responseHandler: Closure for sending responses back to the host
    static func unhook(
        data: [UInt8],
        params: [[Int]],
        intermediates: [UInt8],
        grid: TerminalGrid,
        responseHandler: (([UInt8]) async -> Void)?
    ) async {
        // Dispatch based on intermediates
        // DCS $ q ... ST = DECRQSS
        if intermediates.contains(0x24) { // '$'
            await handleDECRQSS(
                data: data, grid: grid, responseHandler: responseHandler
            )
            return
        }

        // Other DCS types can be added here:
        // - DECSIXEL (DCS <params> q <sixel data> ST) — sixel graphics
        // - DECUDK (DCS <params> | <key definitions> ST) — user-defined keys
        // - DECTMUX (DCS 1000p ... ST) — tmux control mode
        //
        // For now, unknown DCS sequences are silently ignored.
    }

    // MARK: - A.14.2 DECRQSS (Request Status String)

    /// Handle DECRQSS — DCS $ q <selector> ST
    /// The selector is a string identifying what status to report:
    /// - "m"  → SGR (current text attributes)
    /// - "r"  → DECSTBM (scroll region)
    /// - " q" → DECSCUSR (cursor style)
    ///
    /// Response format: DCS <valid> $ r <value> ST
    /// where <valid> is 1 for valid request, 0 for invalid.
    private static func handleDECRQSS(
        data: [UInt8],
        grid: TerminalGrid,
        responseHandler: (([UInt8]) async -> Void)?
    ) async {
        guard let selector = String(bytes: data, encoding: .utf8) else { return }

        let response: String?

        switch selector {
        case "m": // SGR — report current text attributes
            response = await buildSGRReport(grid: grid)

        case "r": // DECSTBM — report scroll region
            response = await buildScrollRegionReport(grid: grid)

        case " q": // DECSCUSR — report cursor style
            response = await buildCursorStyleReport(grid: grid)

        default:
            // Unknown selector — respond with invalid marker
            response = nil
        }

        if let resp = response {
            // Valid: DCS 1 $ r <value> ST
            let dcsResponse = "\u{1B}P1$r\(resp)\u{1B}\\"
            await responseHandler?(Array(dcsResponse.utf8))
        } else {
            // Invalid: DCS 0 $ r ST
            let dcsResponse = "\u{1B}P0$r\u{1B}\\"
            await responseHandler?(Array(dcsResponse.utf8))
        }
    }

    // MARK: - DECRQSS Report Builders

    /// Build SGR report string for current attributes.
    /// Returns the CSI parameter string (e.g., "0;1;31" for reset+bold+red fg).
    private static func buildSGRReport(grid: TerminalGrid) async -> String {
        let sgr = await grid.sgrState()
        var codes: [Int] = [0] // Always start with reset

        if sgr.attributes.contains(.bold)          { codes.append(1) }
        if sgr.attributes.contains(.dim)           { codes.append(2) }
        if sgr.attributes.contains(.italic)        { codes.append(3) }
        if sgr.attributes.contains(.underline)     { codes.append(4) }
        if sgr.attributes.contains(.blink)         { codes.append(5) }
        if sgr.attributes.contains(.reverse)       { codes.append(7) }
        if sgr.attributes.contains(.hidden)        { codes.append(8) }
        if sgr.attributes.contains(.strikethrough) { codes.append(9) }
        if sgr.attributes.contains(.doubleUnder)   { codes.append(21) }

        // Foreground color
        switch sgr.fg {
        case .default: break
        case .indexed(let idx) where idx < 8:
            codes.append(30 + Int(idx))
        case .indexed(let idx) where idx < 16:
            codes.append(90 + Int(idx) - 8)
        case .indexed(let idx):
            codes.append(contentsOf: [38, 5, Int(idx)])
        case .rgb(let r, let g, let b):
            codes.append(contentsOf: [38, 2, Int(r), Int(g), Int(b)])
        }

        // Background color
        switch sgr.bg {
        case .default: break
        case .indexed(let idx) where idx < 8:
            codes.append(40 + Int(idx))
        case .indexed(let idx) where idx < 16:
            codes.append(100 + Int(idx) - 8)
        case .indexed(let idx):
            codes.append(contentsOf: [48, 5, Int(idx)])
        case .rgb(let r, let g, let b):
            codes.append(contentsOf: [48, 2, Int(r), Int(g), Int(b)])
        }

        return codes.map(String.init).joined(separator: ";") + "m"
    }

    /// Build DECSTBM report string for current scroll region.
    private static func buildScrollRegionReport(grid: TerminalGrid) async -> String {
        let top = await grid.scrollTop + 1  // 1-based
        let bottom = await grid.scrollBottom + 1
        return "\(top);\(bottom)r"
    }

    /// Build DECSCUSR report string for current cursor style.
    private static func buildCursorStyleReport(grid: TerminalGrid) async -> String {
        let style = await grid.cursor.style
        let code: Int
        switch style {
        case .block:     code = 2  // Steady block
        case .underline: code = 4  // Steady underline
        case .bar:       code = 6  // Steady bar
        }
        return "\(code) q"
    }
}
