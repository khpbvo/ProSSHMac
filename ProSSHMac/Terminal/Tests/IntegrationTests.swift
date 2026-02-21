// IntegrationTests.swift
// ProSSHV2
//
// A.18 — Integration tests with captured htop/vim/Cisco/color output.
// These tests feed realistic escape sequences through VTParser → TerminalGrid
// and verify the resulting grid state matches expectations.
//
// The byte sequences replicate the kind of output produced by real programs:
// - htop: alternate screen, color bars, status line, scroll regions
// - vim: alternate screen, syntax highlighting, status/command line
// - Cisco IOS: DEC Special Graphics line drawing, show command output
// - 256-color / truecolor: palette gradients, SGR attribute rendering

#if canImport(XCTest)
import XCTest

// MARK: - Integration Test Base

class IntegrationTestBase: XCTestCase {

    var engine: TerminalEngine!
    var grid: TerminalGrid!
    var responses: [[UInt8]]!

    override func setUp() async throws {
        engine = TerminalEngine(columns: 80, rows: 24)
        grid = await engine.grid
        responses = []

        await engine.setResponseHandler { @Sendable [weak self] bytes in
            self?.responses.append(bytes)
        }
    }

    // MARK: - Helpers

    /// Feed a string as UTF-8 bytes into the parser.
    func feed(_ string: String) async {
        await engine.feed(Array(string.utf8))
    }

    /// Feed raw bytes into the parser.
    func feedBytes(_ bytes: [UInt8]) async {
        await engine.feed(bytes)
    }

    /// Read the character at a grid position.
    func charAt(row: Int, col: Int) async -> String {
        let cell = await grid.cellAt(row: row, col: col)
        return cell?.graphemeCluster ?? ""
    }

    /// Read the foreground color at a grid position.
    func fgAt(row: Int, col: Int) async -> TerminalColor {
        let cell = await grid.cellAt(row: row, col: col)
        return cell?.fgColor ?? .default
    }

    /// Read the background color at a grid position.
    func bgAt(row: Int, col: Int) async -> TerminalColor {
        let cell = await grid.cellAt(row: row, col: col)
        return cell?.bgColor ?? .default
    }

    /// Read the attributes at a grid position.
    func attrsAt(row: Int, col: Int) async -> CellAttributes {
        let cell = await grid.cellAt(row: row, col: col)
        return cell?.attributes ?? []
    }

    /// Read a string from a row spanning columns [startCol, endCol).
    func rowText(row: Int, startCol: Int = 0, endCol: Int? = nil) async -> String {
        let cols = await grid.columns
        let end = endCol ?? cols
        var result = ""
        for col in startCol..<end {
            let ch = await charAt(row: row, col: col)
            result += ch.isEmpty ? " " : ch
        }
        return result
    }
}

// MARK: - HTOPRenderTest

/// Simulates htop-like output: alternate screen switch, colored process bars,
/// status header with CPU/memory bars, process list with colors, scrolling content.
final class HTOPRenderTest: IntegrationTestBase {

    /// htop switches to alternate screen on startup.
    func testAlternateScreenSwitch() async {
        // Print some text on primary screen first
        await feed("primary content\r\n")

        // htop sends: CSI ?1049h (save cursor + switch to alt buffer + clear)
        await feed("\u{1B}[?1049h")

        let usingAlt = await grid.usingAlternateBuffer
        XCTAssertTrue(usingAlt, "htop should switch to alternate screen buffer")

        // Primary content should not be visible on alternate screen
        let firstChar = await charAt(row: 0, col: 0)
        XCTAssertNotEqual(firstChar, "p", "Alternate screen should be clear, not showing primary content")
    }

    /// htop renders a colored CPU usage bar at the top.
    func testCPUUsageBars() async {
        await feed("\u{1B}[?1049h") // Switch to alt screen

        // Simulate htop CPU bar: "  1[||||||||||||     25.0%]"
        // htop uses: cursor positioning, bold, colored bars
        await feed("\u{1B}[1;1H")        // Move to row 1, col 1
        await feed("\u{1B}[1m")           // Bold
        await feed("\u{1B}[34m")          // Blue foreground
        await feed("  1")                 // CPU number
        await feed("\u{1B}[0m")           // Reset
        await feed("[")
        await feed("\u{1B}[32m")          // Green
        await feed("||||||||||||")        // Usage bars
        await feed("\u{1B}[0m")           // Reset
        await feed("     ")
        await feed("\u{1B}[1m")           // Bold
        await feed("25.0%")
        await feed("\u{1B}[0m")           // Reset
        await feed("]")

        // Verify CPU number
        let cpu = await rowText(row: 0, startCol: 2, endCol: 3)
        XCTAssertEqual(cpu, "1")

        // Verify bar characters exist
        let bars = await rowText(row: 0, startCol: 4, endCol: 16)
        XCTAssertTrue(bars.contains("|"), "CPU bar should contain pipe characters")

        // Verify percentage
        let pct = await rowText(row: 0, startCol: 21, endCol: 26)
        XCTAssertEqual(pct, "25.0%")
    }

