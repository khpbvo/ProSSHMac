// AIToolHandler+InteractiveInput.swift
// ProSSHMac
import Foundation

// MARK: - Tool Definition

enum SendInputToolDefinition {
    static func definition() -> LLMToolDefinition {
        LLMToolDefinition(
            name: "send_input",
            description: "Send raw input to the active terminal session — use for answering interactive prompts (y/n, passwords), sending control signals (ctrl_c to interrupt a running process), pressing special keys (tab for completion, arrow keys for navigation in CLIs). Unlike execute_command, no newline is appended and input is sent directly to whatever program is currently running in the terminal. Each element of 'keys' is either a named special key (enter, tab, shift_tab, escape, ctrl_c, ctrl_d, ctrl_z, ctrl_a, ctrl_e, ctrl_k, ctrl_u, ctrl_r, ctrl_w, ctrl_l, ctrl_x, ctrl_o, up, down, right, left, backspace, delete, home, end, page_up, page_down, f1–f12) or a literal text string sent verbatim. Elements are concatenated and sent left to right with no delay.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "keys": .object([
                        "type": .string("array"),
                        "description": .string("Ordered sequence of inputs to send. Each element is a named special key (e.g. 'enter', 'ctrl_c', 'up') or a literal string sent verbatim as UTF-8. Multiple elements are joined and sent in one write."),
                        "items": .object(["type": .string("string")]),
                    ]),
                ]),
                "required": .array([.string("keys")]),
                "additionalProperties": .bool(false),
            ]),
            strict: true
        )
    }
}

// MARK: - Handler Extension

extension AIToolHandler {
    func executeSendInput(
        sessionID: UUID,
        arguments: [String: LLMJSONValue],
        provider: any AIAgentSessionProviding
    ) async throws -> String {
        guard case let .array(keysArray) = arguments["keys"] else {
            throw AIAgentServiceError.invalidToolArguments(
                toolName: "send_input", message: "missing 'keys' array"
            )
        }

        let tokens: [String] = keysArray.compactMap {
            if case let .string(s) = $0 { return s } else { return nil }
        }
        guard !tokens.isEmpty else {
            throw AIAgentServiceError.invalidToolArguments(
                toolName: "send_input", message: "'keys' array must not be empty"
            )
        }

        let payload = Self.resolveKeys(tokens)
        await provider.sendRawShellInput(sessionID: sessionID, input: payload)

        return AIToolDefinitions.jsonString(from: .object([
            "ok": .bool(true),
            "sent_bytes": .number(Double(payload.utf8.count)),
        ]))
    }

    private static func resolveKeys(_ tokens: [String]) -> String {
        tokens.map { token in
            keySequence(for: token) ?? token
        }.joined()
    }

    private static func keySequence(for name: String) -> String? {
        switch name.lowercased() {
        case "enter":      return "\r"
        case "tab":        return "\t"
        case "shift_tab":  return "\u{1B}[Z"
        case "escape":     return "\u{1B}"
        case "ctrl_c":     return "\u{03}"
        case "ctrl_d":     return "\u{04}"
        case "ctrl_z":     return "\u{1A}"
        case "ctrl_a":     return "\u{01}"
        case "ctrl_e":     return "\u{05}"
        case "ctrl_k":     return "\u{0B}"
        case "ctrl_u":     return "\u{15}"
        case "ctrl_r":     return "\u{12}"
        case "ctrl_w":     return "\u{17}"
        case "ctrl_l":     return "\u{0C}"
        case "ctrl_x":     return "\u{18}"
        case "ctrl_o":     return "\u{0F}"
        case "up":         return "\u{1B}[A"
        case "down":       return "\u{1B}[B"
        case "right":      return "\u{1B}[C"
        case "left":       return "\u{1B}[D"
        case "backspace":  return "\u{7F}"
        case "delete":     return "\u{1B}[3~"
        case "home":       return "\u{1B}[H"
        case "end":        return "\u{1B}[F"
        case "page_up":    return "\u{1B}[5~"
        case "page_down":  return "\u{1B}[6~"
        case "f1":  return "\u{1B}OP"
        case "f2":  return "\u{1B}OQ"
        case "f3":  return "\u{1B}OR"
        case "f4":  return "\u{1B}OS"
        case "f5":  return "\u{1B}[15~"
        case "f6":  return "\u{1B}[17~"
        case "f7":  return "\u{1B}[18~"
        case "f8":  return "\u{1B}[19~"
        case "f9":  return "\u{1B}[20~"
        case "f10": return "\u{1B}[21~"
        case "f11": return "\u{1B}[23~"
        case "f12": return "\u{1B}[24~"
        default: return nil
        }
    }
}
