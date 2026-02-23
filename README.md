# ProSSHMac

A native macOS SSH client built with SwiftUI and Metal, featuring GPU-accelerated terminal rendering, an AI terminal assistant, multi-pane sessions, a built-in file browser, SSH key management, and a certificate authority.

![macOS](https://img.shields.io/badge/macOS-26.0%2B-blue)
![Swift](https://img.shields.io/badge/Swift-6.0-orange)
![License](https://img.shields.io/badge/License-MIT-green)
![Build](https://github.com/khpbvo/ProSSHMac/actions/workflows/ci.yml/badge.svg)

![ProSSHMac Split Panes](Screenshots/Splitscreen2.png)

## Features

### Terminal

- **GPU-Accelerated Rendering** -- Metal-based rendering pipeline with glyph atlas caching for smooth, high-performance terminal output
- **Multi-Pane Sessions** -- Split your terminal into multiple panes with flexible tree-based layouts and draggable dividers
- **Local Terminal** -- Full PTY-backed local shell sessions alongside SSH connections
- **External Terminal Windows** -- Detach sessions into standalone windows
- **VT100/xterm Emulation** -- Comprehensive state-machine parser handling CSI, SGR, OSC (including OSC 133 semantic prompts), ESC, and DCS escape sequences
- **Terminal Search** -- Search through terminal buffer content
- **Session Recording** -- Record terminal sessions with encrypted persistence and asciinema-compatible export
- **Link Detection** -- Clickable URL detection in terminal output

### AI Terminal Assistant

- **AI Copilot Sidebar** -- In-terminal AI assistant powered by the OpenAI Responses API (model: `gpt-5.1-codex-max`)
- **Context-Aware Tools** -- The AI agent can read the current screen, search command history, inspect command output, browse the filesystem, read files in bounded chunks, and execute commands
- **Local and Remote Support** -- AI tools work in both local terminal sessions and remote SSH sessions (remote tools execute read-only shell queries over SSH)
- **Safe Execution** -- Commands are executed only when the user's prompt contains explicit intent; file reads are bounded to 200-line windows to prevent unbounded ingestion

### SSH and Security

- **SSH Key Management (KeyForge)** -- Generate, import, export, and inspect SSH keys including Ed25519, ECDSA, and RSA
- **Certificate Authority** -- Built-in CA for signing SSH certificates with Secure Enclave support
- **Port Forwarding** -- Local and remote port forwarding with an intuitive rule editor and NWListener-based proxying
- **Biometric Authentication** -- Touch ID and password gating for stored credentials
- **Secure Credential Storage** -- AES-256-GCM encryption with Keychain-managed master keys and Secure Enclave key management
- **Known Hosts Verification** -- Trust-on-first-use (TOFU) model with persistent host key storage
- **Audit Logging** -- All connections, authentication events, port forwards, and transfers are logged

### File Management

- **SFTP Transfers** -- File transfers with progress tracking via the Transfers tab
- **File Browser Sidebar** -- Lazy-loading tree-based file browser in the terminal sidebar (`Cmd+B`); uses SFTP for remote sessions and FileManager for local sessions
- **File Actions** -- Open files in `nano`, `vim`, or `less`, cat to terminal, and download via SFTP directly from the file browser

### Customization and Visual Effects

- **CRT Effect** -- Retro scanline overlay with barrel distortion and phosphor persistence
- **Matrix Screensaver** -- Configurable idle-activated Matrix-style falling character animation
- **Custom Prompt Appearance** -- Configurable prompt colors including rainbow username, path segment colors, and symbol color for local terminal sessions
- **Gradient Backgrounds** -- Custom terminal background gradients
- **Scanner Effect** -- Animated scanning line effect

### Productivity

- **Quick Commands** -- Reusable command snippets with variable substitution, host/global scoping, and JSON import/export
- **Spotlight Integration** -- Find your hosts via macOS Spotlight search
- **Siri Shortcuts** -- Automate SSH connections via AppIntents
- **Keyboard Shortcuts** -- File browser toggle (`Cmd+B`), AI sidebar toggle (`Cmd+Option+I`), and standard terminal shortcuts

## Requirements

- **macOS 26.0** (Tahoe) or later
- **Xcode 26.0** or later
- No additional package managers needed -- all dependencies are vendored

## Getting Started

### Clone the Repository

```bash
git clone https://github.com/khpbvo/ProSSHMac.git
cd ProSSHMac
```

### Build and Run

1. Open `ProSSHMac.xcodeproj` in Xcode
2. Select the **ProSSHMac** scheme and your target Mac
3. Press **Cmd+R** to build and run

Alternatively, build from the command line:

```bash
xcodebuild -project ProSSHMac.xcodeproj \
  -scheme ProSSHMac \
  -destination 'platform=macOS' \
  build
```

### Run Tests

```bash
xcodebuild -project ProSSHMac.xcodeproj \
  -scheme ProSSHMac \
  -destination 'platform=macOS' \
  test
```

### AI Assistant Setup

The AI terminal assistant requires an OpenAI API key:

1. Open **Settings** in ProSSHMac
2. Navigate to the **AI Assistant** section
3. Enter your OpenAI API key and click Save

The key is stored securely in the macOS Keychain.

## Installation

Download the latest `.dmg` from the [Releases](https://github.com/khpbvo/ProSSHMac/releases) page, open it, and drag **ProSSHMac** into your **Applications** folder.

### Building a DMG Yourself

```bash
# Unsigned (development / testing)
./scripts/create-dmg.sh

# Signed + notarized (release distribution)
export DEVELOPER_ID_APP="Developer ID Application: Your Name (TEAMID)"
export APPLE_ID="you@example.com"
export APPLE_TEAM_ID="YOURTEAMID"
export APPLE_APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"
./scripts/create-dmg.sh --sign
```

The DMG will be written to `build/ProSSHMac-<version>.dmg`.

## Architecture

ProSSHMac follows the **MVVM** (Model-View-ViewModel) pattern with dependency injection via `AppDependencies`.

```
ProSSHMac/
├── App/                    # Entry point, dependency injection, navigation
│   ├── AppDependencies     # Central DI container
│   ├── AppNavigationCoordinator
│   └── AppLaunchCommandStore
├── Models/                 # Data models
│   ├── Host, Session       # Connection and session models
│   ├── SSHKey, SSHCertificate
│   ├── Transfer, AuditLogEntry
│   └── ...
├── ViewModels/             # Presentation logic
│   ├── HostListViewModel
│   ├── KeyForgeViewModel, CertificatesViewModel
│   ├── OpenAISettingsViewModel
│   └── TerminalAIAssistantViewModel
├── UI/                     # SwiftUI views organized by feature tab
│   ├── Hosts/              # Host management and connection UI
│   ├── Terminal/           # Terminal session views, AI pane, pane splitting
│   ├── KeyForge/           # SSH key management UI
│   ├── Certificates/       # Certificate authority UI
│   ├── Transfers/          # SFTP transfer UI
│   └── Settings/           # App configuration including AI, effects, and prompt settings
├── Services/               # Business logic and protocol handling
│   ├── SSHTransport        # Core SSH protocol via libssh
│   ├── SessionManager      # Session lifecycle, shell I/O, SFTP operations
│   ├── LocalShellChannel   # PTY-backed local terminal sessions
│   ├── KeyForgeService     # Key generation and management
│   ├── PortForwardingManager # NWListener-based port forward proxying
│   ├── TransferManager     # SFTP file transfer orchestration
│   ├── OpenAIResponsesService  # OpenAI Responses API client
│   ├── OpenAIAgentService  # AI tool loop with session-aware tools
│   ├── EncryptedStorage    # AES-256-GCM credential encryption
│   ├── SecureEnclaveKeyManager # Secure Enclave key operations
│   ├── AuditLogManager     # Structured audit logging
│   ├── HostSpotlightIndexer # Spotlight search integration
│   └── KnownHostsStore     # SSH host key verification
├── Terminal/               # Full terminal emulator subsystem
│   ├── Renderer/           # Metal GPU rendering pipeline
│   ├── Parser/             # VT100/xterm escape sequence parser (incl. OSC 133)
│   ├── Grid/               # Terminal cell grid and scrollback buffer
│   ├── Input/              # Keyboard and mouse encoding
│   ├── Features/           # Pane management, session recording, quick commands,
│   │                       # file browser tree, command history index, terminal search
│   └── Effects/            # CRT, Matrix screensaver, prompt appearance, gradients,
│                           # link detection, cursor effects, transparency
├── CLibSSH/                # C bridge layer for libssh
├── AppIntents/             # Siri Shortcuts integration
└── Platform/               # Platform compatibility layer
```

### Key Subsystems

| Subsystem | Description |
|---|---|
| **Terminal Renderer** | Metal-based GPU rendering with glyph atlas caching, cursor and selection rendering, and performance monitoring |
| **VT Parser** | State-machine parser handling CSI, SGR, OSC (including OSC 133 semantic prompts), ESC, and DCS escape sequences |
| **SSH Transport** | Full SSH protocol implementation via libssh supporting password, public key, certificate, and keyboard-interactive authentication |
| **Local Shell** | PTY-backed local terminal using `forkpty` with proper termios configuration, nonblocking I/O, and data coalescing for smooth TUI rendering |
| **AI Agent** | OpenAI Responses API integration with a tool loop supporting terminal context retrieval, filesystem operations, and safe command execution in both local and remote sessions |
| **Command History** | Ring-buffer-backed command block index with OSC 133 semantic prompt boundary detection and fallback heuristics, queryable by the AI agent |
| **Pane Manager** | Tree-based split-node layout engine for arbitrary horizontal/vertical terminal pane arrangements with persistent layout storage |
| **Secure Storage** | Multi-layer credential protection using AES-256-GCM, Keychain, Secure Enclave, and biometric gating |

### Vendored Dependencies

| Library | Version | License | Purpose |
|---|---|---|---|
| [libssh](https://www.libssh.org/) | Bundled xcframework | LGPL-2.1 | SSH protocol implementation |
| [OpenSSL](https://www.openssl.org/) | Bundled xcframework | Apache 2.0 | Cryptographic primitives |

Both are provided as universal (arm64 + x86_64) xcframeworks in the `Vendor/` directory.

## Scripts

| Script | Purpose |
|---|---|
| `scripts/create-dmg.sh` | Build a DMG for distribution (supports signing and notarization) |
| `scripts/benchmark-ssh.sh` | Measure raw SSH transport throughput to a remote host |
| `scripts/benchmark-throughput.sh` | Benchmark terminal rendering throughput |
| `scripts/take-screenshots.sh` | Capture app screenshots for documentation |

## Contributing

We welcome contributions from everyone. See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on:

- Setting up your development environment
- Coding standards and conventions
- Submitting pull requests
- Reporting bugs and requesting features

## Security

For reporting security vulnerabilities, please see [SECURITY.md](SECURITY.md). Do **not** open public issues for security reports.

## License

This project is licensed under the [MIT License](LICENSE).

Vendored dependencies are licensed under their own terms (LGPL-2.1 for libssh, Apache 2.0 for OpenSSL).
