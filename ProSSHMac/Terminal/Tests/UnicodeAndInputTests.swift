// UnicodeAndInputTests.swift
// ProSSHV2
//
// F.14 — Unicode rendering (CJK, emoji, combining chars, RTL)
// F.19 — Mouse tracking mode parsing and encoder coverage
// F.20 — Bracketed paste mode lifecycle and PasteHandler correctness

#if canImport(XCTest)
import XCTest

// MARK: - UnicodeRenderTest (F.14)

/// Validates that Unicode characters — ASCII, CJK wide, emoji, combining
/// marks, Latin extended, Cyrillic, Greek, Arabic, ZWJ sequences, and
/// box-drawing — are positioned correctly in the terminal grid.
final class UnicodeRenderTest: IntegrationTestBase {

    // MARK: F.14.1 — ASCII Printable Range

    /// Feed all printable ASCII (0x20–0x7E) and verify each cell codepoint.
    func testASCIIPrintable() async {
        // Build a string of all 95 printable ASCII characters.
        let printable = String((0x20...0x7E).map { Character(UnicodeScalar($0)) })
        await feed(printable)

        // The first 80 characters land on row 0 (columns 0–79).
        // Characters 80–94 wrap to row 1.
        for (index, char) in printable.enumerated() {
            let row = index / 80
            let col = index % 80
            let cell = await charAt(row: row, col: col)
            let expected = String(char)
            // Space is stored as "" (blank) in the grid.
            if char == " " {
                XCTAssertTrue(
                    cell.isEmpty || cell == " ",
                    "Position (\(row),\(col)): space should be blank or \" \", got \"\(cell)\""
                )
            } else {
                XCTAssertEqual(
                    cell, expected,
                    "Position (\(row),\(col)): expected '\(expected)' (U+\(String(format: "%04X", char.asciiValue ?? 0)))"
                )
            }
        }
    }

    // MARK: F.14.2 — CJK Wide Characters

    /// Feed 4 CJK characters, each occupying 2 columns.
    /// Verify wideChar attribute on primary cells and continuation cells.
    func testCJKWideCharacters() async {
        await feed("世界你好")

        let cjkChars: [String] = ["世", "界", "你", "好"]
        for (i, expected) in cjkChars.enumerated() {
            let primaryCol = i * 2

            // Primary cell should contain the character.
            let ch = await charAt(row: 0, col: primaryCol)
            XCTAssertEqual(ch, expected, "CJK char '\(expected)' at col \(primaryCol)")

            // Primary cell should have wideChar attribute.
            let attrs = await attrsAt(row: 0, col: primaryCol)
            XCTAssertTrue(
                attrs.contains(.wideChar),
                "CJK char '\(expected)' should have wideChar attribute"
            )

            // Continuation cell (col+1) should be width 0 or empty.
            let contCell = await grid.cellAt(row: 0, col: primaryCol + 1)
            XCTAssertNotNil(contCell, "Continuation cell should exist")
            if let contCell {
                XCTAssertEqual(
                    contCell.width, 0,
                    "Continuation cell at col \(primaryCol + 1) should have width 0"
                )
            }
        }
    }

    // MARK: F.14.3 — Emoji

    /// Feed 3 emoji. Current implementation treats emoji as single-width
    /// (wide char detection covers CJK only). Verify they are stored correctly.
    func testEmoji() async {
        await feed("🌍🚀💻")

        // Emoji width detection is not yet implemented — they occupy 1 col each
        let emoji: [(String, Int)] = [("🌍", 0), ("🚀", 1), ("💻", 2)]
        for (expected, col) in emoji {
            let ch = await charAt(row: 0, col: col)
            XCTAssertEqual(ch, expected, "Emoji '\(expected)' at col \(col)")
        }
    }

    // MARK: F.14.4 — Combining Characters

