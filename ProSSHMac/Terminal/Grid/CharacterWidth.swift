// CharacterWidth.swift
// ProSSHV2
//
// Shared Unicode character width determination for the terminal grid and
// glyph rasterizer. Uses a conservative wcwidth-aligned table to classify
// codepoints as narrow (1 cell) or wide (2 cells).
//
// Classification rules (matching standard terminal behavior — xterm, iTerm2, VTE):
// - East Asian Width "W" (Wide) or "F" (Fullwidth) → 2 cells
// - East Asian Width "A" (Ambiguous) → 1 cell (narrow by default)
// - Only emoji/symbol codepoints widely treated as width=2 in modern
//   terminal wcwidth implementations are marked wide
// - Everything else → 1 cell
//
// This is the single source of truth for width determination. Both
// Character.isWideCharacter (TerminalGrid) and GlyphRasterizer delegate here.

import Foundation

// MARK: - CharacterWidth

nonisolated enum CharacterWidth {

    // MARK: - Public API

    /// Returns true if the given Unicode scalar should occupy 2 terminal cells.
    @inline(__always)
    static func isWide(_ scalar: UnicodeScalar) -> Bool {
        let v = scalar.value

        // Fast path: ASCII, Latin-1, and most BMP characters below CJK are narrow.
        if v < 0x1100 { return false }

        // --- East Asian Width "W" and "F" ranges (CJK, Hangul, Fullwidth) ---

        // Hangul Jamo (leading consonants — wide per Unicode EAW)
        if (0x1100...0x115F).contains(v) { return true }
        // Hangul Jamo Extended-A
        if (0xA960...0xA97C).contains(v) { return true }
        // CJK Radicals Supplement, Kangxi Radicals
        if (0x2E80...0x2FDF).contains(v) { return true }
        // Ideographic Description Characters, CJK Symbols and Punctuation
        if (0x2FF0...0x303F).contains(v) { return true }
        // Hiragana, Katakana
        if (0x3040...0x30FF).contains(v) { return true }
        // Bopomofo
        if (0x3100...0x312F).contains(v) { return true }
        // Hangul Compatibility Jamo
        if (0x3130...0x318F).contains(v) { return true }
        // Kanbun, Bopomofo Extended
        if (0x3190...0x31BF).contains(v) { return true }
        // CJK Strokes, Katakana Phonetic Extensions
        if (0x31C0...0x31FF).contains(v) { return true }
        // Enclosed CJK Letters and Months, CJK Compatibility
        if (0x3200...0x33FF).contains(v) { return true }
        // CJK Unified Ideographs Extension A
        if (0x3400...0x4DBF).contains(v) { return true }
        // CJK Unified Ideographs
        if (0x4E00...0x9FFF).contains(v) { return true }
        // Yi Syllables, Yi Radicals
        if (0xA000...0xA4CF).contains(v) { return true }
        // Hangul Syllables
        if (0xAC00...0xD7AF).contains(v) { return true }
        // CJK Compatibility Ideographs
        if (0xF900...0xFAFF).contains(v) { return true }
        // Fullwidth Forms (FF01-FF60: fullwidth ASCII variants)
        if (0xFF01...0xFF60).contains(v) { return true }
        // Fullwidth Forms (FFE0-FFE6: fullwidth symbol variants)
        if (0xFFE0...0xFFE6).contains(v) { return true }
        // CJK Unified Ideographs Extension B through Extension F, CJK Compat Supplement
        if (0x20000...0x2FA1F).contains(v) { return true }
        // CJK Unified Ideographs Extension G
        if (0x30000...0x3134F).contains(v) { return true }

        // --- Emoji and symbol codepoints treated as width=2 by wcwidth ---

        // Watch, Hourglass
        if v == 0x231A || v == 0x231B { return true }
        // Media controls (subset with width=2 in modern wcwidth tables)
        if (0x23E9...0x23EC).contains(v) { return true }
        if v == 0x23F0 || v == 0x23F3 { return true }
        // Medium small squares
        if v == 0x25FD || v == 0x25FE { return true }

        // Misc Symbols (U+2600-U+26FF) and Dingbats (U+2700-U+27BF):
        // Only wcwidth-wide codepoints are wide.
        // Everything else in this range is narrow (1 cell).
        if (0x2600...0x27BF).contains(v) {
            return binarySearch(wideMiscAndDingbatScalars, v)
        }

        // Large squares
        if v == 0x2B1B || v == 0x2B1C { return true }
        // Star
        if v == 0x2B50 { return true }
        // Heavy large circle
        if v == 0x2B55 { return true }
        // Coptic Epact Numbers (narrow, skip)
        // Mahjong Tiles, Playing Cards
        if v == 0x1F004 || v == 0x1F0CF { return true }
        // Enclosed Alphanumeric Supplement (subset with width=2)
        if v == 0x1F18E { return true }
        if (0x1F191...0x1F19A).contains(v) { return true }
        // Regional Indicator Symbols (flags)
        if (0x1F1E0...0x1F1FF).contains(v) { return true }
        // Enclosed Ideographic Supplement
        if (0x1F200...0x1F251).contains(v) { return true }
        // Miscellaneous Symbols and Pictographs
        if (0x1F300...0x1F5FF).contains(v) { return true }
        // Emoticons
        if (0x1F600...0x1F64F).contains(v) { return true }
        // Ornamental Dingbats
        if (0x1F650...0x1F67F).contains(v) { return true }
        // Transport and Map Symbols
        if (0x1F680...0x1F6FF).contains(v) { return true }
        // Supplemental Symbols and Pictographs
        if (0x1F900...0x1F9FF).contains(v) { return true }
        // Chess Symbols
        if (0x1FA00...0x1FA6F).contains(v) { return true }
        // Symbols and Pictographs Extended-A
        if (0x1FA70...0x1FAFF).contains(v) { return true }

        return false
    }

    // MARK: - wcwidth-Wide in Misc Symbols & Dingbats (U+2600–U+27BF)

    /// Sorted array of codepoints in U+2600..U+27BF that are width=2 in
    /// mainstream terminal wcwidth tables.
    private static let wideMiscAndDingbatScalars: [UInt32] = [
        0x2614, 0x2615,                         // ☔☕
        0x2648, 0x2649, 0x264A, 0x264B,         // ♈♉♊♋
        0x264C, 0x264D, 0x264E, 0x264F,         // ♌♍♎♏
        0x2650, 0x2651, 0x2652, 0x2653,         // ♐♑♒♓
        0x267F,                                  // ♿
        0x2693,                                  // ⚓
        0x26A1,                                  // ⚡
        0x26AA, 0x26AB,                          // ⚪⚫
        0x26BD, 0x26BE,                          // ⚽⚾
        0x26C4, 0x26C5,                          // ⛄⛅
        0x26CE,                                  // ⛎
        0x26D4,                                  // ⛔
        0x26EA,                                  // ⛪
        0x26F2, 0x26F3,                          // ⛲⛳
        0x26F5,                                  // ⛵
        0x26FA,                                  // ⛺
        0x26FD,                                  // ⛽
        0x2705,                                  // ✅
        0x270A, 0x270B,                          // ✊✋
        0x2728,                                  // ✨
        0x274C,                                  // ❌
        0x274E,                                  // ❎
        0x2753, 0x2754, 0x2755,                  // ❓❔❕
        0x2757,                                  // ❗
        0x2795, 0x2796, 0x2797,                  // ➕➖➗
        0x27B0,                                  // ➰
        0x27BF,                                  // ➿
    ]

    // MARK: - Binary Search

    /// Binary search a sorted UInt32 array. Returns true if value is found.
    @inline(__always)
    private static func binarySearch(_ sortedArray: [UInt32], _ value: UInt32) -> Bool {
        var lo = 0
        var hi = sortedArray.count - 1
        while lo <= hi {
            let mid = (lo + hi) >> 1
            let midVal = sortedArray[mid]
            if midVal == value { return true }
            if midVal < value { lo = mid + 1 }
            else { hi = mid - 1 }
        }
        return false
    }
}
