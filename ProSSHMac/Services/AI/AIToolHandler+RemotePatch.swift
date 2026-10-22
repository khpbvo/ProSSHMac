// AIToolHandler+RemotePatch.swift
// ProSSHMac
//
// apply_patch on a remote POSIX host: base64 read, V4A applied in-process, base64 heredoc write
// (Docs/RemotePatchingFix.md). Each command runs plain first and again with sudo on permission
// denied; a sudo password prompt pauses the command for the user like any other
// (Docs/CredentialPrompt.md), so there is no non-interactive probe and no priming step.
import Foundation

extension AIToolHandler {

    struct RemotePatchOutcome {
        var result: PatchResult
        /// A command stopped at a password prompt and waited for the user.
        var waitedForCredential = false
        /// The user declined a password prompt; the patch stopped there.
        var declinedCredential = false
    }

    private struct RemotePatchStep {
        var result: CommandExecutionResult
        var usedSudo: Bool
        var waitedForCredential: Bool
    }

    func applyRemotePatch(
        _ operation: PatchOperation,
        sessionID: UUID,
        provider: any AIAgentSessionProviding
    ) async -> RemotePatchOutcome {
        let path = operation.path
        var outcome = RemotePatchOutcome(result: PatchResult(success: false, output: "Patch failed.", linesChanged: 0, warnings: []))

        func run(sudoFirst: Bool = false, timeout: TimeInterval, _ command: (Bool) -> String) async -> RemotePatchStep {
            let step = await runRemotePatchCommand(
                provider: provider, sessionID: sessionID, timeoutSeconds: timeout, sudoFirst: sudoFirst, command: command
            )
            outcome.waitedForCredential = outcome.waitedForCredential || step.waitedForCredential
            outcome.declinedCredential = step.result.declinedCredential
            if Task.isCancelled { outcome.result = Self.failedPatch("Tool call cancelled; no further patch commands were sent.") }
            return step
        }

        switch operation.type {
        case .update:
            let diff = operation.diff ?? ""
            let read = await run(timeout: 10) { RemotePatchCommandBuilder.buildReadCommand(path: path, useSudo: $0) }
            if outcome.declinedCredential || Task.isCancelled { return outcome }
            // Partial base64 can decode successfully after a timeout or a failed read.
            // Never build a replacement from an incomplete source file.
            guard !read.result.timedOut, read.result.exitCode == 0 else {
                outcome.result = Self.failedPatch(Self.buildPatchFailureMessage(
                    prefix: read.result.timedOut ? "Read timed out; nothing was written" : "Read failed; nothing was written",
                    rawOutput: read.result.output
                ))
                return outcome
            }
            let decoded = read.result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "" : RemotePatchCommandBuilder.decodeBase64FileOutput(read.result.output)
            guard let original = decoded else {
                outcome.result = Self.failedPatch(
                    read.usedSudo
                        ? Self.buildPatchFailureMessage(prefix: "Sudo read failed", rawOutput: read.result.output)
                        : "Failed to read remote file '\(path)': could not decode base64 output. Verify the file exists and is a text file."
                )
                return outcome
            }
            let patched: String
            do {
                patched = try applyDiff(input: original, diff: diff)
            } catch {
                outcome.result = Self.failedPatch("Diff application failed: \(error.localizedDescription)")
                return outcome
            }
            let originalLines = original.components(separatedBy: "\n")
            let patchedLines = patched.components(separatedBy: "\n")
            let linesChanged = abs(patchedLines.count - originalLines.count)
                + zip(originalLines, patchedLines).filter { $0.0 != $0.1 }.count
            let warnings = patched == original ? ["Patch applied but file content is unchanged"] : []

            // A file that needed sudo to read needs it to write.
            let write = await run(sudoFirst: read.usedSudo, timeout: 20) {
                RemotePatchCommandBuilder.buildWriteCommand(path: path, content: patched, useSudo: $0)
            }
            if outcome.declinedCredential || Task.isCancelled { return outcome }
            outcome.result = !write.result.timedOut && write.result.exitCode == 0
                ? PatchResult(
                    success: true,
                    output: "Updated \(path) (\(linesChanged) lines changed\(write.usedSudo ? ", using sudo" : ""))",
                    linesChanged: linesChanged,
                    warnings: warnings
                )
                : PatchResult(
                    success: false,
                    output: Self.buildPatchFailureMessage(prefix: write.usedSudo ? "Sudo write failed" : "Write failed", rawOutput: write.result.output),
                    linesChanged: linesChanged,
                    warnings: warnings
                )

        case .create:
            let content: String
            do {
                content = try applyDiff(input: "", diff: operation.diff ?? "", mode: .create)
            } catch {
                outcome.result = Self.failedPatch("Diff application failed: \(error.localizedDescription)")
                return outcome
            }
            let lineCount = content.components(separatedBy: "\n").count
            let write = await run(timeout: 20) {
                RemotePatchCommandBuilder.buildWriteCommand(path: path, content: content, useSudo: $0)
            }
            if outcome.declinedCredential || Task.isCancelled { return outcome }
            outcome.result = !write.result.timedOut && write.result.exitCode == 0
                ? PatchResult(
                    success: true,
                    output: "Created \(path) (\(lineCount) lines\(write.usedSudo ? ", using sudo" : ""))",
                    linesChanged: lineCount,
                    warnings: []
                )
                : PatchResult(
                    success: false,
                    output: Self.buildPatchFailureMessage(prefix: write.usedSudo ? "Sudo create failed" : "Create failed", rawOutput: write.result.output),
                    linesChanged: lineCount,
                    warnings: []
                )

        case .delete:
            let delete = await run(timeout: 15) { RemotePatchCommandBuilder.buildDeleteCommand(path: path, useSudo: $0) }
            if outcome.declinedCredential || Task.isCancelled { return outcome }
            if !delete.result.timedOut && delete.result.exitCode == 0 {
                let parsed = RemotePatchCommandBuilder.parseResult(delete.result.output, operation: operation)
                outcome.result = parsed.success && delete.usedSudo
                    ? PatchResult(success: true, output: "Deleted \(path) (using sudo)", linesChanged: 0, warnings: [])
                    : parsed
            } else {
                let parsed = RemotePatchCommandBuilder.parseResult(delete.result.output, operation: operation)
                outcome.result = parsed.success
                    ? Self.failedPatch(Self.buildPatchFailureMessage(
                        prefix: delete.usedSudo ? "Sudo delete failed" : "Delete failed",
                        rawOutput: delete.result.output
                    ))
                    : parsed
            }
        }
        return outcome
    }

