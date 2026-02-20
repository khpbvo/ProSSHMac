# ProSSHMac Bug Report

Comprehensive audit of the ProSSHMac codebase. Bugs are organized by subsystem, numbered
sequentially, and tagged by severity: **Critical**, **High**, **Medium**, or **Low**.

---

## Summary

| Severity | Count |
|----------|-------|
| Critical | 1     |
| High     | 16    |
| Medium   | 30    |
| Low      | 21    |
| **Total**| **68**|

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

### Bug 1 — ForwardConnectionProxy Race Between `connect()` and `disconnect()` (High)

**File:** `SSH/PortForwarding/ForwardConnectionProxy.swift`

The `connected` flag and `channel` are read and written across `connect()`,
`disconnect()`, and `handleData()` without synchronization. If `disconnect()` is called
from one task while `connect()` is running in another, the channel can be closed while
`connect()` still holds a reference to it, or `handleData()` may read from a half-torn-down
channel.

**Impact:** Crash or data corruption during port-forwarding teardown under concurrent
access.

**Suggested fix:** Protect `connected`, `channel`, and the connection lifecycle with an
actor or a serial dispatch queue.

---

### Bug 2 — LibSSHForwardChannel Leaks Resources on Partial `open()` Failure (High)

**File:** `SSH/Channels/LibSSHForwardChannel.swift`

When `open()` succeeds at the SSH level but subsequent configuration (e.g., setting
environment variables or requesting a PTY) fails, the code returns the error without
closing the underlying channel. The SSH channel remains open on the server, consuming
resources until the entire session is torn down.

**Impact:** Resource leak on the remote server; exhaustion of SSH channel slots in
long-running sessions.

**Suggested fix:** Add a `defer` or explicit `close()` call on any failure path after
the channel has been opened.

---

### Bug 3 — LibSSHShellChannel `close()` / `read()` Race (High)

**File:** `SSH/Channels/LibSSHShellChannel.swift`

`close()` sets internal state and frees the channel, but a concurrent `read()` call may
still be blocked waiting for data on that channel handle. On some libssh versions this
causes a use-after-free; on others it returns an opaque error that is silently swallowed.

**Impact:** Potential crash (use-after-free) or silent data loss when closing a shell
channel while reads are in-flight.

**Suggested fix:** Signal the read loop to exit before freeing the channel (e.g., via a
cancellation flag checked inside the read loop, or by using `ssh_channel_request_send_signal`
to interrupt blocking reads).

---

### Bug 4 — LocalShellChannel `waitpid` Blocks the Calling Task (High)

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

### Bug 5 — SSHTransport `normalizeRemotePath` Does Not Handle `..` Components (Medium)

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

### Bug 6 — `cfErrorMessage` Uses `takeRetainedValue` Unsafely (Medium)

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

### Bug 7 — LocalShellChannel `strdup` Memory Not Freed on Failure Path (Low)

**Files:** `SSH/Channels/LocalShellChannel.swift`, `Services/Session/LocalShellChannel.swift`

In `spawn()`, `strdup` is called to build the `argv` array for `execvp`. If `fork()`
fails or the function returns early, the `strdup`'d strings are never freed.

**Impact:** Minor memory leak on fork failure (rare in practice).

**Suggested fix:** Free the `strdup`'d strings in a `defer` block, or use
`withUnsafePointer`-based patterns that don't require manual deallocation.

---

### Bug 8 — LocalShellChannel `ioctl` Called From Async Context Without Isolation (Low)

**File:** `Services/Session/LocalShellChannel.swift`

`ioctl(fd, TIOCSWINSZ, &winsize)` is called inside an `async` method. While `ioctl`
with `TIOCSWINSZ` is fast and non-blocking, it is not formally safe to call from a
Swift Concurrency context without explicit thread isolation.

**Impact:** Theoretical data-race under strict concurrency checking; no practical impact
observed.

---

## 2. Services & Storage

### Bug 9 — EncryptedStorage Deletes Legacy Keychain Item Before Verifying Migration (High)

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

---

### Bug 10 — CertificateAuthorityService Non-Atomic Save Can Corrupt CA Store (High)

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

