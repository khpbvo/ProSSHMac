# RefactorTheActor.md

> **Goal:** Separate concerns, eliminate god files, and establish clean isolation boundaries
> so Swift strict concurrency (`-strict-concurrency=complete`) can be enabled incrementally.
>
> Each phase is scoped to be self-contained. Claude Code should finish one phase, verify the
> build compiles and tests pass, then commit before moving to the next. This ensures context
> compaction between phases is safe.
>
> **Branch strategy:** `git checkout -b refactor/actor-isolation` before starting Phase 0.

---

## Phase 0 — Baseline Audit & Branch Setup

> One-time prep. Do this before touching any source. Every step must complete successfully
> before moving to the next. Phase 0 ends with a single commit containing only the
> `// swiftlint:disable file_length` additions.

### Step 0.1 — Create the refactor branch

```bash
git checkout -b refactor/actor-isolation
```

- [x] Verify: `git branch --show-current` prints `refactor/actor-isolation`
- [x] All subsequent work in this refactor goes on this branch

### Step 0.2 — Run full build and capture warning count

```bash
xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build 2>&1 | tee /tmp/prossh_build.txt
grep -c ': warning:' /tmp/prossh_build.txt
```

- [x] Build must succeed (exit 0) before continuing — if it fails, fix it first and do not proceed
- [x] Note the warning count from `grep` output; you will need it in Step 0.4

### Step 0.3 — Run full test suite and capture results

```bash
xcodebuild -scheme ProSSHMac -destination 'platform=macOS' test 2>&1 | tee /tmp/prossh_test.txt
grep -E 'Test Suite.*passed|Test Suite.*failed' /tmp/prossh_test.txt | tail -5
```

- [x] Note the number of tests passed and failed from the summary lines; you will need it in Step 0.4
- [x] A failing test here is a pre-existing issue — note it but do not block Phase 0 on it

### Step 0.4 — Create WARNINGS_BASELINE.txt (scratch file, do NOT commit)

Create `WARNINGS_BASELINE.txt` at the repo root with this exact format, filling in the numbers
from Steps 0.2 and 0.3:

```
Date: 2026-02-24
Branch: refactor/actor-isolation (before any source changes)
Build warning count: 0
Test results: 861 total, 23 pre-existing failures (color rendering, mouse encoding)
Note: delete this file when Phase 8 is complete. Never commit it.
```

- [x] File created at repo root
- [x] Add `WARNINGS_BASELINE.txt` to `.gitignore` so it cannot be accidentally committed:
  ```bash
  echo 'WARNINGS_BASELINE.txt' >> .gitignore
  git add .gitignore
  ```

### Step 0.5 — Add `// swiftlint:disable file_length` to SSHTransport.swift

- [x] Open `ProSSHMac/Services/SSHTransport.swift`
- [x] Insert `// swiftlint:disable file_length` as **line 1** — before any imports or declarations
- [x] Save the file
- [x] Verify line 1 of the file is exactly `// swiftlint:disable file_length`

### Step 0.6 — Add `// swiftlint:disable file_length` to SessionManager.swift

- [x] Open `ProSSHMac/Services/SessionManager.swift`
- [x] Insert `// swiftlint:disable file_length` as **line 1** — before any imports or declarations
- [x] Save the file
- [x] Verify line 1 of the file is exactly `// swiftlint:disable file_length`

### Step 0.7 — Add `// swiftlint:disable file_length` to OpenAIAgentService.swift

- [x] Open `ProSSHMac/Services/OpenAIAgentService.swift`
- [x] Insert `// swiftlint:disable file_length` as **line 1** — before any imports or declarations
- [x] Save the file
- [x] Verify line 1 of the file is exactly `// swiftlint:disable file_length`

### Step 0.8 — Verify build still passes after the three edits

```bash
xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build
```

- [x] Build exits 0 — BUILD SUCCEEDED
- [x] This also confirms that `CLAUDE.md`'s build command is accurate (Step 0.9 is satisfied)

### Step 0.9 — Commit Phase 0

Stage only the three modified Swift files and the `.gitignore` update — do NOT stage
`WARNINGS_BASELINE.txt`:

```bash
git add ProSSHMac/Services/SSHTransport.swift ProSSHMac/Services/SessionManager.swift ProSSHMac/Services/OpenAIAgentService.swift .gitignore
git status   # confirm WARNINGS_BASELINE.txt is NOT listed as staged
git commit -m "chore: Phase 0 — add swiftlint:disable file_length to god files"
```

- [x] Commit `9913cdc` created on `refactor/actor-isolation`
- [x] `WARNINGS_BASELINE.txt` is untracked (not staged, not committed)
- [x] Phase 0 complete — proceed to expand Phase 1 in this file before writing any code

> **COMPLETED 2026-02-24** — build 0 warnings, 861 tests (23 pre-existing failures).
> God files are at: SSHTransport.swift = 1,653L, SessionManager.swift = 1,640L, OpenAIAgentService.swift = 1,946L (each +1 for the swiftlint comment).

---

## Phase 1 — Split `SSHTransport.swift` (1,653 lines → 6 focused files)

> **Before touching any code:** The actual file is at `ProSSHMac/Services/SSHTransport.swift`.
> Every new file lives under `ProSSHMac/Services/SSH/`.
> **No Xcode project edits are needed** — this project uses `PBXFileSystemSynchronizedRootGroup`
> (Xcode 15.4+ file-system sync). Any Swift file created on disk under `ProSSHMac/` is
> compiled automatically.
> Every extracted file must have `// Extracted from SSHTransport.swift` as its first
> non-blank, non-import line. Build must pass after every sub-phase before proceeding.

### Type map — what goes where (verified against source lines)

| Declaration | Source lines | Destination file |
|-------------|-------------|-----------------|
| `SSHBackendKind` enum | 4–7 | `SSHTransportTypes.swift` |
| `SSHAlgorithmClass` enum | 9–14 | `SSHTransportTypes.swift` |
| `PTYConfiguration` struct | 16–22 | `SSHTransportTypes.swift` |
| `SSHConnectionDetails` struct | 24–32 | `SSHTransportTypes.swift` |
| `SFTPDirectoryEntry` struct | 34–45 | `SSHTransportTypes.swift` |
| `SFTPTransferResult` struct | 47–50 | `SSHTransportTypes.swift` |
| `JumpHostConfig` struct | 52–55 | `SSHTransportTypes.swift` |
| `SSHTransportError` enum | 57–88 | `SSHTransportTypes.swift` |
| `SSHShellChannel` protocol | 90–95 | `SSHTransportProtocol.swift` |
| `SSHForwardChannel` protocol | 97–102 | `SSHTransportProtocol.swift` |
| `SSHTransporting` protocol | 104–114 | `SSHTransportProtocol.swift` |
| `extension SSHTransporting` (default overloads) | 116–128 | `SSHTransportProtocol.swift` |
| `SSHAlgorithmPolicy` struct | 130–149 | `SSHAlgorithmPolicy.swift` |
| `SSHTransportFactory` enum | 151–158 | `SSHTransportTypes.swift` ⚠️ update mock branch to `#if DEBUG` |
| `ActiveMockSession` struct | 160–165 | `MockSSHTransport.swift` — drop `private` |
| `MockRemoteNode` struct | 167–171 | `MockSSHTransport.swift` — drop `private` |
| `UncheckedOpaquePointer` struct | 173–175 | `SSHTransportTypes.swift` ⚠️ used by LibSSH actors — NOT in Mock file |
| `MockServerProfile` enum | 177–188 | `MockSSHTransport.swift` — drop `private` |
| `MockSSHTransport` actor | 190–494 | `MockSSHTransport.swift` |
| `MockSSHShellChannel` actor | 496–595 | `MockSSHTransport.swift` |
| `MockSSHForwardChannel` actor | 597–621 | `MockSSHTransport.swift` |
| `LibSSHConnectResult` struct | 623–626 | stays → `LibSSHTransport.swift` |
| `LibSSHConnectFailure` enum | 628–637 | stays → `LibSSHTransport.swift` |
| `LibSSHAuthenticationMaterial` struct | 639–644 | stays → `LibSSHTransport.swift` |
| `LibSSHTransport` actor | 646–1388 | stays → `LibSSHTransport.swift` (renamed in Step 1.13) |
| `LibSSHShellChannel` actor | 1390–1552 | `LibSSHShellChannel.swift` |
| `LibSSHForwardChannel` actor | 1554–1632 | `LibSSHForwardChannel.swift` |
| `private extension AuthMethod` | 1634–1647 | stays → `LibSSHTransport.swift`, remove `private` |
| `private extension Array where Element == CChar` | 1649–1653 | stays → `LibSSHTransport.swift`, remove `private` |

---

### Step 1.0 — Create the SSH/ directory on disk

```bash
mkdir -p ProSSHMac/Services/SSH
```

- [ ] Directory `ProSSHMac/Services/SSH/` exists on disk
- [ ] No `.xcodeproj` edits are needed at any point in this phase (file-system sync)

---

### Step 1.1 — Create SSHTransportTypes.swift

- [ ] Create `ProSSHMac/Services/SSH/SSHTransportTypes.swift` with this exact header:
  ```swift
  // Extracted from SSHTransport.swift
  import Foundation
  ```
- [ ] Copy then delete from source in this order:
  - [ ] `SSHBackendKind` (lines 4–7)
  - [ ] `SSHAlgorithmClass` (lines 9–14)
  - [ ] `PTYConfiguration` (lines 16–22)
  - [ ] `SSHConnectionDetails` (lines 24–32)
  - [ ] `SFTPDirectoryEntry` (lines 34–45)
  - [ ] `SFTPTransferResult` (lines 47–50)
  - [ ] `JumpHostConfig` (lines 52–55)
  - [ ] `SSHTransportError` (lines 57–88)
  - [ ] `UncheckedOpaquePointer` (lines 173–175)
  - [ ] `SSHTransportFactory` (lines 151–158) — rewrite the mock branch with `#if DEBUG`:
    ```swift
    enum SSHTransportFactory {
        static func makePreferredTransport() -> any SSHTransporting {
            #if DEBUG
            if ProcessInfo.processInfo.environment["PROSSH_FORCE_MOCK"] == "1" {
                return MockSSHTransport()
            }
            #endif
            return LibSSHTransport()
        }
    }
    ```
- [ ] All 10 declarations confirmed deleted from `SSHTransport.swift`

### Step 1.2 — Build check after SSHTransportTypes

```bash
xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build 2>&1 | tail -3
```

- [ ] `** BUILD SUCCEEDED **` — fix any errors before continuing

---

### Step 1.3 — Create SSHTransportProtocol.swift

- [ ] Create `ProSSHMac/Services/SSH/SSHTransportProtocol.swift` with this exact header:
  ```swift
  // Extracted from SSHTransport.swift
  import Foundation
  ```
- [ ] Copy then delete from source in this order:
  - [ ] `SSHShellChannel` protocol (lines 90–95)
  - [ ] `SSHForwardChannel` protocol (lines 97–102)
  - [ ] `SSHTransporting` protocol (lines 104–114)
  - [ ] `extension SSHTransporting` default overloads (lines 116–128)
- [ ] All 4 declarations confirmed deleted from `SSHTransport.swift`

### Step 1.4 — Build check after SSHTransportProtocol

```bash
xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build 2>&1 | tail -3
```

- [ ] `** BUILD SUCCEEDED **`

---

### Step 1.5 — Create SSHAlgorithmPolicy.swift

- [ ] Create `ProSSHMac/Services/SSH/SSHAlgorithmPolicy.swift` with this exact header:
  ```swift
  // Extracted from SSHTransport.swift
  import Foundation
  ```
- [ ] Copy then delete from source: `SSHAlgorithmPolicy` struct (lines 130–149)
- [ ] `SSHAlgorithmPolicy` confirmed deleted from `SSHTransport.swift`

### Step 1.6 — Build check after SSHAlgorithmPolicy

```bash
xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build 2>&1 | tail -3
```

- [ ] `** BUILD SUCCEEDED **`

---

### Step 1.7 — Create MockSSHTransport.swift + fix AppDependencies.swift

**Part A — Create the file:**
- [ ] Create `ProSSHMac/Services/SSH/MockSSHTransport.swift` with this exact structure:
  ```swift
  // Extracted from SSHTransport.swift
  import Foundation

  #if DEBUG
  // ... all mock types go here ...
  #endif
  ```
- [ ] Inside `#if DEBUG`, copy then delete from source in this order:
  - [ ] `ActiveMockSession` struct (lines 160–165) — **remove the `private` keyword**
  - [ ] `MockRemoteNode` struct (lines 167–171) — **remove the `private` keyword**
  - [ ] `MockServerProfile` enum (lines 177–188) — **remove the `private` keyword**
  - [ ] `MockSSHTransport` actor (lines 190–494)
  - [ ] `MockSSHShellChannel` actor (lines 496–595)
  - [ ] `MockSSHForwardChannel` actor (lines 597–621)
- [ ] ⚠️ Do NOT copy `UncheckedOpaquePointer` — it already lives in `SSHTransportTypes.swift`
- [ ] All 6 declarations confirmed deleted from `SSHTransport.swift`

**Part B — Fix `AppDependencies.swift` line 46:**
`AppDependencies.swift` directly references `MockSSHTransport()` without a `#if DEBUG` guard.
Now that MockSSHTransport only exists in DEBUG builds, Release builds will fail without this fix.

- [ ] Open `ProSSHMac/App/AppDependencies.swift`
- [ ] Find line 46:
  ```swift
  let transport: any SSHTransporting = runningTests ? MockSSHTransport() : SSHTransportFactory.makePreferredTransport()
  ```
- [ ] Replace with:
  ```swift
  #if DEBUG
  let transport: any SSHTransporting = runningTests ? MockSSHTransport() : SSHTransportFactory.makePreferredTransport()
  #else
  let transport: any SSHTransporting = SSHTransportFactory.makePreferredTransport()
  #endif
  ```

### Step 1.8 — Build check after MockSSHTransport

```bash
xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build 2>&1 | tail -3
```

- [ ] `** BUILD SUCCEEDED **`

---

### Step 1.9 — Create LibSSHShellChannel.swift

- [ ] Create `ProSSHMac/Services/SSH/LibSSHShellChannel.swift` with this exact header:
  ```swift
  // Extracted from SSHTransport.swift
  import Foundation
  ```
- [ ] Copy then delete from source: `LibSSHShellChannel` actor (lines 1390–1552)
  - Locate by: `nonisolated actor LibSSHShellChannel`
  - This actor uses `UncheckedOpaquePointer` (now in `SSHTransportTypes.swift`) and
    the `asString` extension (will stay in `LibSSHTransport.swift` as `internal`) —
    both visible within the module, no import needed
- [ ] `LibSSHShellChannel` confirmed deleted from `SSHTransport.swift`

### Step 1.10 — Build check after LibSSHShellChannel

```bash
xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build 2>&1 | tail -3
```

- [ ] `** BUILD SUCCEEDED **`

---

### Step 1.11 — Create LibSSHForwardChannel.swift

- [ ] Create `ProSSHMac/Services/SSH/LibSSHForwardChannel.swift` with this exact header:
  ```swift
  // Extracted from SSHTransport.swift
  import Foundation
  ```
