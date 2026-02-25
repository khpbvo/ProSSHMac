# RefactorMetalTerminalRenderer.md — MetalTerminalRenderer.swift Decomposition Checklist

This file is the working checklist and run-book for decomposing `MetalTerminalRenderer.swift`
(1,438 lines) into focused, maintainable extension files.

Follow the same workflow as `RefactorTerminalGrid.md`:
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
Current phase   : Phase 8 — COMPLETE
Phase status    : COMPLETE
Immediate action: All 8 phases done. MetalTerminalRenderer.swift is ~331 lines. Refactor complete.
Last commit     : (Phase 8 commit pending)
```

**Update this block after every phase.**

---

## Phase Status

| Phase | Name | Status |
|-------|------|--------|
| 0 | Baseline — swiftlint:disable + widen `private` → internal | **COMPLETE** (2026-02-25, commit `f2828c8`) |
| 1 | Extract Glyph Resolution → `MetalTerminalRenderer+GlyphResolution.swift` | **COMPLETE** (2026-02-25, commit `c96f7b2`) |
| 2 | Extract Snapshot Update → `MetalTerminalRenderer+SnapshotUpdate.swift` | **COMPLETE** (2026-02-25, commit `a6e3184`) |
| 3 | Extract Font Management → `MetalTerminalRenderer+FontManagement.swift` | **COMPLETE** (2026-02-25, commit `8b0759f`) |
| 4 | Extract Draw Loop → `MetalTerminalRenderer+DrawLoop.swift` | **COMPLETE** (2026-02-25, commit `e04596a`) |
| 5 | Extract View Configuration → `MetalTerminalRenderer+ViewConfiguration.swift` | **COMPLETE** (2026-02-25, commit `697f559`) |
| 6 | Extract Selection → `MetalTerminalRenderer+Selection.swift` | **COMPLETE** (2026-02-25, commit `f913b5a`) |
| 7 | Extract Post-Processing Effects → `MetalTerminalRenderer+PostProcessing.swift` | **COMPLETE** (2026-02-25, commit `2d431d3`) |
| 8 | Extract Diagnostics → `MetalTerminalRenderer+Diagnostics.swift` | **COMPLETE** (2026-02-25) |

---

## Non-Negotiable Rules

1. **Build must pass after every phase** — run `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build` and verify `** BUILD SUCCEEDED **` before committing.
2. **Commit after every phase** — each phase is a self-contained commit on the active branch.
3. **Header comment on every extracted file** — first non-blank, non-import line must be: `// Extracted from MetalTerminalRenderer.swift`
4. **Every new Swift file must pass `-strict-concurrency=complete`** — add the flag temporarily to Other Swift Flags in Xcode, build, fix any warnings, then remove the flag before committing.
5. **`// swiftlint:disable file_length`** — added in Phase 0. Remove only when the main file falls below 400 lines (after Phase 8).
6. **All extractions use `extension MetalTerminalRenderer`** — no new types are created. Every extracted file is an extension of the same `final class`. File naming: `MetalTerminalRenderer+<Concern>.swift`.
7. **Project uses PBXFileSystemSynchronizedRootGroup** — new `.swift` files created on disk in `ProSSHMac/Terminal/Renderer/` are auto-detected by Xcode. No manual xcodeproj editing needed.
8. **Read the full phase plan before touching any file** — never start coding a phase without reading all its steps first.
9. **`rawCellWidth` and `rawCellHeight` are stored properties** — they are currently declared mid-file near line 1118. Move them to the properties section in Phase 0 so the main file is clean before extractions begin.

---

## Why `extension MetalTerminalRenderer` (not new types)

`MetalTerminalRenderer` is a `final class: NSObject, MTKViewDelegate` whose state is one
tightly coupled blob of Metal resources, glyph cache, cell buffer, and effect configurations.
Every group of methods reads or writes multiple stored properties. There is no natural seam to
extract a standalone type — the right Swift decomposition is extensions across files, grouping
methods by functional concern. This is the idiomatic Swift approach for large single-responsibility
classes.

**Consequence of `extension` extraction:** Swift's `private` access modifier is file-scoped, so
methods in extension files cannot read or write `private` stored properties of the main class.
Phase 0 therefore removes `private` from every stored property and helper, making them `internal`
(accessible within the module but not beyond it).

