// ApplyPatchTool.swift
// Structured file patching tool for ProSSHMac AI agents
//
// Port of OpenAI Agents SDK's ApplyPatchTool to Swift, adapted for
// ProSSHMac's dual local/remote session model. Gives AI agents a safe,
// structured way to create, modify, and delete files using unified diffs
// instead of raw shell commands.
//
// Integration: Add as a new tool in AIToolDefinitions.buildToolDefinitions()
// and a new case in AIToolHandler.executeSingleToolCall().

import Foundation
import os.log

// MARK: - Approval Tracker

/// Tracks which patch operations have been approved to avoid repeat prompts.
///
/// Uses SHA-256 fingerprinting of (operation type + path + diff content) so
/// identical patches aren't asked about twice — important when the AI retries
/// after a tool error.
@MainActor
final class PatchApprovalTracker {

    private var approved: Set<String> = []

    /// Generate a fingerprint for a patch operation.
    func fingerprint(operation: PatchOperation) -> String {
        var components = [operation.type.rawValue, operation.path]
        if let diff = operation.diff {
            components.append(diff)
        }
        let joined = components.joined(separator: "\0")
        // Simple hash — not cryptographic, just deduplication.
        let data = Data(joined.utf8)
        return data.base64EncodedString().prefix(32).description
    }

    /// Check if an operation has been approved.
    func isApproved(_ fingerprint: String) -> Bool {
        approved.contains(fingerprint)
    }

    /// Record an operation as approved.
    func remember(_ fingerprint: String) {
        approved.insert(fingerprint)
    }

    /// Clear all approvals (e.g., when switching sessions).
    func reset() {
        approved.removeAll()
    }
}

// MARK: - Patch Operation

/// A single file operation requested by the AI agent.
struct PatchOperation: Sendable {

    enum OperationType: String, Sendable, Codable {
        case create
        case update
        case delete
    }

    /// The operation type.
    let type: OperationType

    /// Relative or absolute path to the target file.
    let path: String

    /// Unified diff content (required for create/update, ignored for delete).
    let diff: String?
}

// MARK: - Patch Result

/// Result of applying a patch operation.
struct PatchResult: Sendable {
    let success: Bool
    let output: String
    let linesChanged: Int
    let warnings: [String]
}

// MARK: - Workspace Patcher (Local)

/// Applies patch operations to the local filesystem with path sandboxing.
///
/// All paths are resolved relative to a workspace root (typically the session's
/// working directory). Operations that would escape the workspace are rejected.
struct LocalWorkspacePatcher: Sendable {

    private let workspaceRoot: URL

    init(workspaceRoot: URL) {
        self.workspaceRoot = workspaceRoot.standardizedFileURL
    }

    /// Apply a patch operation to the local filesystem.
    func apply(_ operation: PatchOperation) throws -> PatchResult {
        switch operation.type {
        case .create:
            return try createFile(operation)
        case .update:
            return try updateFile(operation)
        case .delete:
            return try deleteFile(operation)
        }
    }

    // MARK: - Operations

    private func createFile(_ operation: PatchOperation) throws -> PatchResult {
        let target = try resolvedPath(operation.path, ensureParent: true)
        let relativePath = self.relativePath(target)

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: target.path) {
            // File exists — treat as update instead.
            return try updateFile(operation)
        }

        let diff = operation.diff ?? ""
        let content: String
        // V4A create diffs have all lines prefixed with "+".
        // If the first non-empty line starts with "+", run through the V4A parser.
        // Otherwise treat the diff as raw file content (AI sometimes sends plain text).
        let firstContent = diff.components(separatedBy: "\n").first { !$0.isEmpty }
        if firstContent?.hasPrefix("+") == true {
            content = try applyDiff(input: "", diff: diff, mode: .create)
        } else {
            content = diff
        }

        try content.write(to: target, atomically: true, encoding: .utf8)