    /// htop renders a memory usage bar with color-coded segments.
    func testMemoryBar() async {
        await feed("\u{1B}[?1049h")
        await feed("\u{1B}[2;1H")         // Row 2

        // Memory: "Mem[|||||||||||||||     2.00G/7.78G]"
        await feed("Mem")
        await feed("[")
        await feed("\u{1B}[32m")           // Green = used
        await feed("|||||||||||")
        await feed("\u{1B}[36m")           // Cyan = buffers
        await feed("||||")
        await feed("\u{1B}[0m")
        await feed("     2.00G/7.78G")
        await feed("]")

        // Verify "Mem" label
        let label = await rowText(row: 1, startCol: 0, endCol: 3)
        XCTAssertEqual(label, "Mem")

        // Verify green bars have correct fg color
        let barFg = await fgAt(row: 1, col: 4)
        XCTAssertEqual(barFg, .indexed(2), "Green bars should have indexed color 2")

        // Verify cyan segment
        let cyanFg = await fgAt(row: 1, col: 15)
        XCTAssertEqual(cyanFg, .indexed(6), "Cyan segment should have indexed color 6")
    }

    /// htop renders a process list with PID, USER, CPU%, etc.
    func testProcessListHeader() async {
        await feed("\u{1B}[?1049h")

        // htop header: reverse video, bold
        await feed("\u{1B}[4;1H")          // Row 4
        await feed("\u{1B}[7m")             // Reverse video
        await feed("\u{1B}[1m")             // Bold
        await feed("  PID USER      PRI  NI  VIRT   RES   SHR S CPU%  MEM%   TIME+  Command")
        await feed("\u{1B}[0m")

        // Verify header text
        let header = await rowText(row: 3, startCol: 2, endCol: 5)
        XCTAssertEqual(header, "PID")

        // Verify reverse attribute on header
        let attrs = await attrsAt(row: 3, col: 2)
        XCTAssertTrue(attrs.contains(.reverse), "Header should have reverse video attribute")
        XCTAssertTrue(attrs.contains(.bold), "Header should have bold attribute")
    }

    /// htop uses a scroll region for the process list area.
    func testProcessListScrollRegion() async {
        await feed("\u{1B}[?1049h")

        // Set scroll region to rows 5–22 (process list area)
        await feed("\u{1B}[5;22r")

        let scrollTop = await grid.scrollTop
        let scrollBottom = await grid.scrollBottom
        XCTAssertEqual(scrollTop, 4, "Scroll top should be row 4 (0-indexed)")
        XCTAssertEqual(scrollBottom, 21, "Scroll bottom should be row 21 (0-indexed)")
    }

    /// htop shows a status line at the bottom (F1 Help, F2 Setup, etc.).
    func testStatusLine() async {
        await feed("\u{1B}[?1049h")

        // htop status: move to last row, colored function key labels
        await feed("\u{1B}[24;1H")         // Row 24 (last row)
        await feed("\u{1B}[30;46m")         // Black on cyan
        await feed("F1")
        await feed("\u{1B}[0m")
        await feed("Help ")
        await feed("\u{1B}[30;46m")
        await feed("F2")
        await feed("\u{1B}[0m")
        await feed("Setup")

        // Verify F1 label
        let f1 = await rowText(row: 23, startCol: 0, endCol: 2)
        XCTAssertEqual(f1, "F1")

        // Verify F1 has black-on-cyan colors
        let fg = await fgAt(row: 23, col: 0)
        let bg = await bgAt(row: 23, col: 0)
        XCTAssertEqual(fg, .indexed(0), "F1 should have black foreground")
        XCTAssertEqual(bg, .indexed(6), "F1 should have cyan background")

        // Verify "Help" text follows
        let help = await rowText(row: 23, startCol: 2, endCol: 7)
        XCTAssertEqual(help, "Help ")
    }

    /// htop restores primary screen on exit.
    func testRestorePrimaryOnExit() async {
        // Set up primary content
        await feed("primary> ")

        // Enter alt screen (htop startup)
        await feed("\u{1B}[?1049h")
        await feed("\u{1B}[1;1H")
        await feed("htop content")

        // Exit alt screen (htop exit): CSI ?1049l
        await feed("\u{1B}[?1049l")

        let usingAlt = await grid.usingAlternateBuffer
        XCTAssertFalse(usingAlt, "Should return to primary buffer on exit")

        // Primary content should be restored
        let firstChar = await charAt(row: 0, col: 0)
        XCTAssertEqual(firstChar, "p", "Primary screen content should be restored")
    }
}

// MARK: - VimRenderTest

/// Simulates vim-like output: alternate screen, syntax highlighting, mode line,
/// cursor positioning, and status bar.
final class VimRenderTest: IntegrationTestBase {

    /// vim switches to alternate screen and clears it.
    func testVimStartupAlternateScreen() async {
        // vim sends: save cursor, switch to alt screen, clear screen
        await feed("\u{1B}7")              // DECSC (save cursor)
        await feed("\u{1B}[?1049h")        // Alt screen
        await feed("\u{1B}[2J")            // Clear entire screen
        await feed("\u{1B}[1;1H")          // Home cursor

        let usingAlt = await grid.usingAlternateBuffer
        XCTAssertTrue(usingAlt, "vim should be on alternate screen")

        let cursorRow = await grid.cursor.row
        let cursorCol = await grid.cursor.col
        XCTAssertEqual(cursorRow, 0, "Cursor should be at row 0")
        XCTAssertEqual(cursorCol, 0, "Cursor should be at col 0")
    }

