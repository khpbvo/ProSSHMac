// LinkDetector.swift
// ProSSHV2
//
// URL/path/IP detection for terminal output.

import Foundation
import SwiftUI

struct DetectedLink: Identifiable, Sendable {
    enum Kind: String, Sendable {
        case url
        case filePath
        case ipAddress
    }

    let id = UUID()
    let kind: Kind
    let text: String
    let range: NSRange
    let destinationURL: URL

    var previewLabel: String {
        switch kind {
        case .url:
            return "URL: \(text)"
        case .filePath:
            return "Path: \(text)"
        case .ipAddress:
            return "IP: \(text)"
        }
    }
}

struct LinkDetector {
    private static let urlRegex = try! NSRegularExpression(
        pattern: #"(?i)\b((?:https?://|www\.)[^\s<>'"`]*(?:\([^\s<>'"`]*\)[^\s<>'"`]*)*)"#
    )
    private static let filePathRegex = try! NSRegularExpression(
        pattern: #"(?<!\w)(~\/[^\s:;,]+|\.\/[^\s:;,]+|\/(?:[\w\-.]+\/)+[\w\-.]+)"#
    )
    private static let ipv4Regex = try! NSRegularExpression(
        pattern: #"\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b"#
    )

    func detectLinks(in line: String) -> [DetectedLink] {
        guard !line.isEmpty else { return [] }
        let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
        var detected: [DetectedLink] = []

        collectMatches(
            regex: Self.urlRegex,
            kind: .url,
            in: line,
            fullRange: fullRange,
            into: &detected
        )
        collectMatches(
            regex: Self.filePathRegex,
            kind: .filePath,
            in: line,
            fullRange: fullRange,
            into: &detected
        )
        collectMatches(
            regex: Self.ipv4Regex,
            kind: .ipAddress,
            in: line,
            fullRange: fullRange,
            into: &detected
        )

        // Remove overlaps, preferring earlier ranges and then longer matches.
        let ordered = detected.sorted {
            if $0.range.location == $1.range.location {
                return $0.range.length > $1.range.length
            }
            return $0.range.location < $1.range.location
        }

        var filtered: [DetectedLink] = []
        for candidate in ordered {
            if filtered.contains(where: { NSIntersectionRange($0.range, candidate.range).length > 0 }) {
                continue
            }
            filtered.append(candidate)
        }

        return filtered
    }

    func attributedLine(_ line: String) -> AttributedString {
        let links = detectLinks(in: line)
        guard !links.isEmpty else {
            return AttributedString(line)
        }

        var attributed = AttributedString(line)
        for link in links {
            guard let stringRange = Range(link.range, in: line),
                  let attrRange = Range(stringRange, in: attributed) else {
                continue
            }
            attributed[attrRange].underlineStyle = .single
            attributed[attrRange].foregroundColor = .accentColor
            attributed[attrRange].link = link.destinationURL
        }
        return attributed
    }

    private func collectMatches(
        regex: NSRegularExpression,
        kind: DetectedLink.Kind,
        in line: String,
        fullRange: NSRange,
        into results: inout [DetectedLink]
    ) {
        let matches = regex.matches(in: line, options: [], range: fullRange)
        for match in matches {
            // Use the full match range to avoid capture-group index assumptions.
            let range = match.range
            guard range.location != NSNotFound,
                  let textRange = Range(range, in: line) else {
                continue
            }

            var value = String(line[textRange])
            value = trimTrailingPunctuation(value)
            guard !value.isEmpty else { continue }

            let adjustedLength = (value as NSString).length
            let adjustedRange = NSRange(location: range.location, length: adjustedLength)
            guard let destination = destinationURL(kind: kind, value: value) else {
                continue
            }

            results.append(
                DetectedLink(
                    kind: kind,
                    text: value,
                    range: adjustedRange,
                    destinationURL: destination
                )
            )
        }
    }

    private func trimTrailingPunctuation(_ text: String) -> String {
        var value = text
        // Count open and close parentheses to preserve balanced parens in URLs
        let trailing = CharacterSet(charactersIn: ".,;:!?)")
        while let scalar = value.unicodeScalars.last, trailing.contains(scalar) {
            if scalar == ")" {
                // Only trim closing paren if parentheses are unbalanced
                let openCount = value.filter { $0 == "(" }.count
                let closeCount = value.filter { $0 == ")" }.count
                if closeCount <= openCount {
                    break
                }
            }
            value.removeLast()
        }
        return value
    }

    private func destinationURL(kind: DetectedLink.Kind, value: String) -> URL? {
        switch kind {
        case .url:
            if value.lowercased().hasPrefix("http://") || value.lowercased().hasPrefix("https://") {
                return URL(string: value)
            }
            if value.lowercased().hasPrefix("www.") {
                return URL(string: "https://\(value)")
            }
            return nil

        case .ipAddress:
            return URL(string: "http://\(value)")

        case .filePath:
            let expanded = NSString(string: value).expandingTildeInPath
            return URL(fileURLWithPath: expanded)
        }
    }
}
