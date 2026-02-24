# AIpatchfeatureIntegration.md
# Apply Patch Tool — Full Integration Guide for Claude Code

> **Context**: Two new files have been added to `Services/AI/`:
> - `UnifiedDiffPatcher.swift` — unified diff parser and applicator
> - `ApplyPatchTool.swift` — workspace patcher, approval tracker, remote command builder, tool definition
>
> Tests are in `Tests/ApplyPatchTests.swift`.
>
> These files compile standalone. This document covers every integration point
> including **UI work** — read the entire document before starting.
>
> **Rule**: Do NOT skip the UI sections. Every user-facing behavior change needs
> a corresponding UI element. If the user can't see it or interact with it, it
> doesn't exist.

---

## Step 1: Register the Tool Definition

**File**: `Services/AI/AIToolDefinitions.swift`

In `buildToolDefinitions()`, append the apply_patch tool:

```swift
static func buildToolDefinitions() -> [OpenAIResponsesToolDefinition] {
    var tools: [OpenAIResponsesToolDefinition] = [
        // ... existing tools ...
    ]
    
    // Add apply_patch tool
    tools.append(ApplyPatchToolDefinition.definition())
    
    return tools
}
```

Also add `"apply_patch"` to the `directActionToolNames` set if one exists,
so that direct-action prompts like "create a script that..." can use the tool.

---

## Step 2: Add the Tool Handler Case

**File**: `Services/AI/AIToolHandler.swift`

### 2a: Add an `optionalString` helper

The existing helper methods have `requiredString` and `optionalInt` but no
`optionalString`. Add this alongside the other argument parsing helpers:

```swift
private static func optionalString(
    key: String,
    in arguments: [String: OpenAIJSONValue]
) -> String? {
    guard let value = arguments[key] else { return nil }
    switch value {
    case let .string(s):
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    default:
        return nil
    }
}
```

### 2b: Add the switch case

In `executeSingleToolCall()`, add a new case before the `default`:

```swift
case "apply_patch":
    let operationType = try Self.requiredString(
        key: "operation",
        in: arguments,
        toolName: toolCall.name
    )
    let path = try Self.requiredString(
        key: "path",
        in: arguments,
        toolName: toolCall.name
    )
    let diff = Self.optionalString(key: "diff", in: arguments)

    guard let opType = PatchOperation.OperationType(rawValue: operationType) else {
        throw OpenAIAgentServiceError.invalidToolArguments(
            toolName: toolCall.name,
            message: "operation must be 'create', 'update', or 'delete'"
        )
    }

    let operation = PatchOperation(type: opType, path: path, diff: diff)

    guard let session = provider.sessions.first(where: { $0.id == sessionID }) else {
        throw OpenAIAgentServiceError.sessionNotFound
    }

    // Approval gate
    let approvalTracker = service?.patchApprovalTracker ?? PatchApprovalTracker()
    let fingerprint = approvalTracker.fingerprint(operation: operation)
    if service?.patchApprovalRequired == true && !approvalTracker.isApproved(fingerprint) {
        return AIToolDefinitions.jsonString(from: .object([
            "ok": .bool(false),
            "status": .string("approval_required"),
            "operation": .string(operationType),
            "path": .string(path),
            "diff_preview": .string(String((diff ?? "").prefix(500))),
        ]))
    }
    approvalTracker.remember(fingerprint)

    if session.isLocal {
        let workingDir = provider.workingDirectoryBySessionID[sessionID]
            ?? FileManager.default.currentDirectoryPath
        let workspacePatcher = LocalWorkspacePatcher(
            workspaceRoot: URL(fileURLWithPath: workingDir)
        )
        let result = try workspacePatcher.apply(operation)
        return AIToolDefinitions.jsonString(from: .object([
            "ok": .bool(result.success),
            "output": .string(result.output),
            "lines_changed": .number(Double(result.linesChanged)),
            "warnings": .array(result.warnings.map { .string($0) }),
        ]))
    } else {
        let command = RemotePatchCommandBuilder.buildCommand(for: operation)
        let execution = await provider.executeCommandAndWait(
            sessionID: sessionID,
            command: command,
            timeoutSeconds: 15
        )
        let result = RemotePatchCommandBuilder.parseResult(
            execution.output,
            operation: operation
        )
        return AIToolDefinitions.jsonString(from: .object([
            "ok": .bool(result.success),
            "output": .string(result.output),
            "warnings": .array(result.warnings.map { .string($0) }),
        ]))
    }
```

---

## Step 3: Add Properties to OpenAIAgentService

**File**: `Services/OpenAIAgentService.swift`

Add the approval tracker and configuration properties:

