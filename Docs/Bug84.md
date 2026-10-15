# Bug 84 — Keep One Terminal Renderer per Session Across Layout Changes

Bug register entry: `Docs/bugs.md` Bug 84. Follows Bug 82 (fixed 2026-10-13).

## Overview

**Problem.** `MetalTerminalSessionSurface` owns its `MetalTerminalSurfaceModel` — and through it the
session's `MetalTerminalRenderer` — as a `@StateObject`. The renderer therefore lives exactly as long as
SwiftUI keeps that view's identity, and identity is tied to the view's position in the tree. Bug 82
fixed one trigger (Maximize Terminal moved the surface to a different build site). Phase 0
(2026-10-14) confirmed that all of these still rebuild it; see Phase 0 results:

- **Tab switch** (single layout): the surface at `sessionPanel` gets a different `.id(session.id)`.
- **Split / unsplit** (split right/down, "move to new tab", closing a pane): the session moves
  between the single branch of `TerminalView.macOSBody` and `SplitNodeView`.
- **Pane maximize** (`paneManager.maximizedPaneId`): changes `displayNode`, so the pane's position in
  `SplitNodeView` changes.

Each rebuild loses the selection, smooth-scroll offset and momentum, cursor animation and CRT
afterglow. It also re-creates the command queue, four pipeline states, the glyph atlas and cache (atlas
pages are 2048² BGRA, ~16 MB each, created lazily), and re-prepopulates ASCII, usually twice on Retina
because a new renderer starts at `screenScale = 1`.

**Goal.** One renderer per session per window, surviving every layout change. A session's selection
and scroll position survive tab switches, splits and maximize. Renderers are released when their
session closes.

**Architecture sketch.**

- `TerminalSurfaceModelStore` (`@MainActor final class`, `ObservableObject`), one per window: owned
  as a `@StateObject` by `TerminalView` and by `ExternalTerminalWindowView`, and passed down like
  `selectionCoordinator` is today.
  - `model(for sessionID:) -> MetalTerminalSurfaceModel` creates the model on first use.
  - `release(sessionID:)` drops it; pruning against `sessionManager.sessions` happens on the
    existing `onChange(of: sessionManager.sessions)`.
- `MetalTerminalSessionSurface` takes the model as a parameter (`@ObservedObject`) instead of
  creating it.
- **Attach/detach follows the Bug 81 identity rule.** A new surface can appear before the old one
  disappears, and both may briefly hold the same renderer.
  - The store records the currently attached surface, using a per-view token (`@State` UUID).
  - `onDisappear` pauses the renderer, and unregisters it, only if the disappearing surface is still
    the attached one.
  - `configureView` already re-points `configuredMTKView` and the `MTKView` delegate at the newest
    view.
- **`TerminalSelectionCoordinator` can collapse into the store.** Copy and select-all would look up
  `store.model(for:)` directly. This also removes the registry Bug 81 broke, and prepares Bug 80
  (one shared copy path).

**Affected files.**
- `UI/Terminal/MetalTerminalSessionSurface.swift` (surface, model, coordinator)
- `UI/Terminal/TerminalView.swift`
- `UI/Terminal/TerminalSurfaceView.swift`
- `UI/Terminal/ExternalTerminalWindowView.swift`
- a new `UI/Terminal/TerminalSurfaceModelStore.swift`
- possibly `Terminal/Renderer/MetalTerminalRenderer+ViewConfiguration.swift` and
  `TerminalMetalView.swift`, for re-attaching to a new `MTKView`

**Conventions to respect** (CLAUDE.md):
- `ObservableObject` + `@StateObject`, not `@Observable`.
- `nonisolated deinit` on `@MainActor` types that may deallocate off the main actor.
- View-keyed registries remove by identity, not by key.
- Resize must not reserve `CellBuffer` storage; only a matching snapshot may change buffer dimensions.
- Alternate-buffer scroll policy is unchanged.