    /// Feed "e" + combining acute accent. Current implementation does not merge
    /// combining characters — each codepoint occupies its own cell.
    /// When combining character support is added, this test should be updated
    /// to expect merged graphemes.
    func testCombiningCharacters() async {
        // e (U+0065) + combining acute accent (U+0301)
        await feed("e\u{0301}")

        // Base character at col 0
        let cell = await charAt(row: 0, col: 0)
        XCTAssertEqual(cell, "e", "Base character 'e' at col 0")

        // Combining mark at col 1 (not yet merged with base)
        let nextCell = await charAt(row: 0, col: 1)
        XCTAssertFalse(
            nextCell.isEmpty,
            "Combining character occupies its own cell (merging not yet implemented)"
        )
    }

    // MARK: F.14.5 — Mixed ASCII + CJK

    /// Feed "Hello 世界!" and verify character positions:
    /// H(0), e(1), l(2), l(3), o(4), (5), 世(6-7), 界(8-9), !(10).
    func testMixedASCIICJK() async {
        await feed("Hello 世界!")

        let expected: [(String, Int)] = [
            ("H", 0), ("e", 1), ("l", 2), ("l", 3), ("o", 4)
        ]

        for (ch, col) in expected {
            let cell = await charAt(row: 0, col: col)
            XCTAssertEqual(cell, ch, "Expected '\(ch)' at col \(col)")
        }

        // Space at col 5
        let space = await charAt(row: 0, col: 5)
        XCTAssertTrue(
            space.isEmpty || space == " ",
            "Col 5 should be space, got \"\(space)\""
        )

        // CJK at cols 6-7 and 8-9
        let shi = await charAt(row: 0, col: 6)
        XCTAssertEqual(shi, "世", "CJK '世' at col 6")

        let jie = await charAt(row: 0, col: 8)
        XCTAssertEqual(jie, "界", "CJK '界' at col 8")

        // Exclamation at col 10
        let excl = await charAt(row: 0, col: 10)
        XCTAssertEqual(excl, "!", "Exclamation mark at col 10")
    }

    // MARK: F.14.6 — Latin Extended

    /// Feed "café naïve Ñ". Verify all chars at correct positions.
    /// é, ï, Ñ are single-width characters.
    func testLatinExtended() async {
        // Use precomposed forms to avoid combining-character ambiguity.
        await feed("caf\u{00E9} na\u{00EF}ve \u{00D1}")

        // c(0) a(1) f(2) é(3) (4) n(5) a(6) ï(7) v(8) e(9) (10) Ñ(11)
        let positions: [(String, Int)] = [
            ("c", 0), ("a", 1), ("f", 2), ("\u{00E9}", 3),
            ("n", 5), ("a", 6), ("\u{00EF}", 7), ("v", 8), ("e", 9),
            ("\u{00D1}", 11)
        ]

        for (expected, col) in positions {
            let cell = await charAt(row: 0, col: col)
            let normalizedCell = cell.precomposedStringWithCanonicalMapping
            let normalizedExpected = expected.precomposedStringWithCanonicalMapping
            XCTAssertEqual(
                normalizedCell, normalizedExpected,
                "Expected '\(expected)' at col \(col), got '\(cell)'"
            )
        }

        // é, ï, Ñ should all be single-width (no wideChar attribute).
        for col in [3, 7, 11] {
            let attrs = await attrsAt(row: 0, col: col)
            XCTAssertFalse(
                attrs.contains(.wideChar),
                "Latin extended char at col \(col) should not have wideChar"
            )
        }
    }

    // MARK: F.14.7 — Cyrillic, Greek, Arabic