---

## Isolation Note (SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor)

The project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` globally. `MetalTerminalRenderer` has
no explicit isolation annotation, so it is effectively `@MainActor` under this setting — which is
correct, because `MTKView` drives `draw(in:)` from a `CADisplayLink` on the main thread.

When methods move to separate extension files, Swift re-evaluates isolation per file. In Phase 0,
verify with `-strict-concurrency=complete` that the class is indeed inferred `@MainActor` and that
no cross-thread warnings appear. If warnings arise in any extracted file, add `@MainActor` explicitly
to the extension declaration (e.g. `@MainActor extension MetalTerminalRenderer { … }`). Do NOT use
`nonisolated` — unlike `TerminalGrid`, this class must stay main-thread-bound.

---

## Target Layout After All Phases

```
ProSSHMac/Terminal/Renderer/
├── MetalTerminalRenderer.swift                      # ~215 lines: imports, class decl, stored properties, init
├── MetalTerminalRenderer+GlyphResolution.swift      # Phase 1: rasterize, cache lookup, font fallback
├── MetalTerminalRenderer+SnapshotUpdate.swift       # Phase 2: updateSnapshot, applyPendingSnapshot
├── MetalTerminalRenderer+FontManagement.swift       # Phase 3: font load/change/reload, pixel alignment
├── MetalTerminalRenderer+DrawLoop.swift             # Phase 4: draw(in:), encodeTerminalScenePass
├── MetalTerminalRenderer+ViewConfiguration.swift   # Phase 5: configureView, resize, FPS control
├── MetalTerminalRenderer+Selection.swift            # Phase 6: set/clear/selectAll, selectedText, hit test
├── MetalTerminalRenderer+PostProcessing.swift       # Phase 7: CRT/gradient/scanner setters + texture helpers
├── MetalTerminalRenderer+Diagnostics.swift          # Phase 8: cacheHitRate, atlasPageCount, perfSnapshot
└── ... (existing files, unchanged)
```

---

## Phase 0 — Baseline

**Goal:** Prepare `MetalTerminalRenderer.swift` for cross-file extension access without changing behaviour.

### Steps

- [ ] 0.1 — Record the current line count: `wc -l ProSSHMac/Terminal/Renderer/MetalTerminalRenderer.swift`. Note the number in the commit message.
- [ ] 0.2 — Add `// swiftlint:disable file_length` as line 1 of `MetalTerminalRenderer.swift`.
- [ ] 0.3 — Move the two stored-property declarations `private var rawCellWidth: CGFloat = 8` and `private var rawCellHeight: CGFloat = 16` (currently near line 1118) up to the **Grid State** MARK section alongside `gridColumns`, `gridRows`, `cellWidth`, `cellHeight`.
- [ ] 0.4 — Remove the `private` keyword from every stored property and private helper method that will be referenced from an extension file. This means changing `private var` → `var` and `private func` → `func` for: all stored properties (B.8.1 infrastructure, renderer components, grid state, cursor state, in-flight buffering, timing, effect configs), and all private helper methods. **Do not touch `public` or `internal` members — they are already accessible.**
- [ ] 0.5 — Leave `private static` methods as-is for now; static methods that move to extension files will lose `private` in their respective phase.
- [ ] 0.6 — Build: `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build`. Verify `** BUILD SUCCEEDED **`.
- [ ] 0.7 — Run `-strict-concurrency=complete` (add to Other Swift Flags temporarily, build, note warning count, remove flag). Record baseline warning count for this file.
- [ ] 0.8 — Commit: `refactor(RefactorMTR Phase 0): baseline — widen private to internal, move rawCell props`

---

## Phase 1 — Extract Glyph Resolution

**Goal:** Move all glyph cache lookup, rasterization, and font fallback logic to `MetalTerminalRenderer+GlyphResolution.swift`.

**Source lines (approximate):** 372–545 and 619–653.

### Methods to move

| Method | Approx lines | Notes |
|--------|-------------|-------|
| `rasterizeAndUpload(key:)` | 379–432 | Calls `GlyphRasterizer`, uploads to atlas |
| `rebuildRasterFontCacheIfNeeded(scale:)` | 434–473 | Builds CTFont variants |
| `resolveRenderFont(for:primaryFont:)` | 492–538 | `static` — remove `private` |
| `isEmojiRange(_:)` | 543–545 | `static` — remove `private` |
| `resolveGlyphIndex(for:)` | 619–641 | Called from `applyPendingSnapshotIfNeeded` |
| `packAtlasEntry(_:)` | 649–653 | Pack atlas coords to UInt32 |