- [ ] Copy then delete from source: `LibSSHForwardChannel` actor (lines 1554–1632)
  - Locate by: `nonisolated actor LibSSHForwardChannel`
  - Uses `UncheckedOpaquePointer` and `asString` — both visible within module
- [ ] ⚠️ Do NOT move `LibSSHConnectResult`, `LibSSHConnectFailure`, or
  `LibSSHAuthenticationMaterial` — they are private implementation details of `LibSSHTransport`
- [ ] `LibSSHForwardChannel` confirmed deleted from `SSHTransport.swift`

### Step 1.12 — Build check after LibSSHForwardChannel

```bash
xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build 2>&1 | tail -3
```

- [ ] `** BUILD SUCCEEDED **`

---

### Step 1.13 — Clean up SSHTransport.swift and rename to LibSSHTransport.swift

At this point `SSHTransport.swift` should contain only:
- `// swiftlint:disable file_length` (line 1)
- `import Foundation`
- `LibSSHConnectResult` struct (lines 623–626)
- `LibSSHConnectFailure` enum (lines 628–637)
- `LibSSHAuthenticationMaterial` struct (lines 639–644)
- `LibSSHTransport` actor (lines 646–1388)
- `private extension AuthMethod { var libsshAuthMethod }`
- `private extension Array where Element == CChar { var asString }`

Perform these edits:

- [ ] **Keep** `// swiftlint:disable file_length` on line 1 — the `LibSSHTransport` actor alone
  spans ~743 lines; the resulting file will be ~780 lines total (well above the 400-line
  removal threshold). Remove this comment only if a future phase shrinks the file below 400.
- [ ] Change `private extension AuthMethod` → `extension AuthMethod` (drop `private`
  keyword) so `LibSSHShellChannel` and `LibSSHForwardChannel` can call `.libsshAuthMethod`
- [ ] Change `private extension Array where Element == CChar` → `extension Array where Element == CChar`
  (drop `private` keyword) so `LibSSHShellChannel` and `LibSSHForwardChannel` can call `.asString`
- [ ] Rename file on disk:
  ```bash
  mv ProSSHMac/Services/SSHTransport.swift ProSSHMac/Services/SSH/LibSSHTransport.swift
  ```
- [ ] No `.xcodeproj` edits needed — file-system sync picks up the rename automatically

### Step 1.14 — Build check after rename

```bash
xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build 2>&1 | tail -3
```

- [ ] `** BUILD SUCCEEDED **`
- [ ] Confirm old file is gone:
  ```bash
  ls ProSSHMac/Services/SSHTransport.swift 2>&1   # must print: No such file or directory
  ```

---

### Step 1.15 — Verify sizes of the five small extracted files

```bash
wc -l ProSSHMac/Services/SSH/SSHTransportTypes.swift \
       ProSSHMac/Services/SSH/SSHTransportProtocol.swift \
       ProSSHMac/Services/SSH/SSHAlgorithmPolicy.swift \
       ProSSHMac/Services/SSH/LibSSHShellChannel.swift \
       ProSSHMac/Services/SSH/LibSSHForwardChannel.swift
```

- [ ] Each of the five files above is under 400 lines
- [ ] Note: `LibSSHTransport.swift` (~780L) and `MockSSHTransport.swift` (~458L) exceed 400
  lines — that is expected and correct; their `// swiftlint:disable file_length` comments
  must remain until a future phase shrinks them

---

### Step 1.16 — Run tests and commit

```bash
xcodebuild -scheme ProSSHMac -destination 'platform=macOS' test 2>&1 \
  | grep -E 'Executed [0-9]+ test|FAILED|SUCCEEDED' | tail -5
```

- [ ] Test results: 861 tests, ≤ 23 failures (same pre-existing baseline — no regressions)

```bash
git add ProSSHMac/Services/SSH/ \
        ProSSHMac/App/AppDependencies.swift \
        ProSSHMac.xcodeproj/project.pbxproj
git status   # confirm SSHTransport.swift shows as deleted/renamed, not as a new untracked file
git commit -m "refactor: Phase 1 — split SSHTransport.swift into focused files in Services/SSH/"
```

- [ ] Commit created on `refactor/actor-isolation`
- [ ] `git log --oneline -1` shows the commit on the right branch

---

### Step 1.17 — Update CLAUDE.md

- [ ] Update the "Current State" block in `CLAUDE.md`:
  - Change `Current phase` to `Phase 2 — Kill CString pyramid, inject credential resolver`
  - Change `Phase status` to `NOT PLANNED`
  - Change `Key source file` to `ProSSHMac/Services/SSH/LibSSHTransport.swift`
  - Change `Last commit` to the hash just made
- [ ] Update Phase Status table row for Phase 1 to `**COMPLETE** (2026-02-24, commit <hash>)`
- [ ] Add a Refactor Log entry in `CLAUDE.md` under "Recent Changes / Refactor Log":
  ```
  - **2026-02-24 — Phase 1 COMPLETE** (`<hash>`): Split SSHTransport.swift (1,653L) into 6 files
    under Services/SSH/. Key corrections vs. original plan: removed xcodeproj registration steps
    (project uses file-system sync); added #if DEBUG guard to AppDependencies.swift line 46;
    kept swiftlint:disable in LibSSHTransport.swift (~780L) and MockSSHTransport.swift (~458L).
  ```
- [ ] Phase 1 complete — proceed to State A for Phase 2 (expand sketch into detailed plan
  in RefactorTheActor.md before writing any code)

---

## Phase 1b — Swift 6 Strict Concurrency Pass on Phase 1 Files

> **Goal:** Every file created or renamed in Phase 1 must pass `-strict-concurrency=complete`
> with zero warnings. Fix explicit Sendable gaps identified during the Phase 1 audit.
> No behavior changes — only type annotation additions.
>
> **Rule established:** From this point forward, every new Swift file in this project must
> pass `-strict-concurrency=complete` before its creating commit.

### Step 1b.0 — Temporarily enable strict concurrency for verification

In Xcode: Target → Build Settings → Other Swift Flags → add `-strict-concurrency=complete`.

```bash
# Then build to capture baseline warnings
xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build 2>&1 | grep 'strict-concurrency\|Sendable\|warning:' | head -40
```

- [x] Record all Sendable warnings — expected warnings are listed in steps below
- [x] Do NOT fix anything yet; just confirm the warning list matches this plan

---

### Step 1b.1 — Fix Host.swift (Models)

**File:** `ProSSHMac/Models/Host.swift`

- [x] `AuthMethod`: add `Sendable` → `enum AuthMethod: String, Codable, CaseIterable, Identifiable, Sendable`
- [x] `AlgorithmPreferences`: add `Sendable` → `struct AlgorithmPreferences: Codable, Hashable, Sendable`
- [x] `PortForwardingRule`: add `Sendable` → `struct PortForwardingRule: Identifiable, Codable, Hashable, Sendable`
- [x] `Host`: add `Sendable` → `struct Host: Identifiable, Codable, Hashable, Sendable`
- [x] Build check:
  ```bash
  xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build 2>&1 | tail -3
  ```
- [x] `** BUILD SUCCEEDED **`

---

### Step 1b.2 — Fix SSHTransportTypes.swift

**File:** `ProSSHMac/Services/SSH/SSHTransportTypes.swift`

- [x] `SSHBackendKind`: add `Sendable` → `enum SSHBackendKind: String, Codable, Sendable`
- [x] `SSHTransportError`: add `Sendable` → `enum SSHTransportError: LocalizedError, Sendable`
- [x] Build check (same command as above)
- [x] `** BUILD SUCCEEDED **`

---

### Step 1b.3 — Fix SSHAlgorithmPolicy.swift

**File:** `ProSSHMac/Services/SSH/SSHAlgorithmPolicy.swift`

- [x] `SSHAlgorithmPolicy`: add `Sendable` → `struct SSHAlgorithmPolicy: Sendable`
- [x] Build check
- [x] `** BUILD SUCCEEDED **`

---

### Step 1b.4 — Fix LibSSHTransport.swift

**File:** `ProSSHMac/Services/SSH/LibSSHTransport.swift`

- [x] `LibSSHConnectResult`: add `@unchecked Sendable` with safety comment:
  ```swift
  // safe: OpaquePointer is a C session handle owned exclusively
  // by LibSSHTransport's actor-isolated `handles` dict; never shared across actors.
  nonisolated private struct LibSSHConnectResult: @unchecked Sendable {
  ```
- [x] `LibSSHConnectFailure`: add `Sendable` → `nonisolated private enum LibSSHConnectFailure: LocalizedError, Sendable`
- [x] `LibSSHAuthenticationMaterial`: add `Sendable` → `nonisolated private struct LibSSHAuthenticationMaterial: Sendable`
- [x] Build check
- [x] `** BUILD SUCCEEDED **`

---

### Step 1b.5 — Verify remaining Phase 1 files are clean

```bash
xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build 2>&1 | grep 'strict-concurrency\|Sendable\|warning:' | head -40
```

- [x] Zero new Sendable/strict-concurrency warnings in `SSHTransportProtocol.swift`
- [x] Zero new Sendable/strict-concurrency warnings in `LibSSHShellChannel.swift`
- [x] Zero new Sendable/strict-concurrency warnings in `LibSSHForwardChannel.swift`
- [x] Zero new Sendable/strict-concurrency warnings in `MockSSHTransport.swift`
- [x] Note: warnings may remain in other files outside `Services/SSH/` — those are Phase 7 scope

---

### Step 1b.6 — Remove the temporary strict concurrency flag

In Xcode: Target → Build Settings → Other Swift Flags → remove `-strict-concurrency=complete`.

```bash
xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build 2>&1 | tail -3
```

- [x] `** BUILD SUCCEEDED **` with no regressions

---

### Step 1b.7 — Run tests and commit

```bash
xcodebuild -scheme ProSSHMac -destination 'platform=macOS' test 2>&1 \
  | grep -E 'Executed [0-9]+ test|FAILED|SUCCEEDED' | tail -5
```

- [x] Test results: 861 tests, ≤ 23 failures (same pre-existing baseline — no regressions)

```bash
git add ProSSHMac/Models/Host.swift \
        ProSSHMac/Services/SSH/SSHTransportTypes.swift \
        ProSSHMac/Services/SSH/SSHAlgorithmPolicy.swift \
        ProSSHMac/Services/SSH/LibSSHTransport.swift
git commit -m "chore: Phase 1b — Swift 6 strict concurrency pass on Phase 1 files"
```

- [x] Commit created on `refactor/actor-isolation`

---

### Step 1b.8 — Update CLAUDE.md

- [x] Update "Current State" block: change `Current phase` to `Phase 2 — Kill CString pyramid, inject credential resolver`, `Phase status` to `NOT PLANNED`
- [x] Update Phase Status table: mark Phase 1b as `**COMPLETE** (2026-02-24, commit <hash>)`
- [x] Add Refactor Log entry

---

## Phase 2 — Kill the CString Pyramid & Inject Credential Resolver

> **Before touching any code:** Read `LibSSHTransport.swift` in full. The methods to be moved
> and the pyramid to flatten are all actor-isolated or nonisolated private helpers.
> Understand every call site before moving any symbol.
>
> **Two sub-phases, two commits:**
> - Phase 2a (commit 1): Extract credential-loading helpers into `DefaultSSHCredentialResolver`;
>   inject the resolver into `LibSSHTransport` via `init`.
> - Phase 2b (commit 2): Wrap the 18-level `withCString` pyramid inside
>   `LibSSHJumpCallParams.invoke`; slim `connectViaJumpHost` to ~30 lines with ≤ 3 nesting levels.

---

### Phase 2a — Credential Resolver Extraction

#### Step 2a.0 — Audit call sites and access modifiers (no file changes)

Before writing any code, confirm the call graph from the actual source:

| Method | Lines (current) | Callers | Disposition |
|--------|----------------|---------|-------------|
| `resolveAuthenticationMaterial(for:passwordOverride:keyPassphraseOverride:)` | 565–603 | `connectViaJumpHost` (104), `authenticate` (244) | **STAYS** in `LibSSHTransport`; drop `nonisolated` |
| `resolvePrivateKey(reference:)` | 605–618 | `resolveAuthenticationMaterial` | Move → `DefaultSSHCredentialResolver.privateKey(for:)` |
| `resolveCertificate(reference:)` | 620–643 | `resolveAuthenticationMaterial` | Move → `DefaultSSHCredentialResolver.certificate(for:)` |
| `loadStoredKeys()` | 645–655 | `resolvePrivateKey` | Move → private helper in `DefaultSSHCredentialResolver` |
| `loadStoredCertificates()` | 657–667 | `resolveCertificate` | Move → private helper in `DefaultSSHCredentialResolver` |
| `applicationSupportFileURL(filename:)` | 669–677 | `loadStoredKeys`, `loadStoredCertificates` | Move → private static helper in `DefaultSSHCredentialResolver` |
| `readSSHStringPrefix(from:)` | 679–699 | `resolveCertificate` | Move → private static helper in `DefaultSSHCredentialResolver` |
| `withOptionalCString(_:_:)` | 701–709 | `connectViaJumpHost` (129–132), `authenticate` (246–249) | **STAYS** — promote to file-scope `private func` |
| `extractCTupleString(_:capacity:)` | 711–717 | `connectViaJumpHost` (188) | **STAYS** as `private static` on actor |

- [ ] Audit confirmed — no other callers of the 6 methods-to-move exist in the file
- [ ] Confirm `EncryptedStorage.loadJSON` is the only external dependency in the 6 moved methods
  (no `KeyStore` or `CertificateStore` actor calls — these use raw file I/O only)

---

#### Step 2a.1 — Create `SSHCredentialResolver.swift`

- [ ] Create `ProSSHMac/Services/SSH/SSHCredentialResolver.swift` with this exact content:
  ```swift
  // Extracted from LibSSHTransport.swift
  import Foundation

  protocol SSHCredentialResolving: Sendable {
      func privateKey(for reference: UUID) throws -> String
      func certificate(for reference: UUID) throws -> String
  }
  ```
- [ ] File confirmed created on disk under `ProSSHMac/Services/SSH/`
- [ ] No additional imports needed — `UUID` is in `Foundation`

---

#### Step 2a.2 — Create `DefaultSSHCredentialResolver.swift`

- [ ] Create `ProSSHMac/Services/SSH/DefaultSSHCredentialResolver.swift` with header:
  ```swift
  // Extracted from LibSSHTransport.swift
  import Foundation
  ```
- [ ] Declare `struct DefaultSSHCredentialResolver: SSHCredentialResolving` — no stored
  properties; the struct is stateless (all data comes from the file system on demand).
  A stateless struct automatically satisfies `Sendable`.
