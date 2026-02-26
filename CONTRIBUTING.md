# Contributing to ProSSHMac

Welcome. If you're reading this, you're probably a sysadmin, network engineer, or developer who saw an AI configure a MikroTik through natural language and thought "I want in." Good. We need you.

ProSSHMac is an open-source macOS SSH client with an AI Terminal Copilot that can understand, navigate, and configure anything it's connected to — Linux servers, MikroTik routers, and eventually every piece of network hardware that speaks SSH.

**Who needs CCNA when you've got ProSSH?**

## How This Project Works

This project uses an AI-assisted development workflow. Whether you're working with Claude Code, Cursor, Copilot, or writing every line by hand, the process follows the same structure. The system is designed so that a contributor — human or AI — can pick up any task cold and execute it.

### The Three Documents

Every contributor should understand these three files before touching code:

**`CLAUDE.md`** — Working Memory

This is the brain of the project. It contains architecture notes, project rules, coding conventions, current state, and everything a contributor needs to know *right now* to work in this codebase. Read this first. Always. If you're using an AI coding assistant, this is the file it should read before doing anything.

**`docs/featurelist.md`** — Long-Term Memory

The history book. Every feature that exists, every refactor that happened, every decision that was made. When you need to understand *why* something is the way it is, look here. When you start or complete work, log it here.

**`docs/[YourFeature].md`** — The Implementation Plan

For any significant feature or refactor, a phased implementation plan is created before any code is written. This is a detailed, step-by-step checklist broken into phases, where each phase can be completed in a single focused session. More on this below.

### The Development Cycle

```
1. Read CLAUDE.md and docs/featurelist.md in full
2. Explore the codebase — find every file the feature touches
3. Write docs/YourFeature.md — extensive phased checklist
4. ── HARD STOP ── Open a draft PR with only the plan file, wait for maintainer approval
5. Branch from main
6. Execute phase by phase
7. Update CLAUDE.md and docs/featurelist.md after each phase
8. ── HARD STOP ── Every checkbox in docs/YourFeature.md must be checked before opening a real PR
```

## Designing a Feature (Required First Step)

Before a single line of code is written, every feature must go through a design step that produces a `docs/YourFeature.md` plan file. No plan file = no implementation = no PR.

This step is **mandatory** whether you are a human contributor or an AI coding assistant (Claude Code, Cursor, Codex, etc.). The instructions below are written to be followed directly by an AI session — point it at this file and it knows exactly what to do.

### The Design Process

**Step 1 — Read the project memory**

Read these two files in full. Do not skip or skim. Do not start exploring or planning until both are fully read.

```
CLAUDE.md           ← architecture, conventions, current state, key files
docs/featurelist.md ← history, what exists, what was decided and why
```

**Step 2 — Explore the codebase**

Search and read the files that are relevant to the feature. You are looking for:

- Which existing files and types will this feature touch or extend?
- What patterns, protocols, and actor boundaries already exist that you must follow?
- Does `docs/bugs.md` or `docs/FutureFeatures.md` mention constraints or prior art for this area?
- Are there related coordinators, view models, or services that this feature integrates with?

Do not begin writing the plan until you have read enough actual code to know where every new file goes, what it extends, and what it must not break. Plans written from guesses produce code that doesn't compile.

**Step 3 — Write the plan**

Create `docs/YourFeature.md`. The plan must satisfy all of the following:

- **Phased** — each phase is a self-contained chunk of work completable in one focused session
- **Granular** — every step is a concrete, verifiable action. Not "implement X", but "add method `foo()` to `Bar.swift` that does Y and returns Z"
- **Extensive** — if you think you have enough steps, add more. Every file to be created or modified gets its own step. Sub-steps (`3a`, `3b`) for anything with multiple parts.
- **Checkboxable** — every step uses `- [ ]` syntax so completion state is unambiguous

Every phase must end with these two steps:
```
- [ ] Update CLAUDE.md if any architecture, file locations, or conventions changed
- [ ] Update docs/featurelist.md with a dated loop-log entry
```

**Step 4 — Stop. Open a draft PR with only the plan file.**

Do not branch. Do not write any implementation code. Commit `docs/YourFeature.md` to a new branch and open a **draft PR** with that single file. The PR description should summarise:

- What the feature does
- What files it will touch
- Any architectural decisions made and why

Then wait. The maintainer will review the plan and either approve it or request changes. Only after the draft PR receives explicit approval do you close it, branch properly, and begin Phase 1.

This gate exists so the maintainer can catch design mistakes before they become code debt — and so that any AI session that produced the plan can be held accountable to it.

## Writing Implementation Plans

This is the core of how work gets done here. A good implementation plan is the difference between a clean feature and a chaotic mess.

### Structure