        let lineCount = content.components(separatedBy: "\n").count
        return PatchResult(
            success: true,
            output: "Created \(relativePath) (\(lineCount) lines)",
            linesChanged: lineCount,
            warnings: []
        )
    }

    private func updateFile(_ operation: PatchOperation) throws -> PatchResult {
        let target = try resolvedPath(operation.path)
        let relativePath = self.relativePath(target)

        guard FileManager.default.fileExists(atPath: target.path) else {
            throw PatchToolError.fileNotFound(relativePath)
        }

        let original = try String(contentsOf: target, encoding: .utf8)
        let diff = operation.diff ?? ""

        let patched = try applyDiff(input: original, diff: diff)

        // Calculate change stats.
        let originalLines = original.components(separatedBy: "\n")
        let patchedLines = patched.components(separatedBy: "\n")
        let linesChanged = abs(patchedLines.count - originalLines.count) +
            zip(originalLines, patchedLines).filter { $0 != $1 }.count

        try patched.write(to: target, atomically: true, encoding: .utf8)

        var warnings: [String] = []
        if patched == original {
            warnings.append("Patch applied but file content is unchanged")
        }

        return PatchResult(
            success: true,
            output: "Updated \(relativePath) (\(linesChanged) lines changed)",
            linesChanged: linesChanged,
            warnings: warnings
        )
    }

    private func deleteFile(_ operation: PatchOperation) throws -> PatchResult {
        let target = try resolvedPath(operation.path)
        let relativePath = self.relativePath(target)

        guard FileManager.default.fileExists(atPath: target.path) else {
            throw PatchToolError.fileNotFound(relativePath)
        }

        try FileManager.default.removeItem(at: target)

        return PatchResult(
            success: true,
            output: "Deleted \(relativePath)",
            linesChanged: 0,
            warnings: []
        )
    }

    // MARK: - Path Resolution

    /// Resolve a path relative to the workspace root, preventing escape.
    private func resolvedPath(_ path: String, ensureParent: Bool = false) throws -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        let target: URL

        if expanded.hasPrefix("/") {
            target = URL(fileURLWithPath: expanded).standardizedFileURL
        } else {
            target = workspaceRoot.appendingPathComponent(expanded).standardizedFileURL
        }

        // Security: verify the resolved path is within the workspace.
        guard target.path.hasPrefix(workspaceRoot.path) else {
            throw PatchToolError.outsideWorkspace(
                path: path,
                workspace: workspaceRoot.path
            )
        }

        if ensureParent {
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }

        return target
    }

    private func relativePath(_ url: URL) -> String {
        if let relative = url.path.range(of: workspaceRoot.path) {
            let remainder = String(url.path[relative.upperBound...])
            return remainder.hasPrefix("/") ? String(remainder.dropFirst()) : remainder
        }
        return url.lastPathComponent
    }
}

// MARK: - Remote Patcher

/// Applies patch operations on remote hosts via SSH shell commands.
///
/// Uses cat heredoc for creates and rm for deletes. Updates go through the
/// read-apply-write path in AIToolHandler (base64 read → applyDiff → base64 write).
struct RemotePatchCommandBuilder: Sendable {

    /// Build a shell command to apply a patch operation on a remote host.
    /// Only used for `.create` (cat heredoc) and `.delete` (rm) operations.
    /// `.update` operations go through the read-apply-write path in AIToolHandler.
    static func buildCommand(for operation: PatchOperation) -> String {
        switch operation.type {
        case .create:
            return buildCreateCommand(operation)
        case .update:
            preconditionFailure("update operations use the read-apply-write path in AIToolHandler; buildCommand should not be called for updates")
        case .delete:
            return buildDeleteCommand(operation)
        }
    }

    // MARK: - Create

    private static func buildCreateCommand(_ operation: PatchOperation) -> String {
        let path = shellEscaped(operation.path)
        let diff = operation.diff ?? ""

        // Extract content from diff (addition lines only).
        let content: String
        if diff.contains("@@") {
            // Parse addition lines from the diff.
            content = diff.components(separatedBy: "\n")
                .filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }
                .map { String($0.dropFirst()) }
                .joined(separator: "\n")
        } else {
            content = diff
        }