- [ ] Move (copy then delete-from-source in Step 2a.7) the following methods, adapting
  signatures as noted:

  **`privateKey(for reference: UUID) throws -> String`** — renamed from `resolvePrivateKey(reference:)`;
  drop `nonisolated`:
  ```swift
  func privateKey(for reference: UUID) throws -> String {
      let keys = try loadStoredKeys()
      guard let storedKey = keys.first(where: { $0.id == reference }) else {
          throw SSHTransportError.transportFailure(message: "Referenced SSH private key was not found.")
      }
      let privateKey = storedKey.privateKey.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !privateKey.isEmpty else {
          throw SSHTransportError.transportFailure(
              message: "Referenced SSH key does not contain private key material."
          )
      }
      return privateKey
  }
  ```

  **`certificate(for reference: UUID) throws -> String`** — renamed from `resolveCertificate(reference:)`;
  drop `nonisolated`; replace `Self.readSSHStringPrefix` with just `Self.readSSHStringPrefix`
  (still works — `Self` now refers to `DefaultSSHCredentialResolver`):
  ```swift
  func certificate(for reference: UUID) throws -> String {
      let certificates = try loadStoredCertificates()
      guard let certificate = certificates.first(where: { $0.id == reference }) else {
          throw SSHTransportError.transportFailure(message: "Referenced SSH certificate was not found.")
      }
      if let authorized = certificate.authorizedRepresentation?.trimmingCharacters(in: .whitespacesAndNewlines),
         !authorized.isEmpty {
          return authorized
      }
      guard let keyType = Self.readSSHStringPrefix(from: certificate.rawCertificateData) else {
          throw SSHTransportError.transportFailure(
              message: "Referenced certificate is missing OpenSSH authorized representation."
          )
      }
      let base64 = certificate.rawCertificateData.base64EncodedString()
      let comment = certificate.keyId.trimmingCharacters(in: .whitespacesAndNewlines)
      if comment.isEmpty {
          return "\(keyType) \(base64)"
      }
      return "\(keyType) \(base64) \(comment)"
  }
  ```

  **Private helpers** — copy verbatim, drop `nonisolated`, keep `private` (or `private static`):
  - `private func loadStoredKeys() throws -> [StoredSSHKey]`
  - `private func loadStoredCertificates() throws -> [SSHCertificate]`
  - `private static func applicationSupportFileURL(filename: String) -> URL`
  - `private static func readSSHStringPrefix(from data: Data) -> String?`

---

#### Step 2a.3 — Build check after new files (pre-deletion)

```bash
xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build 2>&1 | tail -3
```

- [ ] `** BUILD SUCCEEDED **`
  (The 6 methods still exist in `LibSSHTransport` at this point — intentional duplication
  until Step 2a.7. Build will succeed because there are no conflicts yet.)

---

#### Step 2a.4 — Promote `withOptionalCString` to file-scope function in `LibSSHTransport.swift`

`LibSSHJumpCallParams` (added in Phase 2b) is a file-scope struct and cannot call a
`private static` method on `LibSSHTransport`. Lifting `withOptionalCString` to file scope
makes it available to both the actor and the struct within the same file.

- [ ] Open `ProSSHMac/Services/SSH/LibSSHTransport.swift`
- [ ] Find and delete the `nonisolated private static func withOptionalCString` declaration
  (lines 701–709) from inside the actor body
- [ ] Add the function at file scope, between `LibSSHAuthenticationMaterial` and
  `actor LibSSHTransport`:
  ```swift
  private func withOptionalCString<Result>(
      _ value: String?,
      _ body: (UnsafePointer<CChar>?) -> Result
  ) -> Result {
      guard let value else {
          return body(nil)
      }
      return value.withCString(body)
  }
  ```
- [ ] Update all 7 call sites in `LibSSHTransport.swift` — change `Self.withOptionalCString(...)` → `withOptionalCString(...)`:
  - [ ] `connectViaJumpHost` (4 occurrences: lines ~129–132)
  - [ ] `authenticate` (3 occurrences: lines ~246–249)

---

#### Step 2a.5 — Inject `credentialResolver` stored property and `init` into `LibSSHTransport`

- [ ] Open `ProSSHMac/Services/SSH/LibSSHTransport.swift`
- [ ] Add stored property immediately after `private var handles: [UUID: OpaquePointer] = [:]`:
  ```swift
  private let credentialResolver: any SSHCredentialResolving
  ```
- [ ] Add custom `init` immediately after the stored property:
  ```swift
  init(credentialResolver: any SSHCredentialResolving = DefaultSSHCredentialResolver()) {
      self.credentialResolver = credentialResolver
  }
  ```
  Note: The default value means `SSHTransportFactory` (`LibSSHTransport()`) needs no change.

---

#### Step 2a.6 — Drop `nonisolated` from `resolveAuthenticationMaterial`; update its call sites

After the move, `resolveAuthenticationMaterial` calls `credentialResolver.privateKey(for:)` and
`credentialResolver.certificate(for:)` — both accesses to an actor-isolated stored property —
so the method must become actor-isolated (drop `nonisolated`).

- [ ] Find line 565:
  ```swift
  nonisolated private func resolveAuthenticationMaterial(for host: Host, passwordOverride: String?, keyPassphraseOverride: String? = nil) throws -> LibSSHAuthenticationMaterial {
  ```
- [ ] Drop `nonisolated`:
  ```swift
  private func resolveAuthenticationMaterial(for host: Host, passwordOverride: String?, keyPassphraseOverride: String? = nil) throws -> LibSSHAuthenticationMaterial {
  ```
- [ ] Inside `resolveAuthenticationMaterial`, replace the two helper call sites:
  - `let privateKey = try resolvePrivateKey(reference: keyReference)` →
    `let privateKey = try credentialResolver.privateKey(for: keyReference)`
  - `let certificate = try resolveCertificate(reference: certificateReference)` →
    `let certificate = try credentialResolver.certificate(for: certificateReference)`
- [ ] Verify callers of `resolveAuthenticationMaterial` (`connectViaJumpHost`, `authenticate`)
  are both actor-isolated methods — no `await` or other change needed at call sites

---

#### Step 2a.7 — Delete the 6 moved methods from `LibSSHTransport.swift`

- [ ] Delete `resolvePrivateKey(reference:)` (lines 605–618)
- [ ] Delete `resolveCertificate(reference:)` (lines 620–643)
- [ ] Delete `loadStoredKeys()` (lines 645–655)
- [ ] Delete `loadStoredCertificates()` (lines 657–667)
- [ ] Delete `applicationSupportFileURL(filename:)` (lines 669–677)
- [ ] Delete `readSSHStringPrefix(from:)` (lines 679–699)
- [ ] Search `LibSSHTransport.swift` for each deleted name — zero remaining references expected:
  `resolvePrivateKey`, `resolveCertificate`, `loadStoredKeys`, `loadStoredCertificates`,
  `applicationSupportFileURL`, `readSSHStringPrefix`

---

#### Step 2a.8 — Build check after LibSSHTransport edits

```bash
xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build 2>&1 | tail -3
```

- [ ] `** BUILD SUCCEEDED **`
- [ ] If `cannot find` errors appear for `EncryptedStorage`, `StoredSSHKey`, or `SSHCertificate`
  in `DefaultSSHCredentialResolver.swift`: these symbols are module-wide (same target);
  no import is needed — check for a typo or missing file registration.

---

#### Step 2a.9 — Run tests and commit Phase 2a

```bash
xcodebuild -scheme ProSSHMac -destination 'platform=macOS' test 2>&1 \
  | grep -E 'Executed [0-9]+ test|FAILED|SUCCEEDED' | tail -5
```

- [ ] Test results: ≤ 23 failures (same pre-existing baseline — no regressions)

```bash
git add ProSSHMac/Services/SSH/SSHCredentialResolver.swift \
        ProSSHMac/Services/SSH/DefaultSSHCredentialResolver.swift \
        ProSSHMac/Services/SSH/LibSSHTransport.swift
git commit -m "refactor: inject SSHCredentialResolving into LibSSHTransport"
```

- [ ] Commit created on `refactor/actor-isolation`

---

### Phase 2b — Flatten the Jump Host CString Pyramid

#### Step 2b.0 — Locate the pyramid (no file changes)

- [ ] Open `ProSSHMac/Services/SSH/LibSSHTransport.swift`
- [ ] Find `connectViaJumpHost` (~line 98). The `let connectResult: Int32 = jumpHost.hostname.withCString { ...`
  block (lines 122–184 in the original; will have shifted after Phase 2a edits) has
  **18 levels of nesting** and is the target.
- [ ] Note the error-handling block and post-connect block after the pyramid — those stay in
  `connectViaJumpHost` and are not moved into the struct.

---

#### Step 2b.1 — Add `LibSSHTargetParams` struct to `LibSSHTransport.swift`

- [ ] In `ProSSHMac/Services/SSH/LibSSHTransport.swift`, add `LibSSHTargetParams` as a
  file-scope `private struct`, between the `withOptionalCString` function and `actor LibSSHTransport`:

  ```swift
  private struct LibSSHTargetParams: Sendable {
      let hostname: String
      let port: UInt16
      let username: String
      let kex: String
      let ciphers: String
      let hostKeys: String
      let macs: String

      init(host: Host, policy: SSHAlgorithmPolicy) {
          hostname = host.hostname
          port = host.port
          username = host.username
          let selectedHostKeys = host.pinnedHostKeyAlgorithms.isEmpty
              ? policy.hostKeys : host.pinnedHostKeyAlgorithms
          kex = policy.keyExchange.joined(separator: ",")
          ciphers = policy.ciphers.joined(separator: ",")
          hostKeys = selectedHostKeys.joined(separator: ",")
          macs = policy.macs.joined(separator: ",")
      }
  }
  ```

  Note: No `nonisolated` keyword — this is a file-scope struct, not an actor member.

---

#### Step 2b.2 — Add `LibSSHJumpCallParams` struct with `invoke` to `LibSSHTransport.swift`

- [ ] Immediately after `LibSSHTargetParams`, add:

  ```swift
  private struct LibSSHJumpCallParams: Sendable {
      let jumpHostname: String
      let jumpPort: UInt16
      let jumpUsername: String
      let jumpKex: String
      let jumpCiphers: String
      let jumpHostKeys: String
      let jumpMacs: String
      let expectedFingerprint: String
      let jumpAuthMethod: ProSSHAuthMethod
      let jumpPassword: String?
      let jumpPrivateKey: String?
      let jumpCertificate: String?
      let jumpKeyPassphrase: String?

      init(jumpHost: Host, policy: SSHAlgorithmPolicy,
           material: LibSSHAuthenticationMaterial, expectedFingerprint: String) {
          jumpHostname = jumpHost.hostname
          jumpPort = jumpHost.port
          jumpUsername = jumpHost.username
          jumpKex = policy.keyExchange.joined(separator: ",")
          jumpCiphers = policy.ciphers.joined(separator: ",")
          jumpHostKeys = policy.hostKeys.joined(separator: ",")
          jumpMacs = policy.macs.joined(separator: ",")
          self.expectedFingerprint = expectedFingerprint
          jumpAuthMethod = jumpHost.authMethod.libsshAuthMethod
          jumpPassword = material.password
          jumpPrivateKey = material.privateKey
          jumpCertificate = material.certificate
          jumpKeyPassphrase = material.keyPassphrase
      }

      func invoke(handle: OpaquePointer, target: LibSSHTargetParams,
                  config: inout ProSSHJumpHostConfig,
                  errorBuffer: inout [CChar]) -> Int32 {
          return jumpHostname.withCString { jumpHostnamePtr in
              jumpUsername.withCString { jumpUsernamePtr in
                  jumpKex.withCString { jumpKexPtr in
                      jumpCiphers.withCString { jumpCiphersPtr in
                          jumpHostKeys.withCString { jumpHostKeysPtr in
                              jumpMacs.withCString { jumpMacsPtr in
                                  expectedFingerprint.withCString { fpPtr in
                                      withOptionalCString(jumpPassword) { pwPtr in
                                          withOptionalCString(jumpPrivateKey) { pkPtr in
                                              withOptionalCString(jumpCertificate) { certPtr in
                                                  withOptionalCString(jumpKeyPassphrase) { ppPtr in
                                                      target.hostname.withCString { hostnamePtr in
                                                          target.username.withCString { usernamePtr in
                                                              target.kex.withCString { kexPtr in
                                                                  target.ciphers.withCString { ciphersPtr in
                                                                      target.hostKeys.withCString { hostKeysPtr in
                                                                          target.macs.withCString { macsPtr in
                                                                              config.jump_hostname = jumpHostnamePtr
                                                                              config.jump_username = jumpUsernamePtr
                                                                              config.jump_port = jumpPort
                                                                              config.kex = jumpKexPtr
                                                                              config.ciphers = jumpCiphersPtr
                                                                              config.hostkeys = jumpHostKeysPtr
                                                                              config.macs = jumpMacsPtr
                                                                              config.timeout_seconds = 10
                                                                              config.expected_fingerprint = fpPtr
                                                                              config.auth_method = jumpAuthMethod
                                                                              config.password = pwPtr
                                                                              config.private_key = pkPtr
                                                                              config.certificate = certPtr
                                                                              config.key_passphrase = ppPtr
                                                                              return prossh_libssh_connect_with_jump(
                                                                                  handle,
                                                                                  hostnamePtr,
                                                                                  target.port,
                                                                                  usernamePtr,
                                                                                  kexPtr,
                                                                                  ciphersPtr,
                                                                                  hostKeysPtr,
                                                                                  macsPtr,
                                                                                  10,
                                                                                  &config,
                                                                                  &errorBuffer,
                                                                                  Int32(errorBuffer.count)
                                                                              )
                                                                          }
                                                                      }
                                                                  }
                                                              }
                                                          }
                                                      }
                                                  }
                                              }
                                          }
                                      }
                                  }
                              }
                          }
                      }
                  }
              }
          }
      }
  }
  ```

  Key notes:
  - `withOptionalCString` is the file-scope function promoted in Step 2a.4 — callable without prefix
  - `errorBuffer.count` cast to `Int32` matches the C function signature
  - `config` is `inout` — the method mutates the caller's `ProSSHJumpHostConfig` in place
  - `ProSSHAuthMethod` is a C enum visible to Swift via `CLibSSH/` — no import needed

---

#### Step 2b.3 — Refactor `connectViaJumpHost` to use the two structs

