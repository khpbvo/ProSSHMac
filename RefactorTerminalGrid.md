# RefactorTerminalGrid.md — TerminalGrid.swift Decomposition Checklist

This file is the working checklist and run-book for decomposing `TerminalGrid.swift`
(2,311 lines) into focused, maintainable files.

Follow the same workflow as `RefactorTerminalView.md`:
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
Current phase   : Phase 3 — NOT STARTED
Phase status    : NOT STARTED
Immediate action: Begin Phase 3 (extract Tab Stops + Dirty Tracking → TerminalGrid+TabsAndDirty.swift).
Last commit     : <hash> "refactor(RefactorTG Phase 2): extract OSC Handlers to TerminalGrid+OSCHandlers.swift"
```

**Update this block after every phase.**

---

## Phase Status

| Phase | Name | Status |
|-------|------|--------|
| 0 | Baseline — swiftlint:disable + remove all `private` from stored properties | **COMPLETE** (2026-02-24) |
| 1 | Extract Mode Setters → `TerminalGrid+ModeSetters.swift` | **COMPLETE** (2026-02-24) |
| 2 | Extract OSC Handlers → `TerminalGrid+OSCHandlers.swift` | **COMPLETE** (2026-02-24) |
| 3 | Extract Tab Stops + Dirty Tracking → `TerminalGrid+TabsAndDirty.swift` | NOT STARTED |
| 4 | Extract Cursor Movement + Cell R/W → `TerminalGrid+CursorOps.swift` | NOT STARTED |
| 5 | Extract Scrolling → `TerminalGrid+Scrolling.swift` | NOT STARTED |
| 6 | Extract Erasing → `TerminalGrid+Erasing.swift` | NOT STARTED |
| 7 | Extract Line Operations → `TerminalGrid+LineOps.swift` | NOT STARTED |
| 8 | Extract Screen Buffer + Cursor Save/Restore → `TerminalGrid+ScreenBuffer.swift` | NOT STARTED |
| 9 | Extract Lifecycle (Full Reset + Resize) → `TerminalGrid+Lifecycle.swift` | NOT STARTED |
| 10 | Extract Print Character → `TerminalGrid+Printing.swift` | NOT STARTED |
| 11 | Extract Snapshot + Text Extraction → `TerminalGrid+Snapshot.swift` | NOT STARTED |
| — | Full test suite run | NOT STARTED |

---

## Non-Negotiable Rules

1. **Build must pass after every phase** — run `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build` and verify `** BUILD SUCCEEDED **` before committing.
2. **Commit after every phase** — each phase is a self-contained commit.
3. **Header comment on every extracted file** — first non-blank, non-import line must be: `// Extracted from TerminalGrid.swift`
4. **Every new Swift file must pass `-strict-concurrency=complete`** — add the flag temporarily to Other Swift Flags in Xcode, build, fix warnings, then remove the flag before committing.
5. **`// swiftlint:disable file_length`** — added in Phase 0. Remove at the end of Phase 11 if line count is below 400; otherwise keep until it is.
6. **All extractions use `extension TerminalGrid`** — no new types are created. Every extracted file is an extension of the same `nonisolated final class`. File naming: `TerminalGrid+<Concern>.swift`.
7. **Project uses PBXFileSystemSynchronizedRootGroup** — new `.swift` files created on disk in `ProSSHMac/Terminal/Grid/` are auto-detected by Xcode. No manual xcodeproj editing needed.
8. **Read the full phase plan before touching any file** — never start coding a phase without reading all its steps first.
9. **`@inline(__always)` moves with the method** — do not strip it when moving methods to extension files.

---

## Why `extension TerminalGrid` (not new types)

`TerminalGrid` is a `nonisolated final class: @unchecked Sendable` whose entire state is
one tightly coupled blob of grid cells, cursor, mode flags, and rendering metadata. Every
operation reads or writes multiple stored properties. There is no natural seam to extract
a standalone type — the right Swift decomposition is extensions across files, grouping methods
by the VT spec section they implement. This is the idiomatic Swift approach for large
single-responsibility classes.

**Consequence of `extension` extraction:** Swift's `private` access modifier is file-scoped, so
methods in extension files cannot read or write `private` stored properties of the main class.
Phase 0 therefore removes `private` from every stored property and helper function, making them
`internal` (accessible within the module but not beyond it). Thread safety is enforced at the
`TerminalEngine` actor boundary — Swift access control is not load-bearing for correctness here.