---

### Bug 11 — CertificateAuthorityService Deleting a CA Orphans Its Secure Enclave Key (Medium)

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

---

### Bug 12 — CertificateAuthorityService `generateCertificate` Discards Extension Values (Medium)

**File:** `Services/Security/CertificateAuthorityService.swift`

When generating a certificate, the code collects extension OIDs from user configuration
but does not pass through extension *values* (critical flag, data). The resulting
certificate has extensions with empty or default values rather than the user-specified
content.

**Impact:** Certificates generated with custom extensions (e.g., `extendedKeyUsage`) will
not contain the intended extension data.

**Suggested fix:** Pass extension values (not just OIDs) through the certificate
generation pipeline.

---

### Bug 13 — KnownHostEntry `id` Collides When Same Host Has Multiple Key Types (Medium)

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

### Bug 14 — FileKnownHostsStore Uses `NSLock` Inside Async Context (Medium)

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

### Bug 15 — SecureEnclaveKeyManager Force-Casts `SecKey` Query Result (Medium)

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

### Bug 16 — TransferManager `cancelTransfer` Does Not Cancel In-Flight Network I/O (Medium)

**File:** `SSH/Transport/TransferManager.swift`

`cancelTransfer()` sets the transfer's state to `.cancelled` but does not cancel the
underlying `Task` or network operation. The SFTP read/write loop continues until it
naturally completes or errors out.

**Impact:** Cancelled transfers continue consuming bandwidth and SSH channel resources
until they finish on their own.

**Suggested fix:** Store the `Task` handle and call `.cancel()` on it, and check
`Task.isCancelled` in the transfer loop.

---

### Bug 17 — EncryptedStorage Backup Filename Collision (Medium)

**File:** `Services/Security/EncryptedStorage.swift`

Backup filenames use a date formatter with second precision. Two backups created within
the same second overwrite each other.

**Impact:** Data loss when rapid successive backups are triggered (e.g., by automated
migration code).

**Suggested fix:** Append a UUID or use sub-second timestamp precision.

---

### Bug 18 — BiometricPasswordStore Returns Confusing "not found" Error on Auth Failure (Low)

**File:** `Services/Security/BiometricPasswordStore.swift`

When biometric authentication fails (user cancels, Face ID not recognized), the error
propagated is "password not found" rather than the actual `LAError`. This makes it
impossible for callers to distinguish between a missing password and a failed biometric
challenge.

**Impact:** Confusing error messages; callers cannot implement "retry biometrics" logic.

**Suggested fix:** Propagate the `LAError` directly and only return "not found" when
the Keychain item genuinely does not exist.

---

### Bug 19 — KnownHostsStore Debug `print()` Statements Left in Production Code (Low)

**File:** `Services/Security/KnownHostsStore.swift`

Several `print()` calls are present in the known-hosts parsing and lookup code. These
write to stdout in release builds.

**Impact:** Information leakage (hostnames and key fingerprints written to console log);
minor performance overhead.

**Suggested fix:** Remove the `print()` calls or replace with `os_log` at `.debug` level.

---

## 3. Session Management

### Bug 20 — `restartLocalSession` Uses Stale Working Directory (Medium)

**File:** `Services/Session/SessionManager.swift`

When restarting a local shell session, the original `host.defaultDirectory` is used
instead of the shell's current working directory at the time of restart. If the user
`cd`'d to a different directory, the restarted session opens in the wrong location.

**Impact:** User loses their working directory context on session restart.

**Suggested fix:** Track the terminal's current working directory (via OSC 7 or similar)
and use it as the restart directory.

---

### Bug 21 — `applicationDidEnterBackground` Matches Sessions by `host.id` Instead of `session.id` (Medium)

**File:** `Services/Session/SessionManager.swift`

Background handling iterates sessions and indexes them by `host.id`. If multiple sessions
share the same host, they map to the same key, and all but one are silently dropped from
the background-tracking dictionary.

**Impact:** On backgrounding, only one session per host is properly managed; others may
be killed or fail to reconnect.

**Suggested fix:** Key the dictionary by `session.id` instead of `host.id`.