- [ ] Replace the entire body of `connectViaJumpHost` with the following ~35-line implementation:

  ```swift
  private func connectViaJumpHost(sessionID: UUID, host: Host, jumpConfig: JumpHostConfig) throws -> SSHConnectionDetails {
      guard let handle = prossh_libssh_create() else {
          throw SSHTransportError.transportFailure(message: "Failed to allocate libssh session handle.")
      }

      let jumpHost = jumpConfig.host
      let jumpMaterial = try resolveAuthenticationMaterial(for: jumpHost, passwordOverride: nil)
      let jumpPolicy: SSHAlgorithmPolicy = jumpHost.legacyModeEnabled ? .legacy : .modern
      let targetPolicy: SSHAlgorithmPolicy = host.legacyModeEnabled ? .legacy : .modern

      let jumpParams = LibSSHJumpCallParams(
          jumpHost: jumpHost,
          policy: jumpPolicy,
          material: jumpMaterial,
          expectedFingerprint: jumpConfig.expectedFingerprint
      )
      let targetParams = LibSSHTargetParams(host: host, policy: targetPolicy)

      var errorBuffer = [CChar](repeating: 0, count: 512)
      var jumpCConfig = ProSSHJumpHostConfig()
      let connectResult = jumpParams.invoke(
          handle: handle,
          target: targetParams,
          config: &jumpCConfig,
          errorBuffer: &errorBuffer
      )

      if connectResult != 0 {
          let errorMessage = errorBuffer.asString
          let actualFP = Self.extractCTupleString(&jumpCConfig.actual_fingerprint, capacity: 256)
          prossh_libssh_destroy(handle)
          switch connectResult {
          case -10, -11:
              throw SSHTransportError.jumpHostVerificationFailed(
                  jumpHostname: jumpHost.hostname,
                  actualFingerprint: actualFP
              )
          case -12:
              throw SSHTransportError.jumpHostAuthenticationFailed(jumpHostname: jumpHost.hostname)
          default:
              throw SSHTransportError.jumpHostConnectionFailed(
                  jumpHostname: jumpHost.hostname,
                  message: errorMessage.isEmpty ? "Connection via jump host failed." : errorMessage
              )
          }
      }

      handles[sessionID] = handle

      var kexBuffer = [CChar](repeating: 0, count: 128)
      var cipherBuffer = [CChar](repeating: 0, count: 128)
      var hostKeyBuffer = [CChar](repeating: 0, count: 128)
      var fingerprintBuffer = [CChar](repeating: 0, count: 256)
      _ = prossh_libssh_get_negotiated(
          handle,
          &kexBuffer, kexBuffer.count,
          &cipherBuffer, cipherBuffer.count,
          &hostKeyBuffer, hostKeyBuffer.count,
          &fingerprintBuffer, fingerprintBuffer.count
      )

      let usedLegacy = host.legacyModeEnabled
      return SSHConnectionDetails(
          negotiatedKEX: kexBuffer.asString,
          negotiatedCipher: cipherBuffer.asString,
          negotiatedHostKeyType: hostKeyBuffer.asString,
          negotiatedHostFingerprint: fingerprintBuffer.asString,
          usedLegacyAlgorithms: usedLegacy,
          securityAdvisory: usedLegacy ? "This session uses legacy cryptography for compatibility with older infrastructure." : nil,
          backend: .libssh
      )
  }
  ```

  Key changes vs. original:
  - Cases `-10` and `-11` are merged into a single `case -10, -11:` branch (both had identical bodies)
  - All 18 levels of `withCString` nesting are gone from the call site
  - The intermediate local `let` bindings (`jumpKex`, `targetKex`, etc.) are eliminated —
    they are now computed inside `LibSSHTargetParams.init` and `LibSSHJumpCallParams.init`

---

#### Step 2b.4 — Build check after pyramid flattening

```bash
xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build 2>&1 | tail -3
```

- [ ] `** BUILD SUCCEEDED **`
- [ ] Confirm `connectViaJumpHost` body nesting depth is ≤ 3 levels at the call site
  (the pyramid is now entirely hidden inside `LibSSHJumpCallParams.invoke`)

---

#### Step 2b.5 — Run tests and commit Phase 2b

```bash
xcodebuild -scheme ProSSHMac -destination 'platform=macOS' test 2>&1 \
  | grep -E 'Executed [0-9]+ test|FAILED|SUCCEEDED' | tail -5
```

- [ ] Test results: ≤ 23 failures (same pre-existing baseline — no regressions)

```bash
git add ProSSHMac/Services/SSH/LibSSHTransport.swift
git commit -m "refactor: flatten jump host CString pyramid into LibSSHJumpCallParams"
```

- [ ] Commit created on `refactor/actor-isolation`

---

#### Step 2b.6 — Update CLAUDE.md

- [ ] Update "Current State" block in `CLAUDE.md`:
  - `Current phase`: `Phase 3 — Deduplicate remote path utilities → RemotePath.swift`
  - `Phase status`: `NOT PLANNED`
  - `Last commit`: hash of the Phase 2b commit
- [ ] Update Phase Status table: mark Phase 2 as `**COMPLETE** (2026-02-24, commit <2b-hash>)`
- [ ] Add Refactor Log entry under "Recent Changes / Refactor Log":
  ```
  - **2026-02-24 — Phase 2 COMPLETE**: 2 commits.
    Phase 2a: extracted 6 credential-loading methods from LibSSHTransport into
    DefaultSSHCredentialResolver; added SSHCredentialResolving protocol; injected via init with
    default value (SSHTransportFactory unchanged); promoted withOptionalCString to file-scope.
    Phase 2b: wrapped 18-level withCString nesting in LibSSHJumpCallParams.invoke +
    LibSSHTargetParams; connectViaJumpHost reduced to ~35 lines with ≤ 3 nesting levels.
    Build: SUCCEEDED. Tests: ≤ 23 failures (pre-existing baseline).
  ```
- [ ] Phase 2 complete — proceed to State A for Phase 3 (expand sketch before touching code)

---

## Phase 3 — Deduplicate Remote Path Utilities

> **Context note for Claude Code:** `normalizeRemotePath`, `parentRemotePath`, `joinRemotePath`
> are copy-pasted between `MockSSHTransport` and `LibSSHTransport`. Extract once, use everywhere.
>
> **Out of scope:** `TransferManager.swift` has its own copies with different logic (`..` resolution,
> different return type for parent). Leave it untouched.

### Step 3.0 — Write detailed plan into RefactorTheActor.md (no code changes)
- [x] Expand sketch into numbered steps; commit `docs: expand Phase 3 plan in RefactorTheActor.md`

### Step 3.1 — Create `RemotePath.swift`

- [ ] Create `ProSSHMac/Services/SSH/RemotePath.swift` with exact content:

```swift
// Extracted from LibSSHTransport.swift
import Foundation

enum RemotePath {
    nonisolated static func normalize(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "/"
        }
        var parts = trimmed.split(separator: "/").map(String.init)
        parts.removeAll(where: { $0.isEmpty || $0 == "." })
        let normalized = "/" + parts.joined(separator: "/")
        if normalized.count > 1 && normalized.hasSuffix("/") {
            return String(normalized.dropLast())
        }
        return normalized
    }

    nonisolated static func parent(of path: String) -> String? {
        let normalized = normalize(path)
        guard normalized != "/" else {
            return nil
        }
        guard let slash = normalized.lastIndex(of: "/") else {
            return "/"
        }
        if slash == normalized.startIndex {
            return "/"
        }
        return String(normalized[..<slash])
    }

    nonisolated static func join(_ base: String, _ name: String) -> String {
        let normalizedBase = normalize(base)
        if normalizedBase == "/" {
            return "/\(name)"
        }
        return "\(normalizedBase)/\(name)"
    }
}
```

Notes:
- All three methods marked `nonisolated` (Swift 6 can infer `@MainActor` on enum static methods)
- Header comment `// Extracted from LibSSHTransport.swift` (normalizeRemotePath originated there)
- Internal calls use unqualified `normalize(...)` (same enum, resolves correctly)

### Step 3.2 — Build check (pre-deletion)

- [ ] Run: `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build 2>&1 | tail -3`
- [ ] Must show: `** BUILD SUCCEEDED **`

### Step 3.3 — Update call sites in `LibSSHTransport.swift` (4 sites)

- [ ] `listDirectory`: `Self.normalizeRemotePath(path)` → `RemotePath.normalize(path)`
- [ ] `uploadFile`: `Self.normalizeRemotePath(remotePath)` → `RemotePath.normalize(remotePath)`
- [ ] `downloadFile`: `Self.normalizeRemotePath(remotePath)` → `RemotePath.normalize(remotePath)`
- [ ] `parseSFTPListing`: `normalizeRemotePath(basePath)` → `RemotePath.normalize(basePath)`

### Step 3.4 — Delete `normalizeRemotePath` from `LibSSHTransport.swift`

- [ ] Delete the `nonisolated private static func normalizeRemotePath` method (~14 lines)
- [ ] Verify zero remaining references to `normalizeRemotePath` in `LibSSHTransport.swift`

### Step 3.5 — Update call sites in `MockSSHTransport.swift` (7 sites)

- [ ] `listDirectory` ~line 101: `Self.normalizeRemotePath(path)` → `RemotePath.normalize(path)`
- [ ] `listDirectory` ~line 118: `Self.joinRemotePath(...)` → `RemotePath.join(...)`
- [ ] `uploadFile` ~line 162: `Self.normalizeRemotePath(...)` → `RemotePath.normalize(...)`
- [ ] `uploadFile` ~line 166: `Self.joinRemotePath(...)` → `RemotePath.join(...)`
- [ ] `downloadFile` ~line 193: `Self.normalizeRemotePath(...)` → `RemotePath.normalize(...)`
- [ ] `ensureParentDirectoriesExist` ~line 292: `Self.parentRemotePath(of: ...)` → `RemotePath.parent(of: ...)`
- [ ] `ensureParentDirectoriesExist` ~line 297: `Self.parentRemotePath(of: ...)` → `RemotePath.parent(of: ...)`

### Step 3.6 — Delete 3 duplicate methods from `MockSSHTransport.swift`

- [ ] Delete `nonisolated private static func normalizeRemotePath` (~14 lines)
- [ ] Delete `nonisolated private static func parentRemotePath` (~12 lines)
- [ ] Delete `nonisolated private static func joinRemotePath` (~7 lines)
- [ ] Verify zero remaining references to all three method names in `MockSSHTransport.swift`

### Step 3.7 — Build check after deletions

- [ ] Run: `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build 2>&1 | tail -3`
- [ ] Must show: `** BUILD SUCCEEDED **`

### Step 3.8 — Run tests and commit

- [ ] Run: `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' test 2>&1 | grep -E 'Executed [0-9]+ test|FAILED|SUCCEEDED' | tail -5`
- [ ] Failures must be ≤ 23 (pre-existing baseline)
- [ ] `git add ProSSHMac/Services/SSH/RemotePath.swift ProSSHMac/Services/SSH/LibSSHTransport.swift ProSSHMac/Services/SSH/MockSSHTransport.swift`
- [ ] `git commit -m "refactor: extract RemotePath utilities, remove duplication"`

### Step 3.9 — Update CLAUDE.md

- [ ] "Current State" block: phase → Phase 4, status → NOT PLANNED, last commit → new hash
- [ ] Phase Status table: Phase 3 → COMPLETE (2026-02-24, commit <hash>)
- [ ] Refactor Log entry: mention `nonisolated` requirement, TransferManager left untouched
- [ ] `git commit -m "docs: mark Phase 3 complete in CLAUDE.md"`

---

## Phase 4 — Generic `PersistentStore<T>` for the Store Boilerplate

> **Sketch corrections vs. original:** `@MainActor final class` (not `actor`) to stay compatible
> with all four `@MainActor` domain protocols without bridging. No `upsert`/`delete` — no call
> site uses per-item operations (bulk array load/save only). No `Identifiable` constraint needed.
> `AuditLogStore` (NSLock + append + maxEntries) and `KnownHostsStore` (actor, complex trust API)
> are NOT fits — left untouched. Keychain-backed stores (`BiometricPasswordStore`,
> `OpenAIAPIKeyStore`) also left alone.

### Step 4.1 — Create `Services/PersistentStore.swift`

- [ ] Create `ProSSHMac/Services/PersistentStore.swift` with:
  - `@MainActor final class PersistentStore<T: Codable>`
  - `init(filename: String, fileManager: FileManager = .default)` — builds fileURL from
    `.applicationSupportDirectory/ProSSHV2/<filename>`, fallback to `.temporaryDirectory`
  - `func load() async throws -> [T]` — guard fileExists, JSONDecoder/.iso8601, EncryptedStorage.loadJSON
  - `func save(_ items: [T]) async throws` — JSONEncoder/.prettyPrinted/.sortedKeys/.iso8601, EncryptedStorage.saveJSON
  - Four conditional conformance extensions:
    - `extension PersistentStore: HostStoreProtocol where T == Host`
    - `extension PersistentStore: KeyStoreProtocol where T == StoredSSHKey`
    - `extension PersistentStore: CertificateStoreProtocol where T == SSHCertificate`
    - `extension PersistentStore: CertificateAuthorityStoreProtocol where T == CertificateAuthorityModel`

### Step 4.2 — Build check (new file coexists with originals)

```bash
xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build 2>&1 | tail -3
# Must show: ** BUILD SUCCEEDED **
```

- [ ] BUILD SUCCEEDED

### Step 4.3 — Delete `FileHostStore` from `HostStore.swift`

- [ ] Delete `@MainActor final class FileHostStore` block (lines 10–57)
- [ ] File shrinks from 57L to ~8L (just `HostStoreProtocol`)
- [ ] No remaining references to `FileHostStore` in the file

### Step 4.4 — Delete `FileKeyStore` from `KeyStore.swift`

- [ ] Delete `@MainActor final class FileKeyStore` block (lines 21–66)
- [ ] File shrinks from 66L to ~18L (`StoredSSHKey` struct + `KeyStoreProtocol`)
- [ ] Keep `StoredSSHKey` struct untouched

### Step 4.5 — Delete `FileCertificateStore` from `CertificateStore.swift`

- [ ] Delete `@MainActor final class FileCertificateStore` block (lines 10–55)
- [ ] File shrinks from 55L to ~8L (just `CertificateStoreProtocol`)

### Step 4.6 — Delete `FileCertificateAuthorityStore` from `CertificateAuthorityStore.swift`

- [ ] Delete `@MainActor final class FileCertificateAuthorityStore` block (lines 10–55)
- [ ] File shrinks from 55L to ~8L (just `CertificateAuthorityStoreProtocol`)

### Step 4.7 — Update `AppDependencies.swift` (4 instantiation sites)

- [ ] Line ~69: `FileHostStore()` → `PersistentStore<Host>(filename: "hosts.json")`
- [ ] Line ~89: `FileKeyStore()` → `PersistentStore<StoredSSHKey>(filename: "keys.json")`
- [ ] Line ~97: `FileCertificateStore()` → `PersistentStore<SSHCertificate>(filename: "certificates.json")`
- [ ] Line ~96: `FileCertificateAuthorityStore()` → `PersistentStore<CertificateAuthorityModel>(filename: "certificate_authorities.json")`
- [ ] `ScreenshotHostStore` and `ScreenshotKeyStore` — untouched

### Step 4.8 — Build check after all deletions

```bash
xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build 2>&1 | tail -3
# Must show: ** BUILD SUCCEEDED **
```

- [ ] BUILD SUCCEEDED

### Step 4.9 — Run tests and commit

```bash
xcodebuild -scheme ProSSHMac -destination 'platform=macOS' test 2>&1 \
  | grep -E 'Executed [0-9]+ test|FAILED|SUCCEEDED' | tail -5
# Failures must be ≤ 23 (pre-existing baseline)
```

```bash
git add ProSSHMac/Services/PersistentStore.swift \
        ProSSHMac/Services/HostStore.swift \
        ProSSHMac/Services/KeyStore.swift \
        ProSSHMac/Services/CertificateStore.swift \
        ProSSHMac/Services/CertificateAuthorityStore.swift \
        ProSSHMac/App/AppDependencies.swift
git commit -m "refactor: introduce PersistentStore<T>, consolidate store boilerplate"
```

- [ ] Tests ≤ 23 failures
- [ ] Committed

### Step 4.10 — Update CLAUDE.md

- [ ] "Current State" block: phase → Phase 5, status → NOT PLANNED
- [ ] Phase Status table: Phase 4 → COMPLETE (2026-02-24, commit `<hash>`)
- [ ] Refactor Log entry added
- [ ] Commit: `docs: mark Phase 4 complete in CLAUDE.md`

---

## Phase 5 — Decompose `SessionManager.swift` (67KB → 5 focused types)

