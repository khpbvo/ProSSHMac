// SGRHandler.swift
// ProSSHV2
//
// Handles SGR (Select Graphic Rendition) — CSI m sequences.
// Processes all parameters to set text attributes and colors.
//
// Supports:
// - Reset (0)
// - Bold, dim, italic, underline, blink, reverse, hidden, strikethrough
// - Standard foreground/background colors (30–37, 40–47)
// - Bright foreground/background colors (90–97, 100–107)
// - 256-color mode (38;5;N / 48;5;N)
// - Truecolor mode (38;2;R;G;B / 48;2;R;G;B)
// - Default color restore (39, 49)
// - Attribute reset codes (22–29)
// - Double underline (21)
// - Underline styles via subparameters: 4:0–4:5
// - Underline color (58;5;N / 58;2;R;G;B) and reset (59)
// - Overline (53/55)
// - Colon subparameter form for extended colors (38:2::R:G:B, 38:5:N)

import Foundation

// MARK: - SGRHandler

/// Namespace for SGR (Select Graphic Rendition) processing.
nonisolated enum SGRHandler {

    /// SGR working state: attributes + foreground + background + underline color.
    typealias SGRState = (
        attributes: CellAttributes,
        fg: TerminalColor,
        bg: TerminalColor,
        underlineColor: TerminalColor,
        underlineStyle: UnderlineStyle
    )

    // MARK: - A.11 Main Handler

    /// Handle a complete SGR sequence with subparameter support.
    /// `params` is [[Int]] where each element is a group of subparameters.
    /// A semicolon-separated sequence like "1;31" produces [[1],[31]].
    /// A colon-separated sequence like "4:3" produces [[4,3]].
    static func handle(params: [[Int]], grid: TerminalGrid) async {
        var sgr = await grid.sgrState()

        // A.11.1 — No parameters means reset
        if params.isEmpty {
            sgr.attributes = []
            sgr.fg = .default
            sgr.bg = .default
            sgr.underlineColor = .default
            sgr.underlineStyle = .none
            await apply(sgr, to: grid)
            return
        }

        var i = 0
        while i < params.count {
            let group = params[i]
            let code = group[0]

            switch code {

            // A.11.1 — Reset
            case SGRCode.reset:
                sgr.attributes = []
                sgr.fg = .default
                sgr.bg = .default
                sgr.underlineColor = .default
                sgr.underlineStyle = .none

            // A.11.2 — Text attributes
            case SGRCode.bold:
                sgr.attributes.insert(.bold)
            case SGRCode.dim:
                sgr.attributes.insert(.dim)
            case SGRCode.italic:
                sgr.attributes.insert(.italic)
            case SGRCode.underline:
                // Check for subparameters: 4:0=none, 4:1=single, 4:2=double, 4:3=curly, 4:4=dotted, 4:5=dashed
                if group.count > 1 {
                    let style = UnderlineStyle(rawValue: UInt8(clamping: group[1])) ?? .single
                    applyUnderlineStyle(style, sgr: &sgr)
                } else {
                    applyUnderlineStyle(.single, sgr: &sgr)
                }
            case SGRCode.slowBlink, SGRCode.rapidBlink:
                sgr.attributes.insert(.blink)
            case SGRCode.reverse:
                sgr.attributes.insert(.reverse)
            case SGRCode.hidden:
                sgr.attributes.insert(.hidden)
            case SGRCode.strikethrough:
                sgr.attributes.insert(.strikethrough)

            // A.11.9 — Double underline
            case SGRCode.doubleUnderline:
                applyUnderlineStyle(.double, sgr: &sgr)

            // A.11.8 — Attribute reset codes (22–29)
            case SGRCode.normalIntensity: // 22
                sgr.attributes.remove(.bold)
                sgr.attributes.remove(.dim)
            case SGRCode.notItalic: // 23
                sgr.attributes.remove(.italic)
            case SGRCode.notUnderlined: // 24
                sgr.attributes.remove(.underline)
                sgr.attributes.remove(.doubleUnder)
                sgr.underlineStyle = .none
            case SGRCode.notBlinking: // 25
                sgr.attributes.remove(.blink)
            case SGRCode.notReversed: // 27
                sgr.attributes.remove(.reverse)
            case SGRCode.notHidden: // 28
                sgr.attributes.remove(.hidden)
            case SGRCode.notStrikethrough: // 29
                sgr.attributes.remove(.strikethrough)

            // A.11.3 — Standard foreground colors (30–37)
            case 30...37:
                sgr.fg = .indexed(UInt8(code - 30))

            // A.11.5 — 256-color / Truecolor foreground (38;5;N or 38;2;R;G;B or 38:5:N or 38:2::R:G:B)
            case SGRCode.fgColorExtended:
                if group.count > 1 {
                    // Colon form: subparams contain all color data
                    parseExtendedColorFromSubparams(group: group, isForeground: true, sgr: &sgr)
                } else {
                    // Semicolon form: consume subsequent top-level params
                    i = parseExtendedColor(params: params, from: i, isForeground: true, sgr: &sgr)
                }

            // A.11.7 — Default foreground restore (39)
            case SGRCode.fgColorDefault:
                sgr.fg = .default

            // A.11.3 — Standard background colors (40–47)
            case 40...47:
                sgr.bg = .indexed(UInt8(code - 40))

            // A.11.5 — 256-color / Truecolor background (48;5;N or 48;2;R;G;B or 48:5:N or 48:2::R:G:B)
            case SGRCode.bgColorExtended:
                if group.count > 1 {
                    parseExtendedColorFromSubparams(group: group, isForeground: false, sgr: &sgr)
                } else {
                    i = parseExtendedColor(params: params, from: i, isForeground: false, sgr: &sgr)
                }

            // A.11.7 — Default background restore (49)
            case SGRCode.bgColorDefault:
                sgr.bg = .default

            // Overline (53/55)
            case SGRCode.overline:
                sgr.attributes.insert(.overline)
            case SGRCode.notOverline:
                sgr.attributes.remove(.overline)

            // Underline color (58) — extended color for underlines
            case SGRCode.underlineColorExtended:
                if group.count > 1 {
                    parseUnderlineColorFromSubparams(group: group, sgr: &sgr)
                } else {
                    i = parseUnderlineColor(params: params, from: i, sgr: &sgr)
                }

            // Underline color reset (59)
            case SGRCode.underlineColorDefault:
                sgr.underlineColor = .default

            // A.11.4 — Bright foreground colors (90–97)
            case 90...97:
                sgr.fg = .indexed(UInt8(code - 90 + 8))

            // A.11.4 — Bright background colors (100–107)
            case 100...107:
                sgr.bg = .indexed(UInt8(code - 100 + 8))

            default:
                break
            }
            i += 1
        }

        await apply(sgr, to: grid)
    }

    // MARK: - Underline Style Helper

    /// Apply an underline style, setting/clearing the appropriate attribute bits.
    private static func applyUnderlineStyle(_ style: UnderlineStyle, sgr: inout SGRState) {
        // Clear all underline-related bits first
        sgr.attributes.remove(.underline)
        sgr.attributes.remove(.doubleUnder)
        sgr.underlineStyle = style

        switch style {
        case .none:
            break
        case .single:
            sgr.attributes.insert(.underline)
        case .double:
            sgr.attributes.insert(.doubleUnder)
        case .curly, .dotted, .dashed:
            // These use the underline attribute bit plus the style stored separately
            sgr.attributes.insert(.underline)
        }
    }

    // MARK: - Extended Color Parsing (Semicolon form)

    /// Parse extended color from semicolon-separated top-level params.
    /// Returns the index of the last consumed parameter group.
    private static func parseExtendedColor(
        params: [[Int]],
        from index: Int,
        isForeground: Bool,
        sgr: inout SGRState
    ) -> Int {
        guard index + 1 < params.count else { return index }

        let colorType = params[index + 1].first ?? 0

        switch colorType {
        case 5: // 256-color: 38;5;N or 48;5;N
            guard index + 2 < params.count else { return index + 1 }
            let colorIndex = UInt8(clamping: params[index + 2].first ?? 0)
            if isForeground { sgr.fg = .indexed(colorIndex) }
            else { sgr.bg = .indexed(colorIndex) }
            return index + 2

        case 2: // Truecolor: 38;2;R;G;B or 48;2;R;G;B
            guard index + 4 < params.count else { return index + 1 }
            let r = UInt8(clamping: params[index + 2].first ?? 0)
            let g = UInt8(clamping: params[index + 3].first ?? 0)
            let b = UInt8(clamping: params[index + 4].first ?? 0)
            if isForeground { sgr.fg = .rgb(r, g, b) }
            else { sgr.bg = .rgb(r, g, b) }
            return index + 4

        default:
            return index + 1
        }
    }

    // MARK: - Extended Color Parsing (Colon/subparam form)

    /// Parse extended color from a colon-separated subparameter group.
    /// Handles: 38:5:N, 38:2:CS:R:G:B (CS = colorspace, usually 0 or omitted)
    private static func parseExtendedColorFromSubparams(
        group: [Int],
        isForeground: Bool,
        sgr: inout SGRState
    ) {
        guard group.count >= 2 else { return }
        let colorType = group[1]

        switch colorType {
        case 5: // 256-color: 38:5:N
            guard group.count >= 3 else { return }
            let colorIndex = UInt8(clamping: group[2])
            if isForeground { sgr.fg = .indexed(colorIndex) }
            else { sgr.bg = .indexed(colorIndex) }

        case 2: // Truecolor: 38:2:CS:R:G:B or 38:2::R:G:B
            // The colorspace ID is at index 2, R/G/B follow.
            // When colorspace is omitted (double-colon), index 2 will be 0.
            if group.count >= 6 {
                // Full form with colorspace: 38:2:CS:R:G:B
                let r = UInt8(clamping: group[3])
                let g = UInt8(clamping: group[4])
                let b = UInt8(clamping: group[5])
                if isForeground { sgr.fg = .rgb(r, g, b) }
                else { sgr.bg = .rgb(r, g, b) }
            } else if group.count >= 5 {
                // Short form without colorspace: 38:2:R:G:B
                let r = UInt8(clamping: group[2])
                let g = UInt8(clamping: group[3])
                let b = UInt8(clamping: group[4])
                if isForeground { sgr.fg = .rgb(r, g, b) }
                else { sgr.bg = .rgb(r, g, b) }
            }

        default:
            break
        }
    }

    // MARK: - Underline Color Parsing (Semicolon form)

    /// Parse underline color from semicolon-separated top-level params.
    private static func parseUnderlineColor(
        params: [[Int]],
        from index: Int,
        sgr: inout SGRState
    ) -> Int {
        guard index + 1 < params.count else { return index }

        let colorType = params[index + 1].first ?? 0

        switch colorType {
        case 5: // 256-color: 58;5;N
            guard index + 2 < params.count else { return index + 1 }
            let colorIndex = UInt8(clamping: params[index + 2].first ?? 0)
            sgr.underlineColor = .indexed(colorIndex)
            return index + 2

        case 2: // Truecolor: 58;2;R;G;B
            guard index + 4 < params.count else { return index + 1 }
            let r = UInt8(clamping: params[index + 2].first ?? 0)
            let g = UInt8(clamping: params[index + 3].first ?? 0)
            let b = UInt8(clamping: params[index + 4].first ?? 0)
            sgr.underlineColor = .rgb(r, g, b)
            return index + 4

        default:
            return index + 1
        }
    }

    // MARK: - Underline Color Parsing (Colon/subparam form)

    /// Parse underline color from a colon-separated subparameter group.
    private static func parseUnderlineColorFromSubparams(
        group: [Int],
        sgr: inout SGRState
    ) {
        guard group.count >= 2 else { return }
        let colorType = group[1]

        switch colorType {
        case 5: // 256-color: 58:5:N
            guard group.count >= 3 else { return }
            sgr.underlineColor = .indexed(UInt8(clamping: group[2]))

        case 2: // Truecolor: 58:2:CS:R:G:B or 58:2::R:G:B
            if group.count >= 6 {
                let r = UInt8(clamping: group[3])
                let g = UInt8(clamping: group[4])
                let b = UInt8(clamping: group[5])
                sgr.underlineColor = .rgb(r, g, b)
            } else if group.count >= 5 {
                let r = UInt8(clamping: group[2])
                let g = UInt8(clamping: group[3])
                let b = UInt8(clamping: group[4])
                sgr.underlineColor = .rgb(r, g, b)
            }

        default:
            break
        }
    }

    // MARK: - Apply to Grid

    /// Write the SGR state back to the grid.
    private static func apply(_ sgr: SGRState, to grid: TerminalGrid) async {
        await grid.setCurrentAttributes(sgr.attributes)
        await grid.setCurrentFgColor(sgr.fg)
        await grid.setCurrentBgColor(sgr.bg)
        await grid.setCurrentUnderlineColor(sgr.underlineColor)
        await grid.setCurrentUnderlineStyle(sgr.underlineStyle)
    }
}
