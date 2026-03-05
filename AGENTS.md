# AGENTS Working Memory

This file is the project working memory for future assistants in this repository.

## Long-Term Memory Source

- The long-term memory document for this project is: `Docs/featurelist.md`.
- Always read `Docs/featurelist.md` before starting substantial work.
- Use `Docs/featurelist.md` as the authoritative checklist, phase plan, and project status record.
- At the start of each task, explicitly align on:
  - Starting Point (current reality)
  - End Point (definition of done)
  and ensure both are represented in `Docs/featurelist.md`.

## Persistence Loop (Required)

- After completing any task, always update `Docs/featurelist.md` to reflect:
  - What was done
  - What is still pending
  - Any scope, architecture, or sequencing changes
- If process/instruction-level guidance changed, also update `AGENTS.md`.
- Add a short dated entry to the loop log in `Docs/featurelist.md` whenever a meaningful milestone is completed.

## Context-Loss Safeguard

- Keep both `AGENTS.md` and `Docs/featurelist.md` current at all times.
- This is mandatory to preserve continuity across assistant handoffs and in cases of context loss, overflow, or truncated history.

## Current Status Snapshot

- Latest status refresh (2026-03-05): this file should be read as a high-signal snapshot only; `Docs/featurelist.md` remains the authoritative long-term record and still requires `gpt-5.1-codex-max` for long-running implementation tasks.
- Latest terminal scroll stabilization (2026-03-05): live-output scrolling now preserves/clamps the current scrollback offset during publish cycles, compensates for scrollback growth, and avoids stale-offset races in `scrollTerminal`, so users can stay scrolled up while commands such as `ping` continue printing.
- Latest scrollbar regression fix (2026-03-05): `TerminalScrollbarView` interaction is constrained to a narrow trailing strip (`interactionWidth = 18`), restoring wheel scrolling in Metal terminal panes while keeping drag-to-scroll available.
- Latest smooth-scroll jitter fix (2026-03-05): `SmoothScrollEngine.jumpTo(row:)` is now a no-op when asked to jump to the current target row, preserving fractional motion and momentum during active gestures instead of snapping each time a snapshot publish re-syncs the same row.
- Latest renderer optimization worktree change (2026-03-05, build-verified, uncommitted): `GlyphRasterizer` now uses a reusable scratch buffer and cached `CGContext`, `MetalTerminalRenderer` owns a long-lived rasterizer for main-thread misses/prepopulation, and background glyph batches reuse a per-batch rasterizer instance. This working-tree state matches the new `Docs/featurelist.md` entry and built successfully with `xcodebuild -project ProSSHMac.xcodeproj -scheme ProSSHMac -destination 'platform=macOS' build`.
- Current foreground track: smooth-scroll polish has landed; renderer/throughput optimization is the active in-progress stream, with planning and phase checklists in `docs/Optimization.md`, `docs/OptimizeP2.md`, and `docs/OptimizeP3.md`.