---

### Bug 22 — `removeSession` Performs Double Cleanup (Low)

**File:** `Services/Session/SessionManager.swift`

`removeSession()` calls both `session.disconnect()` and then removes the session from
the active list. But the `disconnect()` method itself may trigger a delegate callback
that also calls `removeSession()`, causing a double-remove. The second call is harmless
(the session is already gone) but wastes cycles and logs spurious warnings.

**Impact:** Spurious log noise; no functional impact.

---

### Bug 23 — `reconnectTask` Captures `nil` Window Reference (Low)

**File:** `Services/Session/SessionManager.swift`

The reconnection task captures `self.window` at creation time. If the window is dismissed
before reconnection completes, the task holds a nil/stale window reference and the
reconnected session has no associated window.

**Impact:** Reconnected session may not appear in any window after the original window
is closed.

---

## 4. Models & Data

### Bug 24 — Host `portForwardingRules` Encode/Decode Asymmetry (High)

**File:** `Models/Host.swift`

`encode(to:)` encodes `portForwardingRules` as a nested keyed container, but `init(from:)`
decodes it as a flat array with `decodeIfPresent([PortForwardingRule].self)`. A Host
encoded by the current code cannot be decoded by the same code.

**Impact:** Port forwarding rules are silently lost on round-trip through Codable (e.g.,
saving and re-loading from disk, iCloud sync).

**Suggested fix:** Make encode and decode use the same format — either both use the flat
array or both use the nested container.

---

### Bug 25 — Host `legacyModeEnabled` / `tags` Break Backward Compatibility (Medium)

**File:** `Models/Host.swift`

These properties are encoded unconditionally but older versions of the app do not know
about them. Loading a newer config file in an older app version will fail to decode
(or silently drop the properties, depending on decoder settings).

**Impact:** Downgrading the app or syncing config between app versions may lose host
configuration.

**Suggested fix:** Use `encodeIfPresent` and `decodeIfPresent` with sensible defaults
for forward/backward compatibility.

---

### Bug 26 — Session Decoder Not Forward-Compatible (Medium)

**File:** `Models/Session.swift`

The `Session` decoder uses `decode` (not `decodeIfPresent`) for several fields that
may not exist in older stored data. If a stored session was created by an older app
version missing these fields, decoding fails and the session is lost.

**Impact:** Loss of saved sessions on app update.

**Suggested fix:** Use `decodeIfPresent` with defaults for all fields that were added
after the initial release.

---

### Bug 27 — Host Jump-Host Validation Does Not Detect Cycles (Low)

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

### Bug 28 — CertificateAuthorityModel `nextSerialNumber` Can Overflow (Low)

**File:** `Models/CertificateAuthorityModel.swift`

`nextSerialNumber` is an `Int` that is incremented on each certificate issuance. On 64-bit
platforms this is effectively unlimited, but the value is never validated against the X.509
serial number field's constraints (which require a positive integer up to 20 octets per
RFC 5280).

**Impact:** Theoretical; only relevant after issuing > 2^63 certificates.

---

### Bug 29 — Transfer `bytesTransferred` Can Exceed `totalBytes` (Low)

**File:** `Models/Transfer.swift`

Progress updates set `bytesTransferred` from raw byte counts without clamping. If the
underlying transport reports more bytes than the file size (e.g., due to a race between
size query and transfer, or resumed transfers), `bytesTransferred > totalBytes` and
progress bars render incorrectly (> 100%).

**Impact:** Cosmetic — progress bar overflow.

**Suggested fix:** Clamp: `bytesTransferred = min(bytes, totalBytes)`

---

## 5. Terminal Grid & Reflow

### Bug 30 — Snapshot Double-Buffer Can Share Storage With Live Snapshot (High)

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

### Bug 31 — Wide Character at Last Column Creates Orphaned Half-Width Cell (High)

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

### Bug 32 — `printASCIIBytesBulk` Returns Prematurely in Insert Mode (High)

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

### Bug 33 — GridReflow Marks All Screen Rows as `isWrapped: false` (Medium)

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

