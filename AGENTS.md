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

- Latest milestone (2026-02-23): terminal file-browser tree/lazy-load work now has dedicated helper logic and test coverage.
- Next implementation phase is tracked in `Docs/featurelist.md` under Phase 3 (command-block history index).
