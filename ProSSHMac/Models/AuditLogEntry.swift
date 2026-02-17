import Foundation

enum AuditLogCategory: String, Codable, CaseIterable, Sendable {
    case connection
    case authentication
    case hostVerification
    case session
    case security
    case portForwarding

    var title: String {
        switch self {
        case .connection:
            return "Connection"
        case .authentication:
            return "Authentication"
        case .hostVerification:
            return "Host Verification"
        case .session:
            return "Session"
        case .security:
            return "Security"
        case .portForwarding:
            return "Port Forwarding"
        }
    }
}

enum AuditLogOutcome: String, Codable, Sendable {
    case info
    case success
    case warning
    case failure
}

struct AuditLogEntry: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var timestamp: Date
    var category: AuditLogCategory
    var action: String
    var outcome: AuditLogOutcome
    var hostLabel: String?
    var hostname: String?
    var port: UInt16?
    var username: String?
    var sessionID: UUID?
    var details: String?
}
