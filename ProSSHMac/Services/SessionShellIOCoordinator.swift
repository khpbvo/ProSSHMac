// Extracted from SessionManager.swift
import Foundation
import os.log

enum RawShellInputSource: String {
    case hardwareKeyCapture = "hardware_key_capture"
    case stringBridge = "string_bridge"
    case programmatic = "programmatic"
}

@MainActor final class SessionShellIOCoordinator {
    private static let logger = Logger(subsystem: "com.prossh", category: "Terminal.LocalInput")

    weak var manager: SessionManager?
    var parserReaderTasks: [UUID: Task<Void, Never>] = [:]
    private var localInputFailureLogByKey: [String: Date] = [:]
    private let localInputFailureDedupWindow: TimeInterval = 1.5

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
        await sendRawShellInputBytes(
            sessionID: sessionID,
            bytes: Array(input.utf8),
            recordingText: input,
            source: .stringBridge,
            eventType: "string_payload"
        )
    }

    func sendRawShellInputBytes(
        sessionID: UUID,
        bytes: [UInt8],
        recordingText: String? = nil,
        source: RawShellInputSource = .programmatic,
        eventType: String = "unknown"
    ) async {
        guard let manager else { return }
        let session = manager.sessions.first(where: { $0.id == sessionID })
        let isLocalSession = session?.isLocal ?? false

        guard session?.state == .connected else {
            await manager.renderingCoordinator.appendShellLine("Session is not connected.", to: sessionID)
            logLocalInputFailureIfNeeded(
                sessionID: sessionID,
                isLocalSession: isLocalSession,
                source: source,
                eventType: eventType,
                byteCount: bytes.count,
                errorCode: LocalInputSendFailure.disconnected.rawValue,
                reason: "session_not_connected"
            )
            return
        }

        guard let shell = manager.shellChannels[sessionID] else {
            await manager.renderingCoordinator.appendShellLine("Shell channel is not available.", to: sessionID)
            logLocalInputFailureIfNeeded(
                sessionID: sessionID,
                isLocalSession: isLocalSession,
                source: source,
                eventType: eventType,
                byteCount: bytes.count,
                errorCode: LocalInputSendFailure.missingShellChannel.rawValue,
                reason: "shell_channel_unavailable"
            )
            return
        }

        do {
            try await shell.send(bytes: bytes)
            manager.bytesSentBySessionID[sessionID, default: 0] += Int64(bytes.count)
            let rawText = recordingText ?? String(decoding: bytes, as: UTF8.self)
            manager.recordingCoordinator.recordInput(sessionID: sessionID, text: rawText)
            await manager.terminalHistoryIndex.recordRawInput(
                sessionID: sessionID,
                input: rawText,
                at: .now
            )
        } catch {
            let nsError = error as NSError
            logLocalInputFailureIfNeeded(
                sessionID: sessionID,
                isLocalSession: isLocalSession,
                source: source,
                eventType: eventType,
                byteCount: bytes.count,
                errorCode: nsError.code,
                reason: nsError.domain
            )
            await manager.renderingCoordinator.appendShellLine("Error: \(error.localizedDescription)", to: sessionID)
        }
    }

    private func logLocalInputFailureIfNeeded(
        sessionID: UUID,
        isLocalSession: Bool,
        source: RawShellInputSource,
        eventType: String,
        byteCount: Int,
        errorCode: Int,
        reason: String
    ) {
        guard isLocalSession else { return }

        let now = Date()
        let dedupKey = "\(sessionID.uuidString)|\(source.rawValue)|\(eventType)|\(errorCode)|\(reason)"
        if let lastLoggedAt = localInputFailureLogByKey[dedupKey],
           now.timeIntervalSince(lastLoggedAt) < localInputFailureDedupWindow {
            return
        }
        localInputFailureLogByKey[dedupKey] = now

        if localInputFailureLogByKey.count > 256 {
            let expiry = now.addingTimeInterval(-localInputFailureDedupWindow * 4)
            localInputFailureLogByKey = localInputFailureLogByKey.filter { $0.value >= expiry }
        }

        let sessionLabel = shortSessionID(sessionID)
        Self.logger.error(
            "local_input_send result=error session=\(sessionLabel, privacy: .public) local=true source=\(source.rawValue, privacy: .public) event=\(eventType, privacy: .public) byte_count=\(byteCount) error_code=\(errorCode) reason=\(reason, privacy: .public)"
        )
    }

    private func shortSessionID(_ sessionID: UUID) -> String {
        String(sessionID.uuidString.prefix(8)).lowercased()
    }

    func startParserReader(for sessionID: UUID, rawOutput: AsyncStream<Data>) {
        parserReaderTasks[sessionID]?.cancel()
        guard let manager, let engine = manager.engines[sessionID] else {
            return
        }

        let (batchedStream, batchContinuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        let accumulator = ChunkBatchAccumulator(continuation: batchContinuation)

        // Accumulator task: batch raw chunks into 4ms windows to reduce actor-hop
        // frequency on engine.feed(). Bookkeeping used to run here per raw chunk —
        // one MainActor hop each, ~1290 per MB — and now runs once per batch in the
        // parser task below; see recordParsedChunk.
        let accTask = Task.detached(priority: .userInitiated) {
            for await chunk in rawOutput {
                if Task.isCancelled { break }
                await accumulator.push(chunk)
            }
            await accumulator.finish()
        }

        // Parser task: feed batched data to engine, schedule publishes.
        parserReaderTasks[sessionID] = Task.detached(priority: .userInitiated) { [weak self] in
            defer { accTask.cancel() }

            for await batch in batchedStream {
                if Task.isCancelled { break }
                TerminalSchedulingDiagnostics.recordBatch(bytes: batch.count)
                let recordStart = TerminalPerf.now()
                let visibleBatch = await self?.recordParsedChunk(sessionID: sessionID, chunk: batch) ?? batch
                TerminalPerf.record(.chunkRecord, since: recordStart, byteCount: batch.count)

                let feedStart = TerminalPerf.now()
                let outcome = await engine.feedAndCollectOutcome(visibleBatch)
                TerminalPerf.record(.feedCall, since: feedStart, byteCount: batch.count)

                // One MainActor handoff applies the state already captured by feed.
                let followUpStart = TerminalPerf.now()
                await self?.manager?.renderingCoordinator.handleFeedOutcome(
                    sessionID: sessionID,
                    engine: engine,
                    outcome: outcome
                )
                TerminalPerf.record(.batchFollowUp, since: followUpStart, byteCount: batch.count)
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

    /// Per-batch bookkeeping for output that has arrived: activity, byte counts,
    /// command-history capture and recording.
    ///
    /// This is `@MainActor`, so it costs one hop per call. It used to be called once
    /// per raw PTY chunk (~1290 per MB) and now runs once per 4 ms batch (~30 per
    /// MB). Everything it does concatenates, so batching is equivalent — and it also
    /// fixes a latent defect, since a raw chunk can split a UTF-8 sequence that
    /// `TerminalHistoryIndex` decodes.
    private func recordParsedChunk(sessionID: UUID, chunk: Data) async -> Data {
        // No-op outside `--benchmark-render`; the rendered benchmark cannot drain
        // the PTY stream itself, so it watches for its sentinel here. The matcher
        // handles a sentinel split across inputs, so batching delays detection by at
        // most one batch window.
        ThroughputBenchmarkRunner.observeBenchmarkChunk(chunk)
        guard let manager else { return chunk }
        manager.lastActivityBySessionID[sessionID] = .now
        manager.bytesReceivedBySessionID[sessionID, default: 0] += Int64(chunk.count)
        let visibleChunk = manager.aiToolCoordinator.filterToolOutput(sessionID: sessionID, chunk: chunk)
        let historyStart = TerminalPerf.now()
        await manager.terminalHistoryIndex.recordOutputChunk(
            sessionID: sessionID,
            data: visibleChunk,
            at: .now
        )
        TerminalPerf.record(.historyIndex, since: historyStart, byteCount: visibleChunk.count)
        manager.recordingCoordinator.recordIfActive(sessionID: sessionID, chunk: visibleChunk, throughputModeEnabled: manager.throughputModeEnabled)
        return visibleChunk
    }
}

private enum LocalInputSendFailure: Int {
    case disconnected = -1001
    case missingShellChannel = -1002
}

/// Accumulates incoming SSH data chunks and yields them in 4ms batches
/// (or immediately when the buffer exceeds 4 KB) to reduce actor-hop frequency
/// on TerminalEngine.feed() during output bursts.
private actor ChunkBatchAccumulator {
    private var buffer = Data()
    private var generation = 0
    private let continuation: AsyncStream<Data>.Continuation

    init(continuation: AsyncStream<Data>.Continuation) {
        self.continuation = continuation
    }

    func push(_ chunk: Data) {
        let wasEmpty = buffer.isEmpty
        buffer.append(contentsOf: chunk)
        if buffer.count >= 4096 {
            flush()                          // size threshold: flush immediately
        } else if wasEmpty {
            let gen = generation             // start 4ms timer for first chunk in window
            Task { await self.scheduledFlush(generation: gen) }
        }
    }

    func finish() {
        flush()
        continuation.finish()
    }

    private func flush() {
        guard !buffer.isEmpty else { return }
        generation &+= 1                     // invalidate any pending timer
        continuation.yield(buffer)
        buffer = Data()
    }

    private func scheduledFlush(generation: Int) async {
        try? await Task.sleep(for: .milliseconds(4))
        guard self.generation == generation else { return }  // stale timer guard
        flush()
    }
}