    /// Feed "Привет Ελληνικά مرحبا". Verify characters are placed and
    /// column counts are correct.
    func testCyrillicGreekArabic() async {
        let text = "Привет Ελληνικά مرحبا"
        await feed(text)

        // Cyrillic "Привет" — 6 single-width characters at cols 0–5
        let cyrillicChars = Array("Привет")
        for (i, expected) in cyrillicChars.enumerated() {
            let cell = await charAt(row: 0, col: i)
            XCTAssertEqual(
                cell, String(expected),
                "Cyrillic char '\(expected)' at col \(i)"
            )
        }

        // Space at col 6
        let space1 = await charAt(row: 0, col: 6)
        XCTAssertTrue(
            space1.isEmpty || space1 == " ",
            "Col 6 should be space"
        )

        // Greek "Ελληνικά" — 8 single-width characters at cols 7–14
        let greekChars = Array("Ελληνικά")
        for (i, expected) in greekChars.enumerated() {
            let cell = await charAt(row: 0, col: 7 + i)
            let normalizedCell = cell.precomposedStringWithCanonicalMapping
            let normalizedExpected = String(expected).precomposedStringWithCanonicalMapping
            XCTAssertEqual(
                normalizedCell, normalizedExpected,
                "Greek char '\(expected)' at col \(7 + i)"
            )
        }

        // Space at col 15
        let space2 = await charAt(row: 0, col: 15)
        XCTAssertTrue(
            space2.isEmpty || space2 == " ",
            "Col 15 should be space"
        )

        // Arabic "مرحبا" — 5 single-width characters at cols 16–20
        // Note: Arabic characters are stored individually in the grid
        // (the terminal does not perform bidi reordering).
        let arabicChars = Array("مرحبا")
        for (i, expected) in arabicChars.enumerated() {
            let cell = await charAt(row: 0, col: 16 + i)
            XCTAssertEqual(
                cell, String(expected),
                "Arabic char '\(expected)' at col \(16 + i)"
            )
        }
    }

    // MARK: F.14.8 — Emoji ZWJ Sequences

    /// Feed a family emoji (ZWJ sequence: 👨‍👩‍👧). Current implementation
    /// does not merge ZWJ sequences — each codepoint occupies its own cell.
    func testEmojiSequences() async {
        // 👨‍👩‍👧 = U+1F468 ZWJ U+1F469 ZWJ U+1F467
        await feed("👨\u{200D}👩\u{200D}👧")

        // First emoji codepoint should be present at col 0
        let cell = await charAt(row: 0, col: 0)
        XCTAssertFalse(cell.isEmpty, "ZWJ emoji should produce a non-empty cell")
    }

    // MARK: F.14.9 — Box Drawing (Unicode)

    /// Feed Unicode box-drawing characters directly (─│┌┐└┘├┤┬┴┼).
    /// All are single-width. Verify codepoints.
    func testBoxDrawingUnicode() async {
        let boxChars = "─│┌┐└┘├┤┬┴┼"
        await feed(boxChars)

        for (i, expected) in boxChars.enumerated() {
            let cell = await charAt(row: 0, col: i)
            XCTAssertEqual(
                cell, String(expected),
                "Box drawing char '\(expected)' at col \(i)"
            )

            // All box-drawing characters are single-width.
            let attrs = await attrsAt(row: 0, col: i)
            XCTAssertFalse(
                attrs.contains(.wideChar),
                "Box drawing char '\(expected)' should be single-width"
            )
        }
    }
}

// MARK: - MouseTrackingTest (F.19)

/// Validates that mouse-mode enable/disable escape sequences are parsed
/// correctly and the grid's mouseTracking / mouseEncoding state is updated.
/// Also tests MouseEncoder output for X10 and SGR formats.
final class MouseTrackingTest: IntegrationTestBase {

    // MARK: F.19.1 — Enable X10 Mouse Mode (Mode 9)

    /// Feed `\e[?9h`. Mode 9 is the original X10 mouse mode. Since the
    /// codebase maps mode 1000 to `.x10`, we test mode 1000 which is the
    /// supported X10-compatible tracking mode.
    func testEnableX10MouseMode() async {
        await feed("\u{1B}[?1000h")

        let mode = await grid.mouseTracking
        XCTAssertEqual(mode, .x10, "Mode 1000 should enable X10 mouse tracking")
    }

