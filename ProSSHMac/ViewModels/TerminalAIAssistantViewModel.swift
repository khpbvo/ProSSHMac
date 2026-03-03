import Foundation
@preconcurrency import Combine

enum TerminalAIAssistantMessageKind: Sendable, Equatable {
    case text
    case reasoning(isSummary: Bool)
    case patchResult(
        operation: String, path: String,
        linesChanged: Int, warnings: [String], success: Bool
    )
}

struct PatchApprovalRequest: Identifiable, Sendable {
    let id: UUID
    let operation: String
    let path: String
    let diffPreview: String
    let fingerprint: String
}

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
    var kind: TerminalAIAssistantMessageKind = .text
}

@MainActor
final class TerminalAIAssistantViewModel: ObservableObject {
    @Published var messages: [TerminalAIAssistantMessage] = []
    @Published var draftPrompt = ""
    @Published private(set) var isSending = false
    @Published private(set) var lastError: String?
    @Published private(set) var reasoningSummary = ""
    @Published private(set) var reasoningDetails = ""
    @Published private(set) var isReasoningStreaming = false
    @Published private(set) var activePatchApproval: PatchApprovalRequest?

    private let agentService: any AIAgentServicing
    private let streamChunkDelayNanoseconds: UInt64
    private let minChunkSize: Int
    private let maxChunkSize: Int

    private var activePatchApprovalContinuation: CheckedContinuation<(Bool, Bool), Never>?
    private var activeAgentTask: Task<Void, Never>?

    var formattedReasoningSummary: String {
        reasoningSummary.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var formattedReasoningDetails: String {
        reasoningDetails.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var reasoningPanelText: String {
        var sections: [String] = []
        let summaryText = formattedReasoningSummary
        let detailText = formattedReasoningDetails
        if !summaryText.isEmpty {
            sections.append("Summary\n\(summaryText)")
        }
        if !detailText.isEmpty {
            sections.append("Thinking\n\(detailText)")
        }
        return sections.joined(separator: "\n\n")
    }

    init(
        agentService: any AIAgentServicing,
        streamChunkDelayNanoseconds: UInt64 = 6_000_000,
        minChunkSize: Int = 28,
        maxChunkSize: Int = 120
    ) {
        self.agentService = agentService
        self.streamChunkDelayNanoseconds = streamChunkDelayNanoseconds
        self.minChunkSize = minChunkSize
        self.maxChunkSize = maxChunkSize

        if let svc = agentService as? OpenAIAgentService {
            svc.patchApprovalCallback = { [weak self] operation, fingerprint in
                await self?.requestPatchApproval(operation: operation, fingerprint: fingerprint)
                    ?? (false, false)
            }
            svc.patchResultCallback = { [weak self] operation, result in
                self?.appendPatchResultNotification(operation: operation, result: result)
            }
        }
    }

    nonisolated deinit {}

    func clearConversation(sessionID: UUID?) {
        activeAgentTask?.cancel()
        activeAgentTask = nil
        isSending = false
        denyPatch()
        clearReasoningPanel()
        messages = []
        lastError = nil
        if let sessionID {
            agentService.clearConversation(sessionID: sessionID)
        }
    }

    func requestPatchApproval(
        operation: PatchOperation, fingerprint: String
    ) async -> (Bool, Bool) {
        return await withCheckedContinuation { continuation in
            activePatchApprovalContinuation = continuation
            activePatchApproval = PatchApprovalRequest(
                id: UUID(),
                operation: operation.type.rawValue,
                path: operation.path,
                diffPreview: operation.diff ?? "",
                fingerprint: fingerprint
            )
        }
    }

    func approvePatch(remember: Bool) {
        guard activePatchApprovalContinuation != nil else { return }
        activePatchApprovalContinuation?.resume(returning: (true, remember))
        clearActivePatchApproval()
    }

    func denyPatch() {
        guard activePatchApprovalContinuation != nil else { return }
        activePatchApprovalContinuation?.resume(returning: (false, false))
        clearActivePatchApproval()
    }

    func handlePatchApprovalDismissed() {
        denyPatch()
    }

    private func clearActivePatchApproval() {
        activePatchApprovalContinuation = nil
        activePatchApproval = nil
    }

    private func appendPatchResultNotification(operation: PatchOperation, result: PatchResult) {
        messages.append(TerminalAIAssistantMessage(
            id: UUID(), role: .assistant, content: "", createdAt: .now,
            isStreaming: false,
            kind: .patchResult(
                operation: operation.type.rawValue, path: operation.path,
                linesChanged: result.linesChanged, warnings: result.warnings,
                success: result.success
            )
        ))
    }

    func submitPrompt(for sessionID: UUID, broadcastSessionIDs: [UUID]? = nil) {
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

        sendPrompt(trimmed, for: sessionID, broadcastSessionIDs: broadcastSessionIDs)
    }

    private func sendPrompt(_ prompt: String, for sessionID: UUID, broadcastSessionIDs: [UUID]? = nil) {
        isSending = true
        clearReasoningPanel()
        messages.removeAll(where: { message in
            if case .reasoning = message.kind {
                return true
            }
            return false
        })
        activeAgentTask = Task { @MainActor [weak self] in
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
                    broadcastSessionIDs: broadcastSessionIDs,
                    streamHandler: { [weak self] event in
                        Task { @MainActor [weak self] in
                            self?.handleStreamEvent(event, assistantMessageID: assistantID)
                        }
                    }
                )
                guard !Task.isCancelled else { return }
                await Task.yield()
                let normalizedReply = self.normalizeAssistantReply(reply.text)
                let hasReplyText = !normalizedReply.isEmpty
                let finalText = hasReplyText ? normalizedReply : "No response from assistant."
                if let existing = self.messageContent(for: assistantID), !existing.isEmpty {
                    let normalizedExisting = self.normalizeAssistantReply(existing)
                    let preferred = hasReplyText
                        ? finalText
                        : (normalizedExisting.isEmpty ? existing : normalizedExisting)
                    if existing != preferred {
                        self.updateAssistantMessage(
                            id: assistantID,
                            content: preferred,
                            isStreaming: false
                        )
                    } else {
                        self.updateAssistantMessage(id: assistantID, content: nil, isStreaming: false)
                    }
                } else {
                    await self.streamReply(finalText, into: assistantID)
                }
                self.finishReasoningStreams()
            } catch {
                guard !Task.isCancelled else { return }
                self.finishReasoningStreams()
                self.updateAssistantMessage(
                    id: assistantID,
                    content: error.localizedDescription,
                    isStreaming: false
                )
                self.lastError = error.localizedDescription
            }
            self.isSending = false
            self.activeAgentTask = nil
        }
    }

