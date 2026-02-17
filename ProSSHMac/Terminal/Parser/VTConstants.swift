// VTConstants.swift
// ProSSHV2
//
// All constant definitions, mode enums, charset maps, and color tables
// for the VT500-series compatible terminal parser.

import Foundation

// MARK: - Parser States

/// States for the VT parser state machine.
/// Based on Paul Flo Williams' VT500-series state machine model.
/// Reference: https://vt100.net/emu/dec_ansi_parser
nonisolated enum ParserState: UInt8, Sendable {
    case ground             = 0
    case escape             = 1
    case escapeIntermediate = 2
    case csiEntry           = 3
    case csiParam           = 4
    case csiIntermediate    = 5
    case csiIgnore          = 6
    case dcsEntry           = 7
    case dcsParam           = 8
    case dcsIntermediate    = 9
    case dcsPassthrough     = 10
    case dcsIgnore          = 11
    case oscString          = 12
    case sosPmApcString     = 13
}

// MARK: - Parser Actions

/// Actions emitted by the parser state machine on byte transitions.
nonisolated enum ParserAction: UInt8, Sendable {
    case none           = 0
    case print          = 1   // Write character to grid at cursor
    case execute        = 2   // Execute C0/C1 control
    case clear          = 3   // Clear collected parameters
    case collect        = 4   // Add byte to intermediate buffer
    case param          = 5   // Add digit to current parameter / advance on semicolon
    case escDispatch    = 6   // Dispatch escape sequence
    case csiDispatch    = 7   // Dispatch CSI sequence
    case oscStart       = 8   // Begin collecting OSC string
    case oscPut         = 9   // Add byte to OSC string
    case oscEnd         = 10  // Dispatch OSC string
    case dcsHook        = 11  // Begin DCS handler
    case dcsPut         = 12  // Pass byte to DCS handler
    case dcsUnhook      = 13  // End DCS handler
    case put            = 14  // Generic put for passthrough modes
}

// MARK: - C0 Control Characters

/// C0 control characters (0x00–0x1F) executed in most parser states.
nonisolated enum C0: UInt8, Sendable {
    case NUL = 0x00
    case SOH = 0x01
    case STX = 0x02
    case ETX = 0x03
    case EOT = 0x04
    case ENQ = 0x05
    case ACK = 0x06
    case BEL = 0x07  // Bell
    case BS  = 0x08  // Backspace
    case HT  = 0x09  // Horizontal Tab
    case LF  = 0x0A  // Line Feed
    case VT  = 0x0B  // Vertical Tab (same as LF)
    case FF  = 0x0C  // Form Feed (same as LF)
    case CR  = 0x0D  // Carriage Return
    case SO  = 0x0E  // Shift Out (switch to G1 charset)
    case SI  = 0x0F  // Shift In (switch to G0 charset)
    case DLE = 0x10
    case DC1 = 0x11  // XON
    case DC2 = 0x12
    case DC3 = 0x13  // XOFF
    case DC4 = 0x14
    case NAK = 0x15
    case SYN = 0x16
    case ETB = 0x17
    case CAN = 0x18  // Cancel (abort sequence)
    case EM  = 0x19
    case SUB = 0x1A  // Substitute (abort sequence, print error char)
    case ESC = 0x1B  // Escape
    case FS  = 0x1C
    case GS  = 0x1D
    case RS  = 0x1E
    case US  = 0x1F
    case DEL = 0x7F  // Delete (ignored in most states)
}

// MARK: - C1 Control Characters (8-bit)

/// C1 control characters (0x80–0x9F). 8-bit equivalents of ESC sequences.
nonisolated enum C1: UInt8, Sendable {
    case IND = 0x84  // Index
    case NEL = 0x85  // Next Line
    case HTS = 0x88  // Horizontal Tab Set
    case RI  = 0x8D  // Reverse Index
    case SS2 = 0x8E  // Single Shift 2
    case SS3 = 0x8F  // Single Shift 3
    case DCS = 0x90  // Device Control String
    case SPA = 0x96  // Start of Protected Area
    case EPA = 0x97  // End of Protected Area
    case SOS = 0x98  // Start of String
    case CSI = 0x9B  // Control Sequence Introducer
    case ST  = 0x9C  // String Terminator
    case OSC = 0x9D  // Operating System Command
    case PM  = 0x9E  // Privacy Message
    case APC = 0x9F  // Application Program Command
}

