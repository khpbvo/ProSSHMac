import Foundation
import Combine

@MainActor
final class TransferManager: ObservableObject {
    @Published private(set) var remoteEntries: [SFTPDirectoryEntry] = []
    @Published private(set) var currentRemotePath: String = "/"
    @Published private(set) var transfers: [Transfer] = []
    @Published var activeSessionID: UUID?
    @Published var isListing = false
    @Published var errorMessage: String?

    private weak var sessionManager: SessionManager?
    private var queuedTransferIDs: [UUID] = []
    private var pausedTransferIDs: Set<UUID> = []
    private var cancelRequestedIDs: Set<UUID> = []
    private var workerTask: Task<Void, Never>?

    func configure(sessionManager: SessionManager) {
        if self.sessionManager == nil {
            self.sessionManager = sessionManager
        }
    }

    func setActiveSession(_ sessionID: UUID?) {
        guard activeSessionID != sessionID else { return }
        activeSessionID = sessionID
        remoteEntries = []
        currentRemotePath = "/"

        guard sessionID != nil else { return }
        Task { @MainActor in
            await refreshDirectory(path: "/")
        }
    }

    func refreshDirectory(path: String? = nil) async {
        guard let sessionID = activeSessionID, let sessionManager else {
            remoteEntries = []
            return
        }

        isListing = true
        defer { isListing = false }

        let targetPath = normalizeRemotePath(path ?? currentRemotePath)
        do {
            let entries = try await sessionManager.listRemoteDirectory(sessionID: sessionID, path: targetPath)
            currentRemotePath = targetPath
            remoteEntries = entries
        } catch {
            errorMessage = "Failed to list remote directory: \(error.localizedDescription)"
        }
    }

    func openDirectory(_ entry: SFTPDirectoryEntry) {
        guard entry.isDirectory else { return }
        Task { @MainActor in
            await refreshDirectory(path: entry.path)
        }
    }

    func navigateUp() {
        let parent = parentRemotePath(of: currentRemotePath)
        Task { @MainActor in
            await refreshDirectory(path: parent)
        }
    }

    func enqueueDownload(entry: SFTPDirectoryEntry) {
        guard !entry.isDirectory else { return }
        guard let sessionID = activeSessionID else {
            errorMessage = "Select an active SSH session before downloading files."
            return
        }

        do {
            let destinationDirectory = try Self.defaultDownloadDirectory()
            let destinationURL = destinationDirectory.appendingPathComponent(entry.name)

            let transfer = Transfer(
                id: UUID(),
                sessionID: sessionID,
                sourcePath: entry.path,
                destinationPath: destinationURL.path,
                direction: .download,
                bytesTransferred: 0,
                totalBytes: entry.size,
                state: .queued,
                createdAt: .now,
                updatedAt: .now
            )

            enqueueTransfer(transfer)
        } catch {
            errorMessage = "Failed to prepare download: \(error.localizedDescription)"
        }
    }

    func enqueueUpload(localFileURL: URL) {
        guard let sessionID = activeSessionID else {
            errorMessage = "Select an active SSH session before uploading files."
            return
        }

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: localFileURL.path)
            let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let destination = joinRemotePath(currentRemotePath, localFileURL.lastPathComponent)

            let transfer = Transfer(
                id: UUID(),
                sessionID: sessionID,
                sourcePath: localFileURL.path,
                destinationPath: destination,
                direction: .upload,
                bytesTransferred: 0,
                totalBytes: fileSize,
                state: .queued,
                createdAt: .now,
                updatedAt: .now
            )