    private func handleStreamEvent(_ event: AIAgentStreamEvent, assistantMessageID: UUID) {
        switch event {
        case let .assistantTextDelta(delta):
            appendDelta(delta, to: assistantMessageID)
        case let .assistantTextDone(text):
            applyDoneText(text, to: assistantMessageID)
        case let .reasoningTextDelta(delta):
            appendReasoning(delta, isSummary: false)
        case let .reasoningTextDone(text):
            applyReasoningDone(text, isSummary: false)
        case let .reasoningSummaryDelta(delta):
            appendReasoning(delta, isSummary: true)
        case let .reasoningSummaryDone(text):
            applyReasoningDone(text, isSummary: true)
        }
    }

    private func appendDelta(_ delta: String, to messageID: UUID) {
        guard !delta.isEmpty,
              let index = messages.firstIndex(where: { $0.id == messageID }) else {
            return
        }
        messages[index].content += delta
        messages[index].isStreaming = true
    }

    private func applyDoneText(_ text: String, to messageID: UUID) {
        guard !text.isEmpty,
              let index = messages.firstIndex(where: { $0.id == messageID }) else {
            return
        }
        messages[index].content = text
        messages[index].isStreaming = true
    }

    private func appendReasoning(_ text: String, isSummary: Bool) {
        guard !text.isEmpty else { return }
        if isSummary {
            reasoningSummary += text
        } else {
            reasoningDetails += text
        }
        isReasoningStreaming = true
    }

    private func applyReasoningDone(_ text: String, isSummary: Bool) {
        guard !text.isEmpty else { return }
        if isSummary {
            reasoningSummary = text
        } else {
            reasoningDetails = text
        }
        isReasoningStreaming = true
    }

    private func finishReasoningStreams() {
        isReasoningStreaming = false
    }

    private func clearReasoningPanel() {
        reasoningSummary = ""
        reasoningDetails = ""
        isReasoningStreaming = false
    }

    private func streamReply(_ fullText: String, into messageID: UUID) async {
        let normalized = normalizeAssistantReply(fullText)
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

    private func messageContent(for id: UUID) -> String? {
        messages.first(where: { $0.id == id })?.content
    }

    private func streamingChunks(for text: String) -> [String] {
        guard text.count > maxChunkSize else { return [text] }

        let targetChunkCount = 80
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

    private func normalizeAssistantReply(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

}
