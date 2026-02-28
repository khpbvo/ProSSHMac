# Black Text Rendering Fix

**GitHub Issue:** #9 — Terminal input text renders black after prompt intermittently

**Branch:** `fix/black-text-rendering`

---

## Root Cause Analysis

Three distinct triggers cause terminal text to render invisible (black on dark background).
The common self-healing mechanism is minimize/maximize, which forces a full buffer rebuild
via `mtkView(_:drawableSizeWillChange:)` → `isDirty = true` + `dimensionsChanged = true`
in `CellBuffer.update()`.

### Bug 1 — SGR Hidden Attribute Leak from AI Agent Marker

`SessionAIToolCoordinator.swift` line 21 wraps every AI command with:

```swift
let wrappedCommand = "{ \(command); __ps=$?; printf '\\n\\033[8m\(marker):%s\\033[0m\\n' \"$__ps\"; }"
```

`\033[8m` is SGR code 8 (hidden attribute). The `\033[0m` at the end resets it. But if the
inner command fails catastrophically (e.g., unclosed heredoc leaves the shell in PS2
continuation prompt mode), the `printf` never executes and the reset is never sent.

The grid's `currentAttributes` retains `.hidden`. All subsequent text — including the shell
prompt and user keystrokes — is rendered invisible. The shader (`TerminalShaders.metal:298`)
explicitly skips the dark-on-dark contrast safety net when `ATTR_HIDDEN` is set, and at
line 347 renders only the background color.

**Note:** `AIToolHandler+RemoteExecution.swift` line 139 uses the same marker pattern
but does NOT use `\033[8m` — it works correctly. This confirms the SGR hiding is unnecessary.

### Bug 2 — Selection Flag Corruption in Double-Buffered CellBuffer

When the user makes a mouse selection and clears it:

1. `SelectionRenderer.applySelection(to:)` returns a snapshot with `dirtyRange` covering
   only the `previousSelectionLinearRange`.
2. `CellBuffer.update()` receives this partial update. Since `updateRange.count < newCellCount`,
   it copies the entire **read buffer** as a baseline (line 208-209), then overwrites only the
   dirty range.
3. The read buffer may contain stale `flagSelected` bits on cells that were updated by terminal
   output AFTER the selection was made but BEFORE it was cleared. These stale flags live outside
   the dirty range and persist in the GPU buffer.
4. The shader applies the selection overlay to those stale-flagged cells, causing persistent
   rendering artifacts.

### Bug 3 — No SGR Reset on Command Timeout

When `executeCommandAndWait` times out (line 95 of `SessionAIToolCoordinator.swift`), the
function returns without any cleanup. If the timed-out command emitted partial SGR sequences
(e.g., `\033[38;5;` without completing), the grid's color attributes are left corrupted.

---

## Fix Strategy

| Bug | Fix | Risk |
|-----|-----|------|
| Bug 1 | Remove `\033[8m`/`\033[0m` from the marker printf | Minimal — marker detection uses string matching, not SGR |
| Bug 2 | Force full buffer upload when selection projection is active | Minimal — selection changes are infrequent |
| Bug 3 | Send explicit `\033[0m` SGR reset on timeout | Defense-in-depth |

---

## Files That Will Change

| File | Change |
|------|--------|
| `ProSSHMac/Services/SessionAIToolCoordinator.swift` | Remove SGR hidden from marker; add SGR reset on timeout |
| `ProSSHMac/Terminal/Renderer/MetalTerminalRenderer+SnapshotUpdate.swift` | Force full upload when selection projection active |
| `Docs/featurelist.md` | Dated loop-log entry |
| `CLAUDE.md` | Remove reference to `\033[8m` marker pattern if present |

---

## Phase 1: Remove SGR Hidden from Marker

**File:** `ProSSHMac/Services/SessionAIToolCoordinator.swift`

**Line 21 — current:**
```swift
let wrappedCommand = "{ \(command); __ps=$?; printf '\\n\\033[8m\(marker):%s\\033[0m\\n' \"$__ps\"; }"
```

**Line 21 — new:**
```swift
let wrappedCommand = "{ \(command); __ps=$?; printf '\\n\(marker):%s\\n' \"$__ps\"; }"
```

This matches the pattern already used in `AIToolHandler+RemoteExecution.swift` line 139.
The marker is parsed out by `parseWrappedCommandOutput` and `CommandBlock` — it is never
shown to the user in the AI pane output.

**Verification:**
- Build succeeds
- Existing `OpenAIAgentServiceTests` pass (mock already uses markers without SGR)

---

## Phase 2: Add SGR Reset on Timeout

**File:** `ProSSHMac/Services/SessionAIToolCoordinator.swift`

After the polling `while` loop exits without finding the marker (timeout path), send an
explicit SGR reset before returning:

```swift
// Defense-in-depth: reset terminal SGR attributes on timeout to prevent
// stuck hidden/color state from a command that failed to complete its reset.
if let shell = manager?.shellChannels[sessionID] {
    try? await shell.send("\u{1B}[0m\n")
}
return CommandExecutionResult(output: "...", exitCode: nil, timedOut: true, blockID: nil)
```

**Verification:**
- Build succeeds
- Manual test: run a command that times out, verify text remains visible

---

## Phase 3: Force Full Buffer Upload on Selection Change

**File:** `ProSSHMac/Terminal/Renderer/MetalTerminalRenderer+SnapshotUpdate.swift`

**Lines 22-26 — current:**
```swift
if selectionRenderer.needsProjection() {
    renderSnapshot = selectionRenderer.applySelection(to: snapshot)
} else {
    renderSnapshot = snapshot
}
```

**Lines 22-26 — new:**
```swift
if selectionRenderer.needsProjection() {
    renderSnapshot = selectionRenderer.applySelection(to: snapshot)
    forceFullUploadForPendingSnapshot = true
} else {
    renderSnapshot = snapshot
}
```

When selection state changes (set or clear), `needsProjection()` returns true. Forcing a
full upload means the entire write buffer is populated from the snapshot with correct flags
rather than copying stale flags from the read buffer. Performance impact is negligible —
selection changes are infrequent and a full upload for an 80x24 grid (~46KB) takes <2ms.

**Verification:**
- Build succeeds
- Manual test: make a mouse selection, clear it, verify no rendering artifacts

---

## Phase 4: Update Docs

- `Docs/featurelist.md` — dated loop-log entry
- `CLAUDE.md` — update if marker pattern is referenced

---

## Verification

### Build
```bash
xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build
```

### Tests
```bash
xcodebuild -scheme ProSSHMac -destination 'platform=macOS' test
```

### Manual Tests
1. Connect to a remote host, have the AI agent run a command that leaves an open heredoc.
   After timeout, verify text remains visible and the prompt is readable.
2. Make a mouse selection in the terminal, click elsewhere to clear it. Verify no
   rendering artifacts remain.
3. Minimize and maximize the window — should still fix any residual rendering issues
   as before (existing self-healing behavior preserved).