// MARK: - Byte Range Classification

/// Byte range categories for the parser state machine lookup tables.
nonisolated enum ByteRange {
    /// C0 control range: 0x00–0x1F
    static let c0Range: ClosedRange<UInt8> = 0x00...0x1F

    /// Intermediate bytes: 0x20–0x2F (space through /)
    static let intermediateRange: ClosedRange<UInt8> = 0x20...0x2F

    /// Parameter bytes: 0x30–0x3F (0–9, ;, <, =, >, ?)
    static let parameterRange: ClosedRange<UInt8> = 0x30...0x3F

    /// Uppercase dispatch: 0x40–0x5F
    static let uppercaseRange: ClosedRange<UInt8> = 0x40...0x5F

    /// Lowercase dispatch: 0x60–0x7E
    static let lowercaseRange: ClosedRange<UInt8> = 0x60...0x7E

    /// DEL: 0x7F
    static let del: UInt8 = 0x7F

    /// C1 control range: 0x80–0x9F
    static let c1Range: ClosedRange<UInt8> = 0x80...0x9F

    /// High printable range: 0xA0–0xFF (printable, UTF-8 start bytes)
    static let printableHighRange: ClosedRange<UInt8> = 0xA0...0xFF

    /// Printable ASCII range: 0x20–0x7E
    static let printableASCIIRange: ClosedRange<UInt8> = 0x20...0x7E

    /// Digit range: 0x30–0x39 (ASCII '0'–'9')
    static let digitRange: ClosedRange<UInt8> = 0x30...0x39

    /// Semicolon: parameter separator
    static let semicolon: UInt8 = 0x3B // ';'

    /// Colon: subparameter separator (used in some SGR extensions)
    static let colon: UInt8 = 0x3A // ':'

    /// Question mark: private mode indicator
    static let questionMark: UInt8 = 0x3F // '?'

    /// Exclamation mark: used in DECSTR (CSI ! p)
    static let exclamation: UInt8 = 0x21 // '!'

    /// Greater than: used in secondary DA
    static let greaterThan: UInt8 = 0x3E // '>'

    /// Less than: used in some private sequences
    static let lessThan: UInt8 = 0x3C // '<'

    /// Equals: used in some private sequences
    static let equals: UInt8 = 0x3D // '='
}

// MARK: - Cursor Style

/// Terminal cursor display style.
nonisolated enum CursorStyle: UInt8, Sendable {
    case block     = 0  // Filled block (default)
    case underline = 1  // Underline bar
    case bar       = 2  // Vertical bar (I-beam)
}

// MARK: - Mouse Tracking Mode

/// Mouse tracking modes set via DECSET/DECRST.
nonisolated enum MouseTrackingMode: UInt8, Sendable {
    case none        = 0  // No mouse tracking
    case x10         = 1  // Mode 1000: button press only
    case buttonEvent = 2  // Mode 1002: press, release, drag
    case anyEvent    = 3  // Mode 1003: all motion
}

// MARK: - Mouse Encoding

/// Mouse event encoding format.
nonisolated enum MouseEncoding: UInt8, Sendable {
    case x10    = 0  // Classic: ESC [ M <button+32> <col+33> <row+33>
    case utf8   = 1  // Mode 1005: UTF-8 extended coordinates
    case sgr    = 2  // Mode 1006: ESC [ < button ; col ; row M/m
}

// MARK: - Character Sets

/// Character set designations for G0/G1.
nonisolated enum Charset: UInt8, Sendable {
    case ascii              = 0  // Standard ASCII (B)
    case decSpecialGraphics = 1  // DEC Special Graphics / line drawing (0)
    case ukNational         = 2  // UK National (A) — # maps to £
}

// MARK: - DEC Special Graphics Character Map