### Steps

- [ ] 1.1 — Create `ProSSHMac/Terminal/Renderer/MetalTerminalRenderer+GlyphResolution.swift`.
- [ ] 1.2 — Add file header:
  ```swift
  // Extracted from MetalTerminalRenderer.swift
  import Metal
  import CoreText
  import AppKit
  ```
- [ ] 1.3 — Open with `extension MetalTerminalRenderer {` and close with `}`.
- [ ] 1.4 — Cut `rasterizeAndUpload(key:)` from the main file and paste into the extension. Remove `private` keyword.
- [ ] 1.5 — Cut `rebuildRasterFontCacheIfNeeded(scale:)` from the main file and paste. Remove `private`.
- [ ] 1.6 — Cut `resolveRenderFont(for:primaryFont:)` (static) and paste. Remove `private`.
- [ ] 1.7 — Cut `isEmojiRange(_:)` (static) and paste. Remove `private`.
- [ ] 1.8 — Cut `resolveGlyphIndex(for:)` from the main file and paste. Remove `private`.
- [ ] 1.9 — Cut `packAtlasEntry(_:)` from the main file and paste. Remove `private`.
- [ ] 1.10 — Delete now-empty `// MARK: - Font Fallback for Rasterization` comment block from the main file.
- [ ] 1.11 — Build: `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build`. Verify `** BUILD SUCCEEDED **`.
- [ ] 1.12 — Verify with `-strict-concurrency=complete` (temp flag). Fix any isolation warnings (see Isolation Note above). Remove flag.
- [ ] 1.13 — Commit: `refactor(RefactorMTR Phase 1): extract glyph resolution to MetalTerminalRenderer+GlyphResolution.swift`

---

## Phase 2 — Extract Snapshot Update

**Goal:** Move the snapshot ingestion and cell-buffer upload pipeline to `MetalTerminalRenderer+SnapshotUpdate.swift`.

**Source lines (approximate):** 547–617.

### Methods to move

| Method | Approx lines | Notes |
|--------|-------------|-------|
| `updateSnapshot(_:)` | 560–589 | Public API — called by `MetalTerminalSessionSurface` |
| `applyPendingSnapshotIfNeeded()` | 591–617 | Called from `draw(in:)` |

### Steps

- [ ] 2.1 — Create `ProSSHMac/Terminal/Renderer/MetalTerminalRenderer+SnapshotUpdate.swift`.
- [ ] 2.2 — Add file header:
  ```swift
  // Extracted from MetalTerminalRenderer.swift
  import Metal
  ```
- [ ] 2.3 — Open with `extension MetalTerminalRenderer {`.
- [ ] 2.4 — Cut `updateSnapshot(_:)` from the main file and paste. It is already `func` (not private) — no keyword change needed.
- [ ] 2.5 — Cut `applyPendingSnapshotIfNeeded()` from the main file and paste. Remove `private`.
- [ ] 2.6 — Delete now-empty `// MARK: - Snapshot Update (B.8.4)` comment block from the main file.
- [ ] 2.7 — Build: verify `** BUILD SUCCEEDED **`.
- [ ] 2.8 — Verify with `-strict-concurrency=complete`. Fix warnings. Remove flag.
- [ ] 2.9 — Commit: `refactor(RefactorMTR Phase 2): extract snapshot update to MetalTerminalRenderer+SnapshotUpdate.swift`

---

## Phase 3 — Extract Font Management

**Goal:** Move all async font loading, font-change coordination, and pixel-alignment helpers to `MetalTerminalRenderer+FontManagement.swift`.

**Source lines (approximate):** 326–370 (async init) and 1027–1155 (font change + pixel helpers).

### Methods to move

