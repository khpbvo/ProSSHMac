// Extracted from AIToolHandler.swift
import Foundation

extension AIToolHandler {

    // MARK: - Output Helpers

    static func commandBlockSummary(_ block: CommandBlock) -> OpenAIJSONValue {
        .object([
            "id": .string(block.id.uuidString.lowercased()),
            "command": .string(block.command),
            "output_preview": .string(String(block.output.prefix(150))),
            "started_at": .string(ISO8601DateFormatter().string(from: block.startedAt)),
            "exit_code": block.exitCode.map { .number(Double($0)) } ?? .null,
        ])
    }

    static func parseReadFileChunkOutput(
        _ output: String,
        path: String,
        startLine: Int,
        lineCount: Int,
        source: String
    ) -> OpenAIJSONValue {
        let normalized = output
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        if lines.contains(remotePathNotFoundToken) {
            return .object([
                "ok": .bool(false),
                "error": .string("Path does not exist: \(path)"),
            ])
        }
        if lines.contains(remoteNotRegularFileToken) {
            return .object([
                "ok": .bool(false),
                "error": .string("Path is not a regular file: \(path)"),
            ])
        }

        let boundedCount = max(1, min(200, lineCount))
        let content = lines.joined(separator: "\n")
        let hasMore = lines.count >= boundedCount
        let nextStart: OpenAIJSONValue = hasMore
            ? .number(Double(max(1, startLine) + lines.count))
            : .null

        return .object([
            "ok": .bool(true),
            "content": .string(content),
            "lines_returned": .number(Double(lines.count)),
            "has_more": .bool(hasMore),
            "next_start_line": nextStart,
        ])
    }

    static func readBoundViolationMessage(for command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()

        if lowered.hasPrefix("cat "), !lowered.contains("|"), !lowered.contains(">") {
            return "Full-file reads via 'cat' are disabled for AI execution. Read files in chunks of at most 200 lines."
        }

        if let n = firstCapturedInt(in: lowered, pattern: #"\bhead\s+-n\s+([0-9]+)\b"#), n > 200 {
            return "'head -n \(n)' exceeds the 200-line limit for AI file reads."
        }

        if let n = firstCapturedInt(in: lowered, pattern: #"\btail\s+-n\s+([0-9]+)\b"#), n > 200 {
            return "'tail -n \(n)' exceeds the 200-line limit for AI file reads."
        }

        if let range = firstCapturedRange(
            in: lowered,
            pattern: #"\bsed\s+-n\s+['\"]?([0-9]+),([0-9]+)p['\"]?"#
        ) {
            let requested = (range.end - range.start) + 1
            if requested > 200 {
                return "'sed -n \(range.start),\(range.end)p' exceeds the 200-line limit for AI file reads."
            }
        }

        if (lowered.contains("python") || lowered.contains("python3")) &&
            (lowered.contains("read_text(") || lowered.contains(".read()")) {
            return "Scripted full-file reads are disabled for AI execution. Read files in chunks of at most 200 lines."
        }

        return nil
    }

    static func firstCapturedInt(in text: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, options: [], range: fullRange),
              match.numberOfRanges > 1 else {
            return nil
        }
        let capture = match.range(at: 1)
        guard capture.location != NSNotFound else { return nil }
        return Int(nsText.substring(with: capture))
    }

    static func firstCapturedRange(in text: String, pattern: String) -> (start: Int, end: Int)? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, options: [], range: fullRange),
              match.numberOfRanges > 2 else {
            return nil
        }
        let startRange = match.range(at: 1)
        let endRange = match.range(at: 2)
        guard startRange.location != NSNotFound, endRange.location != NSNotFound else { return nil }
        guard let start = Int(nsText.substring(with: startRange)),
              let end = Int(nsText.substring(with: endRange)) else {
            return nil
        }
        return (start: start, end: end)
    }
}