### Bug 34 — GridReflow Cursor Tracking Misses One-Past-End Position (Medium)

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

### Bug 35 — `TerminalGrid.resize` Reflows Primary Buffer With Alternate-Screen Cursor (Medium)

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

### Bug 36 — ScrollbackBuffer `subscript` Has No Bounds Check (Medium)

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

### Bug 37 — `printASCIIBytesBulk` Sets `lastPrintedChar` to Unmapped Byte (Low)

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

### Bug 38 — OSC 4 Only Handles First Color Pair in Multi-Pair Sequences (Low)

**File:** `Terminal/Parser/OSCHandler.swift`, lines 122–145

OSC 4 can set multiple palette colors in one sequence:
`OSC 4 ; idx1 ; color1 ; idx2 ; color2 ST`. The code uses
`text.split(separator: ";", maxSplits: 1)`, so only the first pair is parsed.

**Impact:** Applications that set multiple palette colors in a single OSC 4 (e.g., theme
configuration) only get the first color applied.

**Suggested fix:** Parse all pairs in a loop, advancing two parts at a time.

---

### Bug 39 — DCSHandler DECRQSS Check Uses `contains` Instead of Equality (Low)

**File:** `Terminal/Parser/DCSHandler.swift`, lines 64–69

The DECRQSS routing checks `intermediates.contains(0x24)` (`$`) rather than
`intermediates == [0x24]`. If a future DCS sequence has `$` anywhere in its
intermediates, it will be incorrectly routed to the DECRQSS handler.

**Impact:** No current conflict, but fragile for future DCS handler additions.

---

## 7. Terminal Input

### Bug 40 — Mouse Coordinate 0-Based vs 1-Based Mismatch (Medium)

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

### Bug 41 — KeyEncoder `encodeBackspace` Ignores Ctrl When Alt Is Held (Low)

**File:** `Terminal/Input/KeyEncoder.swift`, lines 217–225

Alt+Ctrl+Backspace and Alt+Backspace (with `backspaceSendsDelete = true`) both produce
`ESC 0x7F`. The Ctrl modifier is effectively ignored when combined with Alt. The behavior
happens to be correct by accident for the common case, but the code path is inconsistent.

**Impact:** Very low — no incorrect behavior in practice for standard configurations.

---

## 8. Terminal Renderer

### Bug 42 — GlyphAtlas `rowHeight` Not Reset When Starting a New Row (Medium)

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

### Bug 43 — RendererPerformanceMonitor Is Not Thread-Safe (High)

**File:** `Terminal/Renderer/RendererPerformanceMonitor.swift`

The performance monitor stores frame times in arrays that are read and written from
both the render thread and the main thread without synchronization. Concurrent access
to Swift arrays is undefined behavior and can cause crashes.

**Impact:** Intermittent crashes during rendering, especially on high-refresh-rate
displays.

**Suggested fix:** Make the monitor an actor, or protect its mutable state with a lock.

---

### Bug 44 — RendererPerformanceMonitor Uses Quadratic `removeFirst()` (Medium)

**File:** `Terminal/Renderer/RendererPerformanceMonitor.swift`

Frame-time history is stored in an `Array`. When the history exceeds its limit,
`removeFirst()` is called, which is O(n) for Array. Over time, this causes increasing
CPU overhead in the render loop.

**Impact:** Performance degradation proportional to history size; minor on short
histories but avoidable.

**Suggested fix:** Use a ring buffer or `Deque` instead of Array.

---

## 9. Terminal Features & Pane Management

### Bug 45 — PaneManager `syncSessions` Mutates Collection During Iteration (High)

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

### Bug 46 — PaneManager `restoreMaximizedPane` Discards Pending Layout Changes (Medium)

**File:** `Terminal/Features/PaneManager.swift`

When un-maximizing a pane, the saved layout is restored but any panes added or removed
while maximized are discarded. The tree reverts to the pre-maximization state.

**Impact:** Panes opened while another pane was maximized silently disappear on
un-maximize.

---

### Bug 47 — PaneManager Force-Unwraps During `restoreLayout` (High)

**File:** `Terminal/Features/PaneManager.swift`

