# ProSSHMac: The Big Picture — Ranked Feature List (October 2026)

**Revision 2, 2026-10-23.** Revision 1 was written from the README alone. This revision checks
every claim against the source at commit `0ebe8e4` and re-checks the competitor facts on the web
on the same day. What revision 1 got wrong is listed under "Corrections to revision 1". Defects
found during the cross-check are listed under "Defects found". The ranked list is the planning
input: each entry is sized to become one `Docs/<Name>.md` spec, following the CLAUDE.md workflow.

## TL;DR

- **The thesis stands.** The most valuable new feature is a deterministic **Change Set engine**:
  pre-checks, a prompt-aware push to N devices, post-checks, a diff and an approval gate. The
  second most valuable is a **serial/console transport**. No Mac tool found does pre/post diff
  with approval.
- **The "basics" were partly wrong.** Single-hop ProxyJump and `~/.ssh/config` import and export
  already exist in code, although import only reads the clipboard. The real foundation gaps are
  different and worse:
  - no ssh-agent authentication;
  - an agent-forwarding toggle that does nothing;
  - Secure Enclave user keys that generate but cannot log in;
  - keyboard-interactive auth that cannot do password + OTP;
  - local port forwards that listen on every network interface.
- **Release hygiene comes before any feature.**
  - The only release is the 0.9.0 pre-release of 2026-02-26. The 171 commits since are
    unreleased, including the Anthropic provider, the network copilot, the credential-prompt card
    and the October bug fixes.
  - The vendored OpenSSL 3.4.1 left upstream support on 2026-10-22.
  - The vendored libssh 0.12.0 misses two security releases.
  - CI cannot fail.
  - The README claims features the code does not have (remote forwarding, clickable links in the
    default renderer).
- **The market moved in 2026.**
  - Termius made host chains, agent forwarding and serial free (September 2026).
  - iTerm2 3.7 ships "orchestration" AI chats across all sessions.
  - Transit, an early open-source cross-platform client (no releases yet), targets the same
    network-engineer niche: a read-only, policy-gated AI with redaction, plus serial.
  - Being "the AI SSH client for network engineers" is no longer unoccupied. Verified execution
    (Change Sets) and trust controls (redaction, per-host policy) are what still set it apart.
- **Build order:**
  1. Release readiness (security fixes, vendor upgrade, CI, auto-update, README).
  2. Finish what the UI already promises: agent, MFA, broadcast paste, links.
  3. The network workflow: logging, host inventory, vendor profiles, Change Sets, serial,
     forwarding.
  4. Trust and polish.
  5. Sync, FIDO2 and the rest.

## How to read the ranked list

- **Rank = build order.** Dependencies and the cost of leaving a broken promise in the UI both
  push an item up. **Value (★1–5)** is shown separately, because the most valuable feature (Change
  Sets) is not the first one to build.
- **Size** counts phases, where one phase is one Claude Code session in the CLAUDE.md workflow:
  S = 1–2 phases, M = 3–5, L = 6 or more. All sizes are judgment, not measurement.
- **Evidence** cites `file:line` at `0ebe8e4`. "Verified by reading" means the code path was traced
  but not run. Nothing in this revision was tested live.
- Defects are registered as Bugs 97–108 in `Docs/bugs.md` (2026-10-23), all open.

---

## What ProSSHMac is today (verified in code)