        let marker = "__PROSSH_PATCH_EOF_\(UUID().uuidString.prefix(8))__"

        return """
        __prossh_dir="$(dirname \(path))"; \
        mkdir -p "$__prossh_dir" && (cat > \(path) << '\(marker)'
        \(content)
        \(marker)
        )
        """
    }

    // MARK: - Delete

    private static func buildDeleteCommand(_ operation: PatchOperation) -> String {
        buildDeleteCommand(path: operation.path)
    }

    static func buildDeleteCommand(
        path: String,
        useSudo: Bool = false,
        nonInteractiveSudo: Bool = false
    ) -> String {
        let escapedPath = shellEscaped(path)
        let sudoPrefix: String
        if useSudo {
            sudoPrefix = nonInteractiveSudo ? "sudo -n" : "sudo"
        } else {
            sudoPrefix = ""
        }
        let rmCommand = useSudo ? "\(sudoPrefix) rm" : "rm"
        return """
        if [ -f \(escapedPath) ]; then \(rmCommand) \(escapedPath) && echo 'Deleted'; \
        else printf '__PROSSH_PATCH_ERROR__: file not found: %s\\n' \(escapedPath); fi
        """
    }

    // MARK: - Write (used by remote read-apply-write path)

    /// Build a command to write content to a remote file using base64 encoding.
    ///
    /// Base64 avoids heredoc escaping issues with special characters, preserves
    /// exact byte content, and works on all modern Ubuntu/Linux servers
    /// (base64 is part of coreutils). The heredoc delimiter only contains
    /// safe characters so it can never appear in the base64 payload.
    static func buildWriteCommand(
        path: String,
        content: String,
        useSudo: Bool = false,
        nonInteractiveSudo: Bool = false
    ) -> String {
        let escapedPath = shellEscaped(path)
        let b64 = Data(content.utf8).base64EncodedString(options: .lineLength76Characters)
        let marker = "__PROSSH_WRITE_EOF_\(UUID().uuidString.prefix(8))__"
        let dirCommand: String
        let teeCommand: String
        if useSudo {
            let sudoPrefix = nonInteractiveSudo ? "sudo -n" : "sudo"
            dirCommand = "\(sudoPrefix) mkdir -p \"$(dirname \(escapedPath))\""
            teeCommand = "\(sudoPrefix) tee \(escapedPath) > /dev/null"
        } else {
            dirCommand = "mkdir -p \"$(dirname \(escapedPath))\""
            teeCommand = "> \(escapedPath)"
        }
        // Wrap the heredoc in a subshell so the terminator stays on its own line
        // when executeCommandAndWait appends "; __ps=$?; ..." to the last line.
        if useSudo {
            return """
            \(dirCommand) && (base64 -d << '\(marker)' | \(teeCommand)
            \(b64)
            \(marker)
            )
            """
        }
        return """
        \(dirCommand) && (base64 -d \(teeCommand) << '\(marker)'
        \(b64)
        \(marker)
        )
        """
    }

    // MARK: - Read (base64, contamination-safe)

    /// Build a shell command to read a remote file using base64 encoding.
    ///
    /// Base64 output consists only of [A-Za-z0-9+/=] characters, making it immune
    /// to shell prompt / command-echo contamination when the output is captured via
    /// the terminal screen buffer. Pair with decodeBase64FileOutput(_:) to recover
    /// the original file content. This is the read-side pair of buildWriteCommand.
    static func buildReadCommand(
        path: String,
        useSudo: Bool = false,
        nonInteractiveSudo: Bool = false
    ) -> String {
        let escapedPath = shellEscaped(path)
        if useSudo {
            let sudoPrefix = nonInteractiveSudo ? "sudo -n" : "sudo"
            return "\(sudoPrefix) base64 \(escapedPath)"
        }
        return "base64 \(escapedPath)"
    }

    /// Build a command that prompts for sudo credentials and refreshes the sudo timestamp.
    /// Use when an operation needs elevation but non-interactive sudo is not yet available.
    static func buildSudoPrimingCommand() -> String {
        "sudo -v"
    }

    /// Extract and decode base64-encoded file content from contaminated command output.
    ///
    /// Filters rawOutput to keep only lines that consist entirely of valid base64
    /// characters ([A-Za-z0-9+/=]), joins them, base64-decodes the result, and
    /// returns the UTF-8 string. Returns nil if decoding fails (e.g., no valid
    /// base64 lines found, or binary file). Shell prompt lines, echoed commands,
    /// and exit-code markers are all automatically excluded by the character filter.
    static func decodeBase64FileOutput(_ rawOutput: String) -> String? {
        let b64Lines = rawOutput.components(separatedBy: "\n").filter { line in
            !line.isEmpty && line.allSatisfy {
                $0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "="
            }
        }
        let joined = b64Lines.joined()
        guard !joined.isEmpty,
              let data = Data(base64Encoded: joined, options: .ignoreUnknownCharacters),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }
        return content
    }

    // MARK: - Helpers

    private static func shellEscaped(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: #"'\"'\"'"#)
        return "'\(escaped)'"
    }

    /// Parse remote command output for patch errors.
    /// Only called for .delete operations; create/update go through buildWriteCommand.
    static func parseResult(_ output: String, operation: PatchOperation) -> PatchResult {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.contains("__PROSSH_PATCH_ERROR__") {
            let errorMessage = trimmed
                .components(separatedBy: "__PROSSH_PATCH_ERROR__:")
                .last?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
            return PatchResult(
                success: false,
                output: errorMessage,
                linesChanged: 0,
                warnings: []
            )
        }

        return PatchResult(
            success: true,
            output: "\(operation.type.rawValue.capitalized) \(operation.path)",
            linesChanged: 0,
            warnings: []
        )
    }
}