`restoreLayout()` force-unwraps optional lookups (`panes[id]!`) when rebuilding the
tree from saved state. If the saved layout references a pane ID that no longer exists
(e.g., session ended during background), the app crashes.

**Impact:** Crash on layout restore with stale pane references.

**Suggested fix:** Use `guard let` with fallback behavior (skip missing panes).

---

### Bug 48 — SessionTabManager `Dictionary(uniqueKeysWithValues:)` Crashes on Duplicate IDs (High)

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

### Bug 49 — SessionRecorder Performs File I/O on Main Thread (High)

**File:** `Terminal/Features/SessionRecorder.swift`

Recording writes (`append` to file) are performed synchronously on the main actor. For
large sessions or slow storage, this blocks the UI.

**Impact:** UI stutters during session recording, especially on iOS devices with flash
contention.

**Suggested fix:** Move file I/O to a background actor or dispatch queue.

---

### Bug 50 — SessionRecorder Playback Has No Cancellation Support (Medium)

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

### Bug 51 — QuickCommands `replacingVariables` Causes Out-of-Range Crash (Critical)

**File:** `Terminal/Features/QuickCommands.swift`

`replacingVariables` uses `String.Index` from one string to subscript another. When a
variable is replaced with a value of different length, the indices become invalid for the
mutated string, causing an out-of-range crash.

**Impact:** Crash when executing any quick command that contains variables and the
replacement value differs in length from the placeholder.

**Suggested fix:** Process replacements in reverse order (from end of string to start),
or rebuild the string from scratch using ranges computed on the original string.

---

### Bug 52 — QuickCommandVariable Uses `name` as `id` Allowing Collisions (Low)

**File:** `Terminal/Features/QuickCommands.swift`

`QuickCommandVariable` conforms to `Identifiable` with `id` computed from `name`. Two
variables with the same name but different default values or types are treated as the
same variable in SwiftUI lists.

**Impact:** Variable list may render incorrectly if duplicate names exist.

---

### Bug 53 — TerminalSearch Range Validation Is Fragile (Low)

**File:** `Terminal/Features/TerminalSearch.swift`

Search result ranges are computed against a snapshot of terminal content but applied to
the live terminal state. If content scrolls between search and highlight, the ranges
may be invalid.

**Impact:** Incorrect highlight positions after terminal content changes during search.

---

## 10. Terminal Effects

### Bug 54 — LinkDetector Fails on Wikipedia-Style URLs With Parentheses (Medium)

**File:** `Terminal/Effects/LinkDetector.swift`

The URL regex does not account for balanced parentheses in URLs. Wikipedia URLs like
`https://en.wikipedia.org/wiki/Foo_(bar)` have the closing `)` stripped because the
regex treats it as sentence-ending punctuation.

**Impact:** Wikipedia and similar URLs are truncated when clicked or displayed.

**Suggested fix:** Add balanced-parenthesis handling to the URL regex, or use a
dedicated URL parser that handles RFC 3986 correctly.

---

### Bug 55 — LinkDetector False Positives on File Paths (Medium)

**File:** `Terminal/Effects/LinkDetector.swift`

The file-path detection regex matches too broadly. Patterns like `v1.2.3/changelog` or
`usr/bin/env` are detected as clickable file paths even when they are not actual paths
in context.

**Impact:** Spurious link highlights in terminal output; clicking them opens error
dialogs or wrong files.

---

### Bug 56 — IdleScreensaverManager Never Removes Event Monitors (High)

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

### Bug 57 — IdleScreensaverManager Timer Task May Outlive Manager (Low)

**File:** `Terminal/Effects/IdleScreensaverManager.swift`

The idle timer is a `Task` that captures `self`. If the manager is deallocated while the
task is sleeping, the task retains `self` and fires on a zombie object.

**Impact:** Screensaver may activate unexpectedly after its manager is torn down.

**Suggested fix:** Use `[weak self]` in the task closure and cancel the task in `deinit`.

---

## 11. Metal Shaders

### Bug 58 — Vertex Shader `vid` Has No Bounds Safety (Medium)

**File:** `Terminal/Renderer/Shaders.metal`

