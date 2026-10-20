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

- [x] **Phase 4: Harness first — nothing the model must remember because the code could not.**
  Done 2026-10-18; see "Phase 4 as built".
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
- [x] **Phase 5: Skill library and `load_skill`.** Done 2026-10-18; see "Phase 5 as built".
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
- [x] **Phase 6: Write the skills — shaped by the lifecycle, not the vendor.** Done 2026-10-18;
  see "Phase 6 as built". **All eight removed 2026-10-20 after Phase 7 measured no gain**
  (see "Phase 7 results so far"); kept below as history. Vendor syntax
  stays with the model. A skill is a procedure or a checklist a team would write down; it
  contains no rules ("never", "always" live in the prompt only, so nothing can conflict). Each
  under ~80 lines. Before closing the phase, read the prompt and all skills together once and
  strike any contradiction.
  - `change-procedure`: the method of procedure every change follows — pre-checks, steps,
    post-checks, rollback, staged rollout (one host, verify, then the rest). One line per
    platform safety net: Junos `commit confirmed`, IOS `reload in`, RouterOS safe mode, VyOS
    `commit-confirm`, nftables/iptables with a timed revert.
  - `baseline-and-diff`: capture state across hosts before touching anything, same read-only
    commands in parallel, diff, change, diff again. Then delete the prompt's SESSIONS line
    "To compare hosts … then do the rest", which holds this until the skill exists.
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
    From Phase 4: `sudo` drops the non-interactive variables (`sudo DEBIAN_FRONTEND=noninteractive
    NEEDRESTART_MODE=a apt-get -y …`, `systemctl --no-pager`, `journalctl --no-pager`); `apt`
    without `-y` and ssh host-key questions (`-o StrictHostKeyChecking=accept-new`) are not
    environment-controlled; a timed-out command may still be running (check the screen first).
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

## Phase 4 as built (2026-10-18)

- **Environment.** `SessionAIToolCoordinator.wrappedCommand(_:token:)` builds
  `{ printf PSB; for __v in <names>; do eval "__s_$__v=\${$__v+1} __o_$__v=\${$__v-}"; done;
  export <assignments>; eval '<cmd>'; __ps=$?; for __v in <names>; do eval "<restore or unset>;
  unset __s_$__v __o_$__v"; done; unset __v; printf PSW; }` from `nonInteractiveEnvironment`
  (`DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a SYSTEMD_PAGER= PAGER=cat GIT_PAGER=cat`).
  Works in sh, dash, bash, zsh, ksh: the command and its children see the values, the shell
  gets its own back (values with spaces too), `cd` persists, the exit code is kept.
  `VAR=x eval` persists in POSIX shells; `VAR=x command eval` fails in zsh and leaks in ksh.
  A variable the shell had but did not export comes back exported (accepted).
- **Line length.** A line over 1,024 bytes never reaches a macOS shell (`MAX_INPUT`), even once
  the shell is ready. Spelling each variable out made the wrapper 1,325 bytes and every local
  command timed out; the loop form is ~530 bytes (was ~190), and
  `testWrapperLeavesMostOfTheLineToTheCommand` caps it at 560. Linux allows 4,095.
- **sudo.** `env_reset` drops the variables. Not fixable in the wrapper without rewriting the
  model's command; the `execute_and_wait` description says to pass them after sudo, and
  `linux-host-operations` (Phase 6) carries the idioms.
- **Timeout.** Nothing is sent to the session on timeout any more (the old `ESC[0m` + newline
  was typed into the still-running command).
- **Prompt.** 55 → 23 lines, 702 → 332 words. Sections: APPROACH, SESSIONS (device CLIs folded
  in), SAFETY (destructive commands, never cut the path you are connected over, secrets),
  FORMAT (with the handover line). Everything about individual tools lives in their
  descriptions; `send_input` and `run_cli_command` no longer mention answering passwords.
- **Contract.** Every `{ok:false}` comes from `AIToolDefinitions.errorObject(_:hint:)` or
  `errorResult(_:hint:)`, both with a required hint, or carries one explicitly
  (`apply_patch` failure, `run_cli_command` statuses). `AIToolContractTests` runs every exposed
  schema on valid minimal input and 13 invalid inputs. Finding: a local `apply_patch` update
  without a diff reported success; now refused.

## Phase 5 as built (2026-10-18)

- **Library.** `Services/AI/AISkillLibrary.swift`: `AISkill` (name, description, platforms,
  body, source), `AISkillSet` (sorted by name, `skill(named:)`, `indexLines`) and
  `AISkillLibrary(bundledDirectory:userDirectory:)`. Front matter is `---` / `key: value` /
  `---`. Rules: `name` is lowercase letters, digits and hyphens; `description` is one line of at
  most 200 characters; `platforms` is `[a, b]` or `a, b`; the body must not be empty. An invalid
  file is logged (`AICopilot.Skills`) and skipped. Within one folder the first file by name wins
  a duplicate name; a user skill replaces a bundled one. A missing folder means no skills.
