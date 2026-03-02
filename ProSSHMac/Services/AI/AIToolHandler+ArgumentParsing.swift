// Extracted from AIToolHandler.swift
import Foundation

extension AIToolHandler {

    // MARK: - Argument Parsing Helpers

    static func decodeArguments(
        toolName: String,
        rawArguments: String
    ) throws -> [String: LLMJSONValue] {
        let trimmed = rawArguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return [:]
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw AIAgentServiceError.invalidToolArguments(
                toolName: toolName,
                message: "arguments are not valid UTF-8"
            )
        }
        do {
            return try JSONDecoder().decode([String: LLMJSONValue].self, from: data)
        } catch {
            throw AIAgentServiceError.invalidToolArguments(
                toolName: toolName,
                message: "arguments must be a JSON object"
            )
        }
    }

    static func requiredString(
        key: String,
        in arguments: [String: LLMJSONValue],
        toolName: String
    ) throws -> String {
        guard let raw = arguments[key] else {
            throw AIAgentServiceError.invalidToolArguments(
                toolName: toolName,
                message: "missing '\(key)'"
            )
        }
        switch raw {
        case let .string(value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        default:
            break
        }
        throw AIAgentServiceError.invalidToolArguments(
            toolName: toolName,
            message: "'\(key)' must be a non-empty string"
        )
    }

    static func requiredInt(
        key: String,
        in arguments: [String: LLMJSONValue],
        toolName: String
    ) throws -> Int {
        guard let raw = arguments[key] else {
            throw AIAgentServiceError.invalidToolArguments(
                toolName: toolName,
                message: "missing '\(key)'"
            )
        }
        switch raw {
        case let .number(number):
            return Int(number.rounded())
        case let .string(string):
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = Int(trimmed) {
                return value
            }
        default:
            break
        }
        throw AIAgentServiceError.invalidToolArguments(
            toolName: toolName,
            message: "'\(key)' must be an integer"
        )
    }

    static func optionalString(
        key: String,
        in arguments: [String: LLMJSONValue]
    ) -> String? {
        guard let value = arguments[key] else { return nil }
        switch value {
        case let .string(s):
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        default: return nil
        }
    }

    static func optionalInt(
        key: String,
        in arguments: [String: LLMJSONValue]
    ) -> Int? {
        guard let value = arguments[key] else {
            return nil
        }
        switch value {
        case let .number(number):
            return Int(number.rounded())
        case let .string(string):
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    static func clamp(_ value: Int, min minValue: Int, max maxValue: Int) -> Int {
        Swift.min(maxValue, Swift.max(minValue, value))
    }
}
