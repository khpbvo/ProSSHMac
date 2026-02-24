# RefactorTerminalView.md — TerminalView.swift Decomposition Checklist

This file is the working checklist and run-book for decomposing `TerminalView.swift`
(3,425 lines) into focused, maintainable files.

Follow the same workflow as `RefactorTheActor.md`:
- Every phase begins with a detailed plan section.
- Execute each numbered step in order.
- Check off `[x]` as each step completes.
- Build must pass after every phase before committing.
- Commit after every phase.
- Run full test suite after all phases complete.

**All new Swift files must pass `-strict-concurrency=complete` before their creating commit.**

---

## ► CURRENT STATE — START HERE

```
Active branch   : master
Current phase   : Phase 5 — NOT STARTED
Phase status    : NOT STARTED
Immediate action: Read RefactorTerminalView.md, begin Phase 5 (extract TerminalSessionTabBar)
Last commit     : TBD "refactor(RefactorTV Phase 4): extract session actions toolbar to TerminalSessionActionsBar"
```

**Update this block after every phase.**

---

## Phase Status

| Phase | Name | Status |
|-------|------|--------|
| 0 | Baseline audit — add swiftlint:disable, verify build | COMPLETE (2026-02-24) |
| 1 | Extract `DirectTerminalInputNSView` + supporting types | COMPLETE (2026-02-24) |
| 2 | Extract `TerminalSessionHeaderView` + `TerminalSessionMetadataView` | COMPLETE (2026-02-24) |
| 3 | Extract `TerminalSearchBarView` | COMPLETE (2026-02-24) |
| 4 | Extract `TerminalSessionActionsBar` | COMPLETE (2026-02-24) |
| 5 | Extract `TerminalSessionTabBar` | NOT STARTED |
| 6 | Extract `TerminalQuickCommandPanel` | NOT STARTED |
| 7 | Extract `TerminalFileBrowserSidebar` | NOT STARTED |
| 8 | Extract `TerminalSurfaceView` | NOT STARTED |
| 9 | Extract `TerminalSidebarLayoutStore` + `TerminalKeyboardShortcutLayer`, final cleanup | NOT STARTED |
| — | Full test suite run | NOT STARTED |

---

## Non-Negotiable Rules

