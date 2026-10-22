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
    private var batchAccumulators: [UUID: ChunkBatchAccumulator] = [:]
    /// Armed while a shell-integration line's echo is held back. See ShellIntegrationEchoFilter.
    private var shellIntegrationFilters: [UUID: ShellIntegrationEchoFilter] = [:]
    var shellIntegrationTiming = ShellIntegrationInjectionTiming.standard
    private var localInputFailureLogByKey: [String: Date] = [:]
    private let localInputFailureDedupWindow: TimeInterval = 1.5

    init() {}

    nonisolated deinit {}

    func cancelParserTask(for sessionID: UUID) {
        parserReaderTasks[sessionID]?.cancel()
        parserReaderTasks.removeValue(forKey: sessionID)
        batchAccumulators.removeValue(forKey: sessionID)
        shellIntegrationFilters.removeValue(forKey: sessionID)
    }

    // MARK: - Shell integration injection

    /// Types the OSC 133 integration line into a remote shell once it sits at a prompt, with
    /// its echo hidden. Nothing is sent to a shell that never looks ready, or once the user has
    /// typed (the line would join their input). The line is recorded nowhere: not in the
    /// history index, not in a recording. See Bug 90 in Docs/bugs.md.
    @discardableResult
    func injectShellIntegration(sessionID: UUID, type: ShellIntegrationType) async -> ShellIntegrationInjectionResult {
        let token = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)).uppercased()
        guard let line = ShellIntegrationScripts.sshInjectionLine(for: type, token: token) else {
            return .skipped(.unsupportedType)
        }
        return await injectSetupLine(line, token: token, sessionID: sessionID)
    }

    func injectLocalBashOverlay(sessionID: UUID, path: String) async -> ShellIntegrationInjectionResult {
        let token = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)).uppercased()
        let line = ShellIntegrationScripts.bashOverlayInjectionLine(path: path, token: token)
        return await injectSetupLine(line, token: token, sessionID: sessionID)
    }

    private func injectSetupLine(_ line: String, token: String, sessionID: UUID) async -> ShellIntegrationInjectionResult {
        let timing = shellIntegrationTiming
        let sentAtStart = manager?.bytesSentBySessionID[sessionID] ?? 0
        let deadline = ContinuousClock.now + timing.readinessTimeout
        while true {
            switch await shellReadiness(sessionID: sessionID, sentAtStart: sentAtStart, quietPeriod: timing.quietPeriod) {
            case .ready:
                return await sendShellIntegrationLine(line, token: token, sessionID: sessionID)
            case .skip(let reason):
                Self.logger.info("shell_integration skipped reason=\(String(describing: reason), privacy: .public)")
                return .skipped(reason)
            case .notYet:
                guard ContinuousClock.now < deadline else {
                    Self.logger.info("shell_integration skipped reason=not_ready")
                    return .skipped(.notReady)
                }
                try? await Task.sleep(for: timing.pollInterval)
            }
        }
    }

    private enum ShellReadiness {
        case ready
        case notYet
        case skip(ShellIntegrationInjectionResult.SkipReason)
    }

    /// Ready: some output arrived and then stopped, the cursor sits mid-line on the primary
    /// screen (a prompt, not the end of a MOTD line), and that line is not a password prompt.
    private func shellReadiness(sessionID: UUID, sentAtStart: Int64, quietPeriod: Duration) async -> ShellReadiness {
        guard let manager,
              manager.sessions.contains(where: { $0.id == sessionID && $0.state == .connected }),
              manager.shellChannels[sessionID] != nil,
              let engine = manager.engines[sessionID] else {
            return .skip(.sessionGone)
        }
        if (manager.bytesSentBySessionID[sessionID] ?? 0) != sentAtStart {
            return .skip(.userInput)
        }
        guard (manager.bytesReceivedBySessionID[sessionID] ?? 0) > 0,
              let lastOutput = manager.lastActivityBySessionID[sessionID],
              Date.now.timeIntervalSince(lastOutput) >= Self.seconds(quietPeriod) else {
            return .notYet
        }
        guard !(await engine.usingAlternateBuffer) else { return .notYet }
        let cursor = await engine.cursor
        guard cursor.col > 0 else { return .notYet }
        let lines = await engine.visibleText()
        if lines.indices.contains(cursor.row), CredentialPromptDetector.match(lines[cursor.row]) != nil {
            return .notYet
        }
        return .ready
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }

    private func sendShellIntegrationLine(_ line: String, token: String, sessionID: UUID) async -> ShellIntegrationInjectionResult {
        guard let manager, let shell = manager.shellChannels[sessionID] else {
            return .skipped(.sessionGone)
        }
        // Armed before the send, so not even an early echo byte gets past.
        shellIntegrationFilters[sessionID] = ShellIntegrationEchoFilter(token: token)
        let bytes = Array((line + "\n").utf8)
        do {
            try await shell.send(bytes: bytes)
        } catch {
            releaseShellIntegrationFilter(sessionID: sessionID, token: token)
            return .skipped(.sendFailed)
        }
        manager.bytesSentBySessionID[sessionID, default: 0] += Int64(bytes.count)
        let releaseTimeout = shellIntegrationTiming.releaseTimeout
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: releaseTimeout)
            self?.releaseShellIntegrationFilter(sessionID: sessionID, token: token)
        }
        return .injected
    }

    /// The marker never came: let the parser pass everything held, in order. The release goes
    /// through the parser's own stream (an empty batch) so it cannot overtake a batch in flight,
    /// and so it happens even when the shell has gone quiet.
    private func releaseShellIntegrationFilter(sessionID: UUID, token: String) {
        guard shellIntegrationFilters[sessionID]?.token == token else { return }
        shellIntegrationFilters[sessionID]?.requestRelease()
        let accumulator = batchAccumulators[sessionID]
        Task { await accumulator?.kick() }
    }

    func isHoldingShellIntegrationEcho(sessionID: UUID) -> Bool {
        shellIntegrationFilters[sessionID] != nil
    }

    /// Output with the shell-integration echo removed. A dictionary lookup when nothing is armed.
    private func filterShellIntegrationEcho(sessionID: UUID, chunk: Data) -> Data {
        guard var filter = shellIntegrationFilters[sessionID] else { return chunk }
        if let visible = filter.process(chunk) {
            shellIntegrationFilters.removeValue(forKey: sessionID)
            return visible
        }
        shellIntegrationFilters[sessionID] = filter
        return Data()
    }

    /// The stream ended while output was held: hand it over rather than lose it.
    private func drainShellIntegrationFilter(sessionID: UUID) -> Data {
        guard var filter = shellIntegrationFilters.removeValue(forKey: sessionID) else { return Data() }
        return filter.drain()
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

        // Sending may suspend while the host consumes the answer and completes the command.
        // Preserve the state at entry so completion cannot turn these secret bytes into history.
        let wasEnteringCredential = manager.aiToolCoordinator.isEnteringCredential(sessionID: sessionID)
        do {
            try await shell.send(bytes: bytes)
            manager.bytesSentBySessionID[sessionID, default: 0] += Int64(bytes.count)
            // A password typed at a copilot command's prompt goes to the host and nowhere else.
            guard !wasEnteringCredential,
                  !manager.aiToolCoordinator.isEnteringCredential(sessionID: sessionID) else { return }
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
        batchAccumulators[sessionID] = accumulator

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

            if !Task.isCancelled, let held = await self?.drainShellIntegrationFilter(sessionID: sessionID), !held.isEmpty {
                let outcome = await engine.feedAndCollectOutcome(held)
                await self?.manager?.renderingCoordinator.handleFeedOutcome(
                    sessionID: sessionID,
                    engine: engine,
                    outcome: outcome
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
        let withoutSetupEcho = filterShellIntegrationEcho(sessionID: sessionID, chunk: chunk)
        let visibleChunk = manager.aiToolCoordinator.filterToolOutput(sessionID: sessionID, chunk: withoutSetupEcho)
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

    /// Wakes the parser with an empty batch after anything buffered, so held output can be
    /// released when no new output arrives.
    func kick() {
        flush()
        continuation.yield(Data())
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