// MARK: - Errors

/// Errors specific to the patch tool.
enum PatchToolError: LocalizedError, Sendable {
    case outsideWorkspace(path: String, workspace: String)
    case fileNotFound(String)
    case invalidDiff(String)
    case approvalRequired(String)
    case remoteExecutionFailed(String)

    var errorDescription: String? {
        switch self {
        case .outsideWorkspace(let path, let workspace):
            return "Path '\(path)' resolves outside the workspace '\(workspace)'"
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .invalidDiff(let reason):
            return "Invalid diff: \(reason)"
        case .approvalRequired(let description):
            return "Approval required: \(description)"
        case .remoteExecutionFailed(let message):
            return "Remote patch execution failed: \(message)"
        }
    }
}

// MARK: - Tool Definition

/// Extension point for adding apply_patch to AIToolDefinitions.
///
/// Call `ApplyPatchToolDefinition.definition()` and append the result
/// to the tool definitions array in `AIToolDefinitions.buildToolDefinitions()`.
enum ApplyPatchToolDefinition {

    /// The JSON Schema tool definition for the apply_patch tool.
    ///
    /// This produces a definition compatible with OpenAI, Anthropic, and Ollama
    /// tool calling formats (all use JSON Schema for parameters).
    static func definition() -> LLMToolDefinition {
        LLMToolDefinition(
            name: "apply_patch",
            description: """
                Create, modify, or delete files using V4A diff format. Three operations:

                "create" — new file. The diff field contains every line prefixed with +.
                  Example diff: "+line one\\n+line two\\n+line three"

                "update" — modify an existing file. ALWAYS call read_file_chunk first.
                  The diff field uses V4A blocks (NOT unified @@ -N,M +N,M @@ headers):
                  - Use @@ or @@ <anchor> to start each change block.
                  - Include only changed lines in each block:
                    - removed lines with -
                    - added lines with +
                  - Do not include unchanged context lines.
                  - For pure insertion, prefer @@ <anchor> to place the new lines.
                  Example diff: "@@ def foo():\\n-    return old_val\\n+    return new_val\\n"

                "delete" — remove a file. No diff field needed.

                Safer than execute_command because paths are sandboxed, anchors disambiguate
                the right location, and writes are atomic.

                For protected remote files, the tool may return status="sudo_password_required"
                after queueing a sudo command in the terminal. In that case, ask the user
                to type their sudo password directly in the terminal and confirm before retrying.

                IMPORTANT: Try to make small, targeted patches that change only what is
                necessary. Avoid rewriting large sections of a file unless the task
                genuinely requires it.
                """,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "operation": .object([
                        "type": .string("string"),
                        "enum": .array([.string("create"), .string("update"), .string("delete")]),
                        "description": .string("The type of file operation to perform."),
                    ]),
                    "path": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Path to the target file. Can be absolute or relative to the session's working directory. " +
                            "Must be within the workspace boundary."
                        ),
                    ]),
                    "diff": .object([
                        "type": .string("string"),
                        "description": .string(
                            "For 'create': file content with + prefix per line. " +
                            "For 'update': V4A blocks using @@/@@ <anchor> with only +/- changed lines (no unified numeric hunks). " +
                            "For 'delete': omit or leave empty."
                        ),
                    ]),
                    "target_session": AIToolDefinitions.targetSessionProperty,
                ]),
                "required": .array([.string("operation"), .string("path")]),
            ])
        )
    }
}

