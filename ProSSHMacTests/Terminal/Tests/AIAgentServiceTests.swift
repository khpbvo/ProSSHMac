#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

@MainActor
final class AIAgentServiceTests: XCTestCase {
    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "AIAgentServicePolicyTests.\(UUID().uuidString)")!
    }

    private func store(client: MockOpenRouterService) async throws -> OpenRouterModelStore {
        let suite = "OpenRouterAgentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = OpenRouterModelStore(client: client, defaults: defaults)
        await store.refresh()
        try store.select("test/one")
        return store
    }

    private func completion(_ text: String, id: String = UUID().uuidString) -> OpenRouterCompletion {
        .init(id: id, model: "test/one", choices: [.init(message: .init(role: "assistant", content: text), finishReason: "stop")], usage: nil)
    }

    private func toolCompletion(_ name: String, arguments: String, id: String = "call_1") -> OpenRouterCompletion {
        let call = OpenRouterToolCall(id: id, function: .init(name: name, arguments: arguments))
        return .init(id: UUID().uuidString, model: "test/one", choices: [.init(message: .init(role: "assistant", content: nil, toolCalls: [call]), finishReason: "tool_calls")], usage: nil)
    }

    func testToolLoopKeepsCallAndResultInTranscript() async throws {
        let client = MockOpenRouterService()
        let session = MockAgentSessionProvider()
        client.enqueue(toolCompletion("get_session_info", arguments: "{}"))
        client.enqueue(completion("Session healthy"))
        let service = AIAgentService(openRouterClient: client, sessionProvider: session, modelStore: try await store(client: client), defaults: isolatedDefaults())
        let reply = try await service.generateReply(sessionID: session.sessionID, prompt: "status")
        XCTAssertEqual(reply.text, "Session healthy")
        XCTAssertEqual(reply.toolCallsExecuted, 1)
        XCTAssertEqual(client.requests.count, 2)
        let replay = client.requests[1].messages
        XCTAssertEqual(replay.first { $0.role == "assistant" }?.toolCalls?.first?.id, "call_1")
        XCTAssertEqual(replay.first { $0.role == "tool" }?.toolCallID, "call_1")
        XCTAssertTrue(replay.first { $0.role == "tool" }?.content?.contains("\"ok\":true") == true)
    }

    func testClearDuringAwaitedToolCannotRestoreTheOldConversation() async throws {
        let client = MockOpenRouterService()
        let session = MockAgentSessionProvider()
        client.enqueue(toolCompletion("execute_and_wait", arguments: #"{"command":"uptime"}"#))
        let service = AIAgentService(
            openRouterClient: client, sessionProvider: session,
            modelStore: try await store(client: client), maxToolIterations: 1, defaults: isolatedDefaults()
        )
        let conversationID = UUID()
        var resumeCommand: CheckedContinuation<Void, Never>?
        session.executeAndWaitGate = {
            await withCheckedContinuation { resumeCommand = $0 }
        }
        let run = Task {
            try await service.generateReply(
                conversationID: conversationID, sessionID: session.sessionID,
                prompt: "check uptime", broadcastSessionIDs: nil, streamHandler: nil
            )
        }
        for _ in 0..<200 where resumeCommand == nil {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let continuation = try XCTUnwrap(resumeCommand)
        XCTAssertNotNil(service.conversationContext.state(for: conversationID))
        service.clearConversation(conversationID: conversationID)
        continuation.resume()
        do {
            _ = try await run.value
            XCTFail("A cleared run must end without another request")
        } catch is CancellationError {
            // The run was invalidated without relying on cancellation of its Task.
        }
        XCTAssertNil(service.conversationContext.state(for: conversationID))
        XCTAssertEqual(client.requests.count, 1)
    }

    /// Skills load once per chat (Docs/NetworkCopilot.md Phase 5): a new file changes nothing
    /// mid-chat, so the system prompt and the cache prefix stay put; the next chat picks it up.
    func testSkillIndexIsFixedPerChatAndReloadedByANewChat() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("skills-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func addSkill(_ name: String) throws {
            try "---\nname: \(name)\ndescription: The \(name) skill\n---\nSteps.\n"
                .write(to: folder.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8)
        }
        try addSkill("first")

        let client = MockOpenRouterService()
        let session = MockAgentSessionProvider()
        client.enqueue(completion("one"))
        client.enqueue(completion("two"))
        client.enqueue(completion("three"))
        let service = AIAgentService(
            openRouterClient: client, sessionProvider: session, modelStore: try await store(client: client),
            skillLibrary: AISkillLibrary(bundledDirectory: nil, userDirectory: folder), defaults: isolatedDefaults()
        )
        func systemPrompt(_ request: Int) -> String {
            client.requests[request].messages.first { $0.role == "system" }?.content ?? ""
        }

        _ = try await service.generateReply(sessionID: session.sessionID, prompt: "hello")
        try addSkill("second")
        _ = try await service.generateReply(sessionID: session.sessionID, prompt: "again")
        XCTAssertTrue(systemPrompt(0).contains("- first — The first skill"))
        XCTAssertEqual(systemPrompt(1), systemPrompt(0))

        service.clearConversation(sessionID: session.sessionID)
        _ = try await service.generateReply(sessionID: session.sessionID, prompt: "new chat")
        XCTAssertTrue(systemPrompt(2).contains("- second — The second skill"))
    }

    func testModelSwitchContinuesHistoryWithoutReasoning() async throws {
        let client = MockOpenRouterService()
        let session = MockAgentSessionProvider()
        let modelStore = try await store(client: client)
        var first = completion("The code is blue")
        first = .init(id: first.id, model: "test/one", choices: [.init(message: .init(role: "assistant", content: "The code is blue", reasoningDetails: [.object(["type": .string("reasoning.text"), "text": .string("private")])]), finishReason: "stop")], usage: nil)
        client.enqueue(first)
        client.enqueue(completion("blue"))
        let service = AIAgentService(openRouterClient: client, sessionProvider: session, modelStore: modelStore, defaults: isolatedDefaults())
        _ = try await service.generateReply(sessionID: session.sessionID, prompt: "Remember the code")
        try modelStore.select("test/two")
        _ = try await service.generateReply(sessionID: session.sessionID, prompt: "What is the code?")
        let second = client.requests[1]
        XCTAssertEqual(second.model, "test/two")
        XCTAssertTrue(second.messages.contains { $0.content == "The code is blue" })
        XCTAssertNil(second.messages.first { $0.content == "The code is blue" }?.reasoningDetails)
    }

    func testModelSwitchKeepsCompletedToolCycle() async throws {
        let client = MockOpenRouterService()
        let session = MockAgentSessionProvider()
        let modelStore = try await store(client: client)
        client.enqueue(toolCompletion("get_session_info", arguments: "{}"))
        client.enqueue(completion("Local shell"))
        client.enqueue(completion("It is a local shell"))
        let service = AIAgentService(openRouterClient: client, sessionProvider: session, modelStore: modelStore, defaults: isolatedDefaults())
        _ = try await service.generateReply(sessionID: session.sessionID, prompt: "Inspect this session")
        try modelStore.select("test/two")
        _ = try await service.generateReply(sessionID: session.sessionID, prompt: "What did you inspect?")
        let replay = client.requests[2].messages
        XCTAssertEqual(replay.first { $0.role == "assistant" && $0.toolCalls != nil }?.toolCalls?.first?.id, "call_1")
        XCTAssertEqual(replay.first { $0.role == "tool" }?.toolCallID, "call_1")
        XCTAssertTrue(replay.contains { $0.content == "Local shell" })
    }

    func testPatchDenialDoesNotWrite() async throws {
        let client = MockOpenRouterService()
        let session = MockAgentSessionProvider()
        client.enqueue(toolCompletion("apply_patch", arguments: #"{"operation":"create","path":"/tmp/denied.txt","content":"blocked"}"#))
        client.enqueue(completion("Denied"))
        let service = AIAgentService(openRouterClient: client, sessionProvider: session, modelStore: try await store(client: client), defaults: isolatedDefaults())
        service.patchApprovalCallback = { _, _ in (false, false) }
        _ = try await service.generateReply(sessionID: session.sessionID, prompt: "create a file")
        XCTAssertTrue(client.requests[1].messages.first { $0.role == "tool" }?.content?.contains("Patch denied by user") == true)
        XCTAssertFalse(session.sentCommands.contains { $0.contains("denied.txt") })
    }

    func testSessionHistoryIsIsolatedAndClearable() async throws {
        let client = MockOpenRouterService()
        let session = MockAgentSessionProvider()
        let secondID = UUID()
        session.sessions.append(Session(id: secondID, kind: .local, hostLabel: "Second", username: "u", hostname: "localhost", port: 0, state: .connected))
        let service = AIAgentService(openRouterClient: client, sessionProvider: session, modelStore: try await store(client: client), defaults: isolatedDefaults())
        client.enqueue(completion("first answer"))
        client.enqueue(completion("second answer"))
        client.enqueue(completion("new answer"))
        _ = try await service.generateReply(sessionID: session.sessionID, prompt: "first")
        _ = try await service.generateReply(sessionID: secondID, prompt: "second")
        XCTAssertFalse(client.requests[1].messages.contains { $0.content == "first answer" })
        service.clearConversation(sessionID: session.sessionID)
        _ = try await service.generateReply(sessionID: session.sessionID, prompt: "new")
        XCTAssertFalse(client.requests[2].messages.contains { $0.content == "first answer" })
    }

    func testOneConversationFollowsTheChatAcrossFocusedSessions() async throws {
        let client = MockOpenRouterService()
        let session = MockAgentSessionProvider()
        let secondID = UUID()
        session.sessions.append(Session(id: secondID, kind: .ssh(hostID: UUID()), hostLabel: "Testserv2", username: "kevin", hostname: "192.168.2.33", port: 22, state: .connected))
        let service = AIAgentService(openRouterClient: client, sessionProvider: session, modelStore: try await store(client: client), defaults: isolatedDefaults())
        let chat = UUID()
        client.enqueue(completion("Noted: dedupe the clones"))
        client.enqueue(completion("You asked me to dedupe the clones"))

        _ = try await service.generateReply(conversationID: chat, sessionID: session.sessionID, prompt: "dedupe the clones", broadcastSessionIDs: nil, streamHandler: nil)
        _ = try await service.generateReply(conversationID: chat, sessionID: secondID, prompt: "what did I ask?", broadcastSessionIDs: nil, streamHandler: nil)

        let second = client.requests[1].messages
        XCTAssertTrue(second.contains { $0.role == "assistant" && $0.content == "Noted: dedupe the clones" }, "memory follows the chat")
        let users = second.filter { $0.role == "user" }.compactMap(\.content)
        XCTAssertEqual(users.count, 2)
        XCTAssertTrue(users[0].hasPrefix("[Focused session: Local shell — "))
        XCTAssertTrue(users[1].hasPrefix("[Focused session: Testserv2 — kevin@192.168.2.33:22]"))

        service.clearConversation(conversationID: chat)
        client.enqueue(completion("fresh"))
        _ = try await service.generateReply(conversationID: chat, sessionID: secondID, prompt: "again", broadcastSessionIDs: nil, streamHandler: nil)
        XCTAssertFalse(client.requests[2].messages.contains { $0.content == "Noted: dedupe the clones" })
    }

    // MARK: - Reaching every open session

    private struct Fleet {
        let service: AIAgentService
        let client: MockOpenRouterService
        let session: MockAgentSessionProvider
        let second: UUID
        let third: UUID
        let closed: UUID
    }

    private func fleet() async throws -> Fleet {
        let client = MockOpenRouterService()
        let session = MockAgentSessionProvider()
        let second = UUID(), third = UUID(), closed = UUID()
        session.sessions += [
            Session(id: second, kind: .ssh(hostID: UUID()), hostLabel: "Testserv2", username: "kevin", hostname: "192.168.2.33", port: 22, state: .connected),
            Session(id: third, kind: .ssh(hostID: UUID()), hostLabel: "Testserv3", username: "kevin", hostname: "192.168.2.19", port: 22, state: .connected),
            Session(id: closed, kind: .ssh(hostID: UUID()), hostLabel: "Testserv9", username: "kevin", hostname: "192.168.2.99", port: 22, state: .disconnected),
        ]
        let service = AIAgentService(openRouterClient: client, sessionProvider: session, modelStore: try await store(client: client), defaults: isolatedDefaults())
        return Fleet(service: service, client: client, session: session, second: second, third: third, closed: closed)
    }

    private func runCommand(_ fleet: Fleet, target: String, broadcast: [UUID]? = nil) async throws -> String {
        fleet.client.enqueue(toolCompletion("execute_and_wait", arguments: #"{"command":"hostname","timeout_seconds":10,"target_session":\#(target)}"#))
        fleet.client.enqueue(completion("done"))
        _ = try await fleet.service.generateReply(sessionID: fleet.session.sessionID, prompt: "check", broadcastSessionIDs: broadcast)
        let request = try XCTUnwrap(fleet.client.requests.last)
        return try XCTUnwrap(request.messages.last { $0.role == "tool" }?.content)
    }

    func testEveryTurnListsTheOpenSessions() async throws {
        let fleet = try await fleet()
        fleet.client.enqueue(completion("ok"))
        _ = try await fleet.service.generateReply(sessionID: fleet.session.sessionID, prompt: "hi", broadcastSessionIDs: [fleet.session.sessionID, fleet.second])
        let user = try XCTUnwrap(fleet.client.requests.last?.messages.first { $0.role == "user" }?.content)
        XCTAssertTrue(user.contains("[Open sessions — pass an id as target_session; null targets the 2 broadcast sessions]"))
        XCTAssertTrue(user.contains("- \(fleet.session.sessionID.uuidString): Local: zsh — local shell · focused · broadcast"))
        XCTAssertTrue(user.contains("- \(fleet.second.uuidString): Testserv2 — kevin@192.168.2.33:22 · broadcast"))
        XCTAssertTrue(user.contains("- \(fleet.third.uuidString): Testserv3 — kevin@192.168.2.19:22\n"))
        XCTAssertFalse(user.contains(fleet.closed.uuidString), "disconnected sessions are not offered")
    }

    func testUntargetedCommandsGoToTheFocusedSessionOrTheBroadcastSet() async throws {
        let single = try await fleet()
        _ = try await runCommand(single, target: "null")
        XCTAssertEqual(single.session.commandSessions, [single.session.sessionID])

        let broadcasting = try await fleet()
        _ = try await runCommand(broadcasting, target: "null", broadcast: [broadcasting.session.sessionID, broadcasting.second])
        XCTAssertEqual(Set(broadcasting.session.commandSessions), [broadcasting.session.sessionID, broadcasting.second])
    }

    func testAnyOpenSessionCanBeTargetedWithOrWithoutBroadcast() async throws {
        let single = try await fleet()
        _ = try await runCommand(single, target: #""\#(single.third.uuidString)""#)
        XCTAssertEqual(single.session.commandSessions, [single.third])

        let broadcasting = try await fleet()
        _ = try await runCommand(broadcasting, target: #""\#(broadcasting.third.uuidString)""#, broadcast: [broadcasting.session.sessionID, broadcasting.second])
        XCTAssertEqual(broadcasting.session.commandSessions, [broadcasting.third], "outside the broadcast set")
    }

    func testUnknownOrClosedSessionsAreRefusedBeforeRunning() async throws {
        let fleet = try await fleet()
        let closed = try await runCommand(fleet, target: #""\#(fleet.closed.uuidString)""#)
        XCTAssertTrue(closed.contains(#""ok":false"#))
        XCTAssertTrue(closed.contains("list_sessions"))
        let unknown = try await runCommand(fleet, target: #""not-a-session""#)
        XCTAssertTrue(unknown.contains("Unknown or disconnected session not-a-session"))
        XCTAssertTrue(fleet.session.commandSessions.isEmpty)
    }

    func testListSessionsReturnsOpenSessionsAndDefaults() async throws {
        let fleet = try await fleet()
        fleet.client.enqueue(toolCompletion("list_sessions", arguments: "{}"))
        fleet.client.enqueue(completion("done"))
        _ = try await fleet.service.generateReply(sessionID: fleet.session.sessionID, prompt: "who is open?")
        let output = try XCTUnwrap(fleet.client.requests.last?.messages.last { $0.role == "tool" }?.content)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let sessions = try XCTUnwrap(json["sessions"] as? [[String: Any]])
        XCTAssertEqual(sessions.compactMap { $0["label"] as? String }, ["Local: zsh", "Testserv2", "Testserv3"])
        XCTAssertEqual(sessions.first?["focused"] as? Bool, true)
        XCTAssertEqual(json["default_targets"] as? [String], [fleet.session.sessionID.uuidString])
    }

    // MARK: - Device CLIs

    func testRunCLICommandRunsOnTheTargetedSession() async throws {
        let fleet = try await fleet()
        fleet.session.simulatedCLIResult = CLICommandResult(output: "Neighbor ID  State", status: .completed, finalPrompt: "testserv-02#", pagesAdvanced: 2)
        fleet.client.enqueue(toolCompletion("run_cli_command", arguments: #"{"command":"show ip ospf neighbor","timeout_seconds":20,"target_session":"\#(fleet.second.uuidString)"}"#))
        fleet.client.enqueue(completion("done"))
        _ = try await fleet.service.generateReply(sessionID: fleet.session.sessionID, prompt: "ospf?")
        XCTAssertEqual(fleet.session.cliCommands.map(\.0), [fleet.second])
        XCTAssertEqual(fleet.session.cliCommands.map(\.1), ["show ip ospf neighbor"])
        let output = try XCTUnwrap(fleet.client.requests.last?.messages.last { $0.role == "tool" }?.content)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(json["output"] as? String, "Neighbor ID  State")
        XCTAssertEqual(json["completed"] as? Bool, true)
        XCTAssertEqual(json["final_prompt"] as? String, "testserv-02#")
        XCTAssertEqual(json["pages_advanced"] as? Int, 2)
        XCTAssertTrue(fleet.client.requests[0].tools.contains { $0.name == "run_cli_command" })
    }

    func testRunCLICommandReportsAQuestion() async throws {
        let fleet = try await fleet()
        fleet.session.simulatedCLIResult = CLICommandResult(output: "", status: .awaitingInput("Destination filename [startup-config]?"))
        fleet.client.enqueue(toolCompletion("run_cli_command", arguments: #"{"command":"copy run start","timeout_seconds":20,"target_session":null}"#))
        fleet.client.enqueue(completion("done"))
        _ = try await fleet.service.generateReply(sessionID: fleet.session.sessionID, prompt: "save")
        let output = try XCTUnwrap(fleet.client.requests.last?.messages.last { $0.role == "tool" }?.content)
        XCTAssertTrue(output.contains(#""completed":false"#))
        XCTAssertTrue(output.contains("Destination filename [startup-config]?"))
        XCTAssertTrue(output.contains("send_input"))
    }

    func testExecuteAndWaitIsRefusedAtADevicePrompt() async throws {
        let fleet = try await fleet()
        fleet.session.shellBuffers[fleet.second] = ["10.255.255.3  1 Full/Backup", "testserv-02# "]
        let output = try await runCommand(fleet, target: #""\#(fleet.second.uuidString)""#)
        XCTAssertTrue(output.contains(#""ok":false"#))
        XCTAssertTrue(output.contains("Testserv2 (testserv-02#)"))
        XCTAssertTrue(output.contains("run_cli_command"))
        XCTAssertTrue(fleet.session.commandSessions.isEmpty, "nothing may be sent")

        fleet.session.shellBuffers[fleet.third] = ["kevin@testserv-02:~$"]
        _ = try await runCommand(fleet, target: #""\#(fleet.third.uuidString)""#)
        XCTAssertEqual(fleet.session.commandSessions, [fleet.third], "a shell prompt still runs")
    }

    // MARK: - Password prompts (Docs/CredentialPrompt.md Phase 3)

    private func toolResult(_ fleet: Fleet) throws -> [String: Any] {
        let output = try XCTUnwrap(fleet.client.requests.last?.messages.last { $0.role == "tool" }?.content)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    }

    private func applyPatch(_ fleet: Fleet, _ arguments: String) async throws -> [String: Any] {
        fleet.service.patchApprovalCallback = { _, _ in (true, false) }
        fleet.client.enqueue(toolCompletion("apply_patch", arguments: arguments))
        fleet.client.enqueue(completion("done"))
        _ = try await fleet.service.generateReply(sessionID: fleet.session.sessionID, prompt: "patch it")
        return try toolResult(fleet)
    }

    private func denied(_ path: String) -> CommandExecutionResult {
        CommandExecutionResult(output: "base64: \(path): Permission denied", exitCode: 1, timedOut: false, blockID: nil)
    }

    func testApplyPatchRetriesAProtectedFileWithSudoThatMayAskTheUser() async throws {
        let fleet = try await fleet()
        fleet.session.simulatedExecuteAndWaitResultsQueue = [
            denied("/etc/motd"),
            CommandExecutionResult(
                output: Data("old\n".utf8).base64EncodedString(), exitCode: 0, timedOut: false, blockID: nil,
                waitedForCredential: true
            ),
            CommandExecutionResult(output: "", exitCode: 0, timedOut: false, blockID: nil),
        ]
        let json = try await applyPatch(fleet, #"{"operation":"update","path":"/etc/motd","diff":"@@\n-old\n+new\n","target_session":"\#(fleet.second.uuidString)"}"#)

        XCTAssertEqual(json["ok"] as? Bool, true, "\(json)")
        XCTAssertEqual(json["note"] as? String, AIToolHandler.credentialWaitNote)
        XCTAssertNil(json["status"], "no sudo_password_required dance")
        let commands = fleet.session.sentCommands
        XCTAssertEqual(commands.count, 3)
        XCTAssertEqual(commands[0], "base64 '/etc/motd'")
        XCTAssertEqual(commands[1], "sudo base64 '/etc/motd'")
        XCTAssertTrue(commands[2].contains("sudo tee '/etc/motd'"), "a file read with sudo is written with sudo")
        XCTAssertFalse(commands.contains { $0.contains("sudo -n") || $0.contains("sudo -v") })
    }

    func testDeclinedSudoStopsThePatchBeforeAnyWrite() async throws {
        let fleet = try await fleet()
        fleet.session.simulatedExecuteAndWaitResultsQueue = [
            denied("/etc/motd"),
            CommandExecutionResult(
                output: "[sudo] password for kevin:", exitCode: nil, timedOut: false, blockID: nil,
                waitedForCredential: true, declinedCredential: true
            ),
        ]
        let json = try await applyPatch(fleet, #"{"operation":"update","path":"/etc/motd","diff":"@@\n-old\n+new\n","target_session":"\#(fleet.second.uuidString)"}"#)

        XCTAssertEqual(json["ok"] as? Bool, false)
        XCTAssertEqual(json["error"] as? String, "The user declined the password prompt on Testserv2.")
        XCTAssertEqual(json["hint"] as? String, AIToolHandler.credentialDeclinedHint)
        XCTAssertEqual(fleet.session.sentCommands.count, 2, "nothing is written")
    }

    func testRemoteCreateWithoutADiffIsRefusedBeforeAnythingRuns() async throws {
        let fleet = try await fleet()
        var asked = false
        fleet.client.enqueue(toolCompletion("apply_patch", arguments: #"{"operation":"create","path":"/etc/motd","content":"hello","target_session":"\#(fleet.second.uuidString)"}"#))
        fleet.client.enqueue(completion("done"))
        fleet.service.patchApprovalCallback = { _, _ in asked = true; return (true, false) }
        _ = try await fleet.service.generateReply(sessionID: fleet.session.sessionID, prompt: "create")
        let json = try toolResult(fleet)

        XCTAssertEqual(json["ok"] as? Bool, false)
        XCTAssertTrue((json["error"] as? String)?.contains("diff is required") == true)
        XCTAssertFalse(asked, "no approval card for a patch that cannot run")
        XCTAssertTrue(fleet.session.sentCommands.isEmpty, "a missing diff once fell through to rm")
    }

    func testExecuteAndWaitTellsTheModelAboutAPasswordWait() async throws {
        let fleet = try await fleet()
        fleet.session.simulatedExecuteAndWaitResultsQueue = [
            CommandExecutionResult(output: "root", exitCode: 0, timedOut: false, blockID: nil, waitedForCredential: true),
        ]
        _ = try await runCommand(fleet, target: #""\#(fleet.second.uuidString)""#)
        let json = try toolResult(fleet)
        XCTAssertEqual(json["ok"] as? Bool, true)
        XCTAssertEqual(json["output"] as? String, "root")
        XCTAssertEqual(json["note"] as? String, AIToolHandler.credentialWaitNote)
    }

    func testExecuteAndWaitReportsADeclineWithTheHost() async throws {
        let fleet = try await fleet()
        fleet.session.simulatedExecuteAndWaitResultsQueue = [
            CommandExecutionResult(output: "", exitCode: nil, timedOut: false, blockID: nil, waitedForCredential: true, declinedCredential: true),
        ]
        _ = try await runCommand(fleet, target: #""\#(fleet.second.uuidString)""#)
        let json = try toolResult(fleet)
        XCTAssertEqual(json["ok"] as? Bool, false)
        XCTAssertEqual(json["error"] as? String, "The user declined the password prompt on Testserv2.")
        XCTAssertEqual(json["hint"] as? String, AIToolHandler.credentialDeclinedHint)
    }

    func testBroadcastDeclineSkipsOnlyThatHost() async throws {
        let fleet = try await fleet()
        fleet.session.simulatedExecuteAndWaitResultsQueue = [
            CommandExecutionResult(output: "", exitCode: nil, timedOut: false, blockID: nil, waitedForCredential: true, declinedCredential: true),
            CommandExecutionResult(output: "testserv-03", exitCode: 0, timedOut: false, blockID: nil),
        ]
        _ = try await runCommand(fleet, target: "null", broadcast: [fleet.second, fleet.third])
        let results = try XCTUnwrap(try toolResult(fleet)["results"] as? [[String: Any]])
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0]["error"] as? String, "The user declined the password prompt on Testserv2.")
        XCTAssertNil(results[1]["error"])
        XCTAssertEqual(results[1]["output"] as? String, "testserv-03")
    }

    func testRunCLICommandReportsAPasswordWaitAndADecline() async throws {
        let fleet = try await fleet()
        fleet.session.simulatedCLIResult = CLICommandResult(
            output: "Password:", status: .completed, finalPrompt: "testserv-02#", waitedForCredential: true
        )
        fleet.client.enqueue(toolCompletion("run_cli_command", arguments: #"{"command":"enable","target_session":"\#(fleet.second.uuidString)"}"#))
        fleet.client.enqueue(completion("done"))
        _ = try await fleet.service.generateReply(sessionID: fleet.session.sessionID, prompt: "enable")
        XCTAssertEqual(try toolResult(fleet)["note"] as? String, AIToolHandler.credentialWaitNote)

        fleet.session.simulatedCLIResult = CLICommandResult(output: "", status: .declined, waitedForCredential: true)
        fleet.client.enqueue(toolCompletion("run_cli_command", arguments: #"{"command":"enable","target_session":"\#(fleet.second.uuidString)"}"#))
        fleet.client.enqueue(completion("done"))
        _ = try await fleet.service.generateReply(sessionID: fleet.session.sessionID, prompt: "enable")
        let json = try toolResult(fleet)
        XCTAssertEqual(json["ok"] as? Bool, false)
        XCTAssertEqual(json["error"] as? String, "The user declined the password prompt on Testserv2.")
        XCTAssertNil(json["note"])
    }

    func testSessionListMarksDeviceCLIPrompts() async throws {
        let fleet = try await fleet()
        fleet.session.shellBuffers[fleet.second] = ["testserv-02(config)#"]
        fleet.client.enqueue(completion("ok"))
        _ = try await fleet.service.generateReply(sessionID: fleet.session.sessionID, prompt: "hi")
        let user = try XCTUnwrap(fleet.client.requests.last?.messages.first { $0.role == "user" }?.content)
        XCTAssertTrue(user.contains("- \(fleet.second.uuidString): Testserv2 — kevin@192.168.2.33:22 · device CLI \"testserv-02(config)#\""))
        XCTAssertTrue(user.contains("- \(fleet.third.uuidString): Testserv3 — kevin@192.168.2.19:22\n"))
    }

    // MARK: - Anthropic provider

    private struct AnthropicStack {
        let service: AIAgentService
        let openRouter: MockOpenRouterService
        let claude: MockAnthropicService
        let selection: AIProviderSelection
        let session: MockAgentSessionProvider
    }

    private func anthropicStack(selected: AIProvider = .anthropic) async throws -> AnthropicStack {
        let openRouter = MockOpenRouterService()
        let claude = MockAnthropicService()
        let session = MockAgentSessionProvider()
        let defaults = UserDefaults(suiteName: "AnthropicAgentTests.\(UUID().uuidString)")!
        let selection = AIProviderSelection(defaults: defaults)
        selection.select(selected)
        let service = AIAgentService(
            openRouterClient: openRouter,
            sessionProvider: session,
            modelStore: try await store(client: openRouter),
            anthropicClient: claude,
            anthropicModelStore: AnthropicModelStore(client: claude, defaults: defaults),
            providerSelection: selection, defaults: defaults
        )
        return AnthropicStack(service: service, openRouter: openRouter, claude: claude, selection: selection, session: session)
    }

    private func claudeText(_ text: String) -> AnthropicResponse {
        AnthropicResponse(id: "msg", model: "claude-opus-5-5", content: [.text(text)], text: text, reasoning: "", toolCalls: [], stopReason: "end_turn", usage: nil, inputTransformations: [])
    }

    func testClaudeRunsTheToolLoopWithCatalogMetadata() async throws {
        let stack = try await anthropicStack()
        let toolUse = AnthropicBlock(json: #"{"id":"toolu_1","input":{},"name":"get_session_info","type":"tool_use"}"#)
        stack.claude.enqueue(AnthropicResponse(id: "msg_1", model: "claude-opus-5-5", content: [toolUse], text: "", reasoning: "", toolCalls: [LLMToolCall(id: "toolu_1", name: "get_session_info", arguments: "{}")], stopReason: "tool_use", usage: nil, inputTransformations: []))
        stack.claude.enqueue(claudeText("Session healthy"))

        let reply = try await stack.service.generateReply(sessionID: stack.session.sessionID, prompt: "status")

        XCTAssertEqual(reply.text, "Session healthy")
        XCTAssertEqual(reply.toolCallsExecuted, 1)
        XCTAssertEqual(stack.claude.catalogFetches, 1, "the catalog loads before the first turn")
        XCTAssertTrue(stack.openRouter.requests.isEmpty)
        XCTAssertEqual(stack.claude.requests.count, 2)
        let first = stack.claude.requests[0]
        XCTAssertEqual(first.model, "claude-opus-5-5")
        XCTAssertTrue(first.serverFallback)
        XCTAssertEqual(first.effort, .medium)
        let second = stack.claude.requests[1]
        XCTAssertEqual(second.messages.map(\.role), ["user", "assistant", "user"])
        XCTAssertEqual(second.messages[1].content, [toolUse])
        let result = try XCTUnwrap(second.messages[2].content.first?.json)
        XCTAssertTrue(result.contains(#""tool_use_id":"toolu_1""#))
        XCTAssertTrue(result.contains(#"\"ok\":true"#))
    }

    func testSwitchingProvidersKeepsTheConversation() async throws {
        let stack = try await anthropicStack(selected: .openRouter)
        stack.openRouter.enqueue(completion("The code is blue"))
        _ = try await stack.service.generateReply(sessionID: stack.session.sessionID, prompt: "Remember the code")

        stack.selection.select(.anthropic)
        stack.claude.enqueue(claudeText("It is blue."))
        _ = try await stack.service.generateReply(sessionID: stack.session.sessionID, prompt: "What is the code?")
        let claudeRequest = try XCTUnwrap(stack.claude.requests.last)
        XCTAssertEqual(claudeRequest.messages.map(\.role), ["user", "assistant", "user"])
        XCTAssertEqual(claudeRequest.messages[1].content, [.text("The code is blue")])

        stack.selection.select(.openRouter)
        stack.openRouter.enqueue(completion("Still blue"))
        _ = try await stack.service.generateReply(sessionID: stack.session.sessionID, prompt: "And now?")
        let openRouterRequest = try XCTUnwrap(stack.openRouter.requests.last)
        XCTAssertTrue(openRouterRequest.messages.contains { $0.role == "assistant" && $0.content == "It is blue." })
    }

    func testClaudeRefusalSurfacesAndRunsNoTools() async throws {
        let stack = try await anthropicStack()
        stack.claude.failure = AnthropicError.refused(category: "cyber", explanation: nil)
        do {
            _ = try await stack.service.generateReply(sessionID: stack.session.sessionID, prompt: "do it")
            XCTFail("Expected a refusal")
        } catch {
            XCTAssertEqual(error as? AnthropicError, .refused(category: "cyber", explanation: nil))
        }
        XCTAssertTrue(stack.session.sentCommands.isEmpty)
    }

    func testDirectActionPromptKeepsAllToolsOnlyForClaude() async throws {
        let stack = try await anthropicStack()
        stack.claude.enqueue(claudeText("ok"))
        _ = try await stack.service.generateReply(sessionID: stack.session.sessionID, prompt: "run uptime")
        XCTAssertEqual(stack.claude.requests.last?.tools.count, stack.service.toolDefinitions.count)

        stack.selection.select(.openRouter)
        stack.openRouter.enqueue(completion("ok"))
        _ = try await stack.service.generateReply(sessionID: stack.session.sessionID, prompt: "run uptime")
        XCTAssertEqual(
            stack.openRouter.requests.last?.tools.count,
            AIToolDefinitions.directActionToolDefinitions(from: stack.service.toolDefinitions).count
        )
        XCTAssertLessThan(stack.openRouter.requests.last?.tools.count ?? 0, stack.service.toolDefinitions.count)
    }
}

@MainActor
private final class MockAgentSessionProvider: AIAgentSessionProviding {
    let sessionID = UUID()
    var sessions: [Session]
    var shellBuffers: [UUID: [String]]
    var workingDirectoryBySessionID: [UUID: String]
    var bytesReceivedBySessionID: [UUID: Int64]
    var bytesSentBySessionID: [UUID: Int64]
    var sentCommands: [String] = []
    var commandSessions: [UUID] = []
    var commandBlocks: [CommandBlock]
    var commandOutputByBlockID: [UUID: String]
    var simulatedExecuteAndWaitOutput: String = ""
    var simulatedExecuteAndWaitExitCode: Int? = 0
    var simulatedExecuteAndWaitTimedOut: Bool = false
    var simulatedExecuteAndWaitResultsQueue: [CommandExecutionResult] = []
    var executeAndWaitGate: (() async -> Void)?
    var cliCommands: [(UUID, String)] = []
    var simulatedCLIResult = CLICommandResult(output: "", status: .completed, finalPrompt: "router#")

    init(isLocal: Bool = true) {
        let session = Session(
            id: sessionID,
            kind: isLocal ? .local : .ssh(hostID: UUID()),
            hostLabel: isLocal ? "Local: zsh" : "Remote: ssh",
            username: "kevin",
            hostname: isLocal ? "localhost" : "example.remote",
            port: isLocal ? 0 : 22,
            state: .connected
        )
        sessions = [session]
        shellBuffers = [sessionID: ["line 1", "line 2"]]
        workingDirectoryBySessionID = [sessionID: "/Users/kevin"]
        bytesReceivedBySessionID = [sessionID: 100]
        bytesSentBySessionID = [sessionID: 200]

        let block = CommandBlock(
            id: UUID(),
            sessionID: sessionID,
            command: "ls",
            output: "file.txt",
            startedAt: .now.addingTimeInterval(-5),
            completedAt: .now.addingTimeInterval(-4),
            exitCode: 0,
            boundarySource: .userInput
        )
        commandBlocks = [block]
        commandOutputByBlockID = [block.id: block.output]
    }

    func recentCommandBlocks(sessionID: UUID, limit: Int) async -> [CommandBlock] {
        Array(commandBlocks.prefix(limit))
    }

    func searchCommandHistory(sessionID: UUID, query: String, limit: Int) async -> [CommandBlock] {
        Array(commandBlocks.filter { $0.command.contains(query) || $0.output.contains(query) }.prefix(limit))
    }

    func commandOutput(sessionID: UUID, blockID: UUID) async -> String? {
        commandOutputByBlockID[blockID]
    }

    func sendRawShellInput(sessionID: UUID, input: String) async {
        sentCommands.append(input)
    }

    func sendShellInput(sessionID: UUID, input: String, suppressEcho: Bool) async {
        sentCommands.append(input)
    }

    func executeCommandAndWait(
        sessionID: UUID,
        command: String,
        timeoutSeconds: TimeInterval
    ) async -> CommandExecutionResult {
        sentCommands.append(command)
        commandSessions.append(sessionID)
        await executeAndWaitGate?()

        if !simulatedExecuteAndWaitResultsQueue.isEmpty {
            return simulatedExecuteAndWaitResultsQueue.removeFirst()
        }

        if simulatedExecuteAndWaitTimedOut {
            return CommandExecutionResult(output: "", exitCode: nil, timedOut: true, blockID: nil)
        }

        let blockID = UUID()
        let block = CommandBlock(
            id: blockID,
            sessionID: sessionID,
            command: command,
            output: simulatedExecuteAndWaitOutput,
            startedAt: .now,
            completedAt: .now,
            exitCode: simulatedExecuteAndWaitExitCode,
            boundarySource: .userInput
        )
        commandBlocks.append(block)
        commandOutputByBlockID[blockID] = simulatedExecuteAndWaitOutput

        return CommandExecutionResult(
            output: simulatedExecuteAndWaitOutput,
            exitCode: simulatedExecuteAndWaitExitCode,
            timedOut: false,
            blockID: blockID
        )
    }

    func executeCLICommand(sessionID: UUID, command: String, timeoutSeconds: TimeInterval) async -> CLICommandResult {
        cliCommands.append((sessionID, command))
        return simulatedCLIResult
    }
}

@MainActor
private final class MockOpenRouterService: OpenRouterServicing {
    struct Request { var model: String; var messages: [OpenRouterMessage]; var tools: [LLMToolDefinition] }
    var requests: [Request] = []
    var responses: [OpenRouterCompletion] = []
    func enqueue(_ response: OpenRouterCompletion) { responses.append(response) }
    func fetchModels() async throws -> [OpenRouterModel] {
        ["test/one", "test/two"].map { OpenRouterModel(id: $0, name: $0, contextLength: 32_768, supportedParameters: ["tools"], architecture: .init(inputModalities: ["text"], outputModalities: ["text"]), pricing: nil) }
    }
    func complete(model: String, messages: [OpenRouterMessage], tools: [LLMToolDefinition], onEvent: @escaping @Sendable (LLMStreamEvent) -> Void) async throws -> OpenRouterCompletion {
        requests.append(.init(model: model, messages: messages, tools: tools))
        guard !responses.isEmpty else { throw OpenRouterError.invalidResponse }
        let response = responses.removeFirst()
        if let text = response.choices.first?.message.content { onEvent(.textDone(text)) }
        return response
    }
}
@MainActor
private final class MockAnthropicService: AnthropicServicing {
    var requests: [AnthropicRequest] = []
    var responses: [AnthropicResponse] = []
    var failure: Error?
    var catalogFetches = 0
    func enqueue(_ response: AnthropicResponse) { responses.append(response) }
    func fetchModels() async throws -> [AnthropicModel] {
        catalogFetches += 1
        return [AnthropicModel(
            id: "claude-opus-5-5",
            displayName: "Claude Opus 5.5",
            maxInputTokens: 1_000_000,
            maxTokens: 128_000,
            allowedFallbackModels: ["claude-opus-5"],
            capabilities: .init(
                thinking: .init(supported: true, types: .init(adaptive: .init(supported: true))),
                effort: .init(supported: true, low: .init(supported: true), medium: .init(supported: true), high: .init(supported: true), xhigh: .init(supported: true), max: .init(supported: true))
            )
        )]
    }
    func complete(_ request: AnthropicRequest, onEvent: @escaping @Sendable (LLMStreamEvent) -> Void) async throws -> AnthropicResponse {
        requests.append(request)
        if let failure { throw failure }
        guard !responses.isEmpty else { throw AnthropicError.invalidResponse }
        return responses.removeFirst()
    }
}
#endif