    /// vim draws tilde lines (~) for empty buffer lines.
    func testTildeLines() async {
        await feed("\u{1B}[?1049h")
        await feed("\u{1B}[2J")
        await feed("\u{1B}[1;1H")

        // vim draws ~ at the start of each empty line
        for row in 1...23 {
            await feed("\u{1B}[\(row + 1);1H")   // Position cursor
            await feed("\u{1B}[34m")               // Blue foreground
            await feed("~")
            await feed("\u{1B}[0m")
        }

        // Verify tildes
        for row in 1...23 {
            let ch = await charAt(row: row, col: 0)
            XCTAssertEqual(ch, "~", "Row \(row) should have tilde")

            let fg = await fgAt(row: row, col: 0)
            XCTAssertEqual(fg, .indexed(4), "Tildes should be blue (indexed 4)")
        }
    }

    /// vim renders syntax-highlighted code.
    func testSyntaxHighlightedCode() async {
        await feed("\u{1B}[?1049h")
        await feed("\u{1B}[2J")
        await feed("\u{1B}[1;1H")

        // Simulate: `func main() {`
        // "func" is keyword (yellow), "main" is function name (green), rest default
        await feed("\u{1B}[33m")           // Yellow
        await feed("func")
        await feed("\u{1B}[0m")
        await feed(" ")
        await feed("\u{1B}[32m")           // Green
        await feed("main")
        await feed("\u{1B}[0m")
        await feed("() {")

        // Line 2: `    return 0`
        await feed("\u{1B}[2;1H")
        await feed("    ")
        await feed("\u{1B}[33m")           // Yellow
        await feed("return")
        await feed("\u{1B}[0m")
        await feed(" ")
        await feed("\u{1B}[35m")           // Magenta (number literal)
        await feed("0")
        await feed("\u{1B}[0m")

        // Verify "func" is yellow
        let funcFg = await fgAt(row: 0, col: 0)
        XCTAssertEqual(funcFg, .indexed(3), "Keyword 'func' should be yellow")

        let funcText = await rowText(row: 0, startCol: 0, endCol: 4)
        XCTAssertEqual(funcText, "func")

        // Verify "main" is green
        let mainFg = await fgAt(row: 0, col: 5)
        XCTAssertEqual(mainFg, .indexed(2), "Function 'main' should be green")

        // Verify "return" is yellow
        let retFg = await fgAt(row: 1, col: 4)
        XCTAssertEqual(retFg, .indexed(3), "Keyword 'return' should be yellow")

        // Verify "0" is magenta
        let numFg = await fgAt(row: 1, col: 11)
        XCTAssertEqual(numFg, .indexed(5), "Number literal should be magenta")
    }

    /// vim renders a status line with filename, position, and mode.
    func testVimStatusLine() async {
        await feed("\u{1B}[?1049h")
        await feed("\u{1B}[2J")

        // vim status line (row 24): reverse video
        await feed("\u{1B}[24;1H")
        await feed("\u{1B}[7m")            // Reverse video
        await feed("\"main.c\" 42L, 1234B")
        // Pad to end of line
        for _ in 0..<60 {
            await feed(" ")
        }
        await feed("\u{1B}[0m")

        // Verify status line content
        let filename = await rowText(row: 23, startCol: 0, endCol: 8)
        XCTAssertEqual(filename, "\"main.c\"")

        // Verify reverse video
        let attrs = await attrsAt(row: 23, col: 0)
        XCTAssertTrue(attrs.contains(.reverse), "Status line should have reverse video")
    }

    /// vim cursor positioning during editing.
    func testVimCursorMovement() async {
        await feed("\u{1B}[?1049h")
        await feed("\u{1B}[2J")

        // Write some lines
        await feed("\u{1B}[1;1H")
        await feed("Line one")
        await feed("\u{1B}[2;1H")
        await feed("Line two")
        await feed("\u{1B}[3;1H")
        await feed("Line three")

        // vim positions cursor at row 2, col 6 (in "two")
        await feed("\u{1B}[2;6H")

        let cursorRow = await grid.cursor.row
        let cursorCol = await grid.cursor.col
        XCTAssertEqual(cursorRow, 1, "Cursor should be at row 1 (0-indexed)")
        XCTAssertEqual(cursorCol, 5, "Cursor should be at col 5 (0-indexed)")
    }

    /// vim enables application cursor keys mode.
    func testVimApplicationCursorKeys() async {
        // vim sends DECCKM (application cursor keys) on startup
        await feed("\u{1B}[?1h")

        let appCursor = await grid.applicationCursorKeys
        XCTAssertTrue(appCursor, "vim should enable application cursor keys")
    }

    /// vim exit: restore cursor, switch back to primary screen.
    func testVimExit() async {
        // Set up primary screen
        await feed("shell$ ")

        // vim startup
        await feed("\u{1B}7")              // Save cursor
        await feed("\u{1B}[?1049h")
        await feed("vim content")

        // vim exit
        await feed("\u{1B}[?1049l")        // Restore alt screen
        await feed("\u{1B}8")              // Restore cursor (DECRC)

        let usingAlt = await grid.usingAlternateBuffer
        XCTAssertFalse(usingAlt, "Should be back on primary screen")

        // Check primary content preserved
        let shell = await rowText(row: 0, startCol: 0, endCol: 7)
        XCTAssertEqual(shell, "shell$ ")
    }
}

