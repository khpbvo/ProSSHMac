# IntegrationOfNewFeats.md
# Pre-Built Module Integration Guide for Claude Code

> **Purpose**: This document describes pre-built, self-contained modules that are
> ready to drop into ProSSHMac. Each module is fully tested and needs only
> integration wiring — connecting to existing protocols, adding model fields,
> and building UI. No refactoring of the modules themselves should be needed.
>
> **Convention**: Read CLAUDE.md first for project conventions, build commands,
> and file locations. All new files go under the existing directory structure.

---

## Module 1: TOTP 2FA Auto-Fill

### What It Does

Adds TOTP (RFC 6238) two-factor authentication to SSH keyboard-interactive auth.
When a server prompts for a verification code during login, ProSSHMac detects
the prompt, retrieves the stored TOTP secret from Keychain, generates the code,
and auto-fills it — no alt-tabbing to an authenticator app.

### Files to Add

```
ProSSHMac/
├── Models/
│   └── TOTPConfiguration.swift      # Config model + otpauth:// URI parser + Base32 codec
├── Services/
│   ├── TOTPGenerator.swift          # RFC 6238 code generation engine (CommonCrypto HMAC)
│   └── TOTPStore.swift              # Secret storage wrapper + auto-fill detector + provisioning
└── Tests/
    └── TOTPTests.swift              # RFC 6238 test vectors + full test suite (~40 tests)
```

Copy these files as-is into the project. They compile independently — no
existing files need modification to add them to the target.

### Integration Steps

#### Step 1: Add `totpConfiguration` to the Host Model

In `Models/Host.swift`, add an optional field to `struct Host`:

```swift
var totpConfiguration: TOTPConfiguration?
```

Add it to:
- The `CodingKeys` enum
- The `init(from decoder:)` method (use `decodeIfPresent`, default `nil`)
- The `encode(to encoder:)` method (use `encodeIfPresent`)
- The memberwise `init(...)` — add as `totpConfiguration: TOTPConfiguration? = nil`

Also add to `HostDraft`:
```swift
var totpConfiguration: TOTPConfiguration? = nil
```

And wire it through `toHost()` and `init(from host:)`.

#### Step 2: Conform BiometricPasswordStore to SecretStorageProtocol

In `TOTPStore.swift`, there's a `SecretStorageProtocol`:

```swift
@MainActor
protocol SecretStorageProtocol {
    func saveData(_ data: Data, forKey key: String) async throws
    func retrieveData(forKey key: String) async throws -> Data?
    func deleteData(forKey key: String) async throws
}
```

The existing `BiometricPasswordStore` (or `EncryptedStorage`) likely has similar
methods for password storage. Options:

**Option A** (preferred): Add a conformance extension:
```swift
extension BiometricPasswordStore: SecretStorageProtocol {
    func saveData(_ data: Data, forKey key: String) async throws {
        // Convert Data to base64 string and save using existing save method
        try await savePassword(data.base64EncodedString(), forKey: key)
    }
    func retrieveData(forKey key: String) async throws -> Data? {
        guard let base64 = try await retrievePassword(forKey: key) else { return nil }
        return Data(base64Encoded: base64)
    }
    func deleteData(forKey key: String) async throws {
        try await deletePassword(forKey: key)
    }
}
```

**Option B**: If the password store already handles `Data` natively, just conform
it directly.

#### Step 3: Hook into Keyboard-Interactive Auth

The keyboard-interactive auth callback lives in the libssh integration layer.
Find where `KeyboardInteractiveAuth` (or the libssh callback) receives prompts
from the server. The current flow is roughly:

```
Server sends prompt → libssh callback → show prompt to user → user types response
```

Modify to:

```
Server sends prompt → libssh callback → check TOTPAutoFillDetector
  ├── TOTP detected + host has TOTPConfiguration:
  │     → retrieve secret from TOTPStore
  │     → TOTPGenerator.generateSmartCode(...)
  │     → auto-respond with code
  │     → show notification: "🔐 TOTP auto-filled (27s remaining)"
  └── Not TOTP or no configuration:
        → fall through to existing manual input flow
```

The detector call:
```swift
let detector = TOTPAutoFillDetector()
if detector.isTOTPPrompt(prompt, customPattern: host.totpConfiguration?.customPromptPattern),
   let config = host.totpConfiguration,
   let secret = try await totpStore.retrieveSecret(forHostID: host.id) {
    let result = TOTPGenerator().generateSmartCode(
        secret: secret,
        configuration: config
    )
    // Send result.code as the keyboard-interactive response
    // Show inline notification with result.secondsRemaining
}
```

**Important**: `generateSmartCode` is used instead of `generateCode`. If the
current code has ≤3 seconds remaining, it automatically generates the next
period's code to avoid the "expires while typing" problem.

#### Step 4: Add TOTP Section to Host Editor UI

In the host editor view (where users configure hostname, port, auth method, etc.),
add a "Two-Factor Authentication" section:

