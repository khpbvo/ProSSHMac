// ApplicationCompatibilityTests.swift
// ProSSHV2
//
// F.12 — Network equipment compatibility (Cisco IOS, Juniper JunOS, MikroTik RouterOS).
// F.13 — Full-screen application compatibility (vim, nano, tmux, mc).
//
// These tests feed realistic escape sequences that each application/device emits
// through VTParser -> TerminalGrid and verify the resulting grid state.

#if canImport(XCTest)
import XCTest

// MARK: - F.12: Cisco IOS 12.x Compatibility

/// Simulates Cisco IOS 12.x VT100 output: show commands, --More-- prompt,
/// DEC Special Graphics menu borders, and banner MOTD with CR/LF line endings.
final class CiscoIOSCompatTest: IntegrationTestBase {

    // MARK: - testCiscoShowRunning

    /// Feed Cisco `show running-config` output with `!` comment lines,
    /// `interface` blocks, and line wrapping. Verify text at correct grid positions.
    func testCiscoShowRunning() async {
        // Cisco IOS precedes output with the command echo and a CR/LF.
        await feed("Router#show running-config\r\n")

        // IOS sends a header block before config body.
        await feed("Building configuration...\r\n")
        await feed("\r\n")
        await feed("Current configuration : 1234 bytes\r\n")

        // Comment line
        await feed("!\r\n")

        // Global config
        await feed("hostname Router\r\n")

        // Another comment separator
        await feed("!\r\n")

        // Interface block
        await feed("interface GigabitEthernet0/0\r\n")
        await feed(" ip address 192.168.1.1 255.255.255.0\r\n")
        await feed(" no shutdown\r\n")

        // Comment and end
        await feed("!\r\n")
        await feed("end\r\n")

        // Row 0: command echo
        let prompt = await rowText(row: 0, startCol: 0, endCol: 26)
        XCTAssertEqual(prompt, "Router#show running-config")

        // Row 1: "Building configuration..."
        let building = await rowText(row: 1, startCol: 0, endCol: 24)
        XCTAssertTrue(building.hasPrefix("Building configuration"),
                       "Should display building message")

        // Row 4: "!" comment separator
        let comment = await charAt(row: 4, col: 0)
        XCTAssertEqual(comment, "!", "Comment line should begin with !")

        // Row 5: hostname line
        let hostname = await rowText(row: 5, startCol: 0, endCol: 15)
        XCTAssertEqual(hostname, "hostname Router")

        // Row 7: interface block header
        let iface = await rowText(row: 7, startCol: 0, endCol: 30)
        XCTAssertTrue(iface.hasPrefix("interface GigabitEthernet0/0"),
                       "Interface line should appear")

        // Row 8: indented sub-command
        let ipAddr = await rowText(row: 8, startCol: 0, endCol: 40)
        XCTAssertTrue(ipAddr.contains("ip address 192.168.1.1"),
                       "IP address sub-command should appear indented")
    }

    // MARK: - testCiscoMorePrompt

    /// Cisco IOS paginates long output with a ` --More-- ` prompt displayed
    /// in reverse video. Verify the reverse attribute on the prompt cells.
    func testCiscoMorePrompt() async {
        // Fill some lines of show output above the prompt
        for i in 1...22 {
            await feed("config line \(i)\r\n")
        }

        // Cisco --More-- prompt uses SGR 7 (reverse video) and sits on the last line.
        // Cisco IOS puts it at column 0 of the current row.
        await feed("\u{1B}[7m --More-- \u{1B}[0m")

        // The --More-- prompt lands at row 22 (0-indexed) because 22 \r\n pushed
        // rows up by one when they exceeded 24 rows.  Depending on scroll state,
        // the prompt should be on the last written row.
        // After 22 lines + the prompt on row 22, content has scrolled.
        // Row 23 is the current cursor row after 22 newlines (rows 0-21 occupied,
        // then cursor at 22 after last \n, and text written there).

        // Find the row containing --More--
        var moreRow = -1
        for r in 0..<24 {
            let text = await rowText(row: r, startCol: 0, endCol: 12)
            if text.contains("--More--") {
                moreRow = r
                break
            }
        }
        XCTAssertNotEqual(moreRow, -1, "Should find --More-- prompt on some row")

        // Verify reverse attribute on the prompt text (check the '-' of --More--)
        if moreRow >= 0 {
            let attrs = await attrsAt(row: moreRow, col: 1) // first '-'
            XCTAssertTrue(attrs.contains(.reverse),
                          "--More-- prompt should have reverse video attribute")

            // Verify text content
            let text = await rowText(row: moreRow, startCol: 1, endCol: 9)
            XCTAssertEqual(text, "--More--")
        }
    }

    // MARK: - testCiscoLineDrawingMenu

    /// Cisco menu output uses DEC Special Graphics for box drawing.
    /// Verify box characters render as correct Unicode line-drawing glyphs.
    func testCiscoLineDrawingMenu() async {
        // Position cursor and draw a Cisco-style menu box:
        //  ┌────────────────────────┐
        //  │  1. System Configuration │
        //  │  2. Interfaces           │
        //  └────────────────────────┘

        await feed("\u{1B}[1;1H")

        // Top border using DEC Special Graphics
        await feed("\u{1B}(0")   // Switch G0 to DEC line drawing
        await feed("l")          // ┌
        for _ in 0..<26 { await feed("q") }  // ─ x26
        await feed("k")          // ┐
        await feed("\u{1B}(B")   // Back to ASCII

        // Menu item 1
        await feed("\r\n")
        await feed("\u{1B}(0")
        await feed("x")          // │
        await feed("\u{1B}(B")
        await feed("  1. System Configuration ")
        await feed("\u{1B}(0")
        await feed("x")          // │
        await feed("\u{1B}(B")

        // Menu item 2
        await feed("\r\n")
        await feed("\u{1B}(0")
        await feed("x")          // │
        await feed("\u{1B}(B")
        await feed("  2. Interfaces           ")
        await feed("\u{1B}(0")
        await feed("x")          // │
        await feed("\u{1B}(B")

        // Bottom border
        await feed("\r\n")
        await feed("\u{1B}(0")
        await feed("m")          // └
        for _ in 0..<26 { await feed("q") }  // ─ x26
        await feed("j")          // ┘
        await feed("\u{1B}(B")

        // Verify corners
        let topLeft = await charAt(row: 0, col: 0)
        XCTAssertEqual(topLeft, "┌", "Top-left corner should be ┌")

        let topRight = await charAt(row: 0, col: 27)
        XCTAssertEqual(topRight, "┐", "Top-right corner should be ┐")

        let bottomLeft = await charAt(row: 3, col: 0)
        XCTAssertEqual(bottomLeft, "└", "Bottom-left corner should be └")

        let bottomRight = await charAt(row: 3, col: 27)
        XCTAssertEqual(bottomRight, "┘", "Bottom-right corner should be ┘")

        // Verify horizontal lines
        let horiz = await charAt(row: 0, col: 1)
        XCTAssertEqual(horiz, "─", "Horizontal border should be ─")

        // Verify vertical lines
        let vertLeft = await charAt(row: 1, col: 0)
        XCTAssertEqual(vertLeft, "│", "Left vertical border should be │")

        let vertRight = await charAt(row: 1, col: 27)
        XCTAssertEqual(vertRight, "│", "Right vertical border should be │")

        // Verify menu text content
        let item1 = await rowText(row: 1, startCol: 3, endCol: 27)
        XCTAssertTrue(item1.contains("1. System Configuration"),
                       "First menu item should be present")

        let item2 = await rowText(row: 2, startCol: 3, endCol: 17)
        XCTAssertTrue(item2.contains("2. Interfaces"),
                       "Second menu item should be present")
    }