// MARK: - CiscoIOSRenderTest

/// Simulates Cisco IOS output: DEC Special Graphics line drawing characters,
/// show command output with table borders, and banner messages.
final class CiscoIOSRenderTest: IntegrationTestBase {

    /// Cisco IOS draws box-drawing borders using DEC Special Graphics.
    func testDECSpecialGraphicsBoxDrawing() async {
        // ESC ( 0 — Designate G0 as DEC Special Graphics
        // Then draw a box: lqqk / x  x / mqqj
        // l=┌, q=─, k=┐, x=│, m=└, j=┘

        await feed("\u{1B}[1;1H")

        // Top border: ┌──┐
        await feed("\u{1B}(0")             // Switch G0 to DEC Special Graphics
        await feed("lqqk")                 // l=┌, q=─, k=┐
        await feed("\u{1B}(B")             // Switch back to ASCII

        // Verify line drawing characters
        let topLeft = await charAt(row: 0, col: 0)
        XCTAssertEqual(topLeft, "┌", "DEC 'l' should map to ┌")

        let horiz = await charAt(row: 0, col: 1)
        XCTAssertEqual(horiz, "─", "DEC 'q' should map to ─")

        let topRight = await charAt(row: 0, col: 3)
        XCTAssertEqual(topRight, "┐", "DEC 'k' should map to ┐")
    }

    /// Cisco IOS draws complete box-drawing table borders.
    func testFullBoxTable() async {
        // Draw a full box:
        // ┌──┬──┐
        // │  │  │
        // ├──┼──┤
        // │  │  │
        // └──┴──┘

        // Top row
        await feed("\u{1B}[1;1H")
        await feed("\u{1B}(0")
        await feed("lqqwqqk")              // ┌──┬──┐
        await feed("\u{1B}(B")

        // Row 2: │  │  │
        await feed("\u{1B}[2;1H")
        await feed("\u{1B}(0")
        await feed("x")                    // │
        await feed("\u{1B}(B")
        await feed("  ")
        await feed("\u{1B}(0")
        await feed("x")                    // │
        await feed("\u{1B}(B")
        await feed("  ")
        await feed("\u{1B}(0")
        await feed("x")                    // │
        await feed("\u{1B}(B")

        // Divider: ├──┼──┤
        await feed("\u{1B}[3;1H")
        await feed("\u{1B}(0")
        await feed("tqqnqqu")              // ├──┼──┤
        await feed("\u{1B}(B")

        // Row 4: │  │  │
        await feed("\u{1B}[4;1H")
        await feed("\u{1B}(0")
        await feed("x")
        await feed("\u{1B}(B")
        await feed("  ")
        await feed("\u{1B}(0")
        await feed("x")
        await feed("\u{1B}(B")
        await feed("  ")
        await feed("\u{1B}(0")
        await feed("x")
        await feed("\u{1B}(B")

        // Bottom: └──┴──┘
        await feed("\u{1B}[5;1H")
        await feed("\u{1B}(0")
        await feed("mqqvqqj")              // └──┴──┘
        await feed("\u{1B}(B")

        // Verify top-left corner
        let tl = await charAt(row: 0, col: 0)
        XCTAssertEqual(tl, "┌")

        // Verify T-junction
        let tJunction = await charAt(row: 0, col: 3)
        XCTAssertEqual(tJunction, "┬")

        // Verify cross junction
        let cross = await charAt(row: 2, col: 3)
        XCTAssertEqual(cross, "┼")

        // Verify left T
        let leftT = await charAt(row: 2, col: 0)
        XCTAssertEqual(leftT, "├")

        // Verify right T
        let rightT = await charAt(row: 2, col: 6)
        XCTAssertEqual(rightT, "┤")

        // Verify bottom-left
        let bl = await charAt(row: 4, col: 0)
        XCTAssertEqual(bl, "└")

        // Verify bottom T
        let bottomT = await charAt(row: 4, col: 3)
        XCTAssertEqual(bottomT, "┴")

        // Verify bottom-right
        let br = await charAt(row: 4, col: 6)
        XCTAssertEqual(br, "┘")

        // Verify vertical line
        let vert = await charAt(row: 1, col: 0)
        XCTAssertEqual(vert, "│")
    }

    /// Cisco "show interfaces" output with status headers.
    func testShowInterfacesOutput() async {
        // Typical Cisco IOS "show ip interface brief"
        let output = """
        \u{1B}[1;1H\u{1B}[2JRouter#show ip interface brief\r
        Interface              IP-Address      OK? Method Status                Protocol\r
        GigabitEthernet0/0     192.168.1.1     YES manual up                    up\r
        GigabitEthernet0/1     10.0.0.1        YES manual up                    up\r
        Loopback0              1.1.1.1         YES manual up                    up\r
        Serial0/0/0            unassigned      YES unset  administratively down down\r
        Router#
        """

        await feed(output)

        // Verify "Router#" prompt
        let prompt = await rowText(row: 0, startCol: 0, endCol: 7)
        XCTAssertEqual(prompt, "Router#")

        // Verify interface name in output
        let iface = await rowText(row: 2, startCol: 0, endCol: 20)
        XCTAssertTrue(iface.contains("GigabitEthernet0/0"), "Should show interface name")
    }

