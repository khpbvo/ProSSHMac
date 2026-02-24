// Extracted from SessionManager.swift
import Foundation

@MainActor final class SessionRecordingCoordinator {
    weak var manager: SessionManager?
    private let sessionRecorder: SessionRecorder

    init(sessionRecorder: SessionRecorder = SessionRecorder()) {
        self.sessionRecorder = sessionRecorder
    }

    nonisolated deinit {}

    // MARK: - Recording controls

    func toggleRecording(sessionID: UUID) async {
        guard let manager else { return }
        if manager.isRecordingBySessionID[sessionID, default: false] {
            await stopRecording(sessionID: sessionID)
        } else {
            await startRecording(sessionID: sessionID)
        }
    }

    func startRecording(sessionID: UUID) async {
        guard let manager else { return }
        guard let session = manager.sessions.first(where: { $0.id == sessionID }) else { return }
        do {
            try sessionRecorder.startRecording(for: session)
            manager.isRecordingBySessionID[sessionID] = true
            await manager.renderingCoordinator.appendShellLine("[Recorder] Started session capture.", to: sessionID)
        } catch {
            await manager.renderingCoordinator.appendShellLine("[Recorder] \(error.localizedDescription)", to: sessionID)
        }
    }

    func stopRecording(sessionID: UUID) async {
        guard let manager else { return }
        do {
            let recordingURL = try sessionRecorder.stopRecording(sessionID: sessionID)
            manager.isRecordingBySessionID[sessionID] = false
            manager.hasRecordingBySessionID[sessionID] = true
            manager.latestRecordingURLBySessionID[sessionID] = recordingURL
            await manager.renderingCoordinator.appendShellLine("[Recorder] Saved encrypted recording: \(recordingURL.lastPathComponent)", to: sessionID)
        } catch {
            await manager.renderingCoordinator.appendShellLine("[Recorder] \(error.localizedDescription)", to: sessionID)
        }
    }

    func playLastRecording(sessionID: UUID, speed: Double) async {
        guard let manager else { return }
        guard !manager.isPlaybackRunningBySessionID[sessionID, default: false] else { return }

        manager.isPlaybackRunningBySessionID[sessionID] = true
        defer { manager.isPlaybackRunningBySessionID[sessionID] = false }

        do {
            manager.renderingCoordinator.clearShellBuffer(sessionID: sessionID)
            await manager.renderingCoordinator.appendShellLine("[Recorder] Playback started (\(String(format: "%.1fx", speed))).", to: sessionID)
            try await sessionRecorder.playLatestRecording(sessionID: sessionID, speed: speed) { [weak self] step in
                await self?.manager?.renderingCoordinator.applyPlaybackStep(step, to: sessionID)
            }
            await manager.renderingCoordinator.appendShellLine("[Recorder] Playback finished.", to: sessionID)
        } catch {
            await manager.renderingCoordinator.appendShellLine("[Recorder] Playback failed: \(error.localizedDescription)", to: sessionID)
        }
    }

    func exportLastRecordingAsCast(sessionID: UUID, columns: Int = 80, rows: Int = 24) async {
        guard let manager else { return }
        do {
            let castURL = try sessionRecorder.exportLatestRecordingAsCast(
                sessionID: sessionID,
                columns: columns,
                rows: rows
            )
            await manager.renderingCoordinator.appendShellLine("[Recorder] Exported .cast: \(castURL.path(percentEncoded: false))", to: sessionID)
        } catch {
            await manager.renderingCoordinator.appendShellLine("[Recorder] Export failed: \(error.localizedDescription)", to: sessionID)
        }
    }

    // MARK: - Input recording

    func recordInput(sessionID: UUID, text: String) {
        sessionRecorder.recordInput(sessionID: sessionID, text: text)
    }

    // MARK: - Chunk recording (called from recordParsedChunk)

    func recordIfActive(sessionID: UUID, chunk: Data, throughputModeEnabled: Bool) {
        guard sessionRecorder.isRecording(sessionID: sessionID) else { return }
        if sessionRecorder.coalescingEnabled != throughputModeEnabled {
            sessionRecorder.coalescingEnabled = throughputModeEnabled
        }
        sessionRecorder.recordOutputData(sessionID: sessionID, data: chunk)
    }

    // MARK: - Finalization

    func finalizeIfNeeded(sessionID: UUID) {
        guard sessionRecorder.isRecording(sessionID: sessionID) else { return }
        Task { @MainActor [weak self] in
            guard let self, let manager = self.manager else { return }
            do {
                let recordingURL = try self.sessionRecorder.stopRecording(sessionID: sessionID)
                manager.hasRecordingBySessionID[sessionID] = true
                manager.latestRecordingURLBySessionID[sessionID] = recordingURL
            } catch {
                // Best-effort finalization when sessions disconnect unexpectedly.
            }
        }
    }
}
