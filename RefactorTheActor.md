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

> **Context note for Claude Code:** This phase only touches `LibSSHTransport.swift`
> and introduces one new protocol file. No UI or ViewModel changes.

### 2a. Introduce `SSHCredentialResolving` protocol

- [ ] Create `Services/SSH/SSHCredentialResolver.swift`
  ```swift
  protocol SSHCredentialResolving: Sendable {
      func privateKey(for reference: UUID) throws -> String
      func certificate(for reference: UUID) throws -> String
  }
  ```
- [ ] Create `Services/SSH/DefaultSSHCredentialResolver.swift`
  - Extract `loadStoredKeys()`, `loadStoredCertificates()`, `applicationSupportFileURL(filename:)`,
    `resolvePrivateKey(reference:)`, `resolveCertificate(reference:)`, `readSSHStringPrefix(from:)`
    from `LibSSHTransport` into a `struct DefaultSSHCredentialResolver: SSHCredentialResolving`
- [ ] Update `LibSSHTransport.init` to accept `credentialResolver: any SSHCredentialResolving`
      (default: `DefaultSSHCredentialResolver()`)
- [ ] Replace all direct `loadStoredKeys()` / `loadStoredCertificates()` calls in
      `LibSSHTransport` with calls through `self.credentialResolver`
- [ ] Verify `LibSSHTransport` no longer imports `EncryptedStorage` directly for key/cert loading
- [ ] Update `SSHTransportFactory.makePreferredTransport()` to pass default resolver
- [ ] Run tests; commit: `refactor: inject SSHCredentialResolving into LibSSHTransport`

### 2b. Flatten the jump host CString pyramid

- [ ] Create `nonisolated private struct LibSSHJumpCallParams` inside `LibSSHTransport.swift`
  - Fields: `hostname`, `port`, `username`, policy strings, material strings, `expectedFingerprint`
  - Single method: `func invoke(handle: OpaquePointer, target: LibSSHTargetParams, errorBuffer: inout [CChar]) -> Int32`
    — all `withCString` nesting lives here, behind a clean call site
- [ ] Create `nonisolated private struct LibSSHTargetParams`
  - Fields: `hostname`, `port`, `username`, policy strings
- [ ] Refactor `connectViaJumpHost` to build `LibSSHJumpCallParams` + `LibSSHTargetParams`
      and call `params.invoke(...)` — the call site should be ~10 lines, not 80
- [ ] Verify `connectViaJumpHost` nesting depth is ≤ 3 levels
- [ ] Run tests; commit: `refactor: flatten jump host CString pyramid into LibSSHJumpCallParams`

---

## Phase 3 — Deduplicate Remote Path Utilities

> **Context note for Claude Code:** `normalizeRemotePath`, `parentRemotePath`, `joinRemotePath`
> are copy-pasted between `MockSSHTransport` and `LibSSHTransport`. Extract once, use everywhere.

- [ ] Create `Services/SSH/RemotePath.swift`
  ```swift
  enum RemotePath {
      static func normalize(_ path: String) -> String { ... }
      static func parent(of path: String) -> String? { ... }
      static func join(_ base: String, _ name: String) -> String { ... }
  }
  ```
- [ ] Replace all `Self.normalizeRemotePath(_:)` calls in `LibSSHTransport` with `RemotePath.normalize(_:)`
- [ ] Replace all `Self.normalizeRemotePath(_:)`, `Self.parentRemotePath(of:)`,
      `Self.joinRemotePath(_:_:)` calls in `MockSSHTransport` with `RemotePath.*`
- [ ] Delete the now-duplicate private static methods from both transport actors
- [ ] Run tests; commit: `refactor: extract RemotePath utilities, remove duplication`

---

## Phase 4 — Generic `PersistentStore<T>` for the Store Boilerplate

> **Context note for Claude Code:** `HostStore`, `KeyStore`, `CertificateStore`,
> `AuditLogStore`, `CertificateAuthorityStore` all follow the same
> load-from-JSON / save-to-JSON / publish-via-Combine pattern.

- [ ] Audit all `*Store.swift` files in `Services/`; document their shared interface in a comment
- [ ] Create `Services/PersistentStore.swift`
  ```swift
  actor PersistentStore<T: Codable & Identifiable> {
      init(filename: String, decoder: JSONDecoder, encoder: JSONEncoder)
      func loadAll() throws -> [T]
      func save(_ items: [T]) throws
      func upsert(_ item: T) throws
      func delete(id: T.ID) throws
  }
  ```
- [ ] Refactor `HostStore` to use `PersistentStore<Host>` internally
- [ ] Refactor `KeyStore` to use `PersistentStore<StoredSSHKey>`
- [ ] Refactor `CertificateStore` to use `PersistentStore<SSHCertificate>`
- [ ] Refactor `CertificateAuthorityStore` to use `PersistentStore<CertificateAuthority>`
- [ ] Refactor `AuditLogStore` — may need a custom policy (size-limited log rotation);
      use `PersistentStore` for the base and add rotation logic as an extension