    /// Cisco banner motd with line drawing border.
    func testBannerWithLineDrawing() async {
        // Cisco sometimes uses DEC line drawing in banner
        await feed("\u{1B}[2J\u{1B}[1;1H")

        // Draw a banner border
        await feed("\u{1B}(0")
        // Top border: 30 chars wide
        await feed("l")
        for _ in 0..<28 { await feed("q") }
        await feed("k")
        await feed("\u{1B}(B")

        await feed("\r\n")

        // Content line with vertical bars
        await feed("\u{1B}(0")
        await feed("x")
        await feed("\u{1B}(B")
        await feed("  Authorized Access Only!  ")
        await feed("\u{1B}(0")
        await feed("x")
        await feed("\u{1B}(B")

        await feed("\r\n")

        // Bottom border
        await feed("\u{1B}(0")
        await feed("m")
        for _ in 0..<28 { await feed("q") }
        await feed("j")
        await feed("\u{1B}(B")

        // Verify corners
        let topLeft = await charAt(row: 0, col: 0)
        XCTAssertEqual(topLeft, "┌")

        let topRight = await charAt(row: 0, col: 29)
        XCTAssertEqual(topRight, "┐")

        let bottomLeft = await charAt(row: 2, col: 0)
        XCTAssertEqual(bottomLeft, "└")

        let bottomRight = await charAt(row: 2, col: 29)
        XCTAssertEqual(bottomRight, "┘")

        // Verify message content
        let msg = await rowText(row: 1, startCol: 3, endCol: 27)
        XCTAssertTrue(msg.contains("Authorized Access Only"), "Banner should contain message text")
    }

    /// Charset invocation via SO/SI (Shift Out / Shift In).
    func testShiftOutShiftIn() async {
        // Some Cisco devices use SO (0x0E) to invoke G1 charset
        // and SI (0x0F) to go back to G0

        // First, designate G1 as DEC Special Graphics
        await feed("\u{1B})0")             // ESC ) 0 — G1 = DEC Special Graphics

        await feed("A")                   // ASCII 'A' (G0 active = ASCII)

        // Shift Out — activate G1
        await feedBytes([0x0E])
        await feed("q")                   // Should be ─ (DEC Special Graphics)

        // Shift In — back to G0
        await feedBytes([0x0F])
        await feed("B")                   // ASCII 'B'

        let a = await charAt(row: 0, col: 0)
        XCTAssertEqual(a, "A", "Before SO, should print ASCII")

        let line = await charAt(row: 0, col: 1)
        XCTAssertEqual(line, "─", "After SO, G1 (DEC Special Graphics) should map 'q' to ─")

        let b = await charAt(row: 0, col: 2)
        XCTAssertEqual(b, "B", "After SI, should print ASCII again")
    }
}

// MARK: - ColorRenderTest

/// Tests 256-color palette and truecolor rendering through the full parser → grid pipeline.
final class ColorRenderTest: IntegrationTestBase {

    /// Standard 8 colors (SGR 30–37 foreground).
    func testStandardForegroundColors() async {
        let colorNames = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]

        for i in 0..<8 {
            await feed("\u{1B}[\(30 + i)m")
            await feed("\(colorNames[i].prefix(1))")
            await feed("\u{1B}[0m")
        }