| Area | What exists | Limits found |
|---|---|---|
| **Terminal** | Metal renderer with glyph atlas and ProMotion pacing; split panes (`PaneManager.maxDepth = 4`, so up to 16 panes) and uncapped tabs; detachable windows; local PTY; VT/xterm parser with OSC 133, OSC 52 write (read denied), kitty keyboard disambiguation and `modifyOtherKeys`; search; smooth scrolling; CRT, bloom, gradient and Matrix effects | Links are not clickable in the default Metal renderer, and OSC 8 hyperlinks are parsed then dropped (Bug 102). No image protocols: APC is ignored. No ANSI colour schemes: only background, bold and prompt colours. VoiceOver reads nothing. Throughput: 3.80–5.01 MB/s on the Release real-app path with no window, vs Terminal.app 26.5 MB/s rendered (CLAUDE.md baseline). Open issue #13 (FPS drops). |
| **SSH** | libssh **0.12.0** and OpenSSL **3.4.1**, vendored as binary xcframeworks with no build script in the repo. Password, public-key, certificate and keyboard-interactive auth. TOTP auto-fill. Algorithm preferences, legacy mode and pinned host-key algorithms. Keepalive and auto-reconnect. Single-hop jump host with TOFU per hop (`prossh_libssh_connect_with_jump`, `ProSSHLibSSHWrapper.c:1776`). App-private known-hosts JSON. | No agent authentication. Agent forwarding does nothing (Bug 98). Keyboard-interactive is not interactive (Bug 100). libssh is built without FIDO2 (the library's own error string says to rebuild `WITH_FIDO2`) and without GSSAPI (no `gss_` imports). No X11 forwarding. Connect and auth block the shared transport actor (Bug 104). No `~/.ssh/known_hosts` import. Known hosts can only be cleared all at once. |
| **Keys and CA** | KeyForge: Ed25519/ECDSA/RSA generation, import, export and conversion; ssh-copy-id; Secure Enclave P-256 user keys. Built-in CA with Secure Enclave signing and KRL bundles. | Secure Enclave user keys cannot authenticate (Bug 99). ssh-copy-id refuses them. |
| **Port forwarding** | Local forwards through `NWListener`, 32 connections per rule | Local only: no remote (-R) and no dynamic SOCKS (-D). The listener binds to every interface (Bug 97). |
| **Files** | SFTP browse, single-file download (always to `~/Downloads`) and upload; transfer queue with pause and resume; file-browser sidebar for local and remote sessions | No rename, delete, mkdir or chmod. No folder transfers. Dropping a file onto an SSH terminal types its *local* path. |
| **Hosts** | Folders, tags, notes; `~/.ssh/config` import with preview (`ProxyJump`, `LocalForward`, `IdentityFile`, algorithms, `ForwardAgent`) and export; Spotlight indexing; App Intents (Open Section, Connect Host) | Import and export use the clipboard only (Bug 106). No `Include`. No in-app host search. Tags are stored and indexed for Spotlight, but nothing in the UI filters by them. The host form refuses a jump host that has its own jump host (`HostFormView.swift:39`), and import keeps only the first hop. |
| **Productivity** | Quick Commands: variables with defaults, host or global scope, JSON import/export, a ⇧⌘P drawer. Broadcast, group and solo input routing (`Cmd+Shift+B`). Encrypted session recording with playback and `.cast` export. Audit log (text, CSV and JSON export to the clipboard). Shell integration for zsh, bash, fish and sh, plus prompt regexes for 8 network OSes and a custom regex. | Broadcast covers keystrokes only (Bug 101). Quick Commands has no search and sends to one session. No plain-text logging. Recording grows quadratically in memory (Bug 103). No menu bar at all (no `.commands` anywhere; issue #18 open since 2026-02-27). |
| **AI copilot** | OpenRouter, or the Anthropic Messages API directly. 13 tools; every connected session is reachable (`target_session`, `list_sessions`). `run_cli_command` handles device CLIs, including pagers and a password wait. A credential-prompt card pauses for sudo, su, ssh, passphrases and `enable`. `apply_patch` has an approval card. User skills. Stop and Clear. Up to 200 iterations. | Commands are not approval-gated; this was the user's decision on 2026-10-16 for unfocused hosts, and only `apply_patch` is gated (that gate can be switched off). Nothing is redacted before a turn is sent, although each turn includes the focused screen. No custom or local endpoint. No cost display: run costs ($0.85–$3.98 per mission in NetworkCopilot Phase 7) were read from logs. Chat memory is lost on relaunch. Live-validated on Ubuntu VMs and FRR only. No real router or switch run is recorded (Phase 7 still open). |
| **Distribution** | Developer ID DMG and a notarization script; hardened runtime on; **App Sandbox off**. Entitlements: a Keychain group and user-selected files. | One release only: v0.9.0, a pre-release dated 2026-02-26. No auto-update. CI cannot fail (Bug 105). 0 stars, 0 forks, 2 open issues (#13 and #18) [1]. |

## Corrections to revision 1

| Revision 1 said | The code (or the web, re-checked 2026-10-23) says |
|---|---|
| "Fix the basic connectivity gaps (ProxyJump, ssh-agent/1Password, ~/.ssh/config import, SOCKS)" | **ProxyJump exists**, single hop: `Host.jumpHost`, a picker in the host form, and libssh's in-library ProxyJump with per-hop host-key and auth callbacks [2]. **ssh_config import and export exist** (`SSHConfig*.swift`, 1,016 lines), clipboard-only. Agent auth and SOCKS really are missing. Agent forwarding is worse than missing: the toggle exists and does nothing. |
| "If your vendored libssh is older than 0.11, upgrade" | It is 0.12.0. Upgrade to **0.12.2** (2026-07-28): 0.12.1 and 0.12.2 fix about a dozen CVEs [3]. OpenSSL 3.4.1 must move to 3.5 LTS: 3.4 support ended 2026-10-22 [4]. |
| "AI copilot: OpenRouter-only" | OpenRouter **or** Anthropic direct (`Docs/Anthropic.md`, complete). |
| "The AI operates on one session"; "the 4-session ceiling … needs headless sessions" | The copilot reaches every connected session (NetworkCopilot Phases 1–6). "4" is the split *depth* (up to 16 panes); tabs are uncapped. A session that is not on screen already runs with an engine and no renderer (`TerminalSurfaceModelStore`, Bug 84). Fleet scale is still unmeasured, and connects serialize (Bug 104). |
| "Broadcast input: Planned" | Keystroke broadcast exists, with groups and solo mode (`Docs/Issue15.md`). Paste, Quick Commands and file drops still go to one session (Bug 101). |
| "Local **and remote** port forwarding" (from the README) | Local only. `PortForwardingRule` has no direction field, and the wrapper never calls `ssh_channel_listen_forward`. |
| "Only MikroTik RouterOS is tested" | The device-CLI command path was built later (`run_cli_command`). Recorded live runs cover Ubuntu VMs and FRR `vtysh`, not MikroTik, Cisco or Juniper. |
| "Quick Commands already has … per-host scope" | One host or global. No tag or group scope. It sends to the selected session only. |
| "App Sandbox status unknown" | `ENABLE_APP_SANDBOX = NO`, hardened runtime on. Serial devices, agent sockets and `~/.ssh` reads need no entitlement in the DMG build. |
| "Check that your swift-nio-ssh fork handles certificate auth" | Not applicable to this repo: macOS-only targets, no NIO dependency. The iOS app is not in this repository, so that claim stays unverified. |
| "Accessibility … I did not verify this" | Verified: the Metal view sets only an accessibility label and hint (`TerminalMetalView.swift:22`). No text is exposed. |
| Termius desktop 10.1.0 "Sept 30, 2026" | **Sept 21, 2026.** 10.1.3 is Sept 30 and fixes FIDO2 in the Mac App Store build [5]. |
| Core Shell "4.0 (USB/Bluetooth/built-in serial)" | Serial arrived in **5.0**; the current version is 5.1.1 (Sept 20, 2026). Shortcuts came in 4.0 [6]. |
| Serial "App Store page lists FTDI, Prolific, CH34x … Cisco USB console" | That App Store listing is **Serial 1** (1.4.11, 2021) [7]. Serial 2.0.18 (2025-09-09, macOS 26 support) lists FTDI, Silicon Labs, Prolific, TI and Microchip on its own page [8][9]. |
| MobaXterm alongside the Mac competitors | **Windows-only.** Use it as a feature benchmark, not as a Mac competitor. |
| "Sander de Beus … on TrustRadius" | The reviewer's name could not be verified (TrustRadius blocked fetching). The text now says "a TrustRadius reviewer". |
| "Nothing on the Mac combines broadcast with verification" | Still true for pre/post diff with approval. But Transit [10] ships broadcast with a policy-gated read-only AI on macOS, and iTerm2 3.7 [11] ships orchestration chats across sessions. |
| Ghostty and Kitty as "faster-moving terminals" | Ghostty's latest release is 1.3.1 (2026-03-13) [12]. |
| SecureCRT "Python 3.12/3.13" | The version range is unverified. Latest is SecureCRT 9.7.3 (2026-07-01) [13]. |
| ZOC "triggers" | ZOC calls them Auto Macros, Auto Replies and Auto Highlight [14]. |
| Warp's "server and AI/cloud components stay proprietary" | Only the AGPL client release (April 2026) is confirmed [15]. |
| Termius AI Agent "closed beta" | True as of its Nov 2024 post. No GA announcement found [16]. |

## Defects found during the cross-check

All were verified by reading the code; none was reproduced live. They are registered in
`Docs/bugs.md` under these numbers, with the full write-ups.

| # | Severity | Defect | Evidence | Fix lives in |
|---|---|---|---|---|
| 97 | **High (security)** | Local port forwards listen on **all interfaces**, not loopback. Anyone on the LAN can reach the forwarded remote service through the user's tunnel. OpenSSH binds to localhost by default. To confirm, run `lsof -iTCP:<port> -sTCP:LISTEN` and expect to see `*:<port>`. | `PortForwardingManager.swift:49-57`: `NWParameters.tcp` with no `requiredLocalEndpoint` or interface restriction | F0 |
| 98 | Medium | **"Forward SSH Agent" does nothing useful.** The channel requests `auth-agent-req`, but no libssh callbacks are registered, so libssh refuses the server's agent channel. The UI still shows "Agent Fwd" badges and the audit log records a warning. | `ProSSHLibSSHWrapper.c:1986-1992`; no `ssh_set_callbacks` anywhere in the wrapper; `HostFormView.swift:76` | F1 |
| 99 | Medium | **Secure Enclave user keys can't authenticate.** KeyForge generates them with an empty `privateKey`, the host form offers every key, and the credential resolver throws "does not contain private key material" at connect. | `KeyForgeService.swift:716-760`; `HostFormView.swift:68-70`; `DefaultSSHCredentialResolver.swift:11-16` | F1 |
| 100 | Medium | **Keyboard-interactive is not interactive.** Every round's first prompt gets the same stored secret and the other prompts get `""`. With TOTP configured, the code *replaces* the password. So password + OTP (Google Authenticator PAM), Duo menus and password-change prompts cannot succeed. | `ProSSHLibSSHWrapper.c:277-286`; `SessionManager.swift:364-369` | F2 |
| 101 | Medium | **Broadcast covers keystrokes only.** Paste, Quick Commands and file drops go to one session while the UI says "Broadcasting". Pasting a config block into a device group reaches one device. | `TerminalView.swift:923-929` (paste), `:191-196` (Quick Commands to `selectedSession`); `TerminalSurfaceView.swift:157` (drop) | F3 |
| 102 | Medium | **Links aren't clickable in the default renderer.** `LinkDetector` is used only by the non-Metal fallback, and the Metal surface has no link handling. OSC 8 URIs are stored in `grid.currentHyperlink` and never attached to cells. The README advertises clickable links. | `TerminalSurfaceView.swift:40, 399`; `OSCHandler.swift:297-316`; `TerminalGrid+OSCHandlers.swift:26` | F4 |
| 103 | Medium | **Session recording is quadratic and memory-bound.** Each commit copies `ActiveRecording` out of the dictionary before appending, so the `chunks` array (and a retain of every `Data` in it) is copied on every chunk. The whole recording stays in memory until Stop. This is the pattern CLAUDE.md forbids in `TerminalHistoryIndex`. | `SessionRecorder.swift:297-307` | F5 |
| 104 | Medium (unmeasured) | **Connect and auth block the shared transport actor.** `connectDirect` and the jump-host connect call blocking `ssh_connect` (10 s timeout, possibly twice with legacy fallback) synchronously inside the one `LibSSHTransport` actor that holds every session. Meanwhile keepalives, shell opens, forward-channel opens and disconnects for *all* sessions wait. Connecting to N hosts is serial. | `LibSSHTransport.swift:156-194, 645-683`; `sendKeepalive` and `openForwardChannel` are actor-isolated (`:559, :587`) | F8 prerequisite, or its own fix |
| 105 | Medium (process) | **CI can never fail.** Both the build and test steps end in `\| xcpretty --color \|\| true`. The runner is `macos-15` with Xcode 26.2, which cannot run a macOS 26 deployment target's tests. The README badge is always green. | `.github/workflows/ci.yml:16, 24, 33, 42` | F0 |
| 106 | Low | **ssh_config import is clipboard-only.** `readDefaultConfig()` and `readConfig(at:)` exist but are never called. `Include` is not followed. Export also goes only to the clipboard. | `HostsView.swift:50-67`; `SSHConfigImportService.swift:78-95` | F6 |
| 107 | Low | **Stale Settings text on macOS:** "System follows iOS." and "Secure Enclave integration coming in KeyForge/CertAuthority phases." Secure Enclave support shipped long ago. | `SettingsView.swift:41, 347` | F0 |
| 108 | Low (high credibility cost) | **README claims that don't match the code:** remote port forwarding; "OpenRouter Chat Completions" as the only provider; a tool table that lists internal names (`read_file_chunk`, `get_session_info`) and misses `run_cli_command`, `list_sessions` and `load_skill`; "AI currently operates on one session"; "supports 4 simultaneous sessions"; clickable links; "Xcode 26.0" (the toolchain is Xcode 27); the Swift 6.0 badge; the "What ProSSHMac Has That Competitors Don't" table (see below). | `README.md` | F0 |

**The README competitor table, re-checked 2026-10-23:**

| README row | Verdict |
|---|---|
| AI agent with file patching and an approval flow | Narrow it to "diff-approved file patching, local and remote". iTerm2 3.7 and Transit have permissioned AI, but no diff-approved patching was found. |
| AI that understands network device CLIs | **False as written.** Transit gates commands per vendor for IOS/IOS-XE/IOS-XR/NX-OS, Junos, EOS and PAN-OS [10]. Narrow it to the device-CLI command path (pager handling, prompt return, password wait) or to MikroTik. |
| Built-in Certificate Authority | No counterexample found. Keep it. |
| Secure Enclave key generation ("Prompt 3 storage only") | **False.** Prompt 3 generates Secure Enclave keys on Mac (3.0b3) [17], and Termius generates them too [18]. Ours also can't log in yet (Bug 99). |
| Metal + SSH + SFTP + CA | Unverifiable and of little value to readers. Drop it. |
| Audit logging ("SecureCRT limited") | Unverified. Soften the wording. |
| Spotlight host search | No counterexample found. Keep it. |
| Siri Shortcuts ("Prompt 3 partial") | Not unique: Secure ShellFish (macOS) [19], Core Shell Premium [6], and Prompt on iOS. |

---

## Gap analysis vs. comparable tools (re-verified 2026-10-23)

| Dimension | ProSSHMac (code) | Who does it well |
|---|---|---|
| Jump hosts | Single hop; chains truncated | Termius host chains (free since Sept 2026) [5]; Prompt 3 (since 3.0b7) [17]; Royal TSX Secure Gateway [20]; Transit (up to 4 hops) [10]; MobaXterm SSH gateway (Windows) [21] |
| ssh-agent / 1Password | None; forwarding toggle broken | Prompt 3: agent forwarding including Secure Enclave and YubiKey keys, Bitwarden agent since 3.5.0 [17]. Core Shell: agent only in its direct-download build [6]. Termius: agent forwarding free since Sept 2026 [5]. Royal TSX: 1Password, KeePass and LastPass integration [20]. |
| `~/.ssh/config` | Import and export via clipboard | Core Shell reads ssh_config (direct-download build) [6] |
| Port forwarding | Local only, bound to all interfaces | SecureCRT; MobaXterm graphical tunnel manager (Windows) [22] — local, remote and dynamic |
| Hardware keys | Secure Enclave generation (can't log in); no FIDO2 | Termius: Secure Enclave biometric keys, FIDO2 and SSH ID [18][23]. Prompt 3: Secure Enclave generation, FIDO2 (3.0b5) and YubiKey PIV [17]. |
| Broadcast | Keystrokes only; the AI can target any session | MobaXterm MultiExec (Windows) [21]; Prompt 3 Omniview [24]; Transit [10]; iTerm2 broadcast and 3.7 orchestration chats [11] |
| Scripting / expect | Quick Commands (variables) | SecureCRT Python [13]; ZOC REXX with 75+ extensions, AppleScript, Auto Macros/Replies [14]; Royal TSX Command and Key Sequence Tasks [20] |
| Serial console | None | Serial 2.0.18 (macOS 26) [8][9]; Core Shell 5.x [6]; Termius (free since Sept 2026) [5]; SecureCRT; ZOC [14]; Transit [10] |
| Session logging | Encrypted recording plus `.cast` export | Serial, SecureCRT and ZOC write plain text, which is what change records need |
| Sync | None | Prompt 3 Panic Sync [17]; Termius vault; Core Shell iCloud (Premium) [6] |
| AI | Agentic across sessions; device-CLI path; credential pause; patch approval; no command gate, no redaction | iTerm2 3.7: orchestration chats, permissions, opt-in command safety check [11]. Transit: read-only AI, vendor policy gates, redaction [10]. Termius AI Agent: confirmation before each command, closed beta as of 2024 [16]; Gloria (limited preview) [25]. Warp: client AGPL since April 2026 [15]. |
| Triggers / highlighting | None | iTerm2 (event triggers in 3.7) [11]; ZOC Auto Highlight and Replies [14] |
| Colour schemes | None | Every mainstream terminal |
| Mosh / ET | None | Prompt 3 [24], Termius |

---

## Ranked feature list

| Rank | Feature | Tier | Value | Size | Depends on | Spec |
|---|---|---|---|---|---|---|
| F0 | Release readiness | 0: before anything | ★★★★★ | M | — | `Docs/ReleaseReadiness.md` |
| F1 | SSH agent, agent forwarding, usable Secure Enclave keys | 1: finish what the UI promises | ★★★★★ | M | F0 (libssh 0.12.2) | `Docs/SSHAgent.md` |
| F2 | Keyboard-interactive prompts and MFA | 1 | ★★★★ | S–M | — | `Docs/KeyboardInteractiveAuth.md` |
| F3 | Broadcast completeness and paste safety | 1 | ★★★★ | S | — | `Docs/BroadcastPaste.md` |
| F4 | Clickable links in the Metal renderer (and OSC 8) | 1 | ★★★ | S | — | `Docs/TerminalLinks.md` |
| F5 | Plain-text session logging (plus the recording fix) | 2: network workflow | ★★★★ | S–M | — | `Docs/SessionLogging.md` |
| F6 | Host inventory at scale | 2 | ★★★★ | M | — | `Docs/HostInventory.md` |
| F7 | Vendor profiles as data | 2 | ★★★★ | M | — | `Docs/VendorProfiles.md` |
| F8 | **Change Set engine** | 2 | ★★★★★ | L | F3, F5, F6, F7, Bug 104 | `Docs/ChangeSets.md` |
| F9 | Serial console and telnet | 2 | ★★★★ | M | (F5, F7 nice to have) | `Docs/SerialConsole.md` |
| F10 | Port forwarding: remote, SOCKS, bind address | 2 | ★★★ | M | F0 | `Docs/PortForwarding.md` |
| F11 | AI trust controls: redaction, per-host policy, custom endpoint, cost meter | 3: trust and polish | ★★★★ | M | (F7 for allowlists) | `Docs/AITrustControls.md` |
| F12 | Triggers and highlighting | 3 | ★★★ | M | (F7) | `Docs/Triggers.md` |
| F13 | Menu bar (issue #18) and colour schemes | 3 | ★★★ | S + S | — | `Docs/MenuBar.md`, `Docs/ColorSchemes.md` |
| F14 | Accessibility (VoiceOver) | 3 | ★★★ | M–L | — | `Docs/Accessibility.md` |
| F15 | SFTP file management | 3 | ★★★ | M | — | `Docs/SFTPFileManagement.md` |
| F16 | Throughput vs. Terminal.app | 3 | ★★★ | (existing) | — | `Docs/RenderCost.md` R2b |
| F17 | iCloud sync | 4: later | ★★★ | L | F6 | `Docs/Sync.md` |
| F18 | FIDO2 / sk keys | 4 | ★★ | M | F0 vendor build | `Docs/FIDO2Keys.md` |
| F19 | Kerberos / GSSAPI | 4 | ★★ | M | F0 vendor build | `Docs/Kerberos.md` |
| F20 | tmux control mode | 4 | ★★ | L | — | `Docs/TmuxControlMode.md` |

F9 (serial) has no hard dependencies and can be pulled forward if Change Sets stall.

### F0 — Release readiness · `Docs/ReleaseReadiness.md` · M · ★★★★★

**Why first.** DMG users are running February's 0.9.0. Both crypto dependencies carry known
CVEs, and OpenSSL 3.4 is out of support. One defect exposes forwarded ports to the LAN. The CI
badge cannot go red. The README makes claims that network engineers will check.

**Scope:**
1. **Reproducible vendor build.** Add `scripts/build-vendor.sh`, which builds universal static
   xcframeworks for **OpenSSL 3.5 LTS** (supported until 2030-04-08 [4]) and **libssh 0.12.2** [3].
   Decide `WITH_FIDO2` (libfido2 + libcbor; see F18) and GSSAPI now, so the rebuild happens once.
   Record the versions in the README. The 0.12.1/0.12.2 CVEs that touch a client include:
   - ProxyCommand (`%r` expansion, fork failure);
   - AES-GCM tag verification;
   - a channel use-after-free;
   - the certificate-auth loop;
   - SFTP response parsing.
2. **Bug 97:** bind forwards to `127.0.0.1`/`::1`, with a regression test. A per-rule "allow LAN"
   option belongs to F10.
3. **CI (Bug 105):** use `set -o pipefail` and drop `|| true`. Run on a runner that can execute
   macOS 26 binaries (a GitHub-hosted macOS 26 image if one is available, otherwise
   self-hosted). Run the targeted suites until a full-suite baseline exists on Xcode 27.
4. **Release 0.10.0** (notarized DMG), with **Sparkle 2** auto-update (EdDSA-signed appcast on
   GitHub Releases). Without auto-update, the CVE fixes never reach installed copies.
5. **README truth pass** (Bug 108): rewrite the competitor table per the verdicts above, and fix
   the stale Settings text (Bug 107).

**Risk.** The vendor build: universal static libraries, and libssh 0.12.2 against OpenSSL 3.5.

### F1 — SSH agent, agent forwarding, Secure Enclave keys that work · `Docs/SSHAgent.md` · M · ★★★★★

**Today.** There is no explicit agent path. When a public-key host has no key selected, the
wrapper falls back to `ssh_userauth_publickey_auto`, which libssh may route to `SSH_AUTH_SOCK`;
this is untested. The forwarding toggle is broken (Bug 98), and Secure Enclave keys can't log in
(Bug 99). The vendored libssh already exports `ssh_userauth_agent`, `ssh_set_agent_socket` and
`ssh_channel_request_auth_agent`.

**Phases:**
1. **Agent auth.** A per-host "Use agent" setting with a socket choice: system (`SSH_AUTH_SOCK`);
   1Password (`~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock` [26]); Secretive;
   Bitwarden; or a custom path. Map `IdentityAgent`/`IdentitiesOnly` on ssh_config import. It must
   also work for jump hosts.
2. **Agent forwarding that works.** Register the channel-open callback for `auth-agent` channels
   and bridge each one to the selected agent socket.
3. **In-app agent for Secure Enclave keys.** Serve Secure Enclave keys over a `socketpair` handed to
   libssh with `ssh_set_agent_socket`, with optional Touch ID per signature. The same agent then
   serves forwarding, so Secure Enclave keys also work on the far side of a bastion, and each
   forwarded signature can be audited. This also makes the README's Secure Enclave claim true.

**Why it ranks this high.** Pros keep their keys in agents. Termius made agent forwarding free
in September 2026 [5]. A toggle and a key type that silently fail cost more credibility than a
missing feature does. Within F1, forwarding comes after agent auth: ProxyJump covers most cases
without exposing the agent on the bastion [27].

### F2 — Keyboard-interactive prompts and MFA · `Docs/KeyboardInteractiveAuth.md` · S–M · ★★★★

**Today.** Bug 100.

**Scope.**
- A C→Swift callback per keyboard-interactive round, carrying the name, instruction, prompts and
  echo flags.
- A prompt sheet, reusing the credential-card styling. Answers are never stored unless saved.
- TOTP auto-fill only for the prompt that matches an OTP pattern; the password prompt gets the
  password.
- Duo-style choices ("1" for push) as a per-host saved answer.
- Jump-host rounds as well.

**Why.** Bastions are where enterprises put MFA, and bastions are how network engineers reach
their gear.

### F3 — Broadcast completeness and paste safety · `Docs/BroadcastPaste.md` · S · ★★★★

**Today.** Bug 101. There is no multi-line paste warning and no send pacing.

**Scope.**
- Paste, Quick Commands, file drops and context-menu sends all follow
  `PaneManager.inputTargetSessionIDs`, keeping the credential guard.
- A multi-line paste confirmation showing the line count and the number of target sessions.
- Per-host **paste pacing**: a line delay, or wait for the prompt or echo, for gear that drops
  characters on large pastes.
- Quick Commands gains a search field and "send to group".

**Why.** It is the cheapest step towards Change Sets, and it fixes a UI that currently misleads.

### F4 — Clickable links in the Metal renderer · `Docs/TerminalLinks.md` · S · ★★★

**Today.** Bug 102.

**Scope.**
- Cmd-hover underlines and Cmd-click opens URLs detected on the Metal surface (`LinkDetector`
  over the snapshot row text).
- OSC 8: store a link ID per cell, indexing a per-grid URI table (never a `String` per cell, since
  this is the grid hot path), then render and open those links.
- Confirm before opening non-http(s) schemes.
- Benchmark per CLAUDE.md: Release builds, interleaved A/B.

### F5 — Plain-text session logging · `Docs/SessionLogging.md` · S–M · ★★★★

**Today.** None. Recording is encrypted, kept in memory and quadratic (Bug 103).

**Scope.**
- Per-host "log automatically", plus a global default.
- A folder and filename tokens (`%host %date %time %session`).
- Plain text after escape stripping, with optional per-line timestamps.
- Streamed to disk with rotation.
- Never logs input while `isEnteringCredential` is true.
- The log path shown in the session header, and an "Open log" action.
- Fix Bug 103 in the same spec: mutate in place or stream chunks to disk.

**Why.** Change records, TAC cases and audits need it, and the Change Set run log is built on it.

### F6 — Host inventory at scale · `Docs/HostInventory.md` · M · ★★★★

**Today.** Bug 106. Tags are unused in the UI, there is no search, and jump chains are blocked
both by the form and by import.

**Scope.**
- Import `~/.ssh/config` from the file (the reader exists but is unused), following `Include`;
  `Match` blocks are reported, not mapped.
- Import `~/.ssh/known_hosts`. Hashed entries can be matched but not listed.
- Delete known-host entries one at a time.
- An in-app host search across label, hostname, tags and folder.
- Tags as filter chips.
- Multi-select hosts, then "Connect all" (as tabs or a pane grid) or "Add to broadcast group".
- **Multi-hop ProxyJump:** libssh takes a comma list, plus one `SSH_OPTIONS_PROXYJUMP_CB_LIST_APPEND`
  per hop.
- Export to a file.

**Why.** Revision 1's "re-enter 200 hosts" barrier is mostly solved in code but hidden behind the
clipboard. Picking N hosts is step one of every Change Set.

### F7 — Vendor profiles as data · `Docs/VendorProfiles.md` · M · ★★★★

**Today.** Prompt regexes for 8 network OSes are hard-coded in
`ShellIntegrationScripts.vendorPromptPattern`: Cisco IOS, JunOS, EOS, RouterOS, PAN-OS, ProCurve,
FortiOS and Nokia SR OS. Prompt and pager handling for `run_cli_command` lives separately in
`DeviceCLIPrompt`/`DeviceCLICapture`.

**Scope.** One profile format (JSON or YAML), bundled with the app and also read from a user
folder like skills. A profile holds:
- exec and config prompt regexes;
- the pager-disable command (`terminal length 0`, `set cli screen-length 0`, RouterOS
  `without-paging`) and the pager pattern;
- error patterns (`% Invalid input`, `syntax error`, `failure:`);
- confirm prompts;
- commit, rollback and save verbs (`commit confirmed`, `write mem`);
- the running-config capture command.

Consumers: the history index, `run_cli_command`, Change Sets, triggers (F12), serial (F9) and AI
allowlists (F11). Contributors can add a vendor without writing Swift, which is what the README's
"more network device support" item asks for.

**Risk.** Keep the current regex behaviour; DeviceCLI tests exist.

### F8 — The Change Set engine (broadcast done right) · `Docs/ChangeSets.md` · L · ★★★★★

**What it is.** Pick N hosts (a tag, group or multi-selection) and a templated command block.
Then:
1. Run pre-checks (`show run | sec X`, `show interfaces status`, `/export`) and capture each
   device's output.
2. Push the change sequentially, in batches or in parallel. Each line waits for the device's
   prompt (expect-style, from F7), not a fixed sleep.
3. Stop on error patterns.
4. Re-run the post-checks and show a per-device diff in an approval card (the `apply_patch` card is
   the model).
5. Commit only after approval (`commit confirmed` on JunOS, `write mem` on IOS), and write the
   whole run to a plain-text change log (F5).

**Why it is the main differentiator.**
- **The parts exist:** the diff-and-approve UI, Quick Commands variables, the command-block index,
  the device-CLI capture path, and an agent that already reaches every session.
- **It makes the AI trustworthy.** The LLM proposes, a deterministic engine executes, and a human
  approves. The AI *authors* change sets and *summarises* diffs. A network engineer will not let a
  200-iteration loop type into 40 core switches, but will use a reviewable change set.
- **The gap is still open.** No Mac tool with pre/post diff and approval was found.
  - MobaXterm MultiExec (Windows) and Prompt 3 Omniview send keystrokes [21][24].
  - SecureCRT and ZOC can do this only with your own Python or REXX.
  - Transit has broadcast and a read-only AI but no diff that could be found [10].
  - iTerm2 3.7's orchestration chats are LLM-driven, not deterministic [11].
  - Off the Mac, Ansible `--check --diff`, Unimus and Itential cover parts of it.
- **The demand is real.** A TrustRadius reviewer describes using "MobaXterm Split and MultiExec
  features" to "push configuration changes for more than 100 Switches within a few hours". That
  is the workload, done blind.

**Pitfalls.**
- **Prompt detection is the real work:** banners, `--More--`, confirm prompts and vendor modes.
  F7 contains it.
- **Scale:** sessions that aren't shown already run without renderers, but 20–50 concurrent
  engines (scrollback, publish cadence, MainActor work) are unmeasured. Measure before promising a
  fleet size.
- **Connects serialize on one actor (Bug 104).** Move blocking libssh calls off the transport
  actor, as SFTP already does with `Task.detached`, then cap parallelism. libssh sessions are not
  thread-safe, so keep one handle per session.

**MVP.** Sequential and batch modes, IOS/JunOS/RouterOS/EOS profiles, a text diff and the run log.
About 6–8 phases.

### F9 — Serial console and telnet · `Docs/SerialConsole.md` · M · ★★★★

**What it is.**
- A Serial session type: pick a `/dev/cu.*` device and set baud, parity and flow control.
- Send break, from a menu item and a key binding.
- Plain-text timestamped logs (F5).
- Reconnect when the USB device re-enumerates.
- In the same transport, telnet with RFC 2217 for console servers (Opengear, Lantronix, Cisco
  terminal servers), marked insecure in the UI.

**Why.**
- Out-of-band access is where network engineers most need tooling: day-zero builds, password
  recovery, ROMMON, a broken management VRF.
- On macOS today that means a paid single-purpose app, a suite, or `screen`. In the Netgate thread
  "Console access with MacOS 26.1?" one user wrote "With 26.1, /dev just offers cu.debug-console and
  Bluetooth", and another replied "I use the app 'Serial2' by Decisive Tactics, works fine for
  console connection" [28]. That was one Prolific PL2303GT, so treat it as an anecdote, not proof
  that drivers were removed.
- The copilot on a console session (`run_cli_command` against a ROMMON or setup prompt) is still
  rare. Make it experimental, and read-only per F11.

**Fit with the code.** The terminal is transport-agnostic. `SSHShellChannel` (a raw output
stream, `send`, `resizePTY`, `close`) fits a termios channel directly. `SessionKind` gains
`.serial` and `.telnet`, and about 43 `isLocal` call sites need review. The app is not sandboxed,
so no entitlement is needed. A Mac App Store build would need `com.apple.security.device.serial`
[29].

**Pitfalls.**
- Don't replicate Serial's user-space drivers. Support whatever macOS exposes as `/dev/cu.*` and
  document the rest. The in-box driver situation on macOS 26 is murky, and vendors ship DriverKit
  drivers.

**Competitors.** Termius made serial free in September 2026 [5], Core Shell 5.x has it [6], and
so does Transit [10]. Serial still ranks as a must-have for the audience, but it is now table
stakes rather than a differentiator.

**Size.** About 3–4 phases.

### F10 — Port forwarding completion · `Docs/PortForwarding.md` · M · ★★★

**Scope.**
- **Remote (-R):** `ssh_channel_listen_forward` plus an accept loop in the transport.
- **Dynamic (-D):** a SOCKS5 handshake on the `NWListener`, then `ssh_channel_open_forward` to the
  requested destination. This lets users reach device web UIs behind a bastion.
- A bind address per rule (loopback by default, an explicit LAN opt-in with a warning).
- Map `RemoteForward`/`DynamicForward` on ssh_config import.
- Per-rule status in the UI.

### F11 — AI trust controls · `Docs/AITrustControls.md` · M · ★★★★

**Today.**
- Commands run ungated. This is the user's decision of 2026-10-16 for unfocused hosts
  (`Docs/NetworkCopilot.md`, "Open questions").
- Every turn sends the focused screen and the session list.
- Nothing is redacted.
- There is no custom endpoint and no cost display.

**Scope.**
1. **Redaction before anything leaves the Mac.** Cover SNMP communities, `password`/`secret`/`key`
   config lines (Cisco type 7/8/9, Junos `$9$`, RouterOS), PSKs, private keys and tokens. Show
   them as `‹redacted›`, with a count per chat. Device configs sent to a cloud model will get the
   app banned in many NOCs. Recommendation: on by default.
2. **Per-host AI policy:** full / ask before each command (an approval card modelled on
   `PatchApprovalCardView`) / read-only (an F7 allowlist of show/display/get commands) / no AI.
   **The default stays "full"** to honour the 2026-10-16 decision unless the maintainer changes it
   (see Open decisions).
3. **A custom OpenAI-compatible endpoint** (base URL, key and model ID) through the existing Chat
   Completions client. `OpenRouterClient` already takes both URLs as init parameters. This covers
   Ollama, LM Studio and corporate gateways. Tool-calling quality on local models varies, so label
   it as such.
4. **A per-chat token and cost meter** from the providers' usage fields.

**Competitors.** Transit (read-only, gates, redaction) [10]; iTerm2 3.7 (permissions, opt-in safety
check) [11]; Termius (confirmation before each command) [16].

### F12 — Triggers and highlighting · `Docs/Triggers.md` · M · ★★★

**Scope.**
- Regex rules mapped to a highlight colour, bell, notification or auto-reply. Auto-replies need an
  explicit confirm.
- Rules apply per host or per vendor profile.
- A built-in network set: `down`, `err-disabled`, `%LINK-3-UPDOWN`, `%SYS-5-CONFIG_I`.
- The same matcher feeds Change Set error detection.

**Implementation note.** Match completed lines in the batched reader (once per 4 ms batch), never
per byte. Benchmark per CLAUDE.md.

**Competitors.** iTerm2 [11]; ZOC Auto Highlight and Replies [14].

### F13 — Menu bar and colour schemes · `Docs/MenuBar.md` + `Docs/ColorSchemes.md` · S + S · ★★★

- **Menu bar.** There is no `.commands` or `CommandMenu` anywhere today; shortcuts live in a hidden
  button layer (`TerminalKeyboardShortcutLayer`). Implement issue #18's File, Edit, View, Session
  and Agent menus. This is basic Mac HIG, gives discoverability, and is a prerequisite for F14.
- **Colour schemes.** ANSI 16 plus foreground, background, cursor and selection colours, with
  presets and `.itermcolors` import. Add a **per-host scheme**: a red background for production is
  a genuine network-engineer safety feature.

### F14 — Accessibility · `Docs/Accessibility.md` · M–L · ★★★

**Today.** VoiceOver gets a label and a hint, nothing else.

**Scope.**
- An `NSAccessibility` text-area role on the terminal view, exposing the visible lines, cursor
  position and selection.
- Throttled announcements for new output.
- Keyboard reachability for every sidebar.

**Why.** Enterprise procurement asks for it, and Terminal.app is the benchmark.

### F15 — SFTP file management · `Docs/SFTPFileManagement.md` · M · ★★★

**Scope.**
- Rename, delete, mkdir, rmdir and chmod (new wrapper calls).
- Folder transfers.
- A download destination picker.
- Drop-to-upload onto SSH sessions, to the current directory (OSC 7) or the browser's folder,
  instead of typing a local path.
- Resume from an offset (`sftp_seek64`).

**Why.** This is the sysadmin half of the audience; Prompt, Termius and Core Shell all have it.

### F16 — Throughput · existing `Docs/RenderCost.md` R2b · ★★★

**Today.**
- The Release real-app path runs at 3.80–5.01 MB/s (detached, no window). Terminal.app manages
  26.5 MB/s with rendering.
- R2b is merged but unvalidated, and issue #13 (FPS drops) is open.

**Plan.** Keep the existing plan; this does not need a new spec. It matters for `show tech`, build
logs and the "fast terminal" claim more than for interactive device work.

### Tier 4 — later

- **F17 iCloud sync** (`Docs/Sync.md`, L).
  - Sync hosts, snippets, known hosts and change sets, **not** private keys.
  - **Lateral idea from revision 1, still good:** combine the built-in CA with per-device Secure
    Enclave keys. Each device gets a short-lived certificate signed by the CA, and servers trust
    the CA once. That is what Termius's SSH ID gives [23], without editing `authorized_keys` per
    device. It needs F1 phase 3 first, since Secure Enclave keys must be able to log in.
  - Caveat: OpenSSH certificate support on Cisco IOS and JunOS is limited. This works for Linux
    bastions, less so for the switches themselves.
- **F18 FIDO2/sk keys** (`Docs/FIDO2Keys.md`, M).
  - libssh 0.12 supports them through libfido2, but `WITH_FIDO2` defaults to OFF and our build
    lacks it [30]. Rebuild with libfido2 and libcbor, then add enrolment and touch UI.
  - Termius and Prompt 3 both have it [18][17].
  - Lower priority, because once F1 lands Secure Enclave keys cover most Mac users.
- **F19 Kerberos/GSSAPI** (`Docs/Kerberos.md`, M). The vendored libssh exports the GSSAPI entry
  points but links no GSS library. 0.12 adds GSSAPI key exchange [30]. Relevant for Active
  Directory shops; it is a vendor-build decision made in F0.
- **F20 tmux control mode** (`Docs/TmuxControlMode.md`, L). Nice for sysadmins, irrelevant on
  network gear.

## Probably not worth it now (contrarian calls)

- **The Kitty graphics protocol (the README's #1 "high impact" item).** Routers don't emit images,
  and the parser ignores APC today. Ghostty, Kitty, WezTerm, iTerm2, Konsole and Warp already
  serve that crowd [31]. Defer it until Tiers 1–2 ship.
- **Mosh / Eternal Terminal.** Network devices don't run mosh-server, libssh gives no help, and it
  means maintaining a whole UDP protocol. Prompt 3 and Termius cover it [24].
- **RDP/VNC/web tabs.** That is Royal TSX's category. Stay a terminal.
- **More visual effects** (CRT, Matrix, scanner). They cost nothing to keep, but they signal "toy"
  to this audience. Don't lead with them in screenshots.
- **Team vaults / shared credentials.** That means a backend, key escrow and a support burden. A
  secret-free export of host lists and change sets gets most of the value. VanDyke framed exactly
  this as a feature in SecureCRT 9.6 ("easy to exclude usernames and passwords from the exported
  sessions") [32].
- **A higher AI iteration cap or "autonomous" modes.** That is the opposite of what this audience
  trusts. iTerm2 and Transit are moving towards permissions, not away from them.

## Open decisions for the maintainer

1. **AI command gate default.** On 2026-10-16 the decision was no gate for unfocused hosts. F11
   keeps that as the default and adds per-host policy. Should network-device hosts (by
   `ShellIntegrationType`) default to read-only, or to "ask"?
2. **Redaction on by default?** Recommended yes. It changes what the model sees, so confirm
   whether that affects the NetworkCopilot Phase 7 comparisons.
3. **Mac App Store, ever?** A sandboxed build would lose agent sockets, direct `~/.ssh` reads and
   ProxyCommand, as Core Shell's App Store build did [6], and would need the serial entitlement. If
   the answer is "never", say so in the README; it is a selling point.
4. **The vendor build in F0:** include libfido2 (F18) and GSSAPI (F19) now, or rebuild later?
5. **Serial before Change Sets?** Serial is smaller, independent and now table stakes; Change Sets
   is the differentiator. Revision 1 put Change Sets first, and this list keeps that order.

## Caveats

- Code facts come from reading the source at `0ebe8e4` (2026-10-23). Bugs 97–108 were traced by
  reading, not reproduced. Bug 97 needs one `lsof` check, and Bug 104's impact is unmeasured.
- Competitor facts were re-checked on the web on 2026-10-23 from vendor pages, changelogs and
  release notes where possible. Some rows rest on one source:
  - Warp's licensing comes from a news report.
  - iTerm2 3.7's date comes from its downloads page.
  - Transit is one repository with 21 commits, 1 star and no releases, so its features are claims
    in its README.
- Effort sizes assume one developer working phase by phase with Claude Code, and are judgment.
- The iOS app (ProSSH) and its SSH stack are outside this repository and were not checked.

## Sources

1. [GitHub — khpbvo/ProSSHMac](https://github.com/khpbvo/ProSSHMac) (0 stars and 0 forks; issues #13 and #18 open; one release, v0.9.0 pre-release, 2026-02-26)
2. [libssh 0.11.0 release](https://www.libssh.org/2024/08/08/libssh-0-11-0-release/) ("Implemented proxy jump using libssh") and [issue #178](https://gitlab.com/libssh/libssh-mirror/-/issues/178)
3. libssh 0.12.1 security release [libssh.org/?p=999](https://www.libssh.org/?p=999) and 0.12.2 (2026-07-28) [libssh.org](https://www.libssh.org/); [tags](https://gitlab.com/libssh/libssh-mirror/-/tags)
4. [OpenSSL release strategy](https://openssl-library.org/policies/releasestrat/) (3.4 supported until 2026-10-22; 3.5 LTS until 2030-04-08) and [vulnerabilities](https://openssl-library.org/news/vulnerabilities/)
5. Termius changelogs: [Android](https://docs.termius.com/changelog/android) (7.10.0, 2026-09-15) and [desktop](https://docs.termius.com/changelog/desktop.md) (10.1.0, 2026-09-21; 10.1.3, 2026-09-30)
6. [Core Shell — Mac App Store](https://apps.apple.com/ml/app/core-shell/id1354319581?platform=mac) (5.1.1, Sept 20, 2026; serial in 5.0; Shortcuts in 4.0; Core Helper features only in the direct-download build since 3.8.6)
7. [Serial 1 — Mac App Store listing](https://apps.apple.com/us/app/serial/id877615577?mt=12) (1.4.11, 2021; not Serial 2)
8. [Serial — Decisive Tactics](https://www.decisivetactics.com/products/serial/)
9. [Serial release notes](https://www.decisivetactics.com/products/serial/release-notes) (2.0.18, 2025-09-09, macOS 26 support)
10. [Transit Community Edition](https://github.com/transit-community/transit) (Apache-2.0; macOS/Windows/Linux; 21 commits, no releases)
11. [iTerm2 downloads and release notes](https://iterm2.com/downloads.html) (3.7.6, built 2026-10-15; 3.7.0 adds orchestration chats, watches and an opt-in command safety check)
12. [Ghostty 1.3.0 release notes](https://ghostty.org/docs/install/release-notes/1-3-0) (latest 1.3.1, 2026-03-13)
13. [SecureCRT version history](https://www.vandyke.com/products/securecrt/history.txt) (9.7.3, 2026-07-01)
14. [ZOC Terminal features](https://www.emtec.com/zoc/features.html)
15. [Help Net Security — Warp open-sources its client](https://www.helpnetsecurity.com/2026/04/30/warp-open-source-client/) (2026-04-30)
16. [Termius — AI Agent](https://termius.com/blog/ai-agent) (Nov 12, 2024 post: closed beta, confirmation before every command)
17. [Panic — Prompt 3 beta release notes](https://help.panic.com/prompt/prompt3-releasenotes/) and [Prompt 3 release notes](https://help.panic.com/releasenotes/prompt3) (3.5.3, Oct 7, 2026)
18. [Termius — SSH keys and certificates](https://docs.termius.com/keychain/ssh-keys-and-certificates)
19. [Secure ShellFish — App Store](https://apps.apple.com/jp/app/secure-shellfish-ssh-sftp/id1336634154) (Shortcuts actions on macOS)
20. [Royal TSX for macOS — features](https://www.royalapps.com/ts/mac/features)
21. [MobaXterm features (Windows)](https://mobaxterm.mobatek.net/features.html)
22. [MobaXterm documentation](https://mobaxterm.mobatek.net/documentation.html)
23. [Termius — SSH ID](https://termius.com/blog/ssh-id-passkeys-for-ssh) (May 20, 2026)
24. [Panic — Prompt help](https://help.panic.com/prompt/) and [Prompt 3](https://panic.com/prompt/)
25. [Termius — Gloria DevOps agent](https://termius.com/blog/devops-ai-agent-gloria) (Aug 20, 2025, limited preview)
26. [1Password — SSH agent compatibility](https://www.1password.dev/ssh/agent/compatibility/)
27. [SSH agent forwarding vs ProxyJump (DEV Community)](https://dev.to/mahafuz/ssh-agent-forwarding-vs-proxyjump-why-agent-forwarding-is-dangerous-and-what-to-use-instead-1no6)
28. [Netgate Forum — "Console access with MacOS 26.1?"](https://forum.netgate.com/topic/199414/console-access-with-macos-26.1)
29. [Apple Developer Forums — serial device entitlement](https://developer.apple.com/forums/thread/94177)
30. [libssh CHANGELOG](https://gitlab.com/libssh/libssh-mirror/-/raw/master/CHANGELOG), [DefineOptions.cmake](https://gitlab.com/libssh/libssh-mirror/-/raw/master/DefineOptions.cmake), and the [0.12.0 announcement](https://archive.libssh.org/libssh/2026-02/0000001.html) (Feb 10, 2026)
31. [Kitty graphics protocol — implementations](https://sw.kovidgoyal.net/kitty/graphics-protocol/)
32. [SecureCRT 9.6 press release](https://www.vandyke.com/aboutus/news/pressreleases/securecrt/securecrt96.html) (Nov 19, 2024)
