// DeviceCLITests.swift
// ProSSHMac
//
// Prompt classification and output capture for router/switch CLIs (run_cli_command).

#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

@MainActor
final class DeviceCLITests: XCTestCase {

    // MARK: - Prompt classification

    func testClassifiesDevicePromptsAsDeviceCLI() {
        for prompt in [
            "testserv-02#",                 // FRR vtysh
            "Router>", "Router#", "Router(config)#", "Router(config-if)#",  // Cisco IOS
            "kevin@r1>", "kevin@r1#",       // Junos
            "[admin@MikroTik] >", "[admin@MikroTik] /ip/address>",  // RouterOS
            "leaf1(config)#",               // EOS
        ] {
            XCTAssertEqual(DeviceCLIPrompt.classify(prompt), .deviceCLI, prompt)
        }
    }

    func testClassifiesShellPromptsAsPOSIX() {
        for prompt in [
            "kevin@testserv-02:~$", "root@testserv-02:/etc#", "kevin@mac ~ %",
            "bash-5.1#", "sh-5.2$", "$",
        ] {
            XCTAssertEqual(DeviceCLIPrompt.classify(prompt), .posixShell, prompt)
        }
        XCTAssertEqual(DeviceCLIPrompt.classify(""), .unknown)
        XCTAssertEqual(DeviceCLIPrompt.classify("Building configuration..."), .unknown)
    }

    func testCursorLineIsLastNonEmptyLine() {
        XCTAssertEqual(DeviceCLIPrompt.cursorLine(in: ["output", "testserv-02# ", "", "  "]), "testserv-02#")
    }

    func testPromptBaseSurvivesModeChanges() {
        XCTAssertEqual(DeviceCLIPrompt.base(of: "testserv-02#"), "testserv-02")
        XCTAssertEqual(DeviceCLIPrompt.base(of: "kevin@r1>"), "kevin@r1")
        XCTAssertEqual(DeviceCLIPrompt.base(of: "[admin@MikroTik] >"), "[admin@MikroTik]")
        XCTAssertEqual(DeviceCLIPrompt.base(of: "kevin@testserv-02:~$"), "kevin@testserv-02")
    }

    // MARK: - Capture

    func testCompletesWhenPromptReturnsAndStripsEchoAndPrompt() {
        var capture = DeviceCLICapture(command: "show ip ospf neighbor", startPrompt: "testserv-02#")
        capture.ingest(Array("show ip ospf neighbor\r\n".utf8))
        XCTAssertEqual(capture.poll(idleFor: .seconds(5)), .wait, "Only the echo so far")
        capture.ingest(Array("Neighbor ID     Pri State\r\n10.255.255.3      1 Full/Backup\r\n\r\ntestserv-02# ".utf8))
        XCTAssertEqual(capture.poll(idleFor: .milliseconds(100)), .wait, "Prompt must stay quiet first")
        XCTAssertEqual(capture.poll(idleFor: DeviceCLICapture.promptIdle), .complete)
        XCTAssertEqual(capture.output(dropTrailingPrompt: true), "Neighbor ID     Pri State\n10.255.255.3      1 Full/Backup")
        XCTAssertEqual(capture.finalPrompt, "testserv-02#")
    }

    func testCompletesOnModeChangedPrompt() {
        var capture = DeviceCLICapture(command: "configure terminal", startPrompt: "testserv-02#")
        capture.ingest(Array("configure terminal\r\ntestserv-02(config)# ".utf8))
        XCTAssertEqual(capture.poll(idleFor: .seconds(1)), .complete)
        XCTAssertEqual(capture.output(dropTrailingPrompt: true), "")
        XCTAssertEqual(capture.finalPrompt, "testserv-02(config)#")
    }

    func testOtherPromptLikeLineDoesNotComplete() {
        var capture = DeviceCLICapture(command: "show run", startPrompt: "testserv-02#")
        capture.ingest(Array("show run\r\n!\r\ninterface lo\r\n ip address 10.255.255.2/32 >".utf8))
        XCTAssertEqual(capture.poll(idleFor: .seconds(1)), .wait)
    }

