import XCTest
@testable import ProSSHMac

@MainActor
final class ShellIntegrationTests: XCTestCase {

    // MARK: - Codable Round-Trip Tests

    func testShellIntegrationConfigDefaultRoundTrip() throws {
        let config = ShellIntegrationConfig()
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ShellIntegrationConfig.self, from: data)
        XCTAssertEqual(decoded.type, .none)
        XCTAssertEqual(decoded.customPromptRegex, "")
    }

    func testShellIntegrationConfigAllTypesRoundTrip() throws {
        for type in ShellIntegrationType.allCases {
            let config = ShellIntegrationConfig(type: type, customPromptRegex: type == .custom ? "^myhost\\$" : "")
            let data = try JSONEncoder().encode(config)
            let decoded = try JSONDecoder().decode(ShellIntegrationConfig.self, from: data)
            XCTAssertEqual(decoded.type, type, "Round-trip failed for \(type)")
            XCTAssertEqual(decoded.customPromptRegex, config.customPromptRegex)
        }
    }

    func testHostBackwardCompatibilityWithoutShellIntegration() throws {
        // Simulate a Host JSON blob from before shellIntegration was added
        let json: [String: Any] = [
            "id": UUID().uuidString,
            "label": "Test Host",
            "hostname": "example.com",
            "port": 22,
            "username": "admin",
            "authMethod": "password",
            "pinnedHostKeyAlgorithms": [],
            "agentForwardingEnabled": false,
            "portForwardingRules": [],
            "legacyModeEnabled": false,
            "tags": [],
            "createdAt": ISO8601DateFormatter().string(from: Date())
        ]

        let data = try JSONSerialization.data(withJSONObject: json)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let host = try decoder.decode(Host.self, from: data)

        XCTAssertEqual(host.shellIntegration.type, .none)
        XCTAssertEqual(host.shellIntegration.customPromptRegex, "")
    }

    // MARK: - Shell Script Content Tests

    func testZshScriptContainsRequiredElements() {
        let script = ShellIntegrationScripts.script(for: .zsh)
        XCTAssertNotNil(script)
        XCTAssertTrue(script!.contains("add-zsh-hook"))
        XCTAssertTrue(script!.contains("precmd"))
        XCTAssertTrue(script!.contains("preexec"))
        XCTAssertTrue(script!.contains("133;A"))
        XCTAssertTrue(script!.contains("133;C"))
        XCTAssertTrue(script!.contains("133;D"))
        XCTAssertTrue(script!.contains("__PROSSH_SHELL_INTEGRATION"))
    }

    func testBashScriptContainsRequiredElements() {
        let script = ShellIntegrationScripts.script(for: .bash)
        XCTAssertNotNil(script)
        XCTAssertTrue(script!.contains("PROMPT_COMMAND"))
        XCTAssertTrue(script!.contains("DEBUG"))
        XCTAssertTrue(script!.contains("133;A"))
        XCTAssertTrue(script!.contains("133;C"))
        XCTAssertTrue(script!.contains("133;D"))
        XCTAssertTrue(script!.contains("__PROSSH_SHELL_INTEGRATION"))
    }

    func testFishScriptContainsRequiredElements() {
        let script = ShellIntegrationScripts.script(for: .fish)
        XCTAssertNotNil(script)
        XCTAssertTrue(script!.contains("fish_prompt"))
        XCTAssertTrue(script!.contains("fish_preexec"))
        XCTAssertTrue(script!.contains("133;A"))
        XCTAssertTrue(script!.contains("133;C"))
        XCTAssertTrue(script!.contains("133;D"))
        XCTAssertTrue(script!.contains("__PROSSH_SHELL_INTEGRATION"))
    }

    func testPosixShScriptContainsRequiredElements() {
        let script = ShellIntegrationScripts.script(for: .posixSh)
        XCTAssertNotNil(script)
        XCTAssertTrue(script!.contains("PS1"))
        XCTAssertTrue(script!.contains("133;A"))
        XCTAssertTrue(script!.contains("133;B"))
        XCTAssertTrue(script!.contains("__PROSSH_SHELL_INTEGRATION"))
    }

    func testVendorTypesReturnNilScript() {
        let vendorTypes: [ShellIntegrationType] = [
            .ciscoIOS, .juniperJunOS, .aristaEOS, .mikrotikRouterOS,
            .paloAltoPANOS, .hpProCurve, .fortinetFortiOS, .nokiaSROS
        ]
        for type in vendorTypes {
            XCTAssertNil(ShellIntegrationScripts.script(for: type), "Expected nil script for \(type)")
        }
    }

    // MARK: - SSH Injection Script Tests

    func testSSHInjectionScriptsAreSingleLine() {
        let shellTypes: [ShellIntegrationType] = [.zsh, .bash, .fish, .posixSh]
        for type in shellTypes {
            let script = ShellIntegrationScripts.sshInjectionScript(for: type)
            XCTAssertNotNil(script, "Expected SSH injection script for \(type)")
            // Must be a single line (no newlines)
            XCTAssertFalse(script!.contains("\n"), "SSH injection script for \(type) must be single-line")
            // Must start with space (history suppression)
            XCTAssertTrue(script!.hasPrefix(" "), "SSH injection script for \(type) must start with space")
            // Must end with clear
            XCTAssertTrue(script!.hasSuffix("; clear"), "SSH injection script for \(type) must end with clear")
            // Must contain OSC 133 sequences
            XCTAssertTrue(script!.contains("133;A"), "SSH injection script for \(type) must contain OSC 133;A")
            // Must contain idempotency guard
            XCTAssertTrue(script!.contains("__PROSSH_SHELL_INTEGRATION"), "SSH injection script for \(type) must contain guard")
        }
    }

    func testSSHInjectionVendorTypesReturnNil() {
        let vendorTypes: [ShellIntegrationType] = [
            .ciscoIOS, .juniperJunOS, .aristaEOS, .mikrotikRouterOS,
            .paloAltoPANOS, .hpProCurve, .fortinetFortiOS, .nokiaSROS,
            .none, .custom
        ]
        for type in vendorTypes {
            XCTAssertNil(ShellIntegrationScripts.sshInjectionScript(for: type), "Expected nil SSH injection for \(type)")
        }
    }

    func testNoneAndCustomReturnNilScript() {
        XCTAssertNil(ShellIntegrationScripts.script(for: .none))
        XCTAssertNil(ShellIntegrationScripts.script(for: .custom))
    }

    func testLocalShellTabCompletionCompletesPartialToken() async throws {
        let harness = try await LocalShellTestHarness.spawn()
        defer {
            Task { await harness.close() }
        }

        let unique = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let readyMarker = "__PROSSH_READY_\(unique)__"
        let setupMarker = "__PROSSH_SETUP_\(unique)__"
        let fileName = "prossh_tab_\(unique)_target"
        let partial = "prossh_tab_\(unique)_ta"
        let contentMarker = "TAB_COMPLETION_OK_\(unique)"
        let testDir = "/tmp/prossh-local-input-v2-\(unique)"

        try await harness.send("echo \(readyMarker)\n")
        let readySeen = await harness.waitFor(readyMarker, timeout: .seconds(10))
        XCTAssertTrue(readySeen, "Timed out waiting for local shell readiness.")

        try await harness.send("mkdir -p \(testDir) && cd \(testDir) && printf '%s\\n' '\(contentMarker)' > \(fileName)\n")
        try await harness.send("echo \(setupMarker)\n")
        let setupSeen = await harness.waitFor(setupMarker, timeout: .seconds(10))
        XCTAssertTrue(setupSeen, "Timed out waiting for local shell setup completion.")

        await harness.clearOutput()
        try await harness.send("cat \(partial)\t\n")

        let completed = await harness.waitFor(contentMarker, timeout: .seconds(6))
        if !completed {
            let outputTail = await harness.snapshot().suffix(800)
            XCTFail("Expected Tab completion to resolve '\(partial)' to '\(fileName)'. Output tail:\n\(outputTail)")
        }
    }

    func testLocalShellCtrlCInterruptsForegroundCommand() async throws {
        let harness = try await LocalShellTestHarness.spawn()
        defer {
            Task { await harness.close() }
        }

        let unique = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let readyMarker = "__PROSSH_READY_\(unique)__"
        let markerValue = "SIGINT_OK_\(unique)"

        try await harness.send("echo \(readyMarker)\n")
        let readySeen = await harness.waitFor(readyMarker, timeout: .seconds(10))
        XCTAssertTrue(readySeen, "Timed out waiting for local shell readiness.")

        try await harness.send("__prossh_sigint_marker='\(markerValue)'\n")
        await harness.clearOutput()

        try await harness.send("sleep 10\n")
        try await Task.sleep(for: .milliseconds(350))
        try await harness.send(bytes: [0x03]) // Ctrl+C
        try await harness.send("echo $__prossh_sigint_marker\n")

        let interrupted = await harness.waitFor(markerValue, timeout: .seconds(2))
        if !interrupted {
            let outputTail = await harness.snapshot().suffix(800)
            XCTFail("Expected Ctrl+C to interrupt foreground sleep quickly. Output tail:\n\(outputTail)")
        }
    }

    func testLocalShellBackspaceEditsInputLine() async throws {
        let harness = try await LocalShellTestHarness.spawn()
        defer {
            Task { await harness.close() }
        }

        let unique = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let readyMarker = "__PROSSH_READY_\(unique)__"
        let marker = "BACKSPACE_OK_\(unique)"

        try await harness.send("echo \(readyMarker)\n")
        let readySeen = await harness.waitFor(readyMarker, timeout: .seconds(10))
        XCTAssertTrue(readySeen, "Timed out waiting for local shell readiness.")

        await harness.clearOutput()
        try await harness.send("echo \(marker)X")
        try await harness.send(bytes: [0x7F]) // Backspace removes trailing typo.
        try await harness.send("\n")

        let sawEditedOutput = await harness.waitFor(marker, timeout: .seconds(3))
        if !sawEditedOutput {
            let outputTail = await harness.snapshot().suffix(800)
            XCTFail("Expected Backspace-edited line to print '\(marker)'. Output tail:\n\(outputTail)")
        }
    }

    func testLocalShellArrowKeysEditInPlace() async throws {
        let harness = try await LocalShellTestHarness.spawn()
        defer {
            Task { await harness.close() }
        }

        let unique = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let readyMarker = "__PROSSH_READY_\(unique)__"
        let marker = "ABCD_\(unique)"

        try await harness.send("echo \(readyMarker)\n")
        let readySeen = await harness.waitFor(readyMarker, timeout: .seconds(10))
        XCTAssertTrue(readySeen, "Timed out waiting for local shell readiness.")

        await harness.clearOutput()
        try await harness.send("echo ACD")
        try await harness.send(bytes: [0x1B, 0x5B, 0x44, 0x1B, 0x5B, 0x44]) // Left, Left
        try await harness.send("B")
        try await harness.send(bytes: [0x1B, 0x5B, 0x43, 0x1B, 0x5B, 0x43]) // Right, Right
        try await harness.send("_\(unique)\n")

        let sawEditedOutput = await harness.waitFor(marker, timeout: .seconds(3))
        if !sawEditedOutput {
            let outputTail = await harness.snapshot().suffix(800)
            XCTFail("Expected arrow-key edited line to print '\(marker)'. Output tail:\n\(outputTail)")
        }
    }

    func testLocalShellEnterSubmitsCurrentLine() async throws {
        let harness = try await LocalShellTestHarness.spawn()
        defer {
            Task { await harness.close() }
        }

        let unique = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let readyMarker = "__PROSSH_READY_\(unique)__"
        let marker = "ENTER_OK_\(unique)"

        try await harness.send("echo \(readyMarker)\n")
        let readySeen = await harness.waitFor(readyMarker, timeout: .seconds(10))
        XCTAssertTrue(readySeen, "Timed out waiting for local shell readiness.")

        await harness.clearOutput()
        try await harness.send("echo \(marker)\n")

        let sawOutput = await harness.waitFor(marker, timeout: .seconds(3))
        if !sawOutput {
            let outputTail = await harness.snapshot().suffix(800)
            XCTFail("Expected Enter to submit current command line. Output tail:\n\(outputTail)")
        }
    }

    func testLocalShellEscapeIsDeliveredToForegroundRead() async throws {
        let harness = try await LocalShellTestHarness.spawn()
        defer {
            Task { await harness.close() }
        }

        let unique = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let readyMarker = "__PROSSH_READY_\(unique)__"
        let marker = "ESC_OK_\(unique)"

        try await harness.send("echo \(readyMarker)\n")
        let readySeen = await harness.waitFor(readyMarker, timeout: .seconds(10))
        XCTAssertTrue(readySeen, "Timed out waiting for local shell readiness.")

        await harness.clearOutput()
        try await harness.send("read -rk1 ch; if [[ \"$ch\" == $'\\\\e' ]]; then echo \(marker); else echo ESC_FAIL_\(unique); fi\n")
        try await Task.sleep(for: .milliseconds(150))
        try await harness.send(bytes: [0x1B]) // Escape

        let sawEscape = await harness.waitFor(marker, timeout: .seconds(3))
        if !sawEscape {
            let outputTail = await harness.snapshot().suffix(800)
            XCTFail("Expected ESC byte delivery to foreground read command. Output tail:\n\(outputTail)")
        }
    }

    // MARK: - Vendor Prompt Regex Tests

    func testCiscoIOSPromptRegex() throws {
        let pattern = try XCTUnwrap(ShellIntegrationScripts.vendorPromptPattern(for: .ciscoIOS))
        let regex = try NSRegularExpression(pattern: pattern)

        let positives = ["Router>", "Router#", "Router(config)#", "Router(config-if)#", "RP/0/RP0/CPU0:router#"]
        let negatives = ["Router", "Router(config", "total 24"]

        for prompt in positives {
            let range = NSRange(prompt.startIndex..., in: prompt)
            XCTAssertNotNil(regex.firstMatch(in: prompt, range: range), "Cisco IOS should match: \(prompt)")
        }
        for prompt in negatives {
            let range = NSRange(prompt.startIndex..., in: prompt)
            XCTAssertNil(regex.firstMatch(in: prompt, range: range), "Cisco IOS should NOT match: \(prompt)")
        }
    }

    func testJuniperJunOSPromptRegex() throws {
        let pattern = try XCTUnwrap(ShellIntegrationScripts.vendorPromptPattern(for: .juniperJunOS))
        let regex = try NSRegularExpression(pattern: pattern)

        let positives = ["user@host>", "user@host#", "[edit] user@host#", "[edit interfaces ge-0/0/0] user@host#"]
        let negatives = ["user@host", "@host#", "[edit user@host"]

        for prompt in positives {
            let range = NSRange(prompt.startIndex..., in: prompt)
            XCTAssertNotNil(regex.firstMatch(in: prompt, range: range), "JunOS should match: \(prompt)")
        }
        for prompt in negatives {
            let range = NSRange(prompt.startIndex..., in: prompt)
            XCTAssertNil(regex.firstMatch(in: prompt, range: range), "JunOS should NOT match: \(prompt)")
        }
    }

    func testAristaEOSPromptRegex() throws {
        let pattern = try XCTUnwrap(ShellIntegrationScripts.vendorPromptPattern(for: .aristaEOS))
        let regex = try NSRegularExpression(pattern: pattern)

        let positives = ["switch>", "switch#", "switch(config)#", "switch(config-if)#"]
        let negatives = ["switch", "switch(Config)#"]

        for prompt in positives {
            let range = NSRange(prompt.startIndex..., in: prompt)
            XCTAssertNotNil(regex.firstMatch(in: prompt, range: range), "Arista EOS should match: \(prompt)")
        }
        for prompt in negatives {
            let range = NSRange(prompt.startIndex..., in: prompt)
            XCTAssertNil(regex.firstMatch(in: prompt, range: range), "Arista EOS should NOT match: \(prompt)")
        }
    }

    func testMikrotikRouterOSPromptRegex() throws {
        let pattern = try XCTUnwrap(ShellIntegrationScripts.vendorPromptPattern(for: .mikrotikRouterOS))
        let regex = try NSRegularExpression(pattern: pattern)

        let positives = ["[admin@MikroTik] >", "[admin@MikroTik] /ip/route>", "[admin@MikroTik] (SAFE)>"]
        let negatives = ["admin@MikroTik >", "[admin@MikroTik] #"]

        for prompt in positives {
            let range = NSRange(prompt.startIndex..., in: prompt)
            XCTAssertNotNil(regex.firstMatch(in: prompt, range: range), "MikroTik should match: \(prompt)")
        }
        for prompt in negatives {
            let range = NSRange(prompt.startIndex..., in: prompt)
            XCTAssertNil(regex.firstMatch(in: prompt, range: range), "MikroTik should NOT match: \(prompt)")
        }
    }

    func testPaloAltoPANOSPromptRegex() throws {
        let pattern = try XCTUnwrap(ShellIntegrationScripts.vendorPromptPattern(for: .paloAltoPANOS))
        let regex = try NSRegularExpression(pattern: pattern)

        let positives = ["admin@PA-VM>", "admin@PA-VM#", "[edit] admin@PA-VM#"]
        let negatives = ["admin@PA-VM", "PA-VM#"]

        for prompt in positives {
            let range = NSRange(prompt.startIndex..., in: prompt)
            XCTAssertNotNil(regex.firstMatch(in: prompt, range: range), "PAN-OS should match: \(prompt)")
        }
        for prompt in negatives {
            let range = NSRange(prompt.startIndex..., in: prompt)
            XCTAssertNil(regex.firstMatch(in: prompt, range: range), "PAN-OS should NOT match: \(prompt)")
        }
    }

    func testHPProCurvePromptRegex() throws {
        let pattern = try XCTUnwrap(ShellIntegrationScripts.vendorPromptPattern(for: .hpProCurve))
        let regex = try NSRegularExpression(pattern: pattern)

        let positives = ["switch>", "HPswitch(config)#", "switch(config-vlan)#"]
        let negatives = ["(config)#", " switch#"]

        for prompt in positives {
            let range = NSRange(prompt.startIndex..., in: prompt)
            XCTAssertNotNil(regex.firstMatch(in: prompt, range: range), "HP ProCurve should match: \(prompt)")
        }
        for prompt in negatives {
            let range = NSRange(prompt.startIndex..., in: prompt)
            XCTAssertNil(regex.firstMatch(in: prompt, range: range), "HP ProCurve should NOT match: \(prompt)")
        }
    }

    func testFortinetFortiOSPromptRegex() throws {
        let pattern = try XCTUnwrap(ShellIntegrationScripts.vendorPromptPattern(for: .fortinetFortiOS))
        let regex = try NSRegularExpression(pattern: pattern)

        let positives = ["FortiGate-60F#", "FortiGate-60F (global)#", "my-firewall#"]
        let negatives = ["FortiGate-60F", "(global)#"]

        for prompt in positives {
            let range = NSRange(prompt.startIndex..., in: prompt)
            XCTAssertNotNil(regex.firstMatch(in: prompt, range: range), "FortiOS should match: \(prompt)")
        }
        for prompt in negatives {
            let range = NSRange(prompt.startIndex..., in: prompt)
            XCTAssertNil(regex.firstMatch(in: prompt, range: range), "FortiOS should NOT match: \(prompt)")
        }
    }

    func testNokiaSROSPromptRegex() throws {
        let pattern = try XCTUnwrap(ShellIntegrationScripts.vendorPromptPattern(for: .nokiaSROS))
        let regex = try NSRegularExpression(pattern: pattern)

        let positives = ["A:router#", "A:router>", "A:router[/system]#"]
        let negatives = ["router#", "a:router#"]

        for prompt in positives {
            let range = NSRange(prompt.startIndex..., in: prompt)
            XCTAssertNotNil(regex.firstMatch(in: prompt, range: range), "Nokia SROS should match: \(prompt)")
        }
        for prompt in negatives {
            let range = NSRange(prompt.startIndex..., in: prompt)
            XCTAssertNil(regex.firstMatch(in: prompt, range: range), "Nokia SROS should NOT match: \(prompt)")
        }
    }

    // MARK: - Custom Regex Test

    func testCustomRegexFallback() throws {
        // Valid custom regex
        let pattern = "^myhost\\$"
        let regex = try NSRegularExpression(pattern: pattern)
        let line = "myhost$"
        let range = NSRange(line.startIndex..., in: line)
        XCTAssertNotNil(regex.firstMatch(in: line, range: range))

        // Non-matching line should not match
        let other = "otherhost$"
        let otherRange = NSRange(other.startIndex..., in: other)
        XCTAssertNil(regex.firstMatch(in: other, range: otherRange))
    }

    func testInvalidCustomRegexGracefullyFails() {
        // Invalid regex should not crash — just returns nil
        let invalidPattern = "[unclosed"
        let regex = try? NSRegularExpression(pattern: invalidPattern)
        XCTAssertNil(regex, "Invalid regex pattern should fail gracefully")
    }

    // MARK: - Vendor Pattern Availability

    func testAllVendorTypesHavePatterns() {
        let vendorTypes: [ShellIntegrationType] = [
            .ciscoIOS, .juniperJunOS, .aristaEOS, .mikrotikRouterOS,
            .paloAltoPANOS, .hpProCurve, .fortinetFortiOS, .nokiaSROS
        ]
        for type in vendorTypes {
            XCTAssertNotNil(ShellIntegrationScripts.vendorPromptPattern(for: type), "Missing pattern for \(type)")
        }
    }

    func testNonVendorTypesHaveNoPattern() {
        let nonVendorTypes: [ShellIntegrationType] = [.none, .zsh, .bash, .fish, .posixSh, .custom]
        for type in nonVendorTypes {
            XCTAssertNil(ShellIntegrationScripts.vendorPromptPattern(for: type), "Unexpected pattern for \(type)")
        }
    }
}