---

## Target Directory After All Phases

```
ProSSHMac/Terminal/Grid/
├── TerminalGrid.swift                  (~410 lines — state declarations, init, buffer access,
│                                         grapheme encoding, scrollback getter, helpers)
├── TerminalGrid+ModeSetters.swift      (~233 lines — 29 cross-actor mode-flag setters)
├── TerminalGrid+OSCHandlers.swift      (~85 lines  — window title (OSC 0/1/2) + color palette (OSC 4/10/11/12))
├── TerminalGrid+TabsAndDirty.swift     (~66 lines  — tab stop management + dirty tracking API)
├── TerminalGrid+CursorOps.swift        (~82 lines  — cursor movement commands + cell read/write)
├── TerminalGrid+Scrolling.swift        (~162 lines — scroll up/down (A.6.4) + scroll region (A.6.9))
├── TerminalGrid+Erasing.swift          (~126 lines — erase in line (A.6.5) + erase in display (A.6.6))
├── TerminalGrid+LineOps.swift          (~112 lines — insert/delete characters (A.6.7) + lines (A.6.8))
├── TerminalGrid+ScreenBuffer.swift     (~114 lines — alternate screen buffer (A.6.10) + cursor save/restore (A.6.11))
├── TerminalGrid+Lifecycle.swift        (~227 lines — full reset (RIS) + resize/reflow)
├── TerminalGrid+Printing.swift         (~357 lines — printCharacter + performWrap)
├── TerminalGrid+Snapshot.swift         (~298 lines — snapshot generation (A.6.14) + text extraction (A.6.15))
├── GridReflow.swift                    (existing, unchanged)
├── ScrollbackBuffer.swift              (existing, unchanged)
├── TerminalCell.swift                  (existing, unchanged)
└── ... (other Grid/ files, unchanged)
```

---

## Phase 0 — Baseline Audit

### Plan

No method extraction in this phase. Establish a clean baseline:
1. Add `// swiftlint:disable file_length` as line 1.
2. Remove `private` (and `private(set)`) from all stored properties and helper methods so that
   extension files in later phases can access them. The properties become `internal`.
3. For previously `private(set) var` properties whose setter is used only within the class methods
   being extracted, change to plain `var`. For properties whose private setter is an intentional
   read-only public API (e.g., `columns`, `rows`), keep `private(set)`.
4. Verify build. Record warning count.

**Properties that change from `private var` → `var` (internal):**
- `scrollback`, `graphemeSideTable`
- `primaryCells`, `primaryRowBase`, `primaryRowMap`
- `alternateCells`, `alternateRowBase`, `alternateRowMap`
- `usingAlternateBuffer`
- `tabStopMask`
- `customPalette`, `defaultForegroundColor`, `defaultBackgroundColor`
- `currentFgPacked`, `currentBgPacked`, `currentUnderlinePacked`
- `dirtyRowMin`, `dirtyRowMax`, `hasDirtyCells`, `lastSnapshot`
- `snapshotBufferA`, `snapshotBufferB`, `useSnapshotBufferA`

**Properties that change from `private(set) var` → `var` (internal):**
- `synchronizedOutput`, `syncExitSnapshot` (setter used in +Snapshot and fullReset → +Lifecycle)
- `windowTitle`, `iconName` (setter used in +OSCHandlers)
- `pendingBellCount` (setter used by `ringBell`/`consumeBellCount` which stay in main file — can stay `private(set)`, but change for consistency)
- `workingDirectory`, `currentHyperlink`, `cursorColor` (setters used in +OSCHandlers)

**Properties that stay `private(set)` (read-only surface stays clean):**
- `columns`, `rows` — public API; written only in `init` and resize (+Lifecycle calls `self.columns = ...`)
  → Actually resize writes them, so change to plain `var`. Re-evaluate after reading resize body.

**Static properties that change from `private static` → `static`:**
- `asciiScalarStringCache`, `asciiCharacterCache` — used in +Printing

**Functions that change from `private func` → `func` (internal):**
- `cells` computed property (var)
- `activeRowBase` computed property (var)
- `activeRowMap` computed property (var)
- `withActiveBuffer(_:)`
- `withActiveBufferState(_:)`
- `physicalRow(_:base:)` (both overloads)
- `logicalRowIndex(_:base:)`
- `linearizedRows(_:base:map:)`
- `releaseCellGrapheme(_:)`
- `resolveSideTableEntries(in:)`
- `resolveAllSideTableEntries()`
- `invalidatePackedColors()`
- `makeBlankRow()`