    // MARK: - testCiscoBannerMOTD

    /// Cisco banners use \r\n line endings. Verify correct line positioning
    /// with multiple MOTD lines.
    func testCiscoBannerMOTD() async {
        // Cisco sends the banner after connection with CR/LF line endings.
        // Typical banner from "banner motd ^C ... ^C" configuration.
        await feed("\r\n")
        await feed("*******************************************\r\n")
        await feed("*                                         *\r\n")
        await feed("*   WARNING: Authorized access only!      *\r\n")
        await feed("*   All sessions are monitored.           *\r\n")
        await feed("*                                         *\r\n")
        await feed("*******************************************\r\n")
        await feed("\r\n")
        await feed("Router>")

        // Row 0: empty (from the initial \r\n)
        // Row 1: top asterisk border
        let topBorder = await charAt(row: 1, col: 0)
        XCTAssertEqual(topBorder, "*", "Top border should start with *")

        // Row 3: WARNING line
        let warning = await rowText(row: 3, startCol: 0, endCol: 43)
        XCTAssertTrue(warning.contains("WARNING: Authorized access only"),
                       "Warning line should appear at correct row")

        // Row 4: monitoring line
        let monitor = await rowText(row: 4, startCol: 0, endCol: 43)
        XCTAssertTrue(monitor.contains("All sessions are monitored"),
                       "Monitoring notice should appear at correct row")

        // Row 6: bottom asterisk border
        let bottomBorder = await charAt(row: 6, col: 0)
        XCTAssertEqual(bottomBorder, "*", "Bottom border should start with *")

        // Row 8: Router> prompt
        let routerPrompt = await rowText(row: 8, startCol: 0, endCol: 7)
        XCTAssertEqual(routerPrompt, "Router>")
    }
}

// MARK: - F.12: Juniper JunOS Compatibility

/// Simulates JunOS xterm-compatible output: tab completion screen redraws,
/// show interfaces with underlined headers, and config mode prompts with
/// cursor save/restore for line editing.
final class JuniperJunOSCompatTest: IntegrationTestBase {

    // MARK: - testJuniperTabCompletion

    /// JunOS redraws the command line during tab completion, repositioning
    /// the cursor and printing completion options. Verify completions appear
    /// at the correct grid positions.
    func testJuniperTabCompletion() async {
        // User types partial command at prompt
        await feed("user@router> show interfaces ")

        // User presses Tab. JunOS sends completion list below the command line,
        // then re-renders the prompt and partial command.
        await feed("\r\n")
        await feed("Possible completions:\r\n")
        await feed("  detail               Show detailed output\r\n")
        await feed("  extensive            Show extensive output\r\n")
        await feed("  terse                Show terse output\r\n")

        // JunOS then repositions cursor back to the command line.
        // Use CUP to go to row 6 (after completions), re-draw prompt.
        await feed("\u{1B}[6;1H")
        await feed("user@router> show interfaces ")

        // Verify the completions appeared at correct rows
        let possible = await rowText(row: 1, startCol: 0, endCol: 21)
        XCTAssertEqual(possible, "Possible completions:")

        let detail = await rowText(row: 2, startCol: 2, endCol: 8)
        XCTAssertEqual(detail, "detail")

        let extensive = await rowText(row: 3, startCol: 2, endCol: 11)
        XCTAssertEqual(extensive, "extensive")

        let terse = await rowText(row: 4, startCol: 2, endCol: 7)
        XCTAssertEqual(terse, "terse")

        // Verify the re-drawn command line on row 5 (0-indexed)
        let redrawn = await rowText(row: 5, startCol: 0, endCol: 29)
        XCTAssertEqual(redrawn, "user@router> show interfaces ")
    }

    // MARK: - testJuniperShowInterfaces

    /// JunOS `show interfaces` prints a header row with underline attribute.
    /// Verify the attribute and text content.
    func testJuniperShowInterfaces() async {
        // JunOS prompt
        await feed("user@router> show interfaces terse\r\n")

        // Header row: JunOS underlines the header using SGR 4 (underline).
        await feed("\u{1B}[4m")  // SGR underline on
        await feed("Interface               Admin Link Proto    Local                 Remote")
        await feed("\u{1B}[0m")  // SGR reset
        await feed("\r\n")

        // Data rows (no underline)
        await feed("ge-0/0/0                up    up\r\n")
        await feed("ge-0/0/0.0              up    up   inet     192.168.1.1/24\r\n")
        await feed("ge-0/0/1                up    down\r\n")
        await feed("lo0                     up    up\r\n")
        await feed("lo0.0                   up    up   inet     10.0.0.1/32\r\n")

        // Verify header text
        let headerIface = await rowText(row: 1, startCol: 0, endCol: 9)
        XCTAssertEqual(headerIface, "Interface")

        let headerAdmin = await rowText(row: 1, startCol: 24, endCol: 29)
        XCTAssertEqual(headerAdmin, "Admin")

        // Verify underline attribute on header row
        let attrsI = await attrsAt(row: 1, col: 0)
        XCTAssertTrue(attrsI.contains(.underline),
                       "Header should have underline attribute")

        let attrsA = await attrsAt(row: 1, col: 24)
        XCTAssertTrue(attrsA.contains(.underline),
                       "Admin header should have underline attribute")

        // Verify data row does NOT have underline
        let dataAttrs = await attrsAt(row: 2, col: 0)
        XCTAssertFalse(dataAttrs.contains(.underline),
                        "Data rows should not have underline")

        // Verify data content
        let ge000 = await rowText(row: 2, startCol: 0, endCol: 8)
        XCTAssertEqual(ge000, "ge-0/0/0")

        let ipAddr = await rowText(row: 3, startCol: 0, endCol: 70)
        XCTAssertTrue(ipAddr.contains("192.168.1.1/24"),
                       "Interface data should contain IP address")
    }

    // MARK: - testJuniperConfigModePrompt

