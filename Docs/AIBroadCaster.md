# AI Broadcaster — Session-Aware AI Agent for Multi-Pane Broadcast

## Overview

Makes the AI terminal copilot broadcast-aware. When broadcast/group input routing is active, the AI agent:

1. **Knows which sessions exist** with labels (host names, session types)
2. **Sees labeled outputs** per session (knows which server returned what)
3. **Targets individual sessions** via `target_session` parameter to fix one if something goes wrong
4. **Executes parallel tool calls** across different sessions simultaneously

## Architecture

### BroadcastContext

```swift
struct BroadcastContext: Sendable {
    let primarySessionID: UUID
    let allSessionIDs: [UUID]
    let sessionLabels: [UUID: String]  // sessionID → "user@host" or "Local Shell"
    var isBroadcasting: Bool { allSessionIDs.count > 1 }
}
```

Defined in `AIToolHandler.swift`. Threaded through: `TerminalView` → `ViewModel` → `AgentService` → `AgentRunner` → `ToolHandler`.

Built by `OpenAIAgentService.buildBroadcastContext()` from `broadcastSessionIDs` + `sessionProvider.sessions`. Labels use `"username@hostname"` for SSH sessions, `"Local Shell"` for local sessions.

### Session Resolution (`resolveTargetSessions`)

Every execution tool accepts an optional `target_session` parameter (nullable string in JSON schema for OpenAI strict mode compatibility). Resolution logic in `AIToolHandler.resolveTargetSessions()`:

1. **Explicit target** (`target_session` is a valid UUID in the broadcast session list) → that one session
2. **Invalid target** (UUID not found in broadcast sessions) → falls through to next rule
3. **Broadcast mode + no target** → all broadcast sessions
4. **Single focus / no broadcast context** → primary session only

### Fan-Out Behavior

- `execute_and_wait`: **Sequential** execution across target sessions (not TaskGroup — `@MainActor` isolation prevents concurrent task group dispatch). Results aggregated as labeled JSON array: `[{session, output, exit_code}, ...]`
- `execute_command` / `send_input`: Sequential loop, fire-and-forget to each target
- `get_current_screen` / `get_recent_commands`: Multi-session output via `formatBroadcastResult` (labeled sections with `---` separator)
- Read-only file tools (`read_file_chunk`, `read_files`, `search_filesystem`, `search_file_contents`): Resolve to first target session only
- `get_session_info`: Resolve to first target session
- `apply_patch`: Resolve to first target session (patching should be deliberate per-session)

### `formatBroadcastResult`

For single-session results, returns raw output. For multi-session, labels each result:

```
[user@server1]
<output>
---
[user@server2]
<output>
```

Falls back to short UUID prefix if session label is missing.

### Tool Schema: `target_session`

All 13 tools + `apply_patch` include `target_session` in their JSON schema:

```swift
static let targetSessionProperty: LLMJSONValue = .object([
    "type": .array([.string("string"), .string("null")]),
    "description": .string("Session ID to target. Pass null to target all sessions in broadcast mode..."),
])
```

The nullable type `["string", "null"]` ensures OpenAI strict mode compatibility — all properties must be in the `required` array with strict mode, so the parameter is always required but can be `null`.

### Developer Prompt

`AIToolDefinitions.developerPrompt()` includes a `MULTI-SESSION BROADCAST` section instructing the AI to:
- Use `target_session` to pick specific sessions
- Omit it to execute on all broadcast sessions
- Use `get_session_info` / `get_current_screen` with `target_session` to inspect individual sessions
- Fix failing sessions individually after broadcast execution

### Agent Context Injection

When broadcast is active, `AIAgentRunner.run()` prepends a session map to the first user message:

```
[Active broadcast sessions — 3 sessions]
  - <uuid>: user@server1 (primary)
  - <uuid>: user@server2
  - <uuid>: Local Shell
```

### UI Wiring

`TerminalView` passes `paneManager.targetSessionIDs` when `inputRoutingMode != .singleFocus`:

```swift
let broadcastIDs = paneManager.inputRoutingMode != .singleFocus
    ? paneManager.targetSessionIDs
    : nil
terminalAIAssistantViewModel.submitPrompt(for: sessionID, broadcastSessionIDs: broadcastIDs)
```

## Files Modified

| File | Changes |
|------|---------|
| `AIToolHandler.swift` | `BroadcastContext` struct, `resolveTargetSessions`, `formatBroadcastResult`, fan-out in all tool dispatch cases |
| `AIToolHandler+InteractiveInput.swift` | Accept `broadcastContext` param, resolve targets for `send_input` fan-out |
| `AIAgentRunner.swift` | Accept `BroadcastContext?`, inject session map preamble into user message |
| `AIToolDefinitions.swift` | `targetSessionProperty` constant, `target_session` on all tools, `MULTI-SESSION BROADCAST` developer prompt section |
| `ApplyPatchTool.swift` | `target_session` in `apply_patch` tool schema |
| `OpenAIAgentService.swift` | `broadcastSessionIDs` in `AIAgentServicing` protocol + implementation, `buildBroadcastContext` helper |
| `TerminalAIAssistantViewModel.swift` | `broadcastSessionIDs` param in `submitPrompt` / `sendPrompt` |
| `TerminalView.swift` | Wire `paneManager.targetSessionIDs` into AI submit callback |
| `AIBroadcastTests.swift` | 10 tests: context, resolution, formatting |

## Tests (AIBroadcastTests.swift)

10 tests covering:
- `testBroadcastContextIsBroadcastingMultipleSessions` / `...SingleSession`
- `testResolveTargetSessionsWithExplicitTarget`
- `testResolveTargetSessionsInBroadcastNoTarget`
- `testResolveTargetSessionsSingleFocus`
- `testResolveTargetSessionsInvalidTargetFallsBackToBroadcast` / `...ToPrimary`
- `testFormatBroadcastResultSingleSession` / `...MultipleSessions` / `...UsesShortIDForMissingLabel`