### Steps (5 steps)

- [x] **0.1** Confirm current line count of `ProSSHMac/Terminal/Grid/TerminalGrid.swift`: expected **2,311 lines**. Record here: **2,311**
- [x] **0.2** Add `// swiftlint:disable file_length` as the very first line of `TerminalGrid.swift`.
- [x] **0.3** Remove `private` from every stored property and helper function listed in the plan above. Work top-to-bottom through the file. Change `private(set) var` → `var` where the setter will be used from extension files. Verify each property name against the list — do not miss any.
- [x] **0.4** Run build: `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build`. Verify `** BUILD SUCCEEDED **`. Record warning count here: **0 warnings**
- [x] **0.5** Commit: `chore(RefactorTG Phase 0): baseline — swiftlint:disable + internal access for extension files`

---

## Phase 1 — Mode Setters → `TerminalGrid+ModeSetters.swift`

### Plan

`// MARK: - Mode Setters (for cross-actor access from VTParser)` spans lines **1981–2213**
(233 lines, 29 methods). Every method is a simple property assignment (1–5 lines). These are
the safest and highest-volume extraction in the whole refactor — a perfect first phase.

The `setSynchronizedOutput` setter also writes `syncExitSnapshot` and reads `lastSnapshot`.
Both are now `internal` after Phase 0 so there are no access issues.

**New file:** `ProSSHMac/Terminal/Grid/TerminalGrid+ModeSetters.swift`

### Steps (6 steps)