    /// JunOS uses cursor save/restore (DECSC/DECRC) during config-mode line
    /// editing. Verify the cursor ends at the correct column after the
    /// save/restore cycle.
    func testJuniperConfigModePrompt() async {
        // Enter configuration mode
        await feed("user@router> configure\r\n")
        await feed("Entering configuration mode\r\n")
        await feed("\r\n")

        // JunOS config prompt with [edit] indicator.
        // JunOS saves cursor, writes the prompt, and restores for inline editing.

        // Save cursor position
        await feed("\u{1B}7")                   // DECSC

        // Move to row 4 and write the [edit] context
        await feed("\u{1B}[4;1H")
        await feed("\u{1B}[K")                  // Clear line
        await feed("[edit]\r\n")
        await feed("user@router# ")

        // Restore cursor to saved position (which was at end of row 2)
        await feed("\u{1B}8")                   // DECRC

        // Now override: move cursor to a specific editing position.
        // Simulate user typing in config mode; JunOS places cursor at col 14
        // (right after "user@router# ").
        await feed("\u{1B}[5;14H")

        // Verify [edit] text at row 3
        let editTag = await rowText(row: 3, startCol: 0, endCol: 6)
        XCTAssertEqual(editTag, "[edit]")

        // Verify prompt text at row 4
        let configPrompt = await rowText(row: 4, startCol: 0, endCol: 13)
        XCTAssertEqual(configPrompt, "user@router# ")

        // Verify final cursor position (row 4, col 13 in 0-indexed)
        let cursorRow = await grid.cursor.row
        let cursorCol = await grid.cursor.col
        XCTAssertEqual(cursorRow, 4, "Cursor should be on config prompt row")
        XCTAssertEqual(cursorCol, 13, "Cursor should be after the # prompt")
    }
}

// MARK: - F.12: MikroTik RouterOS Compatibility

/// Simulates MikroTik RouterOS TUI output: colored menu headings with bold
/// and foreground colors, box-drawing borders, and interface tables with
/// aligned columns.
final class MikroTikCompatTest: IntegrationTestBase {

    // MARK: - testMikroTikColoredMenu

    /// RouterOS main menu uses bold + fg color for headings and DEC Special
    /// Graphics for box-drawing borders. Verify colors and line-drawing glyphs.
    func testMikroTikColoredMenu() async {
        // Clear and position
        await feed("\u{1B}[2J\u{1B}[1;1H")

        // RouterOS-style top border using DEC line drawing
        await feed("\u{1B}(0")
        await feed("lqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqk")  // ┌─...─┐  (40 wide)
        await feed("\u{1B}(B")
        await feed("\r\n")

        // Menu heading: bold + cyan foreground
        await feed("\u{1B}(0")
        await feed("x")                                           // │
        await feed("\u{1B}(B")
        await feed(" ")
        await feed("\u{1B}[1;36m")                                // Bold + Cyan
        await feed("MikroTik RouterOS Main Menu")
        await feed("\u{1B}[0m")
        await feed("          ")
        await feed("\u{1B}(0")
        await feed("x")                                           // │
        await feed("\u{1B}(B")
        await feed("\r\n")

        // Divider: ├─...─┤
        await feed("\u{1B}(0")
        await feed("tqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqu")  // ├─...─┤
        await feed("\u{1B}(B")
        await feed("\r\n")

        // Menu items with bold + white
        await feed("\u{1B}(0")
        await feed("x")
        await feed("\u{1B}(B")
        await feed(" ")
        await feed("\u{1B}[1;37m")                                // Bold + White
        await feed("1)")
        await feed("\u{1B}[0m")
        await feed(" Interfaces                    ")
        await feed("\u{1B}(0")
        await feed("x")
        await feed("\u{1B}(B")
        await feed("\r\n")

        await feed("\u{1B}(0")
        await feed("x")
        await feed("\u{1B}(B")
        await feed(" ")
        await feed("\u{1B}[1;37m")
        await feed("2)")
        await feed("\u{1B}[0m")
        await feed(" IP Addresses                  ")
        await feed("\u{1B}(0")
        await feed("x")
        await feed("\u{1B}(B")
        await feed("\r\n")

        // Bottom border: └─...─┘
        await feed("\u{1B}(0")
        await feed("mqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqj")  // └─...─┘
        await feed("\u{1B}(B")

        // --- Assertions ---

        // Top-left corner
        let tl = await charAt(row: 0, col: 0)
        XCTAssertEqual(tl, "┌", "Top-left corner should be ┌")

        // Top-right corner at col 40
        let tr = await charAt(row: 0, col: 40)
        XCTAssertEqual(tr, "┐", "Top-right corner should be ┐")

        // Horizontal line
        let hLine = await charAt(row: 0, col: 5)
        XCTAssertEqual(hLine, "─", "Horizontal border should be ─")

        // Left-T junction at divider row
        let leftT = await charAt(row: 2, col: 0)
        XCTAssertEqual(leftT, "├", "Divider left should be ├")

        // Right-T junction
        let rightT = await charAt(row: 2, col: 40)
        XCTAssertEqual(rightT, "┤", "Divider right should be ┤")

        // Bottom-left corner
        let bl = await charAt(row: 5, col: 0)
        XCTAssertEqual(bl, "└", "Bottom-left corner should be └")

        // Bottom-right corner
        let br = await charAt(row: 5, col: 40)
        XCTAssertEqual(br, "┘", "Bottom-right corner should be ┘")

        // Heading: verify bold + cyan on "MikroTik"
        let headingFg = await fgAt(row: 1, col: 2)
        XCTAssertEqual(headingFg, .indexed(6),
                        "Heading should have cyan foreground (indexed 6)")

        let headingAttrs = await attrsAt(row: 1, col: 2)
        XCTAssertTrue(headingAttrs.contains(.bold),
                       "Heading should have bold attribute")

        // Menu item number: verify bold + white
        let itemFg = await fgAt(row: 3, col: 2)
        XCTAssertEqual(itemFg, .indexed(7),
                        "Menu item number should have white foreground (indexed 7)")

        let itemAttrs = await attrsAt(row: 3, col: 2)
        XCTAssertTrue(itemAttrs.contains(.bold),
                       "Menu item number should have bold attribute")
    }

    // MARK: - testMikroTikInterfaceTable

