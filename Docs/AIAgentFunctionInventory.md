# AI function inventory

Generated with `python3 scripts/inventory-ai-functions.py`. Explicit functions, local helpers, protocol requirements, init/deinit and computed properties are included. Synthesized Swift members, stored closures and unrelated terminal/SSH internals are excluded. Links refer to the audited source snapshot. This is source coverage, not executed branch coverage.

48 files, 501 declarations.

Call paths and review outcomes: [core](AIAgentAuditCore.md), [tools](AIAgentAuditTools.md), [execution](AIAgentAuditExecution.md), [prompts and skills](AIAgentAuditPrompts.md).

## ProSSHMac/Services/AI/AIAgentRunner.swift

5 declarations.

| Line | Declaration |
|---|---|
| [8](../ProSSHMac/Services/AI/AIAgentRunner.swift#L8) | `init() {}` |
| [9](../ProSSHMac/Services/AI/AIAgentRunner.swift#L9) | `nonisolated deinit {}` |
| [13](../ProSSHMac/Services/AI/AIAgentRunner.swift#L13) | `func run(` |
| [194](../ProSSHMac/Services/AI/AIAgentRunner.swift#L194) | `nonisolated private static func forward(` |
| [215](../ProSSHMac/Services/AI/AIAgentRunner.swift#L215) | `private func runWithTimeout<T: Sendable>(` |

## ProSSHMac/Services/AI/AIConversationContext.swift

14 declarations.

| Line | Declaration |
|---|---|
| [13](../ProSSHMac/Services/AI/AIConversationContext.swift#L13) | `mutating func prepare(for modelID: String) {` |
| [24](../ProSSHMac/Services/AI/AIConversationContext.swift#L24) | `mutating func requestHistory(` |
| [62](../ProSSHMac/Services/AI/AIConversationContext.swift#L62) | `mutating func fittedHistory(` |
| [69](../ProSSHMac/Services/AI/AIConversationContext.swift#L69) | `func messages() -> [AITranscriptMessage] {` |
| [81](../ProSSHMac/Services/AI/AIConversationContext.swift#L81) | `mutating func appendTurn(_ messages: [AITranscriptMessage]) {` |
| [86](../ProSSHMac/Services/AI/AIConversationContext.swift#L86) | `private static func removingOpenRouterReasoning(_ message: AITranscriptMessage) -> AITranscriptMessage {` |
| [92](../ProSSHMac/Services/AI/AIConversationContext.swift#L92) | `private static func removingAnthropicThinking(_ message: AITranscriptMessage) -> AITranscriptMessage {` |
| [105](../ProSSHMac/Services/AI/AIConversationContext.swift#L105) | `func beginRun(for conversationID: UUID) -> UUID {` |
| [111](../ProSSHMac/Services/AI/AIConversationContext.swift#L111) | `func isCurrentRun(_ runID: UUID, for conversationID: UUID) -> Bool {` |
| [115](../ProSSHMac/Services/AI/AIConversationContext.swift#L115) | `func finishRun(_ runID: UUID, for conversationID: UUID) {` |
| [121](../ProSSHMac/Services/AI/AIConversationContext.swift#L121) | `func update(state: AIConversationState, for conversationID: UUID, runID: UUID) {` |
| [126](../ProSSHMac/Services/AI/AIConversationContext.swift#L126) | `func state(for conversationID: UUID) -> AIConversationState? {` |
| [130](../ProSSHMac/Services/AI/AIConversationContext.swift#L130) | `func update(state: AIConversationState?, for conversationID: UUID) {` |
| [134](../ProSSHMac/Services/AI/AIConversationContext.swift#L134) | `func clear(conversationID: UUID) {` |

## ProSSHMac/Services/AI/AIKeychain.swift

9 declarations.

| Line | Declaration |
|---|---|
| [6](../ProSSHMac/Services/AI/AIKeychain.swift#L6) | `func loadAPIKey() async throws -> String?` |
| [7](../ProSSHMac/Services/AI/AIKeychain.swift#L7) | `func saveAPIKey(_ key: String) async throws` |
| [8](../ProSSHMac/Services/AI/AIKeychain.swift#L8) | `func deleteAPIKey() async throws` |
| [14](../ProSSHMac/Services/AI/AIKeychain.swift#L14) | `var errorDescription: String? {` |
| [25](../ProSSHMac/Services/AI/AIKeychain.swift#L25) | `static func load(service: String, account: String, dataProtection: Bool) throws -> String? {` |
| [46](../ProSSHMac/Services/AI/AIKeychain.swift#L46) | `static func load(service: String, account: String) throws -> String? {` |
| [51](../ProSSHMac/Services/AI/AIKeychain.swift#L51) | `static func save(_ value: String, service: String, account: String) throws {` |
| [69](../ProSSHMac/Services/AI/AIKeychain.swift#L69) | `static func delete(service: String, account: String, dataProtection: Bool) throws {` |
| [83](../ProSSHMac/Services/AI/AIKeychain.swift#L83) | `static func delete(service: String, account: String) throws {` |

## ProSSHMac/Services/AI/AIProviderSelection.swift

4 declarations.

| Line | Declaration |
|---|---|
| [8](../ProSSHMac/Services/AI/AIProviderSelection.swift#L8) | `var id: String { rawValue }` |
| [10](../ProSSHMac/Services/AI/AIProviderSelection.swift#L10) | `var displayName: String {` |
| [27](../ProSSHMac/Services/AI/AIProviderSelection.swift#L27) | `init(defaults: UserDefaults = .standard) {` |
| [32](../ProSSHMac/Services/AI/AIProviderSelection.swift#L32) | `func select(_ provider: AIProvider) {` |

## ProSSHMac/Services/AI/AISessionDirectory.swift

6 declarations.

| Line | Declaration |
|---|---|
| [18](../ProSSHMac/Services/AI/AISessionDirectory.swift#L18) | `static func entries(` |
| [43](../ProSSHMac/Services/AI/AISessionDirectory.swift#L43) | `static func defaultTargets(focusedID: UUID, broadcastContext: BroadcastContext?) -> [UUID] {` |
| [48](../ProSSHMac/Services/AI/AISessionDirectory.swift#L48) | `static func preamble(entries: [Entry], broadcasting: Bool) -> String {` |
| [64](../ProSSHMac/Services/AI/AISessionDirectory.swift#L64) | `static func json(entries: [Entry], defaultTargets: [UUID]) -> LLMJSONValue {` |
| [81](../ProSSHMac/Services/AI/AISessionDirectory.swift#L81) | `private static func deviceCLIPrompt(_ screenLines: [String]) -> String? {` |
| [87](../ProSSHMac/Services/AI/AISessionDirectory.swift#L87) | `static func describe(_ session: Session) -> String {` |

## ProSSHMac/Services/AI/AISharedTypes.swift

12 declarations.

| Line | Declaration |
|---|---|
| [38](../ProSSHMac/Services/AI/AISharedTypes.swift#L38) | `func data(for request: URLRequest) async throws -> (Data, URLResponse)` |
| [39](../ProSSHMac/Services/AI/AISharedTypes.swift#L39) | `func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse)` |
| [43](../ProSSHMac/Services/AI/AISharedTypes.swift#L43) | `func data(for request: URLRequest) async throws -> (Data, URLResponse) {` |
| [47](../ProSSHMac/Services/AI/AISharedTypes.swift#L47) | `func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {` |
| [80](../ProSSHMac/Services/AI/AISharedTypes.swift#L80) | `var requiresStableToolSet: Bool { get }` |
| [84](../ProSSHMac/Services/AI/AISharedTypes.swift#L84) | `func prefixFingerprint(systemPrompt: String, tools: [LLMToolDefinition]) -> String?` |
| [87](../ProSSHMac/Services/AI/AISharedTypes.swift#L87) | `func estimatedRequestBytes(` |
| [95](../ProSSHMac/Services/AI/AISharedTypes.swift#L95) | `func complete(` |
| [105](../ProSSHMac/Services/AI/AISharedTypes.swift#L105) | `var requiresStableToolSet: Bool { false }` |
| [107](../ProSSHMac/Services/AI/AISharedTypes.swift#L107) | `func prefixFingerprint(systemPrompt: String, tools: [LLMToolDefinition]) -> String? { nil }` |
| [123](../ProSSHMac/Services/AI/AISharedTypes.swift#L123) | `init(from decoder: any Decoder) throws {` |
| [155](../ProSSHMac/Services/AI/AISharedTypes.swift#L155) | `func encode(to encoder: any Encoder) throws {` |

## ProSSHMac/Services/AI/AISkillLibrary.swift

8 declarations.

| Line | Declaration |
|---|---|
| [34](../ProSSHMac/Services/AI/AISkillLibrary.swift#L34) | `init(_ skills: [AISkill] = []) {` |
| [38](../ProSSHMac/Services/AI/AISkillLibrary.swift#L38) | `func skill(named name: String) -> AISkill? {` |
| [43](../ProSSHMac/Services/AI/AISkillLibrary.swift#L43) | `var indexLines: [String] {` |
| [58](../ProSSHMac/Services/AI/AISkillLibrary.swift#L58) | `var errorDescription: String? {` |
| [90](../ProSSHMac/Services/AI/AISkillLibrary.swift#L90) | `func load() -> AISkillSet {` |
| [102](../ProSSHMac/Services/AI/AISkillLibrary.swift#L102) | `func ensureUserDirectory() throws -> URL? {` |
| [108](../ProSSHMac/Services/AI/AISkillLibrary.swift#L108) | `private static func skills(in directory: URL?, source: AISkill.Source) -> [AISkill] {` |
| [131](../ProSSHMac/Services/AI/AISkillLibrary.swift#L131) | `static func parse(_ text: String, source: AISkill.Source) throws -> AISkill {` |

## ProSSHMac/Services/AI/AIToolDefinitions.swift

11 declarations.

| Line | Declaration |
|---|---|
| [9](../ProSSHMac/Services/AI/AIToolDefinitions.swift#L9) | `static func developerPrompt(skills: [String] = []) -> String {` |
| [18](../ProSSHMac/Services/AI/AIToolDefinitions.swift#L18) | `private static var basePrompt: String {` |
| [52](../ProSSHMac/Services/AI/AIToolDefinitions.swift#L52) | `static func buildToolDefinitions(patchToolEnabled: Bool = true) -> [LLMToolDefinition] {` |
| [272](../ProSSHMac/Services/AI/AIToolDefinitions.swift#L272) | `static func directActionToolDefinitions(` |
| [284](../ProSSHMac/Services/AI/AIToolDefinitions.swift#L284) | `static func isDirectActionPrompt(_ prompt: String) -> Bool {` |
| [293](../ProSSHMac/Services/AI/AIToolDefinitions.swift#L293) | `static func errorResult(_ message: String, hint: String) -> String {` |
| [297](../ProSSHMac/Services/AI/AIToolDefinitions.swift#L297) | `nonisolated static func errorObject(_ message: String, hint: String) -> LLMJSONValue {` |
| [301](../ProSSHMac/Services/AI/AIToolDefinitions.swift#L301) | `static func jsonString(from value: LLMJSONValue) -> String {` |
| [311](../ProSSHMac/Services/AI/AIToolDefinitions.swift#L311) | `static func shortTraceID() -> String {` |
| [315](../ProSSHMac/Services/AI/AIToolDefinitions.swift#L315) | `static func shortSessionID(_ id: UUID) -> String {` |
| [319](../ProSSHMac/Services/AI/AIToolDefinitions.swift#L319) | `static func elapsedMillis(since startNanoseconds: UInt64) -> Int {` |

## ProSSHMac/Services/AI/AIToolHandler+ArgumentParsing.swift

6 declarations.

| Line | Declaration |
|---|---|
| [8](../ProSSHMac/Services/AI/AIToolHandler+ArgumentParsing.swift#L8) | `static func decodeArguments(` |
| [32](../ProSSHMac/Services/AI/AIToolHandler+ArgumentParsing.swift#L32) | `static func requiredString(` |
| [56](../ProSSHMac/Services/AI/AIToolHandler+ArgumentParsing.swift#L56) | `static func requiredInt(` |
| [84](../ProSSHMac/Services/AI/AIToolHandler+ArgumentParsing.swift#L84) | `static func optionalString(` |
| [97](../ProSSHMac/Services/AI/AIToolHandler+ArgumentParsing.swift#L97) | `static func optionalInt(` |
| [114](../ProSSHMac/Services/AI/AIToolHandler+ArgumentParsing.swift#L114) | `static func clamp(_ value: Int, min minValue: Int, max maxValue: Int) -> Int {` |

## ProSSHMac/Services/AI/AIToolHandler+DeviceCLI.swift

4 declarations.

| Line | Declaration |
|---|---|
| [8](../ProSSHMac/Services/AI/AIToolHandler+DeviceCLI.swift#L8) | `static func definition() -> LLMToolDefinition {` |
| [38](../ProSSHMac/Services/AI/AIToolHandler+DeviceCLI.swift#L38) | `func executeRunCLICommand(` |
| [93](../ProSSHMac/Services/AI/AIToolHandler+DeviceCLI.swift#L93) | `func deviceCLITargets(_ targets: [UUID], provider: any AIAgentSessionProviding) -> [(UUID, String)] {` |
| [100](../ProSSHMac/Services/AI/AIToolHandler+DeviceCLI.swift#L100) | `private static func cliResultJSON(_ result: CLICommandResult, timeout: TimeInterval, label: String) -> LLMJSONValue {` |

## ProSSHMac/Services/AI/AIToolHandler+InteractiveInput.swift

4 declarations.

| Line | Declaration |
|---|---|
| [8](../ProSSHMac/Services/AI/AIToolHandler+InteractiveInput.swift#L8) | `static func definition() -> LLMToolDefinition {` |
| [33](../ProSSHMac/Services/AI/AIToolHandler+InteractiveInput.swift#L33) | `func executeSendInput(` |
| [82](../ProSSHMac/Services/AI/AIToolHandler+InteractiveInput.swift#L82) | `private static func resolveKeys(_ tokens: [String]) -> String {` |
| [88](../ProSSHMac/Services/AI/AIToolHandler+InteractiveInput.swift#L88) | `private static func keySequence(for name: String) -> String? {` |

## ProSSHMac/Services/AI/AIToolHandler+LocalFilesystem.swift

7 declarations.

| Line | Declaration |
|---|---|
| [8](../ProSSHMac/Services/AI/AIToolHandler+LocalFilesystem.swift#L8) | `nonisolated static func searchFilesystemEntries(` |
| [77](../ProSSHMac/Services/AI/AIToolHandler+LocalFilesystem.swift#L77) | `nonisolated static func searchFileContents(` |
| [153](../ProSSHMac/Services/AI/AIToolHandler+LocalFilesystem.swift#L153) | `nonisolated static func readLocalFileChunk(` |
| [221](../ProSSHMac/Services/AI/AIToolHandler+LocalFilesystem.swift#L221) | `nonisolated static func resolvedLocalSearchURL(path: String, workingDirectory: String?) throws -> URL {` |
| [241](../ProSSHMac/Services/AI/AIToolHandler+LocalFilesystem.swift#L241) | `nonisolated static func filenameMatches(_ filename: String, pattern: String) -> Bool {` |
| [250](../ProSSHMac/Services/AI/AIToolHandler+LocalFilesystem.swift#L250) | `nonisolated static func groupMatchesByFile(_ matches: [LLMJSONValue]) -> [LLMJSONValue] {` |
| [276](../ProSSHMac/Services/AI/AIToolHandler+LocalFilesystem.swift#L276) | `nonisolated static func contentMatchesForFile(` |

## ProSSHMac/Services/AI/AIToolHandler+OutputHelpers.swift

10 declarations.

| Line | Declaration |
|---|---|
| [13](../ProSSHMac/Services/AI/AIToolHandler+OutputHelpers.swift#L13) | `static func credentialDeclinedMessage(label: String) -> String {` |
| [17](../ProSSHMac/Services/AI/AIToolHandler+OutputHelpers.swift#L17) | `static func credentialDeclinedResult(label: String) -> String {` |
| [21](../ProSSHMac/Services/AI/AIToolHandler+OutputHelpers.swift#L21) | `static func credentialDeclinedObject(label: String) -> LLMJSONValue {` |
| [25](../ProSSHMac/Services/AI/AIToolHandler+OutputHelpers.swift#L25) | `static func cancelledToolObject() -> LLMJSONValue {` |
| [29](../ProSSHMac/Services/AI/AIToolHandler+OutputHelpers.swift#L29) | `static func sessionLabel(_ sessionID: UUID, in provider: any AIAgentSessionProviding) -> String {` |
| [33](../ProSSHMac/Services/AI/AIToolHandler+OutputHelpers.swift#L33) | `static func commandBlockSummary(_ block: CommandBlock) -> LLMJSONValue {` |
| [43](../ProSSHMac/Services/AI/AIToolHandler+OutputHelpers.swift#L43) | `static func parseReadFileChunkOutput(` |
| [78](../ProSSHMac/Services/AI/AIToolHandler+OutputHelpers.swift#L78) | `static func readBoundViolationMessage(for command: String) -> String? {` |
| [111](../ProSSHMac/Services/AI/AIToolHandler+OutputHelpers.swift#L111) | `static func firstCapturedInt(in text: String, pattern: String) -> Int? {` |
| [124](../ProSSHMac/Services/AI/AIToolHandler+OutputHelpers.swift#L124) | `static func firstCapturedRange(in text: String, pattern: String) -> (start: Int, end: Int)? {` |

## ProSSHMac/Services/AI/AIToolHandler+RemoteExecution.swift

13 declarations.

| Line | Declaration |
|---|---|
| [16](../ProSSHMac/Services/AI/AIToolHandler+RemoteExecution.swift#L16) | `func searchFilesystemEntriesRemote(` |
| [53](../ProSSHMac/Services/AI/AIToolHandler+RemoteExecution.swift#L53) | `func searchFileContentsRemote(` |
| [90](../ProSSHMac/Services/AI/AIToolHandler+RemoteExecution.swift#L90) | `func readRemoteFileChunk(` |
| [168](../ProSSHMac/Services/AI/AIToolHandler+RemoteExecution.swift#L168) | `func executeRemoteToolCommand(` |
| [196](../ProSSHMac/Services/AI/AIToolHandler+RemoteExecution.swift#L196) | `static func parseRemoteFilesystemSearchOutput(` |
| [237](../ProSSHMac/Services/AI/AIToolHandler+RemoteExecution.swift#L237) | `static func parseRemoteFileContentSearchOutput(` |
| [279](../ProSSHMac/Services/AI/AIToolHandler+RemoteExecution.swift#L279) | `static func parseRemoteFilesystemResultLine(_ line: String) -> (path: String, isDirectory: Bool)? {` |
| [307](../ProSSHMac/Services/AI/AIToolHandler+RemoteExecution.swift#L307) | `static func remoteOutputPreview(_ normalizedOutput: String, maxCharacters: Int = 3000) -> String {` |
| [313](../ProSSHMac/Services/AI/AIToolHandler+RemoteExecution.swift#L313) | `static func parseRemoteGrepMatchLine(_ line: String) -> (path: String, lineNumber: Int, line: String)? {` |
| [338](../ProSSHMac/Services/AI/AIToolHandler+RemoteExecution.swift#L338) | `static func buildRemoteFilesystemSearchCommand(` |
| [364](../ProSSHMac/Services/AI/AIToolHandler+RemoteExecution.swift#L364) | `static func buildRemoteFileContentSearchCommand(` |
| [386](../ProSSHMac/Services/AI/AIToolHandler+RemoteExecution.swift#L386) | `static func buildRemoteReadFileChunkCommand(` |
| [401](../ProSSHMac/Services/AI/AIToolHandler+RemoteExecution.swift#L401) | `static func shellSingleQuoted(_ value: String) -> String {` |

## ProSSHMac/Services/AI/AIToolHandler+RemotePatch.swift

7 declarations.

| Line | Declaration |
|---|---|
| [26](../ProSSHMac/Services/AI/AIToolHandler+RemotePatch.swift#L26) | `func applyRemotePatch(` |
| [34](../ProSSHMac/Services/AI/AIToolHandler+RemotePatch.swift#L34) | `func run(sudoFirst: Bool = false, timeout: TimeInterval, _ command: (Bool) -> String) async -> RemotePatchStep {` |
| [150](../ProSSHMac/Services/AI/AIToolHandler+RemotePatch.swift#L150) | `private func runRemotePatchCommand(` |
| [180](../ProSSHMac/Services/AI/AIToolHandler+RemotePatch.swift#L180) | `private static func failedPatch(_ message: String) -> PatchResult {` |
| [184](../ProSSHMac/Services/AI/AIToolHandler+RemotePatch.swift#L184) | `static func trimmedPatchOutput(_ output: String) -> String {` |
| [188](../ProSSHMac/Services/AI/AIToolHandler+RemotePatch.swift#L188) | `static func isPermissionDeniedPatchOutput(_ output: String) -> Bool {` |
| [197](../ProSSHMac/Services/AI/AIToolHandler+RemotePatch.swift#L197) | `static func buildPatchFailureMessage(prefix: String, rawOutput: String) -> String {` |

## ProSSHMac/Services/AI/AIToolHandler.swift

8 declarations.

| Line | Declaration |
|---|---|
| [10](../ProSSHMac/Services/AI/AIToolHandler.swift#L10) | `var isBroadcasting: Bool { allSessionIDs.count > 1 }` |
| [18](../ProSSHMac/Services/AI/AIToolHandler.swift#L18) | `init() {}` |
| [19](../ProSSHMac/Services/AI/AIToolHandler.swift#L19) | `nonisolated deinit {}` |
| [23](../ProSSHMac/Services/AI/AIToolHandler.swift#L23) | `func executeToolCalls(` |
| [62](../ProSSHMac/Services/AI/AIToolHandler.swift#L62) | `private func executeSingleToolCall(` |
| [792](../ProSSHMac/Services/AI/AIToolHandler.swift#L792) | `static func hint(for error: Error) -> String {` |
| [806](../ProSSHMac/Services/AI/AIToolHandler.swift#L806) | `func resolveTargetSessions(` |
| [820](../ProSSHMac/Services/AI/AIToolHandler.swift#L820) | `func formatBroadcastResult(` |

## ProSSHMac/Services/AI/AnthropicAPIKeyStore.swift

3 declarations.

| Line | Declaration |
|---|---|
| [9](../ProSSHMac/Services/AI/AnthropicAPIKeyStore.swift#L9) | `func loadAPIKey() throws -> String? {` |
| [13](../ProSSHMac/Services/AI/AnthropicAPIKeyStore.swift#L13) | `func saveAPIKey(_ key: String) throws {` |
| [19](../ProSSHMac/Services/AI/AnthropicAPIKeyStore.swift#L19) | `func deleteAPIKey() throws {` |

## ProSSHMac/Services/AI/AnthropicChatProvider.swift

9 declarations.

| Line | Declaration |
|---|---|
| [16](../ProSSHMac/Services/AI/AnthropicChatProvider.swift#L16) | `var requiresStableToolSet: Bool { true }` |
| [18](../ProSSHMac/Services/AI/AnthropicChatProvider.swift#L18) | `func prefixFingerprint(systemPrompt: String, tools: [LLMToolDefinition]) -> String? {` |
| [24](../ProSSHMac/Services/AI/AnthropicChatProvider.swift#L24) | `func estimatedRequestBytes(` |
| [32](../ProSSHMac/Services/AI/AnthropicChatProvider.swift#L32) | `func complete(` |
| [63](../ProSSHMac/Services/AI/AnthropicChatProvider.swift#L63) | `func request(` |
| [88](../ProSSHMac/Services/AI/AnthropicChatProvider.swift#L88) | `nonisolated static func messages(from transcript: [AITranscriptMessage]) -> [AnthropicMessage] {` |
| [90](../ProSSHMac/Services/AI/AnthropicChatProvider.swift#L90) | `func append(_ role: String, _ blocks: [AnthropicBlock]) {` |
| [111](../ProSSHMac/Services/AI/AnthropicChatProvider.swift#L111) | `private nonisolated static func assistantBlocks(_ turn: AIAssistantTurn) -> [AnthropicBlock] {` |
| [130](../ProSSHMac/Services/AI/AnthropicChatProvider.swift#L130) | `nonisolated static func toolID(_ id: String) -> String {` |

## ProSSHMac/Services/AI/AnthropicClient.swift

19 declarations.

| Line | Declaration |
|---|---|
| [6](../ProSSHMac/Services/AI/AnthropicClient.swift#L6) | `func fetchModels() async throws -> [AnthropicModel]` |
| [7](../ProSSHMac/Services/AI/AnthropicClient.swift#L7) | `func complete(` |
| [38](../ProSSHMac/Services/AI/AnthropicClient.swift#L38) | `init(` |
| [52](../ProSSHMac/Services/AI/AnthropicClient.swift#L52) | `func fetchModels() async throws -> [AnthropicModel] {` |
| [83](../ProSSHMac/Services/AI/AnthropicClient.swift#L83) | `func complete(` |
| [120](../ProSSHMac/Services/AI/AnthropicClient.swift#L120) | `nonisolated static func betas(for request: AnthropicRequest) -> [String] {` |
| [128](../ProSSHMac/Services/AI/AnthropicClient.swift#L128) | `nonisolated static func requestBody(for request: AnthropicRequest) -> Data {` |
| [157](../ProSSHMac/Services/AI/AnthropicClient.swift#L157) | `nonisolated static func toolJSON(_ tool: LLMToolDefinition) -> String {` |
| [168](../ProSSHMac/Services/AI/AnthropicClient.swift#L168) | `private nonisolated static func retryDelay(attempt: Int, retryAfter: String?) -> Duration {` |
| [242](../ProSSHMac/Services/AI/AnthropicClient.swift#L242) | `init(start: [String: LLMJSONValue]) {` |
| [251](../ProSSHMac/Services/AI/AnthropicClient.swift#L251) | `private func consumeStream(` |
| [266](../ProSSHMac/Services/AI/AnthropicClient.swift#L266) | `func handle(_ payload: String) throws {` |
| [347](../ProSSHMac/Services/AI/AnthropicClient.swift#L347) | `nonisolated static func assemble(` |
| [434](../ProSSHMac/Services/AI/AnthropicClient.swift#L434) | `private func applyHeaders(to request: inout URLRequest, key: String, betas: [String]) {` |
| [442](../ProSSHMac/Services/AI/AnthropicClient.swift#L442) | `private func requireKey() async throws -> String {` |
| [448](../ProSSHMac/Services/AI/AnthropicClient.swift#L448) | `private func validate(response: URLResponse, data: Data) throws {` |
| [455](../ProSSHMac/Services/AI/AnthropicClient.swift#L455) | `private func errorMessage(from data: Data) -> String {` |
| [460](../ProSSHMac/Services/AI/AnthropicClient.swift#L460) | `private func readAll(_ bytes: URLSession.AsyncBytes) async throws -> Data {` |
| [470](../ProSSHMac/Services/AI/AnthropicClient.swift#L470) | `private nonisolated static func mapped(_ error: Error) -> Error {` |

## ProSSHMac/Services/AI/AnthropicModelStore.swift

10 declarations.

| Line | Declaration |
|---|---|
| [27](../ProSSHMac/Services/AI/AnthropicModelStore.swift#L27) | `init(client: any AnthropicServicing, defaults: UserDefaults = .standard) {` |
| [41](../ProSSHMac/Services/AI/AnthropicModelStore.swift#L41) | `var selectedModel: AnthropicModel? {` |
| [45](../ProSSHMac/Services/AI/AnthropicModelStore.swift#L45) | `func select(_ modelID: String) throws {` |
| [57](../ProSSHMac/Services/AI/AnthropicModelStore.swift#L57) | `func requireSelection() throws -> String {` |
| [64](../ProSSHMac/Services/AI/AnthropicModelStore.swift#L64) | `func setEffort(_ effort: AnthropicEffort) {` |
| [72](../ProSSHMac/Services/AI/AnthropicModelStore.swift#L72) | `func effort(for modelID: String) -> AnthropicEffort? {` |
| [79](../ProSSHMac/Services/AI/AnthropicModelStore.swift#L79) | `func contextLength(for modelID: String) -> Int {` |
| [83](../ProSSHMac/Services/AI/AnthropicModelStore.swift#L83) | `func maxOutputTokens(for modelID: String) -> Int {` |
| [87](../ProSSHMac/Services/AI/AnthropicModelStore.swift#L87) | `func refresh() async {` |
| [110](../ProSSHMac/Services/AI/AnthropicModelStore.swift#L110) | `func metadata(for modelID: String) -> AnthropicModel? {` |

## ProSSHMac/Services/AI/AnthropicTypes.swift

16 declarations.

| Line | Declaration |
|---|---|
| [7](../ProSSHMac/Services/AI/AnthropicTypes.swift#L7) | `var displayName: String {` |
| [17](../ProSSHMac/Services/AI/AnthropicTypes.swift#L17) | `static func < (lhs: Self, rhs: Self) -> Bool {` |
| [68](../ProSSHMac/Services/AI/AnthropicTypes.swift#L68) | `init(` |
| [88](../ProSSHMac/Services/AI/AnthropicTypes.swift#L88) | `var supportsAdaptiveThinking: Bool {` |
| [93](../ProSSHMac/Services/AI/AnthropicTypes.swift#L93) | `var supportedEffortLevels: [AnthropicEffort] {` |
| [103](../ProSSHMac/Services/AI/AnthropicTypes.swift#L103) | `var supportsServerFallback: Bool {` |
| [128](../ProSSHMac/Services/AI/AnthropicTypes.swift#L128) | `static func text(_ text: String) -> Self {` |
| [133](../ProSSHMac/Services/AI/AnthropicTypes.swift#L133) | `var type: String? {` |
| [139](../ProSSHMac/Services/AI/AnthropicTypes.swift#L139) | `var isThinking: Bool {` |
| [143](../ProSSHMac/Services/AI/AnthropicTypes.swift#L143) | `static func toolResult(toolUseID: String, content: String, isError: Bool = false) -> Self {` |
| [183](../ProSSHMac/Services/AI/AnthropicTypes.swift#L183) | `mutating func merge(_ other: AnthropicUsage) {` |
| [207](../ProSSHMac/Services/AI/AnthropicTypes.swift#L207) | `static func string(_ value: String) -> String {` |
| [211](../ProSSHMac/Services/AI/AnthropicTypes.swift#L211) | `static func object(_ fields: [(String, String)]) -> String {` |
| [215](../ProSSHMac/Services/AI/AnthropicTypes.swift#L215) | `static func array(_ elements: [String]) -> String {` |
| [220](../ProSSHMac/Services/AI/AnthropicTypes.swift#L220) | `static func encode<T: Encodable>(_ value: T) -> String? {` |
| [240](../ProSSHMac/Services/AI/AnthropicTypes.swift#L240) | `var errorDescription: String? {` |

## ProSSHMac/Services/AI/ApplyPatchTool.swift

24 declarations.

| Line | Declaration |
|---|---|
| [29](../ProSSHMac/Services/AI/ApplyPatchTool.swift#L29) | `func fingerprint(operation: PatchOperation, context: String? = nil) -> String {` |
| [37](../ProSSHMac/Services/AI/ApplyPatchTool.swift#L37) | `func isApproved(_ fingerprint: String) -> Bool {` |
| [42](../ProSSHMac/Services/AI/ApplyPatchTool.swift#L42) | `func remember(_ fingerprint: String) {` |
| [47](../ProSSHMac/Services/AI/ApplyPatchTool.swift#L47) | `func reset() {` |
| [93](../ProSSHMac/Services/AI/ApplyPatchTool.swift#L93) | `init(workspaceRoot: URL) {` |
| [98](../ProSSHMac/Services/AI/ApplyPatchTool.swift#L98) | `func apply(_ operation: PatchOperation) throws -> PatchResult {` |
| [111](../ProSSHMac/Services/AI/ApplyPatchTool.swift#L111) | `private func createFile(_ operation: PatchOperation) throws -> PatchResult {` |
| [144](../ProSSHMac/Services/AI/ApplyPatchTool.swift#L144) | `private func updateFile(_ operation: PatchOperation) throws -> PatchResult {` |
| [179](../ProSSHMac/Services/AI/ApplyPatchTool.swift#L179) | `private func deleteFile(_ operation: PatchOperation) throws -> PatchResult {` |
| [201](../ProSSHMac/Services/AI/ApplyPatchTool.swift#L201) | `private func resolvedPath(_ path: String, ensureParent: Bool = false) throws -> URL {` |
| [235](../ProSSHMac/Services/AI/ApplyPatchTool.swift#L235) | `private func canonicalTarget(_ target: URL, remainingLinks: Int = 40) throws -> URL {` |
| [257](../ProSSHMac/Services/AI/ApplyPatchTool.swift#L257) | `private func requireRegularFile(_ url: URL, displayPath: String) throws {` |
| [263](../ProSSHMac/Services/AI/ApplyPatchTool.swift#L263) | `private func relativePath(_ url: URL) -> String {` |
| [283](../ProSSHMac/Services/AI/ApplyPatchTool.swift#L283) | `static func buildCommand(for operation: PatchOperation) -> String {` |
| [296](../ProSSHMac/Services/AI/ApplyPatchTool.swift#L296) | `private static func buildCreateCommand(_ operation: PatchOperation) -> String {` |
| [325](../ProSSHMac/Services/AI/ApplyPatchTool.swift#L325) | `private static func buildDeleteCommand(_ operation: PatchOperation) -> String {` |
| [329](../ProSSHMac/Services/AI/ApplyPatchTool.swift#L329) | `static func buildDeleteCommand(path: String, useSudo: Bool = false) -> String {` |
| [346](../ProSSHMac/Services/AI/ApplyPatchTool.swift#L346) | `static func buildWriteCommand(` |
| [390](../ProSSHMac/Services/AI/ApplyPatchTool.swift#L390) | `static func buildReadCommand(path: String, useSudo: Bool = false) -> String {` |
| [402](../ProSSHMac/Services/AI/ApplyPatchTool.swift#L402) | `static func decodeBase64FileOutput(_ rawOutput: String) -> String? {` |
| [419](../ProSSHMac/Services/AI/ApplyPatchTool.swift#L419) | `private static func shellEscaped(_ value: String) -> String {` |
| [426](../ProSSHMac/Services/AI/ApplyPatchTool.swift#L426) | `static func parseResult(_ output: String, operation: PatchOperation) -> PatchResult {` |
| [462](../ProSSHMac/Services/AI/ApplyPatchTool.swift#L462) | `var errorDescription: String? {` |
| [491](../ProSSHMac/Services/AI/ApplyPatchTool.swift#L491) | `static func definition() -> LLMToolDefinition {` |

## ProSSHMac/Services/AI/CredentialPromptDetector.swift

4 declarations.

| Line | Declaration |
|---|---|
| [45](../ProSSHMac/Services/AI/CredentialPromptDetector.swift#L45) | `static func match(_ line: String) -> Match? {` |
| [58](../ProSSHMac/Services/AI/CredentialPromptDetector.swift#L58) | `static func isRetryNotice(_ line: String) -> Bool {` |
| [63](../ProSSHMac/Services/AI/CredentialPromptDetector.swift#L63) | `static func cursorLine(in bytes: [UInt8]) -> String {` |
| [71](../ProSSHMac/Services/AI/CredentialPromptDetector.swift#L71) | `static func showsProgress(afterAnswer bytes: [UInt8]) -> Bool {` |

## ProSSHMac/Services/AI/DeviceCLI.swift

19 declarations.

| Line | Declaration |
|---|---|
| [32](../ProSSHMac/Services/AI/DeviceCLI.swift#L32) | `static func cursorLine(in screenLines: [String]) -> String {` |
| [37](../ProSSHMac/Services/AI/DeviceCLI.swift#L37) | `static func classify(_ line: String) -> Kind {` |
| [47](../ProSSHMac/Services/AI/DeviceCLI.swift#L47) | `static func base(of prompt: String) -> String {` |
| [54](../ProSSHMac/Services/AI/DeviceCLI.swift#L54) | `private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {` |
| [88](../ProSSHMac/Services/AI/DeviceCLI.swift#L88) | `init(command: String, startPrompt: String) {` |
| [93](../ProSSHMac/Services/AI/DeviceCLI.swift#L93) | `mutating func ingest(_ data: some Sequence<UInt8>) {` |
| [102](../ProSSHMac/Services/AI/DeviceCLI.swift#L102) | `mutating func didAdvancePager() {` |
| [107](../ProSSHMac/Services/AI/DeviceCLI.swift#L107) | `func poll(idleFor idle: Duration) -> Step {` |
| [127](../ProSSHMac/Services/AI/DeviceCLI.swift#L127) | `var cursorLine: String {` |
| [131](../ProSSHMac/Services/AI/DeviceCLI.swift#L131) | `var byteCount: Int { bytes.count }` |
| [134](../ProSSHMac/Services/AI/DeviceCLI.swift#L134) | `func lineBreak(from offset: Int) -> Int? {` |
| [139](../ProSSHMac/Services/AI/DeviceCLI.swift#L139) | `func rawBytes(since offset: Int) -> [UInt8] {` |
| [144](../ProSSHMac/Services/AI/DeviceCLI.swift#L144) | `var finalPrompt: String {` |
| [150](../ProSSHMac/Services/AI/DeviceCLI.swift#L150) | `func output(dropTrailingPrompt: Bool) -> String {` |
| [168](../ProSSHMac/Services/AI/DeviceCLI.swift#L168) | `private func isPrompt(_ line: String) -> Bool {` |
| [193](../ProSSHMac/Services/AI/DeviceCLI.swift#L193) | `static func isPager(_ line: String) -> Bool {` |
| [198](../ProSSHMac/Services/AI/DeviceCLI.swift#L198) | `static func isQuestion(_ line: String) -> Bool {` |
| [203](../ProSSHMac/Services/AI/DeviceCLI.swift#L203) | `static func removePagers(_ text: String) -> String {` |
| [212](../ProSSHMac/Services/AI/DeviceCLI.swift#L212) | `static func normalize(_ bytes: [UInt8]) -> String {` |

## ProSSHMac/Services/AI/OpenRouterAPIKeyStore.swift

7 declarations.

| Line | Declaration |
|---|---|
| [4](../ProSSHMac/Services/AI/OpenRouterAPIKeyStore.swift#L4) | `func deleteLegacyProviderKeys() async throws` |
| [18](../ProSSHMac/Services/AI/OpenRouterAPIKeyStore.swift#L18) | `func loadAPIKey() throws -> String? {` |
| [22](../ProSSHMac/Services/AI/OpenRouterAPIKeyStore.swift#L22) | `func saveAPIKey(_ key: String) throws {` |
| [28](../ProSSHMac/Services/AI/OpenRouterAPIKeyStore.swift#L28) | `func deleteAPIKey() throws {` |
| [32](../ProSSHMac/Services/AI/OpenRouterAPIKeyStore.swift#L32) | `func deleteLegacyProviderKeys() throws {` |
| [45](../ProSSHMac/Services/AI/OpenRouterAPIKeyStore.swift#L45) | `init(deleter: any LegacyProviderKeyDeleting, defaults: UserDefaults = .standard) {` |
| [50](../ProSSHMac/Services/AI/OpenRouterAPIKeyStore.swift#L50) | `func runIfNeeded() async throws {` |

## ProSSHMac/Services/AI/OpenRouterChatProvider.swift

5 declarations.

| Line | Declaration |
|---|---|
| [9](../ProSSHMac/Services/AI/OpenRouterChatProvider.swift#L9) | `func estimatedRequestBytes(` |
| [22](../ProSSHMac/Services/AI/OpenRouterChatProvider.swift#L22) | `func complete(` |
| [41](../ProSSHMac/Services/AI/OpenRouterChatProvider.swift#L41) | `static func wireMessages(systemPrompt: String, messages: [AITranscriptMessage]) -> [OpenRouterMessage] {` |
| [45](../ProSSHMac/Services/AI/OpenRouterChatProvider.swift#L45) | `static func wireMessage(_ message: AITranscriptMessage) -> OpenRouterMessage {` |
| [70](../ProSSHMac/Services/AI/OpenRouterChatProvider.swift#L70) | `static func assistantTurn(from message: OpenRouterMessage) -> AIAssistantTurn {` |

## ProSSHMac/Services/AI/OpenRouterClient.swift

14 declarations.

| Line | Declaration |
|---|---|
| [5](../ProSSHMac/Services/AI/OpenRouterClient.swift#L5) | `func fetchModels() async throws -> [OpenRouterModel]` |
| [6](../ProSSHMac/Services/AI/OpenRouterClient.swift#L6) | `func complete(` |
| [95](../ProSSHMac/Services/AI/OpenRouterClient.swift#L95) | `init(` |
| [107](../ProSSHMac/Services/AI/OpenRouterClient.swift#L107) | `func fetchModels() async throws -> [OpenRouterModel] {` |
| [130](../ProSSHMac/Services/AI/OpenRouterClient.swift#L130) | `func complete(` |
| [193](../ProSSHMac/Services/AI/OpenRouterClient.swift#L193) | `private func consumeStream(` |
| [210](../ProSSHMac/Services/AI/OpenRouterClient.swift#L210) | `func consumeEvent(_ dataText: String) throws {` |
| [295](../ProSSHMac/Services/AI/OpenRouterClient.swift#L295) | `private func deltaReasoning(_ delta: StreamChunk.Choice.Delta) -> String? {` |
| [300](../ProSSHMac/Services/AI/OpenRouterClient.swift#L300) | `private func emitDoneEvents(` |
| [308](../ProSSHMac/Services/AI/OpenRouterClient.swift#L308) | `private func validateCompletion(_ completion: OpenRouterCompletion) throws {` |
| [333](../ProSSHMac/Services/AI/OpenRouterClient.swift#L333) | `private func requireKey() async throws -> String {` |
| [339](../ProSSHMac/Services/AI/OpenRouterClient.swift#L339) | `private func validate(response: URLResponse, data: Data) throws {` |
| [346](../ProSSHMac/Services/AI/OpenRouterClient.swift#L346) | `private func errorMessage(from data: Data) -> String {` |
| [351](../ProSSHMac/Services/AI/OpenRouterClient.swift#L351) | `private func readAll(_ bytes: URLSession.AsyncBytes) async throws -> Data {` |

## ProSSHMac/Services/AI/OpenRouterModelStore.swift

6 declarations.

| Line | Declaration |
|---|---|
| [19](../ProSSHMac/Services/AI/OpenRouterModelStore.swift#L19) | `init(client: any OpenRouterServicing, defaults: UserDefaults = .standard) {` |
| [31](../ProSSHMac/Services/AI/OpenRouterModelStore.swift#L31) | `var selectedModel: OpenRouterModel? {` |
| [35](../ProSSHMac/Services/AI/OpenRouterModelStore.swift#L35) | `func select(_ modelID: String) throws {` |
| [47](../ProSSHMac/Services/AI/OpenRouterModelStore.swift#L47) | `func requireSelection() throws -> String {` |
| [57](../ProSSHMac/Services/AI/OpenRouterModelStore.swift#L57) | `func contextLength(for modelID: String) -> Int {` |
| [63](../ProSSHMac/Services/AI/OpenRouterModelStore.swift#L63) | `func refresh() async {` |

## ProSSHMac/Services/AI/OpenRouterTypes.swift

8 declarations.

| Line | Declaration |
|---|---|
| [32](../ProSSHMac/Services/AI/OpenRouterTypes.swift#L32) | `var isUsableForAssistant: Bool {` |
| [38](../ProSSHMac/Services/AI/OpenRouterTypes.swift#L38) | `var promptPricePerMillion: Decimal? {` |
| [42](../ProSSHMac/Services/AI/OpenRouterTypes.swift#L42) | `var completionPricePerMillion: Decimal? {` |
| [77](../ProSSHMac/Services/AI/OpenRouterTypes.swift#L77) | `static func system(_ text: String) -> Self { .init(role: "system", content: text) }` |
| [78](../ProSSHMac/Services/AI/OpenRouterTypes.swift#L78) | `static func user(_ text: String) -> Self { .init(role: "user", content: text) }` |
| [79](../ProSSHMac/Services/AI/OpenRouterTypes.swift#L79) | `static func tool(_ output: String, callID: String) -> Self {` |
| [83](../ProSSHMac/Services/AI/OpenRouterTypes.swift#L83) | `func removingReasoning() -> Self {` |
| [134](../ProSSHMac/Services/AI/OpenRouterTypes.swift#L134) | `var errorDescription: String? {` |

## ProSSHMac/Services/AI/ServerSentEvents.swift

4 declarations.

| Line | Declaration |
|---|---|
| [20](../ProSSHMac/Services/AI/ServerSentEvents.swift#L20) | `mutating func consume(_ byte: UInt8) throws -> String? {` |
| [36](../ProSSHMac/Services/AI/ServerSentEvents.swift#L36) | `mutating func finish() throws -> String? {` |
| [41](../ProSSHMac/Services/AI/ServerSentEvents.swift#L41) | `private mutating func consumeLine() throws -> String? {` |
| [53](../ProSSHMac/Services/AI/ServerSentEvents.swift#L53) | `private mutating func dispatch() -> String? {` |

## ProSSHMac/Services/AI/UnifiedDiffPatcher.swift

10 declarations.

| Line | Declaration |
|---|---|
| [23](../ProSSHMac/Services/AI/UnifiedDiffPatcher.swift#L23) | `var errorDescription: String? {` |
| [63](../ProSSHMac/Services/AI/UnifiedDiffPatcher.swift#L63) | `var text: String {` |
| [109](../ProSSHMac/Services/AI/UnifiedDiffPatcher.swift#L109) | `func parse(diff: String) throws -> [DiffHunk] {` |
| [167](../ProSSHMac/Services/AI/UnifiedDiffPatcher.swift#L167) | `func apply(diff: String, to original: String, mode: Mode = .patch) throws -> String {` |
| [185](../ProSSHMac/Services/AI/UnifiedDiffPatcher.swift#L185) | `private func parseHunk(lines: [String], startIndex: Int) throws -> (DiffHunk, Int) {` |
| [280](../ProSSHMac/Services/AI/UnifiedDiffPatcher.swift#L280) | `private func applyCreate(hunks: [DiffHunk]) -> String {` |
| [300](../ProSSHMac/Services/AI/UnifiedDiffPatcher.swift#L300) | `private func applyPatch(hunks: [DiffHunk], to original: String) throws -> String {` |
| [392](../ProSSHMac/Services/AI/UnifiedDiffPatcher.swift#L392) | `private func findHunkPosition(` |
| [469](../ProSSHMac/Services/AI/UnifiedDiffPatcher.swift#L469) | `private func verifyHunkContext(` |
| [496](../ProSSHMac/Services/AI/UnifiedDiffPatcher.swift#L496) | `private func linesMatch(_ a: String, _ b: String) -> Bool {` |

## ProSSHMac/Services/AI/apply_diff.swift

19 declarations.

| Line | Declaration |
|---|---|
| [32](../ProSSHMac/Services/AI/apply_diff.swift#L32) | `var errorDescription: String? {` |
| [64](../ProSSHMac/Services/AI/apply_diff.swift#L64) | `func applyDiff(input: String, diff: String, mode: V4ADiffMode = .default) throws -> String {` |
| [111](../ProSSHMac/Services/AI/apply_diff.swift#L111) | `init(lines: [String], index: Int = 0, fuzz: Int = 0) {` |
| [120](../ProSSHMac/Services/AI/apply_diff.swift#L120) | `nonisolated deinit {}` |
| [137](../ProSSHMac/Services/AI/apply_diff.swift#L137) | `private func v4aNormalizeDiffLines(_ diff: String) -> [String] {` |
| [148](../ProSSHMac/Services/AI/apply_diff.swift#L148) | `private func v4aDetectNewlineFromText(_ text: String) -> String {` |
| [152](../ProSSHMac/Services/AI/apply_diff.swift#L152) | `private func v4aDetectNewline(input: String, diff: String, mode: V4ADiffMode) -> String {` |
| [160](../ProSSHMac/Services/AI/apply_diff.swift#L160) | `private func v4aNormalizeTextNewlines(_ text: String) -> String {` |
| [167](../ProSSHMac/Services/AI/apply_diff.swift#L167) | `private func v4aIsDone(_ state: V4AParserState, prefixes: [String]) -> Bool {` |
| [177](../ProSSHMac/Services/AI/apply_diff.swift#L177) | `private func v4aReadStr(_ state: V4AParserState, prefix: String) -> String {` |
| [187](../ProSSHMac/Services/AI/apply_diff.swift#L187) | `private func v4aParseCreateDiff(lines: [String], newline: String) throws -> String {` |
| [206](../ProSSHMac/Services/AI/apply_diff.swift#L206) | `private func v4aParseUpdateDiff(lines: [String], input: String) throws -> V4AParsedUpdate {` |
| [281](../ProSSHMac/Services/AI/apply_diff.swift#L281) | `private func v4aAdvanceCursorToAnchor(` |
| [325](../ProSSHMac/Services/AI/apply_diff.swift#L325) | `private func v4aReadSection(lines: [String], startIndex: Int) throws -> V4AReadSectionResult {` |
| [431](../ProSSHMac/Services/AI/apply_diff.swift#L431) | `private func v4aFindContext(` |
| [449](../ProSSHMac/Services/AI/apply_diff.swift#L449) | `private func v4aFindContextCore(` |
| [485](../ProSSHMac/Services/AI/apply_diff.swift#L485) | `private func v4aEqualsSlice(` |
| [499](../ProSSHMac/Services/AI/apply_diff.swift#L499) | `private func v4aRStrip(_ s: String) -> String {` |
| [509](../ProSSHMac/Services/AI/apply_diff.swift#L509) | `private func v4aApplyChunks(` |

## ProSSHMac/Services/AIAgentService.swift

28 declarations.

| Line | Declaration |
|---|---|
| [8](../ProSSHMac/Services/AIAgentService.swift#L8) | `var toolDefinitions: [LLMToolDefinition] { get }` |
| [9](../ProSSHMac/Services/AIAgentService.swift#L9) | `func clearConversation(conversationID: UUID)` |
| [10](../ProSSHMac/Services/AIAgentService.swift#L10) | `func generateReply(` |
| [21](../ProSSHMac/Services/AIAgentService.swift#L21) | `func clearConversation(sessionID: UUID) {` |
| [26](../ProSSHMac/Services/AIAgentService.swift#L26) | `func generateReply(` |
| [69](../ProSSHMac/Services/AIAgentService.swift#L69) | `var errorDescription: String? {` |
| [87](../ProSSHMac/Services/AIAgentService.swift#L87) | `var sessions: [Session] { get }` |
| [88](../ProSSHMac/Services/AIAgentService.swift#L88) | `var shellBuffers: [UUID: [String]] { get }` |
| [89](../ProSSHMac/Services/AIAgentService.swift#L89) | `var workingDirectoryBySessionID: [UUID: String] { get }` |
| [90](../ProSSHMac/Services/AIAgentService.swift#L90) | `var bytesReceivedBySessionID: [UUID: Int64] { get }` |
| [91](../ProSSHMac/Services/AIAgentService.swift#L91) | `var bytesSentBySessionID: [UUID: Int64] { get }` |
| [93](../ProSSHMac/Services/AIAgentService.swift#L93) | `func recentCommandBlocks(sessionID: UUID, limit: Int) async -> [CommandBlock]` |
| [94](../ProSSHMac/Services/AIAgentService.swift#L94) | `func searchCommandHistory(sessionID: UUID, query: String, limit: Int) async -> [CommandBlock]` |
| [95](../ProSSHMac/Services/AIAgentService.swift#L95) | `func commandOutput(sessionID: UUID, blockID: UUID) async -> String?` |
| [96](../ProSSHMac/Services/AIAgentService.swift#L96) | `func sendShellInput(sessionID: UUID, input: String, suppressEcho: Bool) async` |
| [97](../ProSSHMac/Services/AIAgentService.swift#L97) | `func sendRawShellInput(sessionID: UUID, input: String) async` |
| [98](../ProSSHMac/Services/AIAgentService.swift#L98) | `func executeCommandAndWait(sessionID: UUID, command: String, timeoutSeconds: TimeInterval) async -> CommandExecutionResult` |
| [99](../ProSSHMac/Services/AIAgentService.swift#L99) | `func executeCLICommand(sessionID: UUID, command: String, timeoutSeconds: TimeInterval) async -> CLICommandResult` |
| [137](../ProSSHMac/Services/AIAgentService.swift#L137) | `var toolDefinitions: [LLMToolDefinition] {` |
| [163](../ProSSHMac/Services/AIAgentService.swift#L163) | `var patchToolEnabled: Bool {` |
| [166](../ProSSHMac/Services/AIAgentService.swift#L166) | `var patchApprovalRequired: Bool {` |
| [169](../ProSSHMac/Services/AIAgentService.swift#L169) | `var patchAllowDelete: Bool {` |
| [173](../ProSSHMac/Services/AIAgentService.swift#L173) | `func requestPatchApproval(` |
| [180](../ProSSHMac/Services/AIAgentService.swift#L180) | `init(` |
| [208](../ProSSHMac/Services/AIAgentService.swift#L208) | `func clearConversation(conversationID: UUID) {` |
| [214](../ProSSHMac/Services/AIAgentService.swift#L214) | `func activeModel() async throws -> AIActiveModel {` |
| [239](../ProSSHMac/Services/AIAgentService.swift#L239) | `func generateReply(` |
| [259](../ProSSHMac/Services/AIAgentService.swift#L259) | `private func buildBroadcastContext(` |

## ProSSHMac/Services/SessionAIToolCoordinator.swift

33 declarations.

| Line | Declaration |
|---|---|
| [37](../ProSSHMac/Services/SessionAIToolCoordinator.swift#L37) | `init() {}` |
| [39](../ProSSHMac/Services/SessionAIToolCoordinator.swift#L39) | `nonisolated deinit {}` |
| [41](../ProSSHMac/Services/SessionAIToolCoordinator.swift#L41) | `func executeCommandAndWait(` |
| [118](../ProSSHMac/Services/SessionAIToolCoordinator.swift#L118) | `nonisolated static func wrappedCommand(_ command: String, token: String) -> String {` |
| [133](../ProSSHMac/Services/SessionAIToolCoordinator.swift#L133) | `func executeCLICommand(` |
| [223](../ProSSHMac/Services/SessionAIToolCoordinator.swift#L223) | `private func endCLICommand(sessionID: UUID) {` |
| [238](../ProSSHMac/Services/SessionAIToolCoordinator.swift#L238) | `private func stepCLICredentialWait(sessionID: UUID, pending: PendingCLICommand, idle: Duration) -> CLICredentialStep {` |
| [280](../ProSSHMac/Services/SessionAIToolCoordinator.swift#L280) | `private func supersedePendingCommands(sessionID: UUID) async {` |
| [297](../ProSSHMac/Services/SessionAIToolCoordinator.swift#L297) | `func filterToolOutput(sessionID: UUID, chunk: Data) -> Data {` |
| [310](../ProSSHMac/Services/SessionAIToolCoordinator.swift#L310) | `func completeToolCommand(sessionID: UUID, token: String, exitCode: Int) {` |
| [323](../ProSSHMac/Services/SessionAIToolCoordinator.swift#L323) | `private func timeoutToolCommand(sessionID: UUID, token: String) {` |
| [337](../ProSSHMac/Services/SessionAIToolCoordinator.swift#L337) | `private func cancelToolCommand(sessionID: UUID, token: String) async {` |
| [350](../ProSSHMac/Services/SessionAIToolCoordinator.swift#L350) | `func isEnteringCredential(sessionID: UUID) -> Bool {` |
| [360](../ProSSHMac/Services/SessionAIToolCoordinator.swift#L360) | `func declineCredentialPrompt(sessionID: UUID) async {` |
| [382](../ProSSHMac/Services/SessionAIToolCoordinator.swift#L382) | `func cancelCredentialPrompts() async {` |
| [401](../ProSSHMac/Services/SessionAIToolCoordinator.swift#L401) | `func sessionEnded(sessionID: UUID) {` |
| [414](../ProSSHMac/Services/SessionAIToolCoordinator.swift#L414) | `private func interruptCredentialPrompt(sessionID: UUID) async {` |
| [421](../ProSSHMac/Services/SessionAIToolCoordinator.swift#L421) | `private func startTimeout(for pending: PendingToolCommand, sessionID: UUID) {` |
| [432](../ProSSHMac/Services/SessionAIToolCoordinator.swift#L432) | `private func noteCommandOutput(_ visible: Data, sessionID: UUID, pending: PendingToolCommand) {` |
| [456](../ProSSHMac/Services/SessionAIToolCoordinator.swift#L456) | `private func armCredentialIdleCheck(sessionID: UUID, pending: PendingToolCommand) {` |
| [472](../ProSSHMac/Services/SessionAIToolCoordinator.swift#L472) | `private func checkForCredentialPrompt(sessionID: UUID, pending: PendingToolCommand) {` |
| [502](../ProSSHMac/Services/SessionAIToolCoordinator.swift#L502) | `func publishCommandCompletion(_ block: CommandBlock) {` |
| [525](../ProSSHMac/Services/SessionAIToolCoordinator.swift#L525) | `init(capture: DeviceCLICapture) {` |
| [529](../ProSSHMac/Services/SessionAIToolCoordinator.swift#L529) | `func result(status: CLICommandResult.Status) -> CLICommandResult {` |
| [558](../ProSSHMac/Services/SessionAIToolCoordinator.swift#L558) | `var continuation: CheckedContinuation<CommandExecutionResult, Never>? {` |
| [567](../ProSSHMac/Services/SessionAIToolCoordinator.swift#L567) | `init(token: String, command: String, timeoutSeconds: TimeInterval) {` |
| [573](../ProSSHMac/Services/SessionAIToolCoordinator.swift#L573) | `func filter(_ chunk: Data) -> Data {` |
| [601](../ProSSHMac/Services/SessionAIToolCoordinator.swift#L601) | `var commandOutput: String {` |
| [608](../ProSSHMac/Services/SessionAIToolCoordinator.swift#L608) | `var cursorLine: String {` |
| [612](../ProSSHMac/Services/SessionAIToolCoordinator.swift#L612) | `func recordAfterAnswer(_ bytes: some Sequence<UInt8>, restart: Bool) {` |
| [620](../ProSSHMac/Services/SessionAIToolCoordinator.swift#L620) | `func finish(_ result: CommandExecutionResult) {` |
| [634](../ProSSHMac/Services/SessionAIToolCoordinator.swift#L634) | `static func stripEscapes(_ bytes: [UInt8], keepingBackspace: Bool = false) -> [UInt8] {` |
| [659](../ProSSHMac/Services/SessionAIToolCoordinator.swift#L659) | `static func plainText(_ bytes: [UInt8]) -> String {` |

## ProSSHMac/Services/SessionManager+CredentialPrompt.swift

8 declarations.

| Line | Declaration |
|---|---|
| [24](../ProSSHMac/Services/SessionManager+CredentialPrompt.swift#L24) | `var credentialPromptPublisher: AnyPublisher<CredentialPromptRequest?, Never> { get }` |
| [25](../ProSSHMac/Services/SessionManager+CredentialPrompt.swift#L25) | `func declineCredentialPrompt(sessionID: UUID) async` |
| [26](../ProSSHMac/Services/SessionManager+CredentialPrompt.swift#L26) | `func cancelCredentialPrompts() async` |
| [30](../ProSSHMac/Services/SessionManager+CredentialPrompt.swift#L30) | `var credentialPromptPublisher: AnyPublisher<CredentialPromptRequest?, Never> {` |
| [35](../ProSSHMac/Services/SessionManager+CredentialPrompt.swift#L35) | `func credentialWaitsDidChange() {` |
| [56](../ProSSHMac/Services/SessionManager+CredentialPrompt.swift#L56) | `func declineCredentialPrompt(sessionID: UUID) async {` |
| [61](../ProSSHMac/Services/SessionManager+CredentialPrompt.swift#L61) | `func cancelCredentialPrompts() async {` |
| [67](../ProSSHMac/Services/SessionManager+CredentialPrompt.swift#L67) | `func isEnteringCredential(sessionID: UUID) -> Bool {` |

## ProSSHMac/Services/SessionShellIOCoordinator.swift

15 declarations.

| Line | Declaration |
|---|---|
| [19](../ProSSHMac/Services/SessionShellIOCoordinator.swift#L19) | `init() {}` |
| [21](../ProSSHMac/Services/SessionShellIOCoordinator.swift#L21) | `nonisolated deinit {}` |
| [23](../ProSSHMac/Services/SessionShellIOCoordinator.swift#L23) | `func cancelParserTask(for sessionID: UUID) {` |
| [28](../ProSSHMac/Services/SessionShellIOCoordinator.swift#L28) | `func sendShellInput(sessionID: UUID, input: String, suppressEcho: Bool = false) async {` |
| [62](../ProSSHMac/Services/SessionShellIOCoordinator.swift#L62) | `func sendRawShellInput(sessionID: UUID, input: String) async {` |
| [72](../ProSSHMac/Services/SessionShellIOCoordinator.swift#L72) | `func sendRawShellInputBytes(` |
| [142](../ProSSHMac/Services/SessionShellIOCoordinator.swift#L142) | `private func logLocalInputFailureIfNeeded(` |
| [172](../ProSSHMac/Services/SessionShellIOCoordinator.swift#L172) | `private func shortSessionID(_ sessionID: UUID) -> String {` |
| [176](../ProSSHMac/Services/SessionShellIOCoordinator.swift#L176) | `func startParserReader(for sessionID: UUID, rawOutput: AsyncStream<Data>) {` |
| [246](../ProSSHMac/Services/SessionShellIOCoordinator.swift#L246) | `private func recordParsedChunk(sessionID: UUID, chunk: Data) async -> Data {` |
| [281](../ProSSHMac/Services/SessionShellIOCoordinator.swift#L281) | `init(continuation: AsyncStream<Data>.Continuation) {` |
| [285](../ProSSHMac/Services/SessionShellIOCoordinator.swift#L285) | `func push(_ chunk: Data) {` |
| [296](../ProSSHMac/Services/SessionShellIOCoordinator.swift#L296) | `func finish() {` |
| [301](../ProSSHMac/Services/SessionShellIOCoordinator.swift#L301) | `private func flush() {` |
| [308](../ProSSHMac/Services/SessionShellIOCoordinator.swift#L308) | `private func scheduledFlush(generation: Int) async {` |

## ProSSHMac/UI/Settings/AIAPIKeyFields.swift

1 declarations.

| Line | Declaration |
|---|---|
| [7](../ProSSHMac/UI/Settings/AIAPIKeyFields.swift#L7) | `var body: some View {` |

## ProSSHMac/UI/Settings/AnthropicModelPicker.swift

2 declarations.

| Line | Declaration |
|---|---|
| [7](../ProSSHMac/UI/Settings/AnthropicModelPicker.swift#L7) | `var body: some View {` |
| [69](../ProSSHMac/UI/Settings/AnthropicModelPicker.swift#L69) | `private func limits(for model: AnthropicModel) -> String {` |

## ProSSHMac/UI/Settings/AnthropicSettingsSection.swift

1 declarations.

| Line | Declaration |
|---|---|
| [9](../ProSSHMac/UI/Settings/AnthropicSettingsSection.swift#L9) | `var body: some View {` |

## ProSSHMac/UI/Settings/OpenRouterModelPicker.swift

4 declarations.

| Line | Declaration |
|---|---|
| [8](../ProSSHMac/UI/Settings/OpenRouterModelPicker.swift#L8) | `private var visibleModels: [OpenRouterModel] {` |
| [17](../ProSSHMac/UI/Settings/OpenRouterModelPicker.swift#L17) | `var body: some View {` |
| [81](../ProSSHMac/UI/Settings/OpenRouterModelPicker.swift#L81) | `private func metadata(for model: OpenRouterModel) -> String {` |
| [91](../ProSSHMac/UI/Settings/OpenRouterModelPicker.swift#L91) | `private func price(_ value: Decimal) -> String {` |

## ProSSHMac/UI/Terminal/CredentialPromptCardView.swift

3 declarations.

| Line | Declaration |
|---|---|
| [13](../ProSSHMac/UI/Terminal/CredentialPromptCardView.swift#L13) | `var body: some View {` |
| [69](../ProSSHMac/UI/Terminal/CredentialPromptCardView.swift#L69) | `static func title(for request: CredentialPromptRequest) -> String {` |
| [79](../ProSSHMac/UI/Terminal/CredentialPromptCardView.swift#L79) | `static func status(for request: CredentialPromptRequest) -> String {` |

## ProSSHMac/UI/Terminal/PatchApprovalCardView.swift

8 declarations.

| Line | Declaration |
|---|---|
| [14](../ProSSHMac/UI/Terminal/PatchApprovalCardView.swift#L14) | `var body: some View {` |
| [114](../ProSSHMac/UI/Terminal/PatchApprovalCardView.swift#L114) | `private var diffLines: [String] {` |
| [120](../ProSSHMac/UI/Terminal/PatchApprovalCardView.swift#L120) | `private var operationIcon: String {` |
| [128](../ProSSHMac/UI/Terminal/PatchApprovalCardView.swift#L128) | `private var operationColor: Color {` |
| [136](../ProSSHMac/UI/Terminal/PatchApprovalCardView.swift#L136) | `private var headerLabel: String {` |
| [150](../ProSSHMac/UI/Terminal/PatchApprovalCardView.swift#L150) | `var body: some View {` |
| [166](../ProSSHMac/UI/Terminal/PatchApprovalCardView.swift#L166) | `private var foregroundColor: Color {` |
| [172](../ProSSHMac/UI/Terminal/PatchApprovalCardView.swift#L172) | `private var backgroundColor: Color {` |

## ProSSHMac/UI/Terminal/ReasoningStreamView.swift

7 declarations.

| Line | Declaration |
|---|---|
| [9](../ProSSHMac/UI/Terminal/ReasoningStreamView.swift#L9) | `func makeNSView(context: Context) -> ReasoningStreamScrollView {` |
| [13](../ProSSHMac/UI/Terminal/ReasoningStreamView.swift#L13) | `func updateNSView(_ view: ReasoningStreamScrollView, context: Context) {` |
| [25](../ProSSHMac/UI/Terminal/ReasoningStreamView.swift#L25) | `init() {` |
| [54](../ProSSHMac/UI/Terminal/ReasoningStreamView.swift#L54) | `required init?(coder: NSCoder) { nil }` |
| [56](../ProSSHMac/UI/Terminal/ReasoningStreamView.swift#L56) | `func update(summary: String, details: String) {` |
| [70](../ProSSHMac/UI/Terminal/ReasoningStreamView.swift#L70) | `override func layout() {` |
| [88](../ProSSHMac/UI/Terminal/ReasoningStreamView.swift#L88) | `private static func attributedText(summary: String, details: String) -> NSAttributedString {` |

## ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift

47 declarations.

| Line | Declaration |
|---|---|
| [22](../ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift#L22) | `var body: some View {` |
| [65](../ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift#L65) | `private var header: some View {` |
| [94](../ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift#L94) | `private var activeModelDisplayName: String {` |
| [103](../ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift#L103) | `private var messagesView: some View {` |
| [111](../ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift#L111) | `private var conversationMessagesView: some View {` |
| [158](../ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift#L158) | `private var reasoningStreamPanel: some View {` |
| [195](../ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift#L195) | `private var visibleMessages: [TerminalAIAssistantMessage] {` |
| [204](../ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift#L204) | `private var activePatchApprovalBinding: Binding<PatchApprovalRequest?> {` |
| [215](../ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift#L215) | `private var emptyState: some View {` |
| [228](../ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift#L228) | `private var composer: some View {` |
| [318](../ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift#L318) | `private func submitComposer() {` |
| [330](../ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift#L330) | `var body: some View {` |
| [374](../ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift#L374) | `private var backgroundColor: Color {` |
| [389](../ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift#L389) | `var body: some View {` |
| [429](../ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift#L429) | `var body: some View {` |
| [460](../ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift#L460) | `private var codeBackground: Color {` |
| [470](../ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift#L470) | `var body: some View {` |
| [483](../ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift#L483) | `var body: some View {` |
| [496](../ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift#L496) | `private func tableRow(_ cells: [String], isHeader: Bool) -> some View {` |
| [524](../ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift#L524) | `func makeCoordinator() -> Coordinator {` |
| [530](../ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift#L530) | `func makeNSView(context: Context) -> NSScrollView {` |
| [582](../ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift#L582) | `func updateNSView(_ nsView: NSScrollView, context: Context) {` |
| [615](../ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift#L615) | `init(parent: AIAssistantComposerTextView) {` |
| [619](../ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift#L619) | `func textDidChange(_ notification: Notification) {` |
| [626](../ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift#L626) | `func textDidBeginEditing(_ notification: Notification) {` |
| [630](../ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift#L630) | `func textDidEndEditing(_ notification: Notification) {` |
| [634](../ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift#L634) | `func submitRequested() {` |
| [638](../ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift#L638) | `func updateFocus(_ focused: Bool) {` |
| [647](../ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift#L647) | `func recalculateHeight() {` |
| [669](../ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift#L669) | `private func setDraftText(_ value: String) {` |
| [678](../ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift#L678) | `func recalculateHeightDeferred() {` |
| [691](../ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift#L691) | `override func keyDown(with event: NSEvent) {` |
| [708](../ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift#L708) | `override func becomeFirstResponder() -> Bool {` |
| [716](../ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift#L716) | `override func resignFirstResponder() -> Bool {` |
| [724](../ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift#L724) | `override func setFrameSize(_ newSize: NSSize) {` |
| [729](../ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift#L729) | `override func menu(for event: NSEvent) -> NSMenu? {` |
| [773](../ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift#L773) | `init(id: Int = 0, kind: Kind) {` |
| [779](../ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift#L779) | `static func parseSegments(from content: String) -> [Segment] {` |
| [861](../ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift#L861) | `private static func tableCells(_ line: String) -> [String]? {` |
| [886](../ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift#L886) | `private static func isTableDivider(_ line: String, columns: Int) -> Bool {` |
| [894](../ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift#L894) | `static func highlightedCode(_ code: String, language: String?, darkMode: Bool) -> AttributedString {` |
| [932](../ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift#L932) | `static func markdownText(_ text: String) -> AttributedString {` |
| [964](../ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift#L964) | `private static func applyRegex(_ pattern: String, color: NSColor, to attributed: NSMutableAttributedString) {` |
| [975](../ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift#L975) | `private static func keywordList(for language: String?) -> [String] {` |
| [1003](../ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift#L1003) | `var body: some View {` |
| [1022](../ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift#L1022) | `private var icon: String {` |
| [1030](../ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift#L1030) | `private var summaryText: String {` |

## ProSSHMac/ViewModels/AIKeySettingsViewModel.swift

6 declarations.

| Line | Declaration |
|---|---|
| [17](../ProSSHMac/ViewModels/AIKeySettingsViewModel.swift#L17) | `init(providerName: String, keyStore: any AIAPIKeyStoring, refreshCatalog: @escaping @MainActor () async -> Void) {` |
| [23](../ProSSHMac/ViewModels/AIKeySettingsViewModel.swift#L23) | `func refresh() async {` |
| [34](../ProSSHMac/ViewModels/AIKeySettingsViewModel.swift#L34) | `func saveAPIKey() async {` |
| [51](../ProSSHMac/ViewModels/AIKeySettingsViewModel.swift#L51) | `func removeAPIKey() async {` |
| [62](../ProSSHMac/ViewModels/AIKeySettingsViewModel.swift#L62) | `func pasteFromClipboard() {` |
| [68](../ProSSHMac/ViewModels/AIKeySettingsViewModel.swift#L68) | `private func applyStoredKeyState(_ key: String?) {` |

## ProSSHMac/ViewModels/AnthropicSettingsViewModel.swift

1 declarations.

| Line | Declaration |
|---|---|
| [7](../ProSSHMac/ViewModels/AnthropicSettingsViewModel.swift#L7) | `init(modelStore: AnthropicModelStore, keyStore: any AIAPIKeyStoring) {` |

## ProSSHMac/ViewModels/OpenRouterSettingsViewModel.swift

1 declarations.

| Line | Declaration |
|---|---|
| [7](../ProSSHMac/ViewModels/OpenRouterSettingsViewModel.swift#L7) | `init(modelStore: OpenRouterModelStore, keyStore: any AIAPIKeyStoring) {` |

## ProSSHMac/ViewModels/TerminalAIAssistantViewModel.swift

31 declarations.

| Line | Declaration |
|---|---|
| [77](../ProSSHMac/ViewModels/TerminalAIAssistantViewModel.swift#L77) | `var formattedReasoningSummary: String {` |
| [81](../ProSSHMac/ViewModels/TerminalAIAssistantViewModel.swift#L81) | `var formattedReasoningDetails: String {` |
| [85](../ProSSHMac/ViewModels/TerminalAIAssistantViewModel.swift#L85) | `var reasoningPanelText: String {` |
| [98](../ProSSHMac/ViewModels/TerminalAIAssistantViewModel.swift#L98) | `init(` |
| [129](../ProSSHMac/ViewModels/TerminalAIAssistantViewModel.swift#L129) | `nonisolated deinit {}` |
| [131](../ProSSHMac/ViewModels/TerminalAIAssistantViewModel.swift#L131) | `func clearConversation() {` |
| [147](../ProSSHMac/ViewModels/TerminalAIAssistantViewModel.swift#L147) | `func stop() {` |
| [164](../ProSSHMac/ViewModels/TerminalAIAssistantViewModel.swift#L164) | `func declineCredentialPrompt() {` |
| [170](../ProSSHMac/ViewModels/TerminalAIAssistantViewModel.swift#L170) | `private func endCredentialPromptsForStop() {` |
| [178](../ProSSHMac/ViewModels/TerminalAIAssistantViewModel.swift#L178) | `private func applyCredentialPrompt(_ request: CredentialPromptRequest?) {` |
| [199](../ProSSHMac/ViewModels/TerminalAIAssistantViewModel.swift#L199) | `private func appendStatus(_ text: String) {` |
| [206](../ProSSHMac/ViewModels/TerminalAIAssistantViewModel.swift#L206) | `func requestPatchApproval(` |
| [223](../ProSSHMac/ViewModels/TerminalAIAssistantViewModel.swift#L223) | `func approvePatch(remember: Bool) {` |
| [229](../ProSSHMac/ViewModels/TerminalAIAssistantViewModel.swift#L229) | `func denyPatch() {` |
| [235](../ProSSHMac/ViewModels/TerminalAIAssistantViewModel.swift#L235) | `func handlePatchApprovalDismissed() {` |
| [239](../ProSSHMac/ViewModels/TerminalAIAssistantViewModel.swift#L239) | `private func clearActivePatchApproval() {` |
| [244](../ProSSHMac/ViewModels/TerminalAIAssistantViewModel.swift#L244) | `private func appendPatchResultNotification(operation: PatchOperation, result: PatchResult) {` |
| [256](../ProSSHMac/ViewModels/TerminalAIAssistantViewModel.swift#L256) | `func submitPrompt(for sessionID: UUID, broadcastSessionIDs: [UUID]? = nil) {` |
| [277](../ProSSHMac/ViewModels/TerminalAIAssistantViewModel.swift#L277) | `private func sendPrompt(_ prompt: String, for sessionID: UUID, broadcastSessionIDs: [UUID]? = nil) {` |
| [354](../ProSSHMac/ViewModels/TerminalAIAssistantViewModel.swift#L354) | `private func handleStreamEvent(_ event: AIAgentStreamEvent, assistantMessageID: UUID) {` |
| [372](../ProSSHMac/ViewModels/TerminalAIAssistantViewModel.swift#L372) | `private func appendDelta(_ delta: String, to messageID: UUID) {` |
| [381](../ProSSHMac/ViewModels/TerminalAIAssistantViewModel.swift#L381) | `private func applyDoneText(_ text: String, to messageID: UUID) {` |
| [390](../ProSSHMac/ViewModels/TerminalAIAssistantViewModel.swift#L390) | `private func appendReasoning(_ text: String, isSummary: Bool) {` |
| [400](../ProSSHMac/ViewModels/TerminalAIAssistantViewModel.swift#L400) | `private func applyReasoningDone(_ text: String, isSummary: Bool) {` |
| [410](../ProSSHMac/ViewModels/TerminalAIAssistantViewModel.swift#L410) | `private func finishReasoningStreams() {` |
| [414](../ProSSHMac/ViewModels/TerminalAIAssistantViewModel.swift#L414) | `private func clearReasoningPanel() {` |
| [420](../ProSSHMac/ViewModels/TerminalAIAssistantViewModel.swift#L420) | `private func streamReply(_ fullText: String, into messageID: UUID) async {` |
| [439](../ProSSHMac/ViewModels/TerminalAIAssistantViewModel.swift#L439) | `private func updateAssistantMessage(` |
| [453](../ProSSHMac/ViewModels/TerminalAIAssistantViewModel.swift#L453) | `private func messageContent(for id: UUID) -> String? {` |
| [457](../ProSSHMac/ViewModels/TerminalAIAssistantViewModel.swift#L457) | `private func streamingChunks(for text: String) -> [String] {` |
| [479](../ProSSHMac/ViewModels/TerminalAIAssistantViewModel.swift#L479) | `private func normalizeAssistantReply(_ raw: String) -> String {` |