- **Bundle layout.** Xcode's synchronized group **flattens** `ProSSHMac/Resources/Skills/*.md`
  into `Contents/Resources/*.md` (checked with a probe file and a build). So
  `AISkillLibrary.standard` reads every `.md` at the resource root as a bundled skill. Nothing
  else in the app target is Markdown; if that changes, give skills their own extension.
  User folder: `~/Library/Application Support/ProSSHMac/Skills/`.
- **Once per chat.** `AIConversationState.skills` is filled on the chat's first turn
  (`AIAgentRunner.run`) and kept, so the system prompt and the Anthropic prefix fingerprint stay
  fixed. Clear drops the state, so the next chat reloads both folders. With
  `persistConversationContext == false` the library loads each turn.
- **Prompt.** `developerPrompt(skills:)` adds a blank line, `SKILLS (procedures and
  checklists; call load_skill with the name before a task one covers):` and one
  `- name — description` line per skill, only when skills exist. The base prompt is unchanged
  (23 lines).
- **Tool.** `load_skill {name}` (strict, no `target_session`), the 13th exposed schema; not
  in the direct-action set. Returns `{ok, name, description, platforms, source, body}`. An
  unknown name gives `{ok:false}` with the hint `Available skills: …` or "No skills are
  installed". The handler gets the chat's snapshot through
  `executeToolCalls(…, skills:, traceID:)`.
- **Wiring.** `AIAgentService(skillLibrary:)` defaults to `.empty`, so tests never read the
  developer's folders; `AppDependencies` passes `.standard`. Settings → AI Assistant has a
  "SKILLS" group with **Open Skills Folder**, which creates the folder and opens it in Finder.
- **Tests.** `AISkillLibraryTests` (parsing, invalid files skipped, override, duplicates,
  absent folders, folder creation). `AIAgentServiceTests.testSkillIndexIsFixedPerChatAndReloadedByANewChat`:
  a file added mid-chat leaves the system prompt unchanged, and a new chat lists it.
  `AIToolContractTests` gains a `load_skill` case, two error cases and the hint check.
  `AIToolDefinitionsTests` checks that the index adds 2 + n lines.
- **Not yet seen live:** the Settings button, and a user skill loaded by the model in a real chat.

## Phase 6 as built (2026-10-18)

- **Eight skills** in `ProSSHMac/Resources/Skills/` (body lines): `change-procedure` (53),
  `baseline-and-diff` (41), `troubleshooting` (47), `routing` (45), `services` (53),
  `access-safety` (42), `clone-deduplication` (41), `linux-host-operations` (53). Each has a
  "Done when" section. Skills point to each other with "load <name>".
- **One home per fact.** The per-platform safety nets (Junos, IOS/IOS-XE, EOS, RouterOS, VyOS,
  nftables/iptables, Netplan) are only in `change-procedure`; `access-safety` points there.
  Staged rollout is only in `change-procedure`. Per-daemon config checks are only in
  `services`. The sudo/apt/ssh idioms from Phase 4 are only in `linux-host-operations`; its
  draft line about password prompts was struck because it repeated the `execute_and_wait`
  description. `access-safety` keeps the `sudo -n true` check from this spec, reworded as
  planning ("the user will have to type a password; say so before a multi-host run"). It is
  not a harness probe, which CredentialPrompt removed.
- **Prompt.** The SESSIONS line "To compare hosts … then do the rest" is deleted
  (`baseline-and-diff` + `change-procedure`). Base prompt 23 → 22 lines, 332 → 310 words; with
  the eight-line index the system prompt is 32 lines, about 470 words.
- **Contradiction pass** (prompt and all skills read together), three findings:
  1. The prompt's "Never repeat an identical tool call" contradicted every post-check, which
     deliberately re-runs the same capture after a change. It now reads "… unless something
     has changed since".
  2. `access-safety` restated three safety nets; it now points to `change-procedure`.
  3. `routing`'s restart-to-prove-persistence step could cut the session through that
     router; it now says to load `access-safety` first.
- **Enforced by `BundledSkillsTests`** (runs in the app host, so `Bundle.main` is the app):
  all eight load and none are skipped (the `.md` file count matches); description ≤ 120
  characters; body ≤ 80 lines; no "never"/"always" in any body (Design rules); every
  "load <name>" names a real skill. `AIToolDefinitionsTests` checks that the compare line is gone.
- **Example user skill**: `Docs/Skills.md` (format, folders, override, the built-in list and a
  full `my-lab.md`).

## Phase 7 results so far

### Run 1 (2026-10-19): four fresh cloned Ubuntu VMs, skills installed

