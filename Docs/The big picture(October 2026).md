# ProSSHMac: What to Build Next and Where It Falls Behind (October 2026)

**Build a deterministic multi-device change engine first: send a command to many sessions, detect prompts the way expect does, capture state before and after, diff it, and require approval before anything is committed. Then build a native serial/console transport.** Both are aimed at the network-engineer workflow that ProSSHMac already markets to. Both reuse pieces you already have (the apply_patch approval card, Quick Commands variables, command-block indexing, the AI tool loop). And both land where Mac competitors are either crude (keystroke broadcast) or locked inside single-purpose paid apps (Serial, SecureCRT, ZOC). Before either, fix the basic connectivity gaps (ProxyJump, ssh-agent/1Password, ~/.ssh/config import, SOCKS). Without them a lot of pros will uninstall on day one, whatever the AI can do.

## TL;DR

- **Most valuable feature:** a "Change Set" engine: per-host templated commands, prompt-aware sequential/parallel execution across N devices, automatic pre/post `show` capture, a diff view and an approval gate. Your planned "multi-exec" and "multi-session AI orchestration" should both sit on top of it, not be built separately. MobaXterm's MultiExec and Prompt 3's Omniview broadcast keystrokes. Nothing on the Mac combines broadcast with verification, and that combination is the gap.
- **Second feature:** a serial/USB console transport (termios on `/dev/cu.*`, break signal, plain-text timestamped logging), with the AI copilot available on console sessions too. On macOS, console access means a paid single-purpose app (Serial 2) or a heavyweight suite (SecureCRT, ZOC). Your DMG/non-App-Store distribution makes this cheap to build.
- **What's missing vs. peers, in priority order:** ProxyJump/bastions, ssh-agent and 1Password agent support, ~/.ssh/config import, dynamic (SOCKS) forwarding, plain-text session logs, telnet, FIDO2 keys, sync. Probably **not** worth it right now: Kitty graphics (currently your #1 roadmap item), mosh, RDP/VNC, and more visual effects.

## Key Findings

### What ProSSHMac actually is today (verified from the README; source code not audited)

Verified from the repository front page, which shows 363 commits, 2 open issues, 0 stars/forks, version 0.9.0 ("first public release… 1.0.0 will ship once known critical bugs are cleared"), macOS 26+ only, MIT licence, with libssh (LGPL-2.1) and OpenSSL vendored as universal xcframeworks:\[1\]

- **Terminal:** Metal renderer with a glyph atlas ("up to 120fps"); tree-based split panes; local PTY shell; detachable windows; VT100/xterm parser including OSC 133; buffer search; session recording (encrypted, asciinema export); link detection.\[1\]
- **SSH/security:** auth by password, public key, certificate and keyboard-interactive; KeyForge (Ed25519/ECDSA/RSA); built-in SSH CA with Secure Enclave support; **local and remote** port forwarding; Touch ID gating; AES-256-GCM + Keychain storage; TOFU known-hosts; audit logging of connections, auth, forwards and transfers.\[1\]
- **Files:** SFTP transfers and a lazy-loading SFTP/local file browser.\[1\]
- **Productivity:** Quick Commands (variables, host/global scope, JSON import/export), Spotlight, Siri Shortcuts.\[1\]
- **AI copilot:** OpenRouter-only, tool-calling agent (screen read, command history, execute_and_wait, send_input, filesystem search/read, apply_patch with an approval diff), up to 200 iterations. Only MikroTik RouterOS is tested; Cisco/Juniper/Arista are "possibly supported just not yet tested."\[1\]
- **Roadmap (unchecked):** Kitty graphics protocol, more network-device support, multi-session AI orchestration, iCloud/CloudKit sync, and a command palette with multi-exec broadcast. The README also says "ProSSHMac already supports 4 simultaneous sessions."\[1\]
- **Distribution:** DMG via GitHub Releases with Developer ID signing and notarization scripts.\[1\] No Mac App Store listing.

