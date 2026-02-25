// Extracted from SSHConfigParser.swift
import Foundation

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
