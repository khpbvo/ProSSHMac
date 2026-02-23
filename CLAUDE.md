# CLAUDE.md — Project Knowledge Base

This file is the general knowledge memory for Claude Code working on ProSSHMac.
It is read automatically at the start of every session.

---

## Long-Term Memory

The long-term memory for this project lives in `docs/featurelist.md`.

**After every code change, you MUST:**
1. Update `docs/featurelist.md` with a dated loop-log entry describing what was changed and why.
2. Update this `CLAUDE.md` file if any architectural knowledge, conventions, known issues, or key file locations changed.
3. Keep both files current — they are the only persistent memory across sessions.

---

## Project Overview

**ProSSHMac** is a native macOS SSH/terminal client built with SwiftUI + Metal.

Key capabilities:
- Metal-rendered terminal (custom glyph atlas, GPU cell buffer, cursor animation)
- SSH connections via libssh (C wrapper in `CLibSSH/`)
- Local shell sessions via PTY (`LocalShellChannel`)
- SFTP file browser sidebar (left, toggle `Cmd+B`)
- AI Terminal Copilot sidebar (right, toggle `Cmd+Opt+I`) — uses OpenAI Responses API pinned to `gpt-5.1-codex-max`
- Pane splitting, session tabs, session recording/playback
- KeyForge (SSH key generation), certificate management, port forwarding
- Visual effects: CRT scanlines, barrel distortion, gradient glow, matrix screensaver

---

## Build & Test

```bash
# Build
xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build

# Run all tests
xcodebuild -scheme ProSSHMac -destination 'platform=macOS' test

# Run specific test suite
xcodebuild -scheme ProSSHMac -destination 'platform=macOS' test -only-testing:ProSSHMacTests/OpenAIAgentServiceTests
```

- Test bundle: `ProSSHMacTests`
- Most test files are still compiled under app sources (migration to test bundle is ongoing)
- Known: some tests require the host app process; avoid `-disable-main-thread-checker` unless needed

---

## Project Structure

```
ProSSHMac/
├── App/                  # App entry, dependencies, navigation coordinator
├── CLibSSH/              # C wrapper around libssh (ProSSHLibSSHWrapper.c/.h)
├── Models/               # Host, Session, Transfer, SSHKey, SSHCertificate, AuditLogEntry
├── Services/             # SessionManager, SSHTransport, TransferManager, EncryptedStorage,
│                         #   PortForwardingManager, KeyStore, CertificateStore, OpenAI services
├── Terminal/
│   ├── Grid/             # TerminalGrid, TerminalCell, ScrollbackBuffer, GridReflow, GridSnapshot
│   ├── Parser/           # VT parser, CSIHandler, OSCHandler, SGRHandler, ESCHandler, DCSHandler
│   ├── Input/            # KeyEncoder, MouseEncoder, HardwareKeyHandler, PasteHandler
│   ├── Renderer/         # MetalTerminalRenderer, GlyphAtlas, GlyphCache, CellBuffer,
│   │                     #   CursorRenderer, SelectionRenderer, FontManager, Shaders.metal
│   ├── Effects/          # CRT, gradient, scanner, blink, transparency, bell, link detection
│   └── Features/         # PaneManager, SessionTabManager, TerminalSearch, QuickCommands,
│                         #   SessionRecorder, TerminalHistoryIndex, CommandBlock
├── UI/
│   ├── Terminal/         # TerminalView.swift (~3400 lines, main terminal UI),
│   │                     #   TerminalAIAssistantPane, MetalTerminalSessionSurface,
│   │                     #   SplitNodeView, PaneDividerView
│   ├── Hosts/            # HostsView, HostFormView
│   ├── Transfers/        # TransfersView
│   ├── Settings/         # SettingsView + effect settings subviews
│   ├── KeyForge/         # KeyForgeView, KeyInspectorView
│   └── Certificates/     # CertificatesView, CertificateInspectorView
├── ViewModels/           # HostListViewModel, KeyForgeViewModel, CertificatesViewModel
└── Platform/             # PlatformCompatibility (macOS/iOS shims)
```

---

## Key Files (most frequently edited)

| File | What it does | Size |
|------|-------------|------|
| `UI/Terminal/TerminalView.swift` | Main terminal UI, sidebar layout, focus management, input capture | ~3400 lines |
| `UI/Terminal/TerminalAIAssistantPane.swift` | AI copilot sidebar, composer text view, message rendering | Large |
| `UI/Terminal/MetalTerminalSessionSurface.swift` | SwiftUI ↔ Metal bridge, snapshot application, selection | Medium |
| `Terminal/Renderer/MetalTerminalRenderer.swift` | Metal draw loop, cell buffer upload, cursor/selection render | Large |
| `Services/SessionManager.swift` | Session lifecycle, shell I/O, SFTP, grid snapshots, history | Large |
| `Terminal/Grid/TerminalGrid.swift` | Terminal grid state, character printing, scrolling, resize/reflow | Large |