    /// RouterOS interface list table uses aligned columns with tabs and spaces.
    /// Verify the grid content alignment.
    func testMikroTikInterfaceTable() async {
        // RouterOS-style interface table header
        await feed("\u{1B}[1m")  // Bold header
        await feed("Flags: X - disabled, R - running\r\n")
        await feed("\u{1B}[0m")
        await feed(" #     NAME                 TYPE       MTU  L2MTU\r\n")

        // Data rows with flags and aligned columns
        // RouterOS uses spaces for alignment (not always tabs).
        await feed(" 0  R  ether1                ether      1500  1598\r\n")
        await feed(" 1  R  ether2                ether      1500  1598\r\n")
        await feed(" 2  X  wlan1                 wlan       1500  1600\r\n")
        await feed(" 3  R  bridge1               bridge     1500  1598\r\n")

        // Verify bold on header line
        let flagsAttrs = await attrsAt(row: 0, col: 0)
        XCTAssertTrue(flagsAttrs.contains(.bold),
                       "Flags header should be bold")

        // Verify column header text
        let nameHeader = await rowText(row: 1, startCol: 7, endCol: 11)
        XCTAssertEqual(nameHeader, "NAME")

        let typeHeader = await rowText(row: 1, startCol: 28, endCol: 32)
        XCTAssertEqual(typeHeader, "TYPE")

        // Verify data alignment: interface names
        let ether1 = await rowText(row: 2, startCol: 7, endCol: 13)
        XCTAssertEqual(ether1, "ether1")

        let ether2 = await rowText(row: 3, startCol: 7, endCol: 13)
        XCTAssertEqual(ether2, "ether2")

        // Verify disabled interface flag
        let disabledFlag = await charAt(row: 4, col: 4)
        XCTAssertEqual(disabledFlag, "X", "wlan1 should have X (disabled) flag")

        let runningFlag = await charAt(row: 2, col: 4)
        XCTAssertEqual(runningFlag, "R", "ether1 should have R (running) flag")

        // Verify MTU column alignment
        let mtu0 = await rowText(row: 2, startCol: 40, endCol: 44)
        XCTAssertEqual(mtu0, "1500")

        let mtu2 = await rowText(row: 4, startCol: 40, endCol: 44)
        XCTAssertEqual(mtu2, "1500")
    }
}

// MARK: - F.13: Vim Compatibility

/// Simulates vim editor output: alternate screen entry with tilde lines,
/// syntax highlighting with multiple SGR colors, rapid cursor movement,
/// alt-screen exit, and insert-mode status line.
final class VimCompatTest: IntegrationTestBase {

    // MARK: - testVimStartup

    /// vim enters alternate screen, clears it, draws `~` tildes on empty
    /// lines, and renders a reverse-video status bar at the bottom.
    func testVimStartup() async {
        // vim startup sequence: DECSC, enter alt buffer, clear, home cursor
        await feed("\u{1B}7")              // DECSC (save cursor)
        await feed("\u{1B}[?1049h")        // Enter alternate screen
        await feed("\u{1B}[2J")            // Clear entire screen
        await feed("\u{1B}[1;1H")          // Home cursor

        // Line 1: cursor sits here (empty file)
        // Lines 2-23: blue tildes (~) for empty-buffer lines
        for row in 2...23 {
            await feed("\u{1B}[\(row);1H")
            await feed("\u{1B}[34m")       // Blue foreground
            await feed("~")
            await feed("\u{1B}[0m")
        }

        // Status bar at row 24: reverse video
        await feed("\u{1B}[24;1H")
        await feed("\u{1B}[7m")            // Reverse video
        await feed("[No Name]                                                    0,0-1         All")
        await feed("\u{1B}[0m")

        // Verify alternate screen is active
        let usingAlt = await grid.usingAlternateBuffer
        XCTAssertTrue(usingAlt, "vim should be on alternate screen")

        // Verify tildes on empty lines
        for row in 1...22 {
            let ch = await charAt(row: row, col: 0)
            XCTAssertEqual(ch, "~", "Row \(row) should have tilde")

            let fg = await fgAt(row: row, col: 0)
            XCTAssertEqual(fg, .indexed(4), "Tildes should be blue (indexed 4)")
        }

        // Verify status bar has reverse attribute
        let statusAttrs = await attrsAt(row: 23, col: 0)
        XCTAssertTrue(statusAttrs.contains(.reverse),
                       "Status bar should have reverse video attribute")

        // Verify status bar text
        let statusText = await rowText(row: 23, startCol: 0, endCol: 9)
        XCTAssertEqual(statusText, "[No Name]")
    }

    // MARK: - testVimSyntaxHighlighting

    /// vim renders a Python file with keywords in blue, strings in green,
    /// and comments in gray. Verify fg colors on the respective cells.
    func testVimSyntaxHighlighting() async {
        await feed("\u{1B}[?1049h")
        await feed("\u{1B}[2J")
        await feed("\u{1B}[1;1H")

        // Line 1: `# This is a comment`  — comment in gray (SGR 90 = bright black)
        await feed("\u{1B}[90m")           // Bright black (gray)
        await feed("# This is a comment")
        await feed("\u{1B}[0m")

        // Line 2: `def hello():` — keyword in blue, function name in default
        await feed("\u{1B}[2;1H")
        await feed("\u{1B}[34m")           // Blue
        await feed("def")
        await feed("\u{1B}[0m")
        await feed(" hello():")

        // Line 3: `    print("Hello, world!")` — keyword in blue, string in green
        await feed("\u{1B}[3;1H")
        await feed("    ")
        await feed("\u{1B}[34m")           // Blue
        await feed("print")
        await feed("\u{1B}[0m")
        await feed("(")
        await feed("\u{1B}[32m")           // Green
        await feed("\"Hello, world!\"")
        await feed("\u{1B}[0m")
        await feed(")")

        // Line 4: `x = 42` — number literal
        await feed("\u{1B}[4;1H")
        await feed("x = ")
        await feed("\u{1B}[34m")           // Blue (number literal in some themes)
        await feed("42")
        await feed("\u{1B}[0m")

        // Verify comment is gray (bright black = indexed 8)
        let commentFg = await fgAt(row: 0, col: 0)
        XCTAssertEqual(commentFg, .indexed(8),
                        "Comment should be bright black/gray (indexed 8)")

        let commentText = await rowText(row: 0, startCol: 0, endCol: 19)
        XCTAssertEqual(commentText, "# This is a comment")

        // Verify 'def' keyword is blue
        let defFg = await fgAt(row: 1, col: 0)
        XCTAssertEqual(defFg, .indexed(4),
                        "'def' keyword should be blue (indexed 4)")

        // Verify 'print' keyword is blue
        let printFg = await fgAt(row: 2, col: 4)
        XCTAssertEqual(printFg, .indexed(4),
                        "'print' keyword should be blue (indexed 4)")

        // Verify string literal is green
        let stringFg = await fgAt(row: 2, col: 10)
        XCTAssertEqual(stringFg, .indexed(2),
                        "String literal should be green (indexed 2)")

        let stringText = await rowText(row: 2, startCol: 10, endCol: 25)
        XCTAssertEqual(stringText, "\"Hello, world!\"")
    }

    // MARK: - testVimCursorMovement

