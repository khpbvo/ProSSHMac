# Release readiness (F0) — fixed dependencies, a CI that can fail, a notarized 0.10.0 that updates itself

Planning input: `Docs/The big picture(October 2026).md`, F0. Spec written 2026-10-24 from
`f6846bc`; every "today" fact below was checked against that commit on that date.

## Overview

**Why first.** People who installed the DMG are running February's 0.9.0, and nothing tells
them a newer build exists. Both vendored crypto libraries are behind on security fixes, and
OpenSSL 3.4 went out of upstream support on 2026-10-22. Local port forwards listen on every
network interface (Bug 97). The CI job reports success whatever happens (Bug 105). Every
later feature ships through this pipeline, so it comes first.

**Today (verified 2026-10-24):**

| Area | State | Evidence |
|---|---|---|
| libssh | **0.12.0**, static, universal (arm64 + x86_64), minos 13.0. OpenSSL backend, zlib, SFTP and PCAP on; server, GSSAPI and FIDO2 off | `Vendor/libssh/.../Headers/libssh/libssh_version.h:30-32`; `nm` (no `ssh_bind_new`, no `gss_*`/`fido_*` imports) |
| OpenSSL | **3.4.1** (11 Feb 2025), static, universal, minos 26.0, built against the 26.2 SDK | `opensslv.h:77`; `strings libcrypto.a` |
| Vendor build | **No script in this repo.** The binaries were built in the sibling `~/Desktop/ProSSHV2` checkout by `scripts/build-openssl-ios.sh` and `scripts/build-libssh-ios.sh` from pre-downloaded sources, with no version pins or checksums. Only the macOS slice directories were copied here (no xcframework `Info.plist`); the project links them through `HEADER_SEARCH_PATHS`/`LIBRARY_SEARCH_PATHS` and `-lssh -lcrypto -lssl -lz`. **Phase 3 added `scripts/build-vendor.sh`**; Phase 3 also found today's libcrypto C code unoptimized and carrying ProSSHV2 paths | `project.pbxproj:342-363`; ProSSHV2 scripts |
| Port forwards | `NWListener(using: .tcp, on: port)` with no local endpoint or interface: listens on all interfaces (Bug 97, not yet reproduced). **Phase 1 fixed it**; Phase 1 also found that forwards never carry data (Bug 109, **fixed in Phase 1b**) | `Services/PortForwardingManager.swift:49-57` |
| CI | `macos-15`, Xcode 26.2, both steps end in `\| xcpretty --color \|\| true` (Bug 105, **fixed in Phase 2**: `xcode-27`, Xcode 27.1, pipefail, unsigned build, 42 targeted suites) | `.github/workflows/ci.yml` |
| Signing | Hardened runtime on, sandbox off, team `KPHHFS89HZ`. Entitlements: `keychain-access-groups`, user-selected files. **No "Developer ID Application" identity in this Mac's keychain**, only Apple Development | `project.pbxproj:331-338`; `security find-identity -v -p codesigning` |
| Releases | One: v0.9.0, pre-release, 2026-02-26. Its DMG is **unsigned and not notarized** (`codesign -dv`: not signed; `spctl`: rejected; no stapled ticket) | `gh release view v0.9.0` |
| Packaging | `scripts/create-dmg.sh` archives, and with `--sign` exports Developer ID, notarizes (`notarytool`), staples and signs the DMG. The signed path has never produced a release | `scripts/create-dmg.sh` |
| Version | `MARKETING_VERSION = 0.9.0`, `CURRENT_PROJECT_VERSION = 1`, generated Info.plist | `project.pbxproj:334-356` |
| Auto-update | None. No Swift packages at all | `project.pbxproj` (no `XCRemoteSwiftPackageReference`) |
| Settings text | "System follows iOS." and "Secure Enclave integration coming in KeyForge/CertAuthority phases." (Bug 107, **fixed in Phase 1**) | `UI/Settings/SettingsView.swift:41, 347` |

**Upstream, checked 2026-10-24 (re-check at the phase that uses it):**

- libssh **0.12.2** (2026-07-28) is current. 0.12.1 was a security release; 0.12.2 completes
  the fix for CVE-2026-59843 (denial of service through a zero channel packet size). The
  planning doc lists the client-relevant 0.12.1/0.12.2 fixes.
