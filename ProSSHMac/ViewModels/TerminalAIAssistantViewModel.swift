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
    @Published private(set) var isSending = false
    @Published private(set) var lastError: String?

    private let agentService: any OpenAIAgentServicing
    private let streamChunkDelayNanoseconds: UInt64
    private let minChunkSize: Int
    private let maxChunkSize: Int

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
            agentService.clearConversation(sessionID: sessionID)
        }
    }

    func submitPrompt(for sessionID: UUID) {
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

        sendPrompt(trimmed, for: sessionID)
    }

    private func sendPrompt(_ prompt: String, for sessionID: UUID) {
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
                    prompt: prompt
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
