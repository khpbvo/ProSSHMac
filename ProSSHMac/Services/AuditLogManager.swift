import Foundation
import Combine

@MainActor
final class AuditLogManager: ObservableObject {
    @Published private(set) var entries: [AuditLogEntry] = []
    @Published var isEnabled: Bool {
        didSet {
            persistEnabledFlag()
        }
    }

    private let store: any AuditLogStoreProtocol
    private let userDefaults: UserDefaults
    private let enabledDefaultsKey: String
    private let displayLimit: Int

    init(
        store: any AuditLogStoreProtocol,
        userDefaults: UserDefaults = .standard,
        enabledDefaultsKey: String = "prossh.audit.enabled",
        displayLimit: Int = 200
    ) {
        self.store = store
        self.userDefaults = userDefaults
        self.enabledDefaultsKey = enabledDefaultsKey
        self.displayLimit = displayLimit
        self.isEnabled = userDefaults.object(forKey: enabledDefaultsKey) as? Bool ?? true
    }

    func refresh() async {
        do {
            entries = try await store.loadEntries(limit: displayLimit)
        } catch {
            entries = []
        }
    }

    func clearAll() async {
        do {
            try await store.clearAll()
            entries = []
        } catch {
            // Best-effort maintenance operation.
        }
    }

    func record(
        category: AuditLogCategory,
        action: String,
        outcome: AuditLogOutcome = .info,
        host: Host? = nil,
        sessionID: UUID? = nil,
        username: String? = nil,
        hostname: String? = nil,
        port: UInt16? = nil,
        details: String? = nil
    ) async {
        guard isEnabled else {
            return
        }

        let entry = AuditLogEntry(
            id: UUID(),
            timestamp: .now,
            category: category,
            action: action,
            outcome: outcome,
            hostLabel: host?.label,
            hostname: host?.hostname ?? hostname,
            port: host?.port ?? port,
            username: host?.username ?? username,
            sessionID: sessionID,
            details: details?.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        do {
            try await store.append(entry)
            entries.insert(entry, at: 0)
            if entries.count > displayLimit {
                entries.removeLast(entries.count - displayLimit)
            }
        } catch {
            // Never block user-facing flows when audit persistence fails.
        }
    }

    func exportPlainText() async -> String {
        let allEntries = await loadAllEntriesForExport()
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var lines: [String] = [
            "# ProSSH v2 Audit Log Export",
            "# Generated: \(dateFormatter.string(from: .now))",
            "# Entries: \(allEntries.count)",
            ""
        ]

        for entry in allEntries {
            let timestamp = dateFormatter.string(from: entry.timestamp)
            let endpoint = endpointText(for: entry)
            let subject = entry.username.map { "\($0)@" } ?? ""
            let detail = entry.details.map { " (\($0))" } ?? ""
            lines.append("[\(timestamp)] [\(entry.outcome.rawValue.uppercased())] [\(entry.category.title)] \(entry.action) \(subject)\(endpoint)\(detail)")
        }

        return lines.joined(separator: "\n")
    }

    func exportCSV() async -> String {
        let allEntries = await loadAllEntriesForExport()
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var lines: [String] = [
            "timestamp,outcome,category,action,hostLabel,hostname,port,username,sessionID,details"
        ]

        for entry in allEntries {
            let columns: [String] = [
                dateFormatter.string(from: entry.timestamp),
                entry.outcome.rawValue,
                entry.category.rawValue,
                entry.action,
                entry.hostLabel ?? "",
                entry.hostname ?? "",
                entry.port.map(String.init) ?? "",
                entry.username ?? "",
                entry.sessionID?.uuidString ?? "",
                entry.details ?? ""
            ]

            lines.append(columns.map(csvSafe).joined(separator: ","))
        }

        return lines.joined(separator: "\n")
    }

    func exportJSON() async -> String {
        let allEntries = await loadAllEntriesForExport()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(allEntries),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    private func persistEnabledFlag() {
        userDefaults.set(isEnabled, forKey: enabledDefaultsKey)
    }

    private func loadAllEntriesForExport() async -> [AuditLogEntry] {
        do {
            return try await store.loadEntries(limit: nil)
        } catch {
            return entries
        }
    }

    private func endpointText(for entry: AuditLogEntry) -> String {
        guard let hostname = entry.hostname else {
            return entry.hostLabel ?? "n/a"
        }
        if let port = entry.port {
            return "\(hostname):\(port)"
        }
        return hostname
    }

    private func csvSafe(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}