- OpenSSL **3.5 LTS**, supported until 2030-04-08. The newest patch found is **3.5.8**
  (2026-08-25). OpenSSL 4 exists, but 3.5 is the LTS line and the planning doc's choice.
  **Phase 3 correction:** 3.5.9 (2026-09-29, a security release, most severe High) is newer,
  and is the one pinned.
- Sparkle **2.10.0** (2026-09-13) is current.
- GitHub's hosted **`xcode-27`** image (preview) runs macOS 27.0.1 with **Xcode 27.1
  (27A9275) as default**, our exact toolchain, plus 27.0 and a 27.2 release candidate. It ships
  CMake, Ninja and Perl. The Metal Toolchain component is not listed in its readme. The plain
  `macos-26` image has only Xcode 26.x. **Phase 2 correction:** the image readme (20261012)
  lists Xcode **27.0** as default, with 27.1 at `/Applications/Xcode_27.1.app`. The workflow
  selects 27.1 explicitly, and the Metal Toolchain was already installed.

**Decisions (the user, 2026-10-24):**

1. **0.10.0 ships signed with Developer ID and notarized.** The user obtains the certificate
   before Phase 6.
2. **The vendor build leaves FIDO2 and GSSAPI off**, the same feature set as today. F18/F19
   will add a dependency build to the script later.
3. **CI runs on GitHub's hosted `xcode-27` image.** It's a preview; if it proves unusable, stop
   and ask rather than switching to a self-hosted runner.

**Affected files (expected):** `Services/PortForwardingManager.swift`,
`ProSSHMacTests/Terminal/Tests/PortForwardingManagerTests.swift`, `UI/Settings/SettingsView.swift`,
`.github/workflows/ci.yml`, new `scripts/build-vendor.sh`, `Vendor/**` (binaries and headers),
new `Vendor/VERSIONS.md`, `ProSSHMac.xcodeproj/project.pbxproj` (Sparkle package, versions),
`ProSSHMacApp.swift` or `App/` (updater), a partial Info.plist for Sparkle keys,
`scripts/create-dmg.sh`, new `appcast.xml` (location decided in Phase 5), `README.md`,
`CONTRIBUTING.md`, `SECURITY.md`, `Docs/bugs.md`, `CLAUDE.md`.

## Rules for every phase

- **Reproduce before fixing** (Bug 97 by `lsof`). Bugs 97, 105 and 107 were found by reading.
- **Nothing outward-facing without the user's go-ahead in that session:** pushing a tag,
  creating or editing a GitHub release, uploading assets, publishing the appcast, changing
  repository settings. Approval for one doesn't carry to the next.
- **Secrets never enter the repo or a log:** the Sparkle EdDSA private key, notarization
  credentials, certificates. Scripts read them from the keychain or the environment.
- **The vendor build must be rebuildable from this repo alone:** pinned versions, pinned
  SHA-256 checksums, one command. "Reproducible" here means anyone can rebuild the same versions
  with the same options. Static archives embed timestamps, so output bytes won't match.
- **Sparkle never runs under XCTest or a benchmark launch.** Tests are hosted in the app, and the
  benchmark scripts launch it dozens of times; an update check or the "check automatically?"
  prompt there costs network time and a modal window.

## Phases

- [x] **Phase 1: Loopback-only forwards (Bug 97) and the stale Settings text (Bug 107).**
  Done 2026-10-24; results under "Phase 1 results" below.
  - Reproduce first: a temporary loopback `sshd` (the Bug 3 method in `Docs/featurelist.md`), a
    host with one forward rule, then `lsof -nP -iTCP:<port> -sTCP:LISTEN`. Record the output.
    Expect `*:<port>`.
  - Bind each listener to loopback only, IPv4 and IPv6, as OpenSSH does for `localhost`. Choose
    between two listeners (`127.0.0.1` and `::1`, via `requiredLocalEndpoint`) and
    `requiredInterfaceType = .loopback` by what `lsof` shows and by whether a connection to the
    Mac's LAN address is refused. A browser connecting to `localhost:<port>` must work. Port in
    use on one family: the rule shows `.error` with that message, as today.
  - Regression test in `PortForwardingManagerTests`: one that would fail on the current code.
    Prefer a behavioural test (127.0.0.1 and ::1 connect, a non-loopback local address is
    refused, skipped when the machine has none) over asserting parameter values.
  - Bug 107: replace the two strings in `SettingsView.swift` with true ones (macOS appearance;
    what Secure Enclave support exists today), or remove the Security label.
  - Verify: Debug build, `PortForwardingManagerTests`, live `lsof` after the fix. Mark Bugs 97 and
    107 fixed in `Docs/bugs.md` and its Summary table.

