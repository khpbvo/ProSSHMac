import Foundation

actor TerminalHistoryIndex {
    private struct PromptHints: Sendable {
        let username: String
        let hostname: String
    }

    private struct ActiveCommandContext: Sendable {
        let id: UUID
        let command: String
        let startedAt: Date
        var boundarySource: CommandBoundarySource
        let startVisibleLines: [String]
        var rawOutput: String = ""
        var hasOutput = false
        var sawNonPromptScreenAfterStart = false
    }

    private struct SessionHistoryState: Sendable {
        var blocks: [CommandBlock] = []
        var activeCommand: ActiveCommandContext?
        var lastVisibleLines: [String] = []
        var semanticPromptSeen = false
        var promptHints: PromptHints?
        var rawInputBuffer = ""
        var escapeSequenceInProgress = false
    }

    private var sessionStates: [UUID: SessionHistoryState] = [:]
    private let maxBlocksPerSession: Int
    private let maxOutputCharacters: Int

    init(maxBlocksPerSession: Int = 500, maxOutputCharacters: Int = 120_000) {
        self.maxBlocksPerSession = max(10, maxBlocksPerSession)
        self.maxOutputCharacters = max(2_000, maxOutputCharacters)
    }

    func registerSession(sessionID: UUID, username: String, hostname: String) {
        var state = sessionStates[sessionID] ?? SessionHistoryState()
        state.promptHints = PromptHints(username: username, hostname: hostname)
        sessionStates[sessionID] = state
    }

    func removeSession(sessionID: UUID) {
        sessionStates.removeValue(forKey: sessionID)
    }

    func recordCommandInput(
        sessionID: UUID,
        command: String,
        at: Date = .now,
        source: CommandBoundarySource = .userInput
    ) {
        var state = sessionStates[sessionID] ?? SessionHistoryState()
        startCommand(command: command, for: sessionID, at: at, source: source, state: &state)
        state.rawInputBuffer.removeAll(keepingCapacity: true)
        state.escapeSequenceInProgress = false
        sessionStates[sessionID] = state
    }

    func recordRawInput(sessionID: UUID, input: String, at: Date = .now) {
        var state = sessionStates[sessionID] ?? SessionHistoryState()
        for scalar in input.unicodeScalars {
            let value = scalar.value

            if state.escapeSequenceInProgress {
                if (0x40...0x7E).contains(value) {
                    state.escapeSequenceInProgress = false
                }
                continue
            }

            if value == 0x1B { // ESC
                state.escapeSequenceInProgress = true
                continue
            }

            if value == 0x08 || value == 0x7F { // backspace/delete
                if !state.rawInputBuffer.isEmpty {
                    state.rawInputBuffer.removeLast()
                }
                continue
            }

            if value == 0x0A || value == 0x0D { // newline/carriage return
                let typed = state.rawInputBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !typed.isEmpty {
                    startCommand(
                        command: typed,
                        for: sessionID,
                        at: at,
                        source: .rawInput,
                        state: &state
                    )
                }
                state.rawInputBuffer.removeAll(keepingCapacity: true)
                continue
            }

            if value >= 0x20 {
                state.rawInputBuffer.unicodeScalars.append(scalar)
            }
        }
        sessionStates[sessionID] = state
    }

    func recordOutputChunk(sessionID: UUID, data: Data, at: Date = .now) {
        guard !data.isEmpty else { return }
        var state = sessionStates[sessionID] ?? SessionHistoryState()
        guard var active = state.activeCommand else {
            sessionStates[sessionID] = state
            return
        }

        let chunk = String(decoding: data, as: UTF8.self)
        let sanitizedChunk = chunk.replacingOccurrences(of: "\u{0000}", with: "")
        if sanitizedChunk.contains(where: { !$0.isWhitespace }) {
            active.hasOutput = true
        }

        if !sanitizedChunk.isEmpty {
            active.rawOutput.append(sanitizedChunk)
            if active.rawOutput.count > maxOutputCharacters {
                let overflow = active.rawOutput.count - maxOutputCharacters
                active.rawOutput.removeFirst(overflow)
            }
        }

        state.activeCommand = active
        sessionStates[sessionID] = state
        _ = at
    }

    func recordSemanticEvent(sessionID: UUID, event: SemanticPromptEvent, at: Date = .now) -> CommandBlock? {
        var state = sessionStates[sessionID] ?? SessionHistoryState()
        state.semanticPromptSeen = true
        var completedBlock: CommandBlock?

        switch event {
        case .promptStart:
            if state.activeCommand != nil {
                completedBlock = finalizeActiveCommand(
                    for: sessionID,
                    at: at,
                    explicitExitCode: nil,
                    completionSource: .osc133,
                    state: &state
                )
            }

        case .promptEnd:
            break

        case .commandStart:
            if var active = state.activeCommand {
                active.boundarySource = .osc133
                state.activeCommand = active
            }

        case let .commandEnd(exitCode):
            completedBlock = finalizeActiveCommand(
                for: sessionID,
                at: at,
                explicitExitCode: exitCode,
                completionSource: .osc133,
                state: &state
            )
        }

        sessionStates[sessionID] = state
        return completedBlock
    }

    func observeVisibleLines(sessionID: UUID, lines: [String], at: Date = .now) -> CommandBlock? {
        var state = sessionStates[sessionID] ?? SessionHistoryState()
        state.lastVisibleLines = lines
        var completedBlock: CommandBlock?

        if var active = state.activeCommand {
            let promptLine = detectPromptLine(in: lines, hints: state.promptHints)
            if promptLine == nil {
                active.sawNonPromptScreenAfterStart = true
            }
            state.activeCommand = active

            if promptLine != nil {
                let runtime = at.timeIntervalSince(active.startedAt)
                let shouldFinalizeFromPrompt: Bool
                if active.sawNonPromptScreenAfterStart {
                    shouldFinalizeFromPrompt = true
                } else {
                    // If output was emitted and the prompt is visible again after a small delay,
                    // treat it as command completion even if we missed an intermediate frame.
                    shouldFinalizeFromPrompt = active.hasOutput && runtime >= 0.2
                }

                if shouldFinalizeFromPrompt {
                    let source: CommandBoundarySource = state.semanticPromptSeen ? .osc133 : .heuristicPrompt
                    completedBlock = finalizeActiveCommand(
                        for: sessionID,
                        at: at,
                        explicitExitCode: nil,
                        completionSource: source,
                        state: &state
                    )
                }
            }
        }

        sessionStates[sessionID] = state
        return completedBlock
    }

    func flushActiveCommand(sessionID: UUID, at: Date = .now) -> CommandBlock? {
        var state = sessionStates[sessionID] ?? SessionHistoryState()
        let completedBlock = finalizeActiveCommand(
            for: sessionID,
            at: at,
            explicitExitCode: nil,
            completionSource: .heuristicPrompt,
            state: &state
        )
        sessionStates[sessionID] = state
        return completedBlock
    }

    func recentCommands(sessionID: UUID, limit: Int = 20) -> [CommandBlock] {
        guard let state = sessionStates[sessionID], !state.blocks.isEmpty else { return [] }
        let count = max(1, limit)
        return Array(state.blocks.suffix(count).reversed())
    }

    func searchCommands(sessionID: UUID, query: String, limit: Int = 20) -> [CommandBlock] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, let state = sessionStates[sessionID], !state.blocks.isEmpty else { return [] }

        let count = max(1, limit)
        return state.blocks
            .filter { block in
                block.command.lowercased().contains(trimmed) ||
                block.output.lowercased().contains(trimmed)
            }
            .suffix(count)
            .reversed()
    }

    func commandOutput(sessionID: UUID, blockID: UUID) -> String? {
        guard let state = sessionStates[sessionID] else { return nil }
        return state.blocks.first(where: { $0.id == blockID })?.output
    }

    // MARK: - Internals

    private func startCommand(
        command: String,
        for sessionID: UUID,
        at: Date,
        source: CommandBoundarySource,
        state: inout SessionHistoryState
    ) {
        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        if state.activeCommand != nil {
            _ = finalizeActiveCommand(
                for: sessionID,
                at: at,
                explicitExitCode: nil,
                completionSource: source,
                state: &state
            )
        }

        state.activeCommand = ActiveCommandContext(
            id: UUID(),
            command: normalized,
            startedAt: at,
            boundarySource: source,
            startVisibleLines: state.lastVisibleLines
        )
    }

    private func finalizeActiveCommand(
        for sessionID: UUID,
        at: Date,
        explicitExitCode: Int?,
        completionSource: CommandBoundarySource,
        state: inout SessionHistoryState
    ) -> CommandBlock? {
        guard let active = state.activeCommand else { return nil }
        state.activeCommand = nil

        var output = deriveOutput(
            command: active.command,
            startLines: active.startVisibleLines,
            endLines: state.lastVisibleLines,
            rawOutputFallback: active.rawOutput,
            hints: state.promptHints
        )

        if output.count > maxOutputCharacters {
            output = String(output.suffix(maxOutputCharacters))
        }

        let block = CommandBlock(
            id: active.id,
            sessionID: sessionID,
            command: active.command,
            output: output,
            startedAt: active.startedAt,
            completedAt: max(active.startedAt, at),
            exitCode: explicitExitCode,
            boundarySource: completionSource
        )

        state.blocks.append(block)
        if state.blocks.count > maxBlocksPerSession {
            state.blocks.removeFirst(state.blocks.count - maxBlocksPerSession)
        }
        return block
    }

    private func deriveOutput(
        command: String,
        startLines: [String],
        endLines: [String],
        rawOutputFallback: String,
        hints: PromptHints?
    ) -> String {
        var changedLines = lineDiff(from: startLines, to: endLines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let first = changedLines.first,
           first == command || first.hasSuffix(" \(command)") {
            changedLines.removeFirst()
        }

        if let last = changedLines.last, detectPromptLine(in: [last], hints: hints) != nil {
            changedLines.removeLast()
        }

        if !changedLines.isEmpty {
            return changedLines.joined(separator: "\n")
        }

        let fallback = rawOutputFallback
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return fallback
    }

    private func lineDiff(from start: [String], to end: [String]) -> [String] {
        guard !end.isEmpty else { return [] }
        guard !start.isEmpty else { return end }

        var prefix = 0
        let minCount = min(start.count, end.count)
        while prefix < minCount, start[prefix] == end[prefix] {
            prefix += 1
        }

        var suffix = 0
        while suffix < (minCount - prefix),
              start[start.count - 1 - suffix] == end[end.count - 1 - suffix] {
            suffix += 1
        }

        let upperBound = max(prefix, end.count - suffix)
        if prefix >= upperBound || prefix >= end.count {
            return []
        }
        return Array(end[prefix..<upperBound])
    }

    private func detectPromptLine(in lines: [String], hints: PromptHints?) -> String? {
        guard let candidate = lines.reversed().first(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            return nil
        }
        return looksLikePrompt(candidate, hints: hints) ? candidate : nil
    }

    private func looksLikePrompt(_ rawLine: String, hints: PromptHints?) -> Bool {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, line.count <= 220 else { return false }

        let promptChars: Set<Character> = ["$", "#", "%", ">"]
        guard let last = line.last, promptChars.contains(last) else { return false }

        if let hints {
            let lower = line.lowercased()
            if lower.contains(hints.username.lowercased()),
               lower.contains(hints.hostname.lowercased()) {
                return true
            }
        }

        let lower = line.lowercased()
        if lower.hasSuffix(" $") || lower.hasSuffix(" #") || lower.hasSuffix(" %") || lower.hasSuffix(" >") {
            return true
        }

        // Common POSIX prompt forms: "user@host:~$" or "root#"
        if line.contains("@") || line.contains(":") || line == "$" || line == "#" {
            return true
        }

        return false
    }
}
