import Foundation

enum SessionState: String, Codable {
    case connecting
    case connected
    case disconnected
    case failed
}

enum SessionKind: Codable, Hashable {
    case ssh(hostID: UUID)
    case local
}

struct Session: Identifiable, Codable, Hashable {
    var id: UUID
    var kind: SessionKind
    var hostLabel: String
    var username: String
    var hostname: String
    var port: UInt16
    var state: SessionState
    var negotiatedKEX: String?
    var negotiatedCipher: String?
    var negotiatedHostKeyType: String?
    var negotiatedHostFingerprint: String?
    var usesLegacyCrypto: Bool
    var usesAgentForwarding: Bool
    var securityAdvisory: String?
    var transportBackend: SSHBackendKind?
    var jumpHostLabel: String?
    var shellPath: String?
    var startedAt: Date
    var endedAt: Date?
    var errorMessage: String?

    /// Backward-compatible computed property.
    var hostID: UUID {
        switch kind {
        case let .ssh(hostID):
            return hostID
        case .local:
            return UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        }
    }

    var isLocal: Bool {
        if case .local = kind { return true }
        return false
    }

    // MARK: - Backward-compatible decoding

    enum CodingKeys: String, CodingKey {
        case id, kind, hostLabel, username, hostname, port, state
        case negotiatedKEX, negotiatedCipher, negotiatedHostKeyType, negotiatedHostFingerprint
        case usesLegacyCrypto, usesAgentForwarding, securityAdvisory, transportBackend
        case jumpHostLabel, shellPath, startedAt, endedAt, errorMessage
        // Legacy key
        case hostID
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(hostLabel, forKey: .hostLabel)
        try container.encode(username, forKey: .username)
        try container.encode(hostname, forKey: .hostname)
        try container.encode(port, forKey: .port)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(negotiatedKEX, forKey: .negotiatedKEX)
        try container.encodeIfPresent(negotiatedCipher, forKey: .negotiatedCipher)
        try container.encodeIfPresent(negotiatedHostKeyType, forKey: .negotiatedHostKeyType)
        try container.encodeIfPresent(negotiatedHostFingerprint, forKey: .negotiatedHostFingerprint)
        try container.encode(usesLegacyCrypto, forKey: .usesLegacyCrypto)
        try container.encode(usesAgentForwarding, forKey: .usesAgentForwarding)
        try container.encodeIfPresent(securityAdvisory, forKey: .securityAdvisory)
        try container.encodeIfPresent(transportBackend, forKey: .transportBackend)
        try container.encodeIfPresent(jumpHostLabel, forKey: .jumpHostLabel)
        try container.encodeIfPresent(shellPath, forKey: .shellPath)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(endedAt, forKey: .endedAt)
        try container.encodeIfPresent(errorMessage, forKey: .errorMessage)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)

        if let decodedKind = try container.decodeIfPresent(SessionKind.self, forKey: .kind) {
            kind = decodedKind
        } else if let legacyHostID = try container.decodeIfPresent(UUID.self, forKey: .hostID) {
            kind = .ssh(hostID: legacyHostID)
        } else {
            kind = .local
        }

        hostLabel = try container.decode(String.self, forKey: .hostLabel)
        username = try container.decode(String.self, forKey: .username)
        hostname = try container.decode(String.self, forKey: .hostname)
        port = try container.decode(UInt16.self, forKey: .port)
        state = try container.decode(SessionState.self, forKey: .state)
        negotiatedKEX = try container.decodeIfPresent(String.self, forKey: .negotiatedKEX)
        negotiatedCipher = try container.decodeIfPresent(String.self, forKey: .negotiatedCipher)
        negotiatedHostKeyType = try container.decodeIfPresent(String.self, forKey: .negotiatedHostKeyType)
        negotiatedHostFingerprint = try container.decodeIfPresent(String.self, forKey: .negotiatedHostFingerprint)
        usesLegacyCrypto = try container.decode(Bool.self, forKey: .usesLegacyCrypto)
        usesAgentForwarding = try container.decode(Bool.self, forKey: .usesAgentForwarding)
        securityAdvisory = try container.decodeIfPresent(String.self, forKey: .securityAdvisory)
        transportBackend = try container.decodeIfPresent(SSHBackendKind.self, forKey: .transportBackend)
        jumpHostLabel = try container.decodeIfPresent(String.self, forKey: .jumpHostLabel)
        shellPath = try container.decodeIfPresent(String.self, forKey: .shellPath)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
    }

    init(
        id: UUID = UUID(),
        kind: SessionKind,
        hostLabel: String,
        username: String,
        hostname: String,
        port: UInt16,
        state: SessionState,
        negotiatedKEX: String? = nil,
        negotiatedCipher: String? = nil,
        negotiatedHostKeyType: String? = nil,
        negotiatedHostFingerprint: String? = nil,
        usesLegacyCrypto: Bool = false,
        usesAgentForwarding: Bool = false,
        securityAdvisory: String? = nil,
        transportBackend: SSHBackendKind? = nil,
        jumpHostLabel: String? = nil,
        shellPath: String? = nil,
        startedAt: Date = .now,
        endedAt: Date? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.hostLabel = hostLabel
        self.username = username
        self.hostname = hostname
        self.port = port
        self.state = state
        self.negotiatedKEX = negotiatedKEX
        self.negotiatedCipher = negotiatedCipher
        self.negotiatedHostKeyType = negotiatedHostKeyType
        self.negotiatedHostFingerprint = negotiatedHostFingerprint
        self.usesLegacyCrypto = usesLegacyCrypto
        self.usesAgentForwarding = usesAgentForwarding
        self.securityAdvisory = securityAdvisory
        self.transportBackend = transportBackend
        self.jumpHostLabel = jumpHostLabel
        self.shellPath = shellPath
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.errorMessage = errorMessage
    }
}