> **This is the biggest phase. Context compaction is likely between sub-phases.**
> **Each sub-phase is a safe commit point.**
>
> `SessionManager` currently owns: connection lifecycle, terminal rendering pipeline,
> PTY resize debouncing, keepalive, auto-reconnect w/ network monitoring, session recording,
> scrollback navigation, command history, and screenshot injection.
> These need separate homes.
>
> **Architecture:** Each coordinator is `@MainActor final class`, owned (strong) by SessionManager,
> and holds `weak var manager: SessionManager?`. `@Published` properties stay on SessionManager
> (SwiftUI observes via `@EnvironmentObject`); coordinators write via `manager?.prop = value`.
> Private state used ONLY by a coordinator moves into that coordinator.
> State also used by SessionManager stays on SessionManager but with visibility widened
> from `private` to `internal` so coordinators can read it via `manager.prop`.

---

### Sub-Phase 5a — Extract `SessionReconnectCoordinator` (~55 lines extracted)

**New file:** `ProSSHMac/Services/SessionReconnectCoordinator.swift`
**Header (first non-blank, non-import line):** `// Extracted from SessionManager.swift`

#### Step 5a.1 — Read SessionManager.swift reconnect section (lines 56–61, 122–134, 252–262, 487–530, 1127–1185, 1239–1242, 1548–1598)
- [ ] Confirm: properties `pendingReconnectHosts` (line 56), `reconnectTask` (line 57),
      `networkMonitor` (line 59), `networkMonitorQueue` (line 60), `isNetworkReachable` (line 61)
- [ ] Confirm: methods `handleNetworkStatusChange` (line 1548), `scheduleReconnectAttempt` (line 1557),
      `attemptPendingReconnects` (line 1577)
- [ ] Confirm: coordinator also needs to see `manager.hostBySessionID`, `manager.jumpHostBySessionID`,
      `manager.manuallyDisconnectingSessions` (read in `handleShellStreamEnded` and `disconnect`)

#### Step 5a.2 — Create `SessionReconnectCoordinator.swift`
- [ ] Create file at `ProSSHMac/Services/SessionReconnectCoordinator.swift`
- [ ] First non-blank, non-import line: `// Extracted from SessionManager.swift`
- [ ] Declare `@MainActor final class SessionReconnectCoordinator`
- [ ] Properties:
  - `weak var manager: SessionManager?`
  - `var pendingReconnectHosts: [UUID: (host: Host, jumpHost: Host?)] = [:]`
  - `var reconnectTask: Task<Void, Never>?`
  - `nonisolated let networkMonitor: NWPathMonitor`  ← `nonisolated let` so deinit can cancel it
  - `nonisolated let networkMonitorQueue: DispatchQueue`
  - `var isNetworkReachable: Bool = true`
- [ ] `init(manager: SessionManager)` — sets all properties; does NOT start monitor yet
- [ ] `nonisolated deinit { networkMonitor.cancel() }`
      (reconnectTask terminates naturally via [weak self]; NWPathMonitor needs explicit cancel)
- [ ] `func start()` — sets `networkMonitor.pathUpdateHandler` then calls `networkMonitor.start(queue:)`
- [ ] `func stop()` — calls `reconnectTask?.cancel(); reconnectTask = nil`
- [ ] `func applicationDidEnterBackground()` — iterates `manager.sessions` to populate
      `pendingReconnectHosts` with connected SSH sessions
- [ ] `func applicationDidBecomeActive()` — calls `scheduleReconnectAttempt(after: .milliseconds(0))`
- [ ] `func cancelPending(sessionID: UUID)` — `pendingReconnectHosts.removeValue(forKey: sessionID)`
- [ ] `func removePendingForHost(_ hostID: UUID)` — removes all entries where `entry.host.id == hostID`
- [ ] `func scheduleReconnect(for sessionID: UUID, host: Host?, jumpHost: Host?)` — stores in
      `pendingReconnectHosts` if host non-nil, then calls `scheduleReconnectAttempt(after: .seconds(1))`
- [ ] `private func handleNetworkStatusChange(isReachable: Bool)` — moved verbatim
- [ ] `private func scheduleReconnectAttempt(after delay: Duration)` — moved verbatim,
      but calls `manager?.reconnectConnect(host:jumpHost:)` indirectly via `attemptPendingReconnects`
- [ ] `private func attemptPendingReconnects()` — moved verbatim, uses
      `manager?.activeSession(for:)` and `manager?.reconnectConnect(host:jumpHost:)`
- [ ] File must pass `-strict-concurrency=complete` — verify `nonisolated let` annotations
      on networkMonitor and networkMonitorQueue allow deinit access

#### Step 5a.3 — Widen visibility in SessionManager.swift
- [ ] `private var hostBySessionID` → `var hostBySessionID` (remove `private`)
- [ ] `private var jumpHostBySessionID` → `var jumpHostBySessionID`
- [ ] `private var manuallyDisconnectingSessions` → `var manuallyDisconnectingSessions`

#### Step 5a.4 — Add coordinator + helper to SessionManager.swift
- [ ] Add `let reconnectCoordinator: SessionReconnectCoordinator` (after existing `let` declarations)
- [ ] In `init()`: remove the `networkMonitor.pathUpdateHandler = ...` block (lines 122–127);
      add at end of init:
      ```swift
      reconnectCoordinator = SessionReconnectCoordinator(manager: self)
      reconnectCoordinator.start()
      ```
- [ ] In `deinit`: remove `networkMonitor.cancel()` and `reconnectTask?.cancel()` lines
- [ ] Add `nonisolated deinit {}` (empty body prevents actor-isolated deallocation crash in XCTest)
      — NOTE: if SessionManager already has a `deinit`, rename to `nonisolated deinit` and keep
      `keepaliveTask?.cancel()` inside until Phase 5b removes it
- [ ] Add internal helper method:
      ```swift
      func reconnectConnect(host: Host, jumpHost: Host?) async throws -> Session {
          try await connect(to: host, jumpHost: jumpHost, automaticReconnect: true, passwordOverride: nil)
      }
      ```

#### Step 5a.5 — Update SessionManager call sites
- [ ] `applicationDidEnterBackground()` (line ~252): replace body with
      `reconnectCoordinator.applicationDidEnterBackground()`
- [ ] `applicationDidBecomeActive()` (line ~260): replace body with
      `reconnectCoordinator.applicationDidBecomeActive()`
- [ ] `connect()` private method (line ~371): replace
      `for (key, entry) in pendingReconnectHosts where entry.host.id == host.id { ... }` with
      `reconnectCoordinator.removePendingForHost(host.id)`
- [ ] `disconnect()` (line ~497): replace `pendingReconnectHosts.removeValue(forKey: sessionID)` with
      `reconnectCoordinator.cancelPending(sessionID: sessionID)`
- [ ] `removeSession()` (line ~1239): replace `pendingReconnectHosts.removeValue(forKey: sessionID)` with
      `reconnectCoordinator.cancelPending(sessionID: sessionID)`
- [ ] `handleShellStreamEnded()` (line ~1162): capture host BEFORE cleanup:
      `let jumpHost = jumpHostBySessionID[sessionID]`; remove the
      `if let host { pendingReconnectHosts[sessionID] = ... }` block;
      replace `scheduleReconnectAttempt(after: .seconds(1))` at end with
      `reconnectCoordinator.scheduleReconnect(for: sessionID, host: host, jumpHost: jumpHost)`
- [ ] Delete private properties from SessionManager: `pendingReconnectHosts`, `reconnectTask`,
      `networkMonitor`, `networkMonitorQueue`, `isNetworkReachable` (they now live on coordinator)
- [ ] Delete private methods from SessionManager: `handleNetworkStatusChange(isReachable:)`,
      `scheduleReconnectAttempt(after:)`, `attemptPendingReconnects()`

#### Step 5a.6 — Build check
```bash
xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build
# Must print: ** BUILD SUCCEEDED **
```
- [ ] BUILD SUCCEEDED

#### Step 5a.7 — Commit
- [ ] Commit: `refactor: extract SessionReconnectCoordinator from SessionManager`

---

### Sub-Phase 5b — Extract `SessionKeepaliveCoordinator` (~45 lines extracted)

**New file:** `ProSSHMac/Services/SessionKeepaliveCoordinator.swift`
**Header:** `// Extracted from SessionManager.swift`

#### Step 5b.1 — Read SessionManager.swift keepalive section (lines 71, 87–98, 1430–1464)
- [ ] Confirm: `keepaliveTask` (line 71), `keepaliveEnabled` computed (line 91),
      `keepaliveInterval` computed (line 95)
- [ ] Confirm: methods `startKeepaliveTimerIfNeeded` (line 1432),
      `stopKeepaliveTimerIfIdle` (line 1443), `sendKeepalives` (line 1451)
- [ ] Note: `sendKeepalives` reads `manager.sessions`, `manager.lastActivityBySessionID`,
      `manager.transport` — these stay on SessionManager, coordinator accesses via manager ref

#### Step 5b.2 — Create `SessionKeepaliveCoordinator.swift`
- [ ] Create file at `ProSSHMac/Services/SessionKeepaliveCoordinator.swift`
- [ ] First non-blank, non-import line: `// Extracted from SessionManager.swift`
- [ ] Declare `@MainActor final class SessionKeepaliveCoordinator`
- [ ] Properties:
  - `weak var manager: SessionManager?`
  - `var keepaliveTask: Task<Void, Never>?`
- [ ] Computed properties (read UserDefaults via manager pattern or directly):
  - `private var keepaliveEnabled: Bool { UserDefaults.standard.bool(forKey: "ssh.keepalive.enabled") }`
  - `private var keepaliveInterval: TimeInterval { let s = UserDefaults.standard.integer(forKey: "ssh.keepalive.interval"); return s > 0 ? TimeInterval(s) : 30 }`
- [ ] `init(manager: SessionManager)`
- [ ] `nonisolated deinit {}` (keepaliveTask uses [weak self], terminates naturally)
- [ ] `func startIfNeeded()` — moved from `startKeepaliveTimerIfNeeded`; references `manager` for
      the keepalive task body
- [ ] `func stopIfIdle()` — moved from `stopKeepaliveTimerIfIdle`; reads `manager?.sessions`
- [ ] `private func sendKeepalives() async` — moved from `sendKeepalives`; accesses
      `manager?.sessions`, `manager?.lastActivityBySessionID`, `manager?.transport`
- [ ] `func handleShellStreamEnded(sessionID: UUID)` — calls `stopIfIdle()`
      (convenience wrapper called from SessionManager)
- [ ] File must pass `-strict-concurrency=complete`

#### Step 5b.3 — Widen visibility in SessionManager.swift
- [ ] `private let transport` → `let transport` (remove `private`; coordinator reads it)
- [ ] `private var shellChannels` → `var shellChannels` (coordinator may read for connected check)
- [ ] `private(set) var lastActivityBySessionID` → `var lastActivityBySessionID`
      (coordinator reads it; TerminalView may also read — keep internal with full read/write)

#### Step 5b.4 — Add coordinator to SessionManager.swift + remove keepalive state
- [ ] Add `let keepaliveCoordinator: SessionKeepaliveCoordinator`
- [ ] In `init()`: at end, after reconnectCoordinator setup, add:
      `keepaliveCoordinator = SessionKeepaliveCoordinator(manager: self)`
- [ ] In `nonisolated deinit`: remove `keepaliveTask?.cancel()` (if still present from 5a)
- [ ] Delete private property `keepaliveTask` from SessionManager
- [ ] Delete computed properties `keepaliveEnabled` and `keepaliveInterval` from SessionManager
- [ ] Delete methods `startKeepaliveTimerIfNeeded()`, `stopKeepaliveTimerIfIdle()`,
      `sendKeepalives()` from SessionManager

#### Step 5b.5 — Update SessionManager call sites
- [ ] After `try await openShell(for: session)` in `connect()` (line ~413):
      replace `startKeepaliveTimerIfNeeded()` with `keepaliveCoordinator.startIfNeeded()`
- [ ] In `disconnect()` (line ~521): replace `stopKeepaliveTimerIfIdle()` with
      `keepaliveCoordinator.stopIfIdle()`
- [ ] In `handleShellStreamEnded()` (line ~1158): replace `stopKeepaliveTimerIfIdle()` with
      `keepaliveCoordinator.stopIfIdle()`

#### Step 5b.6 — Build check
```bash
xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build
# Must print: ** BUILD SUCCEEDED **
```
- [ ] BUILD SUCCEEDED

#### Step 5b.7 — Commit
- [ ] Commit: `refactor: extract SessionKeepaliveCoordinator from SessionManager`

---

### Sub-Phase 5c — Extract `TerminalRenderingCoordinator` (~420 lines extracted — largest)

**New file:** `ProSSHMac/Services/TerminalRenderingCoordinator.swift`
**Header:** `// Extracted from SessionManager.swift`

#### Step 5c.1 — Read SessionManager.swift rendering section
- [ ] Confirm private properties moving to coordinator:
  - `gridSnapshotsBySessionID` (line 29) — private cache, NOT @Published
  - `pendingSnapshotPublishTasksBySessionID` (line 66)
  - `scrollOffsetBySessionID` (line 68)
  - `lastShellBufferPublishAtBySessionID` (line 70)
  - `lastBellTimeBySessionID` (line 64)
  - `pendingResizeTasks` (line 62)
  - `desiredPTYBySessionID` (line 52)
  - `shellBufferPublishInterval` (line 73)
  - `throughputShellBufferPublishInterval` (line 74)
  - `snapshotPublishInterval` (line 75)
  - `throughputSnapshotPublishInterval` (line 76)
  - `perfSignpostLog` (lines 77–79, DEBUG only)
  - `throughputModeEnabled` computed (line 87)
  - `configuredScrollbackLines` computed (line 100)
- [ ] Confirm `@Published` properties that STAY on SessionManager (coordinator writes via manager ref):
  `gridSnapshotNonceBySessionID`, `shellBuffers`, `bellEventNonceBySessionID`,
  `inputModeSnapshotsBySessionID`, `windowTitleBySessionID`, `workingDirectoryBySessionID`
  — drop `private(set)` from all so coordinator can write
- [ ] Confirm methods moving to coordinator:
  lines 627–712 (resizeTerminal, clearShellBuffer, scrollTerminal, scrollToBottom,
  isScrolledBack, gridSnapshot), lines 1100–1125 (publishSyncExitSnapshot,
  scheduleParsedChunkPublish), lines 1187–1222 (appendShellLine, applyPlaybackStep),
  lines 1303–1428 (shouldPublishShellBuffer, scheduleCoalescedGridPublish,
  flushPendingSnapshotPublishIfNeeded, cancelPendingSnapshotPublish, publishGridState)

#### Step 5c.2 — Create `TerminalRenderingCoordinator.swift`
- [ ] Create file at `ProSSHMac/Services/TerminalRenderingCoordinator.swift`
- [ ] First non-blank, non-import line: `// Extracted from SessionManager.swift`
- [ ] Declare `@MainActor final class TerminalRenderingCoordinator`
- [ ] Move all properties listed in 5c.1 into coordinator
- [ ] `init(manager: SessionManager)`
- [ ] `nonisolated deinit {}` (tasks use [weak self])
- [ ] `func initializePTY(for sessionID: UUID)` — sets `desiredPTYBySessionID[sessionID] = .default`
- [ ] `func cleanupSession(_ sessionID: UUID)` — cancels pending tasks and removes all dicts for session
- [ ] Move all rendering methods listed in 5c.1 into coordinator; replace direct SessionManager
      property accesses with `manager?.prop` for `@Published` state, and local `self.prop` for
      coordinator-owned private state