The vertex shader indexes into the instance buffer using `vid` (vertex ID) without
bounds checking. If the draw call specifies more vertices than instances, the shader
reads out-of-bounds GPU memory.

**Impact:** GPU crash or visual artifacts if instance count is miscalculated.

---

### Bug 59 — Atlas UV for `GLYPH_INDEX_NONE` Samples Arbitrary Texels (Low)

**File:** `Terminal/Renderer/Shaders.metal`

When a cell has `GLYPH_INDEX_NONE`, the shader still computes UV coordinates and samples
the atlas texture. The glyph entry at index 0 may contain a valid glyph, causing faint
ghost rendering.

**Impact:** Subtle ghost artifacts for empty cells (usually invisible due to alpha).

---

### Bug 60 — Barrel Distortion Shader Produces Edge Artifacts (Medium)

**File:** `Terminal/Renderer/Effects/BarrelDistortion.metal`

The barrel distortion effect does not clamp UV coordinates at the screen edges. Pixels
near the corners sample outside the valid texture region, producing black or wrapped
artifacts.

**Impact:** Visible black fringing at corners when barrel distortion CRT effect is
enabled.

**Suggested fix:** Clamp UV to [0, 1] or return a solid color when UV is out of bounds.

---

### Bug 61 — Gradient Glow Division by Zero (Medium)

**File:** `Terminal/Renderer/Effects/GradientGlow.metal`

The glow intensity computation divides by a distance value that can be zero when the
sample point coincides with the glow source. This produces NaN values that propagate
through the fragment output.

**Impact:** Flickering white or black pixels at glow source positions.

**Suggested fix:** Add an epsilon: `float dist = max(distance(p, source), 0.001);`

---

### Bug 62 — Scanner Sweep Effect Has Angular Discontinuity (Low)

**File:** `Terminal/Renderer/Effects/ScannerSweep.metal`

The sweep angle is computed with `atan2` which has a discontinuity at ±π. The sweep
animation jumps when crossing the -π/+π boundary.

**Impact:** Visible "seam" in the scanner sweep animation at one angle.

---

### Bug 63 — Blink Effect Uses Truncated Pi Constant (Low)

**File:** `Terminal/Renderer/Effects/Blink.metal`

The blink animation uses a hardcoded `3.14159` instead of `M_PI` or `M_PI_F`. The
truncation introduces a tiny phase drift over long durations.

**Impact:** Negligible — blink timing drifts by microseconds per hour.

---

### Bug 64 — CRT Scanline Effect Scrolls With Content (Low)

**File:** `Terminal/Renderer/Effects/CRTScanline.metal`

The CRT scanline overlay is computed from the fragment's Y coordinate in content space
rather than screen space. When the terminal scrolls, the scanlines move with the text
instead of remaining fixed on screen.

**Impact:** Cosmetic — scanlines should be stationary but move with scroll.

---

## 12. UI Layer

### Bug 65 — PromptPreviewRenderer Rainbow Mode Crashes on Empty Segments (High)

**File:** `Views/Settings/PromptPreviewRenderer.swift`

In rainbow color mode, the renderer indexes into the color array using
`index % colors.count`. If the `colors` array is empty (e.g., user configuration error),
this is a division by zero, causing an immediate crash.

**Impact:** Crash when opening prompt settings with an empty color palette configured.

**Suggested fix:** Guard against empty array:
```swift
guard !colors.isEmpty else { return defaultColor }
```

---

### Bug 66 — MatrixScreensaverView Event Monitor Leaks on Every `onAppear` (High)

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

### Bug 67 — MatrixScreensaverView Mutates `@State` Inside Canvas `draw` Closure (High)

**File:** `Views/Screensaver/MatrixScreensaverView.swift`

The `Canvas` `draw` closure mutates `@State` properties (column positions, character
arrays) during rendering. SwiftUI's `Canvas` draw closure should be pure — mutations
trigger re-renders, creating an infinite update loop that pegs the CPU.

**Impact:** 100% CPU usage when the Matrix screensaver is active; potential UI freeze.

