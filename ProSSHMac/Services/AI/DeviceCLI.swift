// DeviceCLI.swift
// ProSSHMac
//
// Prompt classification and output capture for router, switch and appliance CLIs, which
// cannot run the POSIX wrapper `execute_and_wait` uses. See Docs/NetworkCopilot.md Phase 3.
import Foundation

/// What a session's cursor line looks like.
nonisolated enum DeviceCLIPrompt {
    enum Kind: Equatable, Sendable {
        case posixShell
        case deviceCLI
        case unknown
    }

    private static let vendorTypes: [ShellIntegrationType] = [
        .ciscoIOS, .juniperJunOS, .aristaEOS, .mikrotikRouterOS,
        .paloAltoPANOS, .hpProCurve, .fortinetFortiOS, .nokiaSROS,
    ]

    private static let vendorPatterns: [NSRegularExpression] = vendorTypes.compactMap { type in
        ShellIntegrationScripts.vendorPromptPattern(for: type).flatMap { try? NSRegularExpression(pattern: $0) }
    }

    private static let posixPatterns: [NSRegularExpression] = [
        #"^\S+@\S+:\S*\s?[$#]\s*$"#,                // kevin@host:~$, root@host:/etc#
        #"[$%]\s*$"#,                               // any $ or % prompt
        #"^(ba|z|k|da|tc|c)?sh(-[0-9.]+)?[$#]\s*$"#, // bash-5.1#, sh-5.2$
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// The last non-empty screen line: where the cursor sits at a prompt.
    static func cursorLine(in screenLines: [String]) -> String {
        let line = screenLines.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return line.trimmingCharacters(in: .whitespaces)
    }

    static func classify(_ line: String) -> Kind {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 200 else { return .unknown }
        if posixPatterns.contains(where: { matches($0, trimmed) }) { return .posixShell }
        if vendorPatterns.contains(where: { matches($0, trimmed) }) { return .deviceCLI }
        return .unknown
    }

    /// The part of a prompt that survives mode changes: `testserv-02` in `testserv-02(config)#`,
    /// `kevin@r1` in `kevin@r1>`, `[admin@MikroTik]` in `[admin@MikroTik] /ip>`.
    static func base(of prompt: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.@-[]"))
        let trimmed = prompt.trimmingCharacters(in: .whitespaces)
        let scalars = trimmed.unicodeScalars.prefix { allowed.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

/// Collects one device command's output and decides, from the text and how long the device has
/// been quiet, whether the command finished, a pager needs a key press, or the device asks a
/// question. Time is passed in, so the decisions are deterministic.
nonisolated struct DeviceCLICapture {
    enum Step: Equatable {
        case wait
        case advancePager
        case complete
        case awaitingInput(String)
    }

    static let maxPages = 1_000
    static let pagerIdle: Duration = .milliseconds(150)
    static let promptIdle: Duration = .milliseconds(300)
    static let promptIdleWithoutBase: Duration = .seconds(1)
    static let questionIdle: Duration = .seconds(2)
    private static let maxBytes = 4_000_000

    let command: String
    let promptBase: String
    private(set) var pagesAdvanced = 0
    private var bytes: [UInt8] = []
    private var bytesAtLastAdvance = -1

    init(command: String, startPrompt: String) {
        self.command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        self.promptBase = DeviceCLIPrompt.base(of: startPrompt)
    }

    mutating func ingest(_ data: some Sequence<UInt8>) {
        bytes.append(contentsOf: data)
        if bytes.count > Self.maxBytes {
            bytes.removeFirst(bytes.count - Self.maxBytes / 2)
            bytesAtLastAdvance = -1
        }
    }

    /// Call after sending the pager key; the next page must arrive before another press.
    mutating func didAdvancePager() {
        pagesAdvanced += 1
        bytesAtLastAdvance = bytes.count
    }

    func poll(idleFor idle: Duration) -> Step {
        let text = DeviceCLIText.normalize(bytes)
        guard let lastNewline = text.lastIndex(of: "\n") else { return .wait }  // still the echo
        let tail = String(text[text.index(after: lastNewline)...]).trimmingCharacters(in: .whitespaces)

        if DeviceCLIText.isPager(tail) {
            let newSinceAdvance = bytes.count > bytesAtLastAdvance
            return idle >= Self.pagerIdle && newSinceAdvance && pagesAdvanced < Self.maxPages ? .advancePager : .wait
        }
        if isPrompt(tail) {
            let needed = promptBase.isEmpty ? Self.promptIdleWithoutBase : Self.promptIdle
            return idle >= needed ? .complete : .wait
        }
        if idle >= Self.questionIdle, DeviceCLIText.isQuestion(tail) {
            return .awaitingInput(tail)
        }
        return .wait
    }

    /// The prompt the device returned to, once complete.
    var finalPrompt: String {
        let lines = DeviceCLIText.normalize(bytes).components(separatedBy: "\n")
        return (lines.last ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// The command's output: without the echoed command, pager prompts or the trailing prompt.
    func output(dropTrailingPrompt: Bool) -> String {
        var lines = DeviceCLIText.removePagers(DeviceCLIText.normalize(bytes)).components(separatedBy: "\n")
        if let first = lines.first, !command.isEmpty,
           first.trimmingCharacters(in: .whitespaces).hasSuffix(command) {
            lines.removeFirst()
        }
        if dropTrailingPrompt, let last = lines.last, isPrompt(last.trimmingCharacters(in: .whitespaces)) {
            lines.removeLast()
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        return lines.map { line in
            var line = line
            while line.last?.isWhitespace == true { line.removeLast() }
            return line
        }.joined(separator: "\n")
    }

    private func isPrompt(_ line: String) -> Bool {
        guard let last = line.last, "#>$%".contains(last), line.count <= 200 else { return false }
        return promptBase.isEmpty || line.hasPrefix(promptBase)
    }
}

/// Turns raw device output into the text a terminal would show, line by line.
nonisolated enum DeviceCLIText {
    private static let pagerPattern = #"(--\s*more\s*--|<-+\s*more\s*-+>|-+\s*\(\s*more(\s+\d+%)?\s*\)\s*-+|\(more\)|press any key to continue[^\n]*)"#
    private static let pagerLine = try? NSRegularExpression(pattern: "^\\s*" + pagerPattern + "\\s*$", options: [.caseInsensitive])
    private static let pagerAtLineStart = try? NSRegularExpression(
        pattern: "^[ \\t]*" + pagerPattern + "[ \\t]*",
        options: [.caseInsensitive, .anchorsMatchLines]
    )
    private static let questionPattern = try? NSRegularExpression(
        pattern: #"([?:\]]|\((y|yes)/(n|no)\)|\[(y|yes)/(n|no)\])\s*$"#,
        options: [.caseInsensitive]
    )

    static func isPager(_ line: String) -> Bool {
        guard let pagerLine else { return false }
        return pagerLine.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    static func isQuestion(_ line: String) -> Bool {
        guard !line.isEmpty, let questionPattern else { return false }
        return questionPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    static func removePagers(_ text: String) -> String {
        guard let pagerAtLineStart else { return text }
        return pagerAtLineStart.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: ""
        )
    }

    /// Escape sequences removed; backspace deletes a character; a carriage return that does not
    /// start a CRLF starts the line over, as pagers and line editors use it to overwrite.
    static func normalize(_ bytes: [UInt8]) -> String {
        let plain = TerminalPlainText.stripEscapes(bytes, keepingBackspace: true)
        var result: [UInt8] = []
        var line: [UInt8] = []
        result.reserveCapacity(plain.count)
        var index = 0
        while index < plain.count {
            let byte = plain[index]
            switch byte {
            case 0x0A:
                result.append(contentsOf: line)
                result.append(0x0A)
                line.removeAll(keepingCapacity: true)
            case 0x0D:
                let next = index + 1 < plain.count ? plain[index + 1] : nil
                if next != nil, next != 0x0A, next != 0x0D { line.removeAll(keepingCapacity: true) }
            case 0x08:
                while let last = line.last, (0x80...0xBF).contains(last) { line.removeLast() }
                if !line.isEmpty { line.removeLast() }
            default:
                line.append(byte)
            }
            index += 1
        }
        result.append(contentsOf: line)
        return String(decoding: result, as: UTF8.self)
    }
}
