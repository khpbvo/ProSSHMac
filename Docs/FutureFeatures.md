# Future Features & Improvements

Prioritized roadmap based on competitive analysis against Termius, Prompt 3, Ghostty, Warp, rootshell, SecureCRT, iTerm2, Kitty, and others.

---

## Priority 1 — AI Terminal Assistant

**Why:** AI-powered command assistance is the #1 differentiator in the terminal space right now. Warp (Claude 3.5 / GPT-4o), Termius, and rootshell (Claude / ChatGPT / Gemini) all ship AI features. Users expect help with command construction, error explanation, and workflow automation.

**What to build:**

- [ ] **Inline AI panel** — `Cmd+K` popup (or sidebar) that reads the current terminal context (last N lines of output) and accepts natural language queries
- [ ] **Error explanation** — Detect non-zero exit codes or common error patterns and offer one-click "Explain this error" action
- [ ] **Natural language → shell command** — Translate requests like "find all files larger than 100MB modified in the last week" into the correct `find` command
- [ ] **Bring Your Own Key (BYOK)** — Support user-provided API keys for Claude, OpenAI, and local models (Ollama). No vendor lock-in
- [ ] **Context-aware suggestions** — Use the current working directory, shell history, and host OS (from `uname` output) to tailor suggestions
- [ ] **Privacy controls** — Clear toggle for what terminal data is sent to the AI provider. Option to use fully local models for air-gapped environments

**Competitive positioning:** Would make ProSSHMac the first shipping native macOS Metal-rendered SSH client with AI. rootshell has this but is still in beta.

---

## Priority 2 — Performance: Fix Documented Bottlenecks

**Why:** Ghostty and Alacritty set the throughput bar. ProSSHMac has a documented **400x throughput gap** (see `docs/Optimization.md`). If `cat large_file.txt` or heavy build output feels sluggish, users will notice immediately — no amount of features compensates for a slow terminal.

**What to fix (summary — full details in Optimization.md):**

- [x] **Grid COW traps** — `scrollUp()`, `eraseInLine()`, and 6 other methods trigger full copy-on-write array copies on every call. Use `withActiveCells { }` instead
- [x] **Bulk byte processing** — `printCharacter()` is called per-byte. Write a dedicated fast path in `printASCIIBytes` that processes entire runs: one `withActiveCells` call, one `markDirty`, inline cursor advance
- [ ] **Eliminate Data → Array copy** — `VTParser.feed()` copies every chunk into `Array<UInt8>`. Iterate `Data` directly or use `withUnsafeBytes`
- [x] **Array-indexed parser tables** — Replace `Dictionary` lookup per byte with a flat `[UInt16]` array (14 states x 256 bytes = 3,584 entries). Pure O(1)
- [ ] **Reduce actor boundary overhead** — Parser and grid are always accessed sequentially. Batch post-feed grid queries or merge onto a single actor
- [x] **Pre-allocated snapshot buffers** — Reuse `[CellInstance]` between frames instead of allocating 10,000-element arrays at 120fps
- [x] **Remove redundant text stream** — `LocalShellChannel` decodes UTF-8 Strings that are never consumed by the parser pipeline

**Target:** `dd if=/dev/urandom bs=1024 count=100000 | base64` in under 2 seconds (~89 MB/s throughput).

---

## Priority 3 — Inline Image Protocol (Kitty Graphics / Sixel)

**Why:** The Kitty graphics protocol is becoming a de facto standard for inline images in terminals. Ghostty, Kitty, Warp, and rootshell all support it. Developers use it for `matplotlib` plots, image previews (`viu`, `chafa`), and rich TUI frameworks.

**What to build:**

