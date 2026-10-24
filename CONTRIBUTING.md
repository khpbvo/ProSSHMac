# Contributing to ProSSHMac

Thanks for your interest. ProSSHMac is a native macOS SSH client with a Metal-rendered terminal and an AI copilot. It's built by a small team, and outside help is very welcome. You don't need to write Swift to make a real difference: testing on network gear, reproducing bugs and improving docs all count.

## Ways to help

- **Fix a known issue.** The README's [Known limitations](README.md#known-limitations) and the open entries in [`Docs/bugs.md`](Docs/bugs.md) list real, scoped problems. Bug entries name their files and often a fix direction.
- **Test on network devices.** Prompt patterns ship for Cisco IOS/IOS-XE, Juniper JunOS, Arista EOS, MikroTik RouterOS, Palo Alto PAN-OS, HP/Aruba ProCurve, Fortinet FortiOS and Nokia SR OS. Most have never run against real hardware. A report saying "this prompt wasn't detected, here's what it looks like" is valuable on its own.
- **Pick up a roadmap item.** The ranked plan is [`Docs/The big picture(October 2026).md`](<Docs/The big picture(October 2026).md>). Each entry names the spec file it should become.
- **Improve docs and tests.** Examples, clearer explanations, and coverage for untested paths are all welcome.