Plans live in `docs/` and follow this naming: `docs/MultiSessionOrchestration.md`, `docs/CiscoIOSSupport.md`, etc.

A plan is a **phased checklist** where:

- **Phases** are context-window-sized chunks of work. One phase = one focused session.
- **Steps** within a phase are concrete, atomic actions. Not vibes. Not goals. Actions.
- Each phase is **independently executable** — a fresh contributor should be able to pick up Phase N knowing only CLAUDE.md, featurelist.md, and the plan.

### Example

```markdown
# Multi-Session AI Orchestration

## Phase 1 — Session Registry and Identification
- [ ] 1. Create `SessionRegistry.swift` in `Services/`
- [ ] 2. Define `SessionIdentifier` struct (id, label, deviceType, sessionRef)
- [ ] 3. Add `registerSession()` and `deregisterSession()` methods
- [ ] 3a. Ensure thread safety with actor isolation
- [ ] 4. Add `activeSessions` computed property returning all connected sessions
- [ ] 5. Write unit tests for register/deregister lifecycle
- [ ] 6. Update CLAUDE.md with SessionRegistry architecture notes
- [ ] 7. Update featurelist.md with Phase 1 completion entry

## Phase 2 — Device Type Detection
- [ ] 1. Create `DeviceDetector.swift` in `Services/AI/`
- [ ] 2. Define `DeviceType` enum (linux, macOS, routerOS, ciscoIOS, junOS, unknown)
- [ ] 3. Implement prompt-pattern matching for each device type
- [ ] 3a. RouterOS: `[admin@MikroTik] >`
- [ ] 3b. Cisco IOS: `Switch#`, `Router(config)#`
- [ ] 3c. JunOS: `user@router>`
...
```

Notice the granularity. Step 3a is a sub-step. Every step is something you can verify worked before moving on. There's no ambiguity about what "done" looks like.

### Why Phases?

If you're working with AI coding assistants (and we encourage it), a single context window can reliably complete about one phase of work. The workflow is:

1. Start a fresh AI session
2. Point it at CLAUDE.md, featurelist.md, and the implementation plan
3. Ask it to plan Phase N in detail
4. Let it execute
5. Verify the build succeeds and tests pass
6. Commit, update docs, move on

This also works perfectly for human contributors. A phase is roughly a focused afternoon of work. You don't need to hold the entire project in your head — just the current phase and the three documents.

## AI Tool Development

The AI Terminal Copilot is the heart of what makes ProSSHMac unique. If you're contributing new AI tools, there are specific conventions to follow.

### Tool Architecture

AI tools are defined as structured function calls that the AI model can invoke. Each tool has:

- A **name** (snake_case, descriptive)
- A **description** (clear enough that the AI understands when and why to use it)
- **Parameters** with types and descriptions
- A **handler** that executes the action and returns results

### Current Tool Categories

| Category | Tools |
|---|---|
| Terminal Context | `get_current_screen`, `get_recent_commands`, `get_command_output`, `search_terminal_history` |
| Command Execution | `execute_command`, `execute_and_wait` |
| Interactive Input | `send_input` (write directly to running process — prompts, Ctrl+C, REPLs, etc.) |
| Filesystem | `search_filesystem`, `search_file_contents`, `read_file_chunk`, `read_files` |
| File Editing | `apply_patch` (V4A diff format, user approval flow) |
| Session Info | `get_session_info` |

### Adding a New Tool

1. Define the tool schema (name, description, parameters) in `ProSSHMac/Services/AI/AIToolDefinitions.swift`
2. Implement the handler in `ProSSHMac/Services/AI/AIToolHandler.swift` (add a `case "your_tool":` branch in `executeSingleToolCall`). For non-trivial handlers, extract the logic into a new `AIToolHandler+YourTool.swift` extension file.
3. Add the tool name to the relevant allowed-tool-set arrays in `AIToolDefinitions.swift`
4. Test locally with the AI copilot — ask it to use the new tool in a natural conversation
5. Update `CLAUDE.md` with the new tool's existence and purpose
6. Update `docs/featurelist.md`

### Tool Design Principles

- **Tools must be CLAUDE.md compatible.** If an AI assistant reads CLAUDE.md, it should understand what the tool does, when to use it, and what it returns. Your tool description is documentation for both humans and AIs.
- **Return structured, parseable output.** The AI needs to understand the result. Don't return raw terminal noise when a clean summary will do.
- **Respect session boundaries.** Tools operate on specific sessions. Always include session context.
- **Fail gracefully.** If a command times out or a file doesn't exist, return a clear error the AI can reason about — not a crash.
- **User approval for destructive actions.** Any tool that modifies files or changes configuration must go through the approval flow (modal diff preview for patches, confirmation for deletions).

## Multi-Device / Multi-Session Work

This is the frontier. ProSSHMac supports multiple terminal sessions (up to 4). The current AI copilot operates on a single session. The next major milestone is **multi-session orchestration** — letting the AI reason across multiple connected devices and execute coordinated changes.

If this is what excites you, check the issues tagged `multi-session` and the implementation plan in `docs/`.

## What We Need

### Device Support
The AI copilot currently works on Linux/macOS and MikroTik RouterOS. We need people who know:
- **Cisco IOS/IOS-XE** — prompt detection, command patterns, mode awareness
- **Juniper JunOS** — CLI structure, commit model
- **Arista EOS** — similar to IOS but with differences
- **Ubiquiti EdgeOS/UniFi** — Vyatta-derived CLI
- **Palo Alto PAN-OS** — security appliance CLI
- **Any other SSH-accessible network OS**

You don't need to be a Swift developer to help here. If you can document the CLI patterns, prompt formats, and common command sequences for a device type, that's enormously valuable.

### Core Development (Swift/macOS)
- Multi-session AI orchestration
- Provider abstraction (OpenAI, Anthropic, Ollama)
- Terminal rendering improvements
- SFTP integration with AI tools
- Undo/rollback for patches
- Clipboard integration

### Documentation and Testing
- Architecture documentation
- Tool usage examples
- Test coverage for AI tool handlers
- Device-specific testing (if you have the hardware)

## Getting Started

```bash
# Clone the repo
git clone https://github.com/khpbvo/ProSSHMac.git
cd ProSSHMac