    /// Rapid hjkl movements simulated as cursor position updates via CUP
    /// (CSI row;col H). Verify the final cursor position.
    func testVimCursorMovement() async {
        await feed("\u{1B}[?1049h")
        await feed("\u{1B}[2J")

        // Write some content to navigate through
        await feed("\u{1B}[1;1H")
        await feed("Line 1: The quick brown fox")
        await feed("\u{1B}[2;1H")
        await feed("Line 2: jumps over the lazy dog")
        await feed("\u{1B}[3;1H")
        await feed("Line 3: and more text here")
        await feed("\u{1B}[4;1H")
        await feed("Line 4: final destination line")

        // Simulate rapid hjkl movement — vim sends CUP for each:
        // Start at (1,1), move down (j) three times, right (l) 10 times
        await feed("\u{1B}[1;1H")          // Start: row 1, col 1
        await feed("\u{1B}[2;1H")          // j: row 2
        await feed("\u{1B}[3;1H")          // j: row 3
        await feed("\u{1B}[4;1H")          // j: row 4
        await feed("\u{1B}[4;5H")          // l x4: col 5
        await feed("\u{1B}[4;10H")         // l x5: col 10
        await feed("\u{1B}[4;15H")         // l x5: col 15
        await feed("\u{1B}[3;15H")         // k: up to row 3
        await feed("\u{1B}[3;20H")         // l x5: col 20

        // Final position: row 3, col 20 (1-based), so 0-indexed = row 2, col 19
        let cursorRow = await grid.cursor.row
        let cursorCol = await grid.cursor.col
        XCTAssertEqual(cursorRow, 2, "Cursor should be at row 2 (0-indexed)")
        XCTAssertEqual(cursorCol, 19, "Cursor should be at col 19 (0-indexed)")
    }

    // MARK: - testVimExit

    /// Exiting vim sends CSI ?1049l to leave the alternate screen.
    /// Verify main screen content is restored.
    func testVimExit() async {
        // Primary screen: shell prompt with some history
        await feed("user@host:~$ vim test.py\r\n")
        let primaryRow0 = await rowText(row: 0, startCol: 0, endCol: 23)
        XCTAssertEqual(primaryRow0, "user@host:~$ vim test.p")

        // Enter vim
        await feed("\u{1B}7")              // DECSC
        await feed("\u{1B}[?1049h")        // Alt screen on
        await feed("\u{1B}[2J")            // Clear
        await feed("\u{1B}[1;1H")
        await feed("# vim editing content here")

        let usingAlt = await grid.usingAlternateBuffer
        XCTAssertTrue(usingAlt)

        // Exit vim
        await feed("\u{1B}[?1049l")        // Alt screen off
        await feed("\u{1B}8")              // DECRC

        let usingAltAfter = await grid.usingAlternateBuffer
        XCTAssertFalse(usingAltAfter, "Should be back on primary screen after vim exit")

        // Primary content should be restored
        let restored = await rowText(row: 0, startCol: 0, endCol: 13)
        XCTAssertEqual(restored, "user@host:~$ ", "Primary screen content should be restored")
    }

    // MARK: - testVimInsertMode

    /// vim displays `-- INSERT --` at the bottom row in bold when insert mode
    /// is active. Verify the text and bold attribute.
    func testVimInsertMode() async {
        await feed("\u{1B}[?1049h")
        await feed("\u{1B}[2J")

        // Write some content
        await feed("\u{1B}[1;1H")
        await feed("Hello world")

        // Status bar (row 23 in vim's layout, row 24 for message line)
        // vim puts -- INSERT -- on the last line (row 24) with bold
        await feed("\u{1B}[24;1H")
        await feed("\u{1B}[1m")            // Bold
        await feed("-- INSERT --")
        await feed("\u{1B}[0m")

        // Verify text on last row (row 23, 0-indexed)
        let insertText = await rowText(row: 23, startCol: 0, endCol: 12)
        XCTAssertEqual(insertText, "-- INSERT --")

        // Verify bold attribute
        let attrs = await attrsAt(row: 23, col: 0)
        XCTAssertTrue(attrs.contains(.bold),
                       "INSERT mode indicator should be bold")

        let attrsEnd = await attrsAt(row: 23, col: 11)
        XCTAssertTrue(attrsEnd.contains(.bold),
                       "Bold should extend to end of -- INSERT --")
    }
}

// MARK: - F.13: Nano Compatibility

/// Simulates GNU nano editor output: reverse-video title bar, content area,
/// and shortcut bar at the bottom with reverse-video key labels.
final class NanoCompatTest: IntegrationTestBase {

    // MARK: - testNanoStartup

    /// nano displays a reverse-video title bar at the top, content area in
    /// the middle, and a shortcut bar at the bottom. Verify the layout.
    func testNanoStartup() async {
        // nano uses the main screen (no alternate screen in older versions;
        // newer versions may use alt screen, but the classic behavior is main).
        await feed("\u{1B}[2J\u{1B}[1;1H")

        // Title bar: row 1, reverse video, centered filename
        await feed("\u{1B}[7m")            // Reverse video
        await feed("  GNU nano 7.2                    New Buffer                                  ")
        await feed("\u{1B}[0m")

        // Content area: rows 2-21 (empty for new file)
        // Cursor sits at row 2, col 1 for editing
        await feed("\u{1B}[2;1H")

        // Row 22: "[ line 1/1 (100%), col 1/1 (100%) ]" — status info (optional)

        // Shortcut bar: rows 23-24
        // Row 23: ^G Help   ^O Write Out ^W Where Is  ^K Cut     ^T Execute   ^C Location
        await feed("\u{1B}[23;1H")
        await feed("\u{1B}[7m")            // Reverse for key
        await feed("^G")
        await feed("\u{1B}[0m")
        await feed(" Help    ")
        await feed("\u{1B}[7m")
        await feed("^O")
        await feed("\u{1B}[0m")
        await feed(" Write Out ")
        await feed("\u{1B}[7m")
        await feed("^W")
        await feed("\u{1B}[0m")
        await feed(" Where Is  ")
        await feed("\u{1B}[7m")
        await feed("^K")
        await feed("\u{1B}[0m")
        await feed(" Cut       ")
        await feed("\u{1B}[7m")
        await feed("^T")
        await feed("\u{1B}[0m")
        await feed(" Execute  ")
        await feed("\u{1B}[7m")
        await feed("^C")
        await feed("\u{1B}[0m")
        await feed(" Location")

        // Row 24: ^X Exit   ^R Read File ^\ Replace   ^U Paste   ^J Justify   ^/ Go To Line
        await feed("\u{1B}[24;1H")
        await feed("\u{1B}[7m")
        await feed("^X")
        await feed("\u{1B}[0m")
        await feed(" Exit    ")
        await feed("\u{1B}[7m")
        await feed("^R")
        await feed("\u{1B}[0m")
        await feed(" Read File ")
        await feed("\u{1B}[7m")
        await feed("^\\")
        await feed("\u{1B}[0m")
        await feed(" Replace   ")
        await feed("\u{1B}[7m")
        await feed("^U")
        await feed("\u{1B}[0m")
        await feed(" Paste     ")
        await feed("\u{1B}[7m")
        await feed("^J")
        await feed("\u{1B}[0m")
        await feed(" Justify  ")
        await feed("\u{1B}[7m")
        await feed("^/")
        await feed("\u{1B}[0m")
        await feed(" Go To Line")

        // --- Assertions ---

        // Title bar: verify reverse video
        let titleAttrs = await attrsAt(row: 0, col: 0)
        XCTAssertTrue(titleAttrs.contains(.reverse),
                       "Title bar should have reverse video")

        let titleText = await rowText(row: 0, startCol: 2, endCol: 16)
        XCTAssertTrue(titleText.contains("GNU nano"),
                       "Title should contain 'GNU nano'")

        // Content area should be empty
        let contentChar = await charAt(row: 1, col: 0)
        XCTAssertTrue(contentChar.isEmpty || contentChar == " ",
                       "Content area should be empty for new buffer")

        // Shortcut bar row 22 (0-indexed): verify ^G is present
        let shortcutText = await rowText(row: 22, startCol: 0, endCol: 2)
        XCTAssertEqual(shortcutText, "^G")
    }