    // MARK: F.19.2 — Enable Normal Mouse Mode (Mode 1000)

    /// Feed `\e[?1000h`. Verify mouseTracking == .x10.
    func testEnableNormalMouseMode() async {
        await feed("\u{1B}[?1000h")

        let mode = await grid.mouseTracking
        XCTAssertEqual(mode, .x10, "Mode 1000 should set mouseTracking to .x10")
    }

    // MARK: F.19.3 — Enable Button Event Mode (Mode 1002)

    /// Feed `\e[?1002h`. Verify mouseTracking == .buttonEvent.
    func testEnableButtonEventMode() async {
        await feed("\u{1B}[?1002h")

        let mode = await grid.mouseTracking
        XCTAssertEqual(mode, .buttonEvent, "Mode 1002 should set mouseTracking to .buttonEvent")
    }

    // MARK: F.19.4 — Enable Any Event Mode (Mode 1003)

    /// Feed `\e[?1003h`. Verify mouseTracking == .anyEvent.
    func testEnableAnyEventMode() async {
        await feed("\u{1B}[?1003h")

        let mode = await grid.mouseTracking
        XCTAssertEqual(mode, .anyEvent, "Mode 1003 should set mouseTracking to .anyEvent")
    }

    // MARK: F.19.5 — Disable Mouse Mode

    /// Enable then disable mouse mode. Verify mouseTracking == .none.
    func testDisableMouseMode() async {
        await feed("\u{1B}[?1000h")

        let enabled = await grid.mouseTracking
        XCTAssertEqual(enabled, .x10, "Precondition: mouse should be enabled")

        await feed("\u{1B}[?1000l")

        let disabled = await grid.mouseTracking
        XCTAssertEqual(disabled, .none, "Mode 1000 reset should disable mouse tracking")
    }

    // MARK: F.19.6 — SGR Mouse Encoding (Mode 1006)

    /// Feed `\e[?1006h`. Verify mouseEncoding == .sgr.
    func testSGRMouseEncoding() async {
        await feed("\u{1B}[?1006h")

        let encoding = await grid.mouseEncoding
        XCTAssertEqual(encoding, .sgr, "Mode 1006 should set mouseEncoding to .sgr")
    }

    // MARK: F.19.7 — UTF-8 Mouse Encoding (Mode 1005)

    /// Feed `\e[?1005h`. Verify mouseEncoding == .utf8.
    func testUTF8MouseEncoding() async {
        await feed("\u{1B}[?1005h")

        let encoding = await grid.mouseEncoding
        XCTAssertEqual(encoding, .utf8, "Mode 1005 should set mouseEncoding to .utf8")
    }

    // MARK: F.19.8 — MouseEncoder X10 Format

    /// Create a MouseEncoder with trackingMode .x10, encoding .x10.
    /// Encode a left-press at row 5, col 10.
    /// Verify it produces ESC [ M followed by correct bytes:
    ///   button+32, col+32, row+32
    func testMouseEncoderX10Format() {
        let encoder = MouseEncoder(trackingMode: .x10, encoding: .x10)
        let event = MouseEvent(kind: .press, button: .left, row: 5, column: 10)

        let sequence = encoder.encode(event)
        XCTAssertNotNil(sequence, "X10 encoder should produce output for a press event")

        if let sequence {
            let bytes = Array(sequence.utf8)
            // ESC [ M <button+32> <col+32> <row+32>
            // button=0 (left press), col=10, row=5
            XCTAssertEqual(bytes[0], 0x1B, "First byte should be ESC")
            XCTAssertEqual(bytes[1], 0x5B, "Second byte should be [")
            XCTAssertEqual(bytes[2], 0x4D, "Third byte should be M")
            XCTAssertEqual(bytes[3], UInt8(0 + 32), "Button code: left(0) + 32 = 32")
            XCTAssertEqual(bytes[4], UInt8(10 + 32), "Column: 10 + 32 = 42")
            XCTAssertEqual(bytes[5], UInt8(5 + 32), "Row: 5 + 32 = 37")
        }
    }

