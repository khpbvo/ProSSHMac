// Extracted from SessionManager.swift
import Foundation

@MainActor final class SessionShellIOCoordinator {
    weak var manager: SessionManager?
    var parserReaderTasks: [UUID: Task<Void, Never>] = [:]

    init() {}

    nonisolated deinit {}

    func cancelParserTask(for sessionID: UUID) {
        parserReaderTasks[sessionID]?.cancel()
        parserReaderTasks.removeValue(forKey: sessionID)
    }

    func sendShellInput(sessionID: UUID, input: String, suppressEcho: Bool = false) async {
        guard let manager else { return }
        guard manager.sessions.contains(where: { $0.id == sessionID && $0.state == .connected }) else {
            await manager.renderingCoordinator.appendShellLine("Session is not connected.", to: sessionID)
            return
        }

        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        guard let shell = manager.shellChannels[sessionID] else {
            await manager.renderingCoordinator.appendShellLine("Shell channel is not available.", to: sessionID)
            return
        }

        do {
            let payload = trimmed + "\n"
            try await shell.send(payload)
            manager.lastActivityBySessionID[sessionID] = .now
            manager.bytesSentBySessionID[sessionID, default: 0] += Int64(payload.utf8.count)
            manager.recordingCoordinator.recordInput(sessionID: sessionID, text: payload)
            await manager.terminalHistoryIndex.recordCommandInput(
                sessionID: sessionID,
                command: trimmed,
                at: .now,
                source: .userInput
            )
        } catch {
            await manager.renderingCoordinator.appendShellLine("Error: \(error.localizedDescription)", to: sessionID)
        }
    }

    func sendRawShellInput(sessionID: UUID, input: String) async {
        guard let manager else { return }
        guard manager.sessions.contains(where: { $0.id == sessionID && $0.state == .connected }) else {
            await manager.renderingCoordinator.appendShellLine("Session is not connected.", to: sessionID)
            return
        }

        guard let shell = manager.shellChannels[sessionID] else {
            await manager.renderingCoordinator.appendShellLine("Shell channel is not available.", to: sessionID)
            return
        }

        do {
            try await shell.send(input)
            manager.bytesSentBySessionID[sessionID, default: 0] += Int64(input.utf8.count)
            manager.recordingCoordinator.recordInput(sessionID: sessionID, text: input)
            await manager.terminalHistoryIndex.recordRawInput(
                sessionID: sessionID,
                input: input,
                at: .now
            )
        } catch {
            await manager.renderingCoordinator.appendShellLine("Error: \(error.localizedDescription)", to: sessionID)
        }
    }

    func startParserReader(for sessionID: UUID, rawOutput: AsyncStream<Data>) {
        parserReaderTasks[sessionID]?.cancel()
        guard let manager, let engine = manager.engines[sessionID] else {
            return
        }

        parserReaderTasks[sessionID] = Task.detached(priority: .userInitiated) { [weak self] in
            for await chunk in rawOutput {
                if Task.isCancelled {
                    break
                }
                await engine.feed(chunk)
                await self?.recordParsedChunk(sessionID: sessionID, chunk: chunk)

                if let syncExitSnap = await engine.consumeSyncExitSnapshot() {
                    await self?.manager?.renderingCoordinator.publishSyncExitSnapshot(
                        sessionID: sessionID,
                        engine: engine,
                        snapshotOverride: syncExitSnap
                    )
                }

                let inSyncMode = await engine.synchronizedOutput
                if inSyncMode { continue }

                await self?.manager?.renderingCoordinator.scheduleParsedChunkPublish(
                    sessionID: sessionID,
                    engine: engine
                )
            }

            await self?.manager?.renderingCoordinator.flushPendingSnapshotPublishIfNeeded(
                for: sessionID,
                engine: engine
            )

            if await engine.usingAlternateBuffer {
                await engine.disableAlternateBuffer()
                await self?.manager?.renderingCoordinator.publishGridState(for: sessionID, engine: engine)
            }

            if !Task.isCancelled {
                await self?.manager?.handleShellStreamEndedInternal(sessionID: sessionID)
            }
        }
    }

    private func recordParsedChunk(sessionID: UUID, chunk: Data) async {
        guard let manager else { return }
        manager.lastActivityBySessionID[sessionID] = .now
        manager.bytesReceivedBySessionID[sessionID, default: 0] += Int64(chunk.count)
        await manager.terminalHistoryIndex.recordOutputChunk(
            sessionID: sessionID,
            data: chunk,
            at: .now
        )
        manager.recordingCoordinator.recordIfActive(sessionID: sessionID, chunk: chunk, throughputModeEnabled: manager.throughputModeEnabled)
    }
}