    /// Runs `command(false)`, and `command(true)` if that failed with permission denied. With
    /// `sudoFirst` it runs only `command(true)`.
    private func runRemotePatchCommand(
        provider: any AIAgentSessionProviding,
        sessionID: UUID,
        timeoutSeconds: TimeInterval,
        sudoFirst: Bool,
        command: (Bool) -> String
    ) async -> RemotePatchStep {
        guard !Task.isCancelled else {
            return RemotePatchStep(
                result: CommandExecutionResult(output: "Tool call cancelled.", exitCode: nil, timedOut: false, blockID: nil),
                usedSudo: sudoFirst, waitedForCredential: false
            )
        }
        let first: CommandExecutionResult
        if sudoFirst {
            // A sudo password prompt must remain visible in the terminal.
            first = await provider.executeCommandAndWait(
                sessionID: sessionID, command: command(true), timeoutSeconds: timeoutSeconds
            )
        } else {
            first = await provider.executeInternalCommandAndWait(
                sessionID: sessionID, command: command(false), timeoutSeconds: timeoutSeconds
            )
        }
        guard !Task.isCancelled, !sudoFirst, !first.declinedCredential, !first.timedOut, first.exitCode != 0,
              Self.isPermissionDeniedPatchOutput(Self.trimmedPatchOutput(first.output)) else {
            return RemotePatchStep(result: first, usedSudo: sudoFirst, waitedForCredential: first.waitedForCredential)
        }
        let elevated = await provider.executeCommandAndWait(
            sessionID: sessionID, command: command(true), timeoutSeconds: timeoutSeconds
        )
        return RemotePatchStep(
            result: elevated,
            usedSudo: true,
            waitedForCredential: first.waitedForCredential || elevated.waitedForCredential
        )
    }

    private static func failedPatch(_ message: String) -> PatchResult {
        PatchResult(success: false, output: message, linesChanged: 0, warnings: [])
    }

    static func trimmedPatchOutput(_ output: String) -> String {
        output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isPermissionDeniedPatchOutput(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("permission denied") ||
            lower.contains("operation not permitted") ||
            lower.contains("read-only file system") ||
            lower.contains("access denied") ||
            lower.contains("eacces")
    }

    static func buildPatchFailureMessage(prefix: String, rawOutput: String) -> String {
        let trimmed = trimmedPatchOutput(rawOutput)
        if trimmed.isEmpty {
            return "\(prefix): command returned no output"
        }
        return "\(prefix): \(trimmed)"
    }
}