1. **Build must pass after every phase** — run `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build` and verify `** BUILD SUCCEEDED **` before committing.
2. **Commit after every phase** — each phase is a self-contained commit.
3. **Header comment on every extracted file** — first non-blank, non-import line must be: `// Extracted from TerminalView.swift`
4. **Every new Swift file must pass `-strict-concurrency=complete`** — add the flag temporarily to Other Swift Flags in Xcode, build, fix warnings, then remove the flag before committing.
5. **`// swiftlint:disable file_length`** — added in Phase 0. Remove only when `TerminalView.swift` drops below 400 lines (it won't reach that until all phases are done; remove at the end of Phase 9 if under 400, otherwise keep).
6. **`@StateObject` ownership never moves** — every `@StateObject` in `TerminalView` stays in `TerminalView`. Child views receive them as `@ObservedObject` passed via init.
7. **`@AppStorage` duplication is correct** — child views re-declaring the same `@AppStorage` key as `TerminalView` stay in sync automatically via SwiftUI. This is intentional.
8. **Project uses PBXFileSystemSynchronizedRootGroup** — new `.swift` files created on disk in `ProSSHMac/UI/Terminal/` are auto-detected by Xcode. No manual xcodeproj editing needed.
9. **Read the full phase plan before touching any file** — the plan for each phase is written below. Never start coding a phase without reading all its steps first.

---

## Target Directory After All Phases

```
ProSSHMac/UI/Terminal/
├── TerminalView.swift                    (~1,100 lines — orchestration only)
├── TerminalInputCaptureView.swift        (~375 lines — NSView keyboard capture + preference keys)
├── TerminalSessionHeaderView.swift       (~60 lines  — session title + status badge)
├── TerminalSessionMetadataView.swift     (~110 lines — expandable SSH metadata panel)
├── TerminalSearchBarView.swift           (~80 lines  — search query bar + match navigation)
├── TerminalSessionActionsBar.swift       (~115 lines — Clear/Record/Playback/Disconnect buttons)
├── TerminalSessionTabBar.swift           (~175 lines — horizontal tab bar + context menus)
├── TerminalQuickCommandPanel.swift       (~435 lines — drawer + editor sheet + execution)
├── TerminalFileBrowserSidebar.swift      (~480 lines — SFTP file tree + row renderer)
├── TerminalSurfaceView.swift             (~440 lines — safe/Metal/classic renderer dispatch)
├── TerminalSidebarLayoutStore.swift      (~60 lines  — UserDefaults sidebar layout persistence)
├── TerminalKeyboardShortcutLayer.swift   (~145 lines — 50+ keyboard shortcut bindings)
├── TerminalAIAssistantPane.swift         (existing, unchanged)
├── MetalTerminalSessionSurface.swift     (existing, unchanged)
├── SplitNodeView.swift                   (existing, unchanged)
├── TerminalPaneView.swift                (existing, unchanged)
├── PaneDividerView.swift                 (existing, unchanged)
├── ExternalTerminalWindowView.swift      (existing, unchanged)
└── MatrixScreensaverView.swift           (existing, unchanged)
```

---

## Phase 0 — Baseline Audit

### Plan

No code extraction in this phase. Establish a clean baseline: add the swiftlint disable
directive to `TerminalView.swift`, verify the build, and record the baseline line count and
warning count. This mirrors Phase 0 of the original actor-isolation refactor.

### Steps (4 steps)

- [x] **0.1** Open `ProSSHMac/UI/Terminal/TerminalView.swift`. Confirm current line count (expected ~3,425). Record it here: **3,425 lines** (3,426 after insert)
- [x] **0.2** Add `// swiftlint:disable file_length` as line 1 of `TerminalView.swift` (shift all existing content down by one line).
- [x] **0.3** Run build: `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build`. Verify `** BUILD SUCCEEDED **`. Record warning count here: **0 warnings**
- [x] **0.4** Commit: `chore(RefactorTV Phase 0): baseline — add swiftlint:disable to TerminalView.swift`

---

## Phase 1 — Extract `DirectTerminalInputNSView` + Supporting Types

### Plan

The bottom of `TerminalView.swift` (lines 3052–3425) contains four types that are defined
*after* the closing brace of `struct TerminalView`: `SafeTerminalRenderedLine`,
`DirectTerminalInputCaptureView`, `DirectTerminalInputNSView`, and two `PreferenceKey` structs
plus an empty `View` extension. None of these types have inward dependencies on `TerminalView`'s
`@State` or `@StateObject` properties — they communicate purely via callback closures.

**New file:** `ProSSHMac/UI/Terminal/TerminalInputCaptureView.swift`

**Access changes required:**
- `private struct SafeTerminalRenderedLine` → `struct SafeTerminalRenderedLine` (used by
  `TerminalView.safeTerminalDisplayLines(for:)` in a different file after extraction)
- `private struct TerminalScrollOffsetPreferenceKey` → `struct TerminalScrollOffsetPreferenceKey`
  (used by `terminalBuffer` in `TerminalSurfaceView` after Phase 8)
- `private struct TerminalScrollContentHeightPreferenceKey` → `struct TerminalScrollContentHeightPreferenceKey`
- `private extension View { func terminalInputBehavior() }` → `extension View { func terminalInputBehavior() }`
  (called from `TerminalView`'s quick command editor text fields)

**`DirectTerminalInputCaptureView`** and **`DirectTerminalInputNSView`** are already `internal`
(no `private` keyword) — no access change needed.

### Steps (11 steps)

- [x] **1.1** Read `TerminalView.swift` lines 3050–3425 in full to confirm the exact content before moving anything.
- [x] **1.2** Create `ProSSHMac/UI/Terminal/TerminalInputCaptureView.swift`.
- [x] **1.3** Add header: first line = `// Extracted from TerminalView.swift`. Then `import SwiftUI`, `import AppKit`.
- [x] **1.4** Copy `SafeTerminalRenderedLine` (lines 3052–3056) into the new file. Change `private struct` → `struct`.
- [x] **1.5** Copy `DirectTerminalInputCaptureView: NSViewRepresentable` (lines 3058–3087) verbatim (already `internal`).
- [x] **1.6** Copy `DirectTerminalInputNSView: NSView` (lines 3089–3400) verbatim (already `internal`).
- [x] **1.7** Copy `extension View { func terminalInputBehavior() }` (lines 3404–3409). Remove the `private` keyword — make it `extension View`.
- [x] **1.8** Copy `TerminalScrollOffsetPreferenceKey` and `TerminalScrollContentHeightPreferenceKey` (lines 3411–3425). Change `private struct` → `struct` on both.
- [x] **1.9** In `TerminalView.swift`, delete lines 3050–3425 (the comment "// MARK: - Supporting Types" and everything after it). Save.
- [x] **1.10** Run build: `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build`. Verify `** BUILD SUCCEEDED **`. Fix any access-level errors (e.g., if `terminalInputBehavior()` is still called with `private` visibility somewhere).
- [x] **1.11** Commit: `refactor(RefactorTV Phase 1): extract DirectTerminalInputNSView + supporting types to TerminalInputCaptureView.swift`

**Actual TerminalView.swift line count after phase:** 3,049 lines (expected ~3,060 ✓)

---

## Phase 2 — Extract `TerminalSessionHeaderView` + `TerminalSessionMetadataView`

### Plan

Two display-only view functions that render per-session information — `header(for:)` (lines
1451–1500) and `sessionMetadata(for:)` (lines 364–462, plus `metadataRow` helper 464–476) —
are self-contained except for one piece of `@State` that travels with `sessionMetadata`:
`expandedMetadataSessions: Set<UUID>` (line 60 in the current property list). This state is
exclusively owned by the metadata accordion and has no other callers. It moves into
`TerminalSessionMetadataView` as `@State private var expandedSessions`.

`header(for:)` uses a `stateColor(for:)` private helper that also appears in `sessionTabs`.
Keep a copy in each file (it is a 6-line pure function).

**New files:**
- `ProSSHMac/UI/Terminal/TerminalSessionHeaderView.swift`
- `ProSSHMac/UI/Terminal/TerminalSessionMetadataView.swift`

Both use `@EnvironmentObject` for `sessionManager` and `portForwardingManager` — no init
injection needed since those are already in the environment chain inherited from `TerminalView`.

### Steps (12 steps)

- [x] **2.1** Read `TerminalView.swift` lines 364–476 (sessionMetadata + metadataRow) and lines 1451–1500 (header) in full before starting.
- [x] **2.2** Create `ProSSHMac/UI/Terminal/TerminalSessionHeaderView.swift`. Header: `// Extracted from TerminalView.swift`. Imports: `import SwiftUI`.
- [x] **2.3** Write `struct TerminalSessionHeaderView: View` with `let session: Session`. Body = exact content of `header(for: session)`. Add `private func stateColor(for state: SessionState) -> Color` as a private helper (copy verbatim).
- [x] **2.4** Create `ProSSHMac/UI/Terminal/TerminalSessionMetadataView.swift`. Header: `// Extracted from TerminalView.swift`. Imports: `import SwiftUI`.
- [x] **2.5** Write `struct TerminalSessionMetadataView: View` with: `let session: Session`, `@EnvironmentObject private var sessionManager: SessionManager`, `@EnvironmentObject private var portForwardingManager: PortForwardingManager`, `@State private var expandedSessions: Set<UUID> = []`.
- [x] **2.6** Copy the body of `sessionMetadata(for:)` as the `body` property of the new struct. Replace every reference to `expandedMetadataSessions` with `expandedSessions`.
- [x] **2.7** Copy `metadataRow(label:value:)` as a `private func` inside `TerminalSessionMetadataView`.
- [x] **2.8** In `TerminalView.swift`: delete `@State private var expandedMetadataSessions: Set<UUID> = []`.
- [x] **2.9** In `TerminalView.swift` `sessionPanel` function: replace `sessionMetadata(for: session)` call with `TerminalSessionMetadataView(session: session)`. Replace `header(for: session)` call with `TerminalSessionHeaderView(session: session)`.
- [x] **2.10** In `TerminalView.swift`: delete `sessionMetadata(for:)`, `metadataRow(label:value:)`, and `header(for:)` function bodies entirely. Delete `stateColor(for:)` — confirmed only used in `header(for:)` (no remaining call sites in TerminalView.swift).
- [x] **2.11** Run build: `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build`. Verify `** BUILD SUCCEEDED **`. ✓
- [x] **2.12** Commit: `refactor(RefactorTV Phase 2): extract session header + metadata views`

**Actual TerminalView.swift line count after phase:** 2,874 lines (expected ~2,910 ✓)

---

## Phase 3 — Extract `TerminalSearchBarView`

### Plan

The `searchBar` computed property (lines 1902–1970) renders the search query field, regex/case
toggles, match navigation buttons, and result count. Three companion computed properties
(`searchQueryBinding`, `searchRegexBinding`, `searchCaseSensitiveBinding` at lines 2658–2677)
are exclusively used by `searchBar` and move with it.

The `@FocusState private var isSearchFieldFocused: Bool` (line 41) belongs to the search bar
and must move into `TerminalSearchBarView`. However, `showSearchBar()` in `TerminalView` needs
to trigger focus on that field. The bridge: add `@State private var searchFocusNonce: Int = 0`
to `TerminalView`. Pass `focusFieldNonce: Int` to the child view. In the child, `.onChange(of:
focusFieldNonce) { isFieldFocused = true }`. This is the exact same pattern as
`directInputActivationNonce` already used in the file.

Also: `shouldEnableDirectTerminalInput(for:)` checks `isSearchFieldFocused`. After extraction,
add an `onFocusChanged: (Bool) -> Void` callback to `TerminalSearchBarView`. Add `@State private
var isSearchBarFocused: Bool = false` to `TerminalView`. Pass `onFocusChanged: { v in
isSearchBarFocused = v }`. Update `shouldEnableDirectTerminalInput` to check `isSearchBarFocused`.

**New file:** `ProSSHMac/UI/Terminal/TerminalSearchBarView.swift`

### Steps (12 steps)

- [x] **3.1** Read `TerminalView.swift` lines 1902–1970 and 2658–2677 in full before starting.
- [x] **3.2** Create `ProSSHMac/UI/Terminal/TerminalSearchBarView.swift`. Header: `// Extracted from TerminalView.swift`. Imports: `import SwiftUI`.
- [x] **3.3** Write `struct TerminalSearchBarView: View` with:
  - `@ObservedObject var terminalSearch: TerminalSearch`
  - `let focusFieldNonce: Int`
  - `var onHide: () -> Void`
  - `var onFocusChanged: (Bool) -> Void`
  - `@FocusState private var isFieldFocused: Bool`
- [x] **3.4** In body: add `.onChange(of: focusFieldNonce) { _, _ in isFieldFocused = true }`. Add `.onChange(of: isFieldFocused) { _, v in onFocusChanged(v) }`.
- [x] **3.5** Copy the content of `searchBar` as the `body`. Replace `isSearchFieldFocused` with `isFieldFocused`, `$isSearchFieldFocused` with `$isFieldFocused`, and `hideSearchBar()` calls with `onHide()`. Move the three binding helper vars (`searchQueryBinding`, etc.) as `private var` computed properties inside the struct.
- [x] **3.6** In `TerminalView.swift`: remove `@FocusState private var isSearchFieldFocused: Bool`.
- [x] **3.7** In `TerminalView.swift`: add `@State private var searchFocusNonce: Int = 0` and `@State private var isSearchBarFocused: Bool = false`.
- [x] **3.8** In `TerminalView.swift` `sessionPanel`: replace the `if includeSearch, terminalSearch.isPresented { searchBar }` block with:
  ```swift
  if includeSearch, terminalSearch.isPresented {
      TerminalSearchBarView(
          terminalSearch: terminalSearch,
          focusFieldNonce: searchFocusNonce,
          onHide: { hideSearchBar() },
          onFocusChanged: { v in isSearchBarFocused = v }
      )
  }
  ```
- [x] **3.9** Rewrite `showSearchBar()` in `TerminalView.swift`: replace `isSearchFieldFocused = true` with `searchFocusNonce &+= 1`.
- [x] **3.10** Rewrite `hideSearchBar()` in `TerminalView.swift`: remove `isSearchFieldFocused = false` (the child manages its own focus).
- [x] **3.11** In `shouldEnableDirectTerminalInput(for:)`: replace `isSearchFieldFocused` check with `isSearchBarFocused`. Delete `searchBar`, `searchQueryBinding`, `searchRegexBinding`, `searchCaseSensitiveBinding` from `TerminalView.swift`.
- [x] **3.12** Run build: `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build`. Verify `** BUILD SUCCEEDED **`. ✓ Commit: `refactor(RefactorTV Phase 3): extract search bar to TerminalSearchBarView`

**Actual TerminalView.swift line count after phase:** 2,787 lines (expected ~2,835 ✓)

---

## Phase 4 — Extract `TerminalSessionActionsBar`

### Plan

The `terminalActions(for:)` function (lines 2049–2157) renders the action toolbar at the bottom
of each session panel: Clear, Record/Stop, Playback menu (with speed options and export), Display
toggle (Metal/Classic), Disconnect/Close, and Restart Shell (local only). It reads:
- `sessionManager` (recording state via `@Published` properties)
- `@AppStorage("terminal.renderer.useMetal")` — re-declare directly in the new view
- `isMetalRendererAvailable`, `isMetalRendererToggleEnabled` — copy as private computed vars
- `@Environment(\.openWindow)` — for pop-out window action

The only callback needed is `onRestartLocal: (Session) -> Void` because `restartLocalSession`
in `TerminalView` closes and reopens the local shell tab — it also calls `tabManager` which is
a `@StateObject` in `TerminalView`. All other actions call `sessionManager` directly (accessible
via `@EnvironmentObject`).

**New file:** `ProSSHMac/UI/Terminal/TerminalSessionActionsBar.swift`

### Steps (7 steps)

- [x] **4.1** Read `TerminalView.swift` lines 2049–2157 in full before starting. Note all `sessionManager` call sites and any references to `TerminalView` state.
- [x] **4.2** Create `ProSSHMac/UI/Terminal/TerminalSessionActionsBar.swift`. Header: `// Extracted from TerminalView.swift`. Imports: `import SwiftUI`, `import Metal`.
- [x] **4.3** Write `struct TerminalSessionActionsBar: View` with:
  - `let session: Session`
  - `@EnvironmentObject private var sessionManager: SessionManager`
  - `@AppStorage("terminal.renderer.useMetal") private var useMetalRenderer = true`
  - `@Environment(\.openWindow) private var openWindow`
  - `var onRestartLocal: (Session) -> Void`
  - Private `isMetalRendererAvailable: Bool` and `isMetalRendererToggleEnabled: Bool` computed vars (copy verbatim).
- [x] **4.4** Copy the content of `terminalActions(for:)` as the `body`. Replace `restartLocalSession(session)` call with `onRestartLocal(session)`.
- [x] **4.5** In `TerminalView.swift` `sessionPanel`: replace `terminalActions(for: session)` with:
  ```swift
  TerminalSessionActionsBar(session: session, onRestartLocal: { s in restartLocalSession(s) })
  ```
- [x] **4.6** Delete `terminalActions(for:)` from `TerminalView.swift`. Do NOT delete `isMetalRendererAvailable`, `isMetalRendererToggleEnabled`, or the `useMetalRenderer` `@AppStorage` from `TerminalView` — they are still used in `terminalSurface` and `terminalLifecycleView`.
- [x] **4.7** Run build: `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build`. Verify `** BUILD SUCCEEDED **`. Commit: `refactor(RefactorTV Phase 4): extract session actions toolbar to TerminalSessionActionsBar`

**Expected TerminalView.swift line count after phase:** ~2,725

---

## Phase 5 — Extract `TerminalSessionTabBar`

### Plan

The `sessionTabs` computed property (lines 789–948) renders the horizontal tab bar with per-tab
status indicators, pin badge, legacy-crypto shield, agent-forwarding indicator, dynamic window
title, CWD display, hover-reveal close button, drag-drop reordering, context menus, and the
"+" new-session menu. It also uses `tabBackground(for:)` (lines 2447–2452) which is only called
from within `sessionTabs` — move it.

The `@State private var hoveredTabID: UUID?` (line 61) is exclusively used by `sessionTabs`
(hover reveal of the close button) and moves into the new view.

The new view receives `tabManager` and `paneManager` as `@ObservedObject` (passed from
`TerminalView`). For actions that need `TerminalView`-level logic, use callbacks:
- `onRequestClose: (Session) -> Void` → `requestCloseSession(session)`
- `onOpenLocalTerminal: () -> Void` → `openLocalTerminal()`
- `onSplitWithExisting: (UUID, UUID, SplitDirection) -> Void` → `splitWithExistingSession`

Tab selection, pinning, and reordering call `tabManager` directly (no callback needed).
`navigationCoordinator` can be accessed via `@EnvironmentObject`.

**New file:** `ProSSHMac/UI/Terminal/TerminalSessionTabBar.swift`

### Steps (8 steps)

- [ ] **5.1** Read `TerminalView.swift` lines 789–948 and 2447–2452 in full before starting.
- [ ] **5.2** Create `ProSSHMac/UI/Terminal/TerminalSessionTabBar.swift`. Header: `// Extracted from TerminalView.swift`. Imports: `import SwiftUI`.
- [ ] **5.3** Write `struct TerminalSessionTabBar: View` with:
  - `@ObservedObject var tabManager: SessionTabManager`
  - `@ObservedObject var paneManager: PaneManager`
  - `@EnvironmentObject private var sessionManager: SessionManager`
  - `@EnvironmentObject private var navigationCoordinator: AppNavigationCoordinator`
  - `@Environment(\.openWindow) private var openWindow`
  - `@Environment(\.colorScheme) private var colorScheme`
  - `var onRequestClose: (Session) -> Void`
  - `var onOpenLocalTerminal: () -> Void`
  - `var onSplitWithExisting: (UUID, UUID, SplitDirection) -> Void`
  - `@State private var hoveredTabID: UUID?`
  - `private func tabBackground(for sessionID: UUID) -> Color` (copy verbatim)
- [ ] **5.4** Copy the content of `sessionTabs` as the `body`. All call sites already use `tabManager` directly; only the three action callbacks need wiring.
- [ ] **5.5** In `TerminalView.swift`: remove `@State private var hoveredTabID: UUID?`.
- [ ] **5.6** In `TerminalView.swift` `macOSBody`: replace all `sessionTabs` call sites (there may be 2: the split-pane path and the single-session path) with:
  ```swift
  TerminalSessionTabBar(
      tabManager: tabManager,
      paneManager: paneManager,
      onRequestClose: { s in requestCloseSession(s) },
      onOpenLocalTerminal: { openLocalTerminal() },
      onSplitWithExisting: { sid, pid, dir in splitWithExistingSession(sid, beside: pid, direction: dir) }
  )
  ```
- [ ] **5.7** Delete `sessionTabs` and `tabBackground(for:)` from `TerminalView.swift`. Verify `tabBackground` has no remaining callers in `TerminalView.swift`.
- [ ] **5.8** Run build: `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build`. Verify `** BUILD SUCCEEDED **`. Commit: `refactor(RefactorTV Phase 5): extract tab bar to TerminalSessionTabBar`

**Expected TerminalView.swift line count after phase:** ~2,560

---

## Phase 6 — Extract `TerminalQuickCommandPanel`

### Plan

The quick command subsystem spans lines 1028–1449 and owns 12 `@State` draft-editing properties
(lines 44–55). It includes: the scrim overlay, slide-in drawer, drawer header (import/export/new
buttons), target session display, snippet list with edit/delete buttons, snippet editor sheet,
variable input sheet, file importer for JSON import, and all execution logic.

The `quickCommands: QuickCommands` `@StateObject` stays in `TerminalView` (the keyboard shortcut
layer calls `quickCommands.toggleDrawer()` directly). Pass it into `TerminalQuickCommandPanel` as
`@ObservedObject`. All 12 `@State` draft-editing vars move into the panel.

The panel's execution requires sending shell commands. Pass `onSendShellInput: (UUID, String) ->
Void` as a callback to avoid a direct `sessionManager` import in the panel (though
`@EnvironmentObject sessionManager` is also acceptable — use whichever is cleaner at
implementation time).

Three sheet/importer modifiers currently on `TerminalView.body` move into the panel's `body`.

**New file:** `ProSSHMac/UI/Terminal/TerminalQuickCommandPanel.swift`

### Steps (13 steps)

- [ ] **6.1** Read `TerminalView.swift` lines 1028–1449 in full. Read `Terminal/Features/QuickCommands.swift` in full to understand the `QuickCommands` API (methods called: `toggleDrawer()`, `dismissDrawer()`, `presentDrawer()`, `isDrawerPresented`, `snippets`, `addSnippet`, `updateSnippet`, `deleteSnippet`, `importLibrary`, `exportLibrary`).
- [ ] **6.2** Create `ProSSHMac/UI/Terminal/TerminalQuickCommandPanel.swift`. Header: `// Extracted from TerminalView.swift`. Imports: `import SwiftUI`, `import UniformTypeIdentifiers`.
- [ ] **6.3** Write `struct TerminalQuickCommandPanel: View` with:
  - `@ObservedObject var quickCommands: QuickCommands`
  - `var selectedSession: Session?`
  - `var onSendShellInput: (UUID, String) -> Void`
  - All 12 `@State` quick-command draft properties (from lines 44–55 of `TerminalView`)
- [ ] **6.4** `body`: a `ZStack(alignment: .trailing)` containing scrim + `quickCommandDrawerLayer`. Apply `.sheet(isPresented: $isQuickCommandEditorPresented)`, `.sheet(item: $quickCommandPendingSnippet)`, and `.fileImporter(isPresented: $isQuickCommandImportPresented, ...)` modifiers. Wrap in `.animation(.easeInOut(duration: 0.2), value: quickCommands.isDrawerPresented)`.
- [ ] **6.5** Copy all helper view properties and functions: `quickCommandDrawerLayer`, `quickCommandDrawer(width:)`, `quickCommandDrawerHeader`, `quickCommandDrawerTarget`, `quickCommandDrawerBody`, `quickCommandSnippetRow(_:)`, `quickCommandVisibleSnippets`, `quickCommandEditorSheet`, `quickCommandVariableSheet(for:)`, `quickCommandDraftVariableNames`, `quickCommandDraftCanSave`, `quickCommandDraftDefaultBinding(for:)`, `presentQuickCommandEditor(for:)`, `saveQuickCommandFromDraft()`, `runQuickCommandSnippet(_:)`, `sendQuickCommand(snippet:values:)`, `exportQuickCommandLibrary()`, `handleQuickCommandImport(result:)`.
- [ ] **6.6** Replace `sendQuickCommand`'s `sessionManager.sendShellInput(...)` call with `onSendShellInput(sessionID, command)`.
- [ ] **6.7** In `TerminalView.swift body`: remove `.sheet(isPresented: $isQuickCommandEditorPresented)`, `.sheet(item: $quickCommandPendingSnippet)`, and `.fileImporter(isPresented: $isQuickCommandImportPresented, ...)` modifier blocks.
- [ ] **6.8** In `TerminalView.swift terminalBaseView`: replace the two `.overlay` blocks for `quickCommandScrim` and `quickCommandDrawerLayer` with:
  ```swift
  .overlay(alignment: .trailing) {
      TerminalQuickCommandPanel(
          quickCommands: quickCommands,
          selectedSession: selectedSession,
          onSendShellInput: { sid, input in
              Task { await sessionManager.sendShellInput(sessionID: sid, input: input) }
          }
      )
  }
  ```
  Remove the existing `.animation` modifier for quick command drawer (now inside the panel).
- [ ] **6.9** Delete all 12 `@State` quick-command draft properties from `TerminalView.swift`.
- [ ] **6.10** Delete from `TerminalView.swift`: `quickCommandScrim`, `quickCommandDrawerLayer`, `quickCommandDrawer(width:)`, and all other quick-command functions/properties listed in step 6.5.
- [ ] **6.11** Verify `terminalShortcutLayer` still calls `quickCommands.toggleDrawer()` / `quickCommands.presentDrawer()` — these work because `quickCommands` is still a `@StateObject` in `TerminalView` and is passed into both the panel and the shortcut layer.
- [ ] **6.12** Run build: `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build`. Verify `** BUILD SUCCEEDED **`.
- [ ] **6.13** Commit: `refactor(RefactorTV Phase 6): extract quick command panel to TerminalQuickCommandPanel`

**Expected TerminalView.swift line count after phase:** ~2,140

---

## Phase 7 — Extract `TerminalFileBrowserSidebar`

### Plan

The file browser sidebar owns the largest contiguous block of state in `TerminalView`:
10 `@State` properties (lines 63–72) plus ~215 lines of SFTP loading and tree-building logic
(lines 2188–2445) plus ~160 lines of UI (lines 624–787). Collectively ~485 lines.

The key architectural insight: all file browser state is exclusively accessed within the
file browser subsystem. No other part of `TerminalView` reads `fileBrowserRows`,
`fileBrowserExpandedPaths`, etc. So all 10 `@State` properties move cleanly into the new view.

Session switching is handled by `.onChange(of: session?.id)` inside the new view — it resets
internal state and reloads the root directory when the session changes. This replaces the
`syncFileBrowserSession()` function in `TerminalView` (which becomes trivially small or is
deleted and inlined).

`onSendShellInput: (UUID, String) -> Void` callback handles "open file in terminal" (which
sends an editor command to the shell). File downloads delegate to `transferManager` directly
via `@EnvironmentObject`.

Before starting: read `Terminal/Features/TerminalFileBrowserTree.swift` to understand the
static API (`normalize`, `parent`, `join`, etc.) already extracted in Phase 3 of the prior
refactor.

**New file:** `ProSSHMac/UI/Terminal/TerminalFileBrowserSidebar.swift`

### Steps (10 steps)

- [ ] **7.1** Read `TerminalView.swift` lines 624–787 (sidebar UI + row renderer) and 2188–2445 (state management) in full. Read `Terminal/Features/TerminalFileBrowserTree.swift` to understand the helper API.
- [ ] **7.2** Create `ProSSHMac/UI/Terminal/TerminalFileBrowserSidebar.swift`. Header: `// Extracted from TerminalView.swift`. Imports: `import SwiftUI`.
- [ ] **7.3** Write `struct TerminalFileBrowserSidebar: View` with:
  - `var session: Session?`
  - `@EnvironmentObject private var sessionManager: SessionManager`
  - `@EnvironmentObject private var transferManager: TransferManager`
  - `var onClose: () -> Void`
  - `var onSendShellInput: (UUID, String) -> Void`
  - All 10 `@State` file-browser properties from lines 63–72 of `TerminalView`
- [ ] **7.4** `body`: the content of `fileBrowserSidebar` (lines 624–716), using `session` in place of `selectedSession`.
- [ ] **7.5** Copy `fileBrowserRow(_:session:)` as a private function. Copy all loading/navigation helpers: `initialFileBrowserRootPath(for:)`, `downloadFileBrowserFile(_:)`, `openFileInTerminal(_:editor:)`, `shellEscapeForTerminal(_:)`, `byteCount(_:)`, `navigateUpFileBrowserRoot(for:)`, `refreshFileBrowserRoot(for:)`, `loadFileBrowserRoot(for:path:)`, `toggleFileBrowserDirectory(_:for:)`, `collapseFileBrowserDirectory(_:)`, `loadFileBrowserDirectory(path:for:isRoot:)`, `listFileBrowserEntries(for:path:)`, `rebuildFileBrowserRows()`, `fileBrowserContainsPath(_:)`, `normalizeFileBrowserPath(_:isLocal:)`, `parentFileBrowserPath(of:isLocal:)`.
- [ ] **7.6** Replace `openFileInTerminal` terminal-send calls with `onSendShellInput(session.id, command)`.
- [ ] **7.7** Add `.onChange(of: session?.id) { _, _ in resetAndReload() }` to the body. Write `private func resetAndReload()` that clears all 10 state vars to defaults and calls `loadFileBrowserRoot` if session is connected.
- [ ] **7.8** In `TerminalView.swift terminalContentWithFileBrowser`: replace `fileBrowserSidebar` with:
  ```swift
  TerminalFileBrowserSidebar(
      session: selectedSession,
      onClose: { showFileBrowser = false },
      onSendShellInput: { sid, input in
          Task { await sessionManager.sendShellInput(sessionID: sid, input: input) }
      }
  )
  ```
- [ ] **7.9** In `TerminalView.swift`: delete all 10 `@State fileBrowser*` properties. Delete `fileBrowserSidebar`, `fileBrowserRow(_:session:)`, `syncFileBrowserSession()`, `initialFileBrowserRootPath(for:)`, and all file-browser helper functions listed in step 7.5. Simplify any `onChange(showFileBrowser)` that called `syncFileBrowserSession()` to just `transferManager.setActiveSession(showFileBrowser ? selectedSession : nil)` if applicable (or remove if the sidebar handles it).
- [ ] **7.10** Run build: `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build`. Verify `** BUILD SUCCEEDED **`. Commit: `refactor(RefactorTV Phase 7): extract file browser sidebar to TerminalFileBrowserSidebar`

**Expected TerminalView.swift line count after phase:** ~1,665

---

## Phase 8 — Extract `TerminalSurfaceView`

### Plan

This is the most complex extraction. `terminalSurface(for:isFocused:paneID:)` (lines 1502–1518)
dispatches among three rendering paths: safe (`safeTerminalBuffer`), Metal
(`metalTerminalBuffer`), and classic SwiftUI (`terminalBuffer` + `terminalLineView`). These
paths touch: bell effects, resize effects, scroll indicator, search highlights, mouse input
overlay, link detection, context menus, selection coordinator, and drag-drop for file paths.

The `SafeTerminalRenderedLine` and both `PreferenceKey` structs were moved in Phase 1 and are
accessible as internal types.

**State and controllers passed in as `@ObservedObject`:** `bellEffect`, `resizeEffect`,
`selectionCoordinator`, `terminalSearch` (all remain `@StateObject` in `TerminalView`).

**`@AppStorage` keys** are re-declared directly in the new view (SwiftUI keeps them synced).

**Callbacks:**
- `onFocusTap: () -> Void` — `focusSessionAndPane(session.id, paneID: paneID)`
- `onPaste: (UUID) -> Void` — `pasteClipboardToSession`
- `onCopy: (UUID) -> Bool` — `copyContentToClipboard`
- `onSplitWithExisting: (UUID, UUID, SplitDirection) -> Void`

`inputModeSnapshot(for:)` — copy it into `TerminalSurfaceView` as a private helper. Also keep
it in `TerminalView` (needed by `hardwareKeyEncoderOptions` and `handleDirectTerminalInput`).

Note: `isMacOSTerminalSafetyModeEnabled` is hardcoded `false` — the safe renderer path is dead
code. It is moved anyway for completeness; it will be deleted in a future cleanup.

The `directTerminalInputOverlay` stays in `TerminalView` (it is applied at the `sessionPanel`
level as a separate overlay, not inside the surface).

**New file:** `ProSSHMac/UI/Terminal/TerminalSurfaceView.swift`

### Steps (11 steps)

- [ ] **8.1** Read `TerminalView.swift` lines 1502–1900 (all surface functions) and 2637–2701 (mouse overlay + attributedLine helpers) in full before starting.
- [ ] **8.2** Create `ProSSHMac/UI/Terminal/TerminalSurfaceView.swift`. Header: `// Extracted from TerminalView.swift`. Imports: `import SwiftUI`, `import Metal`.
- [ ] **8.3** Write `struct TerminalSurfaceView: View` with:
  - `let session: Session`
  - `let isFocused: Bool`
  - `let paneID: UUID?`
  - `@ObservedObject var bellEffect: BellEffectController`
  - `@ObservedObject var resizeEffect: ResizeEffectController`
  - `@ObservedObject var selectionCoordinator: TerminalSelectionCoordinator`
  - `@ObservedObject var terminalSearch: TerminalSearch`
  - `@EnvironmentObject private var sessionManager: SessionManager`
  - `@Environment(\.colorScheme) private var colorScheme`
  - `@Environment(\.openWindow) private var openWindow`
  - Re-declared `@AppStorage` for fontSize, fontFamily, useMetal, backgroundOpacity, bellFeedback
  - `var onFocusTap: () -> Void`
  - `var onPaste: (UUID) -> Void`
  - `var onCopy: (UUID) -> Bool`
  - `var onSplitWithExisting: (UUID, UUID, SplitDirection) -> Void`
  - `private let linkDetector = LinkDetector()`
- [ ] **8.4** `body` = the content of `terminalSurface(for:isFocused:paneID:)`, dispatching among the three render paths.
- [ ] **8.5** Copy all rendering functions verbatim: `safeTerminalBuffer(for:)`, `safeTerminalDisplayLines(for:)`, `metalTerminalBuffer(for:isFocused:paneID:)`, `terminalSurfaceContextMenu(for:)`, `terminalBuffer(for:)`, `terminalLineView(_:lineIndex:)`, `mouseInputOverlay(for:contentPadding:)`, `attributedTerminalLine(_:lineIndex:)`, `terminalCellCoordinates(from:contentPadding:)`, `isMouseTrackingEnabled(for:)`. Copy `inputModeSnapshot(for:)` as a private func.
- [ ] **8.6** Copy `terminalSurfaceColor`, `terminalSurfaceBorderColor`, `supportsMetalTerminalSurface`, `isMacOSTerminalSafetyModeEnabled` as private computed vars.
- [ ] **8.7** Fix call sites in the copied code: `copyContentToClipboard(sessionID:)` → `onCopy(sessionID)`, `pasteClipboardToSession(_:)` → `onPaste(sessionID)`, tap-to-focus → `onFocusTap()`, `splitWithExistingSession(...)` → `onSplitWithExisting(...)`.
- [ ] **8.8** In `TerminalView.swift sessionPanel`: replace `terminalSurface(for: session, isFocused: isFocused, paneID: paneID)` with:
  ```swift
  TerminalSurfaceView(
      session: session,
      isFocused: isFocused,
      paneID: paneID,
      bellEffect: bellEffect,
      resizeEffect: resizeEffect,
      selectionCoordinator: selectionCoordinator,
      terminalSearch: terminalSearch,
      onFocusTap: { focusSessionAndPane(session.id, paneID: paneID) },
      onPaste: { sid in pasteClipboardToSession(sid) },
      onCopy: { sid in copyContentToClipboard(sessionID: sid) },
      onSplitWithExisting: { sid, pid, dir in splitWithExistingSession(sid, beside: pid, direction: dir) }
  )
  ```
- [ ] **8.9** Delete from `TerminalView.swift`: `terminalSurface(for:isFocused:paneID:)`, `safeTerminalBuffer(for:)`, `safeTerminalDisplayLines(for:)`, `metalTerminalBuffer(for:isFocused:paneID:)`, `terminalSurfaceContextMenu(for:)`, `terminalBuffer(for:)`, `terminalLineView(_:lineIndex:)`, `mouseInputOverlay(for:contentPadding:)`, `attributedTerminalLine(_:lineIndex:)`, `terminalCellCoordinates(from:contentPadding:)`, `isMouseTrackingEnabled(for:)`, `terminalSurfaceColor`, `terminalSurfaceBorderColor`, `supportsMetalTerminalSurface`, `isMacOSTerminalSafetyModeEnabled`. Keep `inputModeSnapshot(for:)` in `TerminalView.swift`.
- [ ] **8.10** Run build: `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build`. Verify `** BUILD SUCCEEDED **`.
- [ ] **8.11** Commit: `refactor(RefactorTV Phase 8): extract terminal surface rendering to TerminalSurfaceView`

**Expected TerminalView.swift line count after phase:** ~1,235

---

## Phase 9 — Extract `TerminalSidebarLayoutStore` + `TerminalKeyboardShortcutLayer`, Final Cleanup

### Plan

Two final extractions plus dead-code removal:

**A. `TerminalSidebarLayoutStore`** — A `caseless enum` (static-method namespace, same pattern
as `AIToolDefinitions` from Phase 6 of the prior refactor) containing the 4 sidebar layout
persistence helpers: `contextKey(for:)`, `storageKey(_:context:)`, `restore(for:...)`,
`persist(for:...)`. The 4 `@State` variables related to sidebar persistence
(`loadedSidebarLayoutContextKey`, `isApplyingSidebarLayout`) stay in `TerminalView`; only the
helper logic moves. Function stubs remain in `TerminalView` as one-line delegates.

**B. `TerminalKeyboardShortcutLayer`** — A pure view struct containing the `terminalShortcutLayer`
computed property (~130 lines). It is essentially a `Group` of `Button` views with no state;
all actions become callback closures. This is the single largest remaining computed view
property in `TerminalView`.

**C. Dead code removal** — Delete `splitPaneBody` (lines 950–988) which is never called by any
code path in the file. Verify by searching for all call sites before deleting.

After Phase 9: check line count. If `TerminalView.swift` is below 400 lines, remove
`// swiftlint:disable file_length` from line 1. (Expected: ~1,100 lines — keep the directive.)

**New files:**
- `ProSSHMac/UI/Terminal/TerminalSidebarLayoutStore.swift`
- `ProSSHMac/UI/Terminal/TerminalKeyboardShortcutLayer.swift`

### Steps (14 steps)

- [ ] **9.1** Read `TerminalView.swift` lines 485–545 (sidebar layout helpers) and 2492–2623 (shortcut layer) and 950–988 (splitPaneBody) in full before starting.
- [ ] **9.2** Create `ProSSHMac/UI/Terminal/TerminalSidebarLayoutStore.swift`. Header: `// Extracted from TerminalView.swift`. Imports: `import Foundation`, `import SwiftUI`.
- [ ] **9.3** Write `enum TerminalSidebarLayoutStore` (caseless — prevents Swift 6 `@MainActor` inference on static methods) with static methods: `contextKey(for session: Session) -> String`, `storageKey(_ suffix: String, context: String) -> String`, `restore(for session: Session, showFileBrowser: inout Bool, fileBrowserWidth: inout Double, showAIAssistant: inout Bool, aiAssistantWidth: inout Double, loadedContextKey: inout String?, isApplying: inout Bool)`, `persist(for session: Session, showFileBrowser: Bool, fileBrowserWidth: Double, showAIAssistant: Bool, aiAssistantWidth: Double)`. Copy logic verbatim from `TerminalView`.
- [ ] **9.4** In `TerminalView.swift`: replace the bodies of `sidebarLayoutContextKey(for:)`, `sidebarLayoutStorageKey(_:context:)`, `restoreSidebarLayoutForSelection()`, `persistSidebarLayoutForSelection()` with one-line delegate calls to `TerminalSidebarLayoutStore`. Keep the function stubs (they are called from `onChange` handlers).
- [ ] **9.5** Create `ProSSHMac/UI/Terminal/TerminalKeyboardShortcutLayer.swift`. Header: `// Extracted from TerminalView.swift`. Imports: `import SwiftUI`.
- [ ] **9.6** Write `struct TerminalKeyboardShortcutLayer: View` with callback properties for every keyboard action:
  - `var onSendSelectedCommand: () -> Void`
  - `var onClearBuffer: () -> Void`
  - `var onShowSearch: () -> Void`
  - `var onToggleQuickCommands: () -> Void`
  - `var onToggleFileBrowser: () -> Void`
  - `var onToggleAIAssistant: () -> Void`
  - `var onStepSession: (Int) -> Void`
  - `var onDisconnectOrClose: () -> Void`
  - `var onSplitRight: () -> Void`
  - `var onSplitDown: () -> Void`
  - `var onFocusNextPane: () -> Void`
  - `var onFocusPreviousPane: () -> Void`
  - `var onMaximizePane: () -> Void`
  - `var onNewLocalTerminal: () -> Void`
  - `var onZoom: (Double) -> Void`
  - `var onCopy: () -> Void`
  - `var onPaste: () -> Void`
  - `var onSelectAll: () -> Void`
  - `var onSendControl: (String) -> Void`
  - `var onToggleFullscreen: () -> Void`
- [ ] **9.7** `body` = the content of `terminalShortcutLayer` verbatim, replacing every lambda body with the appropriate callback.
- [ ] **9.8** In `TerminalView.swift terminalBaseView`: replace `.background(terminalShortcutLayer)` (or however it is applied) with:
  ```swift
  .background(
      TerminalKeyboardShortcutLayer(
          onSendSelectedCommand: { sendSelectedCommandShortcut() },
          onClearBuffer: { clearSelectedBuffer() },
          onShowSearch: { showSearchBar() },
          onToggleQuickCommands: { quickCommands.toggleDrawer() },
          onToggleFileBrowser: { showFileBrowser.toggle() },
          onToggleAIAssistant: { showAIAssistant.toggle() },
          onStepSession: { stepSelectedSession(by: $0) },
          onDisconnectOrClose: { disconnectOrCloseSelectedSession() },
          onSplitRight: { splitNextAvailableSession(direction: .horizontal) },
          onSplitDown: { splitNextAvailableSession(direction: .vertical) },
          onFocusNextPane: { paneManager.focusNext() },
          onFocusPreviousPane: { paneManager.focusPrevious() },
          onMaximizePane: { paneManager.toggleMaximize(paneManager.focusedPaneId) },
          onNewLocalTerminal: { openLocalTerminal() },
          onZoom: { adjustTerminalFontSize(by: $0) },
          onCopy: { copyActiveContentToClipboard() },
          onPaste: { if let sid = selectedSession?.id { pasteClipboardToSession(sid) } },
          onSelectAll: { selectAllInFocusedTerminal() },
          onSendControl: { sendControl($0) },
          onToggleFullscreen: { /* fullscreen toggle action */ }
      )
  )
  ```
- [ ] **9.9** Delete `terminalShortcutLayer` from `TerminalView.swift`.
- [ ] **9.10** Search `TerminalView.swift` for all references to `splitPaneBody`. Verify it has zero call sites. Delete the entire `splitPaneBody` computed property.
- [ ] **9.11** Check the final line count of `TerminalView.swift`. Record here: ___. If below 400 lines, remove `// swiftlint:disable file_length` from line 1. (Expected ~1,100 — keep directive.)
- [ ] **9.12** Update the `► CURRENT STATE` block at the top of this file to reflect Phase 9 COMPLETE.
- [ ] **9.13** Run build: `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build`. Verify `** BUILD SUCCEEDED **`.
- [ ] **9.14** Commit: `refactor(RefactorTV Phase 9): extract sidebar layout store + keyboard shortcut layer, remove dead code`

**Expected TerminalView.swift line count after phase:** ~1,100

---

## Final Step — Full Test Suite

After all 9 phases are committed and the build is clean:

- [ ] **T.1** Run full test suite: `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' test`
- [ ] **T.2** Compare failure count to pre-refactor baseline. Expected: same pre-existing failures only (color rendering + mouse encoding — historically 12–23 failures). No new failures.
- [ ] **T.3** If new failures appear: investigate root cause. Do NOT mark refactor complete until all new failures are resolved.
- [ ] **T.4** Update `CLAUDE.md`: mark TerminalView refactor COMPLETE in the phase table, add a Refactor Log entry.
- [ ] **T.5** Update `docs/featurelist.md` with a dated loop-log entry describing the completed refactor.
- [ ] **T.6** Commit: `docs: TerminalView refactor complete — update CLAUDE.md and featurelist.md`

---

## Refactor Log (most recent first)

- **2026-02-24 — Phase 4 COMPLETE** (commit TBD): Extracted `terminalActions(for:)` (~108 lines)
  into `TerminalSessionActionsBar.swift`. `onRestartLocal: (Session) -> Void` callback replaces
  the direct `restartLocalSession(session)` call (which required `tabManager` `@StateObject`).
  `useMetalRenderer` `@AppStorage` re-declared in child (same key, rule 7). `isMetalRendererAvailable`
  and `isMetalRendererToggleEnabled` copied as private computed vars in child.
  `isMetalRendererToggleEnabled` deleted from `TerminalView` (sole caller was `terminalActions`).
  `isMetalRendererAvailable` retained in `TerminalView` (used in `supportsMetalTerminalSurface` + `.onAppear`).
  `TerminalView.swift`: 2,787 → 2,673 lines (−114). Build: `** BUILD SUCCEEDED **`, 0 new warnings.

- **2026-02-24 — Phase 3 COMPLETE** (commit `7bc5e1e`): Extracted `searchBar` computed property and its
  three companion binding helpers (`searchQueryBinding`, `searchRegexBinding`,
  `searchCaseSensitiveBinding`) into `TerminalSearchBarView.swift` (~115 lines). Bridged the
  `@FocusState` boundary with the `searchFocusNonce: Int` pattern (same as `directInputActivationNonce`).
  Added `onFocusChanged: (Bool) -> Void` callback so `shouldEnableDirectTerminalInput(for:)` can
  still gate on search-field focus via `isSearchBarFocused: Bool` in `TerminalView`. Color helpers
  (`terminalSurfaceColor`, `terminalSurfaceBorderColor`) re-declared in child per rule 7 — both
  share the same `@AppStorage` key and stay in sync automatically. Deleted: `@FocusState` var +
  `var searchBar` + 3 binding helpers + `DispatchQueue.main.async` focus call in `showSearchBar()`.
  `TerminalView.swift`: 2,874 → 2,787 lines (−87). Build: `** BUILD SUCCEEDED **`, 0 new warnings.

- **2026-02-24 — Phase 2 COMPLETE** (commit `524fc9b`): Extracted two display-only view functions from
  `TerminalView`. Created `TerminalSessionHeaderView.swift` (~67 lines) containing `header(for:)`
  body and `stateColor(for:)` private helper. Created `TerminalSessionMetadataView.swift`
  (~116 lines) containing `sessionMetadata(for:)` body, `metadataRow(label:value:)` private helper,
  and `@State private var expandedSessions: Set<UUID> = []` (moved from TerminalView).
  `stateColor(for:)` confirmed only called from `header(for:)` — moved entirely to header file,
  deleted from TerminalView. Plan note "also in sessionTabs" was incorrect.
  Call sites in `sessionPanel(for:)` updated to use new struct types. Deleted: 1 `@State` var +
  4 functions. `TerminalView.swift`: 3,049 → 2,874 lines (−175). Build: `** BUILD SUCCEEDED **`,
  0 new warnings.

- **2026-02-24 — Phase 1 COMPLETE**: Extracted 6 file-scope types that lived after the closing
  brace of `struct TerminalView` into `ProSSHMac/UI/Terminal/TerminalInputCaptureView.swift`
  (380 lines). Types moved: `SafeTerminalRenderedLine` (private→internal), `DirectTerminalInputCaptureView`
  (already internal), `DirectTerminalInputNSView` (already internal), `View.terminalInputBehavior()`
  extension (private→internal), `TerminalScrollOffsetPreferenceKey` (private→internal),
  `TerminalScrollContentHeightPreferenceKey` (private→internal). No call-site changes needed —
  Swift resolves all as module-level internal types. `TerminalView.swift`: 3,426 → 3,049 lines
  (−377). Build: `** BUILD SUCCEEDED **`, 0 new warnings. SourceKit diagnostics in new file are
  expected false positives (project uses cross-file type resolution via PBXFileSystemSynchronizedRootGroup).

- **2026-02-24 — Phase 0 COMPLETE** (commit `60b4f08`): Added `// swiftlint:disable file_length`
  as line 1 of `TerminalView.swift` (3,425 → 3,426 lines after insert). Build verified:
  `** BUILD SUCCEEDED **`, 0 warnings. Baseline established.
