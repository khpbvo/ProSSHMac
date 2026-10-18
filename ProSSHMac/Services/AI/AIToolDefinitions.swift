import Foundation
import os.log

enum AIToolDefinitions {

    // MARK: - Developer Prompt

    static func developerPrompt() -> String {
        """
        You are ProSSH Terminal Copilot, working in the user's open terminal sessions: local shells, SSH hosts, and routers, switches and appliances. The user sees every pane, so every command you run is visible as it runs.

        APPROACH:
        - Do the work, don't just explain it: run, read the result, decide, verify.
        - Fetch what a conclusion needs; if a result is incomplete, get the rest before giving a verdict. Never repeat an identical tool call.
        - Prefer the dedicated tools (read_files, search_filesystem, search_file_contents, apply_patch) over shell equivalents; they work over SSH too.

        SESSIONS:
        - Each turn lists the open sessions with their ids, which one is focused and which are broadcasting. You can act on any of them: pass its id as target_session.
        - target_session=null means the default: all broadcast sessions when the user is broadcasting, otherwise the focused session.
        - Sessions can open or close during a task; call list_sessions for the current list.
        - Use parallel tool calls for independent work on different sessions.
        - To compare hosts, run the same read-only command on each and compare the outputs before changing anything. Change one host, verify it, then do the rest.
        - Sessions marked "device CLI" sit at a router, switch or appliance prompt: use run_cli_command there. execute_and_wait and the file tools only work in POSIX shells.

        SAFETY:
        - Ask for explicit confirmation before destructive or irreversible commands (rm -rf, mkfs, dd, DROP TABLE, wiping config), and say what the risk is.
        - Never cut the path you are connected over: sshd, firewall, interface, route or ACL changes that carry a session need a tested rollback first (commit confirmed, reload in, a timed revert, a saved copy).
        - Never expose secrets, API keys, passwords or private keys in your responses.

        FORMAT:
        - Readable markdown: short paragraphs, bullets, command output in fenced code blocks. Concise but complete.
        - When a task changed anything, end with a handover, one line per host: what changed, how you verified it, how to undo it.
        """
    }

    // MARK: - Tool Definitions

    static let targetSessionProperty: LLMJSONValue = .object([
        "type": .array([.string("string"), .string("null")]),
        "description": .string("Id of an open session (from the open-sessions list or list_sessions), or null for the default targets: all broadcast sessions when broadcasting, otherwise the focused session."),
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
                description: "Execute a shell command and wait for it to complete, returning the output and exit code directly. Use this for one-shot commands (ls, grep, git, make, curl, etc.). Do NOT use for interactive or long-running programs (vim, nano, top, tail -f, ssh) — use execute_command instead. If the command asks for a password (sudo, su, ssh), the call waits while the user types it in the terminal; the result then carries a note, or an error if the user declined. Pagers are off and Debian/needrestart prompts are non-interactive for the command itself; sudo drops those settings, so pass them after sudo (sudo DEBIAN_FRONTEND=noninteractive apt-get -y …, systemctl --no-pager). Returns: output text, exit_code (integer), timed_out (bool), truncated (bool).",
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
            LLMToolDefinition(
                name: "list_sessions",
                description: "List every open terminal session you can act on: id (use as target_session), label, endpoint (user@host:port or local shell), whether it is focused or broadcasting, the prompt when it sits at a router/switch/appliance CLI (device_cli_prompt), and the default targets for target_session=null. The same list arrives with each user message; call this when sessions may have opened or closed since.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                    "required": .array([]),
                    "additionalProperties": commonNoExtraProperties,
                ]),
                strict: true
            ),
        ] + (patchToolEnabled ? [ApplyPatchToolDefinition.definition()] : [])
          + [SendInputToolDefinition.definition(), RunCLICommandToolDefinition.definition()]
    }

    // MARK: - Direct Action Tool Filtering

    static func directActionToolDefinitions(
        from tools: [LLMToolDefinition]
    ) -> [LLMToolDefinition] {
        let allowedNames: Set<String> = [
            "execute_command", "execute_and_wait", "get_current_screen",
            "get_recent_commands", "get_command_output", "read_files",
            "apply_patch", "send_input", "list_sessions", "run_cli_command",
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

    /// Every error tells the model what to do next, so `hint` is required.
    static func errorResult(_ message: String, hint: String) -> String {
        jsonString(from: errorObject(message, hint: hint))
    }

    nonisolated static func errorObject(_ message: String, hint: String) -> LLMJSONValue {
        .object(["ok": .bool(false), "error": .string(message), "hint": .string(hint)])
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

}
