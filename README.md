# ProSSHMac

A native macOS SSH client built with SwiftUI and Metal, featuring GPU-accelerated terminal rendering, multi-pane sessions, SSH key management, and a built-in certificate authority.

![macOS](https://img.shields.io/badge/macOS-26.0%2B-blue)
![Swift](https://img.shields.io/badge/Swift-6.0-orange)
![License](https://img.shields.io/badge/License-MIT-green)
![Build](https://github.com/khpbvo/ProSSHMac/actions/workflows/ci.yml/badge.svg)

<!-- ![ProSSHMac Screenshot](docs/screenshots/main.png) -->

## Features

- **GPU-Accelerated Terminal** -- Metal-based rendering with glyph atlasing for smooth, high-performance terminal output
- **Multi-Pane Sessions** -- Split your terminal into multiple panes with flexible layouts
- **SSH Key Management (KeyForge)** -- Generate, import, export, and inspect SSH keys including Ed25519, ECDSA, and RSA
- **Certificate Authority** -- Built-in CA for signing SSH certificates with Secure Enclave support
- **Port Forwarding** -- Local and remote port forwarding with an intuitive rule editor
- **SFTP Transfers** -- File transfers with progress tracking
- **Biometric Authentication** -- Touch ID and password gating for stored credentials
- **Secure Credential Storage** -- AES-256-GCM encryption with Keychain-managed master keys
- **Known Hosts Verification** -- Trust-on-first-use (TOFU) model with persistent host key storage
- **VT100/xterm Emulation** -- Comprehensive terminal parser with full escape sequence support
- **Spotlight Integration** -- Find your hosts via macOS Spotlight search
- **Siri Shortcuts** -- Automate SSH connections via AppIntents
- **Audit Logging** -- All connections, authentication, and transfers are logged

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

## Architecture

ProSSHMac follows the **MVVM** (Model-View-ViewModel) pattern with dependency injection.

```
ProSSHMac/
├── App/                # Application entry point, dependency injection, navigation
├── Models/             # Data models (Host, Session, SSHKey, SSHCertificate, etc.)
├── ViewModels/         # Presentation logic (HostListViewModel, KeyForgeViewModel, etc.)
├── Views/              # SwiftUI views organized by feature tab
│   ├── Hosts/          # Host management and connection UI
│   ├── Terminal/       # Terminal session views
│   ├── KeyForge/       # SSH key management UI
│   ├── Certificates/   # Certificate authority UI
│   ├── Transfers/      # SFTP transfer UI
│   └── Settings/       # App configuration
├── Services/           # Business logic and SSH protocol handling
│   ├── SSHTransport    # Core SSH protocol via libssh
│   ├── SessionManager  # Session lifecycle management
│   ├── KeyForgeService # Key generation and management
│   └── ...             # Encrypted storage, port forwarding, audit logging
├── Terminal/           # Full terminal emulator subsystem
│   ├── Renderer/       # Metal GPU rendering pipeline
│   ├── Parser/         # VT100/xterm escape sequence parser
│   ├── Grid/           # Terminal cell grid and scrollback
│   ├── Input/          # Keyboard and mouse encoding
│   ├── Features/       # Pane management, session recording
│   ├── Effects/        # Visual effects and animations
│   └── Tests/          # Terminal unit and integration tests
├── CLibSSH/            # C bridge layer for libssh
├── AppIntents/         # Siri Shortcuts integration
└── Platform/           # Platform compatibility layer
```

### Key Subsystems

| Subsystem | Description |
|---|---|
| **Terminal Renderer** | Metal-based GPU rendering with glyph atlas caching, cursor and selection rendering, and performance monitoring |
| **VT Parser** | State machine-based parser handling CSI, SGR, OSC, ESC, and DCS escape sequences |
| **SSH Transport** | Full SSH protocol implementation via libssh supporting password, public key, certificate, and keyboard-interactive authentication |
| **Secure Storage** | Multi-layer credential protection using AES-256-GCM, Keychain, Secure Enclave, and biometric gating |

### Vendored Dependencies

| Library | Version | License | Purpose |
|---|---|---|---|
| [libssh](https://www.libssh.org/) | Bundled xcframework | LGPL-2.1 | SSH protocol implementation |
| [OpenSSL](https://www.openssl.org/) | Bundled xcframework | Apache 2.0 | Cryptographic primitives |

Both are provided as universal (arm64 + x86_64) xcframeworks in the `Vendor/` directory.

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
