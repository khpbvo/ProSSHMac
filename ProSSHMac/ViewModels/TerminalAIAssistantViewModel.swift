import Foundation
@preconcurrency import Combine

enum PatchApprovalState: String, Sendable, Equatable {
    case pending, approved, denied
}

enum TerminalAIAssistantMessageKind: Sendable, Equatable {
    case text
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

    private let agentService: any OpenAIAgentServicing
    private let streamChunkDelayNanoseconds: UInt64
    private let minChunkSize: Int
    private let maxChunkSize: Int

    private var activePatchApprovalContinuation: CheckedContinuation<(Bool, Bool), Never>?
    private var activePatchApprovalMessageID: UUID?
    private var activePatchApprovalOperation: PatchOperation?
    private var activePatchApprovalFingerprint: String?

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
        guard !trimmed.contains("\n\n") else { return trimmed }
        return Self.reflowDenseParagraphs(trimmed)
    }

    private static func reflowDenseParagraphs(_ text: String) -> String {
        let pattern = #"(?<=[.!?])\s*(?=[A-Z0-9\"'`])"#
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

        guard parts.count >= 3 else { return text }

        var paragraphs: [String] = []
        var index = 0
        while index < parts.count {
            let end = min(parts.count, index + 2)
            paragraphs.append(parts[index..<end].joined(separator: " "))
            index = end
        }
        return paragraphs.joined(separator: "\n\n")
    }
}