Issues labelled [`good first issue`](https://github.com/khpbvo/ProSSHMac/labels/good%20first%20issue) are a good start. Comment on an issue before you start, so work isn't duplicated.

## Setting up

You need macOS 26.0 or later, and Xcode 27 with the Metal Toolchain component (`xcodebuild -showComponent metalToolchain`). libssh and OpenSSL are vendored, so there is nothing else to install.

```bash
git clone https://github.com/khpbvo/ProSSHMac.git
cd ProSSHMac
open ProSSHMac.xcodeproj   # ProSSHMac scheme, Cmd+R
```

You only need more to rebuild the vendored libraries: `scripts/build-vendor.sh` builds them from pinned, checksummed sources and needs CMake 3.23 or newer (Ninja is optional). It writes to `build/vendor/stage/` and never touches `Vendor/`.

Build and test from the command line:

```bash
xcodebuild -project ProSSHMac.xcodeproj -scheme ProSSHMac -destination 'platform=macOS' build

# Run the suites your change touches
xcodebuild -project ProSSHMac.xcodeproj -scheme ProSSHMac -destination 'platform=macOS' \
  test -only-testing:ProSSHMacTests/<TestClassName>
```

Tests live in `ProSSHMacTests/`, mostly under `ProSSHMacTests/Terminal/Tests/`. Some suites need the host app, so run them through the scheme as shown.

## Project memory: the three documents

The project keeps its knowledge in three places. They are written so that a person or an AI coding assistant can pick up work cold.

| File | Role |
|---|---|
| [`CLAUDE.md`](CLAUDE.md) | **Working memory**: current architecture, conventions, key files and known gotchas. Read it before changing code. Despite the name, it is for every contributor and every tool. |
| [`Docs/featurelist.md`](Docs/featurelist.md) | **Long-term memory**: a dated log of what changed and why, newest first |
| `Docs/<Feature>.md` | **Feature spec**: a phased checklist for one feature or refactor |

`CLAUDE.md`'s "Known Issues & Gotchas" section exists because each item there once cost real time. Read it before touching the terminal pipeline, the renderer or the AI tools.

## Workflow

### Small changes

Bug fixes, docs, tests and other contained changes: branch from `master`, make the change, and open a PR. Explain the root cause, not only the symptom.

### Features and refactors: plan first

Anything that spans several files or adds behaviour starts with a written plan:

1. Read `CLAUDE.md` and the recent entries in `Docs/featurelist.md`.
2. Read the code the feature touches, so you know where each new file goes, what it extends and what it must not break.
3. Write `Docs/<YourFeature.md>`: an overview (goal, architecture sketch, affected files), then phases written as `- [ ] Phase N: <title>`, each one session's worth of work. Make every step concrete and checkable: "add `foo()` to `Bar.swift` that returns Z", not "implement X". End each phase with updating `CLAUDE.md` (if conventions or key files changed) and adding a dated entry to `Docs/featurelist.md`.
4. **Open a draft PR containing only the plan** and wait for maintainer review. This catches design problems before they become code.
5. Once the plan is approved, implement it phase by phase and check off each phase as it lands.

This works the same whether you write every line yourself or use an AI assistant (Claude Code, Cursor, Codex). Point the assistant at `CLAUDE.md` and the spec, and have it plan the current phase before writing code.

## Code conventions

The details are in `CLAUDE.md`. The ones that trip people up most:

- **Concurrency**: Swift 6 language mode with default `MainActor` isolation. `TerminalGrid+*.swift` methods must be explicitly `nonisolated`. `@MainActor` types that can deallocate off the main actor need a `nonisolated deinit`.
- **State**: `ObservableObject` + `@StateObject`, not `@Observable`. Don't add `@Published` writes on `SessionManager` that fire while output streams: each one re-runs every view that observes it.
- **Structure**: one responsibility per file. Large types are split into `Type+Concern.swift` extensions (see `TerminalGrid` and `AIToolHandler`). A few files are still over 1,000 lines; read around before editing them.
- **Tests**: tests must not read your real `UserDefaults`, saved model or API keys. Use the injected defaults suites.
- **Style**: match the surrounding code. Prefer descriptive names to comments, and use comments to explain *why*.

## Adding an AI tool

1. Define the schema in `buildToolDefinitions` in `ProSSHMac/Services/AI/AIToolDefinitions.swift`. Larger tools get their own definition type, like `SendInputToolDefinition`.
2. Handle it in `executeSingleToolCall` in `AIToolHandler.swift`. Put non-trivial logic in an `AIToolHandler+YourTool.swift` extension.
3. If it belongs in direct-action mode, add it to `directActionToolDefinitions`.
4. Add a case to `AIToolContractTests`, which runs every exposed schema on valid minimal input.
5. Update the tool list in `CLAUDE.md` and the README.

Tool design rules:

- Return structured results. Errors are `{ok: false, error, hint}`, and the hint is required: it tells the model what to do next.
- Every tool takes `target_session`. Validate it, and respect broadcast mode.
- Anything that changes files or configuration goes through user approval, like `apply_patch`'s diff card.
- Check for cancellation before each side effect, so Stop and Clear actually stop.

## Pull requests

A PR is ready when:

- [ ] The build succeeds with no new warnings you introduced.
- [ ] The test suites for the code you changed pass, and new behaviour has tests.
- [ ] CI is green. It builds unsigned and runs the suites listed in `.github/workflows/ci.yml`; suites that need the keychain, a window or a real shell run only locally.
- [ ] For a feature, every checkbox in its `Docs/<Feature>.md` is checked.
- [ ] `CLAUDE.md` reflects any change to architecture, conventions or key files.
- [ ] `Docs/featurelist.md` has a dated entry describing the change.
- [ ] No credentials, keys or personal hostnames appear in code, logs, tests or screenshots.

Don't bump `MARKETING_VERSION` or `CURRENT_PROJECT_VERSION`; the maintainer does that at release time.

## Versioning

ProSSHMac follows [SemVer](https://semver.org/). The current version is **0.9.0**. Until 1.0 the feature set and UI can still change. 1.0 ships once the high-severity bugs in `Docs/bugs.md` are fixed and the release-readiness work (updated dependencies, real CI, signed auto-updating releases) is done.

## Questions and reports

- **Bugs and feature requests**: [GitHub Issues](https://github.com/khpbvo/ProSSHMac/issues), using the templates
- **Security issues**: privately, as described in [SECURITY.md](SECURITY.md)
- **Conduct**: everyone taking part agrees to the [Code of Conduct](CODE_OF_CONDUCT.md)

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
