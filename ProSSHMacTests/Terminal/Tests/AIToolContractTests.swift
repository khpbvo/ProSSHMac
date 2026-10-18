// AIToolContractTests.swift
// ProSSHMac
//
// Every exposed tool works on valid minimal input, and every error tells the model what to do
// next. See Docs/NetworkCopilot.md Phase 4.

#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

@MainActor
final class AIToolContractTests: XCTestCase {
    private var directory: URL!
    private var provider: ContractSessionProvider!
    private var service: AIAgentService!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tool-contract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "hello\nworld\n".write(to: directory.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        provider = ContractSessionProvider(workingDirectory: directory.path)
        let client = ContractOpenRouterService()
        let defaults = UserDefaults(suiteName: "AIToolContractTests.\(UUID().uuidString)")!
        defaults.set(true, forKey: "ai.patchTool.requireApproval")
        service = AIAgentService(
            openRouterClient: client,
            sessionProvider: provider,
            modelStore: OpenRouterModelStore(client: client, defaults: defaults),
            defaults: defaults
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func run(_ name: String, _ arguments: String) async -> String {
        let outputs = await service.toolHandler.executeToolCalls(
            sessionID: provider.sessionID,
            broadcastContext: nil,
            toolCalls: [LLMToolCall(id: "call_1", name: name, arguments: arguments)],
            skills: AISkillSet([AISkill(name: "probe", description: "A test skill", platforms: [], body: "Steps.", source: .bundled)]),
            traceID: "contract"
        )
        return outputs.first?.output ?? ""
    }

    /// Valid minimal arguments for every exposed tool.
    private var minimalArguments: [String: String] {
        let block = provider.commandBlocks[0].id.uuidString
        return [
            "get_command_output": #"{"block_id":"\#(block)","max_chars":100,"target_session":null}"#,
            "get_current_screen": #"{"max_lines":10,"target_session":null}"#,
            "search_filesystem": #"{"path":".","name_pattern":"notes","max_results":5,"target_session":null}"#,
            "search_file_contents": #"{"path":".","text_pattern":"world","max_results":5,"target_session":null}"#,
            "read_files": #"{"files":[{"path":"notes.txt","start_line":1,"line_count":2}],"target_session":null}"#,
            "get_recent_commands": #"{"query":null,"limit":5,"target_session":null}"#,
            "execute_command": #"{"command":"true","target_session":null}"#,
            "execute_and_wait": #"{"command":"true","timeout_seconds":5,"target_session":null}"#,
            "list_sessions": "{}",
            "load_skill": #"{"name":"probe"}"#,
            "apply_patch": #"{"operation":"create","path":"new.txt","diff":"+created","target_session":null}"#,
            "send_input": #"{"keys":["enter"],"target_session":null}"#,
            "run_cli_command": #"{"command":"show version","timeout_seconds":5,"target_session":null}"#,
        ]
    }

    func testEveryExposedToolSucceedsOnValidMinimalArguments() async throws {
        let exposed = AIToolDefinitions.buildToolDefinitions(patchToolEnabled: true).map(\.name)
        XCTAssertEqual(Set(minimalArguments.keys), Set(exposed), "every exposed tool needs a contract case")

        for name in exposed {
            let output = await run(name, try XCTUnwrap(minimalArguments[name]))
            XCTAssertFalse(output.contains(#""ok":false"#), "\(name): \(output)")
            XCTAssertFalse(output.isEmpty, name)
        }
        XCTAssertEqual(
            try String(contentsOf: directory.appendingPathComponent("new.txt"), encoding: .utf8)
                .trimmingCharacters(in: .newlines),
            "created"
        )
    }

    func testEveryErrorCarriesAHint() async throws {
        let closed = UUID()
        provider.sessions.append(Session(
            id: closed, kind: .ssh(hostID: UUID()), hostLabel: "gone", username: "kevin",
            hostname: "10.0.0.9", port: 22, state: .disconnected
        ))
        provider.simulatedCLIResult = CLICommandResult(output: "Session is not connected.", status: .failed)
        let cases: [(String, String)] = [
            ("no_such_tool", "{}"),
            ("get_command_output", #"{"block_id":"not-a-uuid","max_chars":100,"target_session":null}"#),
            ("get_command_output", "{not json"),
            ("execute_and_wait", #"{"timeout_seconds":5,"target_session":null}"#),
            ("execute_and_wait", #"{"command":"true","timeout_seconds":5,"target_session":"\#(closed.uuidString)"}"#),
            ("read_files", #"{"files":[{"path":"missing.txt","start_line":1,"line_count":2},{"path":"."}],"target_session":null}"#),
            ("read_files", #"{"files":[{"path":".","start_line":1,"line_count":2}],"target_session":null}"#),
            ("search_filesystem", #"{"path":"missing","name_pattern":"x","max_results":5,"target_session":null}"#),
            ("search_file_contents", #"{"path":"missing","text_pattern":"x","max_results":5,"target_session":null}"#),
            ("apply_patch", #"{"operation":"update","path":"notes.txt","target_session":null}"#),
            ("apply_patch", #"{"operation":"rename","path":"notes.txt","target_session":null}"#),
            ("apply_patch", #"{"operation":"update","path":"notes.txt","diff":"@@ nothing here\n-absent\n+present","target_session":null}"#),
            ("run_cli_command", #"{"command":"show version","timeout_seconds":5,"target_session":null}"#),
            ("load_skill", #"{"name":"missing"}"#),
            ("load_skill", "{}"),
        ]

        for (name, arguments) in cases {
            let output = await run(name, arguments)
            let json = try JSONSerialization.jsonObject(with: Data(output.utf8))
            let failures = Self.failures(in: json)
            XCTAssertFalse(failures.isEmpty, "\(name) \(arguments) should fail: \(output)")
            for failure in failures {
                let hint = failure["hint"] as? String ?? ""
                XCTAssertFalse(hint.isEmpty, "\(name) \(arguments): error without a hint: \(output)")
            }
        }
    }

    func testUnknownSkillHintListsTheInstalledSkills() async {
        let output = await run("load_skill", #"{"name":"missing"}"#)
        XCTAssertTrue(output.contains("Available skills: probe."), output)
        let loaded = await run("load_skill", #"{"name":"probe"}"#)
        XCTAssertTrue(loaded.contains(#""body":"Steps.""#), loaded)
    }

    func testOutOfRangeAndFractionalIntegersReturnErrorsWithoutTrapping() async throws {
        for numeric in ["1e100", "-1e100", "1.5"] {
            let output = await run("search_filesystem", "{\"path\":\".\",\"name_pattern\":\"notes\",\"max_results\":\(numeric)}")
            XCTAssertTrue(output.contains(#""ok":false"#), output)
            let files = await run("read_files", "{\"files\":[{\"path\":\"notes.txt\",\"start_line\":1,\"line_count\":\(numeric)}]}")
            XCTAssertTrue(files.contains(#""ok":false"#), files)
        }
        XCTAssertNil(AIToolHandler.optionalInt(key: "value", in: ["value": .number(.infinity)]))
        XCTAssertNil(AIToolHandler.optionalInt(key: "value", in: ["value": .number(.nan)]))
    }

    func testPatchDispatcherPreservesTrailingSpacesAndFinalBlankLine() async throws {
        let output = await run("apply_patch", #"{"operation":"create","path":"spaces.txt","diff":"+  indented  \n+\n"}"#)
        XCTAssertTrue(output.contains(#""ok":true"#), output)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("spaces.txt"), encoding: .utf8), "  indented  \n")
    }

    func testLocalReadHonorsTheFiveHundredLineSchemaLimit() async throws {
        let lines = (1...450).map { "line \($0)" }
        try lines.joined(separator: "\n").write(to: directory.appendingPathComponent("long.txt"), atomically: true, encoding: .utf8)
        let output = await run("read_files", #"{"files":[{"path":"long.txt","start_line":1,"line_count":300}]}"#)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let result = try XCTUnwrap((object["results"] as? [[String: Any]])?.first)
        XCTAssertEqual(result["lines_returned"] as? Int, 300)
        XCTAssertEqual(result["next_start_line"] as? Int, 301)
        XCTAssertEqual(result["content"] as? String, lines.prefix(300).joined(separator: "\n"))
    }

    func testRemotePatchNeverWritesAfterAFailedOrTimedOutRead() async {
        let base64 = Data("old".utf8).base64EncodedString()
        for execution in [
            CommandExecutionResult(output: base64, exitCode: 1, timedOut: false, blockID: nil),
            CommandExecutionResult(output: base64, exitCode: 0, timedOut: true, blockID: nil),
            CommandExecutionResult(output: base64, exitCode: nil, timedOut: false, blockID: nil),
        ] {
            provider.executedCommands = []
            provider.simulatedExecutions = [execution]
            let outcome = await service.toolHandler.applyRemotePatch(
                PatchOperation(type: .update, path: "config.txt", diff: "@@\n-old\n+new"),
                sessionID: provider.sessionID, provider: provider
            )
            XCTAssertFalse(outcome.result.success)
            XCTAssertEqual(provider.executedCommands.count, 1, "a partial source must not be written back")
        }
    }

    func testRemotePatchCanInsertIntoAnEmptyFile() async {
        provider.simulatedExecutions = [
            CommandExecutionResult(output: "", exitCode: 0, timedOut: false, blockID: nil),
            CommandExecutionResult(output: "", exitCode: 0, timedOut: false, blockID: nil),
        ]
        let outcome = await service.toolHandler.applyRemotePatch(
            PatchOperation(type: .update, path: "empty.txt", diff: "@@\n+first"),
            sessionID: provider.sessionID, provider: provider
        )
        XCTAssertTrue(outcome.result.success, outcome.result.output)
        XCTAssertEqual(provider.executedCommands.count, 2)
    }

    func testRemoteFileReadDoesNotRetryAfterDeclinedCredential() async {
        provider.simulatedExecutions = [CommandExecutionResult(
            output: "", exitCode: nil, timedOut: false, blockID: nil, declinedCredential: true
        )]
        let result = await service.toolHandler.readRemoteFileChunk(
            provider: provider, sessionID: provider.sessionID, path: "/protected", startLine: 1, lineCount: 5
        )
        let output = AIToolDefinitions.jsonString(from: result)
        XCTAssertTrue(output.contains(#""ok":false"#), output)
        XCTAssertTrue(output.contains("declined"), output)
        XCTAssertEqual(provider.executedCommands.count, 1)
    }

    func testRemoteTextSearchUsesLiteralCaseInsensitivePatterns() {
        let command = AIToolHandler.buildRemoteFileContentSearchCommand(path: ".", textPattern: "[literal].*", maxResults: 5)
        XCTAssertTrue(command.contains("rg --fixed-strings"))
        XCTAssertTrue(command.contains("--ignore-case"))
        XCTAssertTrue(command.contains("grep -RIniF"))
    }

    func testMalformedTargetsDoNotFallBackToTheDefaultSession() async {
        for target in ["123", "true", "[]", "\"\""] {
            let output = await run("execute_command", "{\"command\":\"true\",\"target_session\":\(target)}")
            XCTAssertTrue(output.contains(#""ok":false"#), output)
        }
        XCTAssertTrue(provider.shellInputs.isEmpty)
    }

    func testFileToolsAtADevicePromptAreRefusedBeforeSendingShellSyntax() async {
        provider.sessions[0] = Session(
            id: provider.sessionID, kind: .ssh(hostID: UUID()), hostLabel: "router", username: "admin",
            hostname: "10.0.0.1", port: 22, state: .connected
        )
        provider.shellBuffers[provider.sessionID] = ["router#"]
        for name in ["search_filesystem", "search_file_contents", "read_files", "apply_patch"] {
            let output = await run(name, minimalArguments[name]!)
            XCTAssertTrue(output.contains(#""ok":false"#), output)
            XCTAssertTrue(output.contains("run_cli_command"), output)
        }
        XCTAssertTrue(provider.executedCommands.isEmpty)
    }

    func testMalformedInteractiveInputIsRejectedAsAWhole() async {
        for arguments in [#"{"keys":["enter",123]}"#, #"{"keys":[]}"#, #"{"keys":[""]}"#] {
            let output = await run("send_input", arguments)
            XCTAssertTrue(output.contains(#""ok":false"#), output)
        }
        XCTAssertTrue(provider.rawInputs.isEmpty)
    }

    func testDeviceCommandRejectsMultipleLinesBeforeExecution() async {
        for command in ["show version\nreload", "show version\rreload"] {
            let arguments = AIToolDefinitions.jsonString(from: .object(["command": .string(command)]))
            let output = await run("run_cli_command", arguments)
            XCTAssertTrue(output.contains(#""ok":false"#), output)
        }
        XCTAssertTrue(provider.cliCommands.isEmpty)
    }

    func testCommandReadLimitMatchesSchemaAndAvoidsIntegerOverflow() {
        XCTAssertNil(AIToolHandler.readBoundViolationMessage(for: "head -n 500 notes.txt"))
        XCTAssertNotNil(AIToolHandler.readBoundViolationMessage(for: "head -n 501 notes.txt"))
        XCTAssertNotNil(AIToolHandler.readBoundViolationMessage(for: "sed -n '0,\(Int.max)p' notes.txt"))
    }

    func testCancellationDuringFirstToolPreventsTheNextToolAndPreservesCallIDs() async throws {
        var gate: CheckedContinuation<Void, Never>?
        provider.executionGate = { await withCheckedContinuation { gate = $0 } }
        let task = Task { await service.toolHandler.executeToolCalls(
            sessionID: provider.sessionID, broadcastContext: nil,
            toolCalls: [
                LLMToolCall(id: "first", name: "execute_and_wait", arguments: #"{"command":"true"}"#),
                LLMToolCall(id: "second", name: "execute_command", arguments: #"{"command":"must-not-run"}"#),
            ], traceID: "cancel-contract"
        ) }
        for _ in 0..<200 where gate == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        let resume = try XCTUnwrap(gate)
        task.cancel()
        resume.resume()
        let outputs = await task.value
        XCTAssertEqual(outputs.map(\.callID), ["first", "second"])
        XCTAssertTrue(outputs[0].output.contains(#""ok":true"#))
        XCTAssertTrue(outputs[1].output.contains("cancelled"))
        XCTAssertTrue(provider.shellInputs.isEmpty)
    }

    func testCancellationDuringFirstBroadcastTargetPreventsOtherSideEffects() async throws {
        for name in ["execute_command", "execute_and_wait", "send_input", "run_cli_command"] {
            provider.shellInputs = []; provider.rawInputs = []; provider.executedCommands = []; provider.cliCommands = []
            var gate: CheckedContinuation<Void, Never>?
            let pause: () async -> Void = { await withCheckedContinuation { gate = $0 } }
            provider.shellInputGate = pause; provider.executionGate = pause
            provider.rawInputGate = pause; provider.cliGate = pause
            let other = UUID()
            let context = BroadcastContext(primarySessionID: provider.sessionID, allSessionIDs: [provider.sessionID, other], sessionLabels: [:])
            let arguments = name == "send_input" ? #"{"keys":["enter"]}"# : #"{"command":"true"}"#
            let task = Task { await service.toolHandler.executeToolCalls(
                sessionID: provider.sessionID, broadcastContext: context,
                toolCalls: [LLMToolCall(id: name, name: name, arguments: arguments)], traceID: "cancel-broadcast"
            ) }
            for _ in 0..<200 where gate == nil { try await Task.sleep(nanoseconds: 5_000_000) }
            let resume = try XCTUnwrap(gate, name)
            task.cancel(); resume.resume()
            let outputs = await task.value
            XCTAssertTrue(outputs[0].output.contains("cancelled"), name)
            XCTAssertEqual(provider.shellInputs.count + provider.rawInputs.count + provider.executedCommands.count + provider.cliCommands.count, 1, name)
        }
    }

    func testCancellationDuringPatchApprovalCannotWriteOrRememberApproval() async throws {
        var gate: CheckedContinuation<(Bool, Bool), Never>?
        var fingerprint: String?
        service.patchApprovalCallback = { _, value in
            fingerprint = value
            return await withCheckedContinuation { gate = $0 }
        }
        let task = Task { await run("apply_patch", #"{"operation":"create","path":"cancelled.txt","diff":"+must-not-write"}"#) }
        for _ in 0..<200 where gate == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        let resume = try XCTUnwrap(gate)
        task.cancel(); resume.resume(returning: (true, true))
        let output = await task.value
        XCTAssertTrue(output.contains("cancelled"), output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("cancelled.txt").path))
        XCTAssertFalse(service.patchApprovalTracker.isApproved(try XCTUnwrap(fingerprint)))
    }

    func testCancellationAfterRemoteReadPreventsWriteAndSudoRetry() async throws {
        for first in [
            CommandExecutionResult(output: Data("old".utf8).base64EncodedString(), exitCode: 0, timedOut: false, blockID: nil),
            CommandExecutionResult(output: "Permission denied", exitCode: 1, timedOut: false, blockID: nil),
        ] {
            provider.executedCommands = []
            provider.simulatedExecutions = [first]
            var gate: CheckedContinuation<Void, Never>?
            provider.executionGate = { await withCheckedContinuation { gate = $0 } }
            let task = Task { await service.toolHandler.applyRemotePatch(
                PatchOperation(type: .update, path: "remote.txt", diff: "@@\n-old\n+new"),
                sessionID: provider.sessionID, provider: provider
            ) }
            for _ in 0..<200 where gate == nil { try await Task.sleep(nanoseconds: 5_000_000) }
            let resume = try XCTUnwrap(gate)
            task.cancel(); resume.resume()
            let outcome = await task.value
            XCTAssertFalse(outcome.result.success)
            XCTAssertEqual(provider.executedCommands.count, 1)
        }
    }

    /// Every object in a tool result whose `ok` is false, at any depth.
    private static func failures(in value: Any) -> [[String: Any]] {
        switch value {
        case let object as [String: Any]:
            let own = (object["ok"] as? Bool) == false ? [object] : []
            return own + object.values.flatMap { failures(in: $0) }
        case let array as [Any]:
            return array.flatMap { failures(in: $0) }
        default:
            return []
        }
    }
}

@MainActor
private final class ContractSessionProvider: AIAgentSessionProviding {
    let sessionID = UUID()
    var sessions: [Session]
    var shellBuffers: [UUID: [String]]
    var workingDirectoryBySessionID: [UUID: String]
    var bytesReceivedBySessionID: [UUID: Int64] = [:]
    var bytesSentBySessionID: [UUID: Int64] = [:]
    var commandBlocks: [CommandBlock]
    var simulatedCLIResult = CLICommandResult(output: "Version 1.0", status: .completed, finalPrompt: "router#")
    var simulatedExecutions: [CommandExecutionResult] = []
    var executedCommands: [String] = []
    var rawInputs: [String] = []
    var shellInputs: [String] = []
    var cliCommands: [String] = []
    var shellInputGate: (() async -> Void)?
    var rawInputGate: (() async -> Void)?
    var executionGate: (() async -> Void)?
    var cliGate: (() async -> Void)?

    init(workingDirectory: String) {
        sessions = [Session(
            id: sessionID, kind: .local, hostLabel: "Local: zsh", username: "kevin",
            hostname: "localhost", port: 0, state: .connected
        )]
        shellBuffers = [sessionID: ["kevin@mac ~ % "]]
        workingDirectoryBySessionID = [sessionID: workingDirectory]
        commandBlocks = [CommandBlock(
            id: UUID(), sessionID: sessionID, command: "ls", output: "notes.txt",
            startedAt: .now.addingTimeInterval(-5), completedAt: .now.addingTimeInterval(-4),
            exitCode: 0, boundarySource: .userInput
        )]
    }

    func recentCommandBlocks(sessionID: UUID, limit: Int) async -> [CommandBlock] {
        Array(commandBlocks.prefix(limit))
    }

    func searchCommandHistory(sessionID: UUID, query: String, limit: Int) async -> [CommandBlock] {
        Array(commandBlocks.filter { $0.command.contains(query) }.prefix(limit))
    }

    func commandOutput(sessionID: UUID, blockID: UUID) async -> String? {
        commandBlocks.first { $0.id == blockID }?.output
    }

    func sendShellInput(sessionID: UUID, input: String, suppressEcho: Bool) async {
        shellInputs.append(input)
        await shellInputGate?()
    }

    func sendRawShellInput(sessionID: UUID, input: String) async {
        rawInputs.append(input)
        await rawInputGate?()
    }

    func executeCommandAndWait(sessionID: UUID, command: String, timeoutSeconds: TimeInterval) async -> CommandExecutionResult {
        executedCommands.append(command)
        await executionGate?()
        if !simulatedExecutions.isEmpty { return simulatedExecutions.removeFirst() }
        return CommandExecutionResult(output: "", exitCode: 0, timedOut: false, blockID: nil)
    }

    func executeCLICommand(sessionID: UUID, command: String, timeoutSeconds: TimeInterval) async -> CLICommandResult {
        cliCommands.append(command)
        await cliGate?()
        return simulatedCLIResult
    }
}

@MainActor
private final class ContractOpenRouterService: OpenRouterServicing {
    func fetchModels() async throws -> [OpenRouterModel] { [] }
    func complete(model: String, messages: [OpenRouterMessage], tools: [LLMToolDefinition], onEvent: @escaping @Sendable (LLMStreamEvent) -> Void) async throws -> OpenRouterCompletion {
        throw OpenRouterError.invalidResponse
    }
}
#endif
