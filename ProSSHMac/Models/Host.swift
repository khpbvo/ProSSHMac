import Foundation

enum AuthMethod: String, Codable, CaseIterable, Identifiable {
    case password
    case publicKey
    case certificate
    case keyboardInteractive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .password: return "Password"
        case .publicKey: return "Public Key"
        case .certificate: return "Certificate"
        case .keyboardInteractive: return "Keyboard Interactive"
        }
    }
}

struct AlgorithmPreferences: Codable, Hashable {
    var keyExchange: [String] = []
    var hostKeys: [String] = []
    var ciphers: [String] = []
    var macs: [String] = []
}

struct PortForwardingRule: Identifiable, Codable, Hashable {
    var id: UUID
    var localPort: UInt16
    var remoteHost: String
    var remotePort: UInt16
    var label: String
    var isEnabled: Bool

    init(id: UUID = UUID(), localPort: UInt16, remoteHost: String, remotePort: UInt16, label: String = "", isEnabled: Bool = true) {
        self.id = id
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.label = label.isEmpty ? "\(localPort) → \(remoteHost):\(remotePort)" : label
        self.isEnabled = isEnabled
    }
}

struct Host: Identifiable, Codable, Hashable {
    var id: UUID
    var label: String
    var folder: String?
    var hostname: String
    var port: UInt16
    var username: String
    var authMethod: AuthMethod
    var keyReference: UUID?
    var certificateReference: UUID?
    var passwordReference: String?
    var hasSavedPassword: Bool { passwordReference != nil }
    var passphraseReference: String?
    var hasSavedPassphrase: Bool { passphraseReference != nil }
    var jumpHost: UUID?
    var algorithmPreferences: AlgorithmPreferences?
    var pinnedHostKeyAlgorithms: [String]
    var agentForwardingEnabled: Bool
    var portForwardingRules: [PortForwardingRule]
    var legacyModeEnabled: Bool
    var tags: [String]
    var notes: String?
    var lastConnected: Date?
    var createdAt: Date

    init(
        id: UUID,
        label: String,
        folder: String?,
        hostname: String,
        port: UInt16,
        username: String,
        authMethod: AuthMethod,
        keyReference: UUID?,
        certificateReference: UUID?,
        passwordReference: String?,
        passphraseReference: String? = nil,
        jumpHost: UUID?,
        algorithmPreferences: AlgorithmPreferences?,
        pinnedHostKeyAlgorithms: [String],
        agentForwardingEnabled: Bool = false,
        portForwardingRules: [PortForwardingRule] = [],
        legacyModeEnabled: Bool,
        tags: [String],
        notes: String?,
        lastConnected: Date?,
        createdAt: Date
    ) {
        self.id = id
        self.label = label
        self.folder = folder
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.keyReference = keyReference
        self.certificateReference = certificateReference
        self.passwordReference = passwordReference
        self.passphraseReference = passphraseReference
        self.jumpHost = jumpHost
        self.algorithmPreferences = algorithmPreferences
        self.pinnedHostKeyAlgorithms = pinnedHostKeyAlgorithms
        self.agentForwardingEnabled = agentForwardingEnabled
        self.portForwardingRules = portForwardingRules
        self.legacyModeEnabled = legacyModeEnabled
        self.tags = tags
        self.notes = notes
        self.lastConnected = lastConnected
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case folder
        case hostname
        case port
        case username
        case authMethod
        case keyReference
        case certificateReference
        case passwordReference
        case passphraseReference
        case jumpHost
        case algorithmPreferences
        case pinnedHostKeyAlgorithms
        case agentForwardingEnabled
        case portForwardingRules
        case legacyModeEnabled
        case tags
        case notes
        case lastConnected
        case createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        folder = try container.decodeIfPresent(String.self, forKey: .folder)
        hostname = try container.decode(String.self, forKey: .hostname)
        port = try container.decode(UInt16.self, forKey: .port)
        username = try container.decode(String.self, forKey: .username)
        authMethod = try container.decode(AuthMethod.self, forKey: .authMethod)
        keyReference = try container.decodeIfPresent(UUID.self, forKey: .keyReference)
        certificateReference = try container.decodeIfPresent(UUID.self, forKey: .certificateReference)
        passwordReference = try container.decodeIfPresent(String.self, forKey: .passwordReference)
        passphraseReference = try container.decodeIfPresent(String.self, forKey: .passphraseReference)
        jumpHost = try container.decodeIfPresent(UUID.self, forKey: .jumpHost)
        algorithmPreferences = try container.decodeIfPresent(AlgorithmPreferences.self, forKey: .algorithmPreferences)
        pinnedHostKeyAlgorithms = try container.decodeIfPresent([String].self, forKey: .pinnedHostKeyAlgorithms) ?? []
        agentForwardingEnabled = try container.decodeIfPresent(Bool.self, forKey: .agentForwardingEnabled) ?? false
        portForwardingRules = try container.decodeIfPresent([PortForwardingRule].self, forKey: .portForwardingRules) ?? []
        legacyModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .legacyModeEnabled) ?? false
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        lastConnected = try container.decodeIfPresent(Date.self, forKey: .lastConnected)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encodeIfPresent(folder, forKey: .folder)
        try container.encode(hostname, forKey: .hostname)
        try container.encode(port, forKey: .port)
        try container.encode(username, forKey: .username)
        try container.encode(authMethod, forKey: .authMethod)
        try container.encodeIfPresent(keyReference, forKey: .keyReference)
        try container.encodeIfPresent(certificateReference, forKey: .certificateReference)
        try container.encodeIfPresent(passwordReference, forKey: .passwordReference)
        try container.encodeIfPresent(passphraseReference, forKey: .passphraseReference)
        try container.encodeIfPresent(jumpHost, forKey: .jumpHost)
        try container.encodeIfPresent(algorithmPreferences, forKey: .algorithmPreferences)
        try container.encode(pinnedHostKeyAlgorithms, forKey: .pinnedHostKeyAlgorithms)
        try container.encode(agentForwardingEnabled, forKey: .agentForwardingEnabled)
        if !portForwardingRules.isEmpty {
            try container.encode(portForwardingRules, forKey: .portForwardingRules)
        }
        try container.encode(legacyModeEnabled, forKey: .legacyModeEnabled)
        try container.encode(tags, forKey: .tags)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encodeIfPresent(lastConnected, forKey: .lastConnected)
        try container.encode(createdAt, forKey: .createdAt)
    }

    static func bootstrapHosts() -> [Host] {
        [
            Host(
                id: UUID(),
                label: "Core Router (Legacy)",
                folder: "Network",
                hostname: "router-old.local",
                port: 22,
                username: "admin",
                authMethod: .password,
                keyReference: nil,
                certificateReference: nil,
                passwordReference: nil,
                jumpHost: nil,
                algorithmPreferences: nil,
                pinnedHostKeyAlgorithms: [],
                agentForwardingEnabled: false,
                legacyModeEnabled: true,
                tags: ["network", "lab"],
                notes: "Sample legacy-capable host.",
                lastConnected: nil,
                createdAt: .now
            ),
            Host(
                id: UUID(),
                label: "Linux Jump Host",
                folder: "Servers",
                hostname: "jumpbox.local",
                port: 22,
                username: "ops",
                authMethod: .publicKey,
                keyReference: nil,
                certificateReference: nil,
                passwordReference: nil,
                jumpHost: nil,
                algorithmPreferences: nil,
                pinnedHostKeyAlgorithms: [],
                agentForwardingEnabled: false,
                legacyModeEnabled: false,
                tags: ["linux", "prod"],
                notes: "Sample modern host.",
                lastConnected: nil,
                createdAt: .now
            )
        ]
    }
}

