// swiftlint:disable file_length
// SSHConfigParser.swift
// SSH config import/export for ProSSHMac
//
// Parses ~/.ssh/config into intermediate SSHConfigEntry values,
// maps them to ProSSHMac Host models, and exports Hosts back to
// SSH config format. Pure value types — no side effects, fully testable.

import Foundation

// MARK: - Parsed Intermediate Representation

/// A single directive from an SSH config file (e.g., `HostName 10.0.0.1`).
struct SSHConfigDirective: Equatable, Sendable {
    let keyword: String          // Lowercased canonical form
    let originalKeyword: String  // Preserves original casing for export
    let arguments: String        // Raw argument string (not split)
    let lineNumber: Int
}

/// One `Host` or `Match` block from an SSH config file, plus all its directives.
/// Wildcard-only blocks (e.g., `Host *`) are captured as global defaults.
struct SSHConfigEntry: Equatable, Sendable {
    /// The pattern(s) from the `Host` line, e.g., ["web-*", "db-*"] or ["*"].
    let patterns: [String]

    /// Whether this came from a `Match` block (vs. a `Host` block).
    let isMatchBlock: Bool

    /// All directives within this block, in file order.
    let directives: [SSHConfigDirective]

    /// The line number where this block's Host/Match keyword appeared.
    let startLine: Int

    /// True if this is a `Host *` block (global defaults).
    var isGlobalDefaults: Bool {
        !isMatchBlock && patterns == ["*"]
    }

    /// Look up the first directive matching a keyword (case-insensitive).
    /// SSH config uses first-match semantics — the first value wins.
    func firstValue(for keyword: String) -> String? {
        let key = keyword.lowercased()
        return directives.first(where: { $0.keyword == key })?.arguments
    }

    /// Look up all directives matching a keyword (for multi-value keys like LocalForward).
    func allValues(for keyword: String) -> [String] {
        let key = keyword.lowercased()
        return directives.filter { $0.keyword == key }.map(\.arguments)
    }
}

/// Result of parsing an entire SSH config file.
struct SSHConfigParseResult: Sendable {
    /// All Host/Match blocks, in file order.
    let entries: [SSHConfigEntry]

    /// Lines that couldn't be parsed (with line numbers and reason).
    let warnings: [SSHConfigWarning]

    /// Global defaults (`Host *` block), if present.
    var globalDefaults: SSHConfigEntry? {
        entries.first(where: \.isGlobalDefaults)
    }

    /// Concrete host entries (excludes wildcards and Match blocks).
    var concreteHosts: [SSHConfigEntry] {
        entries.filter { entry in
            !entry.isMatchBlock
            && !entry.isGlobalDefaults
            && entry.patterns.allSatisfy { !$0.contains("*") && !$0.contains("?") }
        }
    }
}

struct SSHConfigWarning: Sendable {
    let lineNumber: Int
    let line: String
    let reason: String
}

// MARK: - Parser

/// Parses `~/.ssh/config` format into structured `SSHConfigEntry` values.
///
/// Handles:
/// - Host blocks with single or multiple patterns
/// - Match blocks (captured but not expanded)
/// - Quoted arguments (`"my key file"`)
/// - Inline comments (`# ...`)
/// - Continuation of global scope before any Host/Match block
/// - Case-insensitive keyword matching (SSH config is case-insensitive for keywords)
///
/// Does NOT handle:
/// - `Include` directive expansion (returns a warning; caller should expand before parsing)
/// - Token expansion (`%h`, `%u`, `%p`, etc.) — done at mapping stage
/// - `Match` condition evaluation — blocks are captured verbatim
struct SSHConfigParser: Sendable {

