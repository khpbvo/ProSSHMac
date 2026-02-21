// OSCHandler.swift
// ProSSHV2
//
// Handles OSC (Operating System Command) sequences.
// OSC format: ESC ] <number> ; <string> ST
// where ST is ESC \ or 0x9C.
//
// Supports:
// - A.13.2 Window title (OSC 0/1/2)
// - A.13.3 Color palette query/set (OSC 4/10/11/12)
// - A.13.4 Cursor color (OSC 12/112)
// - A.13.5 Clipboard (OSC 52) — with security restrictions

import Foundation

// MARK: - OSCHandler

/// Namespace for OSC (Operating System Command) dispatch.
nonisolated enum OSCHandler {

    // MARK: - A.13.1 String Collection & Dispatch

    /// Dispatch a collected OSC string.
    /// The string is everything between OSC start and ST.
    ///
    /// - Parameters:
    ///   - oscString: Raw bytes of the OSC payload (after ESC ])
    ///   - grid: The terminal grid to update
    ///   - responseHandler: Closure for sending responses back to the host
    static func dispatch(
        oscString: [UInt8],
        grid: TerminalGrid,
        responseHandler: (([UInt8]) async -> Void)?
    ) async {
        // Parse: <number> ; <string>
        // Some OSC commands have no semicolon (e.g., OSC 112 for cursor color reset)
        let separatorIndex = oscString.firstIndex(of: 0x3B) // ';'

        let numberPart: ArraySlice<UInt8>
        let stringPart: ArraySlice<UInt8>

        if let idx = separatorIndex {
            numberPart = oscString[0..<idx]
            stringPart = oscString[(idx + 1)...]
        } else {
            numberPart = oscString[0...]
            stringPart = [][...]
        }

        guard let numberStr = String(bytes: numberPart, encoding: .utf8),
              let oscCode = Int(numberStr) else {
            return
        }

        let text = String(bytes: stringPart, encoding: .utf8) ?? ""

        switch oscCode {

        // A.13.2 — Window title
        case OSCCommand.setTitleAndIcon:
            grid.setWindowTitle(text)
            grid.setIconName(text)

        case OSCCommand.setIconName:
            grid.setIconName(text)

        case OSCCommand.setWindowTitle:
            grid.setWindowTitle(text)

        // OSC 7 — Working directory (file://hostname/path)
        case OSCCommand.setWorkingDirectory:
            handleWorkingDirectory(text: text, grid: grid)

        // OSC 8 — Hyperlink (stub: parse and store, no click handling yet)
        case OSCCommand.hyperlink:
            handleHyperlink(text: text, grid: grid)

        // A.13.3 — Color palette set/query (OSC 4)
        case OSCCommand.setColorPalette:
            await handleColorPalette(text: text, grid: grid, responseHandler: responseHandler)

        // A.13.3 — Foreground color set/query (OSC 10)
        case OSCCommand.setForeground:
            await handleSpecialColor(
                text: text, kind: .foreground, grid: grid, responseHandler: responseHandler
            )

        // A.13.3 — Background color set/query (OSC 11)
        case OSCCommand.setBackground:
            await handleSpecialColor(
                text: text, kind: .background, grid: grid, responseHandler: responseHandler
            )

        // A.13.4 — Cursor color set/query (OSC 12)
        case OSCCommand.setCursorColor:
            await handleSpecialColor(
                text: text, kind: .cursor, grid: grid, responseHandler: responseHandler
            )

        // A.13.5 — Clipboard (OSC 52)
        case OSCCommand.clipboard:
            await handleClipboard(text: text, grid: grid, responseHandler: responseHandler)

        // A.13.4 — Reset cursor color (OSC 112)
        case OSCCommand.resetCursorColor:
            grid.resetCursorColor()

        // OSC 133 — Semantic prompt (placeholder for future shell integration)
        case OSCCommand.semanticPrompt:
            break

        default:
            break // Unknown OSC — ignore
        }
    }

    // MARK: - A.13.3 Color Palette (OSC 4)

    /// Handle OSC 4 — set or query indexed palette colors.
    /// Format: OSC 4 ; <index> ; <color_spec> ST  (set)
    /// Format: OSC 4 ; <index> ; ? ST              (query)
    private static func handleColorPalette(
        text: String,
        grid: TerminalGrid,
        responseHandler: (([UInt8]) async -> Void)?
    ) async {
        // Text after "4;" is: index;color_spec[;index;color_spec...]
        // OSC 4 can set multiple palette colors in one sequence,
        // so we parse all pairs by advancing two parts at a time.
        let parts = text.split(separator: ";")
        var i = 0
        while i + 1 < parts.count {
            guard let index = UInt8(parts[i]) else {
                i += 2
                continue
            }
            let spec = String(parts[i + 1])

            if spec == "?" {
                // Query: respond with current color
                let (r, g, b) = grid.paletteColor(index: index)
                let response = "\u{1B}]4;\(index);rgb:\(hexPair(r))/\(hexPair(g))/\(hexPair(b))\u{1B}\\"
                await responseHandler?(Array(response.utf8))
            } else {
                // Set: parse color spec
                if let (r, g, b) = parseColorSpec(spec) {
                    grid.setPaletteColor(index: index, r: r, g: g, b: b)
                }
            }

            i += 2
        }
    }

    // MARK: - A.13.3 Special Colors (OSC 10/11/12)

    /// Kind of special color for OSC 10/11/12.
    private enum SpecialColorKind {
        case foreground  // OSC 10
        case background  // OSC 11
        case cursor      // OSC 12
    }

    /// Handle OSC 10/11/12 — set or query foreground/background/cursor color.
    /// Format: OSC N ; <color_spec> ST  (set)
    /// Format: OSC N ; ? ST             (query)
    private static func handleSpecialColor(
        text: String,
        kind: SpecialColorKind,
        grid: TerminalGrid,
        responseHandler: (([UInt8]) async -> Void)?
    ) async {
        if text == "?" {
            // Query: respond with current color
            let (r, g, b): (UInt8, UInt8, UInt8)
            let oscCode: Int

            switch kind {
            case .foreground:
                (r, g, b) = grid.defaultForegroundRGB()
                oscCode = OSCCommand.setForeground
            case .background:
                (r, g, b) = grid.defaultBackgroundRGB()
                oscCode = OSCCommand.setBackground
            case .cursor:
                if let cc = grid.cursorColor {
                    (r, g, b) = cc
                } else {
                    (r, g, b) = grid.defaultForegroundRGB()
                }
                oscCode = OSCCommand.setCursorColor
            }

            let response = "\u{1B}]\(oscCode);rgb:\(hexPair(r))/\(hexPair(g))/\(hexPair(b))\u{1B}\\"
            await responseHandler?(Array(response.utf8))
        } else {
            // Set
            if let (r, g, b) = parseColorSpec(text) {
                switch kind {
                case .foreground:
                    grid.setDefaultForegroundRGB(r: r, g: g, b: b)
                case .background:
                    grid.setDefaultBackgroundRGB(r: r, g: g, b: b)
                case .cursor:
                    grid.setCursorColor(r: r, g: g, b: b)
                }
            }
        }
    }

    // MARK: - A.13.5 Clipboard (OSC 52)

    /// Handle OSC 52 — clipboard access.
    /// Format: OSC 52 ; <selection> ; <base64_data> ST
    /// Selection: c = clipboard, p = primary, s = secondary
    ///
    /// Security: Clipboard read is disabled by default to prevent data exfiltration.
    /// Clipboard write is allowed (apps like tmux use it to set clipboard content).
    private static func handleClipboard(
        text: String,
        grid: TerminalGrid,
        responseHandler: (([UInt8]) async -> Void)?
    ) async {
        let parts = text.split(separator: ";", maxSplits: 1)
        guard parts.count >= 2 else { return }

        let data = String(parts[1])

        if data == "?" {
            // Query clipboard — DENIED for security.
            // Respond with empty data to indicate clipboard read is not supported.
            // This prevents malicious servers from reading clipboard contents.
            let response = "\u{1B}]52;;\u{1B}\\"
            await responseHandler?(Array(response.utf8))
        } else {
            // Set clipboard — decode base64 and store.
            // The actual clipboard integration will be connected in Phase F
            // via a delegate/callback on the grid/session.
            // For now, this is a no-op placeholder.
            // _ = Data(base64Encoded: data) // decoded clipboard content
        }
    }

    // MARK: - OSC 7 Working Directory

    /// Handle OSC 7 — report current working directory.
    /// Format: OSC 7 ; file://hostname/path ST
    /// Stores the extracted path on the grid for session metadata display.
    private static func handleWorkingDirectory(
        text: String,
        grid: TerminalGrid
    ) {
        // Parse file://hostname/path URL
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme == "file" else {
            // Fallback: treat the entire text as a path
            if !trimmed.isEmpty {
                grid.setWorkingDirectory(trimmed)
            }
            return
        }

        let path = url.path
        guard !path.isEmpty else { return }

        // Decode percent-encoded path
        let decoded = path.removingPercentEncoding ?? path
        grid.setWorkingDirectory(decoded)
    }

    // MARK: - OSC 8 Hyperlink (Stub)

    /// Handle OSC 8 — hyperlink.
    /// Format: OSC 8 ; params ; URI ST  (start hyperlink)
    /// Format: OSC 8 ; ; ST             (end hyperlink)
    ///
    /// The text after "8;" is: params;URI
    /// `params` is a semicolon-separated key=value list (e.g., "id=foo").
    /// When URI is empty, the hyperlink is ended.
    ///
    /// For now, this is a stub: we parse the URI and set/clear a hyperlink ID
    /// on the grid, but no click handling or rendering differentiation is done.
    /// Future phases will render hyperlinks with subtle underlines and enable
    /// tap-to-open via a URL handler.
    private static func handleHyperlink(
        text: String,
        grid: TerminalGrid
    ) {
        // Text after "8;" is: params;URI
        // Find the second semicolon to split params from URI
        guard let sepIndex = text.firstIndex(of: ";") else {
            // Malformed — need at least one semicolon
            grid.setCurrentHyperlink(nil)
            return
        }

        let uri = String(text[text.index(after: sepIndex)...])

        if uri.isEmpty {
            // End hyperlink
            grid.setCurrentHyperlink(nil)
        } else {
            // Start hyperlink — store the URI
            grid.setCurrentHyperlink(uri)
        }
    }

    // MARK: - Color Spec Parsing

    /// Parse an X11-style color specification.
    /// Supports:
    /// - "rgb:RR/GG/BB" (hex pairs)
    /// - "rgb:RRRR/GGGG/BBBB" (16-bit components, downscaled)
    /// - "#RRGGBB" (HTML-style hex)
    /// - "#RGB" (short hex)
    private static func parseColorSpec(_ spec: String) -> (UInt8, UInt8, UInt8)? {
        let s = spec.trimmingCharacters(in: .whitespaces)

        // rgb:RR/GG/BB or rgb:RRRR/GGGG/BBBB
        if s.hasPrefix("rgb:") {
            let components = s.dropFirst(4).split(separator: "/")
            guard components.count == 3 else { return nil }

            let vals = components.compactMap { parseHexComponent(String($0)) }
            guard vals.count == 3 else { return nil }
            return (vals[0], vals[1], vals[2])
        }

        // #RRGGBB
        if s.hasPrefix("#") && s.count == 7 {
            let hex = String(s.dropFirst())
            guard let val = UInt32(hex, radix: 16) else { return nil }
            return (
                UInt8((val >> 16) & 0xFF),
                UInt8((val >> 8) & 0xFF),
                UInt8(val & 0xFF)
            )
        }

        // #RGB (short form)
        if s.hasPrefix("#") && s.count == 4 {
            let hex = String(s.dropFirst())
            guard let val = UInt16(hex, radix: 16) else { return nil }
            let r = UInt8(((val >> 8) & 0xF) * 17)
            let g = UInt8(((val >> 4) & 0xF) * 17)
            let b = UInt8((val & 0xF) * 17)
            return (r, g, b)
        }

        return nil
    }

    /// Parse a hex component (2-digit or 4-digit) to a UInt8.
    private static func parseHexComponent(_ hex: String) -> UInt8? {
        guard let val = UInt16(hex, radix: 16) else { return nil }
        if hex.count <= 2 {
            return UInt8(val)
        } else {
            // 4-digit: downscale from 16-bit to 8-bit
            return UInt8(val >> 8)
        }
    }

    /// Format a UInt8 as a two-character hex string.
    private static func hexPair(_ v: UInt8) -> String {
        String(format: "%02x%02x", v, v) // X11 format duplicates: ff → ffff
    }
}
