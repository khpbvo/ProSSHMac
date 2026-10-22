# ProSSHMac Bug Report

Comprehensive audit of the ProSSHMac codebase. Bugs are organized by subsystem, numbered
sequentially, and tagged by severity: **Critical**, **High**, **Medium**, or **Low**.

---

## Summary

| Severity | Total | Fixed | Open |
|----------|-------|-------|------|
| Critical | 1     | 1     | 0    |
| High     | 20    | 20    | 0    |
| Medium   | 40    | 40    | 0    |
| Low      | 35    | 34    | 1    |
| **Total**| **96**| **95**| **1**|

Counts recomputed 2026-10-11 from the bug headings; Bugs 80-83 added 2026-10-12, Bugs 84-85 added and Bug 82 fixed 2026-10-13, Bug 85 fixed and Bugs 86-87 added 2026-10-14, Bug 84 fixed and Bugs 88-90 added 2026-10-15, Bugs 91-93 added 2026-10-18, Bug 94 added 2026-10-20; Bugs 43, 44, 90 and 94 fixed and Bug 95 added 2026-10-20 (43 and 44 were found already fixed in the code); Bugs 87 and 88 fixed 2026-10-21. The `**File:**` paths below predate the
refactors (`Views/` → `UI/`, `SSH/` → `Services/SSH/`, `Services/Security/` → `Services/`) and some
files no longer exist — resolve by basename.

On 2026-10-21, source inspection found Bugs 16, 18, 20, 24, 27, 28, 37, 38, 39, 52, 66, 67,
69, 70, 74, 76, and 79 already fixed in the current code; their headings were corrected without
code changes. Evidence includes in-flight SFTP task cancellation and loop checks; distinct
biometric errors; tracked restart directory; symmetric Host encoding; jump-host cycle checks;
serial overflow guard; mapped REP character; OSC 4 pair loop; exact DCS intermediate match;
UUID quick-command variable IDs; screensaver monitor cleanup and state updates outside Canvas;
quoted file drops; persisted legacy setting; sorted host groups; reset import label; and macOS
availability on Shortcuts. Focused tests also verified Bugs 54 and 55 already resolved. Later
source inspection confirmed Bugs 9, 10, and 11 resolved as well. Counts
above were recomputed from all 96 headings after this audit.

A further 2026-10-21 source pass corrected Bugs 4, 6, 7, 21, 57, 59, 61, 63, and 77:
`waitpid` is dispatched off the async task, CFError formatting uses optional binding,
`strdup` occurs only in the child after `fork` and is freed if `execve` fails, reconnect entries
use session IDs, the idle timer uses weak capture and cancellation, the shader skips missing
glyphs and clamps glow radius, blink uses `M_PI_F`, and KeyForge's file-import error update is
on the main actor. Bugs 87 and 88 already had verified fixes below their stale headings.
Bug 46 was confirmed by a new maximize/restore regression test. Bugs 23, 47, and 75 refer to
old implementations: reconnect has no window capture, `restoreLayout` no longer exists or
force-unwraps pane lookups, and Matrix character indexing uses wrapping arithmetic before
modulo. These headings were corrected after source inspection on 2026-10-21.

On 2026-10-22, Bug 2 was found obsolete: the C forward-open path frees the channel on
open failure, and closes and frees it after wrapper allocation failure; there is no
later PTY/environment configuration. Bug 49 was fixed by moving encrypted save/load and
cast export to a storage actor. Bug 1's late-open race was fixed in the forwarding manager.

On 2026-10-22, Bugs 62 and 72 were closed: the scanner shader has no angular sweep,
and the hardcoded-off safety terminal renderer with unstable line IDs was removed.
Bug 3 was then fixed by making `LibSSHTransport` await shell opening and closing before
destroying its C session handle; Bug 1's forward-stop path now drains pending opens too.
Bug 95 was fixed with post-login Bash prompt injection and a real local PTY regression.
Bug 89's first post-reattach CRT frame was seeded from the current scene so it no longer
switches from zero phosphor blend to a brighter history blend on the next frame.

---

## Table of Contents