        // Verify each character has the correct indexed foreground color
        for i in 0..<8 {
            let fg = await fgAt(row: 0, col: i)
            XCTAssertEqual(fg, .indexed(UInt8(i)), "Color index \(i) should be set correctly")
        }
    }

    /// Standard 8 colors (SGR 40–47 background).
    func testStandardBackgroundColors() async {
        for i in 0..<8 {
            await feed("\u{1B}[\(40 + i)m")
            await feed(" ")
            await feed("\u{1B}[0m")
        }

        for i in 0..<8 {
            let bg = await bgAt(row: 0, col: i)
            XCTAssertEqual(bg, .indexed(UInt8(i)), "Background color index \(i) should be set")
        }
    }

    /// Bright/high-intensity colors (SGR 90–97 fg, 100–107 bg).
    func testBrightColors() async {
        // Bright foreground
        for i in 0..<8 {
            await feed("\u{1B}[\(90 + i)m")
            await feed("X")
            await feed("\u{1B}[0m")
        }

        for i in 0..<8 {
            let fg = await fgAt(row: 0, col: i)
            XCTAssertEqual(fg, .indexed(UInt8(8 + i)), "Bright fg \(i) should map to index \(8 + i)")
        }
    }

    /// 256-color mode: SGR 38;5;N (foreground) for the full palette.
    func testFull256ColorForeground() async {
        // Test a selection of colors across the palette
        let testIndices: [UInt8] = [0, 1, 15, 16, 51, 87, 124, 196, 231, 232, 244, 255]

        for (i, idx) in testIndices.enumerated() {
            await feed("\u{1B}[38;5;\(idx)m")
            await feed("X")
            await feed("\u{1B}[0m")

            let cell = await grid.cellAt(row: 0, col: i)
            // Compare packed RGBA for correctness (reverse-lookup is lossy for
            // palette collisions, e.g. index 15 and 231 share RGB 255,255,255)
            XCTAssertEqual(cell?.fgPackedRGBA, TerminalColor.indexed(idx).packedRGBA(),
                           "256-color fg index \(idx) should be set")
        }
    }

    /// 256-color mode: SGR 48;5;N (background) palette sweep.
    func testFull256ColorBackground() async {
        let testIndices: [UInt8] = [0, 15, 16, 196, 231, 255]

        for (i, idx) in testIndices.enumerated() {
            await feed("\u{1B}[48;5;\(idx)m")
            await feed(" ")
            await feed("\u{1B}[0m")

            let cell = await grid.cellAt(row: 0, col: i)
            // Compare packed RGBA (reverse-lookup lossy for collisions like 15/231)
            XCTAssertEqual(cell?.bgPackedRGBA, TerminalColor.indexed(idx).packedRGBA(),
                           "256-color bg index \(idx) should be set")
        }
    }

    /// Truecolor: SGR 38;2;R;G;B (foreground).
    func testTruecolorForeground() async {
        await feed("\u{1B}[38;2;255;128;0m")   // Orange
        await feed("O")
        await feed("\u{1B}[0m")

        let fg = await fgAt(row: 0, col: 0)
        XCTAssertEqual(fg, .rgb(255, 128, 0), "Truecolor fg should be (255, 128, 0)")
    }

    /// Truecolor: SGR 48;2;R;G;B (background).
    func testTruecolorBackground() async {
        await feed("\u{1B}[48;2;0;100;200m")   // Blue-ish
        await feed(" ")
        await feed("\u{1B}[0m")

        let bg = await bgAt(row: 0, col: 0)
        XCTAssertEqual(bg, .rgb(0, 100, 200), "Truecolor bg should be (0, 100, 200)")
    }

    /// Truecolor gradient: feed a series of cells with incrementing red values.
    func testTruecolorGradient() async {
        // Simulate: awk 'BEGIN{for(i=0;i<80;i++)printf "\033[48;2;%d;0;0m \033[0m",i*3}'
        for i in 0..<80 {
            let r = min(i * 3, 255)
            await feed("\u{1B}[48;2;\(r);0;0m")
            await feed(" ")
            await feed("\u{1B}[0m")
        }

        // Verify gradient endpoints
        // Truecolor (0,0,0) matches palette index 16 in the reverse lookup;
        // compare packed RGBA for correctness rather than enum equality.
        let bgStartCell = await grid.cellAt(row: 0, col: 0)
        XCTAssertEqual(bgStartCell?.bgPackedRGBA, TerminalColor.rgb(0, 0, 0).packedRGBA(),
                        "Gradient start should be black")

        let bgMid = await bgAt(row: 0, col: 40)
        XCTAssertEqual(bgMid, .rgb(120, 0, 0), "Gradient midpoint should be (120, 0, 0)")

        let bgEnd = await bgAt(row: 0, col: 79)
        XCTAssertEqual(bgEnd, .rgb(237, 0, 0), "Gradient end should be (237, 0, 0)")
    }

    /// Multiple SGR attributes combined: bold + color + underline.
    func testCombinedAttributes() async {
        // Bold red underline text
        await feed("\u{1B}[1;31;4m")
        await feed("ERROR")
        await feed("\u{1B}[0m")

        let attrs = await attrsAt(row: 0, col: 0)
        XCTAssertTrue(attrs.contains(.bold), "Should have bold")
        XCTAssertTrue(attrs.contains(.underline), "Should have underline")

        let fg = await fgAt(row: 0, col: 0)
        // boldIsBright is pre-applied at write-time: bold + indexed(1) → indexed(9)
        if TerminalDefaults.boldIsBright {
            XCTAssertEqual(fg, .indexed(9), "Bold red should be bright red with boldIsBright")
        } else {
            XCTAssertEqual(fg, .indexed(1), "Should have red foreground")
        }

        let text = await rowText(row: 0, startCol: 0, endCol: 5)
        XCTAssertEqual(text, "ERROR")
    }

    /// 6×6×6 color cube verification (indices 16–231).
    func testColorCubeValues() async {
        // Verify a few well-known color cube entries:
        // Index 16 = (0,0,0), Index 21 = (0,0,255), Index 196 = (255,0,0)

        await feed("\u{1B}[38;5;16m")
        await feed("A")
        await feed("\u{1B}[38;5;21m")
        await feed("B")
        await feed("\u{1B}[38;5;196m")
        await feed("C")
        await feed("\u{1B}[0m")

        let fg16 = await fgAt(row: 0, col: 0)
        XCTAssertEqual(fg16, .indexed(16), "Index 16 should be set")

        let fg21 = await fgAt(row: 0, col: 1)
        XCTAssertEqual(fg21, .indexed(21), "Index 21 should be set")

        let fg196 = await fgAt(row: 0, col: 2)
        XCTAssertEqual(fg196, .indexed(196), "Index 196 should be set")
    }

    /// Grayscale ramp (indices 232–255).
    func testGrayscaleRamp() async {
        // Write 24 cells with grayscale bg
        for i in 0..<24 {
            let idx = 232 + i
            await feed("\u{1B}[48;5;\(idx)m")
            await feed(" ")
            await feed("\u{1B}[0m")
        }

        let bgStart = await bgAt(row: 0, col: 0)
        XCTAssertEqual(bgStart, .indexed(232), "Grayscale start should be index 232")

        let bgEnd = await bgAt(row: 0, col: 23)
        XCTAssertEqual(bgEnd, .indexed(255), "Grayscale end should be index 255")
    }

    /// SGR attribute stacking and selective reset.
    func testAttributeStackingAndReset() async {
        // Set bold, then add italic, then add underline
        await feed("\u{1B}[1m")
        await feed("\u{1B}[3m")
        await feed("\u{1B}[4m")
        await feed("A")

        let attrsA = await attrsAt(row: 0, col: 0)
        XCTAssertTrue(attrsA.contains(.bold), "Should be bold")
        XCTAssertTrue(attrsA.contains(.italic), "Should be italic")
        XCTAssertTrue(attrsA.contains(.underline), "Should be underline")

        // Turn off bold only (SGR 22)
        await feed("\u{1B}[22m")
        await feed("B")

        let attrsB = await attrsAt(row: 0, col: 1)
        XCTAssertFalse(attrsB.contains(.bold), "Bold should be off")
        XCTAssertTrue(attrsB.contains(.italic), "Italic should remain")
        XCTAssertTrue(attrsB.contains(.underline), "Underline should remain")

        // Turn off italic (SGR 23)
        await feed("\u{1B}[23m")
        await feed("C")

        let attrsC = await attrsAt(row: 0, col: 2)
        XCTAssertFalse(attrsC.contains(.italic), "Italic should be off")
        XCTAssertTrue(attrsC.contains(.underline), "Underline should remain")

        // Full reset
        await feed("\u{1B}[0m")
        await feed("D")

        let attrsD = await attrsAt(row: 0, col: 3)
        XCTAssertEqual(attrsD, [], "Should have no attributes after full reset")
    }

    /// OSC 4 color palette query/set integration.
    func testOSCPaletteColor() async {
        // Set palette color 1 (red) to a custom value
        // OSC 4;1;rgb:ff/80/00 ST
        await feed("\u{1B}]4;1;rgb:ff/80/00\u{1B}\\")

        let color = await grid.paletteColor(index: 1)
        XCTAssertEqual(color.0, 255, "Red component should be 255")
        XCTAssertEqual(color.1, 128, "Green component should be 128")
        XCTAssertEqual(color.2, 0, "Blue component should be 0")
    }
}