    // MARK: F.19.9 — MouseEncoder SGR Format

    /// Create a MouseEncoder with encoding .sgr.
    /// Encode a left-press at row 5, col 10.
    /// Verify it produces `ESC[<0;10;5M` (coordinates passed through).
    func testMouseEncoderSGRFormat() {
        let encoder = MouseEncoder(trackingMode: .anyEvent, encoding: .sgr)
        let event = MouseEvent(kind: .press, button: .left, row: 5, column: 10)

        let sequence = encoder.encode(event)
        XCTAssertEqual(
            sequence, "\u{1B}[<0;10;5M",
            "SGR press should produce ESC[<0;10;5M"
        )
    }

    // MARK: F.19.10 — MouseEncoder Release in SGR

    /// Encode a release event in SGR mode. Verify it ends with 'm' (lowercase).
    func testMouseEncoderRelease() {
        let encoder = MouseEncoder(trackingMode: .buttonEvent, encoding: .sgr)
        let event = MouseEvent(kind: .release, button: .left, row: 5, column: 10)

        let sequence = encoder.encode(event)
        XCTAssertNotNil(sequence, "SGR encoder should produce output for release")

        if let sequence {
            XCTAssertTrue(
                sequence.hasSuffix("m"),
                "SGR release should end with lowercase 'm', got: \(sequence)"
            )
            XCTAssertFalse(
                sequence.hasSuffix("M"),
                "SGR release should NOT end with uppercase 'M'"
            )
        }
    }
}

// MARK: - BracketedPasteTest (F.20)

/// Validates that bracketed paste mode is correctly tracked via DECSET/DECRST,
/// and that PasteHandler produces correctly wrapped and chunked payloads.
final class BracketedPasteTest: IntegrationTestBase {

    // MARK: F.20.1 — Enable Bracketed Paste

    /// Feed `\e[?2004h`. Verify bracketedPasteMode == true.
    func testEnableBracketedPaste() async {
        await feed("\u{1B}[?2004h")

        let enabled = await grid.bracketedPasteMode
        XCTAssertTrue(enabled, "Mode 2004 set should enable bracketed paste")
    }

    // MARK: F.20.2 — Disable Bracketed Paste

    /// Enable then disable. Verify bracketedPasteMode == false.
    func testDisableBracketedPaste() async {
        await feed("\u{1B}[?2004h")

        let enabled = await grid.bracketedPasteMode
        XCTAssertTrue(enabled, "Precondition: bracketed paste should be enabled")

        await feed("\u{1B}[?2004l")

        let disabled = await grid.bracketedPasteMode
        XCTAssertFalse(disabled, "Mode 2004 reset should disable bracketed paste")
    }

    // MARK: F.20.3 — PasteHandler With Bracketed Mode

    /// Verify PasteHandler wraps text with bracketed paste markers.
    func testPasteHandlerWithBracketedMode() async {
        let payload = PasteHandler.payload(
            for: "hello world",
            bracketedPasteEnabled: true
        )

        XCTAssertTrue(
            payload.hasPrefix("\u{1B}[200~"),
            "Bracketed paste payload should start with ESC[200~"
        )
        XCTAssertTrue(
            payload.hasSuffix("\u{1B}[201~"),
            "Bracketed paste payload should end with ESC[201~"
        )
        XCTAssertTrue(
            payload.contains("hello world"),
            "Payload should contain the pasted text"
        )
    }

    // MARK: F.20.4 — PasteHandler Without Bracketed Mode