- [ ] Update `publishGridState` to write `manager?.gridSnapshotNonceBySessionID`,
      `manager?.shellBuffers`, `manager?.bellEventNonceBySessionID`, etc.
- [ ] `appendShellLine` and `applyPlaybackStep` both access `engines` (stays on coordinator)
      and write `manager?.gridSnapshotNonceBySessionID` etc.
- [ ] File must pass `-strict-concurrency=complete`

#### Step 5c.3 — Widen visibility in SessionManager.swift
- [ ] `private var engines` → `var engines` (coordinator needs it; also used in startParserReader)
- [ ] `private let terminalHistoryIndex` → `let terminalHistoryIndex`
- [ ] Drop `private(set)` from: `shellBuffers`, `gridSnapshotNonceBySessionID`,
      `bellEventNonceBySessionID`, `inputModeSnapshotsBySessionID`, `windowTitleBySessionID`,
      `workingDirectoryBySessionID` — they stay `@Published` but coordinator can write them

#### Step 5c.4 — Add coordinator to SessionManager.swift + remove rendering state
- [ ] Add `let renderingCoordinator: TerminalRenderingCoordinator`
- [ ] In `init()`: at end, add `renderingCoordinator = TerminalRenderingCoordinator(manager: self)`
- [ ] In `openLocalSession()` (line ~177): replace `desiredPTYBySessionID[sessionID] = .default` and
      direct snapshot/grid/shellBuffer assignments with `renderingCoordinator.initializePTY(for: sessionID)`
      (keep the @Published initializations like `gridSnapshotNonceBySessionID[sessionID] = 0` etc.
      where they are for now — the coordinator's `initializePTY` only sets desiredPTYBySessionID)
- [ ] In `connect()` private method: same — replace `desiredPTYBySessionID[sessionID] = .default` with
      `renderingCoordinator.initializePTY(for: sessionID)`
- [ ] In `removeSessionArtifacts()`: add `renderingCoordinator.cleanupSession(sessionID)` and
      remove the lines that clear coordinator-owned dicts
- [ ] In `injectScreenshotSessions()` (line ~1615): replace
      `desiredPTYBySessionID[session.id] = .default` with `renderingCoordinator.initializePTY(for: session.id)`
- [ ] In `startParserReader()`: replace calls:
      `scheduleParsedChunkPublish(...)` → `renderingCoordinator.scheduleParsedChunkPublish(...)`
      `publishSyncExitSnapshot(...)` → `renderingCoordinator.publishSyncExitSnapshot(...)`
      `flushPendingSnapshotPublishIfNeeded(...)` → `renderingCoordinator.flushPendingSnapshotPublishIfNeeded(...)`
      `publishGridState(...)` → `renderingCoordinator.publishGridState(...)`
- [ ] Add public forwarding wrappers to SessionManager (keep public API unchanged for TerminalView):
      `func resizeTerminal(sessionID:columns:rows:)` → `await renderingCoordinator.resizeTerminal(...)`
      `func scrollTerminal(sessionID:delta:)` → `renderingCoordinator.scrollTerminal(...)`
      `func scrollToBottom(sessionID:)` → `renderingCoordinator.scrollToBottom(...)`
      `func isScrolledBack(sessionID:) -> Bool` → `renderingCoordinator.isScrolledBack(...)`
      `func gridSnapshot(for:) -> GridSnapshot?` → `renderingCoordinator.gridSnapshot(for:)`
      `func clearShellBuffer(sessionID:)` → `renderingCoordinator.clearShellBuffer(...)`
- [ ] In `appendShellLine(_:to:)` callers: update to `await renderingCoordinator.appendShellLine(_:to:)`
- [ ] In `applyPlaybackStep(_:to:)` in recording coordinator (Phase 5d): update to use
      `manager?.renderingCoordinator.applyPlaybackStep(_:to:)`
- [ ] Delete coordinator-owned private properties and methods from SessionManager

#### Step 5c.5 — Build check
```bash
xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build
# Must print: ** BUILD SUCCEEDED **
```
- [ ] BUILD SUCCEEDED

#### Step 5c.6 — Commit
- [ ] Commit: `refactor: extract TerminalRenderingCoordinator from SessionManager`

---

### Sub-Phase 5d — Extract `SessionRecordingCoordinator` (~85 lines extracted)

**New file:** `ProSSHMac/Services/SessionRecordingCoordinator.swift`
**Header:** `// Extracted from SessionManager.swift`

#### Step 5d.1 — Read SessionManager.swift recording section (lines 47, 714–778, 1081–1098, 1252–1266)
- [ ] Confirm: `sessionRecorder: SessionRecorder` (line 47) moves into coordinator
- [ ] Confirm `@Published` properties STAYING on SessionManager (drop `private(set)`):
      `isRecordingBySessionID`, `hasRecordingBySessionID`, `isPlaybackRunningBySessionID`,
      `latestRecordingURLBySessionID`
- [ ] Confirm methods: `toggleRecording`, `startRecording`, `stopRecording`, `playLastRecording`,
      `exportLastRecordingAsCast`, `finalizeRecordingIfNeeded`, `applyPlaybackStep`
- [ ] Note: `recordParsedChunk` (line 1081) stays on SessionManager but its recording step
      (`sessionRecorder.isRecording(...)` + `sessionRecorder.recordOutputData(...)`) is extracted
      to `recordingCoordinator.recordIfActive(sessionID:chunk:throughputMode:)`

#### Step 5d.2 — Create `SessionRecordingCoordinator.swift`
- [ ] Create file at `ProSSHMac/Services/SessionRecordingCoordinator.swift`
- [ ] First non-blank, non-import line: `// Extracted from SessionManager.swift`
- [ ] Declare `@MainActor final class SessionRecordingCoordinator`
- [ ] Properties:
  - `weak var manager: SessionManager?`
  - `let sessionRecorder: SessionRecorder`
- [ ] `init(manager: SessionManager, recorder: SessionRecorder = SessionRecorder())`
- [ ] `nonisolated deinit {}`
- [ ] Move all recording methods into coordinator; write `@Published` state via `manager?.prop = value`
- [ ] `func recordIfActive(sessionID: UUID, chunk: Data, throughputMode: Bool)` — replaces the
      recording block in `recordParsedChunk`; uses `sessionRecorder.isRecording(...)` and
      `sessionRecorder.recordOutputData(...)`
- [ ] In `playLastRecording`, call `manager?.renderingCoordinator.clearShellBuffer(sessionID:)` for
      the clear-screen step and `manager?.renderingCoordinator.appendShellLine(_:to:)` for messages
- [ ] `applyPlaybackStep(_:to:)` calls `manager?.renderingCoordinator.applyPlaybackStep(_:to:)`
- [ ] File must pass `-strict-concurrency=complete`

#### Step 5d.3 — Widen visibility in SessionManager.swift
- [ ] Drop `private(set)` from: `isRecordingBySessionID`, `hasRecordingBySessionID`,
      `isPlaybackRunningBySessionID`, `latestRecordingURLBySessionID`

#### Step 5d.4 — Add coordinator to SessionManager.swift + remove recording state
- [ ] Add `let recordingCoordinator: SessionRecordingCoordinator`
- [ ] In `init()`: change `self.sessionRecorder = sessionRecorder` to pass it into coordinator:
      `recordingCoordinator = SessionRecordingCoordinator(manager: self, recorder: sessionRecorder)`
      (or create recorder internally in coordinator and remove it from SessionManager's init params)
- [ ] Remove `private let sessionRecorder: SessionRecorder` declaration
- [ ] Add public forwarding wrappers:
      `func toggleRecording(sessionID:)` → `await recordingCoordinator.toggleRecording(...)`
      `func startRecording(sessionID:)` → `await recordingCoordinator.startRecording(...)`
      `func stopRecording(sessionID:)` → `await recordingCoordinator.stopRecording(...)`
      `func playLastRecording(sessionID:speed:)` → `await recordingCoordinator.playLastRecording(...)`
      `func exportLastRecordingAsCast(sessionID:columns:rows:)` → `await recordingCoordinator.exportLastRecordingAsCast(...)`
- [ ] In `disconnect()` (line ~511): replace `finalizeRecordingIfNeeded(sessionID: sessionID)` with
      `recordingCoordinator.finalizeRecordingIfNeeded(sessionID: sessionID)`
- [ ] In `removeSession()` (line ~1243): same replacement
- [ ] In `handleShellStreamEnded()` (line ~1149, 1181): same replacement
- [ ] In `recordParsedChunk()` (line ~1081): replace the `sessionRecorder.isRecording(...)` block with
      `recordingCoordinator.recordIfActive(sessionID: sessionID, chunk: chunk, throughputMode: throughputModeEnabled)`
      — NOTE: `throughputModeEnabled` computed is still on SessionManager (rendering coordinator also uses it)
      — actually `throughputModeEnabled` moved to TerminalRenderingCoordinator in 5c;
        call `renderingCoordinator.throughputModeEnabled` or keep a copy as internal computed on SessionManager
- [ ] In `sendShellInput` (line ~581) and `sendRawShellInput` (line ~607) and
      `executeCommandAndWait` (line ~855): replace `sessionRecorder.recordInput(...)` with
      `recordingCoordinator.sessionRecorder.recordInput(...)` or add a forwarding method
- [ ] Delete `finalizeRecordingIfNeeded`, `applyPlaybackStep` from SessionManager
- [ ] Delete private methods that moved to coordinator

#### Step 5d.5 — Build check
```bash
xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build
# Must print: ** BUILD SUCCEEDED **
```
- [ ] BUILD SUCCEEDED

#### Step 5d.6 — Commit
- [ ] Commit: `refactor: extract SessionRecordingCoordinator from SessionManager`

---

### Sub-Phase 5e — SessionManager Slim-Down

#### Step 5e.1 — Verify no dangling declarations
- [ ] Scan SessionManager.swift for any private property declarations that should have been removed
      in 5a–5d (grep for `pendingReconnectHosts`, `reconnectTask`, `networkMonitor`,
      `networkMonitorQueue`, `isNetworkReachable`, `keepaliveTask`, `desiredPTYBySessionID`,
      `gridSnapshotsBySessionID`, `pendingSnapshotPublishTasksBySessionID`, `scrollOffsetBySessionID`,
      `lastShellBufferPublishAtBySessionID`, `lastBellTimeBySessionID`, `pendingResizeTasks`,
      `sessionRecorder` as private let)
- [ ] Verify all four coordinators are properly initialized in `init()`
- [ ] Verify `nonisolated deinit {}` is present

#### Step 5e.2 — Count lines
```bash
wc -l ProSSHMac/Services/SessionManager.swift
```
- [ ] Record line count. Target: < 300 lines.
- [ ] If line count < 400: remove `// swiftlint:disable file_length` from line 1

#### Step 5e.3 — Run full test suite
```bash
xcodebuild -scheme ProSSHMac -destination 'platform=macOS' test 2>&1 | grep -E 'Test Suite.*passed|Test Suite.*failed|error:'
```
- [ ] Expected: 186 tests, ≤ 2 pre-existing failures (emoji rendering)

#### Step 5e.4 — Update CLAUDE.md
- [ ] Phase 5 → **COMPLETE** in phase status table with commit hash
- [ ] Update "Current State" block: current phase = Phase 6, status = NOT PLANNED
- [ ] Add Refactor Log entry dated 2026-02-24

#### Step 5e.5 — Update docs/featurelist.md
- [ ] Add dated loop-log entry for Phase 5

#### Step 5e.6 — Commit
- [ ] Commit: `refactor: SessionManager slim-down, inject coordinators`

---

## Phase 6 — Decompose `OpenAIAgentService.swift` (1,946 lines → 4 new files + thin orchestrator)

> **Correction vs. original sketch:** The original sketch listed `AIResponseStreamParser.swift`
> as one of the four new files. Exploration confirmed there is **no** SSE/streaming parsing in
> `OpenAIAgentService.swift` — that lives in `OpenAIResponsesService.swift` (unchanged).
> The correct fourth file is `AIToolDefinitions.swift` (caseless enum namespace for the developer
> prompt, `buildToolDefinitions`, and static utility helpers).
>
> **Architecture:** Same coordinator pattern as Phase 5. Each new class is `@MainActor final class`,
> owned (strong) by `OpenAIAgentService`, holding a `weak var service: OpenAIAgentService?`
> back-reference where needed. `AIToolDefinitions` is a caseless `enum` (prevents Swift 6's
> `@MainActor` inference on `nonisolated` statics). `Services/AI/` uses
> `PBXFileSystemSynchronizedRootGroup` — no `.xcodeproj` edits needed.
>
> **Sub-phases must run in order:** 6.1 → 6.2 → 6.3 → 6.4 → 6.5 → 6.6 → 6.7.
> Build must succeed after every sub-phase before proceeding.

---

### Sub-Phase 6.0 — Create Services/AI/ directory

- [x] `mkdir -p ProSSHMac/Services/AI`
- [x] Directory exists on disk; no `.xcodeproj` edits needed

---

### Sub-Phase 6.1 — Extract AIToolDefinitions.swift (~295 lines)

**New file:** `ProSSHMac/Services/AI/AIToolDefinitions.swift`
Header (first non-blank, non-import line): `// Extracted from OpenAIAgentService.swift`

#### Symbols extracted from `OpenAIAgentService` class body:

| Symbol | Original visibility | Lines (approx.) |
|--------|---------------------|-----------------|
| `developerPrompt()` | `private static func` | 1627–1671 |
| `buildToolDefinitions()` | `private static func` | 1714–1945 |
| `directActionToolDefinitions(from:)` | `private nonisolated static func` | 1697–1706 |
| `isDirectActionPrompt(_:)` | `private nonisolated static func` | 1708–1712 |
| `jsonString(from:)` | `private static func` | 1673–1681 |
| `shortTraceID()` | `private nonisolated static func` | 1683–1685 |
| `shortSessionID(_:)` | `private nonisolated static func` | 1687–1689 |
| `elapsedMillis(since:)` | `private nonisolated static func` | 1691–1695 |
| `isPreviousResponseIDError(message:)` | `private static func` | 1515–1519 |

All go into `enum AIToolDefinitions { ... }` (caseless enum — all statics implicitly
`nonisolated`, Swift 6 cannot infer `@MainActor` on caseless enum statics).

#### Changes in `OpenAIAgentService.swift`:

- [x] Remove all 9 static functions listed above from the class body
- [x] `self.toolDefinitions = Self.buildToolDefinitions()` in `init` →
      `self.toolDefinitions = AIToolDefinitions.buildToolDefinitions()`
- [x] All `Self.shortTraceID()` call sites → `AIToolDefinitions.shortTraceID()`
- [x] All `Self.shortSessionID(_:)` call sites → `AIToolDefinitions.shortSessionID(_:)`
- [x] All `Self.elapsedMillis(since:)` call sites → `AIToolDefinitions.elapsedMillis(since:)`
- [x] All `Self.isDirectActionPrompt(_:)` call sites → `AIToolDefinitions.isDirectActionPrompt(_:)`
- [x] All `Self.directActionToolDefinitions(from:)` call sites →
      `AIToolDefinitions.directActionToolDefinitions(from:)`
- [x] All `Self.developerPrompt()` call sites → `AIToolDefinitions.developerPrompt()`
- [x] All `Self.jsonString(from:)` call sites → `AIToolDefinitions.jsonString(from:)`
- [x] All `Self.isPreviousResponseIDError(message:)` call sites →
      `AIToolDefinitions.isPreviousResponseIDError(message:)`

**Build check:**
```bash
xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build
# Must output: ** BUILD SUCCEEDED **
```

**Commit:** `refactor: extract AIToolDefinitions from OpenAIAgentService`

---

### Sub-Phase 6.2 — Extract AIConversationContext.swift (~35 lines)

**New file:** `ProSSHMac/Services/AI/AIConversationContext.swift`
Header: `// Extracted from OpenAIAgentService.swift`

#### Symbol extracted:

| Symbol | Original | Lines |
|--------|----------|-------|
| `previousResponseIDBySessionID: [UUID: String]` | `private var` stored property | 78 |

#### Implementation:

```swift
// Extracted from OpenAIAgentService.swift
import Foundation

@MainActor final class AIConversationContext {
    private(set) var previousResponseIDBySessionID: [UUID: String] = [:]

    init() {}
    nonisolated deinit {}

    func responseID(for sessionID: UUID) -> String? {
        previousResponseIDBySessionID[sessionID]
    }

    func update(responseID: String?, for sessionID: UUID) {
        previousResponseIDBySessionID[sessionID] = responseID
    }

    func clear(sessionID: UUID) {
        previousResponseIDBySessionID.removeValue(forKey: sessionID)
    }
}
```

#### Changes in `OpenAIAgentService.swift`:

- [x] Remove `private var previousResponseIDBySessionID: [UUID: String] = [:]`
- [x] Add `let conversationContext = AIConversationContext()` as stored property
- [x] `clearConversation(sessionID:)` body →
      `conversationContext.clear(sessionID: sessionID)`
- [x] Read sites `previousResponseIDBySessionID[sessionID]` →
      `conversationContext.responseID(for: sessionID)`
- [x] Write sites `previousResponseIDBySessionID[sessionID] = response.id` →
      `conversationContext.update(responseID: response.id, for: sessionID)`
- [x] Nil-write sites `previousResponseIDBySessionID.removeValue(forKey: sessionID)` →
      `conversationContext.clear(sessionID: sessionID)`

**Build check:** `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build`

**Commit:** `refactor: extract AIConversationContext from OpenAIAgentService`

---

### Sub-Phase 6.3 — Extract AIToolHandler.swift (~1,080 lines — largest)

**New file:** `ProSSHMac/Services/AI/AIToolHandler.swift`
Header: `// Extracted from OpenAIAgentService.swift`

#### Symbols extracted:

**Instance state:**
- `iso8601Formatter: ISO8601DateFormatter` — moves into `AIToolHandler.init()`

**Instance methods (become methods on AIToolHandler, access service via `weak var service`):**
- `executeToolCalls(sessionID:toolCalls:traceID:) async -> [OpenAIResponsesToolOutput]` (~lines 264–301)
- `executeSingleToolCall(sessionID:toolCall:) async throws -> String` (giant switch, ~lines 303–672)
- `searchFilesystemEntriesRemote(sessionID:path:namePattern:maxResults:) async -> OpenAIJSONValue` (~777–811)
- `searchFileContentsRemote(sessionID:path:textPattern:maxResults:) async -> OpenAIJSONValue` (~813–847)
- `readRemoteFileChunk(sessionID:path:startLine:lineCount:) async -> OpenAIJSONValue` (~849–885)
- `executeRemoteToolCommand(sessionID:commandBody:timeoutSeconds:) async -> RemoteToolExecutionResult` (~887–928)

**Private type (moves into AIToolHandler file):**
- `RemoteToolExecutionResult` struct (~771–775)

**Static helpers (stay as statics on AIToolHandler — used only by tool execution):**
- `decodeArguments(toolName:rawArguments:) throws -> [String: OpenAIJSONValue]` (~674–696)
- `requiredString(key:in:toolName:) throws -> String` (~698–720)
- `requiredInt(key:in:toolName:) throws -> Int` (~722–748)
- `optionalInt(key:in:) -> Int?` (~750–765)
- `clamp(_:min:max:) -> Int` (~767–769)
- `commandBlockSummary(_:) -> OpenAIJSONValue` (~1505–1513)
- `parseReadFileChunkOutput(_:path:startLine:lineCount:source:) -> OpenAIJSONValue` (~1521–1560)
- `readBoundViolationMessage(for:) -> String?` (~1562–1594)
- `firstCapturedInt(in:pattern:) -> Int?` (~1596–1607)
- `firstCapturedRange(in:pattern:) -> (Int, Int)?` (~1609–1625)
- `parseRemoteWrappedCommandOutput(_:marker:) -> (String, Int?)` (~930–953)
- `parseRemoteFilesystemSearchOutput(_:path:namePattern:maxResults:)` (~955–997)
- `parseRemoteFileContentSearchOutput(_:path:textPattern:maxResults:)` (~999–1042)
- `remotePathNotFoundToken: String` static let (~1044)
- `remoteNotRegularFileToken: String` static let (~1045)
- `remoteContentLineRegex: NSRegularExpression` static let (~1046)
- `parseRemoteFilesystemResultLine(_:) -> (path:isDirectory:)?` (~1048–1074)
- `remoteOutputPreview(_:maxCharacters:) -> String` (~1076–1080)
- `parseRemoteContentMatchLine(_:) -> (path:lineNumber:line:)?` (~1082–1103)
- `buildRemoteFilesystemSearchCommand(path:namePattern:maxResults:) -> String` (~1105–1129)
- `buildRemoteFileContentSearchCommand(path:textPattern:maxResults:) -> String` (~1131–1151)
- `buildRemoteReadFileChunkCommand(path:startLine:endLine:) -> String` (~1153–1166)
- `shellSingleQuoted(_:) -> String` (~1168–1171)

**Nonisolated static methods (keep `nonisolated static`):**
- `searchFilesystemEntries(path:namePattern:maxResults:workingDirectory:) async throws -> OpenAIJSONValue` (~1173–1246)
- `searchFileContents(path:textPattern:maxResults:workingDirectory:) async throws -> OpenAIJSONValue` (~1248–1328)
- `readLocalFileChunk(path:startLine:lineCount:workingDirectory:) async throws -> OpenAIJSONValue` (~1330–1408)
- `resolvedLocalSearchURL(path:workingDirectory:) throws -> URL` (~1410–1428)
- `filenameMatches(_:pattern:) -> Bool` (~1430–1437)
- `groupMatchesByFile(_:) -> [OpenAIJSONValue]` (~1439–1463)
- `contentMatchesForFile(fileURL:textPattern:maxRemaining:maxFileBytes:) -> [OpenAIJSONValue]?` (~1465–1503)

#### Access visibility changes on `OpenAIAgentService`:

The following `private` properties must become `internal` (remove `private`) so
`AIToolHandler` and `AIAgentRunner` can access them through the `service` weak reference:
- `responsesService` → `let` (internal)
- `sessionProvider` → `let` (internal)
- `requestTimeoutSeconds` → `let` (internal)
- `maxToolIterations` → `let` (internal)
- `persistConversationContext` → `let` (internal)

#### Changes in `OpenAIAgentService.swift`:

- [x] Remove `iso8601Formatter`, all moved instance methods, all moved statics from class body
- [x] Add `let toolHandler: AIToolHandler` stored property (initialized in `init`)
- [x] In `init`: `toolHandler = AIToolHandler(); toolHandler.service = self` (after all stored
      properties initialized)
- [x] In `executeToolCalls` call site in `generateReply`:
      `await executeToolCalls(...)` → `await toolHandler.executeToolCalls(...)`
- [x] Change `private let responsesService`, `private let sessionProvider`,
      `private let requestTimeoutSeconds`, `private let maxToolIterations`,
      `private let persistConversationContext` → remove `private`

**Build check:** `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build`

**Commit:** `refactor: extract AIToolHandler from OpenAIAgentService`

---

### Sub-Phase 6.4 — Extract AIAgentRunner.swift (~160 lines)

**New file:** `ProSSHMac/Services/AI/AIAgentRunner.swift`
Header: `// Extracted from OpenAIAgentService.swift`

#### Symbols extracted:

- `generateReply(sessionID:prompt:) async throws -> OpenAIAgentReply` body
  → `run(sessionID:prompt:) async throws -> OpenAIAgentReply`
- `createResponseWithRecovery(request:previousResponseID:traceID:) async throws -> OpenAIResponsesResponse`
- `runWithTimeout<T: Sendable>(operation:) async throws -> T`

#### Implementation sketch:

```swift
// Extracted from OpenAIAgentService.swift
import Foundation
import os.log

@MainActor final class AIAgentRunner {
    private static let logger = Logger(subsystem: "com.prossh", category: "AICopilot.AgentRunner")
    weak var service: OpenAIAgentService?

    init() {}
    nonisolated deinit {}

    func run(sessionID: UUID, prompt: String) async throws -> OpenAIAgentReply { ... }

    private func createResponseWithRecovery(
        request: OpenAIResponsesRequest,
        previousResponseID: inout String?,
        traceID: String
    ) async throws -> OpenAIResponsesResponse { ... }

    private func runWithTimeout<T: Sendable>(
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T { ... }
}
```

Inside `run(...)`, replace all `self.*` references:
- `sessionProvider.sessions` → `service?.sessionProvider.sessions ?? []`
- `Self.shortTraceID()` → `AIToolDefinitions.shortTraceID()`
- `Self.shortSessionID(_:)` → `AIToolDefinitions.shortSessionID(_:)`
- `Self.isDirectActionPrompt(_:)` → `AIToolDefinitions.isDirectActionPrompt(_:)`
- `Self.directActionToolDefinitions(from:)` → `AIToolDefinitions.directActionToolDefinitions(from:)`
- `toolDefinitions` → `service?.toolDefinitions ?? []`
- `maxToolIterations` → `service?.maxToolIterations ?? 50`
- `persistConversationContext` → `service?.persistConversationContext ?? true`
- `previousResponseIDBySessionID[sessionID]` → `service?.conversationContext.responseID(for: sessionID)`
- `Self.developerPrompt()` → `AIToolDefinitions.developerPrompt()`
- `createResponseWithRecovery(...)` → `self.createResponseWithRecovery(...)`
- `Self.elapsedMillis(since:)` → `AIToolDefinitions.elapsedMillis(since:)`
- `previousResponseIDBySessionID[sessionID] = response.id` → `service?.conversationContext.update(responseID: response.id, for: sessionID)`
- `previousResponseIDBySessionID.removeValue(forKey: sessionID)` → `service?.conversationContext.clear(sessionID: sessionID)`
- `await executeToolCalls(...)` → `await (service?.toolHandler.executeToolCalls(...)) ?? []`
- `Self.logger.*` → `Self.logger.*` (AIAgentRunner has its own logger)

Inside `createResponseWithRecovery(...)`:
- `responsesService` → `service?.responsesService` (guard-unwrap at top)
- `Self.isPreviousResponseIDError(message:)` → `AIToolDefinitions.isPreviousResponseIDError(message:)`

Inside `runWithTimeout(...)`:
- `requestTimeoutSeconds` → `service?.requestTimeoutSeconds ?? 60`

#### Changes in `OpenAIAgentService.swift`:

- [x] Remove `generateReply` body, `createResponseWithRecovery`, `runWithTimeout`
- [x] Add `let agentRunner: AIAgentRunner` stored property (initialized in `init`)
- [x] In `init`: `agentRunner = AIAgentRunner(); agentRunner.service = self`
- [x] Public `generateReply(sessionID:prompt:)` becomes a one-line delegate:
      `return try await agentRunner.run(sessionID: sessionID, prompt: prompt)`

**Build check:** `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build`

**Commit:** `refactor: extract AIAgentRunner from OpenAIAgentService`

---

### Sub-Phase 6.5 — OpenAIAgentService Slim-Down

- [x] Verify all moved symbols are deleted — no dangling declarations
- [x] Count lines: `wc -l ProSSHMac/Services/OpenAIAgentService.swift` — expect < 200 lines
- [x] Remove `// swiftlint:disable file_length` from line 1 (file is well under 400 lines)
- [x] Remaining content in `OpenAIAgentService.swift`:
  - `OpenAIAgentServicing` protocol
  - `OpenAIAgentReply` struct (add `Sendable` if missing)
  - `OpenAIAgentServiceError` enum (add `Sendable` if missing)
  - `OpenAIAgentSessionProviding` protocol
  - `CommandExecutionResult` struct
  - `extension SessionManager: OpenAIAgentSessionProviding {}`
  - `@MainActor final class OpenAIAgentService`:
    - Stored: `conversationContext`, `agentRunner`, `toolHandler`, `responsesService`,
      `sessionProvider`, `requestTimeoutSeconds`, `maxToolIterations`, `persistConversationContext`,
      `toolDefinitions`, `logger`
    - `init(responsesService:sessionProvider:requestTimeoutSeconds:maxToolIterations:persistConversationContext:)`
    - `generateReply(sessionID:prompt:)` — one-line delegate to `agentRunner.run`
    - `clearConversation(sessionID:)` — delegates to `conversationContext.clear`

**Build check:** `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build`

**Commit:** `refactor: OpenAIAgentService slim-down, inject AI coordinators (Phase 6 complete)`

---

### Sub-Phase 6.6 — Strict Concurrency Verification

For each new file in `Services/AI/`:
1. Temporarily add `-strict-concurrency=complete` to Other Swift Flags in Xcode build settings
2. Build — fix all warnings (Sendable conformances, actor isolation, nonisolated annotations)
3. Remove the flag before committing

Expected:
- `AIToolDefinitions` (caseless enum): all statics implicitly `nonisolated` — zero warnings
- `AIConversationContext`: `@MainActor` class — zero cross-isolation issues
- `AIAgentRunner`: `@MainActor` class; `service?` access is same actor — safe
- `AIToolHandler`: `nonisolated static` filesystem methods must keep `nonisolated`;
  `RemoteToolExecutionResult` needs `Sendable` conformance
- `CommandExecutionResult`, `OpenAIAgentReply`: confirm `Sendable` conformances present

---

### Sub-Phase 6.7 — Docs Update & Final Commit

- [x] Run full test suite:
  ```bash
  xcodebuild -scheme ProSSHMac -destination 'platform=macOS' test
  # Expected: ≤23 pre-existing failures (color rendering + mouse encoding)
  ```
- [x] Update `CLAUDE.md`:
  - Phase 6 → **COMPLETE** with commit hash
  - Update "Current State" block: current phase = Phase 7, status = NOT PLANNED
  - Fix target directory layout: `AIResponseStreamParser.swift` → `AIToolDefinitions.swift`
  - Add Refactor Log entry dated 2026-02-24
  - Update Key Files table: `OpenAIAgentService.swift` entry to reflect Phase 6 COMPLETE
- [x] Update `docs/featurelist.md` loop log
- [x] Commit: `docs: mark Phase 6 complete in CLAUDE.md`

---

> **PLANNED 2026-02-24** — Full numbered plan expanded from sketch.
> Correction noted: `AIResponseStreamParser.swift` replaced by `AIToolDefinitions.swift`
> (no SSE parsing lives in OpenAIAgentService.swift — it lives in OpenAIResponsesService.swift).

---

## Phase 7 — Strict Concurrency Pass

> **Status: PLANNED** — Full numbered plan below (State B). Execute each step in order.
>
> **Context:** App target already runs Swift 6 mode (`SWIFT_VERSION = 6.0`) with
> `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and produces 0 warnings with
> `-strict-concurrency=complete`. No app-source changes needed. Work is entirely in
> test target build settings + committing untracked files + cleanup.

### Step 7.0 — Write this plan into RefactorTheActor.md (State A → State B)

- [ ] Replace the Phase 7 sketch with this full numbered plan
- [ ] Commit: `docs: expand Phase 7 plan in RefactorTheActor.md`

---

### Step 7.1 — Baseline Audit (read-only)

Run and confirm each expected output before touching any file:

- [ ] **7.1a** — App target builds with 0 warnings under `-strict-concurrency=complete`:
  ```bash
  xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build \
    OTHER_SWIFT_FLAGS="-strict-concurrency=complete" 2>&1 \
    | grep -E "warning:|BUILD SUCCEEDED|BUILD FAILED"
  ```
  Expected: `** BUILD SUCCEEDED **` with no warning lines.

- [ ] **7.1b** — Confirm build settings in `project.pbxproj`:
  ```bash
  grep -n "SWIFT_VERSION\|SWIFT_STRICT_CONCURRENCY\|SWIFT_DEFAULT_ACTOR_ISOLATION" \
    ProSSHMac.xcodeproj/project.pbxproj
  ```
  Expected:
  - `SWIFT_VERSION = 6.0;` (app target, both configs)
  - `SWIFT_STRICT_CONCURRENCY = minimal;` (test target ONLY, `AB100009` + `AB10000A`)
  - `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor;` (app target ONLY, `AA00000E` + `AA00000F`)

- [ ] **7.1c** — Confirm untracked files:
  ```bash
  git status --short
  ```
  Expected:
  ```
  ?? ProSSHMac/Services/SSHConfigParser.swift
  ?? ProSSHMacTests/Terminal/Tests/SSHConfigParserTests.swift
  ```

- [ ] **7.1d** — Confirm `WARNINGS_BASELINE.txt` exists (will be deleted in 7.6):
  ```bash
  ls -la WARNINGS_BASELINE.txt
  ```
  Expected: file listed (≈276 bytes).

---

### Step 7.2 — Update Test Target Build Settings in `project.pbxproj`

**File:** `ProSSHMac.xcodeproj/project.pbxproj`

Read the file first (confirm line numbers match before editing).

- [ ] **7.2a** — In the `AB100009` block (Test target, Debug config, ~line 441):

  Change:
  ```
  SWIFT_STRICT_CONCURRENCY = minimal;
  ```
  To:
  ```
  SWIFT_STRICT_CONCURRENCY = complete;
  SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor;
  ```

- [ ] **7.2b** — In the `AB10000A` block (Test target, Release config, ~line 468):

  Change:
  ```
  SWIFT_STRICT_CONCURRENCY = minimal;
  ```
  To:
  ```
  SWIFT_STRICT_CONCURRENCY = complete;
  SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor;
  ```

  **Rationale:** `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` makes all test methods implicitly
  `@MainActor`, matching the app module's isolation model. This resolves actor isolation errors
  in `SSHConfigParserTests.swift` at the module level. `SWIFT_STRICT_CONCURRENCY = complete`
  is set for consistency (redundant in Swift 6 mode but explicit).

- [ ] **Build check:**
  ```bash
  xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build 2>&1 | tail -3
  ```
  Must output: `** BUILD SUCCEEDED **`

  If actor isolation errors persist in `SSHConfigParserTests.swift` after this change
  (e.g., `@autoclosure` arguments still rejected), proceed to Step 7.3. Otherwise skip to 7.4.

---

### Step 7.3 — Fix SSHConfigParserTests.swift (only if Step 7.2 alone is insufficient)

**Only execute if** the build after Step 7.2 still shows errors in `SSHConfigParserTests.swift`.

- [ ] Read `ProSSHMacTests/Terminal/Tests/SSHConfigParserTests.swift`, find the class declaration.
- [ ] Add `@MainActor` explicitly to the class:
  ```swift
  // Before:
  final class SSHConfigParserTests: XCTestCase {

  // After:
  @MainActor final class SSHConfigParserTests: XCTestCase {
  ```
  This explicit annotation overrides remaining `@autoclosure`-isolation ambiguity. Safe: XCTest
  fully supports `@MainActor` test classes; setUp/tearDown/test methods all run on the main actor.

- [ ] **Build check:**
  ```bash
  xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build 2>&1 | tail -3
  ```
  Must output: `** BUILD SUCCEEDED **`

---

### Step 7.4 — Commit Untracked Files + Project Settings

- [ ] Stage and commit:
  ```bash
  git add ProSSHMac.xcodeproj/project.pbxproj \
          ProSSHMac/Services/SSHConfigParser.swift \
          ProSSHMacTests/Terminal/Tests/SSHConfigParserTests.swift
  git commit -m "chore: enable SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor on test target, commit SSHConfigParser files (Phase 7)"
  ```

---

### Step 7.5 — Run Full Test Suite

- [ ] Run tests:
  ```bash
  xcodebuild -scheme ProSSHMac -destination 'platform=macOS' test 2>&1 \
    | grep -E "Test Suite.*started|Test Suite.*passed|Test Suite.*failed|\*\* TEST"
  ```
  Expected: `** TEST PASSED **` or `** TEST FAILED **` with **≤23 pre-existing failures** only
  (color rendering + mouse encoding — unrelated to concurrency).

  If new failures appear beyond the ≤23 baseline, read failure details, determine root cause,
  and fix before continuing. Do not proceed with unexpected regressions.

---

### Step 7.6 — Delete WARNINGS_BASELINE.txt

- [ ] Delete and verify:
  ```bash
  rm WARNINGS_BASELINE.txt
  git status --short | grep WARNINGS_BASELINE
  ```
  Expected: no output (file is gitignored, does not appear in `git status`).

  If the file IS NOT gitignored (appears in `git status`), add it to `.gitignore` first, then
  delete it.

---

### Step 7.7 — Update CLAUDE.md

- [ ] **Current State block** (top of Active Refactor section) — update to:
  ```
  Active branch : refactor/actor-isolation
  Current phase : Phase 8 — Test coverage backfill for all extracted types
  Phase status  : NOT PLANNED
  Immediate action: Open RefactorTheActor.md → Phase 8 → expand sketch into granular plan (State A)
  Last commit   : <Phase 7 commit hash>  "chore: mark Phase 7 complete in CLAUDE.md"
  ```

- [ ] **Phase Status table** — update Phase 7 row:
  ```
  | 7 | Strict concurrency pass (`-strict-concurrency=complete`) | **COMPLETE** (2026-02-24, commit `<hash>`) |
  ```

- [ ] **Refactor Log** — insert above Phase 6 entry (most-recent-first):
  ```
  - **2026-02-24 — Phase 7 COMPLETE** (commit `<hash>`, plan commit: `<plan-hash>`): Verified app
    target already fully strict-concurrency clean under Swift 6 + SWIFT_DEFAULT_ACTOR_ISOLATION =
    MainActor (0 warnings with -strict-concurrency=complete, no source changes). Updated test
    target (ProSSHMacTests) build configs AB100009 + AB10000A: SWIFT_STRICT_CONCURRENCY minimal →
    complete; added SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor to match app target's isolation model.
    Committed two previously-untracked files (SSHConfigParser.swift + SSHConfigParserTests.swift)
    that were blocking test bundle compilation. If autoclosure actor-isolation errors persisted
    after the build-setting change, @MainActor was added explicitly to SSHConfigParserTests class.
    Deleted WARNINGS_BASELINE.txt (Phase 0 scratch file, gitignored). Build: SUCCEEDED.
    Tests: ≤23 pre-existing failures. Phase 8 is NOT PLANNED.
  ```

---

### Step 7.8 — Update docs/featurelist.md

- [ ] Add loop-log entry immediately after the Phase 6 entry (most-recent-first):
  ```
  - 2026-02-24: Phase 7 COMPLETE (commit `<hash>`). Strict concurrency verified project-wide.
    App target already clean: Swift 6 + SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor = 0 warnings.
    Test target upgraded: SWIFT_STRICT_CONCURRENCY minimal → complete +
    SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor added to both Debug/Release build configs.
    Committed SSHConfigParser.swift + SSHConfigParserTests.swift (previously untracked, blocked
    test bundle compilation). @MainActor added to SSHConfigParserTests class if autoclosure
    errors persisted after build-setting change. WARNINGS_BASELINE.txt deleted (Phase 0 scratch,
    gitignored). Phase 8 is NOT PLANNED.
  ```

---

### Step 7.9 — Final Docs Commit

- [ ] Commit docs:
  ```bash
  git add CLAUDE.md docs/featurelist.md
  git commit -m "docs: mark Phase 7 complete in CLAUDE.md"
  ```

---

### End-of-Phase Verification Checklist

Run all four commands and confirm expected outputs before marking Phase 7 complete:

- [ ] **V1** — App target builds clean:
  ```bash
  xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build 2>&1 | tail -3
  ```
  Expected: `** BUILD SUCCEEDED **`

- [ ] **V2** — Test suite within baseline:
  ```bash
  xcodebuild -scheme ProSSHMac -destination 'platform=macOS' test 2>&1 \
    | grep -E "\*\* TEST" | tail -1
  ```
  Expected: `** TEST PASSED **` or `** TEST FAILED **` with ≤23 pre-existing failures only.

- [ ] **V3** — WARNINGS_BASELINE.txt gone:
  ```bash
  ls WARNINGS_BASELINE.txt 2>&1
  ```
  Expected: `ls: WARNINGS_BASELINE.txt: No such file or directory`

- [ ] **V4** — Test target settings updated:
  ```bash
  grep -A 30 "AB100009" ProSSHMac.xcodeproj/project.pbxproj \
    | grep -E "SWIFT_STRICT_CONCURRENCY|SWIFT_DEFAULT_ACTOR_ISOLATION"
  ```
  Expected: `SWIFT_STRICT_CONCURRENCY = complete;` AND `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor;`

---

## Phase 8 — Test Coverage Backfill

> Now that concerns are separated, unit tests are actually possible.
> **Note:** `AIResponseStreamParser` does not exist — no SSE streaming in `OpenAIAgentService`;
> replaced with `AIToolDefinitionsTests`. `DefaultSSHCredentialResolver` skipped (no injection
> point for filesystem). `LibSSHJumpCallParams`/`LibSSHTargetParams` widened to `internal` (Step 8.2).

### Step 8.1 — Baseline audit

- [x] **8.1a** Clean build confirmed: `** BUILD SUCCEEDED **`
- [x] **8.1b** Test baseline: 12 pre-existing failures (Phase 7 baseline)
- [x] **8.1c** `EncryptedStorage.swift` uses AES-GCM with Keychain-stored key; tests write to
  `Application Support/ProSSHV2/` and work locally (Keychain unlocked)

### Step 8.2 — Widen LibSSHJumpCallParams/LibSSHTargetParams private → internal

- [x] **8.2a** Changed `private struct LibSSHTargetParams` and `private struct LibSSHJumpCallParams`
  to `struct` (internal) in `LibSSHTransport.swift`
- [x] **8.2b** Build check passed

### Step 8.3 — Create RemotePathTests.swift (15 cases)

- [x] **8.3a** 8 normalize cases (empty, whitespace, root, simple, trailing slash, dot, double slash, relative)
- [x] **8.3b** 4 parent cases (root→nil, top-level, deep, normalizes input)
- [x] **8.3c** 3 join cases (root+name, path+name, normalizes base)
- [x] **8.3d** Build check passed

### Step 8.4 — Create AIConversationContextTests.swift (7 cases)

- [x] **8.4a** 7 cases: nil for unknown, update+retrieve, update with nil, clear removes,
  clear nonexistent safe, multiple sessions independent, dict reflects state
- [x] **8.4b** Build check passed

### Step 8.5 — Create PersistentStoreTests.swift (6 cases)

- [x] **8.5a** 4 Host cases: empty on missing file, save+load round trip, overwrite, save empty clears
- [x] **8.5b** 2 StoredSSHKey cases: key round trip, protocol conformance via KeyStoreProtocol
- [x] **8.5c** Build check passed

### Step 8.6 — Create AIToolDefinitionsTests.swift (9 cases)

- [x] **8.6a** Read AIToolDefinitions.swift; found: `developerPrompt`, `isDirectActionPrompt`,
  `shortTraceID`, `shortSessionID`, `directActionToolDefinitions`, `elapsedMillis`,
  `isPreviousResponseIDError`, `buildToolDefinitions`, `jsonString`
- [x] **8.6b** 9 cases covering all discovered static helpers
- [x] **8.6c** Build check passed

### Step 8.7 — Create MockSSHTransportTests.swift (5 cases, #if DEBUG)

- [x] **8.7a** Read MockSSHTransport.swift; connect, authenticate, openShell, disconnect, listDirectory
- [x] **8.7b** 5 cases: connect returns mock details, authenticate after connect, disconnect after connect,
  sessionNotFound if not connected, listDirectory returns entries
- [x] **8.7c** Build check passed

### Step 8.8 — Create SessionReconnectCoordinatorTests.swift (5 cases)

- [x] **8.8a** 5 cases: initial pending empty, initial reachable true, scheduleReconnect adds entry,
  cancelPending removes, removePendingForHost removes all sessions for host
- [x] **8.8b** Build check passed

### Step 8.9 — Create SessionKeepaliveCoordinatorTests.swift (4 cases)

- [x] **8.9a** 4 cases: no task when disabled, task starts when enabled, nil manager stops task,
  interval defaults to 30
- [x] **8.9b** Build check passed

### Step 8.10 — Create LibSSHJumpCallParamsTests.swift (5 cases)

- [x] **8.10a** 3 LibSSHTargetParams cases: hostname+port, username, algorithm strings non-empty
- [x] **8.10b** 2 LibSSHJumpCallParams cases: construction, expectedFingerprint stored
- [x] **8.10c** Build check passed

### Step 8.11 — Full test suite

- [x] 12 pre-existing failures — no new failures introduced

### Step 8.12 — Commit all test files

- [x] `test: add unit tests for refactored components (Phase 8)`

---

## Completion Criteria

All phases done when:

- [ ] No single Swift file exceeds 400 lines (excluding auto-generated)
- [ ] `SessionManager.swift` is under 300 lines
- [ ] `SSHTransport.swift` no longer exists (replaced by `Services/SSH/` directory)
- [ ] `OpenAIAgentService.swift` is under 300 lines
- [ ] Build succeeds with `-strict-concurrency=complete` and zero concurrency warnings
- [ ] All tests green
- [ ] `WARNINGS_BASELINE.txt` scratch file deleted

---

*Generated by: code review of khpbvo/ProSSHMac on 2026-02-24*
*Files analyzed: SSHTransport.swift (64KB), SessionManager.swift (67KB), OpenAIAgentService.swift (83KB),*
*Services/\* (21 files), Models/\* (6 files), ViewModels/\* (5 files)*