```swift
@MainActor
final class OpenAIAgentService: OpenAIAgentServicing {
    // ... existing properties ...
    
    /// Tracks which patch operations have been approved this session.
    let patchApprovalTracker = PatchApprovalTracker()
    
    /// Whether patch operations require user approval before execution.
    /// Controlled by the AI settings UI. Default: true (safe default).
    var patchApprovalRequired: Bool
    
    init(
        // ... existing params ...
        patchApprovalRequired: Bool = true
    ) {
        // ... existing init body ...
        self.patchApprovalRequired = patchApprovalRequired
    }
}
```

---

## Step 4: Update the Developer System Prompt

**File**: `Services/AI/AIToolDefinitions.swift`

In `developerPrompt()`, add documentation about the new tool so the AI knows
when and how to use it. Append to the existing prompt string:

```
## File Editing with apply_patch

When you need to create, modify, or delete files, use the `apply_patch` tool
instead of `execute_command` with echo/cat/sed. It is safer and more reliable.

Workflow for modifying an existing file:
1. Use `read_file_chunk` to read the current file contents
2. Generate a unified diff based on what you read
3. Call `apply_patch` with operation="update" and the diff

Diff format requirements for updates:
- Must include @@ hunk headers with correct line numbers
- Must include context lines (unchanged lines prefixed with space)
- Removal lines prefixed with -
- Addition lines prefixed with +
- Context lines help verify you're editing the right location

For creating new files, you can use either:
- A unified diff with only + lines
- Raw file content (the tool will write it directly)

For deleting files, just specify operation="delete" and the path.

IMPORTANT: Always read a file before trying to update it. Never guess at
the current contents — use read_file_chunk to get accurate context lines.
```

---

## Step 5: Approval UI — The Part You Must Not Skip

This is the critical UI work. When the AI requests a patch and approval is
required, the tool returns `"status": "approval_required"`. The UI must
intercept this and show a confirmation dialog before the AI can proceed.

### 5a: Patch Approval View

**File**: Create `Views/AI/PatchApprovalView.swift`

This is a sheet/popover that appears when a patch needs approval:

```
┌────────────────────────────────────────────────┐
│  🔧 AI wants to modify a file                  │
│                                                 │
│  Operation: Update                              │
│  Path: /etc/nginx/nginx.conf                    │
│                                                 │
│  ┌────────────────────────────────────────┐     │
│  │  @@ -1,4 +1,6 @@                      │     │
│  │   server {                             │     │
│  │  -    listen 80;                       │     │
│  │  +    listen 443 ssl;                  │     │
│  │  +    ssl_certificate /etc/ssl/cert... │     │
│  │       server_name example.com;         │     │
│  └────────────────────────────────────────┘     │
│                                                 │
│  ☐ Remember this decision for this session      │
│                                                 │
│         [ Deny ]              [ Approve ]       │
└────────────────────────────────────────────────┘
```

**Requirements:**
- Diff preview with syntax highlighting: `-` lines in red, `+` lines in green,
  context lines in default text color, `@@` headers in cyan/blue