**Regression test pattern.** `TerminalSurfaceIdentityTests` hosts the real `TerminalView` in an
`NSWindow` with screenshot sessions, an isolated `defaultAppStorage` suite and stub services. It finds
the `TerminalMetalContainerView` and asserts that the same renderer instance survives. Hold strong
references, so that a freed renderer's address can't be reused by its replacement.

## Phases

- [x] **Phase 0: Measure before changing anything.** Done 2026-10-14 — see Phase 0 results.
  - Reuse the Bug 82 logging pattern (per-identity `@State` tokens; model init/deinit; layout
    changes) on a never-merged debug branch. Confirm which of these rebuild the surface:
    - tab switch
    - split
    - unsplit
    - pane maximize
    - move to new tab
    - pop-out window
  - Measure one renderer's memory: footprint with N sessions open, before and after the atlas fills.
  - Record the results in this file, and decide whether the store needs a cap or eviction for
    background sessions.
- [x] **Phase 1: `TerminalSurfaceModelStore`, with no view changes yet.** Done 2026-10-14:
  `UI/Terminal/TerminalSurfaceModelStore.swift`, `TerminalSurfaceModelStoreTests` (5).
  - Write the store with create-on-demand, `release(sessionID:)` and `prune(keeping:)`, plus
    unit tests:
    - the same model is returned for the same session
    - a released model is deallocated, checked with a weak reference
    - prune drops closed sessions
- [x] **Phase 2: The main window uses the store.** Done 2026-10-14. As built:
  - **A session shown in two panes** (possible via "split with existing") gets two renderers,
    because one renderer drives one `MTKView`. The first pane in tree order
    (`paneManager.allPanes`, i.e. `rootNode`, which is stable across maximize) uses the session's
    primary model, and later panes use `model(for:duplicateInPane:)`. The single layout always
    uses the primary model. `TerminalView.surfaceModel(for:paneID:)` decides from pane state,
    never from view order. Prune also drops duplicates whose pane is gone.
  - **Attach/detach** live on the model: `attach(surface:)`, `detach(surface:) -> Bool`. Only the
    attached surface's `onDisappear` pauses, releases textures and unregisters.
  - **Detach also clears `scrollbackBoundsProvider` and `onGridSizeChange`.** They capture view
    structs that now hold the model. Without this, renderer → closure → view → model → renderer
    was a cycle, and a closed session's renderer was never freed (caught by the guard test).
  - **One view drives the renderer.** `configureView` takes the delegate away from a previous
    `MTKView`, and `TerminalMetalView.updateNSView` rebinds renderer callbacks only for the
    renderer's configured view. A lingering old view must not take back `onScrollLineChange`,
    which holds its container weakly, or the grid-resize callback.
  - **Test seam:** `TerminalView(tabManager:paneManager:)`. The identity tests inject managers on
    an isolated defaults suite.
  - The original plan for this phase follows, implemented as written:
  - `TerminalView` owns the store and prunes it on `sessionManager.sessions` changes.
    `TerminalSurfaceView` passes the model through, and `MetalTerminalSessionSurface` takes it as
    an `@ObservedObject`.
  - Attach/detach use the per-view token rule: pause, `scrollJumpTo`, the 150 ms snapshot
    re-apply and register all follow it. Phase 0 logged the new surface appearing 8–30 ms
    *before* the old one disappears on every tab switch and split, so this rule is required.
  - On detach, release the drawable-sized offscreen textures (`postProcessTexture`,
    `previousFrameTexture`, the three bloom textures) and keep the glyph atlas — the Phase 0
    memory decision. All five are already recreated lazily on a size mismatch, which includes
    nil (`MetalTerminalRenderer+PostProcessing.swift`). Also reset `hasCapturedPreviousFrame`,
    so the CRT pass does not sample a texture it no longer has. Test: a detached renderer holds
    no offscreen textures, and the next draw recreates them.
  - Extend `TerminalSurfaceIdentityTests` (each red before the change):
    - a tab switch and switching back keeps each session's renderer
    - split then unsplit keeps the original renderer
    - pane maximize keeps the renderer
    - a closed session's renderer is released
