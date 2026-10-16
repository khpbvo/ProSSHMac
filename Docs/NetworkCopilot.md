# Network Copilot — every session, one memory, specialist skills

Make the AI copilot work like a network specialist across several machines at once: reach every
open session, keep one memory per chat, run commands on routers and switches as well as shells,
and load expert playbooks ("skills") for the job at hand.

## Overview

**Why.** Reported 2026-10-15 with a screenshot: four SSH sessions to Ubuntu VMs cloned from one
image, the user asked the copilot (Claude Opus 5.5) to "find everything that's still identical
between them that shouldn't be, and fix it". It reached one server, then said it had no history
of the task. Root causes, confirmed in code:

1. **Reach.** The copilot gets the other sessions only in broadcast mode (`TerminalView.swift`
   `aiAssistantPane.onSend`: `inputRoutingMode != .singleFocus ? targetSessionIDs : nil`).
   Broadcast was off (no "Broadcast" pane badge or "Broadcasting" toolbar label), so it saw only
   the focused pane. Without broadcast it receives no list of sessions or their IDs and has no
   tool to discover them, so the other three were unreachable.
   (`AIToolHandler.resolveTargetSessions` would already accept any session ID outside broadcast.)
2. **Memory.** The chat pane shows one message list per window (`TerminalAIAssistantViewModel.
   messages`), but the model's memory is per session (`AIConversationContext`, keyed by the
   focused session at send time). Focusing another pane between prompts gives the model an
   empty history while the chat still shows the earlier turns.
3. **Device CLIs.** `execute_and_wait` and the remote file helpers wrap commands in POSIX shell
   syntax with OSC 7777 markers (`SessionAIToolCoordinator.swift:25`). Router/switch CLIs (Cisco
   IOS, Junos, RouterOS, EOS…) reject that line and never emit the completion marker, so every
   command would time out. Only `send_input` + `get_current_screen` work there today.

**Decisions (user, 2026-10-15).**
- The copilot may reach **all open sessions**. Broadcast mode only changes the default target:
  with broadcast on, an untargeted command goes to the broadcast panes; off, to the focused pane.
- **One chat, one memory**: what the chat shows is what the model remembers, whichever pane is
  focused. Each turn states which session is focused.
- **Skills** are built-in playbooks for working on remote boxes "like a network specialist":
  VMs, routers and switches.

### Architecture sketch

- **Session map per turn.** The user message of each turn starts with a table of every connected
  session: id, label, user@host:port, local/SSH, focused, in broadcast set, and the device type
  once known. Appended to the conversation like today's screen snapshot, so it keeps the Anthropic
  prefix append-only. A `list_sessions` tool refreshes it mid-turn (sessions can connect or drop).
- **Target resolution.** `target_session` accepts any connected session; null means "the default
  set" (broadcast panes, or the focused pane). Results from several sessions keep today's
  `[label]` sections.
- **One conversation per chat.** `AIConversationContext` keys by a chat id owned by the chat pane
  (one per window), not by the focused session. Clear starts a new chat. The focused session
  becomes per-turn metadata.
- **Device command path.** A `run_cli_command` tool for non-POSIX CLIs: send the line, wait until
  the device prompt returns (prompt pattern learned from the screen, plus a quiet period),
  disable paging first, return the output between the echoed command and the next prompt.
  `execute_and_wait` refuses with a hint when the session is a known device CLI.
- **Skills.** Markdown playbooks with a name and one-line description: bundled in the app, plus
  a user folder (`~/Library/Application Support/ProSSHMac/Skills/`). The system prompt lists
  names + descriptions only; a `load_skill(name)` tool returns the full text (progressive
  disclosure, small prompt). Skill set fixed per conversation, so the Anthropic prefix stays
  stable.

### Affected files (expected)

`UI/Terminal/TerminalView.swift`, `ViewModels/TerminalAIAssistantViewModel.swift`,
`Services/AIAgentService.swift`, `Services/AI/AIAgentRunner.swift`,
`Services/AI/AIConversationContext.swift`, `Services/AI/AIToolHandler*.swift`,
`Services/AI/AIToolDefinitions.swift`, `Services/SessionAIToolCoordinator.swift`; new
`Services/AI/AISkillLibrary.swift`, `Resources/Skills/*.md`; tests in `AIAgentServiceTests`,
new `AISkillLibraryTests`, `DeviceCLITests`.

## Phases

- [x] **Phase 1: One chat, one memory.** Done 2026-10-15; see "Phase 1 as built".
  - Chat id owned by `TerminalAIAssistantViewModel` (new id on Clear); the service and runner key
    `AIConversationContext` by it. The focused session is passed per turn and named in the user
    message.
  - Keep the per-session tool defaults (the focused pane is the primary session).
  - Tests: two prompts with different focused sessions share history; Clear starts fresh;
    existing `AIAgentServiceTests` adapted.