---

## Architecture Conventions

- **ObservableObject + @StateObject** is the pattern used throughout (not `@Observable`)
- **Metal rendering** uses `MTKView` with display-link driven frames (`isPaused = false`, `enableSetNeedsDisplay = false`). Dirty flag skips draws when nothing changed.
- **Grid snapshots** flow: `TerminalGrid.snapshot()` → `SessionManager` stores + increments nonce → SwiftUI `.onChange(of: nonce)` → `MetalTerminalRenderer.updateSnapshot()` → `isDirty = true`
- **Terminal keyboard input** goes through `DirectTerminalInputNSView` (transparent NSView overlay, `hitTest` returns `nil`). It captures keys when it's the first responder.
- **Focus management** between terminal and chat sidebar uses `isAIAssistantComposerFocused` state. The `ComposerTextView` (NSTextView) signals focus via callbacks. `focusSessionAndPane()` resignes text inputs and re-arms terminal input.
- **AI service stack**: `OpenAIResponsesService` (HTTP + retry) → `OpenAIAgentService` (tool loop + safety) → `TerminalAIAssistantViewModel` → `TerminalAIAssistantPane`

---

## Known Issues & Gotchas

- **TerminalView.swift** is very large (~3400 lines). Be careful with edits — read surrounding context before modifying.
- **Focus management** between the AI composer (`NSTextView`) and the terminal (`DirectTerminalInputNSView`) is delicate. The composer must be resigned at the AppKit level (not just SwiftUI state) before the terminal can reclaim first responder. See `focusSessionAndPane()`.
- **SwiftUI state mutations during `updateNSView`** cause warnings and bugs. All NSView bridge callbacks use `DispatchQueue.main.async` or `Task { @MainActor in await Task.yield() }` deferral.
- **SourceKit diagnostics** for `TerminalView.swift` often show false "Cannot find type" errors because SourceKit can't resolve types from other files in the project. The build itself succeeds fine — always verify with `xcodebuild build`.
- **Bugs doc**: `docs/bugs.md` contains a comprehensive 68-bug audit organized by subsystem/severity. Check it before working on a subsystem.
- **Test quarantines**: Previously quarantined tests (`PaneManagerTests`, `testClearConversation`) have been fixed via `nonisolated deinit`. `SessionTabManager` also uses `nonisolated deinit` for the same reason. No active quarantines remain.

---

## Recent Changes (Session Log)

- **2026-02-23**: Fixed terminal focus loss after clicking AI chat composer. Root cause: clicking the chat input made the `ComposerTextView` first responder, but clicking back on the terminal couldn't reclaim focus because `armForKeyboardInputIfNeeded()` bailed out when `isTextInputFocused` detected the still-active NSTextView. Fix: `focusSessionAndPane()` now explicitly calls `window.makeFirstResponder(nil)` to resign any active NSTextView before setting SwiftUI state, allowing the normal `armForKeyboardInputIfNeeded()` path to succeed.
- **2026-02-23**: Implemented Shell Integration / Device Type configuration. Per-host `ShellIntegrationType` (none, zsh/bash/fish/posixSh, 8 network vendors, custom regex) stored in `ShellIntegrationConfig` on `Host`. UI picker in `HostFormView`. `ShellIntegrationScripts` provides OSC 133 injection for Unix shells (zsh precmd/preexec, bash PROMPT_COMMAND/DEBUG, fish events, POSIX sh PS1 wrapping). Vendor types use regex prompt detection in `TerminalHistoryIndex.looksLikePrompt()`. Local shells inject via overlay rc files; SSH sessions inject via post-connect raw input with 500ms delay. Key new file: `Terminal/Features/ShellIntegrationScripts.swift`.
- **2026-02-23**: Fixed invisible text after TUI programs exit. `disableAlternateBuffer()` now resets SGR attributes to defaults instead of restoring saved (potentially corrupted) colors. Metal shader now has a minimum-contrast safety net: if both fg and bg luminance < 0.06, fg is replaced with white (skipped when `hidden` attribute is set).

---

## Reference Docs

| Doc | Purpose |
|-----|---------|
| `docs/featurelist.md` | **Long-term memory** — phase plan, loop log, progress checklist |
| `docs/bugs.md` | 68-bug audit by subsystem and severity |
| `docs/FutureFeatures.md` | Prioritized feature roadmap (competitive analysis) |
| `docs/Optimization.md` | Performance bottleneck analysis and fixes |
| `docs/optimizationspart2.md` | Additional optimization work |
| `AGENTS.md` | Working memory for GPT-based agents (legacy, kept for compatibility) |
