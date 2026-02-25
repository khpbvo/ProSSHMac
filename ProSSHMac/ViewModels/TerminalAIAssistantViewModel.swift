import Foundation
@preconcurrency import Combine

enum PatchApprovalState: String, Sendable, Equatable {
    case pending, approved, denied
}

enum TerminalAIAssistantMessageKind: Sendable, Equatable {
    case text
    case reasoning(isSummary: Bool)
    case patchApproval(
        operation: String, path: String,
        diffPreview: String, fingerprint: String,
        state: PatchApprovalState
    )
    case patchResult(
        operation: String, path: String,
        linesChanged: Int, warnings: [String], success: Bool
    )
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

    private let agentService: any OpenAIAgentServicing
    private let streamChunkDelayNanoseconds: UInt64
    private let minChunkSize: Int
    private let maxChunkSize: Int

    private var activePatchApprovalContinuation: CheckedContinuation<(Bool, Bool), Never>?
    private var activePatchApprovalMessageID: UUID?
    private var activePatchApprovalOperation: PatchOperation?
    private var activePatchApprovalFingerprint: String?

    var formattedReasoningSummary: String {
        Self.makeReadableText(reasoningSummary)
    }

    var formattedReasoningDetails: String {
        Self.makeReadableText(reasoningDetails)
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
        agentService: any OpenAIAgentServicing,
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
            let msgID = UUID()
            activePatchApprovalContinuation = continuation
            activePatchApprovalMessageID = msgID
            activePatchApprovalOperation = operation
            activePatchApprovalFingerprint = fingerprint
            messages.append(TerminalAIAssistantMessage(
                id: msgID, role: .assistant, content: "", createdAt: .now,
                isStreaming: false,
                kind: .patchApproval(
                    operation: operation.type.rawValue,
                    path: operation.path,
                    diffPreview: String((operation.diff ?? "").prefix(500)),
                    fingerprint: fingerprint,
                    state: .pending
                )
            ))
        }
    }

    func approvePatch(remember: Bool) {
        guard let msgID = activePatchApprovalMessageID,
              let idx = messages.firstIndex(where: { $0.id == msgID }),
              let op = activePatchApprovalOperation,
              let fp = activePatchApprovalFingerprint else { return }
        messages[idx].kind = .patchApproval(
            operation: op.type.rawValue, path: op.path,
            diffPreview: String((op.diff ?? "").prefix(500)),
            fingerprint: fp, state: .approved
        )
        activePatchApprovalContinuation?.resume(returning: (true, remember))
        clearActivePatchApproval()
    }

    func denyPatch() {
        guard let msgID = activePatchApprovalMessageID,
              let idx = messages.firstIndex(where: { $0.id == msgID }),
              let op = activePatchApprovalOperation,
              let fp = activePatchApprovalFingerprint else { return }
        messages[idx].kind = .patchApproval(
            operation: op.type.rawValue, path: op.path,
            diffPreview: String((op.diff ?? "").prefix(500)),
            fingerprint: fp, state: .denied
        )
        activePatchApprovalContinuation?.resume(returning: (false, false))
        clearActivePatchApproval()
    }

    private func clearActivePatchApproval() {
        activePatchApprovalContinuation = nil
        activePatchApprovalMessageID = nil
        activePatchApprovalOperation = nil
        activePatchApprovalFingerprint = nil
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
        clearReasoningPanel()
        messages.removeAll(where: { message in
            if case .reasoning = message.kind {
                return true
            }
            return false
        })
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
                    streamHandler: { [weak self] event in
                        Task { @MainActor [weak self] in
                            self?.handleStreamEvent(event, assistantMessageID: assistantID)
                        }
                    }
                )
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
                self.finishReasoningStreams()
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

    private func handleStreamEvent(_ event: OpenAIAgentStreamEvent, assistantMessageID: UUID) {
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
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard !trimmed.contains("```") else { return trimmed }
        let spaced = Self.normalizeInlineSpacing(trimmed)
        let listified = Self.bulletizeCapabilityListIfNeeded(spaced)
        guard !Self.hasStructuredMarkdown(listified) else { return listified }
        return Self.reflowDenseParagraphs(listified)
    }

    private static func reflowDenseParagraphs(_ text: String) -> String {
        let pattern = #"(?:(?<=[.!?])|(?<=\)))\s*(?=[A-Z0-9\"'`(])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var parts: [String] = []
        var cursor = 0
        regex.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
            guard let match else { return }
            let boundary = match.range.location
            let segmentRange = NSRange(location: cursor, length: max(0, boundary - cursor))
            let segment = nsText.substring(with: segmentRange).trimmingCharacters(in: .whitespacesAndNewlines)
            if !segment.isEmpty {
                parts.append(segment)
            }
            cursor = match.range.location + match.range.length
        }

        if cursor < nsText.length {
            let tailRange = NSRange(location: cursor, length: nsText.length - cursor)
            let tail = nsText.substring(with: tailRange).trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty {
                parts.append(tail)
            }
        }

        guard parts.count >= 2 else { return text }

        var paragraphs: [String] = []
        var index = 0
        while index < parts.count {
            let end = min(parts.count, index + 2)
            paragraphs.append(parts[index..<end].joined(separator: " "))
            index = end
        }
        return paragraphs.joined(separator: "\n\n")
    }

    private static func normalizeInlineSpacing(_ text: String) -> String {
        var result = text.replacingOccurrences(
            of: #"[ \t]+"#,
            with: " ",
            options: .regularExpression
        )
        result = applyRegex(
            pattern: #"(?<=[\.\!\?;:,\)])(?=[A-Z0-9\"'`(])"#,
            replacement: " ",
            to: result
        )
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func bulletizeCapabilityListIfNeeded(_ text: String) -> String {
        let lowered = text.lowercased()
        guard lowered.contains("i can")
            || lowered.contains("abilities")
            || lowered.contains("capabilities") else {
            return text
        }

        guard let colonIndex = text.firstIndex(of: ":") else {
            return text
        }
        let lead = String(text[..<colonIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        let remainder = String(text[text.index(after: colonIndex)...])
        let sentenceBounded = applyRegex(
            pattern: #"(?:(?<=[.!?])|(?<=\)))\s*(?=[A-Z0-9\"'`(])"#,
            replacement: "\n",
            to: remainder
        )
        let semicolonSplit = sentenceBounded.split(
            whereSeparator: { $0 == "\n" || $0 == ";" }
        )
        var clauses = semicolonSplit
            .map { fragment in cleanListItem(String(fragment)) }
            .filter { !$0.isEmpty }

        if clauses.count < 3 {
            clauses = sentenceBounded.split(
                whereSeparator: { $0 == "\n" || $0 == ";" || $0 == "," }
            )
            .map { fragment in cleanListItem(String(fragment)) }
            .filter { !$0.isEmpty }
        }

        guard clauses.count >= 3 else {
            return text
        }

        let bullets = clauses.map { "- \($0)" }.joined(separator: "\n")
        return "\(lead):\n\n\(bullets)"
    }

    private static func cleanListItem(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["and ", "or ", "then ", "also "]
        for prefix in prefixes {
            if value.lowercased().hasPrefix(prefix) {
                value = String(value.dropFirst(prefix.count))
            }
        }
        while let last = value.last, [".", ",", ";", ":"].contains(String(last)) {
            value.removeLast()
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func applyRegex(pattern: String, replacement: String, to text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }

    private static func hasStructuredMarkdown(_ text: String) -> Bool {
        text.contains("\n#")
            || text.contains("\n- ")
            || text.contains("\n* ")
            || text.contains("\n1. ")
            || text.contains("\n2. ")
            || text.contains("\n3. ")
    }

    private static func makeReadableText(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard !hasStructuredMarkdown(trimmed) else { return trimmed }
        let spaced = normalizeInlineSpacing(trimmed)
        return reflowDenseParagraphs(spaced)
    }
}
