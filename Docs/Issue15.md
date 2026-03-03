# Issue #15 — Multi-Session Broadcast Keyboard Input

**Status:** Implemented (2026-03-03)

## Overview

Multi-session broadcast input allows keyboard input to be routed to one or all visible terminal panes simultaneously. Three routing modes are supported:

- **singleFocus** (default): Input goes to the focused pane only. Existing behavior unchanged.
- **broadcast**: Input fans out to all panes. Toggle with `Cmd+Shift+B`.
- **selectGroup**: Input goes to a user-selected subset of panes.

## Architecture

### Input Routing Model

`InputRoutingMode` enum lives in `SplitNode.swift` alongside other pane-related types. State lives in `PaneManager`:

- `inputRoutingMode: InputRoutingMode` — current mode
- `groupPaneIDs: Set<UUID>` — panes in select-group mode
- `targetSessionIDs: [UUID]` — computed, deduplicated session IDs to receive input
- `targetPaneIDs: Set<UUID>` — computed, for visual indicators

### Input Fan-Out

Interception happens at the `onSendSequence` and `onSendBytes` callbacks in `TerminalView.directTerminalInputOverlay()`. In broadcast/group mode, callbacks loop over `paneManager.targetSessionIDs` instead of sending to the single focused session. Each write goes through the existing `sendControl(_:sessionID:)` or `sendRawShellInputBytes` path.

Broadcast mode bypasses the per-session safety-mode character buffer (`directInputBufferBySessionID`) by design — broadcast is for power users wanting immediate key-by-key forwarding.

### Visual Feedback

- Orange 2px border on targeted panes
- Capsule badge ("Broadcast" / "Group") in top-right corner
- Toolbar indicator button (click to dismiss)

### Edge Cases

- Close pane during broadcast: removed from `groupPaneIDs`; empty group reverts to singleFocus
- Single pane remaining: auto-reverts to singleFocus
- Maximize: saves and clears routing state; restore recovers it
- Session sync: stale pane IDs cleaned from group

## Files Modified

| File | Changes |
|------|---------|
| `SplitNode.swift` | Added `InputRoutingMode` enum |
| `PaneManager.swift` | Added routing state, `targetSessionIDs`, `targetPaneIDs`, `toggleBroadcast()`, `togglePaneInGroup()`, `setSelectGroupMode()`, edge-case cleanup in `closePane`/`syncSessions`/`maximizePane`/`restoreMaximize` |
| `TerminalView.swift` | Input fan-out in callbacks, shortcut wiring, toolbar indicator, pass routing state to SplitNodeView |
| `TerminalKeyboardShortcutLayer.swift` | `onToggleBroadcast` + `Cmd+Shift+B` binding |
| `TerminalPaneView.swift` | Broadcast border/badge overlays, context menu items for broadcast/group |
| `SplitNodeView.swift` | Pass-through `inputRoutingMode` + `targetPaneIDs` |
| `InputRoutingTests.swift` | 17 tests covering all routing logic |

## Keyboard Shortcut

`Cmd+Shift+B` — Toggle broadcast mode (singleFocus ↔ broadcast)