            enqueueTransfer(transfer)
        } catch {
            errorMessage = "Failed to inspect selected file: \(error.localizedDescription)"
        }
    }

    func pauseTransfer(_ transferID: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == transferID }) else { return }
        guard transfers[index].state == .queued else { return }

        pausedTransferIDs.insert(transferID)
        transfers[index].state = .paused
        transfers[index].updatedAt = .now
    }

    func resumeTransfer(_ transferID: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == transferID }) else { return }
        guard transfers[index].state == .paused else { return }

        pausedTransferIDs.remove(transferID)
        transfers[index].state = .queued
        transfers[index].updatedAt = .now
        if queuedTransferIDs.contains(transferID) == false {
            queuedTransferIDs.append(transferID)
        }
        startQueueWorkerIfNeeded()
    }

    func cancelTransfer(_ transferID: UUID) {
        cancelRequestedIDs.insert(transferID)

        if let index = transfers.firstIndex(where: { $0.id == transferID }),
           transfers[index].state == .queued || transfers[index].state == .paused {
            queuedTransferIDs.removeAll { $0 == transferID }
            pausedTransferIDs.remove(transferID)
            transfers[index].state = .cancelled
            transfers[index].updatedAt = .now
        }
    }

    func clearFinishedTransfers() {
        transfers.removeAll { transfer in
            transfer.state == .completed || transfer.state == .failed || transfer.state == .cancelled
        }
    }

    func clearError() {
        errorMessage = nil
    }

    private func enqueueTransfer(_ transfer: Transfer) {
        transfers.insert(transfer, at: 0)
        queuedTransferIDs.append(transfer.id)
        startQueueWorkerIfNeeded()
    }

    private func startQueueWorkerIfNeeded() {
        guard workerTask == nil else { return }

        workerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.processQueue()
            self.workerTask = nil

            if self.queuedTransferIDs.contains(where: { self.pausedTransferIDs.contains($0) == false }) {
                self.startQueueWorkerIfNeeded()
            }
        }
    }

    private func processQueue() async {
        guard let sessionManager else {
            return
        }

        while let nextTransferID = queuedTransferIDs.first(where: { pausedTransferIDs.contains($0) == false }) {
            queuedTransferIDs.removeAll { $0 == nextTransferID }

            guard let index = transfers.firstIndex(where: { $0.id == nextTransferID }) else {
                continue
            }

            if cancelRequestedIDs.contains(nextTransferID) {
                transfers[index].state = .cancelled
                transfers[index].updatedAt = .now
                continue
            }

            transfers[index].state = .running
            transfers[index].updatedAt = .now

            let transfer = transfers[index]
            do {
                let result: SFTPTransferResult
                switch transfer.direction {
                case .download:
                    result = try await sessionManager.downloadFile(
                        sessionID: transfer.sessionID,
                        remotePath: transfer.sourcePath,
                        localPath: transfer.destinationPath
                    )
                case .upload:
                    result = try await sessionManager.uploadFile(
                        sessionID: transfer.sessionID,
                        localPath: transfer.sourcePath,
                        remotePath: transfer.destinationPath
                    )
                }

                guard let updatedIndex = transfers.firstIndex(where: { $0.id == transfer.id }) else {
                    continue
                }

                if cancelRequestedIDs.contains(transfer.id) {
                    transfers[updatedIndex].state = .cancelled
                    transfers[updatedIndex].updatedAt = .now
                    continue
                }

                transfers[updatedIndex].bytesTransferred = result.bytesTransferred
                transfers[updatedIndex].totalBytes = max(result.totalBytes, result.bytesTransferred)
                transfers[updatedIndex].state = .completed
                transfers[updatedIndex].updatedAt = .now

                if transfer.direction == .upload,
                   transfer.sessionID == activeSessionID,
                   normalizeRemotePath(transfer.destinationPath).hasPrefix(normalizeRemotePath(currentRemotePath)) {
                    await refreshDirectory(path: currentRemotePath)
                }
            } catch {
                guard let updatedIndex = transfers.firstIndex(where: { $0.id == transfer.id }) else {
                    continue
                }

                transfers[updatedIndex].state = .failed
                transfers[updatedIndex].updatedAt = .now
                errorMessage = "Transfer failed (\(URL(fileURLWithPath: transfer.sourcePath).lastPathComponent)): \(error.localizedDescription)"
            }
        }
    }

    private static func defaultDownloadDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory

        let directory = base
            .appendingPathComponent("ProSSHV2", isDirectory: true)
            .appendingPathComponent("Downloads", isDirectory: true)

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return directory
    }

    private func normalizeRemotePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "/"
        }

        var parts = trimmed.split(separator: "/").map(String.init)
        parts.removeAll(where: { $0.isEmpty || $0 == "." })
        let normalized = "/" + parts.joined(separator: "/")
        if normalized.count > 1 && normalized.hasSuffix("/") {
            return String(normalized.dropLast())
        }
        return normalized
    }

    private func parentRemotePath(of path: String) -> String {
        let normalized = normalizeRemotePath(path)
        guard normalized != "/" else {
            return "/"
        }
        guard let slash = normalized.lastIndex(of: "/") else {
            return "/"
        }
        if slash == normalized.startIndex {
            return "/"
        }
        return String(normalized[..<slash])
    }

    private func joinRemotePath(_ base: String, _ component: String) -> String {
        let normalizedBase = normalizeRemotePath(base)
        if normalizedBase == "/" {
            return "/\(component)"
        }
        return "\(normalizedBase)/\(component)"
    }

    // MARK: - Screenshot Mode Support

    func injectScreenshotTransfers(sessionID: UUID) {
        activeSessionID = sessionID
        transfers = ScreenshotSampleData.transfers(sessionID: sessionID)
    }
}