**Not determinable from what I could access:** I could not read docs/bugs.md, docs/FutureFeatures.md, the two open issues, the releases page, commit history or the source/entitlements. Items marked "absent" below are **not mentioned in the README**; I have not confirmed them absent in code. That covers ProxyJump, agent, agent forwarding, SOCKS, ssh_config import, serial, telnet, mosh, FIDO2 and triggers. The vendored libssh version and the App Sandbox status are also unknown. Check these first: grep for `SSH_OPTIONS_PROXYJUMP`, `ssh_userauth_agent`, `com.apple.security.app-sandbox`, and `LIBSSH_VERSION_*` in `Vendor/`.

### Gap analysis vs. comparable tools (verified competitor facts, 2025–2026 sources)

| Dimension | ProSSHMac (README) | Who does it well |
|---|---|---|
| Jump hosts / bastions | Not mentioned | Prompt 3 (jump hosts + agent forwarding), Core Shell (ProxyJump via OpenSSH), MobaXterm ("SSH gateway"),\[2\]\[3\]\[4\] Royal TSX (Secure Gateway), Termius (host chains, made free on Android 7.10.0 on Sept 15, 2026 and on desktop 10.1.0 on Sept 30, 2026, per the Termius changelogs) |
| ssh-agent / 1Password agent | Not mentioned | Core Shell (OpenSSH-based; agent access only in its non-App-Store build),\[5\] Royal TSX (1Password/KeePass credential integration) |
| ~/.ssh/config | Not mentioned | Core Shell reads ssh_config;\[3\] Termius can convert known hosts into saved hosts |
| Port forwarding | Local + remote | SecureCRT, MobaXterm (graphical tunnel builder)\[6\] add dynamic/SOCKS |
| Hardware keys | Secure Enclave gen + CA | Termius (Secure Enclave biometric keys, FIDO2, and "SSH ID" device-bound passkeys, 2026),\[7\]\[8\] Prompt 3 (Secure Enclave generation on Mac, YubiKey PIV, certificates)\[9\]\[10\] |
| Broadcast input | Planned | MobaXterm MultiExec, Prompt 3 Omniview,\[4\]\[11\] Termius AI Agent across terminals |
| Scripting / expect | Snippets only | SecureCRT (Python 3.12/3.13, button bar),\[12\] ZOC (REXX with 75+ terminal extensions, AppleScript, triggers, recorded login scripts),\[13\] MobaXterm macros,\[14\] Royal TSX Command/Key Sequence Tasks\[15\] |
| Serial console | Not mentioned | Serial 2 (user-space drivers for FTDI/Prolific/CH34x/SiLabs/TI, Cisco USB console, break emulation, logging, timestamps, RFC2217 telnet; macOS 26 support in 2.0.18),\[16\]\[17\]\[18\] SecureCRT, ZOC, Core Shell 4.0 (USB/Bluetooth/built-in serial),\[5\] MobaXterm |
| Session logging | Encrypted recording/asciinema | Serial (manual/auto logging + timestamps), SecureCRT, ZOC: plain text, which is what change records need |
| Sync | Planned (CloudKit) | Prompt 3 (Panic Sync: servers, passwords, keys, clips),\[2\] Termius (encrypted vault), Core Shell (iCloud, Premium)\[5\] |
| AI | Agentic, approval-gated, BYO OpenRouter key | Termius AI Agent (closed beta, confirmation before every command, no access to keys/passwords) and Gloria (experimental cloud DevOps agent, limited preview);\[19\]\[20\] Warp (client released on GitHub on April 28, 2026 under AGPL-3.0 with MIT-licensed UI crates, while its server and AI/cloud components stay proprietary) |
| Mosh / ET | Not mentioned | Prompt 3, Termius |