- [x] **1.1** Read `TerminalGrid.swift` lines 1981–2213 in full to confirm content.
- [x] **1.2** Create `ProSSHMac/Terminal/Grid/TerminalGrid+ModeSetters.swift`.
- [x] **1.3** File header: `// Extracted from TerminalGrid.swift`, `import Foundation`, `extension TerminalGrid {`, close `}`.
- [x] **1.4** Cut the entire `// MARK: - Mode Setters (for cross-actor access from VTParser)` block (lines 1982–2213) from `TerminalGrid.swift` and paste it inside the extension braces in the new file. Added `nonisolated` to all 29 methods (required: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` causes extension methods to default to `@MainActor` even when the class is `nonisolated`; explicit `nonisolated` restores correct isolation).
- [x] **1.5** Build: `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build`. Verify `** BUILD SUCCEEDED **`.
- [x] **1.6** Commit: `refactor(RefactorTG Phase 1): extract Mode Setters to TerminalGrid+ModeSetters.swift`

**Expected TerminalGrid.swift line count after phase:** ~2,080 lines

---

## Phase 2 — OSC Handlers → `TerminalGrid+OSCHandlers.swift`

### Plan

Two MARK sections handle OSC escape sequences that mutate grid metadata:
- `// MARK: - Window Title (OSC 0/1/2)` — lines **~1981–2003** (after Phase 1 shift; original: 2214–2236, ~23 lines, 4 methods)
- `// MARK: - Color Palette (OSC 4/10/11/12)` — original lines 2237–2291 (~55 lines, 9 methods)

Together ~85 lines. The OSC color setters call `invalidatePackedColors()` which stays in the
main file. It is now `internal` after Phase 0 so the extension can call it.

**New file:** `ProSSHMac/Terminal/Grid/TerminalGrid+OSCHandlers.swift`

### Steps (6 steps)

- [x] **2.1** Read the two OSC MARK blocks in `TerminalGrid.swift` in full (find current line numbers after Phase 1 shift).
- [x] **2.2** Create `ProSSHMac/Terminal/Grid/TerminalGrid+OSCHandlers.swift`.
- [x] **2.3** File header: `// Extracted from TerminalGrid.swift`, `import Foundation`, `extension TerminalGrid {`, close `}`.
- [x] **2.4** Cut `// MARK: - Window Title (OSC 0/1/2)` and `// MARK: - Color Palette (OSC 4/10/11/12)` from `TerminalGrid.swift` and paste into the extension. Added `nonisolated` to all 13 methods (same requirement as Phase 1 — `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` defaults extension methods to `@MainActor`).
- [x] **2.5** Build: `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build`. Verify `** BUILD SUCCEEDED **`.
- [x] **2.6** Commit: `refactor(RefactorTG Phase 2): extract OSC Handlers to TerminalGrid+OSCHandlers.swift`

**Expected TerminalGrid.swift line count after phase:** ~1,995 lines

---

## Phase 3 — Tab Stops + Dirty Tracking → `TerminalGrid+TabsAndDirty.swift`

### Plan

Two small, cohesive MARK sections:
- `// MARK: - A.6.12 Tab Stop Management` — original lines **1383–1425** (~43 lines, 5 methods: `horizontalTab`, `horizontalTabBack`, `clearTabStop`, `clearAllTabStops`, `resetTabStops`)
- `// MARK: - A.6.13 Dirty Tracking` — original lines **1426–1448** (~23 lines: `markDirty`, `markRowDirty`, `markAllDirty`, `clearDirtyState`, `hasDirtyRows` computed property)

Note: `resetTabStops()` is also called by `fullReset()` (Phase 9). Since it moves to an
extension, calling it from `+Lifecycle.swift` is fine — extension methods are visible to each
other via `self`.

**New file:** `ProSSHMac/Terminal/Grid/TerminalGrid+TabsAndDirty.swift`

### Steps (6 steps)

- [ ] **3.1** Read the two MARK blocks in `TerminalGrid.swift` in full (find current line numbers after Phase 1–2 shifts).
- [ ] **3.2** Create `ProSSHMac/Terminal/Grid/TerminalGrid+TabsAndDirty.swift`.
- [ ] **3.3** File header: `// Extracted from TerminalGrid.swift`, `import Foundation`, `extension TerminalGrid {`, close `}`.
- [ ] **3.4** Cut `// MARK: - A.6.12 Tab Stop Management` and `// MARK: - A.6.13 Dirty Tracking` from `TerminalGrid.swift` and paste into the extension.
- [ ] **3.5** Build: `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build`. Verify `** BUILD SUCCEEDED **`.
- [ ] **3.6** Commit: `refactor(RefactorTG Phase 3): extract Tab Stops + Dirty Tracking to TerminalGrid+TabsAndDirty.swift`

**Expected TerminalGrid.swift line count after phase:** ~1,929 lines

---

## Phase 4 — Cursor Movement + Cell R/W → `TerminalGrid+CursorOps.swift`

### Plan

Two closely related MARK sections:
- `// MARK: - A.6.1 Cell Read/Write` — original lines **430–449** (~20 lines: `cellAt(row:col:)`, `writeCell(row:col:cell:)`)
- `// MARK: - A.6.2 Cursor Movement` — original lines **450–511** (~62 lines, 9 methods: `moveCursorTo`, `moveCursorUp`, `moveCursorDown`, `moveCursorForward`, `moveCursorBackward`, `moveCursorNextLine`, `moveCursorPreviousLine`, `setCursorColumn`, `setCursorRow`)

All 9 cursor movement methods delegate to `cursor.*` methods (CursorState). `cellAt` and
`writeCell` use `physicalRow` and `cells` — both internal after Phase 0.

**New file:** `ProSSHMac/Terminal/Grid/TerminalGrid+CursorOps.swift`

### Steps (6 steps)

- [ ] **4.1** Read the two MARK blocks in `TerminalGrid.swift` in full (find current line numbers after prior phase shifts).
- [ ] **4.2** Create `ProSSHMac/Terminal/Grid/TerminalGrid+CursorOps.swift`.
- [ ] **4.3** File header: `// Extracted from TerminalGrid.swift`, `import Foundation`, `extension TerminalGrid {`, close `}`.
- [ ] **4.4** Cut `// MARK: - A.6.1 Cell Read/Write` and `// MARK: - A.6.2 Cursor Movement` from `TerminalGrid.swift` and paste into the extension.
- [ ] **4.5** Build: `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build`. Verify `** BUILD SUCCEEDED **`.
- [ ] **4.6** Commit: `refactor(RefactorTG Phase 4): extract Cursor Movement + Cell R/W to TerminalGrid+CursorOps.swift`

**Expected TerminalGrid.swift line count after phase:** ~1,847 lines

---

## Phase 5 — Scrolling → `TerminalGrid+Scrolling.swift`

### Plan

Two MARK sections implementing ring-buffer scrolling and margin management:
- `// MARK: - A.6.4 Scroll Up/Down` — original lines **869–1002** (~134 lines, 7 methods: `scrollUp`, `scrollDown`, `scrollUpPrimary`, `scrollDownPrimary`, `scrollUpRegion`, `scrollDownRegion`, plus internal helpers)
- `// MARK: - A.6.9 Scroll Region (DECSTBM)` — original lines **1241–1268** (~28 lines, 2 methods: `setScrollRegion(top:bottom:)`, `resetScrollRegion()`)

The scroll methods call `resolveSideTableEntries` (when pushing rows to scrollback),
`makeBlankRow`, and `markRowDirty` / `markAllDirty`. All are internal after Phase 0/3.

**New file:** `ProSSHMac/Terminal/Grid/TerminalGrid+Scrolling.swift`

### Steps (6 steps)

- [ ] **5.1** Read `// MARK: - A.6.4 Scroll Up/Down` and `// MARK: - A.6.9 Scroll Region` in `TerminalGrid.swift` in full.
- [ ] **5.2** Create `ProSSHMac/Terminal/Grid/TerminalGrid+Scrolling.swift`.
- [ ] **5.3** File header: `// Extracted from TerminalGrid.swift`, `import Foundation`, `extension TerminalGrid {`, close `}`.
- [ ] **5.4** Cut both MARK blocks from `TerminalGrid.swift` and paste into the extension. Keep MARK headers.
- [ ] **5.5** Build: `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build`. Verify `** BUILD SUCCEEDED **`.
- [ ] **5.6** Commit: `refactor(RefactorTG Phase 5): extract Scrolling + Scroll Region to TerminalGrid+Scrolling.swift`

**Expected TerminalGrid.swift line count after phase:** ~1,685 lines

---

## Phase 6 — Erasing → `TerminalGrid+Erasing.swift`

### Plan

Two MARK sections implementing VT erase sequences:
- `// MARK: - A.6.5 Erase in Line (EL — CSI K)` — original lines **1003–1037** (~35 lines, 1 method: `eraseInLine(_:)` with 4 internal modes)
- `// MARK: - A.6.6 Erase in Display (ED — CSI J)` — original lines **1038–1128** (~91 lines, 2 methods: `eraseInDisplay(_:)`, `eraseLines(from:to:)`)

Both call `makeBlankRow()` and `markDirty()` / `markAllDirty()`. All internal after Phase 0/3.
`eraseLines` may also call `scrollback.pushRow` — check when reading the block.

**New file:** `ProSSHMac/Terminal/Grid/TerminalGrid+Erasing.swift`

### Steps (6 steps)

- [ ] **6.1** Read both MARK blocks in `TerminalGrid.swift` in full. Note any calls to scrollback or other helpers.
- [ ] **6.2** Create `ProSSHMac/Terminal/Grid/TerminalGrid+Erasing.swift`.
- [ ] **6.3** File header: `// Extracted from TerminalGrid.swift`, `import Foundation`, `extension TerminalGrid {`, close `}`.
- [ ] **6.4** Cut `// MARK: - A.6.5 Erase in Line` and `// MARK: - A.6.6 Erase in Display` from `TerminalGrid.swift` and paste into the extension.
- [ ] **6.5** Build: `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build`. Verify `** BUILD SUCCEEDED **`.
- [ ] **6.6** Commit: `refactor(RefactorTG Phase 6): extract Erasing to TerminalGrid+Erasing.swift`

**Expected TerminalGrid.swift line count after phase:** ~1,559 lines

---

## Phase 7 — Line Operations → `TerminalGrid+LineOps.swift`

### Plan

Two MARK sections implementing character and line insertion/deletion:
- `// MARK: - A.6.7 Insert/Delete Characters` — original lines **1129–1187** (~59 lines, 2 methods: `insertCharacters(_:)`, `deleteCharacters(_:)`)
- `// MARK: - A.6.8 Insert/Delete Lines` — original lines **1188–1240** (~53 lines, 2 methods: `insertLines(_:)`, `deleteLines(_:)`)

These use `withActiveBuffer`, `makeBlankRow`, `markAllDirty`. All internal.

**New file:** `ProSSHMac/Terminal/Grid/TerminalGrid+LineOps.swift`

### Steps (6 steps)

- [ ] **7.1** Read both MARK blocks in `TerminalGrid.swift` in full.
- [ ] **7.2** Create `ProSSHMac/Terminal/Grid/TerminalGrid+LineOps.swift`.
- [ ] **7.3** File header: `// Extracted from TerminalGrid.swift`, `import Foundation`, `extension TerminalGrid {`, close `}`.
- [ ] **7.4** Cut `// MARK: - A.6.7 Insert/Delete Characters` and `// MARK: - A.6.8 Insert/Delete Lines` from `TerminalGrid.swift` and paste into the extension.
- [ ] **7.5** Build: `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build`. Verify `** BUILD SUCCEEDED **`.
- [ ] **7.6** Commit: `refactor(RefactorTG Phase 7): extract Line Operations to TerminalGrid+LineOps.swift`

**Expected TerminalGrid.swift line count after phase:** ~1,447 lines

---

## Phase 8 — Screen Buffer + Cursor Save/Restore → `TerminalGrid+ScreenBuffer.swift`

### Plan

Two MARK sections managing full-screen TUI apps and cursor state persistence:
- `// MARK: - A.6.10 Alternate Screen Buffer (Mode 1049)` — original lines **1269–1340** (~72 lines, 2 methods: `enableAlternateBuffer()`, `disableAlternateBuffer()`)
- `// MARK: - A.6.11 Cursor Save/Restore (DECSC/DECRC)` — original lines **1341–1382** (~42 lines, 2 methods: `saveCursor()`, `restoreCursor()`)

`enableAlternateBuffer` / `disableAlternateBuffer` use `makeBlankRow`, `markAllDirty`, and
write `usingAlternateBuffer`. `saveCursor` / `restoreCursor` write `cursor` directly. All internal.

**New file:** `ProSSHMac/Terminal/Grid/TerminalGrid+ScreenBuffer.swift`

### Steps (6 steps)

- [ ] **8.1** Read both MARK blocks in `TerminalGrid.swift` in full.
- [ ] **8.2** Create `ProSSHMac/Terminal/Grid/TerminalGrid+ScreenBuffer.swift`.
- [ ] **8.3** File header: `// Extracted from TerminalGrid.swift`, `import Foundation`, `extension TerminalGrid {`, close `}`.
- [ ] **8.4** Cut `// MARK: - A.6.10 Alternate Screen Buffer` and `// MARK: - A.6.11 Cursor Save/Restore` from `TerminalGrid.swift` and paste into the extension.
- [ ] **8.5** Build: `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build`. Verify `** BUILD SUCCEEDED **`.
- [ ] **8.6** Commit: `refactor(RefactorTG Phase 8): extract Screen Buffer + Cursor Save/Restore to TerminalGrid+ScreenBuffer.swift`

**Expected TerminalGrid.swift line count after phase:** ~1,333 lines

---

## Phase 9 — Lifecycle → `TerminalGrid+Lifecycle.swift`

### Plan

Two MARK sections managing terminal reset and dimension changes:
- `// MARK: - Full Reset (RIS — ESC c)` — original lines **1747–1861** (~115 lines, 3 methods: `fullReset()`, `softReset()`, `resetAttributes()`)
- `// MARK: - Resize` — original lines **1862–1973** (~112 lines, 1 method: `resize(columns:rows:maxScrollbackLines:)` — calls `resolveAllSideTableEntries`, `GridReflow.reflow`, `resetTabStops`, `markAllDirty`)

`fullReset()` calls `makeBlankRow()`, `resetTabStops()` (now in +TabsAndDirty), and resets
many stored properties directly. All calls are to internal members — no issues.

The resize method writes `self.columns` and `self.rows`. Confirm in Phase 0 that `columns` and
`rows` are `var` (not `private(set) var`) — change to plain `var` if they are still `private(set)`.

**New file:** `ProSSHMac/Terminal/Grid/TerminalGrid+Lifecycle.swift`

### Steps (7 steps)

- [ ] **9.1** Read `// MARK: - Full Reset` and `// MARK: - Resize` in `TerminalGrid.swift` in full.
- [ ] **9.2** Confirm `columns` and `rows` are plain `var` (writable from extension). If still `private(set)`, remove `private(set)` now.
- [ ] **9.3** Create `ProSSHMac/Terminal/Grid/TerminalGrid+Lifecycle.swift`.
- [ ] **9.4** File header: `// Extracted from TerminalGrid.swift`, `import Foundation`, `extension TerminalGrid {`, close `}`.
- [ ] **9.5** Cut `// MARK: - Full Reset (RIS — ESC c)` and `// MARK: - Resize` from `TerminalGrid.swift` and paste into the extension.
- [ ] **9.6** Build: `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build`. Verify `** BUILD SUCCEEDED **`.
- [ ] **9.7** Commit: `refactor(RefactorTG Phase 9): extract Lifecycle (Full Reset + Resize) to TerminalGrid+Lifecycle.swift`

**Expected TerminalGrid.swift line count after phase:** ~1,106 lines

---

## Phase 10 — Print Character → `TerminalGrid+Printing.swift`

### Plan

`// MARK: - A.6.3 Print Character` — original lines **512–868** (~357 lines) is the
**hottest code path** in the entire renderer pipeline. It contains:
- `printCharacter(_ char: Character)` — the main output handler: auto-wrap, insert mode, wide-char, SGR attribute application, side-table encoding, dirty marking
- `performWrap()` — called at the start of `printCharacter` when `cursor.pendingWrap` is set
- One or more private inline helpers used only by these two methods

This block uses `encodeGrapheme`, `releaseCellGrapheme`, `physicalRow`, `cells`, `activeRowBase`,
`makeBlankRow`, `markRowDirty`, `cursor`, `currentAttributes`, `currentFgPacked`, `currentBgPacked`,
`currentUnderlinePacked`, `autoWrapMode`, `insertMode`, `columns`, `rows`, and the static caches
`asciiScalarStringCache` / `asciiCharacterCache`. All are internal after Phase 0.

**Read this block thoroughly before extraction** — the interactions between `printCharacter`,
`performWrap`, and the `@inline(__always)` hot-path logic must be preserved exactly.
Do not rename anything. Do not restructure control flow. Move verbatim.

**New file:** `ProSSHMac/Terminal/Grid/TerminalGrid+Printing.swift`

### Steps (7 steps)

- [ ] **10.1** Read `TerminalGrid.swift` lines for `// MARK: - A.6.3 Print Character` in full (all ~357 lines, including every helper function at the end of the section).
- [ ] **10.2** List every helper function defined inside the section. Confirm each is only called from within this MARK block. If any helper is called elsewhere (e.g., by scrolling), note it — do not move it; leave it in the main file.
- [ ] **10.3** Create `ProSSHMac/Terminal/Grid/TerminalGrid+Printing.swift`.
- [ ] **10.4** File header:
  ```swift
  // Extracted from TerminalGrid.swift

  import Foundation

  extension TerminalGrid {
  ```
  Close with `}`.
- [ ] **10.5** Cut the entire `// MARK: - A.6.3 Print Character` block from `TerminalGrid.swift` (from the MARK comment through the last `}` of the last function in the section) and paste into the extension.
- [ ] **10.6** Build: `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build`. Verify `** BUILD SUCCEEDED **`. Pay close attention to any "use of unresolved identifier" errors — they indicate a private helper that was missed.
- [ ] **10.7** Commit: `refactor(RefactorTG Phase 10): extract Print Character to TerminalGrid+Printing.swift`

**Expected TerminalGrid.swift line count after phase:** ~749 lines

---

## Phase 11 — Snapshot + Text Extraction → `TerminalGrid+Snapshot.swift`

### Plan

Two MARK sections forming the renderer bridge — the second-hottest code path:
- `// MARK: - A.6.14 Grid Snapshot Generation` — original lines **1449–1713** (~265 lines, 2 methods: `snapshot()` and `scrollbackSnapshot()`)
- `// MARK: - A.6.15 Text Extraction` — original lines **1714–1746** (~33 lines, 1 method: `extractText(inRows:)`)

`snapshot()` uses the double-buffered `snapshotBufferA`/`snapshotBufferB`, the `lastSnapshot`
cache for synchronized output, `linearizedRows`, `physicalRow`, `cursor`, `scrollback`, and
many cell-level properties. All internal.

The `#if DEBUG` `os_signpost` calls in `snapshot()` require `import os.signpost` in the new file
AND the `#if DEBUG private static let perfSignpostLog` property in the main file. The static
property stays in the main file (it's a class-level declaration); the extension file adds
`#if DEBUG import os.signpost #endif` conditional import.

**New file:** `ProSSHMac/Terminal/Grid/TerminalGrid+Snapshot.swift`

### Steps (8 steps)

- [ ] **11.1** Read `// MARK: - A.6.14 Grid Snapshot Generation` and `// MARK: - A.6.15 Text Extraction` in full.
- [ ] **11.2** Confirm `perfSignpostLog` stays in `TerminalGrid.swift` (it is a `static let` on the class — leaving it there makes it accessible as `TerminalGrid.perfSignpostLog` from the extension).
- [ ] **11.3** Create `ProSSHMac/Terminal/Grid/TerminalGrid+Snapshot.swift`.
- [ ] **11.4** File header:
  ```swift
  // Extracted from TerminalGrid.swift

  import Foundation
  #if DEBUG
  import os.signpost
  #endif

  extension TerminalGrid {
  ```
  Close with `}`.
- [ ] **11.5** Cut `// MARK: - A.6.14 Grid Snapshot Generation` and `// MARK: - A.6.15 Text Extraction` from `TerminalGrid.swift` and paste into the extension.
- [ ] **11.6** Build: `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build`. Verify `** BUILD SUCCEEDED **`.
- [ ] **11.7** Check final line count of `TerminalGrid.swift`. If ≤ 400 lines, remove `// swiftlint:disable file_length` from line 1.
- [ ] **11.8** Commit: `refactor(RefactorTG Phase 11): extract Snapshot + Text Extraction to TerminalGrid+Snapshot.swift`

**Expected TerminalGrid.swift line count after phase:** ~451 lines (state + init + buffer access + grapheme encoding + scrollback getter + helpers)

---

## Post-Refactor Checklist

- [ ] Run full test suite: `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' test`
- [ ] Confirm no new test failures beyond the pre-existing baseline (see CLAUDE.md)
- [ ] Update CLAUDE.md:
  - Add `TerminalGrid+*.swift` files to the Key Files table
  - Update `TerminalGrid.swift` size estimate
  - Add a Refactor Log entry
- [ ] Update `docs/featurelist.md` with a dated loop-log entry

---

## Refactor Log (most recent first)

- **2026-02-24 — Phase 2 COMPLETE**: Extracted `// MARK: - Window Title (OSC 0/1/2)` (4 methods) and
  `// MARK: - Color Palette (OSC 4/10/11/12)` (9 methods) from `TerminalGrid.swift` (lines 1982–2059,
  78 lines, 13 methods total) into `ProSSHMac/Terminal/Grid/TerminalGrid+OSCHandlers.swift`. All 13
  methods annotated `nonisolated` (same pattern as Phase 1 — `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
  causes extension methods to inherit `@MainActor` unless explicitly overridden). Cross-file calls to
  `markAllDirty()`, `customPalette`, `cursorColor`, `defaultForegroundColor`, `defaultBackgroundColor`,
  `windowTitle`, `iconName`, `workingDirectory`, `currentHyperlink` all resolve fine — all widened to
  `internal` in Phase 0. `TerminalGrid.swift`: ~2,003 lines (from ~2,081). Build: SUCCEEDED, 0 new warnings.

- **2026-02-24 — Phase 1 COMPLETE**: Extracted `// MARK: - Mode Setters (for cross-actor access from VTParser)`
  block (lines 1982–2213, 232 lines, 29 methods) from `TerminalGrid.swift` into new file
  `ProSSHMac/Terminal/Grid/TerminalGrid+ModeSetters.swift`. Key correction: all 29 methods required
  explicit `nonisolated` annotation — with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` in the app
  target, extension methods in separate files default to `@MainActor` even when the class is
  declared `nonisolated`. This caused callers in `CharsetHandler.swift` and `ESCHandler.swift`
  to get "main actor-isolated cannot be called from nonisolated context" errors after the initial
  extraction without `nonisolated`. Fix: prepend `nonisolated` to all 29 function declarations.
  This pattern applies to all subsequent phases. `TerminalGrid.swift`: ~2,081 lines (from 2,313).
  `TerminalGrid+ModeSetters.swift`: ~241 lines. Build: SUCCEEDED, 0 new warnings.

- **2026-02-24 — Phase 0 COMPLETE**: Added `// swiftlint:disable file_length` as line 1.
  Removed `private` from all stored properties (20 `private var` → `var`, 11 `private(set) var` → `var`),
  3 `private static let` → `static let`, 3 private computed properties → internal,
  and 18 `private func` → `func`. Build: SUCCEEDED, 0 warnings.