# Open in Xcode
open ProSSHMac.xcodeproj

# Read the brain
cat CLAUDE.md

# Read the history
cat docs/featurelist.md

# Build and run
# Cmd+R in Xcode
```

### Your First Contribution

1. Browse issues labeled `good-first-issue`
2. Comment on the issue that you're picking it up
3. Read CLAUDE.md and featurelist.md
4. Branch, implement, PR
5. If using AI assistance, follow the phased workflow described above

## Code Style

- Swift conventions as enforced by SwiftLint (config in repo)
- Single-responsibility files — if a file grows past ~500 lines, it's time to extract
- Descriptive naming over comments
- Actor isolation for concurrency
- The 20-phase refactor that decomposed the god files is the reference for how we structure code here

## Communication

- **GitHub Issues** — for bugs, feature requests, and task tracking
- **GitHub Discussions** — for questions, ideas, and architecture debates
- **Pull Requests** — one PR per completed feature. See PR requirements below.

## PR Requirements

PRs are merged only when a feature is **fully complete**. A half-finished phase or work-in-progress does not qualify.

To open a PR you must:

1. **Every checkbox in your `docs/YourFeature.md` is checked.** This is the proof of completion. If a box isn't checked, the work isn't done.
2. **The build succeeds.** Run `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build` and confirm zero errors.
3. **Tests pass.** Run `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' test` and confirm no regressions.
4. **`CLAUDE.md` is updated** with any architectural changes, new files, or changed conventions.
5. **`docs/featurelist.md` is updated** with a dated loop-log entry for the completed feature.

No exceptions. A checked plan file is the contract. If you can't check every box, keep working.

## Versioning

ProSSHMac uses [SemVer](https://semver.org/): `MAJOR.MINOR.PATCH`.

| Version range | Meaning |
|---|---|
| `0.x.x` | Pre-1.0 — core is stable but the feature set is still growing. UX and APIs may change. |
| `1.0.0` | First stable, feature-complete release. |
| `1.x.0` | New features, backwards compatible. |
| `1.x.y` | Bug fixes only. |

**Current version: `0.9.0`** (build 1) — first public open-source release.

### Road to 1.0

`1.0.0` ships when all of the following are true:

- [ ] Known critical and high-severity bugs from `docs/bugs.md` are resolved
- [ ] At least one additional AI provider works (Anthropic Claude or Ollama)
- [ ] Multi-session AI orchestration or inline image protocol (Kitty) is shipped

### Version bumps are the maintainer's job

Contributors do not bump version numbers. Do not change `MARKETING_VERSION` or `CURRENT_PROJECT_VERSION` in `project.pbxproj` as part of a feature PR — the maintainer handles this at release time.

**How versions are stored:** `MARKETING_VERSION` (`CFBundleShortVersionString`) and `CURRENT_PROJECT_VERSION` (`CFBundleVersion`) are set directly in `ProSSHMac.xcodeproj/project.pbxproj`. The build number is a monotonically increasing integer that must increment with every release build submitted for notarization.

## License

MIT. Do whatever you want with it. Just build something cool.

---

*ProSSHMac is built by someone who'd rather talk to a MikroTik than a human. If you're the same kind of person, you'll fit right in.*