- [x] **Phase 3: Fold `TerminalSelectionCoordinator` into the store.** Done 2026-10-14. As built:
  - **The registry is gone.** `TerminalSelectionCoordinator` and the surface's register/unregister
    calls are deleted; `onDisappear` only detaches. Nothing fills a selection lookup from view
    lifecycle any more.
  - **`TerminalSurfaceModelStore.existingModel(for:duplicateInPane:)`** returns the model
    `model(for:duplicateInPane:)` would, or nil. It never creates one, so copy cannot allocate a
    renderer.
  - **Main window:** `TerminalView.duplicatePaneID(for:paneID:)` is the one "is this a later pane?"
    rule, shared by `surfaceModel(for:paneID:)` and `existingSurfaceModel(for:paneID:)`.
    `focusedSurfaceModel()` picks the focused pane's model when that pane shows the target session,
    else the session's own. Cmd+C and Select All use it. `sessionPanel` binds the pane's model once
    and passes it to the surface and to its context-menu Copy, so a duplicate pane copies its own
    selection. The context menu's Select All / Clear Selection use the view's own model.
  - **Dropped (user decision):** the main window's fallback that copied a selection from any other
    visible pane when the target had nothing. The pop-out window's equivalent re-checked its only
    session and is gone too. The draft and last-line fallbacks are unchanged (Bug 80).
  - Tests: the two Bug 81 registry tests became store tests (a replaced surface's detach leaves the
    selection copyable; a released session has nothing to copy), plus a duplicate pane copies its
    own selection. `TerminalSurfaceModelStoreTests.testExistingModelNeverCreatesOne`.
- [x] **Phase 4: Pop-out window.** Done 2026-10-14. As built:
  - Phase 2 already gave `ExternalTerminalWindowView` its own store, so renderers are per window
    and never shared. Phase 0 measured that pop-out does not move the session out: the main window
    keeps its own renderer, so it must not release its model on pop-out.
  - **A pop-out left open on a closed session releases its model.** The window stays on its
    "Session Not Found" placeholder; `.onChange(of: session == nil)` calls
    `surfaceModels.release(sessionID:)`, as the main window prunes.
  - **Every closed pop-out leaked its renderer, found live.** `heap` on the Debug app counted one
    more `MetalTerminalRenderer`, `MetalTerminalSurfaceModel`, `GlyphAtlas` and
    `TerminalSurfaceModelStore` per closed pop-out, while its window and views were gone. Cause: a
    cycle, store -> model -> renderer -> `onGridSizeChange` closure -> the pop-out view -> its
    `@StateObject` store. Closing a `WindowGroup` window runs `onDisappear` (detach clears the
    callback) and then one more `TerminalMetalView.updateNSView`, which set it again, since the
    renderer still drew into that view. The main window never showed it: its store outlives the
    surface and prunes the model, which breaks the loop.
    - Misleading evidence, for next time: `leaks` reported 0 and `leaks --trace` rooted the store
      in Combine's global `ObservableObjectTable`, which only references objects that use the
      synthesized `objectWillChange`. Giving the store an explicit publisher (an experiment,
      reverted) turned it into a reported ROOT CYCLE that named the callback.
  - **Fix: `TerminalMetalView.dismantleNSView`** clears `onGridSizeChange` and
    `smoothScrollEngine.onScrollLineChange` when the dismantled view is still the renderer's
    `configuredMTKView`. SwiftUI calls it after the last update (asynchronously, after the view is
    removed); a view already replaced by a newer one leaves the callbacks alone.
  - Tests (`TerminalSurfaceIdentityTests`, "Pop-out window"): the pop-out gets its own renderer and
    the main one is unchanged; closing the pop-out frees only its renderer; a closed session's
    pop-out renderer is freed (red before the release change);
    `testRemovingTheSurfaceClearsCallbacksSetAfterDetach` (red before the dismantle fix). A test
    window cannot reproduce the post-`onDisappear` update (`NSWindow.close()` in a test does not
    even run `onDisappear`), so that test sets the callback itself; the leak is verified live with
    `heap <pid> | grep MetalTerminalRenderer`.
  - Live (Debug, one local session): the pop-out opens, draws and copies its own selection.
    Footprint 134 MB with the session, 214 MB with the pop-out open; after closing it, 165 MB and
    graphics 37 MB before the fix, **138 MB and 21 MB** with it (counts back to 1). A second pop-out
    left nothing behind; the main window kept drawing and copying.