Debug build of `68a1eb2`, Claude Opus 5.5, one window. The user's account of it: the clones
were de-duplicated, OSPF came up across all four, then a few follow-up commands. Raw evidence:
`Docs/debuglogs/phase7-run1-ai.txt` (the AI lines of `debugoutput1.txt`, a 4 MB log that is
99% renderer stats and is gitignored). The log has no prompt text and no timestamps, so which
prompt each turn was is inferred from its size and tools. Cost is from the logged `usage` at
$4 in / $20 out / $0.20 cache read / $5 cache write (5-minute TTL, the client's default).

| Turn | Session | What (inferred) | Iter | Tools | Skills loaded | Wall | Cost |
|---|---|---|---|---|---|---|---|
| 1 | c1428e7a | De-duplication, 4 hosts (new chat) | 14 | 22 | `clone-deduplication` | 5m46s | $0.40 |
| 2 | 8f4b9a67 | Follow-up check, 4 hosts | 2 | 4 | — | 22s | $0.07 |
| 3 | 8f4b9a67 | OSPF (new chat, `messages=2`) | 9 | 20 | `routing`, `linux-host-operations` | 6m26s | $0.31 |
| 4 | 8f4b9a67 | Follow-up check, 4 hosts | 2 | 4 | — | 45s | $0.07 |
| 5 | 8f4b9a67 | Direct action, broadcast on | 2 | 1 | — | 11s | $0.03 |
| 6 | 053ca4ca | Direct action, other focus | 2 | 1 | — | 7s | $0.02 |
| 7 | 053ca4ca | Question, 1 command | 2 | 1 | — | 18s | $0.05 |
| | | **Total** | **33** | **53** | | | **$0.95** |

Skill names come from `load_skill` `output_chars`: every one is its skill's JSON size + 17.

- **OSPF: 9 iterations and $0.31, against ~30 and ~$1.50 on 2026-10-15.** Not yet credit for the
  skills: Phase 4 changed the prompt and the harness in between. The run without skills
  decides it.
- **The right skills loaded unprompted** as the first action of both tasks.
- **Focus changes keep the chat**: the message count carries on across three focused sessions
  (37→39 at turn 2, 41→43 at turn 6). Broadcast was switched on before turn 5 (inferred from the
  toolbar log below).
- **Caching works**: after the first request of a chat, each request writes 0.1–4.6k tokens and
  reads the rest. A new chat's first request writes ~6.6k (tools + system) with nothing read.
- Turn 1, iteration 3: an `execute_and_wait` ran to its 30 s default timeout (121 chars back),
  then `get_current_screen` and `send_input`. That reads as an interactive prompt the
  non-interactive environment did not cover. `linux-host-operations` was not loaded in that
  chat. **The log cannot show which command it was; ask the user.**
- **The model rebooted the VMs mid-task and asked for sudo to do it (user report), because the
  skill told it to.** `clone-deduplication` said "then reboot" on the machine-id row and
  "Reboot where the table says so" in its order. The run without skills (2026-10-15) never
  rebooted. Turn 1 iterations 8, 11 and 12 (an `execute_command`, then a ~50 s
  `execute_and_wait`) fit reboot-and-reconnect. Fixed 2026-10-19: the reboot is the user's
  call, deferred to the end of the whole task and named in the handover; running services keep
  the old machine-id until the next boot. **Turn 1's iterations, time and cost include the
  reboots, so re-run de-duplication with the fixed skill before comparing.**
- Turn 3's four parallel `execute_and_wait` calls each took 45.1 s: a long command or a
  timeout; the log cannot tell.
- **New bug: the broadcast toolbar button has no icon.** `TerminalView.swift:117` uses
  `antenna.radiowaves.left.and.right.fill`, which macOS 26 lacks ("No symbol named …", 16 times).

### Runs 2 and 3 (2026-10-20): fixed skills versus no skills

Fresh clones each run, broadcast off, Clear before each task, the same prompts letter for
letter:

- De-duplication (138 chars): `These four servers were cloned from the same VM image. Find
  everything that is duplicated between them and make each one a unique machine.`
- OSPF (186 chars): `Install FRR on all four servers and set up OSPF in area 0 on the network
  they share. Give each server a unique router ID and make sure each one has a full adjacency
  with the other three.`

Evidence: `Docs/debuglogs/phase7-run2-ai.txt`, `phase7-run3-ai.txt`.

| | Run 1: skills (old clone skill) | Run 2: skills (fixed) | Run 3: no skills |
|---|---|---|---|
| De-duplication | 1 turn, 14 iter, $0.40 (with reboots) | **3 turns**, 22 iter, 39 tools, $0.74 | **1 turn, 12 iter, 25 tools, $0.53**, 3m54s |
| OSPF | 9 iter, $0.31 | 9 iter, 27 tools, $0.30 | 9 iter, 32 tools, $0.32, 7m31s |

- **OSPF: the skills changed nothing measurable.** 9 iterations in all three runs. The drop
  from ~30 / ~$1.50 on 2026-10-15 came from Phase 4 (harness and prompt), not the skills.
- **De-duplication with skills needed babysitting.** Run 2 loaded `clone-deduplication`, which
  pulled in `baseline-and-diff` and `change-procedure`, captured all four hosts once and stopped
  without changing anything. `change-procedure` says to get confirmation before irreversible
  steps (new host keys, machine-id) and to report after the first host before continuing.
  The user prompted twice more (27 and 60 chars; the second loaded `access-safety`). Run 1
  carried the same instruction and did not stop, so whether the model follows it varies from
  run to run. Without skills it finished in one turn.
- User report, run 2 OSPF: no IP forwarding and no loopback interfaces. `routing` listed
  forwarding only as something to check and never mentioned loopbacks. The prompt asked for
  neither. Run 3 was not checked.
- Prompt 3 (the `run …` pager checks) did not run in either run.

**Decision (user, 2026-10-20): no built-in skills.** All eight were deleted, with
`BundledSkillsTests`. The mechanism stays for user skills: the skills folder, `load_skill`, the
per-chat index and Open Skills Folder. The loader still reads `.md` files at the bundle root,
but none ship. One run per arm is a small sample, but the measured gain was zero and the cost
was extra user turns. This matches the Design rules: generic procedure repeats what the model
already knows.

### Run 4 (2026-10-20): one mission at extra high effort, no skills

Four fresh clones, broadcast off, effort set to **extra high** in the UI (runs 1–3 used the
default). One prompt (828 chars) combining both jobs and spelling out what run 2 missed:

```
These four servers were cloned from the same VM image. Do the following as one job, without rebooting any of them:

1. Find everything that is duplicated between them and make each one a unique machine.
2. Install FRR on all four and set up OSPF in area 0 on the network they share. Give each server a loopback interface with its own /32 address, use that address as its router ID, and advertise it into OSPF. Enable IP forwarding. Make all of this survive a reboot.
3. Verify everything: every identifier from step 1 is now unique, each server has a full adjacency with the other three, every server can ping every other server's loopback, and the configuration is saved.

When you are done, give me a table per server with what you changed and how you verified it, and list anything that would only take effect after a reboot.
```

Evidence: `Docs/debuglogs/phase7-run4-ai.txt`.

| | Run 3 (default effort, two prompts) | Run 4 (extra high, one mission) |
|---|---|---|
| User turns | 2 | **1** (the only input was the sudo password, in the card) |
| Iterations | 21 (12 + 9) | 38 |
| Tool calls | 57 | 84 (60 `execute_and_wait`, 8 `execute_command`, 15 `get_current_screen`, 1 `get_recent_commands`) |
| Cost | $0.85 | **$3.98** |
| Wall time | 11m25s | 22m29s (18m52s model, 3m37s tools) |

- **Result (user check): everything done.** Identifiers unique, loopback /32s advertised,
  forwarding on, all adjacencies Full, loopback pings pass. No reboot; no intervention beyond
  the sudo password.
- **Output is the cost.** $2.36 of $3.98 is output, mostly thinking: iterations 3–6 alone wrote
  53k output tokens ($1.06) over 8.5 minutes, iteration 3 thought for 3 minutes. Cache reads
  were $0.78 (context reached 167k tokens), cache writes $0.84; the cache held on every call.
  The handover was 8,900 characters (~10k output tokens).
- **Two polling stretches** (iterations 13–18 and 29–33): a long job started with
  `execute_command`, then repeated `get_current_screen` until it finished. 11 cheap iterations.
- **Not an effort measurement.** Effort and prompt both changed (the prompt asks for loopbacks,
  forwarding and verification that runs 2–3 never did), so this is the price of one complete,
  verified mission at extra high, not the effect of the effort setting alone.
- Found Bug 94 (an AppKit `NSRangeException` when the user clicked the reasoning panel while it
  was streaming); unrelated to the model.

**Still open for Phase 7:** de-duplication with broadcast versus without, a router/switch or
lab image, and the live checks (`systemctl status`/`journalctl` not paging over SSH, `$PAGER`
unchanged afterwards, Open Skills Folder, a dropped-in user skill reaching a new chat). Record
the prompts and the time: the log carries neither.

## Open questions

- (Resolved 2026-10-16) No confirmation gate for unfocused hosts; user skills load once per
  chat, not watched live. Both recorded in Phase 4/5 and "Design rules".
- (Resolved 2026-10-18) The wrapper can scope the non-interactive variables to one command
  without leaking or losing `cd`; see "Phase 4 as built". Only `sudo` defeats it.