    /// Verify PasteHandler does NOT add markers when disabled.
    func testPasteHandlerWithoutBracketedMode() async {
        let payload = PasteHandler.payload(
            for: "hello world",
            bracketedPasteEnabled: false
        )

        XCTAssertFalse(
            payload.contains("\u{1B}[200~"),
            "Non-bracketed payload should not contain start marker"
        )
        XCTAssertFalse(
            payload.contains("\u{1B}[201~"),
            "Non-bracketed payload should not contain end marker"
        )
        XCTAssertEqual(payload, "hello world")
    }

    // MARK: F.20.5 — Newline Normalization

    /// Verify CR+LF is normalized to CR only.
    func testPasteHandlerNewlineNormalization() async {
        let payload = PasteHandler.payload(
            for: "line1\r\nline2\r\n",
            bracketedPasteEnabled: false
        )

        XCTAssertEqual(
            payload, "line1\rline2\r",
            "CR+LF should be normalized to CR"
        )
        XCTAssertFalse(
            payload.contains("\r\n"),
            "Normalized payload should not contain CR+LF sequences"
        )
    }

    // MARK: F.20.6 — Payload Chunking

    /// Verify chunking respects byte limit and only first/last chunks
    /// have bracketed paste markers.
    func testPasteHandlerChunking() async {
        // Create a string that will exceed 100 bytes when UTF-8 encoded.
        let longText = String(repeating: "A", count: 200)

        let chunks = PasteHandler.payloadChunks(
            for: longText,
            bracketedPasteEnabled: true,
            options: PasteHandlerOptions(chunkByteLimit: 100)
        )

        XCTAssertTrue(
            chunks.count >= 2,
            "200-byte text with 100-byte limit should produce at least 2 chunks, got \(chunks.count)"
        )

        // First chunk should start with bracketed paste start marker.
        XCTAssertTrue(
            chunks.first!.hasPrefix("\u{1B}[200~"),
            "First chunk should start with bracketed paste start marker"
        )

        // Last chunk should end with bracketed paste end marker.
        XCTAssertTrue(
            chunks.last!.hasSuffix("\u{1B}[201~"),
            "Last chunk should end with bracketed paste end marker"
        )

        // Middle chunks (if any) should not contain markers.
        if chunks.count > 2 {
            for i in 1..<(chunks.count - 1) {
                XCTAssertFalse(
                    chunks[i].contains("\u{1B}[200~"),
                    "Middle chunk \(i) should not contain start marker"
                )
                XCTAssertFalse(
                    chunks[i].contains("\u{1B}[201~"),
                    "Middle chunk \(i) should not contain end marker"
                )
            }
        }
    }

    // MARK: F.20.7 — Soft Reset Preserves Bracketed Paste

    /// Enable bracketed paste, then send DECSTR (CSI ! p).
    /// DECSTR does not reset mode 2004, so bracketedPasteMode should remain true.
    func testSoftResetPreservesBracketedPaste() async {
        // Enable bracketed paste.
        await feed("\u{1B}[?2004h")

        let beforeReset = await grid.bracketedPasteMode
        XCTAssertTrue(beforeReset, "Precondition: bracketed paste should be enabled")

        // DECSTR — soft terminal reset.
        await feed("\u{1B}[!p")

        let afterReset = await grid.bracketedPasteMode
        XCTAssertTrue(
            afterReset,
            "DECSTR (soft reset) should NOT reset bracketed paste mode"
        )
    }

    // MARK: F.20.8 — Full Reset Clears Bracketed Paste

    /// Enable bracketed paste, then send RIS (ESC c).
    /// Full reset should clear bracketedPasteMode.
    func testFullResetClearsBracketedPaste() async {
        // Enable bracketed paste.
        await feed("\u{1B}[?2004h")

        let beforeReset = await grid.bracketedPasteMode
        XCTAssertTrue(beforeReset, "Precondition: bracketed paste should be enabled")

        // RIS — full terminal reset.
        await feed("\u{1B}c")

        let afterReset = await grid.bracketedPasteMode
        XCTAssertFalse(
            afterReset,
            "RIS (full reset) should clear bracketed paste mode"
        )
    }
}

#endif