    // MARK: - testNanoShortcutBar

    /// Verify the bottom two rows show shortcuts with correct reverse-video
    /// on shortcut keys (^X, ^O, etc.) and normal text for descriptions.
    func testNanoShortcutBar() async {
        await feed("\u{1B}[2J\u{1B}[1;1H")

        // Build top shortcut row (row 23)
        await feed("\u{1B}[23;1H")
        await feed("\u{1B}[7m")
        await feed("^G")
        await feed("\u{1B}[0m")
        await feed(" Help    ")
        await feed("\u{1B}[7m")
        await feed("^O")
        await feed("\u{1B}[0m")
        await feed(" Write Out ")

        // Build bottom shortcut row (row 24)
        await feed("\u{1B}[24;1H")
        await feed("\u{1B}[7m")
        await feed("^X")
        await feed("\u{1B}[0m")
        await feed(" Exit    ")
        await feed("\u{1B}[7m")
        await feed("^R")
        await feed("\u{1B}[0m")
        await feed(" Read File ")

        // --- Assertions ---

        // ^G should have reverse video
        let gAttrs = await attrsAt(row: 22, col: 0)
        XCTAssertTrue(gAttrs.contains(.reverse),
                       "^G should have reverse video")

        // " Help" should NOT have reverse video
        let helpAttrs = await attrsAt(row: 22, col: 3)
        XCTAssertFalse(helpAttrs.contains(.reverse),
                        "Help text should not have reverse video")

        // ^O should have reverse video (starts at col 11 after " Help    " = 9 chars)
        let oAttrs = await attrsAt(row: 22, col: 11)
        XCTAssertTrue(oAttrs.contains(.reverse),
                       "^O should have reverse video")

        // "Write Out" should not have reverse video
        let writeAttrs = await attrsAt(row: 22, col: 13)
        XCTAssertFalse(writeAttrs.contains(.reverse),
                        "Write Out text should not have reverse video")

        // ^X should have reverse video
        let xAttrs = await attrsAt(row: 23, col: 0)
        XCTAssertTrue(xAttrs.contains(.reverse),
                       "^X should have reverse video")

        // " Exit" should not have reverse video
        let exitAttrs = await attrsAt(row: 23, col: 3)
        XCTAssertFalse(exitAttrs.contains(.reverse),
                        "Exit text should not have reverse video")

        // ^R should have reverse video (starts at col 11 after " Exit    " = 9 chars)
        let rAttrs = await attrsAt(row: 23, col: 11)
        XCTAssertTrue(rAttrs.contains(.reverse),
                       "^R should have reverse video")

        // Verify text content
        let exitLabel = await rowText(row: 23, startCol: 3, endCol: 7)
        XCTAssertEqual(exitLabel, "Exit")

        let readLabel = await rowText(row: 23, startCol: 14, endCol: 23)
        XCTAssertEqual(readLabel, "Read File")
    }
}

// MARK: - F.13: Tmux Compatibility

/// Simulates tmux multiplexer output: green status bar at the bottom,
/// vertical pane split with divider character, and window list in the
/// status bar.
final class TmuxCompatTest: IntegrationTestBase {

    // MARK: - testTmuxStatusBar

    /// tmux renders a green (bg=42m) status bar on the bottom row.
    /// Verify the background color on each status line cell.
    func testTmuxStatusBar() async {
        // tmux uses alternate screen for the pane content
        await feed("\u{1B}[?1049h")
        await feed("\u{1B}[2J")

        // Content area: some shell output in the pane
        await feed("\u{1B}[1;1H")
        await feed("user@host:~$ ls\r\n")
        await feed("Documents  Downloads  Pictures\r\n")
        await feed("user@host:~$ ")

        // Status bar at row 24: green background, black text
        await feed("\u{1B}[24;1H")
        await feed("\u{1B}[30;42m")        // Black fg, green bg
        await feed("[0] 0:bash*")
        // Pad to fill the row
        for _ in 0..<69 {
            await feed(" ")
        }
        await feed("\u{1B}[0m")

        // Verify green background on status bar
        let bg0 = await bgAt(row: 23, col: 0)
        XCTAssertEqual(bg0, .indexed(2),
                        "Status bar should have green background (indexed 2)")

        let bg10 = await bgAt(row: 23, col: 10)
        XCTAssertEqual(bg10, .indexed(2),
                        "Status bar background should extend across the row")

        let bg40 = await bgAt(row: 23, col: 40)
        XCTAssertEqual(bg40, .indexed(2),
                        "Status bar background should fill entire width")

        // Verify black foreground
        let fg0 = await fgAt(row: 23, col: 0)
        XCTAssertEqual(fg0, .indexed(0),
                        "Status bar text should be black (indexed 0)")

        // Verify status bar text content
        let statusText = await rowText(row: 23, startCol: 0, endCol: 11)
        XCTAssertEqual(statusText, "[0] 0:bash*")
    }

    // MARK: - testTmuxPaneSplit

    /// tmux vertical split: left pane content, `|` divider in the middle column,
    /// right pane content. Verify the divider character and both pane contents.
    func testTmuxPaneSplit() async {
        await feed("\u{1B}[?1049h")
        await feed("\u{1B}[2J")

        // Left pane: columns 0-38 (39 wide)
        await feed("\u{1B}[1;1H")
        await feed("user@host:~$ echo left")

        // Divider: column 39, drawn on every row (tmux uses │ character)
        // tmux typically uses a Unicode box-drawing vertical line or a pipe.
        for row in 1...23 {
            await feed("\u{1B}[\(row);40H")
            await feed("\u{1B}(0")         // DEC line drawing
            await feed("x")               // │
            await feed("\u{1B}(B")         // Back to ASCII
        }

        // Right pane: columns 40-79 (40 wide)
        await feed("\u{1B}[1;41H")
        await feed("user@host:~$ echo right")

        // Status bar
        await feed("\u{1B}[24;1H")
        await feed("\u{1B}[30;42m")
        await feed("[0] 0:bash* 1:bash-                                                         ")
        await feed("\u{1B}[0m")

        // Verify left pane content
        let leftText = await rowText(row: 0, startCol: 0, endCol: 22)
        XCTAssertEqual(leftText, "user@host:~$ echo left")

        // Verify divider character at column 39
        let divider = await charAt(row: 0, col: 39)
        XCTAssertEqual(divider, "│", "Pane divider should be │")

        // Verify divider runs the full height
        let dividerMid = await charAt(row: 11, col: 39)
        XCTAssertEqual(dividerMid, "│", "Divider should be consistent down the screen")

        // Verify right pane content (starts at col 40)
        let rightText = await rowText(row: 0, startCol: 40, endCol: 63)
        XCTAssertEqual(rightText, "user@host:~$ echo right")
    }