/// DEC Special Graphics character mapping.
/// When G0/G1 is set to DEC Special Graphics (ESC ( 0), ASCII 0x60–0x7E
/// map to box-drawing and special characters. Used by Cisco IOS, Juniper, ncurses.
nonisolated enum DECSpecialGraphics {

    /// Maps ASCII code points (0x60–0x7E) to their Unicode replacements.
    /// Returns nil if the code point has no mapping (passes through unchanged).
    static func mapCharacter(_ ascii: UInt8) -> Character? {
        return characterMap[ascii]
    }

    /// Complete mapping table from the VT100/VT220 spec.
    static let characterMap: [UInt8: Character] = [
        0x60: "\u{25C6}",  // ` → ◆ Diamond
        0x61: "\u{2592}",  // a → ▒ Checkerboard
        0x62: "\u{2409}",  // b → ␉ HT symbol
        0x63: "\u{240C}",  // c → ␌ FF symbol
        0x64: "\u{240D}",  // d → ␍ CR symbol
        0x65: "\u{240A}",  // e → ␊ LF symbol
        0x66: "\u{00B0}",  // f → ° Degree
        0x67: "\u{00B1}",  // g → ± Plus/minus
        0x68: "\u{2424}",  // h → ␤ NL symbol
        0x69: "\u{240B}",  // i → ␋ VT symbol
        0x6A: "\u{2518}",  // j → ┘ Lower-right corner
        0x6B: "\u{2510}",  // k → ┐ Upper-right corner
        0x6C: "\u{250C}",  // l → ┌ Upper-left corner
        0x6D: "\u{2514}",  // m → └ Lower-left corner
        0x6E: "\u{253C}",  // n → ┼ Crossing
        0x6F: "\u{23BA}",  // o → ⎺ Scan line 1 (top)
        0x70: "\u{23BB}",  // p → ⎻ Scan line 3
        0x71: "\u{2500}",  // q → ─ Horizontal line
        0x72: "\u{23BC}",  // r → ⎼ Scan line 7
        0x73: "\u{23BD}",  // s → ⎽ Scan line 9 (bottom)
        0x74: "\u{251C}",  // t → ├ Left tee
        0x75: "\u{2524}",  // u → ┤ Right tee
        0x76: "\u{2534}",  // v → ┴ Bottom tee
        0x77: "\u{252C}",  // w → ┬ Top tee
        0x78: "\u{2502}",  // x → │ Vertical line
        0x79: "\u{2264}",  // y → ≤ Less-than-or-equal
        0x7A: "\u{2265}",  // z → ≥ Greater-than-or-equal
        0x7B: "\u{03C0}",  // { → π Pi
        0x7C: "\u{2260}",  // | → ≠ Not equal
        0x7D: "\u{00A3}",  // } → £ Pound sign
        0x7E: "\u{00B7}",  // ~ → · Middle dot
    ]
}

// MARK: - DEC Private Mode Constants

/// DEC Private Mode numbers used with DECSET (CSI ? Ps h) and DECRST (CSI ? Ps l).
nonisolated enum DECPrivateMode {
    static let DECCKM: Int   = 1     // Application Cursor Keys
    static let DECCOLM: Int  = 3     // 132/80 Column Mode
    static let DECSCNM: Int  = 5     // Reverse Video
    static let DECOM: Int    = 6     // Origin Mode
    static let DECAWM: Int   = 7     // Auto-Wrap Mode
    static let cursorBlink: Int = 12 // att610 cursor blink
    static let DECTCEM: Int  = 25    // Cursor Visible/Hidden
    static let altScreenOld: Int = 47    // Alternate screen buffer (older)
    static let altScreenAlt: Int = 1047  // Alternate screen buffer (no cursor save)
    static let mouseX10: Int     = 1000  // Mouse tracking — X10
    static let mouseButton: Int  = 1002  // Mouse tracking — button event
    static let mouseAny: Int     = 1003  // Mouse tracking — any event
    static let focusEvent: Int   = 1004  // Focus in/out events
    static let mouseUTF8: Int    = 1005  // UTF-8 mouse encoding
    static let mouseSGR: Int     = 1006  // SGR mouse encoding
    static let altScreen: Int    = 1049  // Alternate screen + save cursor (xterm)
    static let bracketedPaste: Int = 2004 // Bracketed paste mode
    static let synchronizedOutput: Int = 2026 // Synchronized output (mode 2026)
}

// MARK: - ANSI Mode Constants

/// ANSI (non-private) mode numbers used with SM (CSI Ps h) and RM (CSI Ps l).
nonisolated enum ANSIMode {
    static let IRM: Int = 4  // Insert/Replace Mode
    static let LNM: Int = 20 // Line Feed / New Line Mode
}