- [x] **Phase 2: Reach every open session.** Done 2026-10-15; see "Phase 2 as built".
  - Session map in each turn's user message (all connected sessions; focused and broadcast
    flags); `list_sessions` tool; `resolveTargetSessions` validates ids against connected
    sessions (unknown/closed id → `{ok:false}` with the map as hint) and defaults to the
    broadcast set or the focused pane.
  - Developer prompt "BROADCAST" section rewritten as "SESSIONS": how to target, compare, and
    act per host; parallel tool calls across sessions.
  - Tests: untargeted command in single focus → focused only; explicit id of an unfocused
    session works; broadcast default unchanged; closed id rejected.

- [x] **Phase 3: Device CLI command path.** Done 2026-10-15; see "Phase 3 as built".
  - First, verify against a real or emulated device what the current tools do (expect
    `execute_and_wait` to time out). Then `run_cli_command(command, target_session,
    timeout_seconds)`: paging off once per session (`terminal length 0`, `set cli screen-length 0`,
    etc. by detected platform), prompt detection, output extraction, timeout handling.
  - Session kind detection from the prompt/banner (POSIX shell vs device CLI), shown in the
    session map; `execute_and_wait` refuses on device CLIs with a hint.
  - Tests with a scripted fake device (echo, prompt, `--More--` paging).