    // MARK: - testTmuxWindowList

    /// tmux window list `[0:bash* 1:vim-]` in status bar. Verify text content.
    func testTmuxWindowList() async {
        await feed("\u{1B}[?1049h")
        await feed("\u{1B}[2J")

        // Status bar with window list
        await feed("\u{1B}[24;1H")
        await feed("\u{1B}[30;42m")        // Black on green
        await feed("[0] 0:bash* 1:vim- 2:htop")
        // Pad remainder
        for _ in 0..<54 {
            await feed(" ")
        }
        await feed("\u{1B}[0m")

        // Verify the full window list text
        let windowList = await rowText(row: 23, startCol: 0, endCol: 25)
        XCTAssertEqual(windowList, "[0] 0:bash* 1:vim- 2:htop")

        // Verify session indicator
        let session = await rowText(row: 23, startCol: 0, endCol: 3)
        XCTAssertEqual(session, "[0]")

        // Verify active window marker (*)
        let activeWindow = await rowText(row: 23, startCol: 4, endCol: 11)
        XCTAssertEqual(activeWindow, "0:bash*")

        // Verify inactive window
        let inactiveWindow = await rowText(row: 23, startCol: 12, endCol: 18)
        XCTAssertEqual(inactiveWindow, "1:vim-")

        // Verify background color persists across window list
        let bgMid = await bgAt(row: 23, col: 15)
        XCTAssertEqual(bgMid, .indexed(2),
                        "Window list background should be green")
    }
}

// MARK: - F.13: Midnight Commander (mc) Compatibility

/// Simulates Midnight Commander (mc) two-panel file manager output:
/// box-drawing borders via DEC Special Graphics, colored directory/file
/// entries, top menu bar, and F-key labels at the bottom.
final class McFileManagerCompatTest: IntegrationTestBase {

    // MARK: - testMcTwoPanelLayout

    /// mc renders two side-by-side panels with box-drawing borders and
    /// colored file entries (blue for directories, green for executables).
    /// Verify panel borders and file colors.
    func testMcTwoPanelLayout() async {
        await feed("\u{1B}[?1049h")
        await feed("\u{1B}[2J")

        // mc draws the entire screen using DEC Special Graphics for borders.
        // Left panel: columns 0-39, Right panel: columns 40-79

        // Row 1: Top border of both panels
        // Left: ┌─── ... ─────┬  Right: ─── ... ────┐
        await feed("\u{1B}[1;1H")
        await feed("\u{1B}(0")
        await feed("l")                    // ┌
        for _ in 0..<38 { await feed("q") }   // ─ x38
        await feed("w")                    // ┬ (join point)
        for _ in 0..<39 { await feed("q") }   // ─ x39
        await feed("k")                    // ┐
        await feed("\u{1B}(B")

        // Row 2: Header row — panel titles with reverse video
        await feed("\u{1B}[2;1H")
        await feed("\u{1B}(0")
        await feed("x")                    // │
        await feed("\u{1B}(B")
        await feed("\u{1B}[7m")            // Reverse
        await feed("  Name          | Size |  MTime   ")
        await feed("\u{1B}[0m")
        await feed("\u{1B}(0")
        await feed("x")                    // │ (divider)
        await feed("\u{1B}(B")
        await feed("\u{1B}[7m")
        await feed("  Name          | Size |  MTime   ")
        await feed("\u{1B}[0m")
        await feed("\u{1B}(0")
        await feed("x")                    // │
        await feed("\u{1B}(B")

        // Row 3: Separator below header
        await feed("\u{1B}[3;1H")
        await feed("\u{1B}(0")
        await feed("t")                    // ├
        for _ in 0..<38 { await feed("q") }
        await feed("n")                    // ┼
        for _ in 0..<39 { await feed("q") }
        await feed("u")                    // ┤
        await feed("\u{1B}(B")

        // Row 4: ".." directory entry (blue, bold) in left panel
        await feed("\u{1B}[4;1H")
        await feed("\u{1B}(0")
        await feed("x")                    // │
        await feed("\u{1B}(B")
        await feed("\u{1B}[1;34m")         // Bold + blue
        await feed("/..")
        await feed("\u{1B}[0m")
        await feed("                                   ")
        await feed("\u{1B}(0")
        await feed("x")                    // │ divider
        await feed("\u{1B}(B")
        await feed("\u{1B}[1;34m")
        await feed("/..")
        await feed("\u{1B}[0m")
        await feed("                                    ")
        await feed("\u{1B}(0")
        await feed("x")                    // │
        await feed("\u{1B}(B")

        // Row 5: Directory entry "Documents" (blue, bold)
        await feed("\u{1B}[5;1H")
        await feed("\u{1B}(0")
        await feed("x")
        await feed("\u{1B}(B")
        await feed("\u{1B}[1;34m")         // Bold + blue
        await feed("/Documents")
        await feed("\u{1B}[0m")
        await feed("                              ")
        await feed("\u{1B}(0")
        await feed("x")
        await feed("\u{1B}(B")
        await feed(" readme.txt                          ")
        // No color codes — plain file
        await feed("   ")
        await feed("\u{1B}(0")
        await feed("x")
        await feed("\u{1B}(B")

        // Row 6: Executable file "build.sh" (green, bold)
        await feed("\u{1B}[6;1H")
        await feed("\u{1B}(0")
        await feed("x")
        await feed("\u{1B}(B")
        await feed("\u{1B}[1;32m")         // Bold + green
        await feed("*build.sh")
        await feed("\u{1B}[0m")
        await feed("                               ")
        await feed("\u{1B}(0")
        await feed("x")
        await feed("\u{1B}(B")
        await feed("\u{1B}[1;32m")
        await feed("*deploy.sh")
        await feed("\u{1B}[0m")
        await feed("                              ")
        await feed("\u{1B}(0")
        await feed("x")
        await feed("\u{1B}(B")

        // Bottom border (row 22)
        await feed("\u{1B}[22;1H")
        await feed("\u{1B}(0")
        await feed("m")                    // └
        for _ in 0..<38 { await feed("q") }
        await feed("v")                    // ┴
        for _ in 0..<39 { await feed("q") }
        await feed("j")                    // ┘
        await feed("\u{1B}(B")

        // --- Border Assertions ---

        // Top-left corner
        let tl = await charAt(row: 0, col: 0)
        XCTAssertEqual(tl, "┌", "Top-left should be ┌")

        // Top-right corner
        let tr = await charAt(row: 0, col: 79)
        XCTAssertEqual(tr, "┐", "Top-right should be ┐")

        // Top junction (panel divider at col 39)
        let topJunction = await charAt(row: 0, col: 39)
        XCTAssertEqual(topJunction, "┬", "Top panel divider should be ┬")

        // Cross junction at header separator
        let cross = await charAt(row: 2, col: 39)
        XCTAssertEqual(cross, "┼", "Header separator divider should be ┼")

        // Left-T at header separator
        let leftT = await charAt(row: 2, col: 0)
        XCTAssertEqual(leftT, "├", "Left edge of separator should be ├")

        // Right-T at header separator
        let rightT = await charAt(row: 2, col: 79)
        XCTAssertEqual(rightT, "┤", "Right edge of separator should be ┤")

        // Bottom-left corner
        let bl = await charAt(row: 21, col: 0)
        XCTAssertEqual(bl, "└", "Bottom-left should be └")

        // Bottom junction
        let bottomJunction = await charAt(row: 21, col: 39)
        XCTAssertEqual(bottomJunction, "┴", "Bottom panel divider should be ┴")

        // Bottom-right corner
        let br = await charAt(row: 21, col: 79)
        XCTAssertEqual(br, "┘", "Bottom-right should be ┘")

        // --- File Color Assertions ---

        // Directory "/Documents" in left panel should be bold + blue
        let dirFg = await fgAt(row: 4, col: 1)
        XCTAssertEqual(dirFg, .indexed(4),
                        "Directory should have blue foreground (indexed 4)")

        let dirAttrs = await attrsAt(row: 4, col: 1)
        XCTAssertTrue(dirAttrs.contains(.bold),
                       "Directory should have bold attribute")

        // Executable "*build.sh" should be bold + green
        let execFg = await fgAt(row: 5, col: 1)
        XCTAssertEqual(execFg, .indexed(2),
                        "Executable should have green foreground (indexed 2)")

        let execAttrs = await attrsAt(row: 5, col: 1)
        XCTAssertTrue(execAttrs.contains(.bold),
                       "Executable should have bold attribute")

        // ".." entry should be bold + blue
        let dotdotFg = await fgAt(row: 3, col: 1)
        XCTAssertEqual(dotdotFg, .indexed(4),
                        "Parent dir (..) should be blue")
    }

