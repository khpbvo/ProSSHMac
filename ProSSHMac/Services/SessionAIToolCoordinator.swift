// Extracted from SessionManager.swift
import Foundation

@MainActor final class SessionAIToolCoordinator {
    weak var manager: SessionManager?

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
        let marker = "__PSW_\(markerToken)__"
        let wrappedCommand = "{ \(command); __ps=$?; printf '\\n\\033[8m\(marker):%s\\033[0m\\n' \"$__ps\"; }"

        guard let manager else {
            return CommandExecutionResult(output: "Session is not connected.", exitCode: nil, timedOut: false, blockID: nil)
        }

        guard manager.sessions.contains(where: { $0.id == sessionID && $0.state == .connected }),
              let shell = manager.shellChannels[sessionID] else {
            return CommandExecutionResult(output: "Session is not connected.", exitCode: nil, timedOut: false, blockID: nil)
        }

        do {
            let payload = wrappedCommand + "\n"
            try await shell.send(payload)
            manager.lastActivityBySessionID[sessionID] = .now
            manager.bytesSentBySessionID[sessionID, default: 0] += Int64(payload.utf8.count)
            manager.recordingCoordinator.recordInput(sessionID: sessionID, text: payload)
            await manager.terminalHistoryIndex.recordCommandInput(
                sessionID: sessionID,
                command: wrappedCommand,
                at: .now,
                source: .userInput
            )
        } catch {
            return CommandExecutionResult(output: "Error sending command: \(error.localizedDescription)", exitCode: nil, timedOut: false, blockID: nil)
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let visibleLines = manager.shellBuffers[sessionID], !visibleLines.isEmpty {
                let screenText = visibleLines.joined(separator: "\n")
                if screenText.contains(marker) {
                    let parsed = parseWrappedCommandOutput(screenText, marker: marker)
                    if parsed.exitCode != nil {
                        return CommandExecutionResult(
                            output: parsed.output,
                            exitCode: parsed.exitCode,
                            timedOut: false,
                            blockID: nil
                        )
                    }
                }
            }

            if let liveOutput = await manager.terminalHistoryIndex.activeCommandRawOutput(sessionID: sessionID),
               liveOutput.contains(marker) {
                let parsed = parseWrappedCommandOutput(liveOutput, marker: marker)
                if parsed.exitCode != nil {
                    return CommandExecutionResult(
                        output: parsed.output,
                        exitCode: parsed.exitCode,
                        timedOut: false,
                        blockID: nil
                    )
                }
            }

            let blocks = await manager.terminalHistoryIndex.searchCommands(
                sessionID: sessionID,
                query: marker,
                limit: 8
            )
            if let block = blocks.first(where: { $0.output.contains(marker) }) {
                let parsed = parseWrappedCommandOutput(block.output, marker: marker)
                if parsed.exitCode != nil {
                    return CommandExecutionResult(
                        output: parsed.output,
                        exitCode: parsed.exitCode,
                        timedOut: false,
                        blockID: block.id
                    )
                }
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        return CommandExecutionResult(output: "", exitCode: nil, timedOut: true, blockID: nil)
    }

    private func parseWrappedCommandOutput(_ output: String, marker: String) -> (output: String, exitCode: Int?) {
        let normalized = output
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let markerPrefix = "\(marker):"
        guard let markerRange = normalized.range(of: markerPrefix, options: .backwards) else {
            return (normalized.trimmingCharacters(in: .whitespacesAndNewlines), nil)
        }
        let statusStart = markerRange.upperBound
        let statusSlice = normalized[statusStart...]
        let statusValue = statusSlice.prefix { $0.isNumber || $0 == "-" }
        let exitCode = Int(statusValue)
        let cleanOutput = normalized[..<markerRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (String(cleanOutput), exitCode)
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