- [ ] **Phase 4: Harness first — nothing the model must remember because the code could not.**
  Reshaped 2026-10-16 (see "Design rules" below). Depends on `Docs/CredentialPrompt.md`
  Phases 0–3 (the password wait; it deletes the SUDO section and the `apply_patch` sudo dance).
  - Non-interactive execution: commands run by `execute_and_wait` must not stall on things the
    model cannot see coming: Ubuntu's `needrestart` dialog after `apt`, pagers on `systemctl`,
    `git` and `journalctl`, `apt` without `-y`, ssh host-key questions. Preferred: the wrapper in
    `SessionAIToolCoordinator.executeCommandAndWait` sets `DEBIAN_FRONTEND=noninteractive
    NEEDRESTART_MODE=a SYSTEMD_PAGER= PAGER=cat GIT_PAGER=cat` for that command only. Builder's
    call on the mechanism: it must neither leak into the user's shell nor lose `cd` (which
    persists today and direct-action mode depends on). If no mechanism satisfies both, the
    variables go into the `linux-host-operations` skill instead and this item says so.
  - Prompt audit: read `developerPrompt()` end to end and remove every rule that is a
    workaround for a harness gap, duplicated, or in tension with another (e.g. "use the minimum
    tool calls" vs "do not truncate diagnostic output"). The prompt keeps: what the harness is,
    how sessions and tools work, the invariants (never cut the path you are connected over,
    confirm before destructive commands, never expose secrets), and gains a three-line
    handover format that does not exist yet (what changed per host, how it was verified, how
    to undo it). Record the before/after line counts in `Docs/featurelist.md`.
  - No confirmation gate on unfocused hosts (decided 2026-10-16): the panes show every command
    as it runs. Remove the open question.
  - Tool contract sweep: a test that calls every exposed tool schema with valid minimal
    arguments against the mock provider and asserts no `{ok:false}`; every error path returns an
    actionable `hint`. Fix what it finds.
- [ ] **Phase 5: Skill library and `load_skill`.**
  - `AISkillLibrary`: bundled (`Resources/Skills/*.md`) + user folder
    (`~/Library/Application Support/ProSSHMac/Skills/`), front matter `name`, `description`,
    optional `platforms` (metadata returned by `load_skill`, never a filter on the index, which
    must not vary with the open sessions); a user skill with a bundled name overrides it;
    validation errors are logged and the skill skipped, never fatal.
  - The index in the system prompt is one line per skill (`name — description`), nothing more.
    Loaded once per conversation at chat start (decided: no live watch; a new chat picks up
    folder changes), so the Anthropic prefix stays fixed.
  - `load_skill(name)` returns the body; unknown name → `{ok:false, hint: <index>}`.
  - Settings row: "Open skills folder".
  - Tests: parsing, override, unknown skill, index stable across turns, folder absent.
- [ ] **Phase 6: Write the skills — shaped by the lifecycle, not the vendor.** Vendor syntax
  stays with the model. A skill is a procedure or a checklist a team would write down; it
  contains no rules ("never", "always" live in the prompt only, so nothing can conflict). Each
  under ~80 lines. Before closing the phase, read the prompt and all skills together once and
  strike any contradiction.
  - `change-procedure`: the method of procedure every change follows — pre-checks, steps,
    post-checks, rollback, staged rollout (one host, verify, then the rest). One line per
    platform safety net: Junos `commit confirmed`, IOS `reload in`, RouterOS safe mode, VyOS
    `commit-confirm`, nftables/iptables with a timed revert.
  - `baseline-and-diff`: capture state across hosts before touching anything, same read-only
    commands in parallel, diff, change, diff again.
  - `troubleshooting`: isolate by layer, change one variable, compare a working host with a
    broken one, capture when reasoning runs out.
  - `routing` (definition of done): adjacencies in the expected state on every neighbour,
    routes present on both ends, reachability both ways, persistence across restart, config
    saved. Covers OSPF/BGP/static; FRR and vendor CLIs alike.
  - `services` (definition of done, sysadmin): unit active and enabled, listening where
    expected, logs clean, survives restart, config validated before reload (`sshd -t`,
    `nginx -t`).
  - `access-safety`: never lock yourself out — keep a session open, validate before restarting
    sshd, firewall changes with a timer, check `sudo -n true` before planning root work.
  - `clone-deduplication`: the specific checklist (hostname, `/etc/hosts`, machine-id + D-Bus
    id, SSH host keys, DHCP DUID/client id, cloud-init instance id, static IPs/MACs, monitoring
    agent ids, iSCSI initiator name, domain joins); compare across sessions first, fix per
    host.
  - `linux-host-operations`: what hangs or misleads in this harness (whatever Phase 4 could
    not fix in code), package and service idioms per family (apt/dnf/apk, systemd/OpenRC).
  - An example user skill in the docs (`my-lab.md`: hosts, roles, what not to touch) so the
    folder's purpose is obvious.
- [ ] **Phase 7: Live validation and cost.** The four cloned VMs, user at the keyboard: the
  original de-duplication task end to end, with and without broadcast, focus changes between
  prompts, and the OSPF task again. Record iterations and dollars per run with and without the
  skills loaded (the 2026-10-15 OSPF run was ~30 iterations, ~$1.50 on Opus 5.5); the skills
  earn their place only if iterations drop. A router or switch if available (or a lab image).
  Docs: `Docs/AIArchitecture.md`, CLAUDE.md.

## Design rules (2026-10-16)

Agreed with the user after the first live runs. Each thing lives in exactly one layer:

| Layer | Holds | Examples |
|---|---|---|
| Code | Guarantees the model should never have to remember | passwords never leave the Mac, prompts that need a human pause the tool, non-interactive execution, tools never error on valid input |
| System prompt | What applies to every turn and fits in a few lines; the Anthropic cache prefix, so fixed per conversation | what this harness is, how sessions work, the invariants, the handover format, the skill index |
| Skills | Procedures and checklists a team would write down; loaded on demand | change procedure, definitions of done, troubleshooting method |
| User skills | What no model can know | the user's lab, hosts, what not to touch |

Why: the model (Opus 5.5) set up OSPF across four VMs unaided; vendor playbooks would repeat
its training at a token cost every turn. Both live failures so far (reach, memory) and the known
gap (hosts left at sudo prompts) were harness gaps, not knowledge gaps. A rule in the prompt
that exists because the code could not do its job is a harness defect: fix the code, delete the
rule. Sysadmins are a target audience as much as network engineers; the lifecycle skills serve
both, only the definition-of-done checklists differ.

## Phase 1 as built (2026-10-15)

- `AIAgentServicing` takes a `conversationID` (memory) next to `sessionID` (focused session:
  tool default and screen snapshot): `generateReply(conversationID:sessionID:prompt:
  broadcastSessionIDs:streamHandler:)`, `clearConversation(conversationID:)`. Protocol-extension
  conveniences keep the old session-keyed calls (session id = conversation id).
- `AIConversationContext` is keyed by conversation; `AIAgentRunner.run(conversationID:sessionID:…)`
  loads and stores by it, and each turn's user message starts with
  `[Focused session: <label> — <user>@<host>:<port>]` (or `Local shell — <label>`).
- `TerminalAIAssistantViewModel` owns `conversationID`; `clearConversation()` clears it and starts
  a new one (Clear button and closing the pane).
- Tests: `AIAgentServiceTests` +1 (memory follows the chat across focused sessions, each turn names
  its session, clear drops it), `TerminalAIAssistantViewModelTests` +1 and the clear test updated;
  76/76 across nine suites.

## Phase 2 as built (2026-10-15)

- `AISessionDirectory` (new): connected sessions (focused first, then by label) with endpoint and
  focused/broadcast flags; the per-turn preamble (`[Open sessions — pass an id as target_session;
  null targets …]` + one line per session), the `list_sessions` JSON, and the default targets.
  It replaced the broadcast-only session map; the Phase 1 focus line moved its `describe` here.
- `AIToolHandler`: a non-null `target_session` that isn't a connected session is refused before
  dispatch (`{ok:false}`, hint to call `list_sessions`); an explicit id now works for any open
  session, also outside the broadcast set; new `list_sessions` case.
- `AIToolDefinitions`: `list_sessions` schema (also allowed in direct-action mode), a clearer
  `target_session` description, and the developer prompt's BROADCAST section rewritten as SESSIONS
  (compare read-only first, change one host, verify, then the rest).
- Tests: `AIAgentServiceTests` +5 (session list per turn, defaults with and without broadcast,
  explicit targets in and outside broadcast, refusal of unknown/closed ids — red with validation
  disabled — and `list_sessions`). 81/81 across nine suites.

## Phase 3 as built (2026-10-15)

**Live findings first.** Phase 2 held up on the four cloned VMs: asked to install FRR and run
OSPF with a loopback per box, the copilot did so on all four (each box sees three neighbours, DR
Testserv4, backup Testserv3, and routes to the other loopbacks); one conversation, ~30 Opus
requests, cache reads growing on every request. The clone fixes themselves still wait at
`sudo` prompts. Inside `vtysh` (an IOS-style CLI) Opus did **not** send the POSIX wrapper: it saw
`testserv-02#` in the turn's screen snapshot and used `send_input` + screen reads (3 requests,
~14 s). Its weak spots: terminal-wrapped lines it had to rebuild, one screen of output at most,
no completion signal ("Maybe it hasn't updated yet, I'll check again"). `vtysh` accepted
`terminal length 0`; its ~20-line `show running-config` never paged, so `--More--` is covered
by the fake device only.