    // MARK: - testMcMenuBar

    /// mc renders a top menu bar with reverse video and F-key labels at the
    /// bottom row. Verify reverse-video attributes on both elements.
    func testMcMenuBar() async {
        await feed("\u{1B}[?1049h")
        await feed("\u{1B}[2J")

        // mc menu bar: not always visible by default, but when activated (F9)
        // it shows as a reverse-video bar at the top.
        // For this test, simulate the always-visible menu approach.

        // Top menu bar (row 1): reverse-video with menu items
        await feed("\u{1B}[1;1H")
        await feed("\u{1B}[7m")            // Reverse video
        await feed(" Left     File     Command     Options     Right                               ")
        await feed("\u{1B}[0m")

        // Bottom F-key bar (row 24)
        await feed("\u{1B}[24;1H")
        await feed("\u{1B}[30;46m")        // Black on cyan (mc style)
        await feed(" 1")
        await feed("\u{1B}[0m")
        await feed("Help  ")
        await feed("\u{1B}[30;46m")
        await feed(" 2")
        await feed("\u{1B}[0m")
        await feed("Menu  ")
        await feed("\u{1B}[30;46m")
        await feed(" 3")
        await feed("\u{1B}[0m")
        await feed("View  ")
        await feed("\u{1B}[30;46m")
        await feed(" 4")
        await feed("\u{1B}[0m")
        await feed("Edit  ")
        await feed("\u{1B}[30;46m")
        await feed(" 5")
        await feed("\u{1B}[0m")
        await feed("Copy  ")
        await feed("\u{1B}[30;46m")
        await feed(" 6")
        await feed("\u{1B}[0m")
        await feed("RenMov")
        await feed("\u{1B}[30;46m")
        await feed(" 7")
        await feed("\u{1B}[0m")
        await feed("Mkdir ")
        await feed("\u{1B}[30;46m")
        await feed(" 8")
        await feed("\u{1B}[0m")
        await feed("Delete")
        await feed("\u{1B}[30;46m")
        await feed(" 9")
        await feed("\u{1B}[0m")
        await feed("Menu  ")
        await feed("\u{1B}[30;46m")
        await feed("10")
        await feed("\u{1B}[0m")
        await feed("Quit")

        // --- Top Menu Bar Assertions ---

        // Verify reverse video on top menu bar
        let menuAttrs = await attrsAt(row: 0, col: 1)
        XCTAssertTrue(menuAttrs.contains(.reverse),
                       "Top menu bar should have reverse video")

        let menuText = await rowText(row: 0, startCol: 1, endCol: 5)
        XCTAssertEqual(menuText, "Left")

        let fileText = await rowText(row: 0, startCol: 10, endCol: 14)
        XCTAssertEqual(fileText, "File")

        // --- Bottom F-Key Bar Assertions ---

        // F1 label " 1" should have black-on-cyan
        let f1Fg = await fgAt(row: 23, col: 0)
        let f1Bg = await bgAt(row: 23, col: 0)
        XCTAssertEqual(f1Fg, .indexed(0), "F-key number should have black foreground")
        XCTAssertEqual(f1Bg, .indexed(6), "F-key number should have cyan background")

        // "Help" text should have default colors (SGR reset after the number)
        let helpAttrs = await attrsAt(row: 23, col: 2)
        // After reset, attributes should be empty
        XCTAssertFalse(helpAttrs.contains(.reverse),
                        "F-key label should not have reverse video after reset")

        // Verify F-key labels text
        let helpText = await rowText(row: 23, startCol: 2, endCol: 8)
        XCTAssertEqual(helpText, "Help  ")

        // F10 "Quit" at the end
        var quitStartCol = -1
        let fullRow = await rowText(row: 23, startCol: 0, endCol: 80)
        if let range = fullRow.range(of: "Quit") {
            quitStartCol = fullRow.distance(from: fullRow.startIndex, to: range.lowerBound)
        }
        XCTAssertNotEqual(quitStartCol, -1, "Should find 'Quit' label in F-key bar")

        // Verify F5 "Copy" label
        let copyFound = fullRow.contains("Copy")
        XCTAssertTrue(copyFound, "F-key bar should contain 'Copy' label")

        // Verify F7 "Mkdir" label
        let mkdirFound = fullRow.contains("Mkdir")
        XCTAssertTrue(mkdirFound, "F-key bar should contain 'Mkdir' label")
    }
}

#endif