struct HostDraft: Equatable {
    var label: String = ""
    var folder: String = ""
    var hostname: String = ""
    var port: String = "22"
    var username: String = ""
    var authMethod: AuthMethod = .publicKey
    var legacyModeEnabled: Bool = false
    var pinnedHostKeyAlgorithms: String = ""
    var agentForwardingEnabled: Bool = false
    var portForwardingRules: [PortForwardingRule] = []
    var keyReference: UUID? = nil
    var tags: String = ""
    var notes: String = ""
    var jumpHost: UUID? = nil

    var validationError: String? {
        if label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Host label is required."
        }
        if hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Hostname or IP is required."
        }
        if username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Username is required."
        }
        guard let numericPort = UInt16(port), numericPort > 0 else {
            return "Port must be between 1 and 65535."
        }
        return nil
    }

    func jumpHostValidationError(hostID: UUID?, allHosts: [Host]) -> String? {
        guard let jh = jumpHost else { return nil }
        if let hostID, jh == hostID { return "A host cannot use itself as a jump host." }
        if let target = allHosts.first(where: { $0.id == jh }),
           target.jumpHost != nil { return "Chained jump hosts are not supported." }
        return nil
    }

    func toHost(id: UUID = UUID(), createdAt: Date = .now, lastConnected: Date? = nil) -> Host {
        Host(
            id: id,
            label: label.trimmingCharacters(in: .whitespacesAndNewlines),
            folder: normalizedFolder,
            hostname: hostname.trimmingCharacters(in: .whitespacesAndNewlines),
            port: UInt16(port) ?? 22,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            authMethod: authMethod,
            keyReference: keyReference,
            certificateReference: nil,
            passwordReference: nil,
            jumpHost: jumpHost,
            algorithmPreferences: nil,
            pinnedHostKeyAlgorithms: parsedPinnedHostKeyAlgorithms,
            agentForwardingEnabled: agentForwardingEnabled,
            portForwardingRules: portForwardingRules,
            legacyModeEnabled: legacyModeEnabled,
            tags: parsedTags,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : notes.trimmingCharacters(in: .whitespacesAndNewlines),
            lastConnected: lastConnected,
            createdAt: createdAt
        )
    }

    private var normalizedFolder: String? {
        let trimmed = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var parsedTags: [String] {
        tags
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var parsedPinnedHostKeyAlgorithms: [String] {
        pinnedHostKeyAlgorithms
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

extension HostDraft {
    init(from host: Host) {
        self.label = host.label
        self.folder = host.folder ?? ""
        self.hostname = host.hostname
        self.port = String(host.port)
        self.username = host.username
        self.authMethod = host.authMethod
        self.legacyModeEnabled = host.legacyModeEnabled
        self.pinnedHostKeyAlgorithms = host.pinnedHostKeyAlgorithms.joined(separator: ", ")
        self.agentForwardingEnabled = host.agentForwardingEnabled
        self.portForwardingRules = host.portForwardingRules
        self.keyReference = host.keyReference
        self.tags = host.tags.joined(separator: ", ")
        self.notes = host.notes ?? ""
        self.jumpHost = host.jumpHost
    }
}