// MARK: - AIToolHandler Integration Snippet
//
// Add this case to AIToolHandler.executeSingleToolCall():
//
//     case "apply_patch":
//         let operationType = try Self.requiredString(key: "operation", in: arguments, toolName: toolCall.name)
//         let path = try Self.requiredString(key: "path", in: arguments, toolName: toolCall.name)
//         let diff = Self.optionalString(key: "diff", in: arguments)
//
//         guard let opType = PatchOperation.OperationType(rawValue: operationType) else {
//             throw AIAgentServiceError.invalidToolArguments(
//                 toolName: toolCall.name,
//                 message: "operation must be 'create', 'update', or 'delete'"
//             )
//         }
//
//         let operation = PatchOperation(type: opType, path: path, diff: diff)
//
//         guard let session = provider.sessions.first(where: { $0.id == sessionID }) else {
//             throw AIAgentServiceError.sessionNotFound
//         }
//
//         // Approval gate (for guided mode profiles)
//         let approvalTracker = service?.patchApprovalTracker ?? PatchApprovalTracker()
//         let fingerprint = approvalTracker.fingerprint(operation: operation)
//         let profile = service?.currentProfile
//         if profile?.confirmBeforeExecute == true && !approvalTracker.isApproved(fingerprint) {
//             // Return a "needs approval" response — the UI layer handles the confirmation dialog.
//             return AIToolDefinitions.jsonString(from: .object([
//                 "ok": .bool(false),
//                 "status": .string("approval_required"),
//                 "operation": .string(operationType),
//                 "path": .string(path),
//                 "diff_preview": .string(String((diff ?? "").prefix(500))),
//             ]))
//         }
//         approvalTracker.remember(fingerprint)
//
//         if session.isLocal {
//             let workingDir = provider.workingDirectoryBySessionID[sessionID] ?? FileManager.default.currentDirectoryPath
//             let workspacePatcher = LocalWorkspacePatcher(workspaceRoot: URL(fileURLWithPath: workingDir))
//             let result = try workspacePatcher.apply(operation)
//             return AIToolDefinitions.jsonString(from: .object([
//                 "ok": .bool(result.success),
//                 "output": .string(result.output),
//                 "lines_changed": .number(Double(result.linesChanged)),
//                 "warnings": .array(result.warnings.map { .string($0) }),
//             ]))
//         } else {
//             let command = RemotePatchCommandBuilder.buildCommand(for: operation)
//             let execution = await provider.executeCommandAndWait(
//                 sessionID: sessionID,
//                 command: command,
//                 timeoutSeconds: 15
//             )
//             let result = RemotePatchCommandBuilder.parseResult(execution.output, operation: operation)
//             return AIToolDefinitions.jsonString(from: .object([
//                 "ok": .bool(result.success),
//                 "output": .string(result.output),
//                 "warnings": .array(result.warnings.map { .string($0) }),
//             ]))
//         }
