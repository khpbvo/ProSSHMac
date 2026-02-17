// QuickCommands.swift
// ProSSHV2
//
// E.5 — quick command snippets, host/global scoping, variable substitution,
// and JSON import/export for command libraries.

import Foundation
import Combine

struct QuickCommandVariable: Identifiable, Codable, Hashable, Sendable {
    var name: String
    var defaultValue: String

    var id: String { name }
}

struct QuickCommandSnippet: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var command: String
    var variables: [QuickCommandVariable]
    var hostID: UUID?
    var hostLabel: String?
    var createdAt: Date
    var updatedAt: Date

    var isGlobal: Bool {
        hostID == nil
    }

    func applies(toHostID hostID: UUID?) -> Bool {
        self.hostID == nil || self.hostID == hostID
    }
}

enum QuickCommandImportStrategy: Sendable {
    case merge
    case replace
}

enum QuickCommandsError: LocalizedError {
    case invalidName
    case invalidCommand
    case missingHostScope
    case invalidLibrary

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "Quick command name is required."
        case .invalidCommand:
            return "Quick command template is required."
        case .missingHostScope:
            return "Host-specific quick commands require a host."
        case .invalidLibrary:
            return "Selected JSON file is not a valid quick command library."
        }
    }
}

private struct QuickCommandLibrary: Codable {
    var version: Int
    var exportedAt: Date
    var snippets: [QuickCommandSnippet]
}

