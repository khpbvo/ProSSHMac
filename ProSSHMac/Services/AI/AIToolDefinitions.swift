// Extracted from OpenAIAgentService.swift
import Foundation
import os.log

enum AIToolDefinitions {

    // MARK: - Developer Prompt

    static func developerPrompt() -> String {
        """
        You are ProSSH Terminal Copilot — an expert terminal agent with full read/write access to the user's terminal session.

        CAPABILITIES:
        - Execute any shell command and read its output directly (execute_and_wait).
        - Read the live terminal screen, structured command history, and individual command outputs.
        - Search and read files on the local or remote filesystem.
        - Run multi-step workflows: execute a command, inspect the result, decide next steps, repeat.
        - Access structured command blocks with UUIDs, exit codes, and timestamps.
        - Send raw input to a running process — answer prompts, send control signals, navigate interactive CLIs (send_input).

        COMMAND EXECUTION:
        - For one-shot commands (ls, grep, git, make, curl, cat via pipe, etc.), use execute_and_wait — it runs the command AND returns the output and exit code in one step.
        - For interactive or long-running commands (vim, nano, top, tail -f, ssh, htop), use execute_command (fire-and-forget), then get_current_screen to see the result.
        - To interact with a running process — answer a y/n prompt, type into a REPL, press Tab for completion, send Ctrl+C to interrupt — use send_input. It writes directly to whatever is currently running, with no newline injected unless you include "enter" in the keys array.
        - Always check the exit_code after execute_and_wait: 0 means success, non-zero means failure. Investigate failures by reading the output.
        - You can chain multiple commands to accomplish complex tasks. Do not stop after one command if the task requires more.

        INTERACTIVE INPUT (send_input):
        - Use send_input whenever a running program is waiting for input and execute_command would send a new shell command instead.
        - Common patterns:
          • Confirm a prompt:    send_input(keys: ["y", "enter"])
          • Interrupt a process: send_input(keys: ["ctrl_c"])
          • EOF / exit REPL:     send_input(keys: ["ctrl_d"])
          • Tab completion:      send_input(keys: ["tab"])
          • Arrow key navigation: send_input(keys: ["up"]) / send_input(keys: ["down"])
          • Suspend to bg:       send_input(keys: ["ctrl_z"])
          • Type then submit:    send_input(keys: ["some text", "enter"])
        - Named keys: enter, tab, shift_tab, escape, ctrl_c, ctrl_d, ctrl_z, ctrl_a, ctrl_e, ctrl_k, ctrl_u, ctrl_r, ctrl_w, ctrl_l, ctrl_x, ctrl_o, up, down, right, left, backspace, delete, home, end, page_up, page_down, f1–f12.
        - Anything that is not a named key is sent verbatim as UTF-8 text.
        - After send_input, use get_current_screen to observe the program's response.

        TERMINAL CONTEXT:
        - The terminal has shell integration that tracks command blocks with IDs and exit codes.
        - Use get_recent_commands to see recent command history with structured metadata (id, command, output_preview, exit_code, started_at).
        - Use get_command_output with a block_id to retrieve the full output of any previous command.
        - Use get_current_screen to see what is currently visible on the terminal.
        - Use search_terminal_history to find specific commands or output text from earlier in the session.

        APPROACH:
        - Think step-by-step. When asked to accomplish a task, plan your approach, execute, verify, and iterate.
        - Proactively explore when it helps answer the question — check file contents, run diagnostic commands, inspect logs.
        - If a command fails, read the error output, diagnose the issue, and suggest or attempt a fix.
        - Gather sufficient evidence before answering. If you need to run a command to confirm something, do it.
        - When the user asks you to do something (install, configure, debug, deploy, fix), actually do it — don't just explain how.
        - Do not repeat the same tool call with identical arguments.

        SAFETY:
        - Never run destructive commands (rm -rf /, mkfs, dd if=/dev/zero, DROP TABLE, etc.) without explicit user confirmation.
        - Never expose secrets, API keys, passwords, or private keys in your responses.
        - If a command could have irreversible side effects, mention the risk and ask for confirmation before executing.
        - Do not modify system files (/etc, /boot, etc.) unless the user specifically asks.

        FORMAT:
        - Use readable markdown with short paragraphs, bullet points, and code blocks.
        - If the user asks for a list (abilities, steps, options, checks), respond as a markdown bullet or numbered list, not a single dense paragraph.
        - Add a brief heading when it improves scanning.
        - Show relevant command output in fenced code blocks.
        - Be concise but thorough.

        ## File Editing with apply_patch

        Use `apply_patch` to create, modify, or delete files. It is safer and more
        reliable than shell redirection or sed/awk. NEVER write file content with
        echo, cat heredocs, or sed — use apply_patch instead.

        RULE 1 — Always read before updating:
        Before calling apply_patch with operation="update", read the current file
        with read_file_chunk. Copy the exact OLD lines you want to replace into
        `-` lines in the diff.

        RULE 2 — Create before patching:
        If the file does not yet exist, use operation="create". Never shell-create
        a file and then immediately patch it.

        RULE 3 — Prefer small, targeted changes:
        When modifying an existing file, try to patch only the lines that actually
        need to change. Avoid rewriting large sections or the entire file unless
        the task genuinely requires it — a minimal diff is easier to review and
        less likely to introduce unintended side effects.

        The `diff` field uses V4A format. Do NOT include *** Begin Patch,
        *** End Patch, or *** Update File: markers — those are expressed by the
        `operation` and `path` fields of the tool call. Only the change body goes
        in `diff`.

        ── CREATE (operation="create") ────────────────────────────────────────────
        Prefix every line of the new file with +. Nothing else.

          diff field:
            +#!/usr/bin/env python3
            +
            +def greet(name):
            +    return f"Hello, {name}!"
            +
            +if __name__ == "__main__":
            +    print(greet("world"))

        ── UPDATE (operation="update") ────────────────────────────────────────────
        Rules:
          • Use V4A blocks with @@ or @@ <anchor>.
          • Include ONLY changed lines inside each block:
            - lines to remove start with -
            - lines to add start with +
          • Do NOT include unchanged context lines.
          • Do NOT use numeric hunk specs like @@ -5,4 +5,4 @@.
          • Use @@ <anchor> when a change location is ambiguous or when inserting
            lines without any removed (-) line. The anchor must match a real line.

        Example — adjacent replacements (no @@ needed between consecutive changes):

          diff field:
            -debug = False
            +debug = True
            -timeout = 30
            +timeout = 60

        Example — non-adjacent replacements (use @@ anchor before each change):

          diff field:
            @@ debug = False
            -debug = False
            +debug = True
            @@ timeout = 30
            -timeout = 30
            +timeout = 60

        Example — anchored change:

          diff field:
            @@ def process_payment(order):
            -    charge = stripe.charge(order.total)
            +    charge = stripe.charge(order.total, currency="usd")

        Example — pure insertion anchored at a known line:

          diff field:
            @@ import sys
            +import pathlib

        ── DELETE (operation="delete") ────────────────────────────────────────────
        No diff field needed. The file is removed entirely.
        """
    }

