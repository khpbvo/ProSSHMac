// AIToolHandler+DeviceCLI.swift
// ProSSHMac
import Foundation

// MARK: - Tool Definition

enum RunCLICommandToolDefinition {
    static func definition() -> LLMToolDefinition {
        LLMToolDefinition(
            name: "run_cli_command",
            description: "Run one command at a router, switch or appliance CLI prompt (Cisco IOS, Junos, EOS, RouterOS, FRR vtysh, firewalls…) and return its complete output once the prompt returns. Pager prompts (--More--) are answered automatically, and the output is the device's own lines, not the wrapped screen. Use this wherever the session list marks a session as a device CLI; execute_and_wait only works in POSIX shells. If the device asks for a password (enable), the call waits while the user types it in the terminal. If it asks anything else (confirm, filename), the result has completed=false and awaiting_input with the question: answer it with send_input. One command per call; for configuration, send each line as its own call.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "command": .object([
                        "type": .string("string"),
                        "description": .string("The command line exactly as typed at the device prompt, without a trailing newline."),
                    ]),
                    "timeout_seconds": .object([
                        "type": .string("integer"),
                        "description": .string("Max seconds to wait for the prompt to return (5-120, default 30)."),
                    ]),
                    "target_session": AIToolDefinitions.targetSessionProperty,
                ]),
                "required": .array([.string("command"), .string("timeout_seconds"), .string("target_session")]),
                "additionalProperties": .bool(false),
            ]),
            strict: true
        )
    }
}

// MARK: - Handler Extension

extension AIToolHandler {
    static let maxCLIOutputChars = 16000

    func executeRunCLICommand(
        sessionID: UUID,
        broadcastContext: BroadcastContext?,
        arguments: [String: LLMJSONValue],
        provider: any AIAgentSessionProviding
    ) async throws -> String {
        let command = try Self.requiredString(key: "command", in: arguments, toolName: "run_cli_command")
        let timeout = TimeInterval(Self.clamp(
            Self.optionalInt(key: "timeout_seconds", in: arguments) ?? 30,
            min: 5,
            max: 120
        ))
        let targets = resolveTargetSessions(
            arguments: arguments,
            primarySessionID: sessionID,
            broadcastContext: broadcastContext
        )

        var results: [(UUID, CLICommandResult)] = []
        for target in targets {
            results.append((target, await provider.executeCLICommand(
                sessionID: target,
                command: command,
                timeoutSeconds: timeout
            )))
        }

        if results.count == 1, let (_, result) = results.first {
            return AIToolDefinitions.jsonString(from: Self.cliResultJSON(
                result, timeout: timeout, label: Self.sessionLabel(targets.first ?? sessionID, in: provider)
            ))
        }
        return AIToolDefinitions.jsonString(from: .object([
            "ok": .bool(true),
            "sessions_targeted": .number(Double(results.count)),
            "results": .array(results.map { target, result in
                let label = Self.sessionLabel(target, in: provider)
                var entry = Self.cliResultJSON(result, timeout: timeout, label: label)
                if case var .object(fields) = entry {
                    fields["session_id"] = .string(target.uuidString)
                    fields["session"] = .string(label)
                    entry = .object(fields)
                }
                return entry
            }),
        ]))
    }

    /// Sessions among `targets` whose cursor sits at a router/switch/appliance prompt.
    func deviceCLITargets(_ targets: [UUID], provider: any AIAgentSessionProviding) -> [(UUID, String)] {
        targets.compactMap { target in
            let line = DeviceCLIPrompt.cursorLine(in: provider.shellBuffers[target] ?? [])
            return DeviceCLIPrompt.classify(line) == .deviceCLI ? (target, line) : nil
        }
    }

    private static func cliResultJSON(_ result: CLICommandResult, timeout: TimeInterval, label: String) -> LLMJSONValue {
        let truncated = result.output.count > maxCLIOutputChars
        var fields: [String: LLMJSONValue] = [
            "ok": .bool(true),
            "output": .string(truncated ? String(result.output.prefix(maxCLIOutputChars)) : result.output),
            "completed": .bool(result.status == .completed),
            "pages_advanced": .number(Double(result.pagesAdvanced)),
            "truncated": .bool(truncated),
            "total_chars": .number(Double(result.output.count)),
        ]
        switch result.status {
        case .completed:
            fields["final_prompt"] = result.finalPrompt.map { .string($0) } ?? .null
        case let .awaitingInput(question):
            fields["awaiting_input"] = .string(question)
            fields["hint"] = .string("The device is asking a question. Answer it with send_input (for example the answer followed by \"enter\"), then call run_cli_command or get_current_screen.")
        case .timedOut:
            fields["timed_out"] = .bool(true)
            fields["hint"] = .string("The prompt did not return within \(Int(timeout)) seconds. It may still be running: check get_current_screen, or send ctrl_c with send_input.")
        case .superseded:
            fields["ok"] = .bool(false)
            fields["error"] = .string("A newer command started in this session.")
            fields["hint"] = .string("Another command took over this session. Check get_current_screen and run this one again if it is still needed.")
        case .failed:
            fields["ok"] = .bool(false)
            fields["error"] = .string(result.output)
            fields["hint"] = .string("Check the session with get_current_screen and list_sessions before retrying.")
        case .declined:
            fields["ok"] = .bool(false)
            fields["error"] = .string(credentialDeclinedMessage(label: label))
            fields["hint"] = .string(credentialDeclinedHint)
        }
        if result.waitedForCredential, result.status != .declined {
            fields["note"] = .string(credentialWaitNote)
        }
        return .object(fields)
    }
}