- [x] **Phase 1b: Forwards that carry data (Bug 109).** Added 2026-10-24 when Phase 1's end-to-end
  check found every forwarded connection closed at once. Cause and evidence: `Docs/bugs.md`
  Bug 109. Done 2026-10-24; results under "Phase 1b results" below.
  - `prossh_forward_channel_open` must not need a blocking session: take the handle lock per
    attempt, retry `ssh_channel_open_forward` on `SSH_AGAIN` with the lock released between
    attempts (the shell keeps running), and give up after a deadline. Never hold the lock through
    a blocking open: the server may spend a long time connecting to an unreachable target.
  - The forward channel keeps its handle and takes the handle lock around every libssh call
    (read, write, is-open, close). Check the lifetime: forwards must stop before
    `prossh_libssh_destroy` (Bug 1/3 ordering).
  - Regression test: a loopback `sshd` with a shell open, as the app does; a forward moves data
    over 127.0.0.1 and ::1, several connections in a row and two at once. It must fail on the
    old wrapper.
  - Verify: Debug build, `PortForwardingManagerTests`, the new test, `LibSSHShellLifecycleTests`.
    Mark Bug 109 fixed.

- [x] **Phase 2: A CI job that can fail (Bug 105).** Done 2026-10-24; results under
  "Phase 2 results" below.
  - `runs-on: xcode-27`; select `/Applications/Xcode_27.1.app` explicitly and print
    `xcodebuild -version`. Check `xcodebuild -showComponent metalToolchain` and download it if
    missing. Never exclude the shader.
  - `set -o pipefail`, no `|| true`, no `xcpretty`. Use `-quiet` or `xcbeautify` if the image has
    it, and upload the `.xcresult` on failure.
  - Signing: the runner has no certificate. Build with an override such as
    `CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO`. **Main risk:** an ad-hoc test host carrying
    the `keychain-access-groups` entitlement may not launch. Find out on the runner and pick the
    smallest override that works. A CI-only entitlements file is fine; it must not change the
    shipping build.
  - Test step: targeted suites only, listed in the workflow, until a full-suite baseline
    exists on Xcode 27. Start from suites with no network, keychain or window dependence (parser,
    grid, key encoder, filters, history index, `PortForwardingManagerTests`, AI contract and
    agent tests with mocks). Add each suite only after it passes on the runner, and record any
    that fail only in CI, with the reason, in this spec.
  - **Prove it can fail:** on a throwaway branch with an open PR, push a commit that breaks the
    build and one that breaks a test. Both runs must go red. Then delete the branch.
  - Restore the README CI badge. Mark Bug 105 fixed.