- [ ] Verify each store's public API is unchanged (no ViewModel changes needed)
- [ ] Run tests; commit: `refactor: introduce PersistentStore<T>, consolidate store boilerplate`

---

## Phase 5 — Decompose `SessionManager.swift` (67KB → 5 focused types)

> **This is the biggest phase. Context compaction is likely between sub-phases.**
> **Each sub-phase is a safe commit point.**
>
> `SessionManager` currently owns: connection lifecycle, terminal rendering pipeline,
> PTY resize debouncing, keepalive, auto-reconnect w/ network monitoring, session recording,
> scrollback navigation, command history, and screenshot injection.
> These need separate homes.

### 5a. Extract `SessionReconnectCoordinator`

- [ ] Create `Services/SessionReconnectCoordinator.swift`
  - Owns: `pendingReconnectHosts`, `reconnectTask`, `isNetworkReachable`, `networkMonitor`,
    `networkMonitorQueue`
  - Methods: `scheduleReconnectAttempt(after:)`, `attemptPendingReconnects()`,
    `handleNetworkStatusChange(isReachable:)`, `applicationDidEnterBackground()`,
    `applicationDidBecomeActive()`
  - Protocol: `SessionReconnecting` — so `SessionManager` holds a reference without tight coupling
- [ ] Update `SessionManager` to hold `private let reconnectCoordinator: SessionReconnectCoordinator`
- [ ] Delegate all reconnect calls from `SessionManager` through the coordinator
- [ ] Verify `networkMonitor.cancel()` still fires on coordinator `deinit`, not on `SessionManager`
- [ ] Run tests; commit: `refactor: extract SessionReconnectCoordinator from SessionManager`

### 5b. Extract `SessionKeepaliveCoordinator`

- [ ] Create `Services/SessionKeepaliveCoordinator.swift`
  - Owns: `keepaliveTask`, `keepaliveEnabled`, `keepaliveInterval` (UserDefaults reads)
  - Methods: `startIfNeeded(activeSessions:)`, `stopIfIdle(activeSessions:)`,
    `sendKeepalives(activeSessions:transport:lastActivity:)`
- [ ] Update `SessionManager` to hold `private let keepaliveCoordinator: SessionKeepaliveCoordinator`
- [ ] Remove `keepaliveTask`, `startKeepaliveTimerIfNeeded()`, `stopKeepaliveTimerIfIdle()`,
      `sendKeepalives()` from `SessionManager`
- [ ] Run tests; commit: `refactor: extract SessionKeepaliveCoordinator from SessionManager`

### 5c. Extract `TerminalRenderingCoordinator`