// MARK: - SGR Constants

/// SGR (Select Graphic Rendition) code constants.
nonisolated enum SGRCode {
    static let reset: Int            = 0
    static let bold: Int             = 1
    static let dim: Int              = 2
    static let italic: Int           = 3
    static let underline: Int        = 4
    static let slowBlink: Int        = 5
    static let rapidBlink: Int       = 6
    static let reverse: Int          = 7
    static let hidden: Int           = 8
    static let strikethrough: Int    = 9
    static let doubleUnderline: Int  = 21
    static let normalIntensity: Int  = 22
    static let notItalic: Int        = 23
    static let notUnderlined: Int    = 24
    static let notBlinking: Int      = 25
    static let notReversed: Int      = 27
    static let notHidden: Int        = 28
    static let notStrikethrough: Int = 29
    static let fgColorBase: Int      = 30   // 30–37: standard fg
    static let fgColorExtended: Int  = 38   // 38;5;N or 38;2;R;G;B
    static let fgColorDefault: Int   = 39
    static let bgColorBase: Int      = 40   // 40–47: standard bg
    static let bgColorExtended: Int  = 48   // 48;5;N or 48;2;R;G;B
    static let bgColorDefault: Int   = 49
    static let overline: Int             = 53
    static let notOverline: Int          = 55
    static let underlineColorExtended: Int = 58
    static let underlineColorDefault: Int  = 59
    static let fgBrightBase: Int     = 90   // 90–97: bright fg
    static let bgBrightBase: Int     = 100  // 100–107: bright bg
}

// MARK: - Underline Style

/// Underline rendering style, set via SGR 4 subparameters (4:0–4:5).
nonisolated enum UnderlineStyle: UInt8, Sendable {
    case none   = 0
    case single = 1
    case double = 2
    case curly  = 3
    case dotted = 4
    case dashed = 5
}

// MARK: - Standard 256-Color Palette

/// The standard 256-color palette with exact RGB values.
/// - Indices 0–7: standard colors
/// - Indices 8–15: bright/high-intensity colors
/// - Indices 16–231: 6×6×6 color cube
/// - Indices 232–255: 24-step grayscale ramp
nonisolated enum ColorPalette {

    /// RGB tuple type.
    typealias RGB = (r: UInt8, g: UInt8, b: UInt8)

    /// The complete 256-color palette. Access by index 0–255.
    static let colors: [RGB] = {
        var palette = [RGB]()
        palette.reserveCapacity(256)

        // 0–7: Standard colors (modern vibrant palette)
        palette.append((0x1A, 0x1A, 0x2E)) // 0: Black (dark navy)
        palette.append((0xFF, 0x5C, 0x57)) // 1: Red (coral red)
        palette.append((0x5A, 0xF7, 0x8E)) // 2: Green (mint green)
        palette.append((0xF3, 0xF9, 0x9D)) // 3: Yellow (warm yellow)
        palette.append((0x57, 0xC7, 0xFF)) // 4: Blue (sky blue)
        palette.append((0xFF, 0x6A, 0xC1)) // 5: Magenta (hot pink)
        palette.append((0x9A, 0xED, 0xFE)) // 6: Cyan (light cyan)
        palette.append((0xF1, 0xF1, 0xF0)) // 7: White (off-white)

        // 8–15: Bright colors (vivid variants)
        palette.append((0x68, 0x6D, 0x7C)) // 8: Bright Black (steel gray)
        palette.append((0xFF, 0x6E, 0x6E)) // 9: Bright Red
        palette.append((0x69, 0xFF, 0x94)) // 10: Bright Green
        palette.append((0xFF, 0xFC, 0x67)) // 11: Bright Yellow
        palette.append((0x6B, 0xCF, 0xFF)) // 12: Bright Blue
        palette.append((0xFF, 0x77, 0xC8)) // 13: Bright Magenta
        palette.append((0xC2, 0xF0, 0xFF)) // 14: Bright Cyan
        palette.append((0xFF, 0xFF, 0xFF)) // 15: Bright White

        // 16–231: 6×6×6 color cube
        // For each component: values are [0, 95, 135, 175, 215, 255]
        let cubeValues: [UInt8] = [0, 95, 135, 175, 215, 255]
        for r in 0..<6 {
            for g in 0..<6 {
                for b in 0..<6 {
                    palette.append((cubeValues[r], cubeValues[g], cubeValues[b]))
                }
            }
        }

        // 232–255: 24-step grayscale ramp
        // Values: 8, 18, 28, ..., 238
        for i in 0..<24 {
            let v = UInt8(8 + 10 * i)
            palette.append((v, v, v))
        }

        return palette
    }()

    /// Look up RGB values for a 256-color index.
    static func rgb(forIndex index: UInt8) -> RGB {
        return colors[Int(index)]
    }
}