- [ ] **Kitty graphics protocol** — Implement the full protocol (image transmission, placement, animation). See [Kitty graphics protocol spec](https://sw.kovidgoyal.net/kitty/graphics-protocol/)
  - Transmission modes: direct (base64 payload), file path, shared memory
  - Placement: cell-anchored with row/column offsets, z-index layering
  - Animation: frame-based animation support
- [ ] **Sixel graphics** (lower priority) — Older protocol but still used by some tools. Simpler to implement than Kitty
- [ ] **Metal texture integration** — Decode incoming images to Metal textures and composite them into the cell grid during the render pass. The existing glyph atlas pipeline provides a blueprint for this
- [ ] **Memory management** — Cap total image memory (e.g. 256MB). Evict off-screen images. Handle large/streaming images gracefully

**Competitive positioning:** Brings ProSSHMac to parity with Ghostty and Kitty on modern terminal capabilities. No other SSH-focused Mac app has this.

---

## Priority 4 — iCloud Sync for Hosts, Keys & Settings

**Why:** Cross-device sync is Termius's killer feature ($10/month). Prompt 3 has Panic Sync. rootshell syncs via iCloud. Users managing dozens of servers need configurations everywhere — especially if ProSSHMac ever ships an iOS companion app.

**What to build:**

- [ ] **CloudKit sync for host configurations** — Sync host entries (hostname, port, username, auth method, tags, labels, algorithm preferences, port forwarding rules) via CloudKit private database
- [ ] **Settings sync** — Terminal appearance, font preferences, theme, keyboard shortcuts
- [ ] **Known hosts sync** — Share the known hosts database across devices
- [ ] **Snippet/Quick Commands sync** — See Priority 5
- [ ] **Pane layout sync** — Persist and restore split-pane layouts across devices
- [ ] **Key reference sync (NOT private keys)** — Sync key metadata and public keys. Private keys stay in the local Keychain/Secure Enclave. On a new device, prompt the user to import or generate the corresponding private key
- [ ] **Conflict resolution** — Last-write-wins for simple fields. Merge strategy for host lists (add-only, flag deletions)
- [ ] **Encryption at rest** — Encrypt synced data with a user-derived key before storing in CloudKit, so even Apple cannot read host configurations

**Competitive positioning:** Free iCloud sync (no subscription) undercuts Termius's $10/month. Native Apple ecosystem integration beats third-party sync solutions.

---

## Priority 5 — Command Snippets & Multi-Exec

**Why:** SecureCRT, Termius, and Prompt 3 all have saved command/snippet systems. ProSSHMac has `QuickCommands.swift` but it's basic. Power users maintain libraries of common commands per-host. Multi-exec (running a command across multiple sessions) is rare and highly valued by sysadmins.

**What to build:**

- [ ] **Searchable snippet library** — `Cmd+Shift+P` command palette to search and execute saved commands
- [ ] **Per-host and global scoping** — Snippets can be tied to a specific host, a tag group, or available globally
- [ ] **Variable interpolation** — Support `${hostname}`, `${username}`, `${date}`, `${prompt:Enter value}` (interactive prompt) in snippets
- [ ] **Folder & tag organization** — Nested folders and taggable snippets for large command libraries
- [ ] **Multi-exec** — Select multiple active sessions and broadcast a command (or snippet) to all of them simultaneously. Show output side-by-side
- [ ] **Import/export** — Import snippets from JSON/YAML. Export for sharing or backup
- [ ] **Sync via iCloud** — If Priority 4 is implemented, snippets sync automatically

**Competitive positioning:** Multi-exec across SSH sessions is a feature only SecureCRT and Royal TSX offer. No native Mac app does it well. Combined with the snippet library, this targets the power-user/sysadmin segment.

---

## Competitive Context

### What ProSSHMac has that competitors don't

| Feature | ProSSHMac | Closest Competitor |
|---------|-----------|-------------------|
| Built-in Certificate Authority | Yes | No competitor has this |
| Audit logging | Yes | SecureCRT (limited) |
| Metal GPU rendering + SSH management + SFTP | Yes (all three) | rootshell has rendering + SSH but no SFTP |
| Secure Enclave key generation | Yes | Prompt 3 (storage only, not generation) |
| Native SwiftUI + SSH + SFTP + CA | Yes | No competitor combines all four |
| Spotlight search for hosts | Yes | No competitor has this |
| Siri Shortcuts for SSH | Yes | Prompt 3 (partial) |

### What competitors have that ProSSHMac doesn't (yet)

| Feature | Who Has It | Priority Above |
|---------|-----------|----------------|
| AI command assistance | Warp, Termius, rootshell | Priority 1 |
| Inline image protocol | Ghostty, Kitty, Warp, rootshell | Priority 3 |
| Cross-device sync | Termius, Prompt 3, rootshell | Priority 4 |
| Command snippets / multi-exec | SecureCRT, Termius, Prompt 3 | Priority 5 |
| Mosh / Eternal Terminal support | Prompt 3, Termius, rootshell | Future consideration |
| Ligature rendering | Ghostty, Kitty, Warp | Future consideration |
| tmux native integration | iTerm2 | Future consideration |
| Scripting/automation API | SecureCRT (Python), iTerm2 (AppleScript) | Future consideration |
| Plugin/extension system | iTerm2, Kitty, Hyper | Future consideration |
| Cloud provider integration (AWS/K8s) | rootshell | Future consideration |