| Method | Approx lines | Notes |
|--------|-------------|-------|
| `initializeFontMetricsAndPrepopulate()` | 330–370 | `async` — called from `init` |
| `handleFontChange()` | 1031–1037 | Public API |
| `setFontSize(_:)` | 1040–1051 | Public API |
| `setFontName(_:)` | 1054–1066 | Public API |
| `reloadFontStateFromManager()` | 1068–1112 | `async`, `private` → internal in Phase 0 |
| `reapplyPixelAlignment()` | 1124–1128 | Helper, `private` → internal |
| `recalculateGridDimensions()` | 1132–1155 | Helper, `private` → internal |

### Steps

- [ ] 3.1 — Create `ProSSHMac/Terminal/Renderer/MetalTerminalRenderer+FontManagement.swift`.
- [ ] 3.2 — Add file header:
  ```swift
  // Extracted from MetalTerminalRenderer.swift
  import Metal
  import CoreText
  ```
- [ ] 3.3 — Open with `extension MetalTerminalRenderer {`.
- [ ] 3.4 — Cut `initializeFontMetricsAndPrepopulate()` from the main file (the `// MARK: - Async Initialization` block). Remove `private`.
- [ ] 3.5 — Cut `handleFontChange()`, `setFontSize(_:)`, `setFontName(_:)` from the main file (the `// MARK: - Font Change` block).
- [ ] 3.6 — Cut `reloadFontStateFromManager()` from the main file. Remove `private`.
- [ ] 3.7 — Cut `reapplyPixelAlignment()` and `recalculateGridDimensions()` from the main file (the `// MARK: - Pixel Alignment Helpers` block). Remove `private` from both.
- [ ] 3.8 — Delete the now-empty MARK comment blocks for Async Initialization, Font Change, and Pixel Alignment Helpers from the main file.
- [ ] 3.9 — Build: verify `** BUILD SUCCEEDED **`.
- [ ] 3.10 — Verify with `-strict-concurrency=complete`. Fix warnings. Remove flag.
- [ ] 3.11 — Commit: `refactor(RefactorMTR Phase 3): extract font management to MetalTerminalRenderer+FontManagement.swift`

---

## Phase 4 — Extract Draw Loop

**Goal:** Move the full MTKViewDelegate draw path to `MetalTerminalRenderer+DrawLoop.swift`.

**Source lines (approximate):** 655–898.

### Methods to move

| Method | Approx lines | Notes |
|--------|-------------|-------|
| `draw(in:)` | 661–851 | `MTKViewDelegate` — must NOT be `private` |
| `encodeTerminalScenePass(_:drawableSize:)` | 853–898 | Helper called only from `draw(in:)` |

### Steps

- [ ] 4.1 — Create `ProSSHMac/Terminal/Renderer/MetalTerminalRenderer+DrawLoop.swift`.
- [ ] 4.2 — Add file header:
  ```swift
  // Extracted from MetalTerminalRenderer.swift
  import Metal
  import MetalKit
  import QuartzCore
  import simd
  ```
- [ ] 4.3 — Open with `extension MetalTerminalRenderer {`.
- [ ] 4.4 — Cut `draw(in:)` and `encodeTerminalScenePass(_:drawableSize:)` from the main file. Remove `private` from `encodeTerminalScenePass`.
- [ ] 4.5 — Delete the now-empty `// MARK: - MTKViewDelegate: Draw (B.8.3, B.8.4)` block from the main file.
- [ ] 4.6 — Build: verify `** BUILD SUCCEEDED **`. The draw loop is the largest method — pay close attention to any missing symbols.
- [ ] 4.7 — Verify with `-strict-concurrency=complete`. Fix warnings. Remove flag.
- [ ] 4.8 — Commit: `refactor(RefactorMTR Phase 4): extract draw loop to MetalTerminalRenderer+DrawLoop.swift`

---

## Phase 5 — Extract View Configuration

**Goal:** Move `MTKViewDelegate` resize delegate, view setup, and frame-rate control to `MetalTerminalRenderer+ViewConfiguration.swift`.

**Source lines (approximate):** 900–1025.

### Methods to move

| Method | Approx lines | Notes |
|--------|-------------|-------|
| `mtkView(_:drawableSizeWillChange:)` | 907–970 | `MTKViewDelegate` |
| `configureView(_:)` | 978–994 | Public API |
| `setPaused(_:)` | 1000–1002 | Public API |
| `setPreferredFPS(_:)` | 1006–1015 | Public API |
| `currentScreenMaximumFPS()` | 1017–1025 | Helper, `private` → internal |

