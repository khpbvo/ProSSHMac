// CredentialPromptDetectorTests.swift
// ProSSHMac
//
// Password and passphrase prompt recognition for paused copilot commands (Docs/CredentialPrompt.md).

#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

@MainActor
final class CredentialPromptDetectorTests: XCTestCase {

    func testRecognizesEveryPromptForm() {
        let cases: [(String, CredentialPromptDetector.Kind)] = [
            ("[sudo] password for kevin:", .sudo),
            ("[sudo] password for kevin: ", .sudo),
            ("Password:", .password),                       // su, IOS enable, macOS sudo
            ("password:", .password),
            ("Password for kevin:", .password),
            ("Password for kevin@EXAMPLE.COM:", .password),
            ("(current) UNIX password:", .password),
            ("doas (kevin@testserv-02) password:", .password),
            ("kevin@testserv-02's password:", .sshPassword),
            ("root@10.0.0.4's password:", .sshPassword),
            ("Enter passphrase for key '/Users/kevin/.ssh/id_ed25519':", .keyPassphrase),
            ("Enter passphrase for /Users/kevin/.ssh/id_ed25519:", .keyPassphrase),
        ]
        for (line, kind) in cases {
            XCTAssertEqual(CredentialPromptDetector.match(line)?.kind, kind, line)
        }
    }

    func testIgnoresPwfeedbackAsterisksAndReportsThePromptWithoutThem() {
        let match = CredentialPromptDetector.match("[sudo] password for kevin: ******")
        XCTAssertEqual(match, .init(kind: .sudo, prompt: "[sudo] password for kevin:"))
    }

    func testRejectsLinesThatAreNotPrompts() {
        for line in [
            "", "   ",
            "Password: hunter2",                 // text after the colon is not a prompt
            "Changing password for kevin.",
            "password: required field",
            "# Password: is set in the vault",
            "kevin@testserv-02:~$", "Router#", "testserv-02(config)#",
            " --More-- ", "Sorry, try again.",
            String(repeating: "x", count: 200) + " password:",
        ] {
            XCTAssertNil(CredentialPromptDetector.match(line), line)
        }
    }

    func testCursorLineIsTheTextAfterTheLastLineBreak() {
        func line(_ text: String) -> String { CredentialPromptDetector.cursorLine(in: Array(text.utf8)) }
        XCTAssertEqual(line("output\r\n[sudo] password for kevin: "), "[sudo] password for kevin:")
        XCTAssertEqual(line("\r\nSorry, try again.\r\n[sudo] password for kevin: "), "[sudo] password for kevin:")
        XCTAssertEqual(line("[sudo] password for kevin: \r\n"), "", "the cursor is on a fresh line")
        XCTAssertEqual(line("\u{1B}[1mPassword:\u{1B}[0m "), "Password:")
        XCTAssertEqual(line(""), "")
    }

    func testCursorLineReadsOnlyTheTail() {
        let bytes = Array(("Password:\n" + String(repeating: "y", count: 4_000)).utf8)
        XCTAssertNil(CredentialPromptDetector.match(CredentialPromptDetector.cursorLine(in: bytes)))
    }

    func testRetryNotices() {
        XCTAssertTrue(CredentialPromptDetector.isRetryNotice("Sorry, try again."))
        XCTAssertTrue(CredentialPromptDetector.isRetryNotice("Permission denied, please try again."))
        XCTAssertFalse(CredentialPromptDetector.isRetryNotice("sudo: 3 incorrect password attempts"))
    }

    func testProgressAfterAnswerNeedsACompleteOrdinaryLine() {
        func progress(_ text: String) -> Bool { CredentialPromptDetector.showsProgress(afterAnswer: Array(text.utf8)) }
        XCTAssertFalse(progress("\r\n"), "sudo's own newline after reading the password")
        XCTAssertFalse(progress("\r\nSorry, try again.\r\n[sudo] password for kevin: "))
        XCTAssertFalse(progress("\r\nhello"), "an incomplete line may still turn into a prompt")
        XCTAssertTrue(progress("\r\nhello\r\n"))
        XCTAssertTrue(progress("\r\nsudo: 3 incorrect password attempts\r\n"))
    }
}
#endif