@MainActor
final class QuickCommands: ObservableObject {
    @Published private(set) var snippets: [QuickCommandSnippet] = []
    @Published var isDrawerPresented = false

    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        keyPrefix: String = "terminal.quickCommands"
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
        self.storageKey = "\(keyPrefix).snippets"
        loadFromDefaults()
    }

    func presentDrawer() {
        isDrawerPresented = true
    }

    func dismissDrawer() {
        isDrawerPresented = false
    }

    func toggleDrawer() {
        isDrawerPresented.toggle()
    }

    func snippets(for hostID: UUID?) -> [QuickCommandSnippet] {
        snippets.filter { $0.applies(toHostID: hostID) }
    }

    func placeholderVariables(in template: String) -> [String] {
        Self.placeholderVariables(in: template)
    }

    @discardableResult
    func saveSnippet(
        id: UUID? = nil,
        name: String,
        command: String,
        variableDefaults: [String: String],
        hostID: UUID?,
        hostLabel: String?
    ) throws -> QuickCommandSnippet {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty else {
            throw QuickCommandsError.invalidName
        }
        guard !trimmedCommand.isEmpty else {
            throw QuickCommandsError.invalidCommand
        }
        if hostID == nil && hostLabel != nil {
            throw QuickCommandsError.missingHostScope
        }

        let variableNames = Self.placeholderVariables(in: trimmedCommand)
        let variables = variableNames.map { name in
            QuickCommandVariable(
                name: name,
                defaultValue: variableDefaults[name, default: ""]
            )
        }

        let now = Date()
        let snippetID = id ?? UUID()

        if let existingIndex = snippets.firstIndex(where: { $0.id == snippetID }) {
            var existing = snippets[existingIndex]
            existing.name = trimmedName
            existing.command = trimmedCommand
            existing.variables = variables
            existing.hostID = hostID
            existing.hostLabel = hostLabel
            existing.updatedAt = now
            snippets[existingIndex] = existing
            sortAndPersist()
            return existing
        }

        let snippet = QuickCommandSnippet(
            id: snippetID,
            name: trimmedName,
            command: trimmedCommand,
            variables: variables,
            hostID: hostID,
            hostLabel: hostLabel,
            createdAt: now,
            updatedAt: now
        )
        snippets.append(snippet)
        sortAndPersist()
        return snippet
    }

    func removeSnippet(id: UUID) {
        snippets.removeAll { $0.id == id }
        persistToDefaults()
    }

    func resolvedCommand(for snippet: QuickCommandSnippet, values: [String: String]) -> String {
        var replacementByName: [String: String] = [:]
        for variable in snippet.variables {
            replacementByName[variable.name] = variable.defaultValue
        }
        for (name, value) in values {
            replacementByName[name] = value
        }

        return Self.replacingVariables(in: snippet.command, values: replacementByName)
    }

    func exportLibrary(destinationDirectory: URL? = nil) throws -> URL {
        let directory = destinationDirectory ?? Self.defaultExportDirectory(fileManager: fileManager)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"

        let filename = "quick-commands-\(formatter.string(from: Date())).json"
        let destinationURL = directory.appendingPathComponent(filename)

        let library = QuickCommandLibrary(version: 1, exportedAt: Date(), snippets: snippets)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(library)
        try data.write(to: destinationURL, options: [.atomic])
        return destinationURL
    }

    func importLibrary(from url: URL, strategy: QuickCommandImportStrategy = .merge) throws {
        let data = try Data(contentsOf: url)
        let imported = try Self.decodeLibrary(from: data)

        switch strategy {
        case .replace:
            snippets = imported
        case .merge:
            var mergedByID = Dictionary(uniqueKeysWithValues: snippets.map { ($0.id, $0) })
            for snippet in imported {
                mergedByID[snippet.id] = snippet
            }
            snippets = Array(mergedByID.values)
        }

        sortAndPersist()
    }

    private func loadFromDefaults() {
        guard let data = defaults.data(forKey: storageKey) else {
            snippets = []
            return
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            snippets = try decoder.decode([QuickCommandSnippet].self, from: data)
            sortAndPersist()
        } catch {
            snippets = []
        }
    }

    private func persistToDefaults() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            defaults.set(try encoder.encode(snippets), forKey: storageKey)
        } catch {
            defaults.removeObject(forKey: storageKey)
        }
    }

    private func sortAndPersist() {
        snippets.sort { lhs, rhs in
            if lhs.isGlobal != rhs.isGlobal {
                return lhs.isGlobal && !rhs.isGlobal
            }

            let lhsHost = lhs.hostLabel ?? ""
            let rhsHost = rhs.hostLabel ?? ""
            if lhsHost != rhsHost {
                return lhsHost.localizedCaseInsensitiveCompare(rhsHost) == .orderedAscending
            }

            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        persistToDefaults()
    }

    private static let variableRegex: NSRegularExpression = {
        let pattern = #"\{\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*\}\}"#
        return try! NSRegularExpression(pattern: pattern)
    }()

    private static func placeholderVariables(in template: String) -> [String] {
        let fullRange = NSRange(template.startIndex..<template.endIndex, in: template)
        let matches = variableRegex.matches(in: template, range: fullRange)

        var seen: Set<String> = []
        var names: [String] = []

        for match in matches {
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: template) else {
                continue
            }

            let name = String(template[range])
            guard seen.insert(name).inserted else { continue }
            names.append(name)
        }

        return names
    }

    private static func replacingVariables(in template: String, values: [String: String]) -> String {
        let fullRange = NSRange(template.startIndex..<template.endIndex, in: template)
        let matches = variableRegex.matches(in: template, range: fullRange)

        var resolved = template
        for match in matches.reversed() {
            guard match.numberOfRanges > 1,
                  let nameRange = Range(match.range(at: 1), in: template),
                  let fullMatchRange = Range(match.range(at: 0), in: resolved) else {
                continue
            }

            let variableName = String(template[nameRange])
            let replacement = values[variableName, default: ""]
            resolved.replaceSubrange(fullMatchRange, with: replacement)
        }

        return resolved
    }

    private static func decodeLibrary(from data: Data) throws -> [QuickCommandSnippet] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let library = try? decoder.decode(QuickCommandLibrary.self, from: data) {
            return library.snippets
        }

        if let snippets = try? decoder.decode([QuickCommandSnippet].self, from: data) {
            return snippets
        }

        throw QuickCommandsError.invalidLibrary
    }

    private static func defaultExportDirectory(fileManager: FileManager) -> URL {
        if let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            return documents.appendingPathComponent("QuickCommandLibraries", isDirectory: true)
        }

        return fileManager.temporaryDirectory.appendingPathComponent("QuickCommandLibraries", isDirectory: true)
    }
}