- [x] **Phase 3: `scripts/build-vendor.sh` — OpenSSL 3.5 LTS and libssh 0.12.2 from pinned
  sources.** Builds only; the app still links the old binaries at the end of this phase.
  Done 2026-10-24 with OpenSSL 3.5.9; results under "Phase 3 results" below.
  - Port the ProSSHV2 scripts (macOS only) into one script in this repo. Pin `OPENSSL_VERSION`
    (the newest 3.5.x at the time; 3.5.8 as of 2026-08-25) and `LIBSSH_VERSION=0.12.2`, with the
    SHA-256 of each tarball. Download from the projects' own release sites and refuse to build on
    a checksum mismatch. Work under `build/vendor/`, which is already git-ignored.
  - OpenSSL: `darwin64-arm64-cc` and `darwin64-x86_64-cc`, `no-tests no-shared no-module`,
    `-mmacosx-version-min=26.0`, `make install_sw`.
  - libssh: CMake per arch with today's options: `WITH_GCRYPT=OFF WITH_GSSAPI=OFF WITH_SERVER=OFF
    WITH_EXAMPLES=OFF WITH_TESTING=OFF BUILD_SHARED_LIBS=OFF`. Also set `WITH_FIDO2=OFF`,
    `WITH_ZLIB=ON` and `CMAKE_OSX_DEPLOYMENT_TARGET=26.0` explicitly. Keep the CMake options in one
    list so F18/F19 add a line, not a rewrite.
  - `lipo` the slices and install into a staging copy of today's layout
    (`<name>.xcframework/macos-arm64_x86_64/{Headers,lib*.a}`), so the project's search paths
    stay unchanged. Write `Vendor/VERSIONS.md`: versions, checksums, options, Xcode and SDK
    versions, build date, the command.
  - Compare the staging output with today's binaries: `lipo -info`, minos, exported `T` symbols
    (anything removed must be explained), new undefined imports (expect none outside
    libSystem and zlib), and a header diff. Record the summary in this spec.
  - Run the script twice from a clean `build/vendor/`. Both runs must produce the same versions
    and symbol lists. Record its wall time.

- [ ] **Phase 4: Swap in the new libraries and verify SSH end to end.**
  - Run `scripts/build-vendor.sh`, then replace `Vendor/OpenSSL` and `Vendor/libssh` with
    `build/vendor/stage/Vendor/*`, `VERSIONS.md` included. Replace the directories rather than
    copying over them, so `asn1_mac.h` (removed in 3.5) goes too. Review the header diff for API
    changes that `CLibSSH/ProSSHLibSSHWrapper.c` uses (Phase 3 results lists them). The build must
    add no new deprecation warnings without a note.
  - The libraries now need macOS 26.0 (libssh was 13.0) and were built against SDK 27.0, which
    matches the app's deployment target. A linker warning about either is a finding.
  - Debug and Release builds. Targeted suites for the SSH stack: `PortForwardingManagerTests`
    and the transport, known-hosts, algorithm-policy, credential-resolver, KeyForge and
    certificate suites. Find their exact names with `grep -l` at the phase.
  - Live, against a temporary loopback `sshd` (and the four Ubuntu VMs if the user is at the
    keyboard):
    - password and public-key login (ed25519, ECDSA, RSA);
    - certificate login;
    - a known-hosts mismatch prompt;
    - SFTP browse, upload and download;
    - a local forward, checked with `lsof` again;
    - one ProxyJump hop;
    - keepalive across idle;
    - five connect/disconnect cycles, as for Bug 3.
  - Update the README vendored-library table and CLAUDE.md. CI from Phase 2 must stay green.

- [ ] **Phase 5: Sparkle 2 auto-update.**
  - Add Sparkle (2.10.0 or newer) as a Swift package, the project's first. Commit
    `Package.resolved`. CONTRIBUTING and README stop saying "no package manager", and the
    license table gains Sparkle (MIT). CI must resolve the package.
  - **Decide with the user first**, because every installed copy keeps this URL: the feed URL.
    Options are `appcast.xml` committed on `master` (served by raw.githubusercontent.com; works
    whether or not a release is marked pre-release) or a `releases/latest/download/appcast.xml`
    asset (only resolves to a full, non-pre-release release). Also decide whether 0.10.0 is a
    full release.
  - The EdDSA key pair comes from Sparkle's `generate_keys`. The private key stays in the user's
    login keychain, with an exported backup the user stores offline. Losing it means installed
    copies can no longer verify updates. Only `SUPublicEDKey` goes in the app.
  - The generated Info.plist cannot hold arbitrary keys. Add a partial `INFOPLIST_FILE` for
    `SUFeedURL`, `SUPublicEDKey` and `SUEnableAutomaticChecks`; the generated keys stay.
  - `SPUStandardUpdaterController` owned by the app. Start the updater only when not running
    under XCTest (`XCTestConfigurationFilePath`) and not on a `--benchmark*` launch, and test that
    gate. Add "Check for Updates…" to the app menu and an automatic-check toggle in Settings.
  - `CFBundleVersion` drives Sparkle's comparison: one integer, incremented per release.
    Document it under "Release procedure" below.
  - Verify the update path locally: build N and N+1 (both signed with the same identity), serve
    an appcast from `python3 -m http.server`, and update N to N+1 from the menu. Debug build,
    the gate test, and CI.

- [ ] **Phase 6: Release 0.10.0, notarized.** The user is at the keyboard.
  - **Before the phase, the user:** has a "Developer ID Application" certificate in the
    keychain; has stored notarization credentials with `xcrun notarytool store-credentials`
    (switch `create-dmg.sh` to a keychain profile instead of `APPLE_APP_PASSWORD`); has the
    Sparkle private key backed up.
  - Check the entitlements under Developer ID. `keychain-access-groups` is likely a restricted
    entitlement on macOS that needs a Developer ID provisioning profile, and the Keychain,
    Secure Enclave and biometric stores depend on it. The notarized build must open the
    stored hosts and keys, unlock with Touch ID and connect.
  - Sparkle's helpers (Autoupdate, Updater.app, XPC services) must be signed with the
    Developer ID and hardened runtime, or notarization fails. Confirm the export re-signs
    them and check with `codesign --verify --deep --strict`.
  - `MARKETING_VERSION = 0.10.0` and the next build number. `create-dmg.sh --sign`, then
    `spctl -a -vv` (expect `Notarized Developer ID`), `stapler validate`, and a first launch from
    a quarantined download on this Mac.
  - Release notes from `Docs/featurelist.md` since 2026-02-26, in user terms. Note that 0.9.0 has
    no updater, so 0.9.0 users install 0.10.0 by hand once.
  - Generate the appcast entry with Sparkle's `sign_update` and publish it at the Phase 5 URL.
    Each outward step waits for the user's go-ahead: tag, release, asset upload, appcast.
  - After publishing: download the DMG from GitHub and install it. Then confirm that a build
    numbered below 0.10.0, pointed at the real feed, is offered the update.
  - README install section: notarized DMG, updates through "Check for Updates…". Record the
    procedure below.

## Phase 1 results (2026-10-24)

A scratch probe (same Network.framework calls, outside the app) and a temporary harness test
(loopback `sshd`, real `LibSSHTransport` and `PortForwardingManager`) on this Mac. LAN address
192.168.2.8 plus a global IPv6 address on en0. The firewall is in stealth mode, so connections
nobody accepts are dropped, not refused.

| Listener setup | `lsof` LISTEN | 127.0.0.1 | ::1 | LAN v4/v6 |
|---|---|---|---|---|
| Before: `NWListener(using: .tcp, on: port)` | `*:p` | accepted | accepted | **accepted** |
| `requiredInterfaceType = .loopback` | `*:p` | accepted | accepted | dropped |
| Two listeners, `requiredLocalEndpoint` 127.0.0.1 and ::1 | `127.0.0.1:p` only | accepted | refused (second listener EADDRINUSE) | dropped |
| **Chosen:** the same plus `allowLocalEndpointReuse` | `127.0.0.1:p`, `[::1]:p` | accepted | accepted | dropped |

- Network.framework refuses a second listener on the same port even in the other family,
  whichever binds first. The kernel allows the pair (raw `bind` succeeds), and reuse lifts it.
- With reuse, the pair still fails with "Address already in use" when the port is held by
  another forward, a plain socket on 127.0.0.1, a `SO_REUSEPORT` socket, a wildcard `*:p` socket
  or `0.0.0.0:p`. Reuse never shadows another listener.
- Harness `lsof`, before: `ProSSHMac … IPv6 … TCP *:47008 (LISTEN)`. After:
  `ProSSHMac … IPv4 … TCP 127.0.0.1:49087 (LISTEN)` and `ProSSHMac … IPv6 … TCP [::1]:49087 (LISTEN)`.
- The first loopback connection read `SSH-2.0-OpenSSH_10.3` through the forward; later ones
  were closed at once, before and after the fix. That is Bug 109 (Phase 1b), not binding.
- `PortForwardingManagerTests` 3/3 (the new loopback test failed on the old code on the LAN
  connect), Debug build passed. A live check in the relaunched app is still open; it needs a
  user at the keyboard.

## Phase 1b results (2026-10-24)

- libssh 0.12.0's own source (`channels.c` in the ProSSHV2 checkout) confirms the cause:
  `ssh_channel_set_blocking` calls `ssh_set_blocking(channel->session, …)`, documented as putting
  "the whole session in non-blocking mode". Reading it also showed partial writes
  (`channel_write_common` returns `origlen - len` when the window is 0) and EOF reported with the
  final read. Both were fixed too; see Bug 109.
- `LibSSHPortForwardingTests`: a shell opened first, then three connections in a row (127.0.0.1,
  ::1, 127.0.0.1), two at once (100 KB each), 4 MB echoed byte for byte, and three reads from
  a target that sends 300 KB and closes. Results:
  - **Old wrapper:** every connection returned nothing.
  - **Only the write loop reverted:** 3,768,320 of 4,194,304 bytes came back.
  - **Only the read order reverted:** 294,912 of 300,000 bytes, in all three reads.
- Forwarding suites (`LibSSHPortForwardingTests`, `LibSSHShellLifecycleTests`,
  `PortForwardingManagerTests`) 5/5, twice. Debug build passed with no new warnings in the
  changed files. The loopback `sshd` setup moved to `LoopbackTestSupport.swift`, shared by both
  libssh suites.
- **Open: throughput.** The 4 MB echo takes about 6.1 s (Debug, loopback): about 0.65 MB/s each
  way. With the read loop's idle sleep at 1 ms instead of 10 ms it took 1.6 s, so the forward's
  polling design is the limit, not the fix. Left as it was; a forwarding-performance item for
  the user to schedule (F10 or its own phase).
- A live check in the relaunched app (`curl` or a browser through a real host's forward) is
  still open; it needs a user at the keyboard.

## Phase 2 results (2026-10-24)

- **Before:** the last green run on the old job (39935406172, 2026-10-23, `macos-15-arm64`,
  macOS 15.7.9) printed `** BUILD FAILED **`, then "Cannot test target “ProSSHMacTests” on “My
  Mac”: My Mac’s macOS 15.7.9 doesn’t match…", and passed in 38 s.
- **Runner:** image `xcode-27-arm64` 20261022.0305.3. After `xcode-select`, `xcodebuild -version`
  printed Xcode 27.1, build 27A9275 (ours). `-showComponent metalToolchain` already reported
  "Status: installed", so nothing was downloaded. The download branch stays for future images.
  Jobs started 2–3 s after the run was created.
- **Signing:** `CODE_SIGNING_ALLOWED=NO` was enough, the smallest override. The linker ad-hoc
  signs the binaries, with no entitlements, so `keychain-access-groups` never blocks the test
  host's launch. No CI entitlements file and no project change were needed. Checked locally
  first (`codesign -dv`: `adhoc,linker-signed`, no entitlements), then on the runner.
- **Shape:** `build-for-testing` once, then `test-without-building` from the same DerivedData,
  each through `xcbeautify --renderer github-actions`, which turns errors into PR annotations.
  Steps run as `bash -eo pipefail` (job default `shell: bash`); with GitHub's default
  `bash -e`, `false | cat` exits 0. On failure, `build/ci/*.xcresult` is uploaded for 7 days.
- **Timing (runner):** checkout 3–4 s, Metal check 5–6 s, build 1m43s–1m54s, tests 1m19s–1m27s
  (68–71 s in XCTest). The whole job takes about 3.5 min. Locally (10 cores): build 54 s,
  tests 24 s.
- **Suites (42 classes, 604 tests), all green on the first runner run:** `SmokeTests`,
  `VTParserTests`, `TerminalGridTests`, `KeyEncoderTests`, `MouseEncoderTests`,
  `InputModeStateTests`, `ZshStartupWarningFilterTests`, `TerminalHistoryIndexTests`,
  `PortForwardingManagerTests`, the AI contract/agent/definitions/context and Anthropic
  transcript suites, `CredentialPromptDetectorTests`, `DeviceCLITests`, the ApplyDiff (3),
  UnifiedDiff (3), `PatchApprovalTrackerTests` and `RemotePatchCommandBuilderTests` classes, the
  six SSHConfig classes, the seven TOTP classes, `RemotePathTests`, `SmoothScrollEngineTests`,
  `LinkDetectorTests`, `TerminalSearchTests` and `GlyphIndexPackingTests`. None failed only on
  the runner, `PortForwardingManagerTests` included (3/3). Whether its LAN-refusal branch ran
  there, or was skipped for want of a non-loopback address, wasn't checked.
- **Not in CI yet, by design:** keychain suites (`PersistentStoreTests`, the OpenRouter and
  Anthropic settings suites), since the unsigned build has no entitlements; window and Metal
  suites; real-shell suites (`ShellIntegrationEchoFilterTests`, `SessionManagerRenderingPathTests`,
  `SessionAIToolCoordinatorTests`, `ShellIntegrationTests`); the loopback-`sshd` suites
  (`LibSSHPortForwardingTests`, `LibSSHShellLifecycleTests`); and the rest not yet tried. Add
  them one at a time, each proven on the runner.
- **Proved red** on throwaway PR #30, closed and its branch deleted: green 40084571525. A type error in
  `ContentView.swift` went red at Build, exit 65, annotated on the line, Test skipped,
  `Build.xcresult` uploaded (40084929947). A false `SmokeTests` assertion went red at Test,
  exit 65, annotated, 113 MB xcresult uploaded (40085032926).
- **Found: Bug 110.** `SSHConfigImportServiceTests.testFullImportPreview` took 35.1 s on the
  runner in both full runs (0.067 s locally): the SSH config mapper looks up
  `ProcessInfo.processInfo.hostName` for every host. Registered, not fixed.
- The proof branch was cut from local `master`, which was 12 commits ahead of `origin`, so
  PR #30 published those commits (R2b through the Phase 2 marker) ahead of the master push. A
  scan of that range found nothing sensitive.

## Phase 3 results (2026-10-24)

- **Pins:** OpenSSL **3.5.9** (newer than the 3.5.8 in the checklist) and libssh **0.12.2**,
  still the newest 0.12.x.
  - Both signatures were verified in a throwaway keyring. OpenSSL's key is primary
    `B146 647E 45A7 B339 47AB 226B 2A2C 87D1 6169 2D40`, listed in OpenSSL's
    `doc/fingerprints.txt` and on openssl-library.org. libssh's is
    `88A2 28D8 9B07 C2C7 7D0C 7809 03D5 DF8C FDD3 E8E7`, the key libssh.org's download page names.
  - OpenSSL's published `.sha256` matched. libssh publishes no checksum, so its pin is the SHA-256
    of the verified tarball.
  - Sources: OpenSSL from the GitHub release that openssl-library.org links to, libssh from
    libssh.org/files.
- **Tools:**
  - CMake 4.4.4 and Ninja 1.13.2 from Homebrew (the user's choice). The script needs CMake 3.23
    or newer (for `CMAKE_IGNORE_PREFIX_PATH`) and falls back to Make without Ninja.
  - Xcode 27.1 (27A9275), macOS SDK **27.0** (today's binaries used 26.2), Apple clang 21.0.0.
- **Wall time:** two runs from an empty `build/vendor/`, both downloading, took **84.7 s and
  83.0 s** on 10 cores. Load was 21.7 at the start of the second.
  - OpenSSL per arch: 7 s configure, 15–19 s build, 3–4 s install. libssh per arch: 12–14 s
    configure, 1 s build.
  - Both runs produced identical reports: `lipo`, minos/sdk, exported symbols, imports and header
    hashes. `VERSIONS.md` differed only in the build time.
- **Found in today's binaries:**
  - **libcrypto's C code is unoptimized.** Its embedded compiler line is
    `clang -fPIC -arch arm64 -arch arm64 -isysroot … -DL_ENDIAN …` with no `-O3`. The ProSSHV2
    script set `CFLAGS` in the environment, which replaces the target's `-O3 -Wall` (the darwin
    targets' `CFLAGS` picker in `Configurations/10-main.conf`). The assembly paths are unaffected.
    The new script passes `-mmacosx-version-min` as a Configure argument and fails unless the
    configured `CFLAGS` contain `-O3`; they read `-O3 -Wall -mmacosx-version-min=26.0`.
  - **libcrypto bakes in ProSSHV2's install paths** as OPENSSLDIR, ENGINESDIR and MODULESDIR:
    22 strings with `/Users/kevinvanosch`. libssh.a holds two more, the source path of
    `bignum.c`, because `OPENSSL_free` passes `__FILE__`.
  - **It loads a config file on its own.** A test program that calls
    `EVP_MD_fetch(NULL, "SHA256", NULL)` fails against today's libcrypto when `OPENSSL_CONF` points
    at a config with a broken provider section and `config_diagnostics = 1`. It succeeds without
    the variable.
- **Decision (the user, this session):** OpenSSL is built with `no-autoload-config` and the fixed
  prefix `/opt/prosshmac-openssl`. The install goes through `DESTDIR`, so that directory is never
  created. The same test program against the staged libcrypto succeeds under the broken config,
  on arm64 and on x86_64 (Rosetta).
  - The staged binaries contain no build-machine path, and the script fails if they do.
  - libssh needed `-ffile-prefix-map`, because CMake compiles by absolute path.
- **Today → staged:**

  | | Today | Staged |
  |---|---|---|
  | Architectures | arm64, x86_64 | same |
  | minos | libcrypto/libssl 26.0, **libssh 13.0** | all 26.0 |
  | SDK | 26.2 | 27.0 |
  | libcrypto `T` exports (arm64 / x86_64) | 7,706 / 7,729 | 8,076 / 8,115 |
  | libssl `T` exports | 1,810 | 1,922 |
  | libssh `T` exports | 836 | 834 |
  | Imports none of the three defines (arm64 / x86_64) | 222 / 220 | 220 / 218, all in libSystem or zlib |
  | Build-machine paths | 24 | 0 |

  - **Removed exports are all internal, and nothing in `ProSSHMac/` references them.**
    - libcrypto: `ecp_nistz256_precomputed` (arm64 only), `ossl_provider_add_parameter` and
      `ossl_provider_prov_ctx`.
    - libssl: 14 internal `ossl_*` QUIC, JSON and error-string helpers, plus
      `ssl_undefined_const_function`.
    - libssh: the four `libcrux_ml_kem_mlkem768_portable_*` functions (see the ML-KEM item below).
    - libssh gained `sftp_get_new_id` and `ssh_session_kex_is_gss`.
  - **Import changes:** imports gone: `___strcpy_chk` (16 objects) and `isdigit`, `isspace` and
    `tolower`, all from today's `-O0` libcrypto, plus `select`. New imports: `strcpy`, `strcat`
    and `lstat` (`bio_sock.o`, `by_dir.o` and the old `__strcpy_chk` callers).
    - At `-O3`, clang inlines the ctype functions and lowers a fortify call whose object size is
      unknown to plain `strcpy`.
    - `bio_sock.o` uses `poll` instead of `select` in 3.5.9.
  - **Headers:**
    - OpenSSL went from 141 to 142 files, 138 of them changed. `asn1_mac.h` is gone (in 3.4.1 it
      held only `#error "This file is obsolete"`), and `byteorder.h` and `ml_kem.h` are new.
    - In libssh, 4 of 7 files changed: the version micro is 2, there are new GSSAPI key-exchange
      declarations (`ssh_userauth_gssapi_keyex`, `ssh_session_kex_is_gss`) and comment
      changes, and `struct sftp_session_struct` gains `outstanding_ids` at the end. The wrapper
      reads no `sftp_session` field directly, and Phase 4 recompiles it against the new headers.
  - **libssh `config.h`:** only `HAVE_OPENSSL_MLKEM` and `HAVE_MLKEM1024` are newly defined; the
    version and the build paths libssh's own tests use also differ.
    - With OpenSSL 3.5, libssh takes ML-KEM from OpenSSL instead of its bundled libcrux copy, and
      adds `mlkem1024nistp384-sha384` to its default key exchanges.
    - **This doesn't change what the app negotiates.** `SSHAlgorithmPolicy` passes an explicit list
      (`curve25519-sha256`, `ecdh-sha2-nistp256`, `diffie-hellman-group14-sha256`), so no
      post-quantum key exchange is offered before or after. Offering `mlkem768x25519-sha256`
      (OpenSSH 10's default) is a separate decision.
  - **CMake option cache:** identical, apart from two entries:
    - `WITH_NACL` is now OFF. It was ON, but today's build found no libnacl, so it was already
      effectively off.
    - The nonexistent `WITH_TESTING` was dropped; `UNIT_TESTING` and `CLIENT_TESTING` are set
      instead.
- **Differences from the checklist:**
  - OpenSSL is 3.5.9.
  - `make build_libs` + `install_dev` instead of `install_sw`: the `openssl` CLI isn't needed.
  - `VERSIONS.md` is generated in the staging tree and reaches `Vendor/` with the binaries in
    Phase 4, because `Vendor/` still holds 3.4.1 and 0.12.0.
  - `no-autoload-config` and the fixed prefix (the user's decision), plus `-ffile-prefix-map` for
    libssh.
  - `CMAKE_SYSTEM_NAME` is no longer set. The old build set `Darwin`, which made CMake treat a
    native build as a cross-compile.
- **Checked:**
  - A corrupted cached tarball stops the run before anything builds ("Checksum mismatch … Nothing
    was built").
  - A failing step stops the run and prints the tail of its log.
  - A failing command in the middle of a step stops it too, because steps run as background jobs:
    bash ignores `set -e` inside a function called from `||`.
  - The app's Debug build passes with `Vendor/` unchanged.

## Release procedure

Written in Phase 5 and Phase 6: version and build number, `create-dmg.sh --sign`, verification
commands, `sign_update`, appcast, GitHub release, post-release check.

## Open questions

- Feed URL and whether 0.10.0 is a full release: decide at the start of Phase 5.
- ~~Whether the `xcode-27` image's preview status causes queueing or failures~~: in Phase 2's
  three runs, jobs started 2–3 s after the run was created, and none failed for image reasons.
  Watch it while the image is a preview.
- Bug 104 (connect blocks the shared transport actor) is unmeasured and not part of F0. Phase 4's
  five-cycle check is not a measurement of it.
