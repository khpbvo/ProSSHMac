// Extracted from SessionManager.swift
import Foundation

@MainActor final class SessionAIToolCoordinator {
    weak var manager: SessionManager?
    private var pendingCommands: [UUID: PendingToolCommand] = [:]
    private var pendingCLICommands: [UUID: PendingCLICommand] = [:]

    init() {}

    nonisolated deinit {}

    func executeCommandAndWait(
        sessionID: UUID,
        command: String,
        timeoutSeconds: TimeInterval = 30
    ) async -> CommandExecutionResult {
        let markerToken = UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .prefix(10)
            .uppercased()
        let token = String(markerToken)
        // Eval the quoted command after PSB: even malformed user shell syntax
        // cannot prevent the start marker from executing and hiding the echo.
        let quotedCommand = "'" + command.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let wrappedCommand = "{ printf '\\033]7777;PSB;%s\\007' '\(token)'; eval \(quotedCommand); __ps=$?; printf '\\033]7777;PSW;%s;%s\\007' '\(token)' \"$__ps\"; }"

        guard let manager else {
            return CommandExecutionResult(output: "Session is not connected.", exitCode: nil, timedOut: false, blockID: nil)
        }

        guard manager.sessions.contains(where: { $0.id == sessionID && $0.state == .connected }),
              let shell = manager.shellChannels[sessionID] else {
            return CommandExecutionResult(output: "Session is not connected.", exitCode: nil, timedOut: false, blockID: nil)
        }

        let pending = PendingToolCommand(token: token)
        do {
            supersedePendingCommands(sessionID: sessionID)
            pendingCommands[sessionID] = pending
            let payload = wrappedCommand + "\n"
            try await shell.send(payload)
            manager.lastActivityBySessionID[sessionID] = .now
            manager.bytesSentBySessionID[sessionID, default: 0] += Int64(payload.utf8.count)
            manager.recordingCoordinator.recordInput(sessionID: sessionID, text: payload)
            await manager.terminalHistoryIndex.recordCommandInput(
                sessionID: sessionID,
                command: command,
                at: .now,
                source: .userInput
            )
        } catch {
            pendingCommands.removeValue(forKey: sessionID)
            return CommandExecutionResult(output: "Error sending command: \(error.localizedDescription)", exitCode: nil, timedOut: false, blockID: nil)
        }

        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pending.continuation = continuation
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(max(0, timeoutSeconds)))
                    self?.timeoutToolCommand(sessionID: sessionID, token: token)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.timeoutToolCommand(sessionID: sessionID, token: token)
            }
        }

        guard result.timedOut else { return result }

        // Defense-in-depth: reset terminal SGR attributes on timeout to prevent
        // stuck hidden/color state from a command that failed to complete its reset.
        if let shell = manager.shellChannels[sessionID] {
            try? await shell.send("\u{1B}[0m\n")
        }

        return result
    }

    /// Runs one command at a router, switch or appliance prompt, which cannot run the POSIX
    /// wrapper above: sends the line as Enter would, presses Space at pager prompts, and returns
    /// once the prompt is back, the device asks a question, or the timeout passes. The output
    /// stays visible in the terminal.
    func executeCLICommand(
        sessionID: UUID,
        command: String,
        timeoutSeconds: TimeInterval = 30
    ) async -> CLICommandResult {
        guard let manager,
              manager.sessions.contains(where: { $0.id == sessionID && $0.state == .connected }),
              let shell = manager.shellChannels[sessionID] else {
            return CLICommandResult(output: "Session is not connected.", status: .failed)
        }

        let startPrompt = DeviceCLIPrompt.cursorLine(in: manager.shellBuffers[sessionID] ?? [])
        let pending = PendingCLICommand(capture: DeviceCLICapture(command: command, startPrompt: startPrompt))
        supersedePendingCommands(sessionID: sessionID)
        pendingCLICommands[sessionID] = pending

        let payload = command + "\r"
        do {
            try await shell.send(payload)
        } catch {
            pendingCLICommands.removeValue(forKey: sessionID)
            return CLICommandResult(output: "Error sending command: \(error.localizedDescription)", status: .failed)
        }
        manager.lastActivityBySessionID[sessionID] = .now
        manager.bytesSentBySessionID[sessionID, default: 0] += Int64(payload.utf8.count)
        manager.recordingCoordinator.recordInput(sessionID: sessionID, text: payload)
        await manager.terminalHistoryIndex.recordCommandInput(
            sessionID: sessionID,
            command: command,
            at: .now,
            source: .userInput
        )

        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(Int(max(0, timeoutSeconds) * 1000))
        pending.lastOutputAt = clock.now
        while true {
            guard pendingCLICommands[sessionID] === pending else {
                return pending.result(status: .superseded)
            }
            if Task.isCancelled || manager.shellChannels[sessionID] == nil {
                pendingCLICommands.removeValue(forKey: sessionID)
                return pending.result(status: .failed)
            }
            switch pending.capture.poll(idleFor: clock.now - pending.lastOutputAt) {
            case .complete:
                pendingCLICommands.removeValue(forKey: sessionID)
                return pending.result(status: .completed)
            case let .awaitingInput(question):
                pendingCLICommands.removeValue(forKey: sessionID)
                return pending.result(status: .awaitingInput(question))
            case .advancePager:
                pending.capture.didAdvancePager()
                try? await shell.send(" ")
                manager.bytesSentBySessionID[sessionID, default: 0] += 1
            case .wait:
                break
            }
            if clock.now >= deadline {
                pendingCLICommands.removeValue(forKey: sessionID)
                return pending.result(status: .timedOut)
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// One AI command per session: a new one ends whichever is still waiting.
    private func supersedePendingCommands(sessionID: UUID) {
        if let previous = pendingCommands.removeValue(forKey: sessionID) {
            previous.finish(CommandExecutionResult(output: "A newer command started in this session.", exitCode: nil, timedOut: true, blockID: nil))
        }
        pendingCLICommands.removeValue(forKey: sessionID)
    }

    func filterToolOutput(sessionID: UUID, chunk: Data) -> Data {
        if let pending = pendingCLICommands[sessionID] {
            pending.capture.ingest(chunk)
            pending.lastOutputAt = ContinuousClock().now
        }
        return pendingCommands[sessionID]?.filter(chunk) ?? chunk
    }

    func completeToolCommand(sessionID: UUID, token: String, exitCode: Int) {
        guard let pending = pendingCommands[sessionID], pending.token == token else { return }
        pendingCommands.removeValue(forKey: sessionID)
        pending.finish(CommandExecutionResult(
            output: pending.commandOutput,
            exitCode: exitCode,
            timedOut: false,
            blockID: nil
        ))
    }

    private func timeoutToolCommand(sessionID: UUID, token: String) {
        guard let pending = pendingCommands[sessionID], pending.token == token else { return }
        pendingCommands.removeValue(forKey: sessionID)
        pending.finish(CommandExecutionResult(output: pending.commandOutput, exitCode: nil, timedOut: true, blockID: nil))
    }

    func publishCommandCompletion(_ block: CommandBlock) {
        guard let manager else { return }
        let sessionID = block.sessionID
        if manager.latestPublishedCommandBlockIDBySessionID[sessionID] == block.id {
            return
        }
        manager.latestPublishedCommandBlockIDBySessionID[sessionID] = block.id
        manager.latestCompletedCommandBlockBySessionID[sessionID] = block
        manager.commandCompletionNonceBySessionID[sessionID, default: 0] += 1
    }
}

/// One device CLI command's output while `executeCLICommand` waits for the prompt.
@MainActor private final class PendingCLICommand {
    var capture: DeviceCLICapture
    var lastOutputAt = ContinuousClock().now

    init(capture: DeviceCLICapture) {
        self.capture = capture
    }

    func result(status: CLICommandResult.Status) -> CLICommandResult {
        let completed = status == .completed
        return CLICommandResult(
            output: capture.output(dropTrailingPrompt: completed),
            status: status,
            finalPrompt: completed ? capture.finalPrompt : nil,
            pagesAdvanced: capture.pagesAdvanced
        )
    }
}

/// Holds one shell command's output until its private OSC completion arrives.
/// Shell line editors may repaint the input repeatedly. Discard everything
/// before the private start marker, then pass real command output through.
@MainActor private final class PendingToolCommand {
    let token: String
    private var prelude: [UInt8] = []
    private var started = false
    private var outputBytes: [UInt8] = []
    private var resolvedResult: CommandExecutionResult?
    var continuation: CheckedContinuation<CommandExecutionResult, Never>? {
        didSet {
            if let resolvedResult, let continuation {
                self.continuation = nil
                continuation.resume(returning: resolvedResult)
            }
        }
    }

    init(token: String) {
        self.token = token
    }

    func filter(_ chunk: Data) -> Data {
        var visible = Array(chunk)
        if !started {
            prelude.append(contentsOf: visible)
            let startMarker = Array("\u{1B}]7777;PSB;\(token)\u{07}".utf8)
            if let markerRange = prelude.firstRange(of: startMarker) {
                visible = Array(prelude[markerRange.upperBound...])
                started = true
            } else if prelude.count > 64_000 {
                // A shell rejected the wrapper or never ran it. Keep the
                // terminal usable, including its error text, with bounded memory.
                visible = prelude
                started = true
            } else {
                return Data()
            }
            prelude.removeAll(keepingCapacity: false)
        }

        outputBytes.append(contentsOf: visible)
        // Amortize the front trim for large outputs instead of shifting the
        // entire retained window on every parser batch.
        if outputBytes.count > 960_000 {
            outputBytes.removeFirst(outputBytes.count - 480_000)
        }
        return Data(visible)
    }

    var commandOutput: String {
        let oscStart = Array("\u{1B}]7777;PSW;\(token);".utf8)
        let commandBytes = outputBytes.firstRange(of: oscStart).map { Array(outputBytes[..<$0.lowerBound]) } ?? outputBytes
        return TerminalPlainText.plainText(commandBytes).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func finish(_ result: CommandExecutionResult) {
        guard resolvedResult == nil else { return }
        resolvedResult = result
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: result)
        }
    }
}

/// Terminal output as plain text: escape sequences removed, printable text and line breaks kept.
nonisolated enum TerminalPlainText {
    static func stripEscapes(_ bytes: [UInt8], keepingBackspace: Bool = false) -> [UInt8] {
        enum EscapeState { case text, escape, csi, osc, oscEscape }
        var state = EscapeState.text
        var cleaned: [UInt8] = []
        cleaned.reserveCapacity(bytes.count)
        for byte in bytes {
            switch state {
            case .text:
                if byte == 0x1B { state = .escape }
                else if byte == 0x0A || byte == 0x0D || byte == 0x09 || byte >= 0x20 { cleaned.append(byte) }
                else if byte == 0x08, keepingBackspace { cleaned.append(byte) }
            case .escape:
                state = byte == 0x5B ? .csi : byte == 0x5D ? .osc : .text
            case .csi:
                if (0x40...0x7E).contains(byte) { state = .text }
            case .osc:
                if byte == 0x07 { state = .text }
                else if byte == 0x1B { state = .oscEscape }
            case .oscEscape:
                state = byte == 0x5C ? .text : .osc
            }
        }
        return cleaned
    }

    static func plainText(_ bytes: [UInt8]) -> String {
        String(decoding: stripEscapes(bytes), as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}