### Steps

- [ ] 5.1 — Create `ProSSHMac/Terminal/Renderer/MetalTerminalRenderer+ViewConfiguration.swift`.
- [ ] 5.2 — Add file header:
  ```swift
  // Extracted from MetalTerminalRenderer.swift
  import MetalKit
  import AppKit
  ```
- [ ] 5.3 — Open with `extension MetalTerminalRenderer {`.
- [ ] 5.4 — Cut `mtkView(_:drawableSizeWillChange:)` from the main file.
- [ ] 5.5 — Cut `configureView(_:)`, `setPaused(_:)`, `setPreferredFPS(_:)` from the main file.
- [ ] 5.6 — Cut `currentScreenMaximumFPS()` from the main file. Remove `private`.
- [ ] 5.7 — Delete the now-empty `// MARK: - MTKViewDelegate: Resize (B.8.6)` and `// MARK: - View Configuration (B.8.6)` and `// MARK: - Frame Rate Control (2.2.9 / 2.2.10)` blocks from the main file.
- [ ] 5.8 — Build: verify `** BUILD SUCCEEDED **`.
- [ ] 5.9 — Verify with `-strict-concurrency=complete`. Fix warnings. Remove flag.
- [ ] 5.10 — Commit: `refactor(RefactorMTR Phase 5): extract view configuration to MetalTerminalRenderer+ViewConfiguration.swift`

---

## Phase 6 — Extract Selection

**Goal:** Move all selection management and text extraction logic to `MetalTerminalRenderer+Selection.swift`.

**Source lines (approximate):** 1157–1259.

### Methods to move

| Method | Approx lines | Notes |
|--------|-------------|-------|
| `setSelection(start:end:type:)` | 1160–1169 | Public API |
| `clearSelection()` | 1172–1177 | Public API |
| `selectAll()` | 1180–1187 | Public API |
| `hasSelection` (computed var) | 1190–1192 | Public API |
| `selectedText()` | 1195–1244 | Public API |
| `gridCell(at:)` | 1247–1259 | Public API |

### Steps

- [ ] 6.1 — Create `ProSSHMac/Terminal/Renderer/MetalTerminalRenderer+Selection.swift`.
- [ ] 6.2 — Add file header:
  ```swift
  // Extracted from MetalTerminalRenderer.swift
  import AppKit
  ```
- [ ] 6.3 — Open with `extension MetalTerminalRenderer {`.
- [ ] 6.4 — Cut all six members from the main file. None are `private` — no keyword changes needed.
- [ ] 6.5 — Delete the now-empty `// MARK: - Selection` block from the main file.
- [ ] 6.6 — Build: verify `** BUILD SUCCEEDED **`.
- [ ] 6.7 — Verify with `-strict-concurrency=complete`. Fix warnings. Remove flag.
- [ ] 6.8 — Commit: `refactor(RefactorMTR Phase 6): extract selection to MetalTerminalRenderer+Selection.swift`

---

## Phase 7 — Extract Post-Processing Effects

**Goal:** Move all CRT, gradient, and scanner effect configuration and texture management to `MetalTerminalRenderer+PostProcessing.swift`.

**Source lines (approximate):** 1261–1410.

### Methods to move

| Method | Approx lines | Notes |
|--------|-------------|-------|
| `setCRTEffectEnabled(_:)` | 1264–1271 | Public API |
| `setCRTEffectConfiguration(_:)` | 1274–1281 | Public API |
| `reloadCRTEffectSettings()` | 1284–1290 | Public API |
| `setGradientBackgroundEnabled(_:)` | 1295–1299 | Public API |
| `setGradientBackgroundConfiguration(_:)` | 1302–1306 | Public API |
| `reloadGradientBackgroundSettings()` | 1309–1312 | Public API |
| `reloadScannerEffectSettings()` | 1317–1320 | Public API |
| `currentGradientConfiguration` (computed var) | 1323–1325 | Public API |
| `ensurePostProcessTextures(for:)` | 1327–1343 | Helper, `private` → internal |
| `makeCRTFrameTexture(width:height:)` | 1345–1356 | Helper, `private` → internal |
| `makePostProcessTexture(width:height:)` | 1358–1369 | Helper, `private` → internal |
| `makeSceneRenderPassDescriptor(texture:clearColor:)` | 1371–1381 | Helper, `private` → internal |
| `makeCRTFallbackTexture()` | 1383–1410 | Helper, `private` → internal |

