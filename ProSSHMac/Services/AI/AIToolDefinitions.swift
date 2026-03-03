// Extracted from OpenAIAgentService.swift
import Foundation
import os.log

enum AIToolDefinitions {

    // MARK: - Developer Prompt

    static func developerPrompt() -> String {
        """
        You are ProSSH Terminal Copilot — an expert terminal agent with full read/write access to the user's terminal session.

        CAPABILITIES:
        - Execute shell commands (execute_and_wait for one-shot, execute_command for interactive), read terminal screen, search/read files, edit files via apply_patch.
        - Run multi-step workflows: execute, inspect, decide next steps, iterate.
        - Send raw input to running processes via send_input (prompts, control keys, interactive CLIs). See the send_input tool description for named keys and patterns.

        COMMAND EXECUTION:
        - For one-shot commands (ls, grep, git, make, curl, etc.), use execute_and_wait — it runs the command AND returns the output and exit code in one step.
        - For interactive or long-running commands (vim, nano, top, tail -f, ssh), use execute_command (fire-and-forget), then get_current_screen to see the result.
        - To interact with a running process (answer prompts, send Ctrl+C, Tab-complete), use send_input. After send_input, call get_current_screen to see the response.
        - Always check exit_code after execute_and_wait: 0 = success, non-zero = failure. Investigate failures by reading the output.
        - Chain multiple commands as needed. Do not stop after one if the task requires more.

        CONTEXT:
        - The terminal tracks command blocks (id, command, output, exit_code, timestamp). Use get_recent_commands for history (with optional query filter), get_command_output for full output of a block, get_current_screen for the live view and session metadata.

        APPROACH:
        - Plan, execute, verify, iterate. Actually do the work — don't just explain how.
        - If a command fails, read the error and fix it. Do not repeat identical tool calls.
        - Use the minimum tool calls needed. Stop when the task is complete or you need user input.

        EFFICIENCY:
        - Batch file reads: use read_files (up to 10 files) instead of multiple single-file reads.
        - Issue parallel tool calls when operations are independent (reading multiple files, running commands on different broadcast sessions).
        - Use search_filesystem/search_file_contents instead of execute_and_wait with find/grep — the dedicated tools handle path resolution and output parsing.

        SUDO:
        - Use execute_command (not execute_and_wait) for sudo commands — the password prompt will timeout execute_and_wait.
        - After sudo, call get_current_screen. If it shows a password prompt, tell the user to type their password in the terminal, then STOP and wait for their confirmation.
        - If apply_patch returns status="sudo_password_required", do the same.

        SAFETY:
        - Never run destructive commands (rm -rf /, mkfs, dd if=/dev/zero, DROP TABLE, etc.) without explicit user confirmation.
        - Never expose secrets, API keys, passwords, or private keys in your responses.
        - If a command could have irreversible side effects, mention the risk and ask for confirmation before executing.

        BROADCAST:
        - Pass target_session=null to target ALL broadcast sessions, or a session ID to target one. In single-session mode, null targets the active session.
        - When a command fails on some sessions, use target_session to fix individually. Use parallel tool calls for independent operations on different sessions.

        FORMAT:
        - Use readable markdown with short paragraphs, bullet points, and code blocks.
        - Show relevant command output in fenced code blocks.
        - Be concise but thorough.

        FILE EDITING:
        - Use apply_patch to create/modify/delete files. Never use echo/cat/sed for file writes.
        - Always read_files before apply_patch with operation="update" to get exact current lines.
        - Use operation="create" for new files, not a shell command followed by a patch.
        - Prefer small, targeted diffs. See the apply_patch tool description for V4A format details.
        """
    }

    // MARK: - Tool Definitions

    static let targetSessionProperty: LLMJSONValue = .object([
        "type": .array([.string("string"), .string("null")]),
        "description": .string("Session ID or null (all broadcast sessions / primary in single mode)."),
    ])