- [x] **Phase 5: Live validation and memory policy.** Done 2026-10-15; results below the list.
  - On a relaunched build:
    - select text, switch tabs and back: the selection is still there and copy works
    - same for split/unsplit and maximize
    - the scroll position survives
    - no visible redraw hitch
    - a session split into two panes ("split with existing"): select different text in each; Cmd+C
      and the context-menu Copy each copy the pane they target (Phase 3)
  - Re-measure hidden-renderer cost with many sessions open. Add an LRU cap only if the numbers
    after Phase 2 call for one (see Phase 0 results).
  - Update `Docs/bugs.md` (Bug 84 fixed; Bug 80 status), `Docs/featurelist.md` and the CLAUDE.md
    gotchas: the surface model is owned by the store, not the view.
  - **As built (2026-10-15).** Relaunched Debug build (process 02:01:46, binary 02:01:40), local
    zsh sessions, the developer's CRT and bloom settings, user at the keyboard.
    - **Passed:** selection and copy survive tab switch, split/unsplit and maximize; the scroll
      position survives; with one session in two panes, Cmd+C and the context-menu Copy each copy
      the pane they target.
    - **Failed, filed separately:** every tab switch, including back to a visited tab, shows a
      brief brightness change (Bug 89). Not diagnosed; the likely cause is the CRT/bloom textures
      that detach frees, so the first frame after reattach has no CRT previous frame. The user
      chose not to block Bug 84 on it.
    - **Found:** in a split layout a tab click only changes the selected tab; no pane shows that
      session (Bug 88, older than Bug 84). The 7 sessions first visited from a split therefore
      had no renderer until the layout was unsplit.
    - **Memory** (`heap <pid>` and `footprint`, Debug, 2x). Renderers exist only for sessions
      that have been shown:

      | State | Renderers | Metal (IOAccelerator) | `phys_footprint` |
      |---|---|---|---|
      | Launch, no session | 0 | — | 38 MB |
      | 11 sessions, 3 shown | 3 | 57 MB | 308 MB |
      | 11 sessions, all shown, 1 visible | 11 | 186 MB | 473 MB |

      Each extra hidden renderer costs **~16 MB of Metal** (its one atlas page) and **~21 MB of
      footprint**, as Phase 0 predicted. `leaks --traceTree` rooted all 11 models in the store's
      dictionary (11 entries, 11 `zsh` children), so none leaked.
    - **Decision: no LRU cap.** 20 hidden sessions cost ~400 MB, more only after heavy Unicode
      output in each. A shared glyph atlas (Open questions) would save more than a cap.

## Phase 0 results (2026-10-14)

Instrumentation lived on `debug/bug84-surface-rebuild` (commit `0f163cc`, never merged):
`os.Logger` category `rebuild` at model init/deinit, surface/pane/window appear and disappear with
per-identity `@State` tokens, layout inputs in `TerminalView`, and a memory line
(`phys_footprint`, `MTLDevice.currentAllocatedSize`, atlas pages). Two sources:

- **Probe:** `Bug84RebuildProbeTests` hosts the real `TerminalView` in a 1400×800 window with the
  three screenshot sessions and drives its tab and pane managers, holding strong renderer refs so
  identity comparisons are sound. It prints rather than asserts. It ran with the developer's CRT
  and bloom settings, at 2x scale.
