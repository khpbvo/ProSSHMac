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

- [ ] **Phase 1: One chat, one memory.**
  - Chat id owned by `TerminalAIAssistantViewModel` (new id on Clear); the service and runner key
    `AIConversationContext` by it. The focused session is passed per turn and named in the user
    message.
  - Keep the per-session tool defaults (the focused pane is the primary session).
  - Tests: two prompts with different focused sessions share history; Clear starts fresh;
    existing `AIAgentServiceTests` adapted.

- [ ] **Phase 2: Reach every open session.**
  - Session map in each turn's user message (all connected sessions; focused and broadcast
    flags); `list_sessions` tool; `resolveTargetSessions` validates ids against connected
    sessions (unknown/closed id → `{ok:false}` with the map as hint) and defaults to the
    broadcast set or the focused pane.
  - Developer prompt "BROADCAST" section rewritten as "SESSIONS": how to target, compare, and
    act per host; parallel tool calls across sessions.
  - Tests: untargeted command in single focus → focused only; explicit id of an unfocused
    session works; broadcast default unchanged; closed id rejected.

- [ ] **Phase 3: Device CLI command path.**
  - First, verify against a real or emulated device what the current tools do (expect
    `execute_and_wait` to time out). Then `run_cli_command(command, target_session,
    timeout_seconds)`: paging off once per session (`terminal length 0`, `set cli screen-length 0`,
    etc. by detected platform), prompt detection, output extraction, timeout handling.
  - Session kind detection from the prompt/banner (POSIX shell vs device CLI), shown in the
    session map; `execute_and_wait` refuses on device CLIs with a hint.
  - Tests with a scripted fake device (echo, prompt, `--More--` paging).

- [ ] **Phase 4: Skill library and `load_skill`.**
  - `AISkillLibrary`: bundled + user skills, front matter (`name`, `description`, optional
    `platforms`), validation; skill index in the system prompt; `load_skill` tool; Settings row
    to open the user folder.
  - Tests: parsing, user override of a bundled name, unknown skill error, index is stable.

- [ ] **Phase 5: Write the skills.** Each one: when to use, safety rules first, the commands,
  how to verify, how to roll back.
  - `clone-deduplication` (Linux VMs cloned from one image): hostname/hostnamectl and
    `/etc/hosts`, `/etc/machine-id` + D-Bus id, SSH host keys, DHCP client id/DUID
    (systemd-networkd, NetworkManager, netplan), cloud-init instance id, static IPs/MAC matches,
    filesystem/swap UUIDs only if shared storage matters, monitoring/agent ids, iSCSI initiator
    name, domain/Kerberos joins; compare across sessions first, then fix per host.
  - `multi-host-operations`: inventory, diff outputs across hosts, staged rollout (one host,
    verify, then the rest), never act on all hosts with an unverified command.
  - `linux-network-diagnostics`: links, addresses, routes, DNS, MTU, sockets, firewall
    (nftables/iptables/ufw), packet capture.
  - Device playbooks: `cisco-ios` (IOS/IOS-XE), `junos` (commit confirmed), `arista-eos`,
    `mikrotik-routeros`, `vyos-edgeos`, `pfsense-opnsense` — read-only discovery first, change
    safety (rollback timers, don't cut the management path you are connected over), save config.
  - `hypervisor-basics`: Proxmox/ESXi/libvirt guest inventory and console access.
- [ ] **Phase 6: Live validation.** The four cloned test VMs: the original task end to end, with
  and without broadcast, focus changes between prompts. A router or switch if available (or a
  lab image). Docs: `Docs/AIArchitecture.md`, CLAUDE.md.

## Open questions

- Should acting on a session the user did not focus or broadcast to require a confirmation, as
  `apply_patch` does? Default proposal: no for read-only commands, a one-time per-turn
  confirmation listing the hosts for changing commands is a candidate if the user wants it.
- User skills folder: watch for changes live, or load at app start / chat start only? (Stable
  per conversation either way.)