**Your README's "What ProSSHMac Has That Competitors Don't" table is partly wrong, and that costs you credibility with the exact audience you want.** Prompt 3 *generates* Secure Enclave keys on Mac: Panic's beta notes say "Mac: Added support for generating device specific keys that utilize the Secure Enclave".\[9\] Termius also generates biometric Secure Enclave keys. Termius has shipped a confirmation-gated AI agent with infrastructure context.\[20\] Core Shell Premium offers Shortcuts automation.\[5\] Fix the table before 1.0. Network engineers check these claims.

## Recommendation #1: The Change Set engine (broadcast done right)

**What it is.** Pick N hosts (a tag or group). Pick a templated command block (Quick Commands already has variables and per-host scope). Then:
1. Run pre-checks (`show run | sec X`, `show interfaces status`, `/export`) and capture the output per device.
2. Push the change sequentially, in batches, or in parallel. Each line waits for the device's prompt (expect-style), not a fixed sleep.
3. Stop on error patterns (`% Invalid input`, `syntax error`, `failure:`).
4. Re-run the post-checks and show a per-device diff in the existing approval-card UI.
5. Commit only after approval: `commit confirmed` on JunOS, `write mem` on IOS. Write the whole run to a plain-text change log.

**Why this beats the alternatives for ProSSHMac specifically:**
- **The existing parts fit.** You already have a diff-and-approve UI (apply_patch), a variable system, a command-block index, and an agent that runs `execute_and_wait`. The engine is mostly orchestration around parts that already exist.
- **It makes the AI more trustworthy.** Right now the roadmap puts "multi-session AI orchestration" first. Reverse that. Build the deterministic executor, then let the AI *author* change sets and *summarise* diffs. The LLM proposes, a deterministic engine executes, and a human approves. The README pitches "Who needs CCNA when you've got ProSSH?", but a network engineer will not let a 200-iteration LLM loop type into 40 core switches. A reviewable change set they will use.
- **Competitors leave this gap open.** MobaXterm's MultiExec and Prompt 3's Omniview send keystrokes; neither checks results.\[4\]\[11\] SecureCRT and ZOC can do all of this, but only if you write the Python/REXX yourself. Termius's agent spans hosts but is a closed beta that runs through their cloud. A native, open-source, prompt-aware, diff-verified multi-device push on the Mac is unoccupied ground.
- **It matches the real workload.** Pushing the same VLAN/ACL/NTP change across a QFX spine-leaf fabric, or across a fleet of telecom CPEs, is exactly this job. Sander de Beus, an IT Service Coördinator reviewing on TrustRadius, writes that "MobaXterm Split and MultiExec features helped me push configuration changes for more than 100 Switches within a few hours". That is real demand, but done blind.

**Pitfalls and effort (judgment):**
- **OSC 133 doesn't exist on network gear.** Command boundaries on IOS/JunOS/RouterOS need prompt-regex detection per vendor profile, and pagers need handling: send `terminal length 0`, `set cli screen-length 0`, or append RouterOS `without-paging`. This vendor-profile layer is the real work. It is also what your "more network device support" roadmap item already asks contributors for, so define it as data files (prompt regex, pager-disable, error patterns, commit/rollback verbs).
- **The 4-session ceiling.** "Supports 4 simultaneous sessions" is fine for panes but not for fleet pushes. Change Sets need headless sessions (an SSH channel plus an off-screen grid, or no renderer at all). Don't render 50 Metal panes.
- **libssh concurrency.** libssh sessions aren't thread-safe across threads. Use one session per actor, which fits your Swift 6 actor model, and cap parallelism.
- **Effort:** roughly 4–8 weeks for an MVP (sequential mode, IOS/JunOS/RouterOS profiles, text diff). Medium risk, mostly in prompt detection edge cases: banners, `--More--`, confirm prompts.

## Recommendation #2: Native serial/console transport

