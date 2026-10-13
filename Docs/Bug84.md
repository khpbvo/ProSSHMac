# Bug 84 — Keep One Terminal Renderer per Session Across Layout Changes

Bug register entry: `Docs/bugs.md` Bug 84. Follows Bug 82 (fixed 2026-10-13).

## Overview

**Problem.** `MetalTerminalSessionSurface` owns its `MetalTerminalSurfaceModel` — and through it the
session's `MetalTerminalRenderer` — as a `@StateObject`. The renderer therefore lives exactly as long as
SwiftUI keeps that view's identity, and identity is tied to the view's position in the tree. Bug 82
fixed one trigger (Maximize Terminal moved the surface to a different build site). Others remain,
expected from the code but not yet measured live:

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

- [ ] **Phase 0: Measure before changing anything.**
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
- [ ] **Phase 1: `TerminalSurfaceModelStore`, with no view changes yet.**
  - Write the store with create-on-demand, `release(sessionID:)` and `prune(keeping:)`, plus
    unit tests:
    - the same model is returned for the same session
    - a released model is deallocated, checked with a weak reference
    - prune drops closed sessions
- [ ] **Phase 2: The main window uses the store.**
  - `TerminalView` owns the store and prunes it on `sessionManager.sessions` changes.
    `TerminalSurfaceView` passes the model through, and `MetalTerminalSessionSurface` takes it as
    an `@ObservedObject`.
  - Attach/detach use the per-view token rule: pause, `scrollJumpTo`, the 150 ms snapshot
    re-apply and register all follow it.
  - Extend `TerminalSurfaceIdentityTests` (each red before the change):
    - a tab switch and switching back keeps each session's renderer
    - split then unsplit keeps the original renderer
    - pane maximize keeps the renderer
    - a closed session's renderer is released
- [ ] **Phase 3: Fold `TerminalSelectionCoordinator` into the store.**
  - Copy, select-all and has-selection look up `store.model(for:)`. Delete the register/unregister
    registry, and update the Bug 81 tests to the new API without losing what they cover.
  - Re-run the copy suites (`TerminalSelectionInteractionTests`, `TerminalInputCaptureViewTests`,
    `MouseInputCaptureViewTests`).
- [ ] **Phase 4: Pop-out window.**
  - `ExternalTerminalWindowView` gets its own store. A session moved to a pop-out window gets a
    fresh renderer there; renderers are per window, never shared across windows.
  - Check whether the main window should release its model when a session moves out.
- [ ] **Phase 5: Live validation and memory policy.**
  - On a relaunched build:
    - select text, switch tabs and back: the selection is still there and copy works
    - same for split/unsplit and maximize
    - the scroll position survives
    - no visible redraw hitch
  - Apply the Phase 0 memory decision if a cap is needed.
  - Update `Docs/bugs.md` (Bug 84 fixed; Bug 80 status), `Docs/featurelist.md` and the CLAUDE.md
    gotchas: the surface model is owned by the store, not the view.

## Open questions

- Should a background session's renderer drop its glyph atlas pages while hidden, and rebuild them
  on show? That trades memory for a smaller version of the same hitch. Decide in Phase 0 from the
  numbers.
- Would one glyph atlas shared across renderers with the same font and scale give most of the
  memory back? That would be a separate change, only worth doing if Phase 0 shows memory matters.