**States:**
1. **Not configured**: Show "Add 2FA" button → opens provisioning sheet
2. **Configured**: Show issuer, account name, current code (live-updating),
   seconds remaining ring, and "Remove 2FA" button

**Provisioning sheet** (two tabs):
- **QR Code**: Camera-based QR scanner that reads `otpauth://` URIs
  - Use `AVCaptureSession` with `AVMetadataObjectTypeQRCode`
  - Pass scanned text to `TOTPProvisioningService.provision(fromURI:forHostID:)`
- **Manual Entry**: Text field for Base32 secret + algorithm/digits/period pickers
  - Pass to `TOTPProvisioningService.provision(fromBase32Secret:...forHostID:)`

**Live code preview** (after provisioning):
```swift
// In a view model, update every second:
Timer.publish(every: 1, on: .main, in: .common)
    .autoconnect()
    .sink { _ in
        let result = TOTPGenerator().generateSmartCode(
            secret: secret,
            configuration: config
        )
        self.currentCode = result.code
        self.secondsRemaining = result.secondsRemaining
        self.progress = result.progress
    }
```

This lets users verify their TOTP is working before they save the host config.

#### Step 5: Wire TOTPStore into SessionManager

`SessionManager` already manages the connection lifecycle. It needs access to a
`TOTPStore` instance to auto-fill during auth:

```swift
// In SessionManager or wherever connection is initiated:
private let totpStore: TOTPStore

// Initialize with the same BiometricPasswordStore used for passwords:
self.totpStore = TOTPStore(store: biometricPasswordStore)
```

#### Step 6: Audit Log Integration

When TOTP auto-fill succeeds, log it via `AuditLogManager`:

```swift
auditLog.logEvent(.totpAutoFilled(hostID: host.id, issuer: config.issuer))
```

Add a `.totpAutoFilled` case to whatever audit event enum exists. This is
important for NEN 7510 compliance — the audit trail should show that 2FA
was used for the session.

#### Step 7: Add Test Target Membership

Add `TOTPTests.swift` to the test target. The tests use `@testable import ProSSHMac`
and reference `TOTPGenerator`, `TOTPConfiguration`, `Base32`, and `TOTPAutoFillDetector`.

Run the RFC 6238 test vectors first — if those pass, the generator is proven
interoperable with every TOTP app on the planet.

### QR Code Camera Integration Note

macOS QR scanning requires `AVFoundation` camera permissions. Add to `Info.plist`:
```xml
<key>NSCameraUsageDescription</key>
<string>ProSSHMac uses the camera to scan QR codes for two-factor authentication setup.</string>
```

Alternatively, support paste-from-clipboard for users who copy the `otpauth://`
URI from a web browser. This is less friction for desktop users.

### Security Considerations

- **Secrets are Keychain-only**: Never stored in UserDefaults, JSON files, or Host model
- **Biometric gate on export**: `TOTPProvisioningService.exportURI()` reveals the raw
  secret — always gate behind Face ID / Touch ID confirmation before calling
- **Wipe on host deletion**: When a host is deleted, also call
  `totpStore.deleteSecret(forHostID:)` to clean up the Keychain entry
- **No secret in logs**: The audit log records that TOTP was used, never the secret
  or the generated code

---

## Module 2: SSH Config Import/Export

### What It Does

Parses `~/.ssh/config` files into ProSSHMac Host models and exports hosts back
to SSH config format. Biggest adoption friction remover — users with existing
SSH configs can import everything in one shot.

### Files to Add

```
ProSSHMac/
├── Services/
│   └── SSHConfigParser.swift        # Parser + token expander + mapper + exporter + import service
└── Tests/
    └── SSHConfigParserTests.swift   # ~40 tests covering parsing, mapping, export, round-trip
```

### Integration Steps

#### Step 1: Add Import Action to Hosts Tab

Add a toolbar button or menu item: "Import from SSH Config". This opens a sheet:

```swift
// Option A: Auto-detect ~/.ssh/config
let service = SSHConfigImportService()
if let configText = service.readDefaultConfig() {
    let preview = service.preview(
        configText: configText,
        existingHosts: hostStore.hosts,
        existingKeys: keyStore.keys
    )
    // Show preview UI
}

// Option B: Open file picker for custom path
let panel = NSOpenPanel()
panel.allowedContentTypes = [.plainText]
// ... user picks file ...
let configText = try service.readConfig(at: selectedPath)
```

#### Step 2: Build Import Preview UI

The `SSHConfigImportService.preview()` returns an `ImportPreview` with:
- `results`: Array of `(host: Host, notes: [String])` — each host ready to import
- `parserWarnings`: Lines that couldn't be parsed
- `skippedEntries`: Count of wildcards/Match blocks skipped
- `summary`: Human-readable summary string

Show a list where each row is a host with:
- ✅ Checkbox (select/deselect for import)
- Host label, hostname, username, port
- ⚠️ Warning badge if `notes` is non-empty (expandable to show notes)