private final class LocalShellTestHarness {
    private let channel: LocalShellChannel
    private let outputBuffer = LocalShellOutputBuffer()
    private let readerTask: Task<Void, Never>

    private init(channel: LocalShellChannel) {
        self.channel = channel
        self.readerTask = Task.detached { [outputBuffer, rawOutput = channel.rawOutput] in
            for await chunk in rawOutput {
                await outputBuffer.append(chunk)
            }
        }
    }

    static func spawn() async throws -> LocalShellTestHarness {
        let shellPath: String?
        if FileManager.default.isExecutableFile(atPath: "/bin/zsh") {
            shellPath = "/bin/zsh"
        } else {
            shellPath = nil
        }

        let channel = try await LocalShellChannel.spawn(
            columns: 120,
            rows: 40,
            shellPath: shellPath,
            workingDirectory: "/tmp"
        )
        return LocalShellTestHarness(channel: channel)
    }

    func send(_ input: String) async throws {
        try await channel.send(input)
    }

    func send(bytes: [UInt8]) async throws {
        try await channel.send(bytes: bytes)
    }

    func waitFor(_ text: String, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout

        while clock.now < deadline {
            if await outputBuffer.contains(text) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(40))
        }

        return await outputBuffer.contains(text)
    }

    func snapshot() async -> String {
        await outputBuffer.snapshot()
    }

    func clearOutput() async {
        await outputBuffer.clear()
    }

    func close() async {
        readerTask.cancel()
        await channel.close()
    }
}

private actor LocalShellOutputBuffer {
    private var text = ""
    private let maxBufferCount = 200_000

    func append(_ data: Data) {
        text += String(decoding: data, as: UTF8.self)
        if text.count > maxBufferCount {
            text.removeFirst(text.count - maxBufferCount)
        }
    }

    func contains(_ needle: String) -> Bool {
        text.contains(needle)
    }

    func snapshot() -> String {
        text
    }

    func clear() {
        text = ""
    }
}
