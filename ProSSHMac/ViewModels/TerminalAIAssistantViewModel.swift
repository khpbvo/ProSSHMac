import Foundation
@preconcurrency import Combine

enum TerminalAIAssistantRole: String, Sendable, Equatable {
    case user
    case assistant
    case system
}

struct TerminalAIAssistantMessage: Identifiable, Sendable, Equatable {
    let id: UUID
    let role: TerminalAIAssistantRole
    var content: String
    var createdAt: Date
    var isStreaming: Bool
}

@MainActor
final class TerminalAIAssistantViewModel: ObservableObject {
    @Published var messages: [TerminalAIAssistantMessage] = []
    @Published var draftPrompt = ""
    @Published var mode: OpenAIAgentMode = .ask
    @Published private(set) var isSending = false
    @Published private(set) var lastError: String?

    private let agentService: any OpenAIAgentServicing
    private let streamChunkDelayNanoseconds: UInt64
    private let minChunkSize: Int
    private let maxChunkSize: Int
    private var lastAutoFollowBlockIDBySessionID: [UUID: UUID] = [:]
    private var lastModeBySessionID: [UUID: OpenAIAgentMode] = [:]

    init(
        agentService: any OpenAIAgentServicing,
        streamChunkDelayNanoseconds: UInt64 = 14_000_000,
        minChunkSize: Int = 8,
        maxChunkSize: Int = 36
    ) {
        self.agentService = agentService
        self.streamChunkDelayNanoseconds = streamChunkDelayNanoseconds
        self.minChunkSize = minChunkSize
        self.maxChunkSize = maxChunkSize
    }

    func clearConversation(sessionID: UUID?) {
        messages = []
        lastError = nil
        if let sessionID {
            lastAutoFollowBlockIDBySessionID.removeValue(forKey: sessionID)
            lastModeBySessionID.removeValue(forKey: sessionID)
            agentService.clearConversation(sessionID: sessionID)
        } else {
            lastAutoFollowBlockIDBySessionID.removeAll(keepingCapacity: false)
            lastModeBySessionID.removeAll(keepingCapacity: false)
        }
    }

    func submitPrompt(for sessionID: UUID) {
        resetConversationIfModeChanged(for: sessionID)

        let trimmed = draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else {
            return
        }

        draftPrompt = ""
        lastError = nil
        messages.append(
            TerminalAIAssistantMessage(
                id: UUID(),
                role: .user,
                content: trimmed,
                createdAt: .now,
                isStreaming: false
            )
        )

        sendPrompt(trimmed, for: sessionID, mode: mode)
    }

    func submitFollowUpIfNeeded(for sessionID: UUID, completedBlock: CommandBlock) {
        resetConversationIfModeChanged(for: sessionID)

        guard mode == .follow, !isSending else {
            return
        }
        guard lastAutoFollowBlockIDBySessionID[sessionID] != completedBlock.id else {
            return
        }

        lastAutoFollowBlockIDBySessionID[sessionID] = completedBlock.id
        lastError = nil

        messages.append(
            TerminalAIAssistantMessage(
                id: UUID(),
                role: .system,
                content: "Follow mode: command finished -> \(completedBlock.command)",
                createdAt: .now,
                isStreaming: false
            )
        )

        sendPrompt(followPrompt(for: completedBlock), for: sessionID, mode: .follow)
    }

    private func resetConversationIfModeChanged(for sessionID: UUID) {
        if let lastMode = lastModeBySessionID[sessionID], lastMode != mode {
            agentService.clearConversation(sessionID: sessionID)
            lastAutoFollowBlockIDBySessionID.removeValue(forKey: sessionID)
        }
        lastModeBySessionID[sessionID] = mode
    }

    private func sendPrompt(_ prompt: String, for sessionID: UUID, mode: OpenAIAgentMode) {
        isSending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let assistantID = UUID()
            self.messages.append(
                TerminalAIAssistantMessage(
                    id: assistantID,
                    role: .assistant,
                    content: "",
                    createdAt: .now,
                    isStreaming: true
                )
            )
            do {
                let reply = try await self.agentService.generateReply(
                    sessionID: sessionID,
                    prompt: prompt,
                    mode: mode
                )
                await self.streamReply(reply.text, into: assistantID)
            } catch {
                self.updateAssistantMessage(
                    id: assistantID,
                    content: error.localizedDescription,
                    isStreaming: false
                )
                self.lastError = error.localizedDescription
            }
            self.isSending = false
        }
    }

    private func followPrompt(for block: CommandBlock) -> String {
        let outputPreview = String(
            block.output
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(1_600)
        )
        let exitCodeText = block.exitCode.map(String.init) ?? "unknown"

        return """
        Follow mode update for a completed terminal command.
        Command: \(block.command)
        Exit code: \(exitCodeText)
        Boundary: \(block.boundarySource.rawValue)
        Started: \(block.startedAt.ISO8601Format())
        Completed: \(block.completedAt.ISO8601Format())
        Output preview:
        \(outputPreview.isEmpty ? "(no captured output)" : outputPreview)

        Give concise operational guidance:
        - what happened,
        - whether action is needed,
        - exact next command(s) if useful.
        """
    }

    private func streamReply(_ fullText: String, into messageID: UUID) async {
        let normalized = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = normalized.isEmpty
            ? "No response from assistant."
            : normalized
        let chunks = streamingChunks(for: text)

        updateAssistantMessage(id: messageID, content: "", isStreaming: true)
        for chunk in chunks {
            guard let index = messages.firstIndex(where: { $0.id == messageID }) else { break }
            messages[index].content += chunk
            if streamChunkDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: streamChunkDelayNanoseconds)
            }
        }
        updateAssistantMessage(id: messageID, content: nil, isStreaming: false)
    }

    private func updateAssistantMessage(
        id: UUID,
        content: String?,
        isStreaming: Bool
    ) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else {
            return
        }
        if let content {
            messages[index].content = content
        }
        messages[index].isStreaming = isStreaming
    }

    private func streamingChunks(for text: String) -> [String] {
        guard text.count > maxChunkSize else { return [text] }

        let targetChunkCount = 48
        let estimated = max(
            minChunkSize,
            min(maxChunkSize, text.count / max(1, targetChunkCount))
        )

        var result: [String] = []
        result.reserveCapacity(max(1, text.count / estimated))
        var index = text.startIndex

        while index < text.endIndex {
            let end = text.index(index, offsetBy: estimated, limitedBy: text.endIndex) ?? text.endIndex
            result.append(String(text[index..<end]))
            index = end
        }

        return result
    }
}