- [ ] Create `Services/TerminalRenderingCoordinator.swift`
  - Owns: per-session `TerminalEngine` instances, grid snapshots, shell buffers,
    bell events, input mode snapshots, window titles, working directories,
    scroll offsets, pending snapshot publish tasks, timing policies
  - Methods: `publishGridState(for:engine:snapshotOverride:)`,
    `scheduleCoalescedGridPublish(for:engine:)`, `scrollTerminal(sessionID:delta:)`,
    `scrollToBottom(sessionID:)`, `clearShellBuffer(sessionID:)`,
    `appendShellLine(_:to:)`, `resizeTerminal(sessionID:columns:rows:)`
  - Exposes `@Published` state via a `TerminalRenderingState` observable wrapper
    (or stays `@MainActor` and is composed into `SessionManager`'s published surface)
- [ ] Move all `gridSnapshotsBySessionID`, `shellBuffers`, `bellEventNonceBySessionID`,
      `inputModeSnapshotsBySessionID`, `windowTitleBySessionID`, `workingDirectoryBySessionID`,
      `scrollOffsetBySessionID`, `throughputModeEnabled` policy into this coordinator
- [ ] Update `SessionManager` to hold `private let renderingCoordinator: TerminalRenderingCoordinator`
- [ ] Run tests; commit: `refactor: extract TerminalRenderingCoordinator from SessionManager`

### 5d. Extract `SessionRecordingCoordinator`

- [ ] Create `Services/SessionRecordingCoordinator.swift`
  - Wraps `SessionRecorder`; owns `isRecordingBySessionID`, `hasRecordingBySessionID`,
    `isPlaybackRunningBySessionID`, `latestRecordingURLBySessionID`
  - Methods: `toggleRecording(sessionID:)`, `startRecording(sessionID:)`,
    `stopRecording(sessionID:)`, `playLastRecording(sessionID:speed:)`,
    `exportLastRecordingAsCast(sessionID:columns:rows:)`, `finalizeRecordingIfNeeded(sessionID:)`
- [ ] Update `SessionManager` to hold `private let recordingCoordinator: SessionRecordingCoordinator`
- [ ] Remove recording methods from `SessionManager`
- [ ] Run tests; commit: `refactor: extract SessionRecordingCoordinator from SessionManager`

### 5e. Clean up `SessionManager` itself

- [ ] Verify `SessionManager` now only owns: session list `@Published`, shell channels map,
      parser reader tasks, connection lifecycle methods, host verification, and known hosts
- [ ] Remove `// swiftlint:disable file_length` added in Phase 0 if file is now under ~400 lines
- [ ] Ensure all `@Published` properties on `SessionManager` that were moved are now
      either forwarded from coordinators or removed where the UI accesses the coordinator directly
- [ ] Update `ProSSHMacApp.swift` / `HostListViewModel` injection points for new coordinator types
- [ ] Run tests; commit: `refactor: SessionManager slim-down, inject coordinators`

---

## Phase 6 — Decompose `OpenAIAgentService.swift` (83KB)

> **Context note for Claude Code:** Read `OpenAIAgentService.swift` fully before starting.
> This file likely contains: agent runner loop, tool dispatch table, individual tool implementations,
> streaming response parsing, conversation context management, and error handling.
> Each of these is a separate concern.

- [ ] Read and annotate `OpenAIAgentService.swift` — add `// MARK: - [ConcernName]` markers
      to identify the distinct sections before extracting anything
- [ ] Create `Services/AI/AIToolHandler.swift`
  - Protocol: `AIToolHandling` — one method: `handle(input: [String: Any]) async throws -> String`
  - One concrete type per tool (e.g. `ShellCommandToolHandler`, `SFTPToolHandler`, etc.)
- [ ] Create `Services/AI/AIConversationContext.swift`
  - Owns conversation history (messages array), context window management,
    truncation strategy
- [ ] Create `Services/AI/AIResponseStreamParser.swift`
  - Owns SSE/streaming response parsing, `delta` accumulation, tool call reconstruction
- [ ] Create `Services/AI/AIAgentRunner.swift`
  - Owns the agent loop: sends message → handles tool calls → loops until `stop`
  - Depends on injected `[AIToolHandling]` array and `AIConversationContext`
- [ ] Slim `OpenAIAgentService` down to: configuration, initialization,
      public API surface (`ask(...)`, `stream(...)`) delegating to `AIAgentRunner`
- [ ] Remove `// swiftlint:disable file_length` added in Phase 0
- [ ] Run tests; commit: `refactor: decompose OpenAIAgentService into focused AI service types`

---

## Phase 7 — Strict Concurrency Pass

> **Context note for Claude Code:** This phase enables Swift's strict concurrency checks
> incrementally, file by file, fixing warnings before moving on.
> Do NOT enable project-wide until every file is clean.

- [ ] Enable `-strict-concurrency=targeted` in build settings (less aggressive than `complete`)
- [ ] Fix all `Sendable` warnings in `Services/SSH/` files (extracted in Phase 1–3)
- [ ] Fix all `Sendable` warnings in `Services/PersistentStore.swift` and `*Store.swift` files
- [ ] Fix all `Sendable` warnings in new coordinator files (Phase 5)
- [ ] Fix all `Sendable` warnings in AI service files (Phase 6)
- [ ] Fix all `Sendable` warnings in `Models/` (likely minor — add `Sendable` conformances)
- [ ] Fix all `Sendable` warnings in `ViewModels/`
- [ ] Upgrade to `-strict-concurrency=complete`; fix any remaining warnings
- [ ] Verify zero concurrency warnings in a clean build
- [ ] Run tests; commit: `chore: enable strict concurrency, fix all Sendable conformances`

---

## Phase 8 — Test Coverage Backfill

> Now that concerns are separated, unit tests are actually possible.

- [ ] Write unit tests for `RemotePath` (normalize edge cases, parent of root, join with slash)
- [ ] Write unit tests for `DefaultSSHCredentialResolver` (mock file system using temp directory)
- [ ] Write unit tests for `LibSSHJumpCallParams` (param construction, error code mapping)
- [ ] Write unit tests for `SessionReconnectCoordinator` (backoff logic, network change handling)
- [ ] Write unit tests for `SessionKeepaliveCoordinator` (interval enforcement, idle detection)
- [ ] Write unit tests for `PersistentStore<T>` (load/save/upsert/delete round-trips)
- [ ] Write unit tests for `AIConversationContext` (truncation strategy, history management)
- [ ] Write unit tests for `AIResponseStreamParser` (SSE delta accumulation, tool call reconstruction)
- [ ] Write integration test: `MockSSHTransport` full connect → auth → shell → disconnect lifecycle
- [ ] Run full test suite; commit: `test: add unit tests for refactored components`

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