    // MARK: - Tool Definitions

    static func buildToolDefinitions(patchToolEnabled: Bool = true) -> [OpenAIResponsesToolDefinition] {
        let commonNoExtraProperties = OpenAIJSONValue.bool(false)

        return [
            OpenAIResponsesToolDefinition(
                name: "search_terminal_history",
                description: "Search through the session's command history. Searches both command text and output. Returns matching CommandBlocks with: id (UUID), command, output_preview, started_at, exit_code. Use the returned block id with get_command_output to retrieve full output.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("Search query for command text or output."),
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Max results to return (1-50)."),
                        ]),
                    ]),
                    "required": .array([.string("query"), .string("limit")]),
                    "additionalProperties": commonNoExtraProperties,
                ]),
                strict: true
            ),
            OpenAIResponsesToolDefinition(
                name: "get_command_output",
                description: "Retrieve the full output of a previously executed command by its block ID. Get block IDs from search_terminal_history or get_recent_commands. Returns the output text, capped to max_chars (100-16000). Indicates if output was truncated and total character count.",
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
                    ]),
                    "required": .array([.string("block_id"), .string("max_chars")]),
                    "additionalProperties": commonNoExtraProperties,
                ]),
                strict: true
            ),
            OpenAIResponsesToolDefinition(
                name: "get_current_screen",
                description: "Read the current visible terminal screen contents. Returns an array of visible lines and the current working directory. Use after execute_command (fire-and-forget) to see what happened, or to understand the current state of the terminal.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "max_lines": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum lines to return (10-300)."),
                        ]),
                    ]),
                    "required": .array([.string("max_lines")]),
                    "additionalProperties": commonNoExtraProperties,
                ]),
                strict: true
            ),
            OpenAIResponsesToolDefinition(
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
                    ]),
                    "required": .array([.string("path"), .string("name_pattern"), .string("max_results")]),
                    "additionalProperties": commonNoExtraProperties,
                ]),
                strict: true
            ),
            OpenAIResponsesToolDefinition(
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
                    ]),
                    "required": .array([.string("path"), .string("text_pattern"), .string("max_results")]),
                    "additionalProperties": commonNoExtraProperties,
                ]),
                strict: true
            ),
            OpenAIResponsesToolDefinition(
                name: "read_file_chunk",
                description: "Read a window of lines from a text file. Returns content, lines_returned, has_more flag, and next_start_line for pagination. Max 200 lines per call. Use read_files for batch reading multiple files.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("File path to read (absolute, ~, or relative to current working directory)."),
                        ]),
                        "start_line": .object([
                            "type": .string("integer"),
                            "description": .string("Line number to start reading from (1 or greater)."),
                        ]),
                        "line_count": .object([
                            "type": .string("integer"),
                            "description": .string("Number of lines to read (1-200)."),
                        ]),
                    ]),
                    "required": .array([.string("path"), .string("start_line"), .string("line_count")]),
                    "additionalProperties": commonNoExtraProperties,
                ]),
                strict: true
            ),
            OpenAIResponsesToolDefinition(
                name: "read_files",
                description: "Read chunks from up to 10 files in a single call. More efficient than multiple read_file_chunk calls. Each file entry needs path, start_line, and line_count.",
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
                                        "description": .string("Number of lines to read (1-200)."),
                                    ]),
                                ]),
                                "required": .array([.string("path"), .string("start_line"), .string("line_count")]),
                                "additionalProperties": commonNoExtraProperties,
                            ]),
                        ]),
                    ]),
                    "required": .array([.string("files")]),
                    "additionalProperties": commonNoExtraProperties,
                ]),
                strict: true
            ),
            OpenAIResponsesToolDefinition(
                name: "get_recent_commands",
                description: "List recent command blocks in reverse chronological order. Each block includes: id (UUID), command text, output_preview (first 150 chars), started_at timestamp, and exit_code (null if unknown). Use get_command_output with the block id to see full output.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Max command blocks to return (1-50)."),
                        ]),
                    ]),
                    "required": .array([.string("limit")]),
                    "additionalProperties": commonNoExtraProperties,
                ]),
                strict: true
            ),
            OpenAIResponsesToolDefinition(
                name: "execute_command",
                description: "Execute a shell command in the terminal (fire-and-forget). The command is sent to the shell but this tool does NOT wait for output — it returns immediately with status 'queued'. Use get_current_screen or get_command_output afterward to see results. Best for: interactive programs (vim, top, nano), long-running tasks, or when you just need to send input. For one-shot commands where you need the output, prefer execute_and_wait instead.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "command": .object([
                            "type": .string("string"),
                            "description": .string("Shell command to execute."),
                        ]),
                    ]),
                    "required": .array([.string("command")]),
                    "additionalProperties": commonNoExtraProperties,
                ]),
                strict: true
            ),
            OpenAIResponsesToolDefinition(
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
                    ]),
                    "required": .array([.string("command"), .string("timeout_seconds")]),
                    "additionalProperties": commonNoExtraProperties,
                ]),
                strict: true
            ),
            OpenAIResponsesToolDefinition(
                name: "get_session_info",
                description: "Get metadata about the current terminal session: host label, username, hostname, port, connection state, whether it is local or SSH, start time, and current working directory.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                    "required": .array([]),
                    "additionalProperties": commonNoExtraProperties,
                ]),
                strict: true
            ),
        ] + (patchToolEnabled ? [ApplyPatchToolDefinition.definition()] : [])
          + [SendInputToolDefinition.definition()]
    }

    // MARK: - Direct Action Tool Filtering

    static func directActionToolDefinitions(
        from tools: [OpenAIResponsesToolDefinition]
    ) -> [OpenAIResponsesToolDefinition] {
        let allowedNames: Set<String> = [
            "execute_command", "execute_and_wait", "get_current_screen",
            "get_session_info", "get_recent_commands", "get_command_output",
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

    static func jsonString(from value: OpenAIJSONValue) -> String {
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