Show `summary` at the top. Show `parserWarnings` in a collapsible "Parser Warnings" section.

#### Step 3: Duplicate Detection

Before committing the import, check for duplicates:

```swift
let dupes = service.findDuplicates(
    imported: selectedHosts,
    existing: hostStore.hosts
)
```

For each duplicate pair, offer:
- **Skip**: Don't import this host
- **Replace**: Overwrite the existing host (preserve its UUID and connections)
- **Import as new**: Import with a different label (append " (imported)")

#### Step 4: Add Export Action

Add "Export to SSH Config" in the hosts list context menu or toolbar:

```swift
let exporter = SSHConfigExporter()
let output = exporter.export(
    selectedHosts,
    options: SSHConfigExporter.ExportOptions(
        includeHeader: true,
        includeProSSHNotes: true,
        allHosts: hostStore.hosts,
        allKeys: keyStore.keys
    )
)

// Save to file via NSSavePanel
let panel = NSSavePanel()
panel.nameFieldStringValue = "config"
panel.allowedContentTypes = [.plainText]
```

#### Step 5: Handle Include Directives

The parser warns on `Include` directives but doesn't expand them. For full
support, resolve includes before parsing:

```swift
func resolveIncludes(in configText: String, baseDir: String = "~/.ssh") -> String {
    // Find Include lines, glob-expand the patterns, read each file,
    // and inline the contents. Recursive for nested includes.
    // This is a nice-to-have — the parser works fine without it,
    // users just get a warning about skipped Include lines.
}
```

This is optional for V1. Most users' configs work fine without Include expansion.

#### Step 6: Wire Key Resolution

The mapper tries to match `IdentityFile` paths to keys in KeyForge. For best
results, pass the full key store:

```swift
let preview = service.preview(
    configText: configText,
    existingHosts: hostStore.hosts,
    existingKeys: keyStore.keys  // ← This enables IdentityFile → key matching
)
```

If a key isn't found, the mapper adds a note: "IdentityFile ~/.ssh/id_ed25519 —
no matching key found in ProSSHMac KeyForge. Import the key separately."

Consider adding a follow-up flow: after SSH config import, offer to import
any unresolved IdentityFile keys via the existing key import mechanism.

### Features Mapped

| SSH Config Directive       | ProSSHMac Host Field          | Notes                              |
|---------------------------|-------------------------------|------------------------------------|
| `HostName`                | `hostname`                    | Token-expanded                     |
| `User`                    | `username`                    | Falls back to local user           |
| `Port`                    | `port`                        | Defaults to 22                     |
| `IdentityFile`            | `keyReference`                | Matched by path/filename/label     |
| `ProxyJump`               | `jumpHost`                    | First hop only; chain noted        |
| `ProxyCommand ssh -W`     | `jumpHost`                    | Common pattern parsed              |
| `ForwardAgent`            | `agentForwardingEnabled`      |                                    |
| `LocalForward`            | `portForwardingRules`         | Multiple rules supported           |
| `RemoteForward`           | —                             | Noted (not supported yet)          |
| `KexAlgorithms`           | `algorithmPreferences.kex`    | Modifiers (+/-/^) stripped         |
| `Ciphers`                 | `algorithmPreferences.ciphers`|                                    |
| `MACs`                    | `algorithmPreferences.macs`   |                                    |
| `HostKeyAlgorithms`       | `pinnedHostKeyAlgorithms`     |                                    |
| `PreferredAuthentications`| `authMethod`                  | First method mapped                |
| Multiple Host patterns    | `tags` (extra patterns)       |                                    |
| Slash in label            | `folder` + `label`            | `prod/web-01` → folder + label     |
| Legacy algorithms         | `legacyModeEnabled`           | Auto-detected                      |
| `Host *`                  | Global defaults               | Applied as fallback                |
| `Match`                   | —                             | Captured, conditions not evaluated |
| `Include`                 | —                             | Warning; resolve before parsing    |

---

## General Integration Notes

### Build Verification

After adding any module files, verify:
```bash
xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build 2>&1 | tail -5
```

After adding test files:
```bash
xcodebuild -scheme ProSSHMac -destination 'platform=macOS' test 2>&1 | grep -E '(Test Suite|Executed|failed)'
```

### Concurrency Safety

All module types are `Sendable`. `TOTPStore` and `TOTPProvisioningService` are
`@MainActor` to match the project convention for store types. The generator and
parser are value types with no mutable state — safe to call from any context.

### No Existing File Modifications Required

Both modules can be added to the Xcode target without modifying any existing
source files. Integration wiring (Steps above) is the only point of contact
with existing code. This means these modules can be integrated on `main` branch
regardless of what's happening on the `refactor/actor-isolation` branch.

### Priority Order

1. **SSH Config Import** — immediate adoption impact, zero dependencies
2. **TOTP 2FA** — requires BiometricPasswordStore conformance + UI work

Both are orthogonal to the actor-isolation refactor (Phases 6-8).