- **Live:** a relaunched Debug build (process 15:51:26, binary 15:51:03), 9 local sessions, user
  at the keyboard.

### Which layout changes rebuild the surface

| Change | Probe | Live | Notes |
|---|---|---|---|
| Tab switch | rebuilt | rebuilt (8 switches) | Switching back does not get the old renderer back; the hidden one is freed ~40 ms later |
| Split | rebuilt, both sessions | rebuilt, both sessions (twice) | Single ↔ split changes the `macOSBody` branch, so every `TerminalPaneView` is new too |
| Unsplit | rebuilt | rebuilt, **twice** | The layout change and the selection change land in separate updates. An interim renderer lived ~300 ms and was freed |
| Pane maximize / restore | rebuilt, both ways | not exercised | The live run toggled Maximize Terminal (`terminalOnly`) instead: no rebuild, so the Bug 82 fix holds |
| Move to new tab | rebuilt | not exercised | No layout change was logged |
| Pop-out window | — | fresh renderer in the new window | The main window keeps its own renderer for the session; closing the pop-out frees only the pop-out's |

So in the main window every listed change rebuilds, which is broader than the Overview expected:
splits rebuild *every* visible session, not just the one that moved. The store fixes all of them
at once, because none of these depends on where the view sits.

### What a renderer costs (Metal, 2x)

- **Never attached to a view:** ~0.1 MB. Pipelines and buffers are negligible; the atlas page and
  all offscreen textures are created on the first attach and draw.
- **Attached:** each extra visible pane added 50–58 MB in the probe, and a full-window renderer
  ~70 MB live. Breakdown of one full-width probe pane (texture 1326×1313):

  | Item | MB | Scales with |
  |---|---|---|
  | Glyph atlas, 1 page | 16.0 | glyph variety, in 16 MB pages |
  | `postProcessTexture` | 7.0 | drawable size |
  | `previousFrameTexture` (CRT) | 7.0 | drawable size |
  | Bloom (3 half-res textures) | 5.8 | drawable size |
  | Cell buffers | 0.2 | grid size |
  | Drawables (CAMetalLayer, only while visible) | ~15–20 | drawable size |

- **Atlas fill:** `cat`ting 12,896 CJK, Hangul, box-drawing and emoji glyphs grew one session's
  atlas from 1 to 5 pages (16 → 80 MB). The process had 164 MB of Metal allocated, against 72 MB
  after that renderer was freed.
- **Hidden renderer (kept alive):** keeps everything except its drawables. That is ~36 MB at the
  probe's pane size, plus whatever atlas pages it has filled. Today a hidden session costs nothing,
  because its renderer is freed: 9 open sessions measured 72 MB Metal total. A store that keeps 9
  full-window renderers as they are would add roughly 8 × 40 MB ≈ 320 MB.

### Decision

- **On detach, release the drawable-sized offscreen textures and keep the atlas** (Phase 2). That
  takes a hidden renderer down to its atlas, 16 MB typical, and they rebuild for free on the next
  draw. Dropping the atlas would bring back part of the rebuild hitch (re-rasterizing every glyph),
  so the atlas stays.
- **No cap or eviction for now.** With textures released, 20 hidden sessions cost ~320 MB only in
  the unusual case where each has filled 1 page; more pages need heavy Unicode output in that
  session. Phase 5 re-measures, and an LRU cap on hidden renderers is the fallback if it matters.
- **Shared atlas:** this is now the largest remaining hidden cost, but it is a separate change
  (atlas eviction and per-renderer glyph caches would become shared state). It is not part of
  Bug 84.

## Open questions

- ~~Should a background session's renderer drop its glyph atlas pages while hidden?~~ No. See
  Phase 0 decision: release the drawable-sized textures instead, and keep the atlas.
- Would one glyph atlas shared across renderers with the same font and scale give most of the
  remaining memory back? After Phase 2 it is the dominant hidden cost (16 MB per session, up to
  80 MB+ after heavy Unicode output). Separate change, decide after Phase 5's measurement.
