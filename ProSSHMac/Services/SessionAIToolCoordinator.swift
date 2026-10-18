// Extracted from SessionManager.swift
import Foundation

/// An awaited copilot command stopped at a password prompt. The user answers in the terminal.
/// See Docs/CredentialPrompt.md.
struct CredentialWait: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// The prompt is up and the command's timeout is suspended.
        case waiting
        /// The user pressed Enter. The timeout runs again until the output shows the command got
        /// past the prompt; a re-raised prompt goes back to `waiting`.
        case verifying
    }

    /// A new wait on the same session is a new card.
    let id = UUID()
    let sessionID: UUID
    var prompt: String
    var kind: CredentialPromptDetector.Kind
    let command: String
    let startedAt: Date
    var phase: Phase
}

@MainActor final class SessionAIToolCoordinator {
    weak var manager: SessionManager?
    private var pendingCommands: [UUID: PendingToolCommand] = [:]
    private var pendingCLICommands: [UUID: PendingCLICommand] = [:]
    /// At most one entry today: tool calls run one after another.
    private(set) var awaitingCredential: [UUID: CredentialWait] = [:] {
        didSet { manager?.credentialWaitsDidChange() }
    }
    /// After Ctrl+C, before anything else is sent: SIGINT flushes the tty's queued input, so a
    /// line sent in the same packet would be discarded.
    private let interruptSettleDelay: Duration = .milliseconds(250)

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
        let wrappedCommand = Self.wrappedCommand(command, token: token)

        guard let manager else {
            return CommandExecutionResult(output: "Session is not connected.", exitCode: nil, timedOut: false, blockID: nil)
        }

        guard manager.sessions.contains(where: { $0.id == sessionID && $0.state == .connected }),
              let shell = manager.shellChannels[sessionID] else {
            return CommandExecutionResult(output: "Session is not connected.", exitCode: nil, timedOut: false, blockID: nil)
        }

