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
        service = AIAgentService(
            openRouterClient: client,
            sessionProvider: provider,
            modelStore: OpenRouterModelStore(client: client, defaults: defaults)
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

    func sendShellInput(sessionID: UUID, input: String, suppressEcho: Bool) async {}

    func sendRawShellInput(sessionID: UUID, input: String) async {}

    func executeCommandAndWait(sessionID: UUID, command: String, timeoutSeconds: TimeInterval) async -> CommandExecutionResult {
        CommandExecutionResult(output: "", exitCode: 0, timedOut: false, blockID: nil)
    }

    func executeCLICommand(sessionID: UUID, command: String, timeoutSeconds: TimeInterval) async -> CLICommandResult {
        simulatedCLIResult
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
