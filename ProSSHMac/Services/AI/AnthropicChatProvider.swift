import CryptoKit
import Foundation
import os.log

/// Adapts `AnthropicServicing` to the provider-neutral agent loop. Claude's turns are replayed
/// exactly as returned, and the tool set stays the same for the whole conversation, so its
/// thinking blocks stay valid (see `Docs/Anthropic.md`, "Rules that shape the design").
@MainActor
struct AnthropicChatProvider: AIChatProviding {
    nonisolated static let maxOutputTokens = 64_000
    private static let logger = Logger(subsystem: "com.prossh", category: "AICopilot.Anthropic")

    let client: any AnthropicServicing
    let modelStore: AnthropicModelStore

    var requiresStableToolSet: Bool { true }

    func prefixFingerprint(systemPrompt: String, tools: [LLMToolDefinition]) -> String? {
        let prefix = AnthropicJSON.array([AnthropicBlock.text(systemPrompt).json])
            + "\n" + AnthropicJSON.array(tools.map(AnthropicClient.toolJSON))
        return SHA256.hash(data: Data(prefix.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func estimatedRequestBytes(
        systemPrompt: String,
        messages: [AITranscriptMessage],
        tools: [LLMToolDefinition]
    ) -> Int {
        AnthropicClient.requestBody(for: request(model: "", systemPrompt: systemPrompt, messages: messages, tools: tools)).count
    }

    func complete(
        model: String,
        systemPrompt: String,
        messages: [AITranscriptMessage],
        tools: [LLMToolDefinition],
        onEvent: @escaping @Sendable (LLMStreamEvent) -> Void
    ) async throws -> AIAssistantTurn {
        let response = try await client.complete(
            request(model: model, systemPrompt: systemPrompt, messages: messages, tools: tools),
            onEvent: onEvent
        )
        for entry in response.inputTransformations {
            if case let .object(fields) = entry,
               case let .string(type)? = fields["type"] {
                let reason: String
                if case let .string(value)? = fields["reason"] { reason = value } else { reason = "unknown" }
                Self.logger.debug("input_transformation type=\(type, privacy: .public) reason=\(reason, privacy: .public)")
            }
        }
        Self.logger.debug(
            "usage model=\(response.model, privacy: .public) input=\(response.usage?.inputTokens ?? -1) cache_read=\(response.usage?.cacheReadInputTokens ?? -1) output=\(response.usage?.outputTokens ?? -1)"
        )
        return AIAssistantTurn(
            text: response.text.isEmpty ? nil : response.text,
            toolCalls: response.toolCalls,
            reasoning: .anthropic(blocks: response.content)
        )
    }

    func request(
        model: String,
        systemPrompt: String,
        messages: [AITranscriptMessage],
        tools: [LLMToolDefinition]
    ) -> AnthropicRequest {
        let metadata = modelStore.metadata(for: model)
        return AnthropicRequest(
            model: model,
            maxTokens: min(Self.maxOutputTokens, modelStore.maxOutputTokens(for: model)),
            system: systemPrompt,
            messages: Self.messages(from: messages),
            tools: tools,
            // Unknown models: every current Claude model takes adaptive thinking, but sending
            // `fallbacks` to one that doesn't allow them is a 400.
            adaptiveThinking: metadata?.supportsAdaptiveThinking ?? true,
            effort: modelStore.effort(for: model),
            serverFallback: metadata?.supportsServerFallback ?? false
        )
    }

    // MARK: - Mapping

    /// Maps the transcript to Anthropic messages. Entries of the same role merge into one
    /// message, so a round's tool results share one user message.
    nonisolated static func messages(from transcript: [AITranscriptMessage]) -> [AnthropicMessage] {
        var result: [AnthropicMessage] = []
        func append(_ role: String, _ blocks: [AnthropicBlock]) {
            guard !blocks.isEmpty else { return }
            if result.last?.role == role {
                result[result.count - 1].content += blocks
            } else {
                result.append(AnthropicMessage(role: role, content: blocks))
            }
        }
        for entry in transcript {
            switch entry {
            case let .user(text):
                append("user", [.text(text)])
            case let .toolResult(output):
                append("user", [.toolResult(toolUseID: toolID(output.callID), content: output.output)])
            case let .assistant(turn):
                append("assistant", assistantBlocks(turn))
            }
        }
        return result
    }

    private nonisolated static func assistantBlocks(_ turn: AIAssistantTurn) -> [AnthropicBlock] {
        if case let .anthropic(blocks)? = turn.reasoning { return blocks }
        // Written by another provider: rebuild it from text and tool calls.
        var blocks: [AnthropicBlock] = []
        if let text = turn.text, !text.isEmpty { blocks.append(.text(text)) }
        for call in turn.toolCalls {
            let isObject = call.arguments.data(using: .utf8)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) } is [String: Any]
            blocks.append(AnthropicBlock(json: AnthropicJSON.object([
                ("id", AnthropicJSON.string(toolID(call.id))),
                ("input", isObject ? call.arguments : "{}"),
                ("name", AnthropicJSON.string(call.name)),
                ("type", #""tool_use""#),
            ])))
        }
        return blocks
    }

    /// Anthropic tool ids must match `[A-Za-z0-9_-]+`; other providers' ids may not.
    nonisolated static func toolID(_ id: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let mapped = String(id.map { allowed.contains($0) ? $0 : "_" })
        return mapped.isEmpty ? "_" : mapped
    }
}