### Steps

- [ ] 7.1 — Create `ProSSHMac/Terminal/Renderer/MetalTerminalRenderer+PostProcessing.swift`.
- [ ] 7.2 — Add file header:
  ```swift
  // Extracted from MetalTerminalRenderer.swift
  import Metal
  import Foundation
  ```
- [ ] 7.3 — Open with `extension MetalTerminalRenderer {`.
- [ ] 7.4 — Cut all thirteen members from the main file. Remove `private` from the five helper methods (`ensurePostProcessTextures`, `makeCRTFrameTexture`, `makePostProcessTexture`, `makeSceneRenderPassDescriptor`, `makeCRTFallbackTexture`).
- [ ] 7.5 — Delete the now-empty `// MARK: - CRT Effect`, `// MARK: - Gradient Background Effect`, and `// MARK: - Scanner (Knight Rider) Effect` comment blocks from the main file.
- [ ] 7.6 — Build: verify `** BUILD SUCCEEDED **`.
- [ ] 7.7 — Verify with `-strict-concurrency=complete`. Fix warnings. Remove flag.
- [ ] 7.8 — Commit: `refactor(RefactorMTR Phase 7): extract post-processing effects to MetalTerminalRenderer+PostProcessing.swift`

---

## Phase 8 — Extract Diagnostics

**Goal:** Move all read-only diagnostic computed properties to `MetalTerminalRenderer+Diagnostics.swift`.

**Source lines (approximate):** 1412–1438.

### Properties to move

| Property | Approx lines | Notes |
|----------|-------------|-------|
| `cacheHitRate` | 1415–1417 | Forwards to `glyphCache` |
| `atlasPageCount` | 1419–1421 | Forwards to `glyphAtlas` |
| `atlasMemoryBytes` | 1423–1427 | Forwards to `glyphAtlas` |
| `cachedGlyphCount` | 1429–1431 | Forwards to `glyphCache` |
| `performanceSnapshot` | 1433–1436 | Forwards to `performanceMonitor` |

### Steps

- [ ] 8.1 — Create `ProSSHMac/Terminal/Renderer/MetalTerminalRenderer+Diagnostics.swift`.
- [ ] 8.2 — Add file header:
  ```swift
  // Extracted from MetalTerminalRenderer.swift
  ```
- [ ] 8.3 — Open with `extension MetalTerminalRenderer {`.
- [ ] 8.4 — Cut all five computed properties from the main file. None are `private`.
- [ ] 8.5 — Delete the now-empty `// MARK: - Diagnostics` block from the main file.
- [ ] 8.6 — Check main file line count: `wc -l ProSSHMac/Terminal/Renderer/MetalTerminalRenderer.swift`. Target is ≤250 lines. If below 400, remove `// swiftlint:disable file_length` from line 1.
- [ ] 8.7 — Build: verify `** BUILD SUCCEEDED **`.
- [ ] 8.8 — Verify with `-strict-concurrency=complete`. Fix warnings. Remove flag.
- [ ] 8.9 — Run full test suite: `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' test`. Confirm no new failures beyond the pre-existing baseline (≤23).
- [ ] 8.10 — Update `CLAUDE.md`: set `MetalTerminalRenderer.swift` size to `~215 lines`, add all 8 new extension files to the Key Files table. Update the "Recent Changes" section.
- [ ] 8.11 — Update `docs/featurelist.md` with a dated loop-log entry.
- [ ] 8.12 — Commit: `refactor(RefactorMTR Phase 8): extract diagnostics + post-refactor cleanup`

---

## Post-Refactor Checklist

- [ ] All 8 phases committed and build passing.
- [ ] `MetalTerminalRenderer.swift` is ≤250 lines (stored properties + init only).
- [ ] `// swiftlint:disable file_length` removed from main file.
- [ ] Full test suite passes (within pre-existing failure baseline).
- [ ] `CLAUDE.md` Key Files table updated.
- [ ] `docs/featurelist.md` loop-log updated.
- [ ] `RefactorMetalTerminalRenderer.md` Current State block updated to Phase 8 COMPLETE.