- `Services/AI/DeviceCLI.swift` (new, pure):
  - `DeviceCLIPrompt.classify` (cursor line → `.posixShell` / `.deviceCLI` / `.unknown`; device
    = an existing vendor prompt pattern from `ShellIntegrationScripts` and not POSIX-looking)
    and `base(of:)` (the part that survives mode changes).
  - `DeviceCLICapture`: complete when the tail line starts with the base and ends in `#>$%`
    after 300 ms quiet (1 s without a base); Space at a pager after 150 ms, once per page, at
    most 1,000; a question (`?`, `:`, `]`, `[y/n]`) after 2 s; output without echo, pagers and
    prompt.
  - `DeviceCLIText` applies backspaces and carriage-return overwrites (pager erase).
- `SessionAIToolCoordinator.executeCLICommand`: sends `command + "\r"` with the same bookkeeping
  as `executeCommandAndWait`, observes output in `filterToolOutput` without hiding it, polls every
  50 ms. A new AI command on a session supersedes either kind. The escape stripper moved from
  `PendingToolCommand` into `TerminalPlainText` (shared).
- `run_cli_command(command, timeout_seconds 5–120, target_session)` in
  `AIToolHandler+DeviceCLI.swift`: `{ok, output, completed, final_prompt, pages_advanced,
  truncated}`, `awaiting_input` + hint, `timed_out` + hint; several targets → `results[]`.
- `execute_and_wait` refuses any target at a device prompt (`Not a POSIX shell: Testserv2
  (testserv-02#) …`, hint `run_cli_command`), nothing sent. `AISessionDirectory` marks
  `· device CLI "<prompt>"` and `device_cli_prompt` in `list_sessions`. Developer prompt: DEVICE
  CLIs section (one line per call, POSIX-only tools, read-only first, rollback before touching
  the management path).
- Not done: platform paging commands are not sent automatically (a `router#` prompt does not
  identify the platform; pagers are answered generically, skills will recommend `terminal length
  0` etc.); the remote file tools do not check for device prompts yet (they would time out);
  the host's configured "Device / Shell Type" is not used (the prompt is the per-call truth, since
  `vtysh` or a jump to a router changes it mid-session).
- Tests: new `DeviceCLITests` (11), `SessionAIToolCoordinatorTests` +1 (scripted fake device:
  echo, a page, `--More--` answered with Space, output left visible), `AIAgentServiceTests` +4.
  The refusal and pager tests went red with their behaviour disabled. 100/100 across eleven
  suites.

## Open questions

- (Resolved 2026-10-16) No confirmation gate for unfocused hosts; user skills load once per
  chat, not watched live. Both recorded in Phase 4/5 and "Design rules".
- Phase 4 non-interactive environment: can the wrapper set the variables for one command
  without leaking into the user's shell or losing `cd`? Builder decides; fallback is the skill.