// MARK: - FullSessionRenderTest

/// Simulates a complete terminal session: shell login, command execution,
/// program launch, and exit — end to end through the parser.
final class FullSessionRenderTest: IntegrationTestBase {

    /// Complete session: login prompt → shell → run ls → see output.
    func testShellSession() async {
        // Login banner
        await feed("Welcome to Ubuntu 22.04 LTS\r\n")
        await feed("\r\n")

        // Shell prompt
        await feed("\u{1B}[32m")           // Green
        await feed("user@host")
        await feed("\u{1B}[0m")
        await feed(":")
        await feed("\u{1B}[34m")           // Blue
        await feed("~")
        await feed("\u{1B}[0m")
        await feed("$ ")

        // User types "ls"
        await feed("ls\r\n")

        // ls output with colors
        await feed("\u{1B}[34m")           // Blue = directory
        await feed("Documents")
        await feed("\u{1B}[0m")
        await feed("  ")
        await feed("\u{1B}[32m")           // Green = executable
        await feed("script.sh")
        await feed("\u{1B}[0m")
        await feed("  ")
        await feed("readme.txt")
        await feed("\r\n")

        // Verify banner
        let banner = await rowText(row: 0, startCol: 0, endCol: 27)
        XCTAssertEqual(banner, "Welcome to Ubuntu 22.04 LTS")

        // Verify prompt
        let prompt = await rowText(row: 2, startCol: 0, endCol: 9)
        XCTAssertEqual(prompt, "user@host")

        let promptFg = await fgAt(row: 2, col: 0)
        XCTAssertEqual(promptFg, .indexed(2), "Username should be green")

        // Verify ls output
        let dir = await rowText(row: 3, startCol: 0, endCol: 9)
        XCTAssertEqual(dir, "Documents")

        let dirFg = await fgAt(row: 3, col: 0)
        XCTAssertEqual(dirFg, .indexed(4), "Directory should be blue")
    }

    /// Full lifecycle: primary → alt screen (htop) → primary.
    func testPrimaryToAltAndBack() async {
        // Shell prompt and some output on primary screen
        await feed("$ whoami\r\nuser\r\n$ ")

        // Verify primary content
        let cmd = await rowText(row: 0, startCol: 0, endCol: 8)
        XCTAssertEqual(cmd, "$ whoami")

        // Launch htop (switches to alt screen)
        await feed("\u{1B}[?1049h")          // Save cursor + switch to alt + clear
        await feed("\u{1B}[2J")
        await feed("\u{1B}[1;1H")

        // Draw some htop content
        await feed("\u{1B}[1m\u{1B}[32m")
        await feed("CPU Usage: 42%")
        await feed("\u{1B}[0m")

        let usingAlt = await grid.usingAlternateBuffer
        XCTAssertTrue(usingAlt)

        let htopContent = await rowText(row: 0, startCol: 0, endCol: 14)
        XCTAssertEqual(htopContent, "CPU Usage: 42%")

        // Exit htop
        await feed("\u{1B}[?1049l")

        let usingAltAfter = await grid.usingAlternateBuffer
        XCTAssertFalse(usingAltAfter, "Should be back on primary")

        // Primary content should be intact
        let cmdAfter = await rowText(row: 0, startCol: 0, endCol: 8)
        XCTAssertEqual(cmdAfter, "$ whoami")
    }