        let pending = PendingToolCommand(token: token, command: command, timeoutSeconds: timeoutSeconds)
        do {
            await supersedePendingCommands(sessionID: sessionID)
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

        // Nothing is sent on timeout: the command may still be running, and any line would be
        // typed into it, answering an `apt` or dpkg question with Enter.
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pending.continuation = continuation
                startTimeout(for: pending, sessionID: sessionID)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                await self?.cancelToolCommand(sessionID: sessionID, token: token)
            }
        }
    }

    /// Settings that keep a command from stopping at something the model can't see coming:
    /// pagers, debconf and needrestart dialogs. They apply to the command only, and `sudo`
    /// drops them (`env_reset`).
    nonisolated static let nonInteractiveEnvironment: KeyValuePairs<String, String> = [
        "DEBIAN_FRONTEND": "noninteractive",
        "NEEDRESTART_MODE": "a",
        "SYSTEMD_PAGER": "",
        "PAGER": "cat",
        "GIT_PAGER": "cat",
    ]

    /// The command as typed into the user's shell. It runs with `eval` in that shell, so `cd`
    /// persists; the environment above is saved, exported for the command and then restored or
    /// unset, which works in sh, dash, bash, zsh and ksh (`VAR=x eval` persists in POSIX shells,
    /// and zsh's `command` can't run `eval`). The command is evaluated after PSB, so even
    /// malformed syntax can't keep the start marker from running and hiding the echo.
    /// Keep it short: a line over 1,024 bytes never reaches a macOS shell (`MAX_INPUT`), and the
    /// command shares that line.
    nonisolated static func wrappedCommand(_ command: String, token: String) -> String {
        let quotedCommand = "'" + command.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let names = nonInteractiveEnvironment.map(\.key).joined(separator: " ")
        let assignments = nonInteractiveEnvironment.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        return #"{ printf '\033]7777;PSB;%s\007' '\#(token)'; "#
            + #"for __v in \#(names); do eval "__s_$__v=\${$__v+1} __o_$__v=\${$__v-}"; done; "#
            + #"export \#(assignments); eval \#(quotedCommand); __ps=$?; "#
            + #"for __v in \#(names); do eval "if [ -n \"\$__s_$__v\" ]; then $__v=\$__o_$__v; else unset $__v; fi; unset __s_$__v __o_$__v"; done; unset __v; "#
            + #"printf '\033]7777;PSW;%s;%s\007' '\#(token)' "$__ps"; }"#
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
        await supersedePendingCommands(sessionID: sessionID)
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
        let timeout = Duration.milliseconds(Int(max(0, timeoutSeconds) * 1000))
        var deadline = clock.now + timeout
        pending.lastOutputAt = clock.now
        while true {
            guard pendingCLICommands[sessionID] === pending else {
                return pending.result(status: pending.interruption ?? .superseded)
            }
            // Declined or stopped at a password prompt: return once Ctrl+C has settled.
            if let interruption = pending.interruption {
                if Task.isCancelled { return pending.result(status: interruption) }
                try? await Task.sleep(for: .milliseconds(50))
                continue
            }
            if Task.isCancelled || manager.shellChannels[sessionID] == nil {
                pendingCLICommands.removeValue(forKey: sessionID)
                if awaitingCredential.removeValue(forKey: sessionID) != nil {
                    await interruptCredentialPrompt(sessionID: sessionID)
                }
                return pending.result(status: .failed)
            }
            let idle = clock.now - pending.lastOutputAt
            switch stepCLICredentialWait(sessionID: sessionID, pending: pending, idle: idle) {
            case .waiting:
                // No timeout while the user is asked for a password.
                try? await Task.sleep(for: .milliseconds(50))
                continue
            case .answered:
                deadline = clock.now + timeout
            case .none:
                break
            }
            switch pending.capture.poll(idleFor: idle) {
            case .complete:
                endCLICommand(sessionID: sessionID)
                return pending.result(status: .completed)
            case let .awaitingInput(question):
                // A password prompt is the wait's, never a question for the model.
                if CredentialPromptDetector.match(question) == nil {
                    endCLICommand(sessionID: sessionID)
                    return pending.result(status: .awaitingInput(question))
                }
            case .advancePager:
                pending.capture.didAdvancePager()
                try? await shell.send(" ")
                manager.bytesSentBySessionID[sessionID, default: 0] += 1
            case .wait:
                break
            }
            if clock.now >= deadline {
                endCLICommand(sessionID: sessionID)
                return pending.result(status: .timedOut)
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func endCLICommand(sessionID: UUID) {
        pendingCLICommands.removeValue(forKey: sessionID)
        awaitingCredential.removeValue(forKey: sessionID)
    }

    private enum CLICredentialStep {
        case none
        /// The prompt is up: no timeout, no polling.
        case waiting
        /// The user just pressed Enter: the timeout restarts in full.
        case answered
    }

    /// The device-CLI counterpart of `noteCommandOutput` + `checkForCredentialPrompt`, run on
    /// each tick of `executeCLICommand` since that loop polls rather than reacting to output.
    private func stepCLICredentialWait(sessionID: UUID, pending: PendingCLICommand, idle: Duration) -> CLICredentialStep {
        let capture = pending.capture
        if var wait = awaitingCredential[sessionID] {
            switch wait.phase {
            case .waiting:
                guard let lineBreak = capture.lineBreak(from: pending.credentialOffset) else { return .waiting }
                wait.phase = .verifying
                awaitingCredential[sessionID] = wait
                pending.answerOffset = lineBreak
                return .answered
            case .verifying:
                if idle >= CredentialPromptDetector.idle, let match = CredentialPromptDetector.match(capture.cursorLine) {
                    wait.phase = .waiting
                    wait.prompt = match.prompt
                    wait.kind = match.kind
                    awaitingCredential[sessionID] = wait
                    pending.credentialOffset = capture.byteCount
                    return .waiting
                }
                if CredentialPromptDetector.showsProgress(afterAnswer: capture.rawBytes(since: pending.answerOffset)) {
                    awaitingCredential.removeValue(forKey: sessionID)
                }
                return .none
            }
        }
        guard idle >= CredentialPromptDetector.idle,
              let match = CredentialPromptDetector.match(capture.cursorLine) else { return .none }
        pending.waitedForCredential = true
        pending.credentialOffset = capture.byteCount
        awaitingCredential[sessionID] = CredentialWait(
            sessionID: sessionID,
            prompt: match.prompt,
            kind: match.kind,
            command: capture.command,
            startedAt: .now,
            phase: .waiting
        )
        return .waiting
    }

    /// One AI command per session: a new one ends whichever is still waiting. A command paused
    /// at a password prompt gets Ctrl+C first, so the new command is never typed into the prompt.
    private func supersedePendingCommands(sessionID: UUID) async {
        let previous = pendingCommands.removeValue(forKey: sessionID)
        pendingCLICommands.removeValue(forKey: sessionID)
        if awaitingCredential.removeValue(forKey: sessionID) != nil {
            await interruptCredentialPrompt(sessionID: sessionID)
        }
        // Finish last, after any interrupt has settled, so the previous call returns only once
        // the session is ready for the new command.
        previous?.finish(CommandExecutionResult(
            output: "A newer command started in this session.",
            exitCode: nil,
            timedOut: true,
            blockID: nil,
            waitedForCredential: previous?.waitedForCredential ?? false
        ))
    }

    func filterToolOutput(sessionID: UUID, chunk: Data) -> Data {
        if let pending = pendingCLICommands[sessionID] {
            pending.capture.ingest(chunk)
            pending.lastOutputAt = ContinuousClock().now
        }
        guard let pending = pendingCommands[sessionID] else { return chunk }
        let visible = pending.filter(chunk)
        if !visible.isEmpty {
            noteCommandOutput(visible, sessionID: sessionID, pending: pending)
        }
        return visible
    }

    func completeToolCommand(sessionID: UUID, token: String, exitCode: Int) {
        guard let pending = pendingCommands[sessionID], pending.token == token else { return }
        pendingCommands.removeValue(forKey: sessionID)
        awaitingCredential.removeValue(forKey: sessionID)
        pending.finish(CommandExecutionResult(
            output: pending.commandOutput,
            exitCode: exitCode,
            timedOut: false,
            blockID: nil,
            waitedForCredential: pending.waitedForCredential
        ))
    }

    private func timeoutToolCommand(sessionID: UUID, token: String) {
        guard let pending = pendingCommands[sessionID], pending.token == token else { return }
        pendingCommands.removeValue(forKey: sessionID)
        awaitingCredential.removeValue(forKey: sessionID)
        pending.finish(CommandExecutionResult(
            output: pending.commandOutput,
            exitCode: nil,
            timedOut: true,
            blockID: nil,
            waitedForCredential: pending.waitedForCredential
        ))
    }

    /// The agent task was cancelled (Stop or Clear). A host left at a password prompt gets Ctrl+C.
    private func cancelToolCommand(sessionID: UUID, token: String) async {
        guard let pending = pendingCommands[sessionID], pending.token == token else { return }
        if awaitingCredential.removeValue(forKey: sessionID) != nil {
            await interruptCredentialPrompt(sessionID: sessionID)
        }
        timeoutToolCommand(sessionID: sessionID, token: token)
    }

    // MARK: - Credential prompts

    /// Whether keys typed in this session now are a password: the wait is up (either phase), or
    /// the awaited command's cursor line is already a prompt the idle check hasn't confirmed yet.
    /// Keystrokes are then sent but recorded nowhere. See Docs/CredentialPrompt.md.
    func isEnteringCredential(sessionID: UUID) -> Bool {
        if awaitingCredential[sessionID] != nil { return true }
        if let cli = pendingCLICommands[sessionID], CredentialPromptDetector.match(cli.capture.cursorLine) != nil {
            return true
        }
        guard let pending = pendingCommands[sessionID] else { return false }
        return CredentialPromptDetector.match(pending.cursorLine) != nil
    }

    /// The user declined to answer: Ctrl+C the prompt and tell the model.
    func declineCredentialPrompt(sessionID: UUID) async {
        guard awaitingCredential.removeValue(forKey: sessionID) != nil else { return }
        let pending = pendingCommands.removeValue(forKey: sessionID)
        let cli = pendingCLICommands[sessionID]
        cli?.interruption = .declined
        await interruptCredentialPrompt(sessionID: sessionID)
        if let cli, pendingCLICommands[sessionID] === cli {
            pendingCLICommands.removeValue(forKey: sessionID)
        }
        pending?.finish(CommandExecutionResult(
            output: pending?.commandOutput ?? "",
            exitCode: nil,
            timedOut: false,
            blockID: nil,
            waitedForCredential: true,
            declinedCredential: true
        ))
    }

    /// Stop or Clear: every host waiting at a prompt gets Ctrl+C and its command returns. Task
    /// cancellation reaches the same commands, but a paused command has no timeout, so a missed
    /// cancellation would leave it waiting forever.
    func cancelCredentialPrompts() async {
        for sessionID in Array(awaitingCredential.keys) {
            if let token = pendingCommands[sessionID]?.token {
                await cancelToolCommand(sessionID: sessionID, token: token)
            } else if let cli = pendingCLICommands[sessionID] {
                awaitingCredential.removeValue(forKey: sessionID)
                cli.interruption = .failed
                await interruptCredentialPrompt(sessionID: sessionID)
                if pendingCLICommands[sessionID] === cli {
                    pendingCLICommands.removeValue(forKey: sessionID)
                }
            } else {
                awaitingCredential.removeValue(forKey: sessionID)
            }
        }
    }

    /// The session closed or dropped. Without this a command paused at a prompt, which has no
    /// timeout, would never return.
    func sessionEnded(sessionID: UUID) {
        awaitingCredential.removeValue(forKey: sessionID)
        pendingCLICommands.removeValue(forKey: sessionID)
        guard let pending = pendingCommands.removeValue(forKey: sessionID) else { return }
        pending.finish(CommandExecutionResult(
            output: "The session ended before the command finished.",
            exitCode: nil,
            timedOut: false,
            blockID: nil,
            waitedForCredential: pending.waitedForCredential
        ))
    }

    private func interruptCredentialPrompt(sessionID: UUID) async {
        guard let manager, let shell = manager.shellChannels[sessionID] else { return }
        try? await shell.send(bytes: [0x03])
        manager.bytesSentBySessionID[sessionID, default: 0] += 1
        try? await Task.sleep(for: interruptSettleDelay)
    }

    private func startTimeout(for pending: PendingToolCommand, sessionID: UUID) {
        pending.timeoutTask?.cancel()
        let token = pending.token
        let seconds = max(0, pending.timeoutSeconds)
        pending.timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.timeoutToolCommand(sessionID: sessionID, token: token)
        }
    }

    private func noteCommandOutput(_ visible: Data, sessionID: UUID, pending: PendingToolCommand) {
        pending.lastOutputAt = .now
        if var wait = awaitingCredential[sessionID] {
            switch wait.phase {
            case .waiting:
                // Only a line break answers the prompt; `pwfeedback` asterisks do not.
                if let lineBreak = visible.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                    wait.phase = .verifying
                    awaitingCredential[sessionID] = wait
                    pending.recordAfterAnswer(visible[lineBreak...], restart: true)
                    startTimeout(for: pending, sessionID: sessionID)
                }
            case .verifying:
                pending.recordAfterAnswer(visible, restart: false)
            }
            if awaitingCredential[sessionID]?.phase == .verifying,
               CredentialPromptDetector.showsProgress(afterAnswer: pending.outputAfterAnswer) {
                awaitingCredential.removeValue(forKey: sessionID)
            }
        }
        armCredentialIdleCheck(sessionID: sessionID, pending: pending)
    }

    /// One task per pending command, checking once output has been quiet for the idle window.
    private func armCredentialIdleCheck(sessionID: UUID, pending: PendingToolCommand) {
        guard pending.idleTask == nil else { return }
        pending.idleTask = Task { [weak self] in
            while !Task.isCancelled {
                let due = pending.lastOutputAt + CredentialPromptDetector.idle
                guard ContinuousClock.now >= due else {
                    try? await Task.sleep(until: due, clock: .continuous)
                    continue
                }
                pending.idleTask = nil
                self?.checkForCredentialPrompt(sessionID: sessionID, pending: pending)
                return
            }
        }
    }

    private func checkForCredentialPrompt(sessionID: UUID, pending: PendingToolCommand) {
        guard pendingCommands[sessionID] === pending else { return }
        let line = pending.cursorLine
        guard let match = CredentialPromptDetector.match(line) else {
            if awaitingCredential[sessionID]?.phase == .verifying, !line.isEmpty {
                awaitingCredential.removeValue(forKey: sessionID)
            }
            return
        }
        pending.timeoutTask?.cancel()
        pending.timeoutTask = nil
        pending.waitedForCredential = true
        if var wait = awaitingCredential[sessionID] {
            wait.phase = .waiting
            wait.prompt = match.prompt
            wait.kind = match.kind
            awaitingCredential[sessionID] = wait
        } else {
            awaitingCredential[sessionID] = CredentialWait(
                sessionID: sessionID,
                prompt: match.prompt,
                kind: match.kind,
                command: pending.command,
                startedAt: .now,
                phase: .waiting
            )
        }
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
    var waitedForCredential = false
    /// Where the current password wait started, and where the user's answer began.
    var credentialOffset = 0
    var answerOffset = 0
    /// Set by Decline or Stop at a password prompt; the loop returns it once Ctrl+C has settled.
    var interruption: CLICommandResult.Status?

    init(capture: DeviceCLICapture) {
        self.capture = capture
    }

    func result(status: CLICommandResult.Status) -> CLICommandResult {
        let completed = status == .completed
        return CLICommandResult(
            output: capture.output(dropTrailingPrompt: completed),
            status: status,
            finalPrompt: completed ? capture.finalPrompt : nil,
            pagesAdvanced: capture.pagesAdvanced,
            waitedForCredential: waitedForCredential
        )
    }
}

/// Holds one shell command's output until its private OSC completion arrives.
/// Shell line editors may repaint the input repeatedly. Discard everything
/// before the private start marker, then pass real command output through.
@MainActor private final class PendingToolCommand {
    let token: String
    let command: String
    let timeoutSeconds: TimeInterval
    var timeoutTask: Task<Void, Never>?
    var idleTask: Task<Void, Never>?
    var lastOutputAt = ContinuousClock.now
    var waitedForCredential = false
    /// Output since the user last answered a credential prompt, bounded.
    private(set) var outputAfterAnswer: [UInt8] = []
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

    init(token: String, command: String, timeoutSeconds: TimeInterval) {
        self.token = token
        self.command = command
        self.timeoutSeconds = timeoutSeconds
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

    /// The line the cursor is on in this command's output.
    var cursorLine: String {
        CredentialPromptDetector.cursorLine(in: outputBytes)
    }

    func recordAfterAnswer(_ bytes: some Sequence<UInt8>, restart: Bool) {
        if restart { outputAfterAnswer.removeAll(keepingCapacity: true) }
        outputAfterAnswer.append(contentsOf: bytes)
        if outputAfterAnswer.count > 4_096 {
            outputAfterAnswer.removeFirst(outputAfterAnswer.count - 4_096)
        }
    }

    func finish(_ result: CommandExecutionResult) {
        guard resolvedResult == nil else { return }
        timeoutTask?.cancel()
        idleTask?.cancel()
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