**What it is.** A Serial session type: pick a `/dev/cu.*` device, set baud/parity/flow, send break (a menu item and a key binding), keep plain-text timestamped logs, and reconnect automatically when the USB device re-enumerates. Add TCP/telnet to console servers (Opengear/Lantronix/Cisco terminal servers) in the same transport, since the code is close.

**Why it is #2:**
- **Out-of-band is where network engineers need tooling most.** Day-zero builds, password recovery, ROMMON and a broken mgmt VRF all need a console cable. On the Mac today that means buying Serial 2, SecureCRT or ZOC, or suffering through `screen`. Serial's own App Store page lists FTDI, Prolific, CH34x, SiLabs and TI bridges plus "Cisco (and other) devices with built-in USB console ports." In the Netgate Forum thread "Console access with MacOS 26.1?", one user reports "With 26.1, /dev just offers cu.debug-console and Bluetooth", and another replies "I use the app 'Serial2' by Decisive Tactics, works fine for console connection."
- **AI on a console session is the differentiator.** Pointing the copilot at a console session during recovery, with `send_input` driving a ROMMON prompt, is something no competitor offers. Treat it as experimental, read-only by default.
- **Distribution makes it cheap.** A Developer ID DMG app can open `/dev/cu.*` with plain POSIX termios. No IOKit driver work is needed for adapters macOS already supports (CDC-ACM, and FTDI/others via Apple or vendor DriverKit drivers).

**Pitfalls:**
- **Don't try to match Serial's user-space drivers.** Its selling point is driving adapters with no installed driver. Replicating that means USB-level protocol work per chipset and is a trap. Support what macOS exposes as `/dev/cu.*` and document the rest.
- **Sandboxing.** If you ever want the Mac App Store, sandboxed apps need the `com.apple.security.device.serial` entitlement. Keep serial behind a capability check.
- **Effort:** 1–3 weeks for termios + break + logging, because the terminal emulator is transport-agnostic. Low risk.

## The broader ranked list of missing features

Effort and risk are my judgment; the libssh facts are verified.