    /// Parse the contents of an SSH config file.
    ///
    /// - Parameter contents: The full text of `~/.ssh/config`.
    /// - Returns: A `SSHConfigParseResult` with all parsed entries and any warnings.
    func parse(_ contents: String) -> SSHConfigParseResult {
        let lines = contents.components(separatedBy: .newlines)
        var entries: [SSHConfigEntry] = []
        var warnings: [SSHConfigWarning] = []

        // Directives before the first Host/Match line are implicitly `Host *`.
        var currentPatterns: [String] = ["*"]
        var currentIsMatch = false
        var currentStartLine = 1
        var currentDirectives: [SSHConfigDirective] = []
        var hasExplicitBlock = false

        for (index, rawLine) in lines.enumerated() {
            let lineNumber = index + 1
            let line = stripComment(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip blank lines.
            if trimmed.isEmpty { continue }

            // Split into keyword + arguments.
            guard let (keyword, arguments) = splitDirective(trimmed) else {
                warnings.append(SSHConfigWarning(
                    lineNumber: lineNumber,
                    line: rawLine,
                    reason: "Could not parse directive"
                ))
                continue
            }

            let keyLower = keyword.lowercased()

            // Handle block-starting keywords.
            if keyLower == "host" || keyLower == "match" {
                // Flush the previous block.
                if hasExplicitBlock || !currentDirectives.isEmpty {
                    entries.append(SSHConfigEntry(
                        patterns: currentPatterns,
                        isMatchBlock: currentIsMatch,
                        directives: currentDirectives,
                        startLine: currentStartLine
                    ))
                }

                currentPatterns = keyLower == "host"
                    ? splitHostPatterns(arguments)
                    : [arguments]  // Match keeps the full condition string
                currentIsMatch = (keyLower == "match")
                currentStartLine = lineNumber
                currentDirectives = []
                hasExplicitBlock = true

                if keyLower == "match" {
                    warnings.append(SSHConfigWarning(
                        lineNumber: lineNumber,
                        line: rawLine,
                        reason: "Match blocks are captured but conditions are not evaluated"
                    ))
                }
                continue
            }

            // Handle Include — warn but don't expand.
            if keyLower == "include" {
                warnings.append(SSHConfigWarning(
                    lineNumber: lineNumber,
                    line: rawLine,
                    reason: "Include directive not expanded; resolve includes before parsing"
                ))
                continue
            }

            // Regular directive — add to current block.
            currentDirectives.append(SSHConfigDirective(
                keyword: keyLower,
                originalKeyword: keyword,
                arguments: arguments,
                lineNumber: lineNumber
            ))
        }

        // Flush the last block.
        if hasExplicitBlock || !currentDirectives.isEmpty {
            entries.append(SSHConfigEntry(
                patterns: currentPatterns,
                isMatchBlock: currentIsMatch,
                directives: currentDirectives,
                startLine: currentStartLine
            ))
        }

        return SSHConfigParseResult(entries: entries, warnings: warnings)
    }

    // MARK: - Private Helpers

    /// Strip inline comments. Respects quoted strings — `#` inside quotes is literal.
    private func stripComment(_ line: String) -> String {
        var inQuote = false
        var result: [Character] = []

        for char in line {
            if char == "\"" { inQuote.toggle() }
            if char == "#" && !inQuote { break }
            result.append(char)
        }

        return String(result)
    }

    /// Split a trimmed line into (keyword, arguments).
    /// SSH config allows both `Keyword value` (space) and `Keyword=value` (equals).
    private func splitDirective(_ trimmed: String) -> (String, String)? {
        // Try equals-separated first: `Keyword=value`
        if let eqIndex = trimmed.firstIndex(of: "=") {
            let keyword = String(trimmed[trimmed.startIndex..<eqIndex])
                .trimmingCharacters(in: .whitespaces)
            let arguments = String(trimmed[trimmed.index(after: eqIndex)...])
                .trimmingCharacters(in: .whitespaces)
            guard !keyword.isEmpty else { return nil }
            return (keyword, stripQuotes(arguments))
        }

        // Space-separated: `Keyword value`
        guard let spaceIndex = trimmed.firstIndex(where: { $0.isWhitespace }) else {
            // Keyword with no arguments (e.g., bare `Host` — malformed but don't crash).
            return (trimmed, "")
        }

        let keyword = String(trimmed[trimmed.startIndex..<spaceIndex])
        let arguments = String(trimmed[trimmed.index(after: spaceIndex)...])
            .trimmingCharacters(in: .whitespaces)
        return (keyword, stripQuotes(arguments))
    }

    /// Remove surrounding quotes from a value if present.
    private func stripQuotes(_ value: String) -> String {
        if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    /// Split `Host` patterns — multiple patterns on one `Host` line are space-separated.
    /// Handles quoted patterns: `Host "my server" other-server`
    private func splitHostPatterns(_ arguments: String) -> [String] {
        var patterns: [String] = []
        var current = ""
        var inQuote = false

        for char in arguments {
            if char == "\"" {
                inQuote.toggle()
                continue
            }
            if char.isWhitespace && !inQuote {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { patterns.append(trimmed) }
                current = ""
                continue
            }
            current.append(char)
        }

        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { patterns.append(trimmed) }

        return patterns.isEmpty ? ["*"] : patterns
    }
}

// MARK: - Token Expansion

/// Expands SSH config tokens (`%h`, `%u`, `%p`, etc.) in directive values.
///
/// Supported tokens:
/// - `%h` — remote hostname
/// - `%u` — remote username
/// - `%p` — remote port
/// - `%r` — remote username (alias for `%u` in most contexts)
/// - `%n` — original hostname as given on the command line (same as `%h` for us)
/// - `%l` — local hostname (short form)
/// - `%L` — local hostname (full FQDN)
/// - `%d` — local user's home directory
/// - `%%` — literal `%`
// MARK: - Import Service (Orchestrator)

/// High-level service that orchestrates the full SSH config import pipeline.
///
/// Usage:
/// ```swift
/// let service = SSHConfigImportService()
/// let preview = try service.preview(configText: contents, existingHosts: hosts, existingKeys: keys)
/// // User reviews preview...
/// let importedHosts = preview.results.map(\.host)
/// ```
struct SSHConfigImportService: Sendable {

    struct ImportPreview: Sendable {
        /// Parsed entries mapped to hosts, with per-host notes.
        let results: [SSHConfigMapper.MappingResult]

        /// Parser-level warnings (malformed lines, unsupported features).
        let parserWarnings: [SSHConfigWarning]

        /// Number of entries skipped (wildcards, Match blocks).
        let skippedEntries: Int

        /// Summary string for display.
        var summary: String {
            let imported = results.count
            let withNotes = results.filter { !$0.notes.isEmpty }.count
            var parts = ["\(imported) host\(imported == 1 ? "" : "s") ready to import"]
            if withNotes > 0 {
                parts.append("\(withNotes) with notes")
            }
            if skippedEntries > 0 {
                parts.append("\(skippedEntries) skipped (wildcards/match blocks)")
            }
            if !parserWarnings.isEmpty {
                parts.append("\(parserWarnings.count) parser warning\(parserWarnings.count == 1 ? "" : "s")")
            }
            return parts.joined(separator: ", ")
        }
    }

    private let parser = SSHConfigParser()
    private let mapper = SSHConfigMapper()

    /// Parse an SSH config string and produce an import preview.
    ///
    /// The preview contains mapped hosts ready for user review before committing the import.
    func preview(
        configText: String,
        existingHosts: [Host] = [],
        existingKeys: [StoredSSHKey] = []
    ) -> ImportPreview {
        let parseResult = parser.parse(configText)

        let totalEntries = parseResult.entries.count
        let concreteCount = parseResult.concreteHosts.count
        let skipped = totalEntries - concreteCount

        let results = mapper.importAll(
            from: parseResult,
            existingHosts: existingHosts,
            existingKeys: existingKeys
        )

        return ImportPreview(
            results: results,
            parserWarnings: parseResult.warnings,
            skippedEntries: skipped
        )
    }

    /// Read the default SSH config file from disk.
    ///
    /// - Returns: The file contents, or `nil` if the file doesn't exist.
    func readDefaultConfig() -> String? {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/config")
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    /// Read an SSH config file from an arbitrary path.
    func readConfig(at path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }
}

// MARK: - Duplicate Detection

extension SSHConfigImportService {

    /// Check for duplicates between import candidates and existing hosts.
    ///
    /// Returns pairs of (imported host, existing host) that match on hostname+username+port.
    func findDuplicates(
        imported: [Host],
        existing: [Host]
    ) -> [(imported: Host, existing: Host)] {
        imported.compactMap { candidate in
            let match = existing.first { existing in
                existing.hostname.lowercased() == candidate.hostname.lowercased()
                && existing.username.lowercased() == candidate.username.lowercased()
                && existing.port == candidate.port
            }
            return match.map { (imported: candidate, existing: $0) }
        }
    }
}