    static func buildToolDefinitions(patchToolEnabled: Bool = true) -> [LLMToolDefinition] {
        let commonNoExtraProperties = LLMJSONValue.bool(false)

        return [
            LLMToolDefinition(
                name: "get_command_output",
                description: "Retrieve the full output of a previously executed command by its block ID. Get block IDs from get_recent_commands. Returns the output text, capped to max_chars (100-16000). Indicates if output was truncated and total character count.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "block_id": .object([
                            "type": .string("string"),
                            "description": .string("UUID of the command block."),
                        ]),
                        "max_chars": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum characters to return (100-16000)."),
                        ]),
                        "target_session": targetSessionProperty,
                    ]),
                    "required": .array([.string("block_id"), .string("max_chars"), .string("target_session")]),
                    "additionalProperties": commonNoExtraProperties,
                ]),
                strict: true
            ),
            LLMToolDefinition(
                name: "get_current_screen",
                description: "Read the current visible terminal screen contents and session metadata (host, state, working directory). Use after execute_command to see what happened, or to check the terminal's current state.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "max_lines": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum lines to return (10-800)."),
                        ]),
                        "target_session": targetSessionProperty,
                    ]),
                    "required": .array([.string("max_lines"), .string("target_session")]),
                    "additionalProperties": commonNoExtraProperties,
                ]),
                strict: true
            ),
            LLMToolDefinition(
                name: "search_filesystem",
                description: "Search for files and directories by name pattern in the active session's filesystem. Works on both local and remote (SSH) sessions. Supports glob patterns (*.swift, *.log) and substring matching. Returns paths with is_directory flag.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("Root path to search (absolute, ~, or relative to current working directory)."),
                        ]),
                        "name_pattern": .object([
                            "type": .string("string"),
                            "description": .string("Filename pattern to match (substring or wildcard)."),
                        ]),
                        "max_results": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum results to return (1-200)."),
                        ]),
                        "target_session": targetSessionProperty,
                    ]),
                    "required": .array([.string("path"), .string("name_pattern"), .string("max_results"), .string("target_session")]),
                    "additionalProperties": commonNoExtraProperties,
                ]),
                strict: true
            ),
            LLMToolDefinition(
                name: "search_file_contents",
                description: "Search for text inside files under a directory tree. Works on both local and remote sessions. Uses ripgrep (rg) if available, falls back to grep. Returns matching lines grouped by file with line numbers.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("Root path to search (absolute, ~, or relative to current working directory)."),
                        ]),
                        "text_pattern": .object([
                            "type": .string("string"),
                            "description": .string("Text pattern to find in files."),
                        ]),
                        "max_results": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum results to return (1-200)."),
                        ]),
                        "target_session": targetSessionProperty,
                    ]),
                    "required": .array([.string("path"), .string("text_pattern"), .string("max_results"), .string("target_session")]),
                    "additionalProperties": commonNoExtraProperties,
                ]),
                strict: true
            ),
            LLMToolDefinition(
                name: "read_files",
                description: "Read chunks from 1-10 files in a single call. Pass a single-entry array for one file. Each entry needs path, start_line, line_count. Returns content, lines_returned, has_more, next_start_line per file. Max 500 lines per file.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "files": .object([
                            "type": .string("array"),
                            "description": .string("Array of file read requests (1-10 items)."),
                            "items": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "path": .object([
                                        "type": .string("string"),
                                        "description": .string("File path (absolute, ~, or relative)."),
                                    ]),
                                    "start_line": .object([
                                        "type": .string("integer"),
                                        "description": .string("Line number to start reading from (1 or greater)."),
                                    ]),
                                    "line_count": .object([
                                        "type": .string("integer"),
                                        "description": .string("Number of lines to read (1-500)."),
                                    ]),
                                ]),
                                "required": .array([.string("path"), .string("start_line"), .string("line_count")]),
                                "additionalProperties": commonNoExtraProperties,
                            ]),
                        ]),
                        "target_session": targetSessionProperty,
                    ]),
                    "required": .array([.string("files"), .string("target_session")]),
                    "additionalProperties": commonNoExtraProperties,
                ]),
                strict: true
            ),
            LLMToolDefinition(
                name: "get_recent_commands",
                description: "List recent command blocks, optionally filtered by query. Each block includes id, command, output_preview, started_at, exit_code. Use get_command_output with block id for full output.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object([
                            "type": .array([.string("string"), .string("null")]),
                            "description": .string("Filter query for command text/output. Null for unfiltered recent history."),
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Max command blocks to return (1-50)."),
                        ]),
                        "target_session": targetSessionProperty,
                    ]),
                    "required": .array([.string("query"), .string("limit"), .string("target_session")]),
                    "additionalProperties": commonNoExtraProperties,
                ]),
                strict: true
            ),
            LLMToolDefinition(
                name: "execute_command",
                description: "Execute a shell command in the terminal (fire-and-forget). The command is sent to the shell but this tool does NOT wait for output — it returns immediately with status 'queued'. Use get_current_screen or get_command_output afterward to see results. Best for: interactive programs (vim, top, nano), long-running tasks, or when you just need to send input. For one-shot commands where you need the output, prefer execute_and_wait instead.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "command": .object([
                            "type": .string("string"),
                            "description": .string("Shell command to execute."),
                        ]),
                        "target_session": targetSessionProperty,
                    ]),
                    "required": .array([.string("command"), .string("target_session")]),
                    "additionalProperties": commonNoExtraProperties,
                ]),
                strict: true
            ),
            LLMToolDefinition(
                name: "execute_and_wait",
                description: "Execute a shell command and wait for it to complete, returning the output and exit code directly. Use this for one-shot commands (ls, grep, git, make, curl, etc.). Do NOT use for interactive or long-running programs (vim, nano, top, tail -f, ssh) — use execute_command instead. Returns: output text, exit_code (integer), timed_out (bool), truncated (bool).",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "command": .object([
                            "type": .string("string"),
                            "description": .string("Shell command to execute and wait for completion."),
                        ]),
                        "timeout_seconds": .object([
                            "type": .string("integer"),
                            "description": .string("Max seconds to wait for completion (5-60, default 30)."),
                        ]),
                        "target_session": targetSessionProperty,
                    ]),
                    "required": .array([.string("command"), .string("timeout_seconds"), .string("target_session")]),
                    "additionalProperties": commonNoExtraProperties,
                ]),
                strict: true
            ),
        ] + (patchToolEnabled ? [ApplyPatchToolDefinition.definition()] : [])
          + [SendInputToolDefinition.definition()]
    }

    // MARK: - Direct Action Tool Filtering

    static func directActionToolDefinitions(
        from tools: [LLMToolDefinition]
    ) -> [LLMToolDefinition] {
        let allowedNames: Set<String> = [
            "execute_command", "execute_and_wait", "get_current_screen",
            "get_recent_commands", "get_command_output", "read_files",
            "apply_patch", "send_input",
        ]
        let filtered = tools.filter { allowedNames.contains($0.name) }
        return filtered.isEmpty ? tools : filtered
    }

    static func isDirectActionPrompt(_ prompt: String) -> Bool {
        let lowered = prompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let directPrefixes = ["run ", "execute ", "cd "]
        return directPrefixes.contains(where: { lowered.hasPrefix($0) })
    }

    // MARK: - Shared Formatting Helpers

    static func errorResult(_ message: String, hint: String? = nil) -> String {
        var payload: [String: LLMJSONValue] = ["ok": .bool(false), "error": .string(message)]
        if let hint { payload["hint"] = .string(hint) }
        return jsonString(from: .object(payload))
    }

    static func jsonString(from value: LLMJSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return #"{"ok":false,"error":"failed_to_encode_tool_output"}"#
        }
        return string
    }

    static func shortTraceID() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }

    static func shortSessionID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8)).lowercased()
    }

    static func elapsedMillis(since startNanoseconds: UInt64) -> Int {
        let now = DispatchTime.now().uptimeNanoseconds
        let delta = now >= startNanoseconds ? now - startNanoseconds : 0
        return Int(delta / 1_000_000)
    }

    static func isPreviousResponseIDError(message: String) -> Bool {
        let lowercased = message.lowercased()
        return lowercased.contains("previous_response_id") ||
            lowercased.contains("previous response")
    }
}
