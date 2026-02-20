import Foundation

enum TransferDirection: String, Codable {
    case upload
    case download
}

enum TransferState: String, Codable {
    case queued
    case running
    case paused
    case completed
    case failed
    case cancelled
}

struct Transfer: Identifiable, Codable, Hashable {
    var id: UUID
    var sessionID: UUID
    var sourcePath: String
    var destinationPath: String
    var direction: TransferDirection
    var bytesTransferred: Int64
    var totalBytes: Int64
    var state: TransferState
    var createdAt: Date
    var updatedAt: Date

    /// Fractional progress (0.0–1.0). Returns 0 when `totalBytes` is zero.
    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, Double(bytesTransferred) / Double(totalBytes))
    }
}