1. [SSH Transport & Connection](#1-ssh-transport--connection)
2. [Services & Storage](#2-services--storage)
3. [Session Management](#3-session-management)
4. [Models & Data](#4-models--data)
5. [Terminal Grid & Reflow](#5-terminal-grid--reflow)
6. [Terminal Parser](#6-terminal-parser)
7. [Terminal Input](#7-terminal-input)
8. [Terminal Renderer](#8-terminal-renderer)
9. [Terminal Features & Pane Management](#9-terminal-features--pane-management)
10. [Terminal Effects](#10-terminal-effects)
11. [Metal Shaders](#11-metal-shaders)
12. [UI Layer](#12-ui-layer)
13. [AppIntents](#13-appintents)

---

## 1. SSH Transport & Connection

### Bug 1 — ~~ForwardConnectionProxy Race Between `connect()` and `disconnect()`~~ [FIXED] (High)

**File:** `Services/PortForwardingManager.swift`

The old proxy fields no longer exist: `ForwardConnectionProxy` is an actor. The remaining
race was in `PortForwardingManager`: an SSH channel opened after `stopForward` could
recreate proxy state for a stopped rule. The manager now reserves slots for in-flight
opens, removes admission state before awaiting shutdown, and closes a channel that arrives
after stop. A stopped proxy also refuses a late `start`. The Debug build and focused
delayed-open regression passed on 2026-10-22. `stopForward` also waits for in-flight opens
to close before the SSH transport is disconnected. Live forwarding stress remains to be checked.

---

### Bug 2 — ~~LibSSHForwardChannel Leaks Resources on Partial `open()` Failure~~ [FIXED] (High)

**File:** `SSH/Channels/LibSSHForwardChannel.swift`

The current forward-channel open path has no environment or PTY configuration stage.
`prossh_forward_channel_open` frees the channel if opening fails and closes and frees it
if allocation of the wrapper fails after opening. Source inspection on 2026-10-22 found
the reported partial-open leak absent; no code change was needed. Live forwarding stress
testing remains separate from this source-level finding.

---

### Bug 3 — ~~LibSSHShellChannel `close()` / `read()` Race~~ [FIXED] (High)

**File:** `Services/SSH/LibSSHShellChannel.swift`, `Services/SSH/LibSSHTransport.swift`

The shell actor serializes read and close, and C reads are nonblocking and locked. The
remaining risk was transport teardown: `disconnect` could destroy the shared C handle
while the shell reader retained it, including during an in-flight `openShell`. The
transport now owns the shell channel, awaits any open task, closes the channel, then
destroys the handle. Connection generations reject results from a superseded open.
A temporary loopback `sshd` integration test completed repeated normal and concurrent
open/disconnect cycles on 2026-10-22; focused session tests and the Debug build passed.
This does not replace stress testing against a remote server.

---

### Bug 4 — ~~LocalShellChannel `waitpid` Blocks the Calling Task~~ [FIXED] (High)

**Files:** `SSH/Channels/LocalShellChannel.swift`, `Services/Session/LocalShellChannel.swift`

`waitpid(pid, &status, 0)` is a blocking POSIX call invoked directly inside an
async context. If the child process does not exit promptly, this blocks the cooperative
thread pool, which can cause deadlocks or starvation of other Swift Concurrency tasks.

**Impact:** UI freezes or deadlocks when a local shell session is closed but the child
process lingers.

**Suggested fix:** Use `waitpid` with `WNOHANG` in a polling loop (with a short sleep
between iterations), or dispatch the blocking call to a dedicated non-cooperative thread:
```swift
await withCheckedContinuation { continuation in
    DispatchQueue.global().async {
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        continuation.resume(returning: status)
    }
}
```

---

### Bug 5 — ~~SSHTransport `normalizeRemotePath` Does Not Handle `..` Components~~ [FIXED] (Medium)

**File:** `SSH/Transport/SSHTransport.swift`

`normalizeRemotePath` resolves `~` and collapses redundant slashes but does not resolve
`..` components. A path like `/home/user/../etc/passwd` is sent to the server as-is.

**Impact:** SFTP operations may access unexpected paths when user-supplied paths contain
`..` segments. Minor security concern if path validation relies on prefix checks.

**Suggested fix:** Resolve `..` components by walking the path segments:
```swift
var resolved: [String] = []
for component in segments {
    if component == ".." { resolved.popLast() }
    else if component != "." { resolved.append(component) }
}
```

---

### Bug 6 — ~~`cfErrorMessage` Uses `takeRetainedValue` Unsafely~~ [FIXED] (Medium)

**File:** `SSH/Transport/SSHTransport.swift`

`SecCopyErrorMessageString` returns a *Create-rule* `CFString?`, so
`takeRetainedValue()` is correct in principle. However, the function can return `nil`
for unknown error codes, and the force-unwrap `as String` on a nil value would crash.

**Impact:** Crash when formatting an error message for an unrecognized Security framework
error code.

**Suggested fix:** Use optional binding:
```swift
let msg = SecCopyErrorMessageString(status, nil)
    .map { $0.takeRetainedValue() as String }
    ?? "Unknown error \(status)"
```

---

### Bug 7 — ~~LocalShellChannel `strdup` Memory Not Freed on Failure Path~~ [FIXED] (Low)

**Files:** `SSH/Channels/LocalShellChannel.swift`, `Services/Session/LocalShellChannel.swift`

In `spawn()`, `strdup` is called to build the `argv` array for `execvp`. If `fork()`
fails or the function returns early, the `strdup`'d strings are never freed.

**Impact:** Minor memory leak on fork failure (rare in practice).

**Suggested fix:** Free the `strdup`'d strings in a `defer` block, or use
`withUnsafePointer`-based patterns that don't require manual deallocation.

---

### Bug 8 — ~~LocalShellChannel `ioctl` Called From Async Context Without Isolation~~ [FIXED] (Low)

**File:** `Services/Session/LocalShellChannel.swift`

`ioctl(fd, TIOCSWINSZ, &winsize)` is called inside an `async` method. While `ioctl`
with `TIOCSWINSZ` is fast and non-blocking, it is not formally safe to call from a
Swift Concurrency context without explicit thread isolation.

**Impact:** Theoretical data-race under strict concurrency checking; no practical impact
observed.

**Verified 2026-10-21:** PTY resize now lives in the `LocalPTYProcess` actor. Its synchronous
`ioctl` call runs within the actor-isolated method; the old unisolated channel path is gone.

---

## 2. Services & Storage

### Bug 9 — ~~EncryptedStorage Deletes Legacy Keychain Item Before Verifying Migration~~ [FIXED] (High)

**File:** `Services/Security/EncryptedStorage.swift`

During migration from the legacy keychain to the new storage backend, the legacy item
is deleted *before* confirming the new storage write succeeded. If the write fails
(disk full, permission error), the data is permanently lost.

**Impact:** Permanent credential loss during storage migration.

**Suggested fix:** Delete the legacy keychain item only *after* confirming the new
write succeeded:
```swift
try newStorage.write(data)
// Only now:
deleteLegacyKeychainItem()
```

**Verified 2026-10-21:** `loadOrCreateMasterKey` saves the legacy key into the new keychain
before deleting the old item.

---

### Bug 10 — ~~CertificateAuthorityService Non-Atomic Save Can Corrupt CA Store~~ [FIXED] (High)

**File:** `Services/Security/CertificateAuthorityService.swift`

`saveAuthorities()` writes directly to the file path. If the process crashes or is
killed mid-write, the file is left in a partially-written state, corrupting the entire
CA store on next load.

**Impact:** Loss of all certificate authorities on crash during save.

**Suggested fix:** Write to a temporary file, then atomically rename:
```swift
let tmp = storePath.appendingPathExtension("tmp")
try data.write(to: tmp, options: .atomic)
// .atomic already does write-then-rename on Apple platforms
```

**Verified 2026-10-21:** CA saves use `PersistentStore`, whose `EncryptedStorage` writer uses
`Data.write(options: .atomic)`.

---

### Bug 11 — ~~CertificateAuthorityService Deleting a CA Orphans Its Secure Enclave Key~~ [FIXED] (Medium)

**File:** `Services/Security/CertificateAuthorityService.swift`

When a CA is deleted, its associated Secure Enclave private key is not removed. The key
remains in the Secure Enclave indefinitely with no way to reference or clean it up.

**Impact:** Secure Enclave key slot leakage over time; eventually exhausting the limited
number of Secure Enclave keys available to the app.

**Suggested fix:** Before removing a CA, look up and delete its Secure Enclave key:
```swift
func deleteAuthority(_ ca: CertificateAuthority) throws {
    try SecureEnclaveKeyManager.shared.deleteKey(tag: ca.keyTag)
    authorities.removeAll { $0.id == ca.id }
    try saveAuthorities()
}
```

**Verified 2026-10-21:** `deleteAuthorities` saves the updated CA list, then calls
`deleteP256Key` for each deleted authority's nonempty Secure Enclave reference.

---

### Bug 12 — ~~CertificateAuthorityService `generateCertificate` Discards Extension Values~~ [FIXED] (Medium)

**File:** `Services/Security/CertificateAuthorityService.swift`

When generating a certificate, the code collects extension OIDs from user configuration
but does not pass through extension *values* (critical flag, data). The resulting
certificate has extensions with empty or default values rather than the user-specified
content.

**Impact:** Certificates generated with custom extensions (e.g., `extendedKeyUsage`) will
not contain the intended extension data.

**Suggested fix:** Pass extension values (not just OIDs) through the certificate
generation pipeline.

**Verified 2026-10-21:** `encodeNameValueMap` serializes each extension name and value, and
`signCertificate` appends that map to the bytes signed and stored in `rawCertificateData`.
`SSHCertificate.extensions` keeps names for display, while the signed certificate retains values.

---

### Bug 13 — ~~KnownHostEntry `id` Collides When Same Host Has Multiple Key Types~~ [FIXED] (Medium)

**File:** `Services/Security/KnownHostsStore.swift`  (and `Models/KnownHostEntry.swift`)

`KnownHostEntry.id` is computed from `"\(hostname):\(port)"`, ignoring the key type. A
host with both RSA and Ed25519 keys produces two entries with the same `id`. In
`SwiftUI.List` or any `Identifiable`-based collection, one entry shadows the other.

**Impact:** Only one host key per host is visible in the Known Hosts UI; users cannot
manage individual key types.

**Suggested fix:** Include the key type in the id:
```swift
var id: String { "\(hostname):\(port):\(keyType)" }
```

---

### Bug 14 — ~~KnownHostVerificationChallenge `id` Also Missing keyType~~ [FIXED] / FileKnownHostsStore Uses `NSLock` Inside Async Context (Medium)

**File:** `Services/Security/FileKnownHostsStore.swift`

An `NSLock` is used to synchronize access to the known-hosts file, but the lock is
acquired inside `async` methods. If a Swift Concurrency task is suspended while
holding the lock (e.g., due to a cooperative yield point between `lock()` and
`unlock()`), other tasks waiting on the lock will block the cooperative thread pool.

The same pattern exists in `FileAuditLogStore`.

**Impact:** Potential thread-pool starvation and UI freezes under heavy concurrent
known-host lookups.

**Suggested fix:** Replace `NSLock` with an actor, or ensure the locked region contains
no `await` (suspension) points.

---

### Bug 15 — ~~SecureEnclaveKeyManager Force-Casts `SecKey` Query Result~~ [FIXED] (Medium)

**File:** `Services/Security/SecureEnclaveKeyManager.swift`

The Keychain query result is force-cast: `let key = result as! SecKey`. If the Keychain
returns an unexpected type (e.g., `CFData`), the app crashes.

**Impact:** Crash when Keychain state is inconsistent or after OS updates change return
types.

**Suggested fix:** Use conditional cast with error handling:
```swift
guard let key = result as? SecKey else {
    throw KeyError.unexpectedKeychainResult
}
```

---

### Bug 16 — ~~TransferManager `cancelTransfer` Does Not Cancel In-Flight Network I/O~~ [FIXED] (Medium)

**File:** `SSH/Transport/TransferManager.swift`

`cancelTransfer()` sets the transfer's state to `.cancelled` but does not cancel the
underlying `Task` or network operation. The SFTP read/write loop continues until it
naturally completes or errors out.

**Impact:** Cancelled transfers continue consuming bandwidth and SSH channel resources
until they finish on their own.

**Suggested fix:** Store the `Task` handle and call `.cancel()` on it, and check
`Task.isCancelled` in the transfer loop.

---

### Bug 17 — ~~EncryptedStorage Backup Filename Collision~~ [FIXED] (Medium)

**File:** `Services/Security/EncryptedStorage.swift`

Backup filenames use a date formatter with second precision. Two backups created within
the same second overwrite each other.

**Impact:** Data loss when rapid successive backups are triggered (e.g., by automated
migration code).

**Suggested fix:** Append a UUID or use sub-second timestamp precision.

---

### Bug 18 — ~~BiometricPasswordStore Returns Confusing "not found" Error on Auth Failure~~ [FIXED] (Low)

**File:** `Services/Security/BiometricPasswordStore.swift`

When biometric authentication fails (user cancels, Face ID not recognized), the error
propagated is "password not found" rather than the actual `LAError`. This makes it
impossible for callers to distinguish between a missing password and a failed biometric
challenge.

**Impact:** Confusing error messages; callers cannot implement "retry biometrics" logic.

**Suggested fix:** Propagate the `LAError` directly and only return "not found" when
the Keychain item genuinely does not exist.

---

### Bug 19 — ~~KnownHostsStore Debug `print()` Statements Left in Production Code~~ [FIXED] (Low)

**File:** `Services/Security/KnownHostsStore.swift`

Several `print()` calls are present in the known-hosts parsing and lookup code. These
write to stdout in release builds.

**Impact:** Information leakage (hostnames and key fingerprints written to console log);
minor performance overhead.

**Suggested fix:** Remove the `print()` calls or replace with `os_log` at `.debug` level.

---

## 3. Session Management

### Bug 20 — ~~`restartLocalSession` Uses Stale Working Directory~~ [FIXED] (Medium)

**File:** `Services/Session/SessionManager.swift`

When restarting a local shell session, the original `host.defaultDirectory` is used
instead of the shell's current working directory at the time of restart. If the user
`cd`'d to a different directory, the restarted session opens in the wrong location.

**Impact:** User loses their working directory context on session restart.

**Suggested fix:** Track the terminal's current working directory (via OSC 7 or similar)
and use it as the restart directory.

---

### Bug 21 — ~~`applicationDidEnterBackground` Matches Sessions by `host.id` Instead of `session.id`~~ [FIXED] (Medium)

**File:** `Services/Session/SessionManager.swift`

Background handling iterates sessions and indexes them by `host.id`. If multiple sessions
share the same host, they map to the same key, and all but one are silently dropped from
the background-tracking dictionary.

**Impact:** On backgrounding, only one session per host is properly managed; others may
be killed or fail to reconnect.

**Suggested fix:** Key the dictionary by `session.id` instead of `host.id`.

---

### Bug 22 — ~~`removeSession` Performs Double Cleanup~~ [FIXED] (Low)

**File:** `Services/Session/SessionManager.swift`

`removeSession()` calls both `session.disconnect()` and then removes the session from
the active list. But the `disconnect()` method itself may trigger a delegate callback
that also calls `removeSession()`, causing a double-remove. The second call is harmless
(the session is already gone) but wastes cycles and logs spurious warnings.

**Impact:** Spurious log noise; no functional impact.

**Fixed 2026-10-21:** The delegate-callback path described above no longer exists and
`removeSession` guards missing sessions. A remaining duplicate was found in
`restartLocalSession`: it called `removeSessionArtifacts` and then `removeSession`, which calls
the same cleanup again. Restart now calls only `removeSession`. Debug build and the focused
`SessionManagerRenderingPathTests` passed (23/23); restart was not exercised directly.

---

### Bug 23 — ~~`reconnectTask` Captures `nil` Window Reference~~ [FIXED] (Low)

**File:** `Services/Session/SessionManager.swift`

The reconnection task captures `self.window` at creation time. If the window is dismissed
before reconnection completes, the task holds a nil/stale window reference and the
reconnected session has no associated window.

**Impact:** Reconnected session may not appear in any window after the original window
is closed.

---

## 4. Models & Data

### Bug 24 — ~~Host `portForwardingRules` Encode/Decode Asymmetry~~ [FIXED] (High)

**File:** `Models/Host.swift`

`encode(to:)` encodes `portForwardingRules` as a nested keyed container, but `init(from:)`
decodes it as a flat array with `decodeIfPresent([PortForwardingRule].self)`. A Host
encoded by the current code cannot be decoded by the same code.

**Impact:** Port forwarding rules are silently lost on round-trip through Codable (e.g.,
saving and re-loading from disk, iCloud sync).

**Suggested fix:** Make encode and decode use the same format — either both use the flat
array or both use the nested container.

---

### Bug 25 — ~~Host `legacyModeEnabled` / `tags` Break Backward Compatibility~~ [FIXED] (Medium)

**File:** `Models/Host.swift`

These properties are encoded unconditionally but older versions of the app do not know
about them. Loading a newer config file in an older app version will fail to decode
(or silently drop the properties, depending on decoder settings).

**Impact:** Downgrading the app or syncing config between app versions may lose host
configuration.

**Suggested fix:** Use `encodeIfPresent` and `decodeIfPresent` with sensible defaults
for forward/backward compatibility.

---

### Bug 26 — ~~Session Decoder Not Forward-Compatible~~ [FIXED] (Medium)

**File:** `Models/Session.swift`

The `Session` decoder uses `decode` (not `decodeIfPresent`) for several fields that
may not exist in older stored data. If a stored session was created by an older app
version missing these fields, decoding fails and the session is lost.

**Impact:** Loss of saved sessions on app update.

**Suggested fix:** Use `decodeIfPresent` with defaults for all fields that were added
after the initial release.

---

### Bug 27 — ~~Host Jump-Host Validation Does Not Detect Cycles~~ [FIXED] (Low)

**File:** `Models/Host.swift` (via `HostDraft`)

A host can reference itself (directly or transitively) as its jump host. The connection
code will recurse until it hits a stack overflow or timeout.

**Impact:** App hang or crash when connecting through a cyclic jump-host chain.

**Suggested fix:** Walk the jump-host chain and check for cycles before connecting:
```swift
var visited: Set<UUID> = []
var current = host
while let jumpId = current.jumpHostID {
    guard !visited.contains(jumpId) else { throw HostError.cyclicJumpHost }
    visited.insert(jumpId)
    current = lookupHost(jumpId)
}
```

---

### Bug 28 — ~~CertificateAuthorityModel `nextSerialNumber` Can Overflow~~ [FIXED] (Low)

**File:** `Models/CertificateAuthorityModel.swift`

`nextSerialNumber` is an `Int` that is incremented on each certificate issuance. On 64-bit
platforms this is effectively unlimited, but the value is never validated against the X.509
serial number field's constraints (which require a positive integer up to 20 octets per
RFC 5280).

**Impact:** Theoretical; only relevant after issuing > 2^63 certificates.

---

### Bug 29 — ~~Transfer `bytesTransferred` Can Exceed `totalBytes`~~ [FIXED] (Low)

**File:** `Models/Transfer.swift`

Progress updates set `bytesTransferred` from raw byte counts without clamping. If the
underlying transport reports more bytes than the file size (e.g., due to a race between
size query and transfer, or resumed transfers), `bytesTransferred > totalBytes` and
progress bars render incorrectly (> 100%).

**Impact:** Cosmetic — progress bar overflow.

**Suggested fix:** Clamp: `bytesTransferred = min(bytes, totalBytes)`

---

## 5. Terminal Grid & Reflow

### Bug 30 — ~~Snapshot Double-Buffer Can Share Storage With Live Snapshot~~ [FIXED] (High)

**File:** `Terminal/Grid/TerminalGrid.swift`, lines 1082–1171

In `snapshot()`, a pre-allocated buffer is swapped out, filled, used to create a
`GridSnapshot` (which captures the `ContiguousArray` by value), then stored *back* into
the same slot for reuse. Because Swift's copy-on-write may optimize away the copy when
the reference count is 1, `snapshotBufferA` and `snap.cells` can end up sharing the same
backing storage. Two `snapshot()` calls later, the buffer is swapped out and mutated
in-place while the renderer may still be reading the earlier snapshot.

**Impact:** Rare visual corruption — cells from different frames intermixed on screen.
Most likely during dropped frames or when synchronized output caches a snapshot via
`lastSnapshot`.

**Suggested fix:** Do not store the buffer back after creating the snapshot (let it be
uniquely owned by the snapshot), or use triple-buffering to guarantee the renderer always
has a unique copy.

---

### Bug 31 — ~~Wide Character at Last Column Creates Orphaned Half-Width Cell~~ [FIXED] (High)

**File:** `Terminal/Grid/TerminalGrid.swift`, lines 301–372

When a wide (2-cell) character is printed at `columns - 1` (the last column), the code
writes the primary cell but skips the continuation cell because `col + 1 < columns` is
false. This leaves a `width: 2` cell without its continuation partner.

**Impact:** Visual corruption when CJK or emoji characters are printed at the rightmost
column. The character renders incorrectly and subsequent text alignment is disrupted.

**Suggested fix:** When a wide character would land at `columns - 1`, wrap first (matching
xterm/VTE behavior):
```swift
if isWide && col >= columns - 1 {
    if autoWrapMode { performWrap() }
    // Now col == 0 on the next row; write normally
}
```

---

### Bug 32 — ~~`printASCIIBytesBulk` Returns Prematurely in Insert Mode~~ [FIXED] (High)

**File:** `Terminal/Grid/TerminalGrid.swift`, lines 456–465

When `insertMode` is true, the bulk ASCII path calls `printCharacter` for the first byte
and then `return`s from the `withActiveCells` closure, abandoning all remaining bytes in
the run.

**Impact:** Bulk ASCII output is truncated to a single character when insert mode is
active. Affects programs that enable insert mode and produce fast text output (e.g.,
interactive editors).

**Suggested fix:** Replace `return` with `continue`, or break out of the closure and
fall back to per-character processing for the remaining bytes.

---

### Bug 33 — ~~GridReflow Marks All Screen Rows as `isWrapped: false`~~ [FIXED] (Medium)

**File:** `Terminal/Grid/GridReflow.swift`, lines 182–184

When extracting logical lines for reflow, screen rows are all added with
`isWrapped: false`:
```swift
for row in screenRows {
    allRows.append((cells: row, isWrapped: false))
}
```

Screen rows *can* be wrapped — a long line that wraps at the right margin sets the
`.wrapped` attribute on the last cell. Scrollback lines correctly carry their
`isWrapped` flag, but screen rows do not check for it.

**Impact:** During reflow on terminal resize, consecutive screen rows that were part of a
single wrapped line are not joined. Long lines that wrapped appear as separate lines after
the resize.

**Suggested fix:** Check the previous row's last cell for the `.wrapped` attribute:
```swift
for (i, row) in screenRows.enumerated() {
    let isWrapped = i > 0 && screenRows[i-1].last.map {
        $0.attributes.contains(.wrapped)
    } ?? false
    allRows.append((cells: row, isWrapped: isWrapped))
}
```

---

### Bug 34 — ~~GridReflow Cursor Tracking Misses One-Past-End Position~~ [FIXED] (Medium)

**File:** `Terminal/Grid/GridReflow.swift`, lines 90–103

During reflow, cursor position is matched with `offsetInLine >= rowStart &&
offsetInLine < rowEnd`. If the cursor is at the one-past-the-end position of a logical
line (i.e., `offsetInLine == rowEnd` on the last physical row), the condition is false
and cursor position defaults to `(0, 0)`.

This can happen when `findCursorInLogicalLines` returns `offsetInLine ==
logLine.cells.count` (after trailing blank trimming).

**Impact:** After resizing, the cursor may jump to position (0, 0) when it was at the
end of a logical line.

**Suggested fix:** Use `<=` for the last row:
```swift
let isLastRow = physIdx == wrapped.count - 1
if offsetInLine >= rowStart
    && (offsetInLine < rowEnd || (isLastRow && offsetInLine == rowEnd)) {
    cursorNewRow = newPhysicalRows.count
    cursorNewCol = min(offsetInLine - rowStart, newColumns - 1)
}
```

---

### Bug 35 — ~~`TerminalGrid.resize` Reflows Primary Buffer With Alternate-Screen Cursor~~ [FIXED] (Medium)

**File:** `Terminal/Grid/TerminalGrid.swift`, lines 1457–1495

The resize method always passes `cursor.row` / `cursor.col` to `GridReflow.reflow()`.
When the alternate buffer is active, these are the *alternate* buffer's cursor, not the
primary buffer's. The primary cursor is saved in `cursor.savedPrimary`.

**Impact:** After resizing while in an alternate-screen app (vim, htop, etc.), switching
back to the primary screen shows the cursor in the wrong position.

**Suggested fix:** Use `cursor.savedPrimary` when the alternate buffer is active, and
update the saved cursor from the reflow result:
```swift
let (row, col) = usingAlternateBuffer
    ? (cursor.savedPrimary?.row ?? 0, cursor.savedPrimary?.col ?? 0)
    : (cursor.row, cursor.col)
```

---

### Bug 36 — ~~ScrollbackBuffer `subscript` Has No Bounds Check~~ [FIXED] (Medium)

**File:** `Terminal/Grid/ScrollbackBuffer.swift`, lines 104–107

The subscript computes `(head + index) % storage.count` without validating that `index`
is in `0..<count`. An out-of-range index returns stale data from a previously overwritten
slot. If `storage` is empty, the modulo causes a division-by-zero crash.

**Impact:** Crash on empty buffer; silent stale-data reads on out-of-range index.

**Suggested fix:**
```swift
subscript(index: Int) -> ScrollbackLine {
    precondition(index >= 0 && index < count,
                 "ScrollbackBuffer index out of range")
    let storageIndex = (head + index) % storage.count
    return storage[storageIndex]
}
```

---

### Bug 37 — ~~`printASCIIBytesBulk` Sets `lastPrintedChar` to Unmapped Byte~~ [FIXED] (Low)

**File:** `Terminal/Grid/TerminalGrid.swift`, line 481

In the bulk ASCII path, `lastPrintedChar` is always set to the unmapped ASCII character,
even when DEC Special Graphics charset mapping is active. A subsequent REP (`CSI b`)
would repeat the unmapped character instead of the mapped one (e.g., `'j'` instead of
the box-drawing character `U+2518`).

**Impact:** REP repeats the wrong character in DEC Special Graphics mode.

**Suggested fix:**
```swift
lastPrintedChar = needsCharsetMapping
    ? charStr.first ?? Self.asciiCharacterCache[Int(byte)]
    : Self.asciiCharacterCache[Int(byte)]
```

---

## 6. Terminal Parser

### Bug 38 — ~~OSC 4 Only Handles First Color Pair in Multi-Pair Sequences~~ [FIXED] (Low)

**File:** `Terminal/Parser/OSCHandler.swift`, lines 122–145

OSC 4 can set multiple palette colors in one sequence:
`OSC 4 ; idx1 ; color1 ; idx2 ; color2 ST`. The code uses
`text.split(separator: ";", maxSplits: 1)`, so only the first pair is parsed.

**Impact:** Applications that set multiple palette colors in a single OSC 4 (e.g., theme
configuration) only get the first color applied.

**Suggested fix:** Parse all pairs in a loop, advancing two parts at a time.

---

### Bug 39 — ~~DCSHandler DECRQSS Check Uses `contains` Instead of Equality~~ [FIXED] (Low)

**File:** `Terminal/Parser/DCSHandler.swift`, lines 64–69

The DECRQSS routing checks `intermediates.contains(0x24)` (`$`) rather than
`intermediates == [0x24]`. If a future DCS sequence has `$` anywhere in its
intermediates, it will be incorrectly routed to the DECRQSS handler.

**Impact:** No current conflict, but fragile for future DCS handler additions.

---

## 7. Terminal Input

### Bug 40 — ~~Mouse Coordinate 0-Based vs 1-Based Mismatch~~ [FIXED] (Medium)

**File:** `Terminal/Input/MouseEncoder.swift`, lines 135–148, 296–313

`locationToCell` returns 0-based coordinates, but both X10 and SGR encoding apply
`max(1, ...)` to the values. In X10 mode this means position (0, 0) is reported as
(1, 1), making clicks in the first row or column off by one.

**Impact:** Mouse interaction is inaccurate for the first row and first column.

**Suggested fix:** Convert to 1-based coordinates at the call site when constructing
the `MouseEvent`:
```swift
let mouseEvent = MouseEvent(
    row: cell.row + 1,
    column: cell.col + 1,
    ...
)
```

---

### Bug 41 — ~~KeyEncoder `encodeBackspace` Ignores Ctrl When Alt Is Held~~ [FIXED] (Low)

**File:** `Terminal/Input/KeyEncoder.swift`, lines 217–225

Alt+Ctrl+Backspace and Alt+Backspace (with `backspaceSendsDelete = true`) both produce
`ESC 0x7F`. The Ctrl modifier is effectively ignored when combined with Alt. The behavior
happens to be correct by accident for the common case, but the code path is inconsistent.

**Impact:** Very low — no incorrect behavior in practice for standard configurations.

**Verified 2026-10-21:** Current encoder applies Ctrl's opposite-byte mapping before Alt's
escape prefix. Added regression cases for both Backspace settings; `KeyEncoderTests` passed
14/14 and the Debug build passed.

---

## 8. Terminal Renderer

### Bug 42 — ~~GlyphAtlas `rowHeight` Not Reset When Starting a New Row~~ [FIXED] (Medium)

**File:** `Terminal/Renderer/GlyphAtlas.swift`, lines 174–178

When a glyph doesn't fit horizontally and the packer moves to a new row, `rowHeight`
carries over from the previous row instead of being reset. If the previous row had a
tall glyph (e.g., emoji), subsequent rows inherit the inflated height, wasting vertical
atlas space.

**Impact:** Premature atlas page allocation; increased GPU memory usage. In pathological
cases, atlas exhaustion triggers page churn.

**Suggested fix:**
```swift
if nextX + width > pageSize {
    nextX = 0
    nextY += rowHeight
    rowHeight = cellHeight  // Reset for the new row
}
```

---

### Bug 43 — ~~RendererPerformanceMonitor Is Not Thread-Safe~~ [FIXED] (High)

**File:** `Terminal/Renderer/RendererPerformanceMonitor.swift`

The performance monitor stores frame times in arrays that are read and written from
both the render thread and the main thread without synchronization. Concurrent access
to Swift arrays is undefined behavior and can cause crashes.

**Impact:** Intermittent crashes during rendering, especially on high-refresh-rate
displays.

**Suggested fix:** Make the monitor an actor, or protect its mutable state with a lock.

**Fixed (found 2026-10-20):** all mutable state is behind an `NSLock`; the entry was never updated.

---

### Bug 44 — ~~RendererPerformanceMonitor Uses Quadratic `removeFirst()`~~ [FIXED] (Medium)

**File:** `Terminal/Renderer/RendererPerformanceMonitor.swift`

Frame-time history is stored in an `Array`. When the history exceeds its limit,
`removeFirst()` is called, which is O(n) for Array. Over time, this causes increasing
CPU overhead in the render loop.

**Impact:** Performance degradation proportional to history size; minor on short
histories but avoidable.

**Suggested fix:** Use a ring buffer or `Deque` instead of Array.

**Fixed (found 2026-10-20):** samples live in a fixed-capacity `RingBuffer`; the entry was never updated.

---

## 9. Terminal Features & Pane Management

### Bug 45 — ~~PaneManager `syncSessions` Mutates Collection During Iteration~~ [FIXED] (High)

**File:** `Terminal/Features/PaneManager.swift`

`syncSessions()` iterates over the pane tree and calls `removePane()` for panes whose
sessions have ended. Removing a pane mutates the tree structure while the iteration is
in progress, which can skip panes or cause index-out-of-bounds crashes.

**Impact:** Crash when multiple sessions end simultaneously; stale panes left in the
tree.

**Suggested fix:** Collect panes to remove in a separate array, then remove them after
iteration:
```swift
let deadPanes = allPanes.filter { !activeSessions.contains($0.sessionId) }
for pane in deadPanes { removePane(pane.id) }
```

---

### Bug 46 — ~~PaneManager `restoreMaximizedPane` Discards Pending Layout Changes~~ [FIXED] (Medium)

**File:** `Terminal/Features/PaneManager.swift`

When un-maximizing a pane, the saved layout is restored but any panes added or removed
while maximized are discarded. The tree reverts to the pre-maximization state.

**Impact:** Panes opened while another pane was maximized silently disappear on
un-maximize.

**Verified 2026-10-21:** `restoreMaximize` merges additions and removals made while maximized.
`PaneManagerTests.testRestoreMaximizeKeepsPanesAddedAndRemovedWhileMaximized` passed, as did the
full focused pane suite (28/28) and Debug build.

---

### Bug 47 — ~~PaneManager Force-Unwraps During `restoreLayout`~~ [FIXED] (High)

**File:** `Terminal/Features/PaneManager.swift`

`restoreLayout()` force-unwraps optional lookups (`panes[id]!`) when rebuilding the
tree from saved state. If the saved layout references a pane ID that no longer exists
(e.g., session ended during background), the app crashes.

**Impact:** Crash on layout restore with stale pane references.

**Suggested fix:** Use `guard let` with fallback behavior (skip missing panes).

---

### Bug 48 — ~~SessionTabManager `Dictionary(uniqueKeysWithValues:)` Crashes on Duplicate IDs~~ [FIXED] (High)

**File:** `Terminal/Features/SessionTabManager.swift`

Tab ordering is rebuilt with `Dictionary(uniqueKeysWithValues:)`, which has a
precondition that keys are unique. If any tab IDs are duplicated (e.g., due to a restore
bug), this crashes immediately.

**Impact:** Crash on launch or tab restore when duplicate tab IDs exist.

**Suggested fix:** Use `Dictionary(_:uniquingKeysWith:)`:
```swift
Dictionary(pairs, uniquingKeysWith: { first, _ in first })
```

---

### Bug 49 — ~~SessionRecorder Performs File I/O on Main Thread~~ [FIXED] (High)

**File:** `Terminal/Features/SessionRecorder.swift`

The recorder buffers chunks in memory; it did not append to a file per chunk. Saving the
encrypted recording at stop, loading it for playback, and serializing/writing a `.cast`
export did run synchronously on the main actor. These operations now run on a dedicated
storage actor. The main actor still owns active recording state and in-memory chunks.
The Debug build and 31 focused tests passed on 2026-10-22. A live large-recording UI
check remains useful.

---

### Bug 50 — ~~SessionRecorder Playback Has No Cancellation Support~~ [FIXED] (Medium)

**File:** `Terminal/Features/SessionRecorder.swift`

The playback loop uses `Task.sleep` but never checks `Task.isCancelled`. Once playback
starts, it cannot be stopped until it finishes.

**Impact:** User cannot stop a long recording playback; the UI is effectively locked to
the playback timeline.

**Suggested fix:** Check `Task.isCancelled` before each frame:
```swift
for frame in recording.frames {
    guard !Task.isCancelled else { break }
    try await Task.sleep(for: frame.delay)
    render(frame)
}
```

---

### Bug 51 — ~~QuickCommands `replacingVariables` Causes Out-of-Range Crash~~ [FIXED] (Critical)

**File:** `Terminal/Features/QuickCommands.swift`

`replacingVariables` uses `String.Index` from one string to subscript another. When a
variable is replaced with a value of different length, the indices become invalid for the
mutated string, causing an out-of-range crash.

**Impact:** Crash when executing any quick command that contains variables and the
replacement value differs in length from the placeholder.

**Suggested fix:** Process replacements in reverse order (from end of string to start),
or rebuild the string from scratch using ranges computed on the original string.

---

### Bug 52 — ~~QuickCommandVariable Uses `name` as `id` Allowing Collisions~~ [FIXED] (Low)

**File:** `Terminal/Features/QuickCommands.swift`

`QuickCommandVariable` conforms to `Identifiable` with `id` computed from `name`. Two
variables with the same name but different default values or types are treated as the
same variable in SwiftUI lists.

**Impact:** Variable list may render incorrectly if duplicate names exist.

---

### Bug 53 — ~~TerminalSearch Range Validation Is Fragile~~ [FIXED] (Low)

**File:** `Terminal/Features/TerminalSearch.swift`

Search result ranges are computed against a snapshot of terminal content but applied to
the live terminal state. If content scrolls between search and highlight, the ranges
may be invalid.

**Impact:** Incorrect highlight positions after terminal content changes during search.

**Fixed 2026-10-21:** Each match stores the source line. Before a stale match is applied to a
newly rendered line, `stringRange(in:)` checks that the whole line is unchanged; otherwise no
highlight is drawn until `updateLines` refreshes matches. This also avoids range arithmetic
overflow in `isMatchValid`. The Debug build and `TerminalSearchTests` passed (6/6).

---

## 10. Terminal Effects

### Bug 54 — ~~LinkDetector Fails on Wikipedia-Style URLs With Parentheses~~ [FIXED] (Medium)

**File:** `Terminal/Effects/LinkDetector.swift`

The URL regex does not account for balanced parentheses in URLs. Wikipedia URLs like
`https://en.wikipedia.org/wiki/Foo_(bar)` have the closing `)` stripped because the
regex treats it as sentence-ending punctuation.

**Impact:** Wikipedia and similar URLs are truncated when clicked or displayed.

**Suggested fix:** Add balanced-parenthesis handling to the URL regex, or use a
dedicated URL parser that handles RFC 3986 correctly.

**Verified 2026-10-21:** Current code retains balanced parentheses and trims sentence
punctuation. `LinkDetectorTests` covers the Wikipedia example; it passes.

---

### Bug 55 — ~~LinkDetector False Positives on File Paths~~ [FIXED] (Medium)

**File:** `Terminal/Effects/LinkDetector.swift`

The file-path detection regex matches too broadly. Patterns like `v1.2.3/changelog` or
`usr/bin/env` are detected as clickable file paths even when they are not actual paths
in context.

**Impact:** Spurious link highlights in terminal output; clicking them opens error
dialogs or wrong files.

**Verified 2026-10-21:** Current path detection requires a leading `/`, `~/`, or `./`.
`LinkDetectorTests` rejects both examples above and accepts `/usr/bin/env` (3/3 passed).

---

### Bug 56 — ~~IdleScreensaverManager Never Removes Event Monitors~~ [FIXED] (High)

**File:** `Terminal/Effects/IdleScreensaverManager.swift`

`NSEvent.addGlobalMonitorForEvents` and `addLocalMonitorForEvents` are called when the
screensaver starts, but the returned monitor tokens are never passed to
`NSEvent.removeMonitor`. Each idle cycle adds new monitors that are never cleaned up.

**Impact:** Memory leak and increasing CPU overhead; eventually thousands of monitors
processing every user event.

**Suggested fix:** Store the monitor tokens and remove them when the screensaver stops:
```swift
private var monitors: [Any] = []

func stop() {
    monitors.forEach { NSEvent.removeMonitor($0) }
    monitors.removeAll()
}
```

---

### Bug 57 — ~~IdleScreensaverManager Timer Task May Outlive Manager~~ [FIXED] (Low)

**File:** `Terminal/Effects/IdleScreensaverManager.swift`

The idle timer is a `Task` that captures `self`. If the manager is deallocated while the
task is sleeping, the task retains `self` and fires on a zombie object.

**Impact:** Screensaver may activate unexpectedly after its manager is torn down.

**Suggested fix:** Use `[weak self]` in the task closure and cancel the task in `deinit`.

---

## 11. Metal Shaders

### Bug 58 — ~~Vertex Shader `vid` Has No Bounds Safety~~ [FIXED] (Medium)

**File:** `Terminal/Renderer/Shaders.metal`

The vertex shader indexes into the instance buffer using `vid` (vertex ID) without
bounds checking. If the draw call specifies more vertices than instances, the shader
reads out-of-bounds GPU memory.

**Impact:** GPU crash or visual artifacts if instance count is miscalculated.

**Verified 2026-10-21:** The shader clamps `vid` before indexing its six-corner array. The draw
loop submits exactly six vertices per instance and uses `cellBuffer.cellCount` as the instance
count. The current shader indexes `cells` by the instance ID, not by `vid`.

---

### Bug 59 — ~~Atlas UV for `GLYPH_INDEX_NONE` Samples Arbitrary Texels~~ [FIXED] (Low)

**File:** `Terminal/Renderer/Shaders.metal`

When a cell has `GLYPH_INDEX_NONE`, the shader still computes UV coordinates and samples
the atlas texture. The glyph entry at index 0 may contain a valid glyph, causing faint
ghost rendering.

**Impact:** Subtle ghost artifacts for empty cells (usually invisible due to alpha).

---

### Bug 60 — ~~Barrel Distortion Shader Produces Edge Artifacts~~ [FIXED] (Medium)

**File:** `Terminal/Renderer/Effects/BarrelDistortion.metal`

The barrel distortion effect does not clamp UV coordinates at the screen edges. Pixels
near the corners sample outside the valid texture region, producing black or wrapped
artifacts.

**Impact:** Visible black fringing at corners when barrel distortion CRT effect is
enabled.

**Suggested fix:** Clamp UV to [0, 1] or return a solid color when UV is out of bounds.

---

### Bug 61 — ~~Gradient Glow Division by Zero~~ [FIXED] (Medium)

**File:** `Terminal/Renderer/Effects/GradientGlow.metal`

The glow intensity computation divides by a distance value that can be zero when the
sample point coincides with the glow source. This produces NaN values that propagate
through the fragment output.

**Impact:** Flickering white or black pixels at glow source positions.

**Suggested fix:** Add an epsilon: `float dist = max(distance(p, source), 0.001);`

---

### Bug 62 — ~~Scanner Sweep Effect Has Angular Discontinuity~~ [FIXED] (Low)

**File:** `Terminal/Renderer/TerminalShaders.metal`

The referenced shader no longer exists. The current scanner moves along the username
with a linear ping-pong position computed from `fract`, with no `atan2` seam. Its settings
preview uses the same ping-pong motion. Source inspection on 2026-10-22 found this
report obsolete; no code change was needed.

---

### Bug 63 — ~~Blink Effect Uses Truncated Pi Constant~~ [FIXED] (Low)

**File:** `Terminal/Renderer/Effects/Blink.metal`

The blink animation uses a hardcoded `3.14159` instead of `M_PI` or `M_PI_F`. The
truncation introduces a tiny phase drift over long durations.

**Impact:** Negligible — blink timing drifts by microseconds per hour.

---

### Bug 64 — ~~CRT Scanline Effect Scrolls With Content~~ [FIXED] (Low)

**File:** `Terminal/Renderer/Effects/CRTScanline.metal`

The CRT scanline overlay is computed from the fragment's Y coordinate in content space
rather than screen space. When the terminal scrolls, the scanlines move with the text
instead of remaining fixed on screen.

**Impact:** Cosmetic — scanlines should be stationary but move with scroll.

---

## 12. UI Layer

### Bug 65 — ~~PromptPreviewRenderer Rainbow Mode Crashes on Empty Segments~~ [FIXED] (High)

**File:** `Views/Settings/PromptPreviewRenderer.swift`

In rainbow color mode, the renderer indexes into the color array using
`index % colors.count`. If the `colors` array is empty (e.g., user configuration error),
this is a division by zero, causing an immediate crash.

**Impact:** Crash when opening prompt settings with an empty color palette configured.

**Suggested fix:** Guard against empty array:
```swift
guard !colors.isEmpty else { return defaultColor }
```

**Fixed 2026-10-21:** The preview uses white when the rainbow palette is empty, matching the
existing shell prompt fallback. Palette lookup is guarded before indexing. Focused tests cover
empty and cycling palettes (2/2 passed); the Debug build passed.

---

### Bug 66 — ~~MatrixScreensaverView Event Monitor Leaks on Every `onAppear`~~ [FIXED] (High)

**File:** `Views/Screensaver/MatrixScreensaverView.swift`

`onAppear` installs a keyboard event monitor via `NSEvent.addLocalMonitorForEvents`.
The returned token is stored in a `@State` variable but is never removed in `onDisappear`.
If the view appears multiple times (e.g., tab switching), monitors accumulate.

**Impact:** Memory leak and increasing CPU cost for keyboard event processing.

**Suggested fix:** Remove the monitor in `onDisappear`:
```swift
.onDisappear {
    if let monitor = keyboardMonitor {
        NSEvent.removeMonitor(monitor)
        keyboardMonitor = nil
    }
}
```

---

### Bug 67 — ~~MatrixScreensaverView Mutates `@State` Inside Canvas `draw` Closure~~ [FIXED] (High)

**File:** `Views/Screensaver/MatrixScreensaverView.swift`

The `Canvas` `draw` closure mutates `@State` properties (column positions, character
arrays) during rendering. SwiftUI's `Canvas` draw closure should be pure — mutations
trigger re-renders, creating an infinite update loop that pegs the CPU.

**Impact:** 100% CPU usage when the Matrix screensaver is active; potential UI freeze.

**Suggested fix:** Move state mutation to a `TimelineView` update callback or a separate
`Timer`-driven update function, and make the `Canvas` closure read-only.

---

### Bug 68 — ~~`pasteClipboardToSession` Pastes to Wrong Session~~ [FIXED] (High)

**File:** `Views/Terminal/TerminalView.swift`

The paste-from-clipboard function uses the *focused* session rather than the session
associated with the view that triggered the paste. In a split-pane layout, if focus
shifts between the context-menu invocation and the paste execution, content is pasted
into the wrong session.

**Impact:** Clipboard content sent to the wrong SSH session — potential security concern
if sessions connect to different hosts.

**Suggested fix:** Capture the target session ID at the time the paste action is created,
not at execution time.

---

### Bug 69 — ~~File Drop Path Escaping Is Incomplete~~ [FIXED] (Medium)

**File:** `Views/Terminal/TerminalView.swift`

Dropped file paths are shell-escaped by wrapping in single quotes, but filenames
containing single quotes themselves (e.g., `it's a file.txt`) break the quoting, leading
to shell injection.

**Impact:** File drops with single quotes in the filename produce broken shell commands;
potential for shell injection if filenames are adversarial.

**Suggested fix:** Escape embedded single quotes:
```swift
let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
return "'\(escaped)'"
```

---

### Bug 70 — ~~`allowLegacyByDefault` Setting Not Persisted~~ [FIXED] (Medium)

**File:** `Views/Settings/SettingsView.swift`

The `allowLegacyByDefault` toggle updates a local `@State` variable but does not write
the value to `UserDefaults` or the settings store. The setting resets on app restart.

**Impact:** User must re-enable the legacy mode toggle every launch.

**Suggested fix:** Bind the toggle to `@AppStorage` or call the settings store's save
method on change.

---

### Bug 71 — ~~GradientBackgroundSettingsView Drops Fourth Color~~ [FIXED] (Medium)

**File:** `Views/Settings/GradientBackgroundSettingsView.swift`

The gradient background supports 4 color stops, but the settings view only reads/writes
3 of them (`color1`, `color2`, `color3`). The fourth color (`color4`) is silently
dropped on save and defaults to black on load.

**Impact:** Users cannot configure the fourth gradient color stop; it always resets to
black.

---

### Bug 72 — ~~`safeTerminalDisplayLines` Uses Array Index as SwiftUI List ID~~ [FIXED] (Medium)

**File:** `UI/Terminal/TerminalSurfaceView.swift`

The affected safety-mode branch was hardcoded off. On 2026-10-22, that unreachable
rendering path and `SafeTerminalRenderedLine` were removed. The supported Metal and
non-Metal terminal paths remain. This eliminates the stale list-ID behavior without
introducing a third renderer identity scheme.

---

### Bug 73 — `copyToClipboard` Always Returns `true` / ~~`statusColor` Uses Fragile String Matching~~ [FIXED] (Low)

**File:** `Views/Settings/CertificateInspectorView.swift`

The `copyToClipboard` function sets the pasteboard content and returns `true`
unconditionally, without checking whether the pasteboard write actually succeeded.

**Impact:** No error handling if clipboard write fails (rare but possible).

---

### Bug 74 — ~~HostsView "Ungrouped" Section Sort Order Not Stable~~ [FIXED] (Low)

**File:** `Views/Hosts/HostsView.swift`

Hosts without a group are displayed in the "Ungrouped" section. The sort order within
this section is not deterministic — it depends on dictionary iteration order, which can
change between app launches.

**Impact:** Ungrouped hosts may shuffle order on each app launch.

---

### Bug 75 — ~~MatrixScreensaverView `charIndex` Can Overflow~~ [FIXED] (Low)

**File:** `Views/Screensaver/MatrixScreensaverView.swift`

The character index counter increments without wrapping. On a 64-bit platform this
takes centuries to overflow, but the value is used in modulo operations where a very
large value has no practical impact.

**Impact:** Theoretical; no practical impact.

---

### Bug 76 — ~~KeyForgeView `importLabel` Not Reset After Successful Import~~ [FIXED] (Low)

**File:** `Views/KeyForge/KeyForgeView.swift`

After a successful key import, the `importLabel` text remains showing the filename of
the imported key. Subsequent visits to the import view show the stale filename.

**Impact:** Confusing UX — user thinks a file is still staged for import.

---

### Bug 77 — ~~KeyForgeView `errorMessage` Read From Non-Main-Actor Context~~ [FIXED] (Low)

**File:** `Views/KeyForge/KeyForgeView.swift`

The `errorMessage` `@State` property is set from an async task that may not be on the
main actor. SwiftUI `@State` must be mutated on the main thread.

**Impact:** Potential runtime warning or undefined behavior under strict concurrency
checking. Usually works in practice due to SwiftUI's internal handling.

---

### Bug 78 — ~~Double `load()` Call in MatrixScreensaver Settings~~ [FIXED] (Low)

**File:** `Views/Settings/SettingsView.swift`

The Matrix screensaver settings panel calls `load()` both in `init` and in `onAppear`,
performing redundant file I/O on the main thread.

**Impact:** Minor redundant work; no functional impact.

---

### Bug 80 — ~~Terminal Copy Is Implemented Twice and Silently Copies a Fallback~~ [FIXED] (Medium)

**Files:** `UI/Terminal/TerminalView.swift` (`copyActiveContentToClipboard`, `copyContentToClipboard`),
`UI/Terminal/ExternalTerminalWindowView.swift` (same two functions), `UI/Terminal/MetalTerminalSessionSurface.swift`
(`TerminalSelectionCoordinator`)

The main window and the pop-out window each have their own copy functions and their own
`TerminalSelectionCoordinator`. The two copies were duplicated rather than shared and have already
drifted: the main window falls back to the unsent input draft, the pop-out window does not. Within
the main window all layouts (single, split, maximized pane, terminal-only) share one copy function,
but each layout branch can build a fresh surface/renderer for the session, and the selection lives
in that renderer.

Both copies also share a silent fallback: when the selection lookup returns nothing, Copy writes
the input draft or the last line of `shellBuffers` (often just the prompt) instead of doing nothing,
so a broken selection lookup looks like "copy copied the wrong thing" rather than failing visibly.

**Impact:** Behaviour differs between windows, fixes must be made twice, and selection failures are
masked. Found while debugging "copy from the terminal does nothing" (2026-10-12).

**Later:** move copy into one shared path used by both windows, and decide whether the fallback
should exist at all (Terminal.app/iTerm2 copy nothing without a selection).

**Progress (2026-10-14, Bug 84 Phase 3):** `TerminalSelectionCoordinator` is deleted. Each window
reads the selection from its `TerminalSurfaceModelStore` (the main window by focused pane), and the
main window's "copy any other visible pane's selection" fallback is gone. Still open: the two
windows' duplicated copy functions, and the draft/last-line fallback. Bug 84 closed 2026-10-15
without changing either.

**Fixed 2026-10-21:** Both windows now call `TerminalSelectionClipboard.copy` with their selected
surface model. Copy writes only nonempty selected text; without a selection it leaves the clipboard
unchanged. The draft and last-line fallbacks were removed. The focused selection tests passed 6/6.

---

### Bug 81 — ~~Terminal Copy Stops Working After a Window Resize~~ [FIXED] (Medium)

**File:** `UI/Terminal/MetalTerminalSessionSurface.swift` (`TerminalSelectionCoordinator.unregister`)

Toggling Maximize Terminal rebuilds the terminal surface (Bug 82; reported as "after resizing the
window", since the toggle resizes the terminal). SwiftUI ran the new surface's `onAppear` (register) before
the old surface's `onDisappear`, and `unregister(sessionID:)` removed the entry by session ID
without checking whose it was — so the old surface deleted the new surface's registration. From then
on every copy route (context menu, Cmd+C) found no surface for the session and wrote nothing, while
the selection stayed visibly highlighted. Confirmed with debug logging on 2026-10-12: `register
model=6dfa49 replacing=dfbdc3`, then 19 ms later `unregister caller=dfbdc3 removing=6dfa49`, then
`lookup found=nil registered=[]`.

**Fix:** `unregister(sessionID:model:)` removes the entry only if it is still that model's (or the
weak reference is dead). Test: `TerminalSelectionInteractionTests.testReplacedSurfaceUnregisteringDoesNotRemoveItsReplacement`.

---

### Bug 82 — ~~Maximize Terminal Rebuilds the Whole Terminal Surface~~ [FIXED] (Medium)

**File:** `UI/Terminal/TerminalView.swift` (`macOSBody`, `sessionPanel`)

Filed as "a window resize rebuilds the surface"; the 2026-10-13 debug log disproved that. Dragging the
window edge (~15 resizes) and entering/leaving full screen all kept the same renderer. The one rebuild
came with no window event and a single layout change, `terminalOnly=false → true`: the Maximize
Terminal toolbar button (or its shortcut), which resizes the terminal and so reads as a resize.

**Cause:** `macOSBody` built the session's `TerminalSurfaceView` at two different places in the view
tree — inside the `sessionPanel` card normally, and a separate copy when maximized (one for the single
layout, one for split panes). SwiftUI keys `@StateObject` state to a view's structural position;
`.id(session.id)` only distinguishes views at the *same* position. Toggling maximize therefore
destroyed the `MetalTerminalSurfaceModel` and its `MetalTerminalRenderer` and built new ones: selection,
smooth-scroll offset, cursor animation and CRT afterglow were lost, all pipelines and the glyph atlas
were rebuilt, and the new renderer briefly requested a grid from its 8×16 placeholder metrics (158×55,
cancelled by the 150 ms resize debounce). It also triggered Bug 81.

**Fix:** `sessionPanel(…, terminalOnly:)` is now the only place the surface is built, in both the
single and split layouts. Maximize hides the header, metadata, search and actions bars and drops the
padding; the surface keeps its slot. It is shown when `terminalOnly || session.state == .connected`,
matching the previous behaviour of each mode. Test:
`TerminalSurfaceIdentityTests.testMaximizeTerminalKeepsTheSameRenderer` hosts the real `TerminalView`
in a window, toggles maximize both ways and asserts the same renderer instance; it failed on both
toggles before the fix.

Other layout changes still rebuild the surface — see Bug 84.

---

### Bug 83 — ~~Audit for Other "Register on Appear, Remove by Key on Disappear" Registries~~ [FIXED] (Low)

Bug 81's pattern — a shared registry keyed by session ID, filled in `onAppear` and cleared by key in
`onDisappear` — breaks whenever SwiftUI rebuilds a view, because the new view's `onAppear` can run
before the old view's `onDisappear`. A first search (2026-10-12) of `.onDisappear`,
`dismantleNSView` and `removeValue(forKey: sessionID)` under `UI/` and `Terminal/` found no other
view-lifecycle instance; the remaining per-session removals (`TerminalHistoryIndex`,
`SessionRecorder`) run on session close, not view disappearance.

**Next:** extend the audit to `Services/` coordinators and AppKit bridges (first-responder and
input-capture state per pane), and check any registry added later against this rule. The Bug 81
registry itself (`TerminalSelectionCoordinator`) was deleted in Bug 84 Phase 3.

**Audited 2026-10-21:** No remaining keyed view-lifecycle registry was found in `UI/`,
`Terminal/`, or the service coordinators. `TerminalInputCaptureView` removes its own AppKit
observer tokens on window changes and deinit. One related shared-state race was found:
`TerminalFileBrowserSidebar.onDisappear` cleared `TransferManager.activeSessionID` even if
`TransfersView` or a replacement sidebar had selected a session. That teardown write was removed;
the visible sidebar and Transfers view still select a session on appearance or change. The Debug
build and `TerminalSurfaceIdentityTests` passed (12/12); the handoff still needs live UI checking.

---

### Bug 84 — ~~Tab Switches and Split Changes Rebuild the Terminal Surface~~ [FIXED] (Medium)

**Files:** `UI/Terminal/TerminalView.swift` (`macOSBody`), `UI/Terminal/SplitNodeView.swift`,
`UI/Terminal/MetalTerminalSessionSurface.swift`

The surface model (and its renderer) is a `@StateObject` of `MetalTerminalSessionSurface`, so it lives
exactly as long as SwiftUI keeps that view's identity. Measured 2026-10-14 (`Docs/Bug84.md` Phase 0
results), with a probe hosting the real `TerminalView` and a live debug log. Every one of these
rebuilds it: a tab switch, including switching back; split, which rebuilds *every* visible session,
not only the one that moved; unsplit, which rebuilds twice, with an interim renderer living
~300 ms; pane maximize and restore; and move to new tab. Each time the selection and scroll state
are lost and the renderer is rebuilt from scratch, costing 50–70 MB of Metal allocations at 2x.
Maximize Terminal (Bug 82) no longer rebuilds. Pop-out builds a second renderer in its own window,
which is expected.

**Progress (2026-10-14):** Phase 2 is merged. The main window owns a `TerminalSurfaceModelStore`,
so tab switch, split, unsplit, pane maximize and move to new tab keep the session's renderer
(`TerminalSurfaceIdentityTests`), and hidden renderers free their drawable-sized textures. Verified
live: the selection, copy and scroll position survive. Phase 3 removed
`TerminalSelectionCoordinator`: copy and select-all read the store's model for the focused pane.
Phase 4 checked the pop-out live and fixed two pop-out leaks: closing a pop-out leaked its
renderer through a callback cycle (`TerminalMetalView.dismantleNSView` now clears the callbacks),
and a pop-out left open on a closed session kept its model.

**Fixed (2026-10-15, Phase 5):** validated live on a relaunched build: selection, copy and scroll
position survive tab switch, split/unsplit and maximize, and split-pane copy targets the right
pane. Hidden renderers cost ~16 MB of Metal (~21 MB footprint) each, so no cap was added. Two
issues found during validation are filed separately: Bug 88 (a tab click in a split layout shows
nothing new) and Bug 89 (a brightness flicker on every tab switch).

**Plan:** `Docs/Bug84.md` — move model ownership out of the view into a per-session store, with the
Bug 81 identity rule for attach/detach.

---

### Bug 85 — ~~A Click Can Leave a One-Cell Selection That Another Click Won't Clear~~ [FIXED] (Medium)

**Files:** `Terminal/Renderer/TerminalMetalView.swift` (`TerminalMTKView`),
`Terminal/Input/TerminalPointerSelection.swift`, `UI/Terminal/MetalTerminalSessionSurface.swift`

Reported 2026-10-13 with a screenshot: after clicking in the terminal a small blue one-cell
rectangle stays highlighted (here in the empty area right of a ping line), and clicking again does
not remove it. Expected (Terminal.app, iTerm2): a plain click never leaves a highlight, and any click
clears an existing selection; a selection only appears once the pointer is dragged.

**Cause (confirmed 2026-10-14 with debug logging on a trackpad):** `TerminalMetalView` attached
single/double/triple `NSClickGestureRecognizer`s and an `NSPanGestureRecognizer` to the `MTKView`.
In ~33 clicks the log recorded 198 pan callbacks and **no** click, double-click or triple-click
callback at all: a trackpad press reports sub-pixel drags (0.0–0.3 pt), the pan began on the first
one and the click recognizers failed. `handleDrag(.began)` selected the clicked cell and `.ended`
kept it, while `handleTap()` (which clears) never ran — so every click moved the one-cell highlight
instead of clearing it. Double-click word selection and triple-click line selection were dead for
the same reason.

**Fix:** the recognizers are gone. `TerminalMTKView` overrides `mouseDown`/`mouseDragged`/`mouseUp`
(forwarding AppKit's `clickCount`, then passing the event up the responder chain as before), and
`TerminalPointerSelection` decides the selection the way Terminal.app does: a single press clears,
a double/triple press selects the word/line, and a drag selects only once the pointer leaves its
start cell (word/line drags extend by word/line). Mouse reporting to TUIs is unaffected — the
`MouseInputCaptureView` overlay still takes the events first when enabled. Tests:
`TerminalPointerSelectionTests` (10: the tracker, the model on a real renderer, and the view
forwarding synthetic `NSEvent`s with their click count and carrying no gesture recognizers).

**Not covered:** a double-click on empty (never-written) cells still selects just the clicked cell,
because word expansion (`TerminalSelectionTextExtractor.isWordCell`) stops at empty cells;
Terminal.app selects the whole blank run. Left as is — it needs a deliberate double-click.

---

### Bug 86 — ~~Colour Emoji Render as Single-Colour Silhouettes; Some Show as `[?]` Boxes~~ [FIXED] (Medium)

**Files:** `Terminal/Renderer/GlyphRasterizer.swift` (`isColorGlyph`, the CTLine slow path),
`Terminal/Renderer/TerminalShaders.metal`; check also `GlyphCache`/atlas colour flags

Seen 2026-10-14 in a screenshot during the Bug 84 Phase 0 atlas fill (`cat` of U+1F300–U+1F5FF in a
local zsh session, macOS 26, 2x). Every emoji rendered as a solid foreground-coloured silhouette
instead of its Apple Color Emoji colours, and many cells showed a boxed `?` instead. CJK, Hangul and
box-drawing in the same output rendered as expected. `GlyphRasterizer` has an explicit colour path:
emoji are rasterized as premultiplied BGRA and flagged as colour glyphs, so the shader should sample
them rather than tint them.

**Cause and fix (2026-10-22):** the rasterizer produced premultiplied color BGRA, but atlas
allocation discarded `isColor` and the fragment shader used only alpha, tinting every glyph with
the terminal foreground. `AtlasEntry` now retains the flag, one unused bit in the packed atlas X
field carries it to Metal, and the shader composites color pixels over the cell background while
ordinary text still uses its foreground color. The range-dump boxes are a separate input issue:
on macOS 26.6.2, all emoji scalars in U+1F300–U+1F5FF have Apple Color Emoji glyphs, while 131
other scalars in the indiscriminate dump have none in that font. `GlyphRasterizerTests` verifies
actual chroma in the rasterized bitmap; `GlyphIndexPackingTests` verifies color and coordinates;
19 focused tests and the Debug build pass. A relaunched-app visual check remains useful.

---

### Bug 87 — ~~Move to New Tab Shows the Remaining Pane's Session, Not the Moved One~~ [FIXED] (Low)

**File:** `UI/Terminal/TerminalView.swift` (`moveToNewTab`, `onChange(of: paneManager.focusedPaneId)`)

`moveToNewTab(paneID:)` calls `paneManager.closePane(paneID)` and then
`tabManager.select(sessionID:)` for the moved session. Closing the pane moves focus to the
remaining pane, and on the next update `onChange(of: paneManager.focusedPaneId)` selects *that*
pane's session, overriding the selection that was just made. Found by
`TerminalSurfaceIdentityTests` during Bug 84 Phase 2: the selected session after the sequence was
A, not the moved B. The user confirmed it live on 2026-10-14: after Move to New Tab, the first tab
is shown.

**Expected:** the moved session's tab is selected. Likely fix: select after the focus change has
been applied, or have the focus handler skip a pane change caused by closing a pane. Test: the
moved session is selected once the layout settles.

**Fixed (2026-10-21):** `PaneTabSelectionCoordinator` skips the focus and tab-selection updates
caused by removing a pane. The moved session remains selected after the layout settles. The
`TerminalSurfaceIdentityTests` regression also checks its renderer is reused.

---

### Bug 88 — ~~In a Split Layout, Clicking a Tab Does Not Show Its Session~~ [FIXED] (Medium)

**Files:** `UI/Terminal/TerminalView.swift` (`macOSBody` split branch, `sessionForPane`),
`UI/Terminal/TerminalSessionTabBar.swift`

Found 2026-10-15 during Bug 84 Phase 5, older than Bug 84. With more than one pane, the terminal
area draws each pane's assigned session (`pane.sessionID`). A tab click only calls
`tabManager.select(sessionID:)`; nothing assigns that session to a pane. So the tab highlights but
both panes keep their sessions; the user saw "only the first 2 are visible, clicking number 9
doesn't show it". Unsplitting shows the selected tab again.

**Expected** (iTerm2 and most split-pane terminals): clicking the tab of a session already in a
pane focuses that pane; otherwise the session replaces the focused pane's session. Fix together
with Bug 87, which is the same interaction between tab selection and
`onChange(of: paneManager.focusedPaneId)`. Test: in a two-pane layout, selecting a third tab shows
it in the focused pane and keeps its renderer.

**Fixed (2026-10-21):** tab selection now focuses an existing pane or assigns the session to the
focused pane, including keyboard selection and a click on an already-selected tab. A hidden
session's renderer is reused when shown again. A targeted hosted-`TerminalView` test covers both
pane assignment and renderer identity.

---

### Bug 89 — ~~Brightness Flicker on Every Tab Switch~~ [FIXED] (Low)

**Files:** `UI/Terminal/MetalTerminalSessionSurface.swift` (`detach`),
`Terminal/Renderer/MetalTerminalRenderer+PostProcessing.swift` (`releaseOffscreenTextures`)

Seen 2026-10-15 during Bug 84 Phase 5, with CRT and bloom enabled. Switching to a tab, including
one already visited, shows a brief change in brightness before the terminal settles. It is not a
blank frame.

**Fixed 2026-10-22:** Detach resets CRT history. The first frame after reattach had zero
phosphor blend, while the next used the brighter pre-CRT scene as history, making static
content brighten. The renderer now samples its current scene as first-frame history and
uses a normal frame interval for that initial blend; it still releases all drawable-sized
textures while hidden. A hosted Metal surface test checks the cold-history frame's
nonzero phosphor uniform, and the 13-test surface suite and Debug build passed. The
user-visible tab-switch flicker still needs a relaunched-app check.

---

### Bug 90 — ~~Shell-Integration Setup Line Is Visible in Remote Bash Sessions~~ [FIXED] (Low)

**Files:** `Terminal/Features/ShellIntegrationScripts.swift`, the code that injects it on connect

Seen 2026-10-15 in a screenshot of four SSH sessions to Ubuntu VMs (bash): each terminal shows the
whole injected line, `if [ -z "$__PROSSH_SHELL_INTEGRATION" ]; then export … trap
'__prossh_debug_trap' DEBUG; printf '\e]133;A\e\\'; fi`, echoed at the prompt. It works (prompt
marks follow), but it clutters the screen and the AI's screen reads (`get_current_screen` returned
it as the session's only history).

**Not yet diagnosed.** Check whether local zsh hides it (ZDOTDIR injection) while remote bash gets
it typed at the prompt, and whether it can be sent with echo suppressed or followed by a clear of
those lines. Expected: no visible setup text, as in iTerm2's shell integration.

Seen again 2026-10-18 on the same four VMs at every login.

**Cause (2026-10-20):** `SessionManager` typed the line into the remote shell 500 ms after
`openShell`, and readline echoed it (five rows at 80 columns). Sent before the prompt it also
appeared twice, once from the tty's canonical echo. It went through `sendRawShellInput`, so the
history index recorded it as a command, and so would a recording; without `ignorespace` it also
landed in bash history.

**Fixed 2026-10-20:** `SessionShellIOCoordinator.injectShellIntegration` sends
`ShellIntegrationScripts.sshInjectionLine(for:token:)` once the shell looks ready (300 ms quiet,
cursor past column 0, primary screen, not a password prompt), recorded nowhere. It sends nothing
after 10 s without a ready prompt, or if the user typed first. The line ends by printing a
private `OSC 7777;PSI;<token>` marker and CR + erase-line; `ShellIntegrationEchoFilter` holds the
output from the send until the marker and drops it. A hold without the marker is released in
order at 16 KB or after 3 s (an empty batch through the parser's stream), and at stream end.
Known limit: with a multi-line prompt the first prompt row shows twice. Not yet run over a live
SSH session; tests: `ShellIntegrationEchoFilterTests` (incl. real local bash and zsh).

---

### Bug 91 — ~~Split Right / Split Down Silently Do Nothing When Every Session Is in a Pane~~ [FIXED] (Low)

**Files:** `UI/Terminal/TerminalView.swift` (`splitNextAvailableSession`),
`UI/Terminal/TerminalKeyboardShortcutLayer.swift`

Seen 2026-10-18 during CredentialPrompt Phase 4 with four SSH sessions in a 2×2 split: the user
picked Split Right and "nothing happens". The menu items (Cmd+D, Cmd+Shift+D) call
`splitNextAvailableSession`, which only moves an open session that is not yet in a pane into a
new pane and returns when there is none. The items stay enabled, so it looks broken.

**Expected:** either disable the items when no unplaced session exists, or split with a new
session (as the pane context menu's "split with new session" does through
`createSessionForNewPane`). Ask the user which before changing it.

**Fixed 2026-10-21:** The user chose to disable the unavailable action. Both keyboard shortcut
buttons are disabled unless the focused pane can split and an open tab is not already shown in a
pane. The action uses the same availability check, so the enabled state and behavior agree.
`PaneManagerTests` covers the available, fully assigned, and depth-limited cases (27/27 passed).

---

### Bug 92 — ~~Copilot File-Tool Internals Are Visible in the Terminal~~ [FIXED] (Low)

**Files:** `Services/AI/AIToolHandler+RemoteExecution.swift` (remote helpers, the not-found
marker), `Services/AI/AIToolHandler+RemotePatch.swift`, `Services/SessionAIToolCoordinator.swift`

Seen 2026-10-18 during CredentialPrompt Phase 4 on testserv-01. The remote file helpers run
through the visible `execute_and_wait` path, so their raw output stays on screen: the
`__PROSSH_PATH_NOT_FOUND__` marker, `apply_patch`'s base64 read of the file
(`aGVsbG8KIyBwcm9zc2ggdGVzdAo=`) and an `ls -l` line. After the not-found marker the prompt was
also drawn twice (`kevin@testserv-01:~$ kevin@testserv-01:~$`). Harmless, but it clutters the
user's terminal and the copilot's own screen reads.

**Cause and fix (2026-10-22):** file helpers used the visible `execute_and_wait` path, whose
captured bytes also fed the terminal parser, history and recorder. They now request an internal
command path: the coordinator captures raw helper output for the tool while only the matching
private completion OSC and the following shell prompt enter the parser. It clears the old prompt
line before the new one, including if a hidden helper times out and its output arrives later.
The normal `execute_and_wait` path and privileged patch retries remain visible so password prompts
are usable. Tests cover split completion markers, real local zsh base64 output, one prompt after
completion, and late output after timeout. Focused suites pass 65/65 and the Debug build passes.
A live SSH file-tool check remains useful.

---

### Bug 93 — Split Panes Overlapped Once After Switching Terminal-Only Mode (Low)

**Files:** `UI/RootTabView.swift` (`columnVisibility` animation),
`UI/Terminal/TerminalView.swift` (`macOSBody`), `Terminal/Renderer/TerminalMetalView.swift`

Seen once, 2026-10-18 01:34, during CredentialPrompt Phase 4 with four SSH sessions in a 2×2
split, broadcast on: the app sidebar and pane header bars came back (terminal-only mode was off)
and the four terminals were drawn overlapping each other. The user described it as "the terminals
jumped".

**Not reproduced.** A Debug build with layout and geometry logging (branch
`debug/terminal-jump`, commit `251e010`, writes `/tmp/prossh-jump.log`) showed that the password
flow causes no layout, focus-mode or size change at all, and that terminal-only mode is switched
only by the toolbar button, Cmd+Shift+F or leaving the Terminal section. Four switches in that
run animated all four terminals through per-frame resizes and settled with Metal frames matching
the SwiftUI pane frames. Most likely the screenshot caught that animation, or a rare bad settle.
If it recurs, run that branch and compare the `swiftui.pane` and `appkit.metal` frames at the
moment it happens.

---

### Bug 94 — ~~Clicking the Reasoning Panel While It Streams Raises an NSRangeException~~ [FIXED] (Low)

**Files:** `UI/Terminal/ReasoningStreamView.swift` (`update(summary:details:)`)

Seen 2026-10-20 during NetworkCopilot Phase 7 run 4 (Opus 5.5, extra high effort): the user
clicked in the chat/reasoning area while the model was thinking, and AppKit logged
`NSRangeException: -[NSBigMutableString _getBlockStart:end:contentsEnd:forRange:stopAtLineSeparators:]:
Range {8053, 14466} out of bounds; string length 8733` from `-[NSTextView mouseDown:]` →
`selectionRangeForProposedRange:granularity:` → `paragraphRangeForRange:`. AppKit caught it; the
app and the copilot turn carried on.

**Not yet diagnosed.** The requested range ends at 22,519 characters, the new text is 8,733 long,
and a new thinking chain had just started after a 13k-token one, so the likely cause is
`update` replacing the text with a shorter chain *during* `mouseDown`'s tracking loop, leaving
AppKit's selection anchor in the old text. `update` clamps the selection it restores, but cannot
reach the anchor AppKit holds while tracking. Unconfirmed: not yet reproduced, and the stack
does not name the text view (the composer is the only other `NSTextView`). To reproduce,
drag-select or triple-click in the reasoning panel as a long chain is replaced by a new one.

**Cause (confirmed 2026-10-20):** as suspected. Main-queue work, SwiftUI's `updateNSView`
included, runs inside `NSTextView.mouseDown`'s tracking loop (`NSEventTrackingRunLoopMode`). A
scratch repro showed AppKit proposing `{25235, -16846}` after a 25k-character text was replaced
by an 8k one mid-drag; character granularity tolerates that, but word and paragraph granularity
raise `NSRangeException` with the crash's exact range.

**Fixed 2026-10-20:** `ReasoningTextView` marks the span of `super.mouseDown`, and
`ReasoningStreamScrollView.update` keeps only the latest update while it lasts, applying it when
the mouse comes up. The panel pauses while the button is held. Test:
`ReasoningStreamViewTests.testChainReplacementDuringClickWaitsForMouseUp` (fails without the fix).

---

### Bug 95 — ~~Local Bash Sessions Get No Shell Integration or Prompt Overlay~~ [FIXED] (Low)

**Files:** `Services/LocalShellBootstrap.swift` (`BASH_ENV`)

Found 2026-10-20 while diagnosing Bug 90. `LocalShellBootstrap` hands bash its overlay rc file
through `BASH_ENV`, but bash reads `BASH_ENV` only for non-interactive shells, so an interactive
local bash would get neither the prompt overlay nor the OSC 133 integration.

**Verified 2026-10-21 in an isolated PTY:** A login interactive Bash (`argv[0] = "-bash"`)
ignored the `BASH_ENV` overlay. Launching with `--rcfile` and `-i` loaded the overlay only when
Bash was not a login shell; that variant stopped loading the login profile. A fix must preserve
normal login-profile behavior. The app's own local Bash UI was not exercised.

**Fixed 2026-10-22:** Local Bash still starts as a login shell. After its prompt is ready,
the app sources a prompt-only overlay through the existing hidden setup-line filter. That
overlay defines the prompt and OSC 133 hooks without sourcing the user's `.bashrc` again.
`BASH_ENV` is no longer set for child scripts. A real local Bash PTY test confirmed login
mode, the configured prompt function, integration, no `BASH_ENV`, and no setup line on
screen or in app command history. The Debug build and 75 focused tests passed. A relaunched
app UI check remains useful.

---

### Bug 96 — ~~Older SFTP Listing Overwrites the Newly Selected Session~~ [FIXED] (Medium)

**File:** `Services/TransferManager.swift` (`refreshDirectory`)

An SFTP directory listing could finish after the active session changed, then replace the new
session's path and entries with results from the old session. A slower older listing could also
clear `isListing` while a newer request was in progress.

**Fixed 2026-10-21:** Each listing has a request ID. Session changes invalidate it; only the
current request for the current session may update results, errors, or the loading state. A
controlled test completes the older request last and confirms the newer session's results remain.
Debug build and `SessionManagerSFTPSidebarTests` passed (4/4).

---

## 13. AppIntents

### Bug 79 — ~~ProSSHShortcuts Uses Wrong `@available` Platform~~ [FIXED] (Medium)

**File:** `AppIntents/ProSSHShortcuts.swift`

The `@available` annotation specifies `iOS 17.0` but the code uses APIs that are
macOS-only (e.g., `NSWorkspace`). On iOS, the shortcut would compile but crash at
runtime when hitting macOS-specific code paths.

**Impact:** Crash on iOS if Shortcuts integration is used. No impact if the target is
macOS-only, but the annotation is misleading and could cause issues if the app is
ported to iOS/Catalyst.

---

## Severity Guide

| Severity | Criteria |
|----------|----------|
| **Critical** | Crash or data loss in normal usage paths |
| **High** | Crash in specific-but-reproducible scenarios, data corruption, security concern |
| **Medium** | Incorrect behavior, resource leak, protocol violation; workaround exists |
| **Low** | Cosmetic issue, theoretical concern, code smell with no observed impact |