    func testPagerIsAdvancedOncePerPageAndErased() {
        var capture = DeviceCLICapture(command: "show running-config", startPrompt: "Switch#")
        capture.ingest(Array("show running-config\r\nline 1\r\nline 2\r\n --More-- ".utf8))
        XCTAssertEqual(capture.poll(idleFor: .milliseconds(50)), .wait)
        XCTAssertEqual(capture.poll(idleFor: DeviceCLICapture.pagerIdle), .advancePager)
        capture.didAdvancePager()
        XCTAssertEqual(capture.poll(idleFor: .seconds(1)), .wait, "No second press before the next page arrives")
        // IOS erases the pager with backspaces, spaces and backspaces.
        let erase = String(repeating: "\u{08}", count: 10) + String(repeating: " ", count: 10) + String(repeating: "\u{08}", count: 10)
        capture.ingest(Array((erase + "line 3\r\nend\r\nSwitch#").utf8))
        XCTAssertEqual(capture.poll(idleFor: .seconds(1)), .complete)
        XCTAssertEqual(capture.output(dropTrailingPrompt: true), "line 1\nline 2\nline 3\nend")
        XCTAssertEqual(capture.pagesAdvanced, 1)
    }

    func testCarriageReturnPagerEraseAndJunosPager() {
        var capture = DeviceCLICapture(command: "show configuration", startPrompt: "kevin@r1>")
        capture.ingest(Array("show configuration\r\nsystem {\r\n---(more 45%)---".utf8))
        XCTAssertEqual(capture.poll(idleFor: .seconds(1)), .advancePager)
        capture.didAdvancePager()
        capture.ingest(Array("\r                \r    host-name r1;\r\n}\r\n\r\nkevin@r1> ".utf8))
        XCTAssertEqual(capture.poll(idleFor: .seconds(1)), .complete)
        XCTAssertEqual(capture.output(dropTrailingPrompt: true), "system {\n    host-name r1;\n}")
    }

    func testQuestionIsReturnedAfterQuietPeriod() {
        var capture = DeviceCLICapture(command: "copy running-config startup-config", startPrompt: "Router#")
        capture.ingest(Array("copy running-config startup-config\r\nDestination filename [startup-config]? ".utf8))
        XCTAssertEqual(capture.poll(idleFor: .seconds(1)), .wait)
        XCTAssertEqual(
            capture.poll(idleFor: DeviceCLICapture.questionIdle),
            .awaitingInput("Destination filename [startup-config]?")
        )
    }

    /// What the coordinator's password wait reads from a device command's output.
    func testCursorLineAndLineBreaksForThePasswordWait() {
        var capture = DeviceCLICapture(command: "enable", startPrompt: "router>")
        capture.ingest(Array("enable\r\nPassword: ".utf8))
        XCTAssertEqual(capture.cursorLine, "Password:")
        let waitStart = capture.byteCount
        XCTAssertNil(capture.lineBreak(from: waitStart), "nothing typed yet")

        capture.ingest(Array("\r\nrouter#".utf8))
        let answer = try? XCTUnwrap(capture.lineBreak(from: waitStart))
        XCTAssertEqual(answer, waitStart)
        XCTAssertEqual(capture.rawBytes(since: waitStart), Array("\r\nrouter#".utf8))
        XCTAssertEqual(capture.cursorLine, "router#")
        XCTAssertEqual(capture.rawBytes(since: 10_000), [], "an offset past the end is clamped")
    }

    func testEscapesAndSplitChunks() {
        var capture = DeviceCLICapture(command: "show version", startPrompt: "leaf1#")
        let stream = Array("show version\r\n\u{1B}[1mArista\u{1B}[0m vEOS\r\nleaf1#".utf8)
        for offset in stride(from: 0, to: stream.count, by: 3) {
            capture.ingest(stream[offset..<min(offset + 3, stream.count)])
        }
        XCTAssertEqual(capture.poll(idleFor: .seconds(1)), .complete)
        XCTAssertEqual(capture.output(dropTrailingPrompt: true), "Arista vEOS")
    }
}
#endif