1. **ProxyJump / bastion chains**: critical; low–medium effort. libssh 0.11.0 (Aug 2024) "Implemented proxy jump using libssh".\[21\] libssh's Feb 10, 2026 announcement of 0.12.0 and 0.11.4 adds "Stability and compatibility improvements of ProxyJump" (backported to 0.11.4 as well). Pitfall: earlier libssh built ProxyJump by shelling out to OpenSSH's `ssh` (libssh issue #178).\[22\] If your vendored libssh is older than 0.11, upgrade before anything else. Known-hosts verification must run per hop.
2. **ssh-agent and 1Password/Secretive agent support**: critical for pros; low effort via `ssh_userauth_agent` against `SSH_AUTH_SOCK` or an `IdentityAgent` path. The 1Password socket on macOS is `~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock`.\[23\] That is reachable from a non-sandboxed DMG app but awkward from a sandboxed one: Core Shell restricts agent access, ssh_config reading and ProxyCommand to its non-App-Store build for exactly this reason.\[5\] Agent *forwarding* is lower priority. ProxyJump covers most cases without exposing your agent on the bastion.\[24\]\[25\]
3. **~/.ssh/config import (one-way, plus a re-sync button)**: low effort. libssh has a config parser. It removes the "re-enter 200 hosts" barrier. Also import `~/.ssh/known_hosts` so TOFU doesn't re-prompt for every known device.
4. **Plain-text session logging with timestamps** (per host, auto-on option, filename tokens): low effort, high value for change records and TAC cases. The encrypted asciinema recording doesn't do this job.
5. **Dynamic (SOCKS) forwarding**: medium effort, since you already proxy through NWListener. Useful for reaching device web UIs behind a bastion.
6. **Triggers/highlighting rules** (regex → colour/notify/auto-respond): medium effort. iTerm2 and ZOC have them.\[26\]\[27\] Highlighting `down`, `err-disabled` or `%LINK-3-UPDOWN` is a large readability win for network output, and the same regex engine serves the Change Set error detection.
7. **Telnet**: low effort. Lab gear, console servers and legacy CPE still need it. Mark it insecure in the UI.
8. **iCloud/CloudKit sync** (already planned) plus a shared schema with ProSSH iOS: medium effort. **Lateral idea:** sync hosts, snippets, known_hosts and change sets, *not* private keys. Combine your built-in CA with per-device Secure Enclave keys: each device (Mac, iPhone running ProSSH) gets a short-lived certificate signed by your CA, and servers trust the CA once. That gives you what Termius's "SSH ID" passkeys give, without editing authorized_keys per device, and it pairs the free Mac app with the paid iOS app. **Caveat (unverified):** OpenSSH-certificate support on Cisco IOS/JunOS is limited. This works for Linux bastions and jump hosts, less so for the switches themselves. Also check that your swift-nio-ssh fork handles certificate auth before promising cross-app parity.
9. **FIDO2/sk keys**: medium effort. libssh 0.12.0 added "Support for FIDO/U2F keys (internal implementation using libfido2)".\[28\] Lower priority because Secure Enclave covers most Mac users, but YubiKey users expect it.
10. **Local/self-hosted model endpoints for the AI** (any OpenAI-compatible URL: Ollama, LM Studio, corporate gateway) plus **output redaction**: low effort, big trust gain. Device configs contain SNMP communities, PSKs, TACACS keys and password hashes. Sending them to OpenRouter by default will get the app banned in many NOCs. Add a read-only "show-commands-only" policy for network devices by default.
11. **tmux control-mode integration**: medium–high effort. Nice for the sysadmin half of your audience, irrelevant for network gear.
12. **Accessibility audit of the Metal renderer**: unknown effort. A custom Metal grid likely exposes nothing to VoiceOver unless you implement accessibility elements. I did not verify this; check before 1.0.

## Probably not worth it now (contrarian calls)

- **Kitty graphics protocol (your #1 "high impact" item):** it is technically elegant with your glyph atlas, but routers don't emit images. It serves the Ghostty/Kitty developer crowd, which already has free, faster-moving terminals. Defer until the connectivity gaps are closed.
- **Mosh / Eternal Terminal:** network devices don't run mosh-server, libssh gives you nothing towards it, and it is a whole UDP protocol to maintain. Prompt 3 and Termius cover it for those who need it.\[29\]
- **RDP/VNC/web tabs (Royal TSX territory):** a different product category. Stay a terminal.
- **More visual effects (CRT, Matrix, scanner):** they cost nothing to keep but signal "toy" to the audience you want. Don't lead with them in screenshots.
- **Team vaults / shared credentials:** a backend, key escrow and a support burden that a solo maintainer shouldn't take on. Shareable, secret-free change-set and host-list export gets you most of the value; VanDyke's Nov 19, 2024 release announcement for SecureCRT 9.6 framed exactly this as a feature, saying it makes "it easy to exclude usernames and passwords from the exported sessions."
- **Raising the AI iteration cap or "autonomous" modes:** the opposite direction from what network engineers will trust.

## Caveats

- Everything about ProSSHMac comes from the README. I could not read source, docs/bugs.md, issues or releases, so "absent" means "not documented." Some items may exist in code.
- Competitor facts come from vendor pages, changelogs and release notes where possible. Some secondary listings (download mirrors, comparison blogs written by competing vendors such as CtrlOps, Transit and TermAI) were used only for corroboration and are commercially motivated.
- Effort estimates assume one experienced Swift developer and are judgment, not measurement.
- Termius serial support is confirmed on both mobile and desktop: the Android 7.10.0 changelog (Sept 15, 2026) and the Windows/Linux/macOS 10.1.0 changelog (Sept 30, 2026) both state "Proxy, Agent Forwarding, Host chains, and Serial connections are now available for free," so Termius belongs in the serial-console row as well.

## Sources

1. [GitHub - khpbvo/ProSSHMac](https://github.com/khpbvo/ProSSHMac)
2. [Prompt 3 - Developer Tools App](https://mwm.ai/apps/prompt-3/1594420480)
3. [Core Shell — Download Mac app on Setapp](https://setapp.com/apps/core-shell)
4. [MobaXterm Xserver with SSH, telnet, RDP, VNC and X11 - Features](https://mobaxterm.mobatek.net/features.html)
5. [Core Shell App - App Store](https://apps.apple.com/ml/app/core-shell/id1354319581?platform=mac)
6. [MobaXterm Xserver with SSH, telnet, RDP, VNC and X11 - Documentation](https://mobaxterm.mobatek.net/documentation.html)
7. [SSH keys and certificates](https://docs.termius.com/keychain/ssh-keys-and-certificates)
8. [SSH ID](https://termius.com/blog/ssh-id-passkeys-for-ssh)
9. [Prompt Beta Release Notes](https://help.panic.com/prompt/prompt3-releasenotes/)
10. [ShellDrop vs Prompt 3: A Free iOS SSH Client Alternative to Panic's App](https://shelldrop.sh/blog/shelldrop-vs-prompt-3/)
11. [Prompt](https://help.panic.com/prompt/)
12. [Press Releases - SecureCRT 9.6 (Official) and SecureFX 9.6 (Official) from VanDyke Software Help System Administrators Easily Export and Share Sessions with Teams](https://www.vandyke.com/aboutus/news/pressreleases/securecrt/securecrt96.html)
13. [Software:ZOC - HandWiki](https://handwiki.org/wiki/Software:ZOC)
14. [Stop Using PuTTY! The Ultimate MobaXterm Guide for 2026](https://ecn-apps.com/pages/articles/mobaxterm-guide.html)
15. [Royal TSX (for macOS)](https://www.royalapps.com/ts/mac/features)
16. [Serial App - App Store](https://apps.apple.com/us/app/serial/id877615577?mt=12)
17. [Serial - Connect your Mac to Anything - Decisive Tactics, Inc.](https://www.decisivetactics.com/products/serial/)
18. [Serial Release Notes - Decisive Tactics, Inc.](https://www.decisivetactics.com/products/serial/release-notes)
19. [DevOps AI Agent Gloria - Termius Blog](https://termius.com/blog/devops-ai-agent-gloria)
20. [AI Agent: Chat with Your Infrastructure - Termius Blog](https://termius.com/blog/ai-agent)
21. [libssh 0.11.0 release](https://www.libssh.org/2024/08/08/libssh-0-11-0-release/)
22. [implement ssh proxy using libssh for jump hosts](https://gitlab.com/libssh/libssh-mirror/-/issues/178)
23. [Get started with 1Password for SSH - 1Password Developer](https://www.1password.dev/ssh/get-started)
24. [How to Configure SSH Jump Hosts (ProxyJump) on Ubuntu](https://oneuptime.com/blog/post/2026-03-02-configure-ssh-jump-hosts-proxyjump-ubuntu/view)
25. [SSH Agent Forwarding vs ProxyJump: Why Agent Forwarding Is Dangerous and What to Use Instead - DEV Community](https://dev.to/mahafuz/ssh-agent-forwarding-vs-proxyjump-why-agent-forwarding-is-dangerous-and-what-to-use-instead-1no6)
26. [Terminal Emulator for Windows and macOS - Features and List of Emulations for the ZOC Terminal Emulator](https://www.emtec.com/zoc/features.html)
27. [Best SSH Clients for macOS in 2026 — Termalin](https://termal.in/blog/best-ssh-client-mac/)
28. [gitlab.com](https://gitlab.com/libssh/libssh-mirror/-/tags)
29. [Prompt 3](https://panic.com/prompt/)
