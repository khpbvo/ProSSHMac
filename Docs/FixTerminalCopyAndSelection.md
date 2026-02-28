# Fix Terminal Copy and Selection — Issue #22

## Problem

Terminal copy is broken and text selection cannot be cleared (GitHub Issue #22):

1. **Copy doesn't work**: Selected text doesn't land on the clipboard via Cmd+C or right-click → Copy.
2. **Selection cannot be cleared**: Clicking in the terminal doesn't deselect — leaves a stale blue cell artifact.
3. **Paste works fine** — this is specifically a copy-out and selection management issue.

## Root Cause Analysis

### Bug A: Click-to-deselect missing

**File:** `ProSSHMac/UI/Terminal/TerminalSurfaceView.swift` lines 154–156

The `onTap` callback in `metalTerminalBuffer(for:isFocused:paneID:)` only calls `onFocusTap()` (which focuses the session/pane). It never calls `selectionCoordinator.clearSelection(sessionID:)`. Standard terminal behavior: a single click clears any active selection.

The blue cell artifact is a consequence — the selection highlight persists because nothing clears it. The "cursor-sized" artifact appears when the selection shrinks to a single cell (start == end from the last drag `.began` event if the user clicks without dragging).

### Bug B: Copy returns nil/empty

**Call chain:** `copyActiveContentToClipboard()` → `selectionCoordinator.copySelection(sessionID:)` → `model.copySelection()` → `renderer.selectedText()`

The `selectedText()` method in `MetalTerminalRenderer+Selection.swift` reads from `latestSnapshot` (which stores original Unicode codepoints — NOT atlas positions). The code path appears correct through static analysis, but has several robustness issues:

1. **`handleDrag(.ended)` silently drops** (`MetalTerminalSessionSurface.swift:249`): When the drag ends outside the grid area, `gridCell(at:)` returns nil, the early `guard` triggers, and `dragStart = nil` is never reached. This leaves `dragStart` stale (non-nil).

2. **Wide-char continuation cells not skipped** (`MetalTerminalRenderer+Selection.swift:75`): For CJK/emoji characters occupying 2 cells, the continuation cell has `glyphIndex = 0` (from `primaryCodepoint` returning 0 for `width == 0` cells). `selectedText()` appends a space for these. Meanwhile `visibleText()` correctly skips continuation cells (`cell.width == 0`). The snapshot `CellInstance` doesn't carry the `width` field, but it carries `attributes` which includes `CellAttributes.wideChar`.

3. **No grapheme cluster support**: `selectedText()` reads `glyphIndex` as a single `UInt32` codepoint. For cells with multi-codepoint grapheme clusters (stored via `GraphemeSideTable`), `primaryCodepoint` returns 0 and the character is lost — replaced by a space. The grid's `visibleText()` uses `resolveGrapheme(for:)` which is not accessible from the renderer.

4. **`selectedText()` returns `nil` for empty result**: If all extracted characters happen to be spaces/empty, the trimming + empty check returns nil, and nothing is written to the clipboard.

## Files Changed

| File | Change |
|------|--------|
| `ProSSHMac/UI/Terminal/TerminalSurfaceView.swift` | Add `clearSelection` to `onTap` callback |
| `ProSSHMac/UI/Terminal/MetalTerminalSessionSurface.swift` | Fix `handleDrag(.ended)` to always clear `dragStart`; add `clearSelection` to `handleClick` flow |
| `ProSSHMac/Terminal/Renderer/MetalTerminalRenderer+Selection.swift` | Fix `selectedText()` to skip wide-char continuations; preserve trailing newlines for multi-line selections |
| `ProSSHMac/Terminal/Grid/GridSnapshot.swift` | (No changes — `CellInstance.attributes` already carries `wideChar` info) |

## Phase 1 — Fix click-to-deselect and copy

### Step 1: Add click-to-deselect in TerminalSurfaceView

- [ ] 1a. In `TerminalSurfaceView.metalTerminalBuffer(for:isFocused:paneID:)`, change the `onTap` callback from:
  ```swift
  onTap: { _ in
      onFocusTap()
  },
  ```
  to:
  ```swift
  onTap: { _ in
      selectionCoordinator.clearSelection(sessionID: session.id)
      onFocusTap()
  },
  ```

### Step 2: Fix handleDrag to always clear dragStart on .ended

- [ ] 2a. In `MetalTerminalSurfaceModel.handleDrag(point:phase:)`, restructure so `.ended` and `.cancelled` always clear `dragStart` regardless of `gridCell(at:)` returning nil:
  ```swift
  func handleDrag(point: CGPoint, phase: TerminalPointerPhase) {
      guard let renderer else { return }

      switch phase {
      case .ended:
          dragStart = nil
          return
      case .cancelled:
          dragStart = nil
          renderer.clearSelection()
          return
      case .began, .changed:
          break
      }

      guard let cell = renderer.gridCell(at: point) else { return }

      switch phase {
      case .began:
          dragStart = cell
          renderer.setSelection(start: cell, end: cell, type: .character)
      case .changed:
          guard let start = dragStart else { return }
          renderer.setSelection(start: start, end: cell, type: .character)
      case .ended, .cancelled:
          break // handled above
      }
  }
  ```

### Step 3: Fix selectedText() to skip wide-char continuation cells

- [ ] 3a. In `MetalTerminalRenderer+Selection.swift`, update `selectedText()` to detect continuation cells via `CellAttributes.wideChar` on the previous cell and skip the continuation cell (which would otherwise insert a spurious space):
  ```swift
  var previousWasWide = false
  for col in left...right {
      let idx = row * cols + col
      guard idx >= 0 && idx < snapshot.cells.count else { continue }

      let cell = snapshot.cells[idx]
      let isWide = (cell.attributes & CellAttributes.wideChar.rawValue) != 0

      // Skip continuation cell of a wide character
      if previousWasWide && !isWide && cell.glyphIndex == 0 {
          previousWasWide = false
          continue
      }
      previousWasWide = isWide

      let codepoint = cell.glyphIndex
      if codepoint == 0 {
          lineChars.append(" ")
      } else if let scalar = Unicode.Scalar(codepoint) {
          lineChars.append(Character(scalar))
      }
  }
  ```

### Step 4: Update CLAUDE.md if any architecture, file locations, or conventions changed

- [ ] 4a. Update CLAUDE.md Known Issues section to note that `selectedText()` now handles wide-char continuation cells.

### Step 5: Update docs/featurelist.md with a dated loop-log entry

- [ ] 5a. Add dated entry documenting the fix for Issue #22.

## Phase 2 — Tests and verification

### Step 6: Add unit test for selectedText() with wide characters

- [ ] 6a. In the test target, add a test that creates a `GridSnapshot` with a wide character (CellAttributes.wideChar on cell N, glyphIndex 0 on cell N+1) and verifies `selectedText()` does not emit a spurious space for the continuation cell.

### Step 7: Add unit test for click-to-deselect behavior

- [ ] 7a. Add a test that verifies `MetalTerminalSurfaceModel.clearSelection()` sets `selectionRenderer.selection` to nil and `hasSelection` returns false.

### Step 8: Build verification

- [ ] 8a. Run `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build` — zero errors.
- [ ] 8b. Run targeted tests to verify no regressions.

### Step 9: Update CLAUDE.md if any architecture, file locations, or conventions changed

- [ ] 9a. Update CLAUDE.md if needed.

### Step 10: Update docs/featurelist.md with a dated loop-log entry

- [ ] 10a. Add dated entry for Phase 2 completion.