    /// OSC window title set during session.
    func testWindowTitleSet() async {
        // Many shells set the window title via OSC 0
        // OSC 0 ; user@host:~ BEL
        await feed("\u{1B}]0;user@host:~\u{07}")

        let title = await grid.windowTitle
        XCTAssertEqual(title, "user@host:~")
    }

    /// Bracketed paste mode enable/disable during session.
    func testBracketedPasteLifecycle() async {
        // zsh/fish enable bracketed paste on startup
        await feed("\u{1B}[?2004h")

        let enabled = await grid.bracketedPasteMode
        XCTAssertTrue(enabled, "Bracketed paste should be enabled")

        // Before running a command, some shells disable it
        await feed("\u{1B}[?2004l")

        let disabled = await grid.bracketedPasteMode
        XCTAssertFalse(disabled, "Bracketed paste should be disabled")
    }

    /// Multi-line colored output with scroll.
    func testScrollingColorOutput() async {
        // Fill 30 lines (exceeds 24-row terminal, causing scroll)
        for i in 1...30 {
            let colorCode = 31 + (i % 7) // Cycle through colors
            await feed("\u{1B}[\(colorCode)m")
            await feed("Line \(i)")
            await feed("\u{1B}[0m")
            await feed("\r\n")
        }

        // After scrolling, Line 30's \r\n causes one final scroll.
        // Lines 8–30 are visible (rows 0–22), row 23 is blank.
        let row0 = await rowText(row: 0, startCol: 0, endCol: 7)
        XCTAssertEqual(row0, "Line 8 ", "Row 0 should show Line 8 after scroll")

        let row22 = await rowText(row: 22, startCol: 0, endCol: 7)
        XCTAssertEqual(row22, "Line 30", "Row 22 should show Line 30")

        // Verify colors cycle correctly
        // SGR codes 30–37 map to ANSI color indices 0–7 (SGR 32 → index 2)
        // colorCode = 31 + (i % 7), ANSI index = colorCode - 30 = 1 + (i % 7)
        let fgRow0 = await fgAt(row: 0, col: 0)
        let expectedIdx = 1 + (8 % 7)  // Line 8 → SGR 32 → ANSI color index 2
        XCTAssertEqual(fgRow0, .indexed(UInt8(expectedIdx)), "Line 8 should have correct color")
    }

    /// CJK wide character output.
    func testCJKWideCharacters() async {
        // Feed some Chinese characters (each occupies 2 columns)
        await feed("Hello 世界!\r\n")

        let h = await charAt(row: 0, col: 0)
        XCTAssertEqual(h, "H")

        let world0 = await charAt(row: 0, col: 6)
        XCTAssertEqual(world0, "世", "First CJK character")

        // Wide char at col 6 should have wideChar attribute
        let attrs = await attrsAt(row: 0, col: 6)
        XCTAssertTrue(attrs.contains(.wideChar), "CJK should have wideChar attribute")

        let world1 = await charAt(row: 0, col: 8)
        XCTAssertEqual(world1, "界", "Second CJK character")

        let excl = await charAt(row: 0, col: 10)
        XCTAssertEqual(excl, "!", "Character after CJK should be at correct position")
    }

    /// Mixed C0 controls embedded in output stream.
    func testC0ControlsInOutput() async {
        // Tab + text + backspace + overwrite
        await feed("Col1\tCol2\tCol3\r\n")

        // Tab stops at 8, 16, 24... so Col1 at 0, Col2 at 8, Col3 at 16
        let col1 = await rowText(row: 0, startCol: 0, endCol: 4)
        XCTAssertEqual(col1, "Col1")

        let col2 = await rowText(row: 0, startCol: 8, endCol: 12)
        XCTAssertEqual(col2, "Col2")

        let col3 = await rowText(row: 0, startCol: 16, endCol: 20)
        XCTAssertEqual(col3, "Col3")

        // Carriage return without line feed — overwrite
        await feed("ABCDE\rXY")

        let overwritten = await rowText(row: 1, startCol: 0, endCol: 5)
        XCTAssertEqual(overwritten, "XYCDE", "CR should return to col 0, overwriting A and B")
    }

    /// Rapid cursor positioning (stress test for CSI parsing).
    func testRapidCursorPositioning() async {
        // Simulate rapid random cursor movement like `top` or custom TUI
        // Place characters at known positions
        await feed("\u{1B}[1;1H*")     // (0,0) = *
        await feed("\u{1B}[12;40H+")   // (11,39) = +
        await feed("\u{1B}[24;80H#")   // (23,79) = #
        await feed("\u{1B}[1;80H@")    // (0,79) = @
        await feed("\u{1B}[24;1H!")    // (23,0) = !

        let topLeft = await charAt(row: 0, col: 0)
        XCTAssertEqual(topLeft, "*", "Top-left corner")

        let center = await charAt(row: 11, col: 39)
        XCTAssertEqual(center, "+", "Center")

        let bottomRight = await charAt(row: 23, col: 79)
        XCTAssertEqual(bottomRight, "#", "Bottom-right corner")

        let topRight = await charAt(row: 0, col: 79)
        XCTAssertEqual(topRight, "@", "Top-right corner")

        let bottomLeft = await charAt(row: 23, col: 0)
        XCTAssertEqual(bottomLeft, "!", "Bottom-left corner")
    }
}

#endif