**Suggested fix:** Move state mutation to a `TimelineView` update callback or a separate
`Timer`-driven update function, and make the `Canvas` closure read-only.

---

### Bug 68 — `pasteClipboardToSession` Pastes to Wrong Session (High)

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

### Bug 69 — File Drop Path Escaping Is Incomplete (Medium)

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

### Bug 70 — `allowLegacyByDefault` Setting Not Persisted (Medium)

**File:** `Views/Settings/SettingsView.swift`

The `allowLegacyByDefault` toggle updates a local `@State` variable but does not write
the value to `UserDefaults` or the settings store. The setting resets on app restart.

**Impact:** User must re-enable the legacy mode toggle every launch.

**Suggested fix:** Bind the toggle to `@AppStorage` or call the settings store's save
method on change.

---

### Bug 71 — GradientBackgroundSettingsView Drops Fourth Color (Medium)

**File:** `Views/Settings/GradientBackgroundSettingsView.swift`

The gradient background supports 4 color stops, but the settings view only reads/writes
3 of them (`color1`, `color2`, `color3`). The fourth color (`color4`) is silently
dropped on save and defaults to black on load.

**Impact:** Users cannot configure the fourth gradient color stop; it always resets to
black.

---

### Bug 72 — `safeTerminalDisplayLines` Uses Array Index as SwiftUI List ID (Medium)

**File:** `Views/Terminal/TerminalView.swift`

Terminal display lines are identified by their array index in a `ForEach`. When lines are
inserted or removed (scrolling), SwiftUI reuses cell views incorrectly because the IDs
shift. This causes visual glitches and incorrect cell recycling.

**Impact:** Visual glitches in the terminal display — lines may flicker or show stale
content during scroll.

**Suggested fix:** Use a stable identifier (e.g., line number or content hash) instead of
array index.

---

### Bug 73 — `copyToClipboard` Always Returns `true` (Low)

**File:** `Views/Settings/CertificateInspectorView.swift`

The `copyToClipboard` function sets the pasteboard content and returns `true`
unconditionally, without checking whether the pasteboard write actually succeeded.

**Impact:** No error handling if clipboard write fails (rare but possible).

---

### Bug 74 — HostsView "Ungrouped" Section Sort Order Not Stable (Low)

**File:** `Views/Hosts/HostsView.swift`

Hosts without a group are displayed in the "Ungrouped" section. The sort order within
this section is not deterministic — it depends on dictionary iteration order, which can
change between app launches.

**Impact:** Ungrouped hosts may shuffle order on each app launch.

---

### Bug 75 — MatrixScreensaverView `charIndex` Can Overflow (Low)

**File:** `Views/Screensaver/MatrixScreensaverView.swift`

The character index counter increments without wrapping. On a 64-bit platform this
takes centuries to overflow, but the value is used in modulo operations where a very
large value has no practical impact.

**Impact:** Theoretical; no practical impact.

---

### Bug 76 — KeyForgeView `importLabel` Not Reset After Successful Import (Low)

**File:** `Views/KeyForge/KeyForgeView.swift`

After a successful key import, the `importLabel` text remains showing the filename of
the imported key. Subsequent visits to the import view show the stale filename.

**Impact:** Confusing UX — user thinks a file is still staged for import.

---

### Bug 77 — KeyForgeView `errorMessage` Read From Non-Main-Actor Context (Low)

**File:** `Views/KeyForge/KeyForgeView.swift`

The `errorMessage` `@State` property is set from an async task that may not be on the
main actor. SwiftUI `@State` must be mutated on the main thread.

**Impact:** Potential runtime warning or undefined behavior under strict concurrency
checking. Usually works in practice due to SwiftUI's internal handling.

---

### Bug 78 — Double `load()` Call in MatrixScreensaver Settings (Low)

**File:** `Views/Settings/SettingsView.swift`

The Matrix screensaver settings panel calls `load()` both in `init` and in `onAppear`,
performing redundant file I/O on the main thread.

**Impact:** Minor redundant work; no functional impact.

---

## 13. AppIntents

### Bug 79 — ProSSHShortcuts Uses Wrong `@available` Platform (Medium)

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