// MARK: - OSC Command Numbers

/// Operating System Command numbers.
nonisolated enum OSCCommand {
    static let setTitleAndIcon: Int       = 0
    static let setIconName: Int           = 1
    static let setWindowTitle: Int        = 2
    static let setColorPalette: Int       = 4
    static let setWorkingDirectory: Int   = 7
    static let hyperlink: Int             = 8
    static let setForeground: Int         = 10
    static let setBackground: Int         = 11
    static let setCursorColor: Int        = 12
    static let clipboard: Int             = 52
    static let resetCursorColor: Int      = 112
    static let semanticPrompt: Int        = 133
}

// MARK: - Terminal Defaults

/// Default terminal configuration values.
nonisolated enum TerminalDefaults {
    static let columns: Int = 80
    static let rows: Int = 24
    static let tabInterval: Int = 8
    static let maxScrollbackLines: Int = 10_000
    static let defaultCursorStyle: CursorStyle = .block

    /// When true, bold + standard color (0–7) automatically brightens
    /// to the high-intensity variant (8–15) at render time.
    /// Matches traditional terminal behavior (xterm, iTerm2).
    /// Set to false for kitty/Alacritty-style bold-is-only-weight.
    /// Note: Only mutated during app setup, before any concurrent access.
    nonisolated(unsafe) static var boldIsBright: Bool = true

    /// Default tab stops: every 8 columns for a given column count.
    static func defaultTabStops(columns: Int) -> Set<Int> {
        var stops = Set<Int>()
        var col = tabInterval
        while col < columns {
            stops.insert(col)
            col += tabInterval
        }
        return stops
    }
}

// MARK: - Device Attributes Response

/// Standard device attributes response strings.
nonisolated enum DeviceAttributes {
    /// Primary DA response: VT220 with ANSI color.
    /// CSI ? 6 2 ; 2 2 c  (VT220, ANSI color)
    static let primaryResponse: [UInt8] = [
        0x1B, 0x5B, 0x3F, 0x36, 0x32, 0x3B, 0x32, 0x32, 0x63
        // ESC  [     ?     6     2     ;     2     2     c
    ]

    /// Secondary DA response: xterm version 279.
    /// CSI > 0 ; 2 7 9 ; 0 c
    static let secondaryResponse: [UInt8] = [
        0x1B, 0x5B, 0x3E, 0x30, 0x3B, 0x32, 0x37, 0x39, 0x3B, 0x30, 0x63
        // ESC  [     >     0     ;     2     7     9     ;     0     c
    ]

    /// DSR cursor position report prefix: CSI row ; col R
    /// Caller fills in the actual row and column values.
    static let dsrPrefix: [UInt8] = [0x1B, 0x5B]  // ESC [
    static let dsrSeparator: UInt8 = 0x3B          // ;
    static let dsrSuffix: UInt8 = 0x52             // R

    /// Terminal identification string for TERM environment variable.
    static let termType = "xterm-256color"
}

// MARK: - Parser Parameter Limits

/// Limits for the parser's parameter collection.
nonisolated enum ParserLimits {
    /// Maximum number of CSI parameters.
    static let maxParams: Int = 16

    /// Maximum value for a single parameter (prevents overflow).
    static let maxParamValue: Int = 16384

    /// Maximum number of intermediate bytes collected.
    static let maxIntermediates: Int = 2

    /// Maximum length of an OSC string.
    static let maxOSCLength: Int = 4096

    /// Maximum length of a DCS string.
    static let maxDCSLength: Int = 4096

    /// Default parameter value when omitted (most CSI commands treat 0 as 1).
    static let defaultParam: Int = 0
}