- Scrollable if the diff is long (cap preview at ~30 lines, show "and N more
  lines..." if truncated)
- "Remember this decision" checkbox: when checked and approved, calls
  `patchApprovalTracker.remember(fingerprint)` so the same patch isn't
  asked about again
- Deny returns an error to the AI: `{"ok": false, "status": "denied_by_user"}`
- Approve calls `patchApprovalTracker.remember(fingerprint)` and re-executes
  the tool call
- The sheet should NOT block the entire UI — it appears inline in the AI
  conversation area or as a floating sheet over the terminal

### 5b: Approval Flow in the Conversation

The approval should appear as a message in the AI conversation view, not as
a system-level dialog. This keeps context visible:

```
┌────────────────────────────────────────────────┐
│ 🤖 I'll update the nginx config to add SSL.    │
│                                                 │
│ ┌──────────────────────────────────────────┐    │
│ │ 📝 Patch: Update /etc/nginx/nginx.conf   │    │
│ │                                          │    │
│ │  -    listen 80;                         │    │
│ │  +    listen 443 ssl;                    │    │
│ │  +    ssl_certificate /etc/ssl/cert.pem; │    │
│ │                                          │    │
│ │   [ Deny ]         [ Approve & Apply ]   │    │
│ └──────────────────────────────────────────┘    │
│                                                 │
│ 🤖 ✅ Patch applied: Updated nginx.conf         │
│    (3 lines changed)                            │
└────────────────────────────────────────────────┘
```

### 5c: AI Conversation Message Types

**File**: Wherever AI chat messages are modeled (likely `Views/AI/` or `Models/`)

Add a new message variant for patch approvals. The AI conversation view needs
to render three types of AI-related messages:

1. **Text message** (existing) — normal AI response text
2. **Tool execution** (existing or implicit) — shows tool calls and results
3. **Patch approval** (NEW) — the approval card shown above

The patch approval message should contain:
```swift
struct AIPatchApprovalMessage {
    let operation: String          // "create", "update", "delete"
    let path: String               // Target file path
    let diffPreview: String        // First ~500 chars of the diff
    let fingerprint: String        // For approval tracking
    var state: ApprovalState       // .pending, .approved, .denied
    
    enum ApprovalState {
        case pending
        case approved
        case denied
    }
}
```

### 5d: Inline Patch Result Notification

After a patch executes (whether auto-approved or manually approved), show a
compact inline notification in the terminal or conversation view:

- **Create**: `📄 Created config/nginx.conf (12 lines)`
- **Update**: `📝 Updated config/nginx.conf (3 lines changed)`
- **Delete**: `🗑 Deleted config/nginx.conf`
- **Failed**: `⚠️ Patch failed: context mismatch at line 15`

If there are warnings (fuzz match, offset applied), show them in amber/yellow:
`⚠️ Patch applied with offset — context was 2 lines off`

---

## Step 6: AI Settings UI — Patch Tool Toggle

**File**: Wherever AI settings are managed (likely `Views/Settings/` or
similar)

### 6a: Add to existing AI settings

If there's already an AI settings view, add a section for the patch tool.
If there isn't an AI settings area yet, create one (see section 6b).

Add these controls to AI settings:

```
┌─────────────────────────────────────────────┐
│  FILE EDITING                               │
│                                             │
│  Allow AI to edit files    [Toggle: ON]     │
│                                             │
│  Require approval before                    │
│  applying patches          [Toggle: ON]     │
│                                             │
│  Allow file deletion       [Toggle: OFF]    │
│                                             │
│  ℹ️ When approval is required, the AI will   │
│  show you the exact changes before applying │
│  them. You can approve or deny each change. │
└─────────────────────────────────────────────┘
```

**Behavior:**
- "Allow AI to edit files" OFF → `apply_patch` tool is completely removed
  from the tool definitions sent to the AI. The AI won't even know it exists.
- "Require approval" ON → `patchApprovalRequired = true` on the service.
  Every patch shows the approval card.
- "Require approval" OFF → patches execute immediately (autonomous mode).
- "Allow file deletion" OFF → the handler rejects `operation: "delete"` with
  a clear error message. This is a separate toggle because deletion is
  irreversible.

### 6b: Persisting Settings

Store these in UserDefaults (or AppStorage for SwiftUI):

```swift
@AppStorage("ai.patchTool.enabled") var patchToolEnabled: Bool = true
@AppStorage("ai.patchTool.requireApproval") var patchRequireApproval: Bool = true
@AppStorage("ai.patchTool.allowDelete") var patchAllowDelete: Bool = false
```

Wire these into `OpenAIAgentService`:
- `patchToolEnabled` → controls whether `ApplyPatchToolDefinition.definition()`
  is included in `buildToolDefinitions()`
- `patchRequireApproval` → maps to `patchApprovalRequired`
- `patchAllowDelete` → checked in the handler before executing delete operations

### 6c: Conditional Tool Registration

**File**: `Services/AI/AIToolDefinitions.swift`

Modify `buildToolDefinitions()` to accept configuration:

```swift
static func buildToolDefinitions(
    patchToolEnabled: Bool = true
) -> [OpenAIResponsesToolDefinition] {
    var tools: [OpenAIResponsesToolDefinition] = [
        // ... existing tools ...
    ]
    
    if patchToolEnabled {
        tools.append(ApplyPatchToolDefinition.definition())
    }
    
    return tools
}
```

This pattern will extend naturally when we add more optional tools later
(e.g., host management tools, TOTP tools, network diagnostic tools). Each
tool gets a toggle, the definition is conditionally included.

---

## Step 7: Delete Safety Gate

In the handler case for `apply_patch`, add a check before the main logic:

```swift
case "apply_patch":
    // ... parse arguments ...
    
    // Delete safety gate
    if opType == .delete && !(service?.patchAllowDelete ?? false) {
        return AIToolDefinitions.jsonString(from: .object([
            "ok": .bool(false),
            "error": .string("File deletion is disabled in AI settings. The user can enable it in Settings > AI > File Editing."),
        ]))
    }
    
    // ... rest of handler ...
```

---

## Step 8: Audit Logging

**File**: Wherever audit events are logged

Every patch operation should be logged for the audit trail. Add events:

```swift
// After successful patch:
auditLog.logEvent(.aiPatchApplied(
    sessionID: sessionID,
    operation: operationType,
    path: path,
    linesChanged: result.linesChanged
))

// After denied patch:
auditLog.logEvent(.aiPatchDenied(
    sessionID: sessionID,
    operation: operationType,
    path: path
))
```

If there's no formal audit system yet, at minimum log via `os.log`:

```swift
Self.logger.info(
    "[\(traceID, privacy: .public)] patch_applied operation=\(operationType, privacy: .public) path=\(path, privacy: .public) lines=\(result.linesChanged)"
)
```

---

## Step 9: Add Test Target Membership

Add `ApplyPatchTests.swift` to the test target. The tests use:
- `@testable import ProSSHMac`
- `UnifiedDiffPatcher`, `DiffError`, `DiffHunk`, `HunkLine`
- `LocalWorkspacePatcher`, `PatchOperation`, `PatchResult`, `PatchToolError`
- `PatchApprovalTracker`
- `RemotePatchCommandBuilder`

The tests create temp directories for filesystem operations and clean up
after themselves. No external dependencies.

Run and verify:
```bash
xcodebuild -scheme ProSSHMac -destination 'platform=macOS' test \
    -only-testing:ProSSHMacTests/UnifiedDiffParserTests \
    -only-testing:ProSSHMacTests/UnifiedDiffApplyTests \
    -only-testing:ProSSHMacTests/UnifiedDiffCreateTests \
    -only-testing:ProSSHMacTests/PatchApprovalTrackerTests \
    -only-testing:ProSSHMacTests/LocalWorkspacePatcherTests \
    -only-testing:ProSSHMacTests/RemotePatchCommandBuilderTests \
    -only-testing:ProSSHMacTests/PatchRoundTripTests \
    2>&1 | grep -E '(Test Suite|Executed|failed)'
```

---

## Step 10: Verify Build

After all integration steps:

```bash
# Build
xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build 2>&1 | tail -5

# Full test suite
xcodebuild -scheme ProSSHMac -destination 'platform=macOS' test 2>&1 | grep -E '(Test Suite|Executed|failed)'
```

---

## File Summary

### Files already added (no modification needed):
| File | Location | Lines |
|------|----------|-------|
| `UnifiedDiffPatcher.swift` | `Services/AI/` | ~370 |
| `ApplyPatchTool.swift` | `Services/AI/` | ~380 |
| `ApplyPatchTests.swift` | `Tests/` | ~450 |

### Files to modify:
| File | Changes |
|------|---------|
| `Services/AI/AIToolDefinitions.swift` | Add tool to `buildToolDefinitions()`, update `developerPrompt()`, accept `patchToolEnabled` param |
| `Services/AI/AIToolHandler.swift` | Add `optionalString` helper, add `case "apply_patch":` handler |
| `Services/OpenAIAgentService.swift` | Add `patchApprovalTracker`, `patchApprovalRequired`, `patchAllowDelete` properties |

### Files to create:
| File | Purpose |
|------|---------|
| `Views/AI/PatchApprovalView.swift` | Approval card with diff preview, approve/deny buttons |

### UI to add to existing views:
| View | Addition |
|------|----------|
| AI conversation view | Render `AIPatchApprovalMessage` inline with approve/deny |
| AI conversation view | Render patch result notifications (📄/📝/🗑/⚠️) |
| AI settings view | "File Editing" section with 3 toggles |

---

## UI Checklist (Do Not Skip)

- [ ] Patch approval card renders inline in AI conversation
- [ ] Diff preview has color-coded lines (red/green/default/blue)
- [ ] Diff preview is scrollable and truncated at ~30 lines
- [ ] "Remember this decision" checkbox works
- [ ] Approve button triggers patch execution and shows result
- [ ] Deny button returns error to AI and shows denial message
- [ ] Patch result notification appears after execution (create/update/delete/fail)
- [ ] Warnings display in amber (fuzz match, offset)
- [ ] Settings: "Allow AI to edit files" toggle works (removes tool entirely)
- [ ] Settings: "Require approval" toggle works
- [ ] Settings: "Allow file deletion" toggle works (blocks delete operations)
- [ ] Settings persist across app restarts (UserDefaults/AppStorage)
- [ ] All three settings wire through to OpenAIAgentService correctly

---

## Design Notes

**Color palette for diff preview** (match common terminal diff colors):
- Addition lines (`+`): green text or green-tinted background
- Removal lines (`-`): red text or red-tinted background
- Context lines (` `): default text color, slightly dimmed
- Hunk headers (`@@`): cyan or blue, monospaced

**Font**: Use the same monospaced font as the terminal view for the diff
preview. The diff is code — it should look like code.

**Animation**: When a patch is approved and applied, briefly flash the result
notification green before fading to normal. Gives tactile feedback that
something happened.

**Error state**: If a patch fails after approval (context mismatch, file not
found), show the error inline in red with the full error message. The AI will
likely retry with corrected context — the error message helps the user
understand what went wrong.
