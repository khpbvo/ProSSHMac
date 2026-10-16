// CredentialPromptDetector.swift
// ProSSHMac
//
// Recognizes the password and passphrase prompts a copilot command can stop at (sudo, su, doas,
// an ssh hop, a key passphrase), so the awaited tool call pauses for the user instead of timing
// out. See Docs/CredentialPrompt.md.
import Foundation

nonisolated enum CredentialPromptDetector {
    enum Kind: Equatable, Sendable {
        case sudo
        case password
        case sshPassword
        case keyPassphrase
    }

    struct Match: Equatable, Sendable {
        let kind: Kind
        /// The prompt as the host printed it, without any `pwfeedback` asterisks.
        let prompt: String
    }

    /// How long the cursor must sit on a prompt with no further output before it counts.
    static let idle: Duration = .milliseconds(300)
    private static let maxTailBytes = 1_024

    private static let patterns: [(Kind, NSRegularExpression)] = [
        (.sudo, #"^\[sudo\] password for [^\s:]+:$"#),
        (.sshPassword, #"^\S+@\S+'s password:$"#),
        (.keyPassphrase, #"^enter passphrase for .+:$"#),
        (.password, #"^(\(current\) unix )?password( for [^:]+)?:$"#),
        (.password, #"^doas \(\S+\) password:$"#),
    ].compactMap { kind, pattern in
        (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])).map { (kind, $0) }
    }

    private static let retryNotices: Set<String> = [
        "sorry, try again.",
        "permission denied, please try again.",
    ]

    static func match(_ line: String) -> Match? {
        var prompt = line.trimmingCharacters(in: .whitespaces)
        guard !prompt.isEmpty, prompt.count <= 200 else { return nil }
        while prompt.last == "*" { prompt.removeLast() }
        prompt = prompt.trimmingCharacters(in: .whitespaces)
        let range = NSRange(prompt.startIndex..., in: prompt)
        guard let kind = patterns.first(where: { $0.1.firstMatch(in: prompt, range: range) != nil })?.0 else {
            return nil
        }
        return Match(kind: kind, prompt: prompt)
    }

    /// The line sudo or ssh prints before asking again after a wrong password.
    static func isRetryNotice(_ line: String) -> Bool {
        retryNotices.contains(line.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// The line the cursor is on at the end of `bytes`: empty right after a line break.
    static func cursorLine(in bytes: [UInt8]) -> String {
        let text = DeviceCLIText.normalize(Array(bytes.suffix(maxTailBytes)))
        let line = text.lastIndex(of: "\n").map { text[text.index(after: $0)...] } ?? text[...]
        return line.trimmingCharacters(in: .whitespaces)
    }

    /// Whether output after the user answered a prompt shows the command got past it: a complete,
    /// non-empty line that is neither a retry notice nor another prompt.
    static func showsProgress(afterAnswer bytes: [UInt8]) -> Bool {
        var lines = DeviceCLIText.normalize(bytes).components(separatedBy: "\n")
        lines.removeLast()  // the cursor line, still incomplete
        return lines.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !isRetryNotice(trimmed) && match(trimmed) == nil
        }
    }
}
