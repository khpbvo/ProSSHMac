import Foundation

/// The open sessions the copilot can act on, as listed to the model each turn and by
/// `list_sessions`. Any connected session can be targeted by id; broadcast only sets the default.
@MainActor
enum AISessionDirectory {
    struct Entry: Equatable {
        let id: UUID
        let label: String
        let endpoint: String
        let focused: Bool
        let broadcast: Bool
        /// The cursor line when it is a router/switch/appliance prompt, else nil.
        var deviceCLIPrompt: String? = nil
    }

    /// Connected sessions, focused first, then by label.
    static func entries(
        sessions: [Session],
        focusedID: UUID,
        broadcastIDs: Set<UUID>,
        shellBuffers: [UUID: [String]] = [:]
    ) -> [Entry] {
        sessions
            .filter { $0.state == .connected }
            .map { session in
                Entry(
                    id: session.id,
                    label: session.hostLabel,
                    endpoint: session.isLocal ? "local shell" : "\(session.username)@\(session.hostname):\(session.port)",
                    focused: session.id == focusedID,
                    broadcast: broadcastIDs.contains(session.id),
                    deviceCLIPrompt: deviceCLIPrompt(shellBuffers[session.id] ?? [])
                )
            }
            .sorted {
                if $0.focused != $1.focused { return $0.focused }
                return $0.label.localizedStandardCompare($1.label) == .orderedAscending
            }
    }

    /// The sessions an untargeted tool call acts on.
    static func defaultTargets(focusedID: UUID, broadcastContext: BroadcastContext?) -> [UUID] {
        if let broadcastContext, broadcastContext.isBroadcasting { return broadcastContext.allSessionIDs }
        return [focusedID]
    }

    static func preamble(entries: [Entry], broadcasting: Bool) -> String {
        let defaultTarget = broadcasting
            ? "the \(entries.filter(\.broadcast).count) broadcast sessions"
            : "the focused session"
        let lines = entries.map { entry -> String in
            var flags: [String] = []
            if entry.focused { flags.append("focused") }
            if entry.broadcast { flags.append("broadcast") }
            if let prompt = entry.deviceCLIPrompt { flags.append("device CLI \"\(prompt)\"") }
            let suffix = flags.isEmpty ? "" : " · " + flags.joined(separator: " · ")
            return "- \(entry.id.uuidString): \(entry.label) — \(entry.endpoint)\(suffix)"
        }
        return "[Open sessions — pass an id as target_session; null targets \(defaultTarget)]\n"
            + lines.joined(separator: "\n") + "\n\n"
    }

    static func json(entries: [Entry], defaultTargets: [UUID]) -> LLMJSONValue {
        .object([
            "ok": .bool(true),
            "sessions": .array(entries.map { entry in
                .object([
                    "id": .string(entry.id.uuidString),
                    "label": .string(entry.label),
                    "endpoint": .string(entry.endpoint),
                    "focused": .bool(entry.focused),
                    "broadcast": .bool(entry.broadcast),
                    "device_cli_prompt": entry.deviceCLIPrompt.map { .string($0) } ?? .null,
                ])
            }),
            "default_targets": .array(defaultTargets.map { .string($0.uuidString) }),
        ])
    }

    private static func deviceCLIPrompt(_ screenLines: [String]) -> String? {
        let line = DeviceCLIPrompt.cursorLine(in: screenLines)
        return DeviceCLIPrompt.classify(line) == .deviceCLI ? line : nil
    }

    /// "Testserv4 — kevin@192.168.2.34:22", or "Local shell — <label>".
    static func describe(_ session: Session) -> String {
        session.isLocal
            ? "Local shell — \(session.hostLabel)"
            : "\(session.hostLabel) — \(session.username)@\(session.hostname):\(session.port)"
    }
}
