# Contributing to ProSSHMac

Thank you for your interest in contributing to ProSSHMac! This guide will help you get started.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Development Workflow](#development-workflow)
- [Coding Standards](#coding-standards)
- [Submitting Changes](#submitting-changes)
- [Reporting Bugs](#reporting-bugs)
- [Requesting Features](#requesting-features)
- [Project Structure](#project-structure)

## Code of Conduct

This project follows a [Code of Conduct](CODE_OF_CONDUCT.md). By participating, you agree to uphold a respectful and inclusive environment.

## Getting Started

### Prerequisites

- **macOS 26.0** (Tahoe) or later
- **Xcode 26.0** or later
- Git

### Setup

1. **Fork** the repository on GitHub
2. **Clone** your fork:
   ```bash
   git clone https://github.com/<your-username>/ProSSHMac.git
   cd ProSSHMac
   ```
3. **Open** the project in Xcode:
   ```bash
   open ProSSHMac.xcodeproj
   ```
4. **Build and run** with Cmd+R to verify everything works

No additional package managers or dependency installs are required -- all dependencies are vendored as xcframeworks.

### Running Tests

Run the full test suite from Xcode (Cmd+U) or the command line:

```bash
xcodebuild -project ProSSHMac.xcodeproj \
  -scheme ProSSHMac \
  -destination 'platform=macOS' \
  test
```

## Development Workflow

1. **Create a branch** from `master` for your work:
   ```bash
   git checkout -b feature/your-feature-name
   ```
   Use descriptive branch names:
   - `feature/` -- new features
   - `fix/` -- bug fixes
   - `refactor/` -- code refactoring
   - `docs/` -- documentation updates
   - `test/` -- test additions or fixes

2. **Make your changes** in small, focused commits

3. **Test your changes** -- run the test suite and verify nothing is broken

4. **Push** to your fork and open a pull request

## Coding Standards

### Swift Style

- Use **Swift 6.0** conventions and strict concurrency
- Follow the existing code style in the project
- Use `SwiftUI` for all new views
- Use `Combine` for reactive data flow where appropriate
- Prefer value types (`struct`, `enum`) over reference types (`class`) unless shared mutable state is required

### Architecture

- Follow the **MVVM** pattern:
  - **Models** -- data structures in `Models/`
  - **ViewModels** -- presentation logic in `ViewModels/`
  - **Views** -- SwiftUI views in `UI/`
  - **Services** -- business logic in `Services/`
- Use `AppDependencies` for dependency injection
- Keep views thin -- business logic belongs in ViewModels or Services

### Terminal Subsystem

The terminal emulator (`Terminal/`) is a performance-critical subsystem. When working on it:

- Profile rendering changes with the `RendererPerformanceMonitor`
- Ensure escape sequence parsing changes pass existing `VTParserTests`
- Test with real-world terminal applications (vim, htop, tmux) when modifying the parser or grid
- Metal shader changes should be tested on both Apple Silicon and Intel Macs

### Security

ProSSHMac handles sensitive data (SSH keys, passwords, certificates). When contributing:

- Never log or print credentials, private keys, or passphrases
- Use `EncryptedStorage` for persisting sensitive data
- Use `SecureEnclaveKeyManager` for hardware-backed key operations
- Follow the principle of least privilege
- See [SECURITY.md](SECURITY.md) for the full security architecture

### Commit Messages

Write clear, descriptive commit messages:

```
Add keyboard shortcut for splitting terminal panes

Adds Cmd+D for horizontal split and Cmd+Shift+D for vertical split.
Updates the KeyEncoder to handle the new modifier combinations.
```

- Use the imperative mood ("Add feature" not "Added feature")
- First line is a short summary (50 chars or less)
- Add a blank line followed by details if needed

## Submitting Changes

### Pull Requests

1. Ensure your branch is up to date with `master`
2. Open a pull request against `master`
3. Fill out the PR template completely
4. Ensure CI passes (build + tests)
5. Request a review

### What Makes a Good PR

- **Focused** -- one logical change per PR
- **Tested** -- includes tests for new functionality
- **Documented** -- updates relevant comments or docs
- **Small** -- easier to review and less likely to introduce issues

## Reporting Bugs

Use the [Bug Report](https://github.com/khpbvo/ProSSHMac/issues/new?template=bug_report.yml) issue template. Include:

- macOS version and hardware (Apple Silicon / Intel)
- Steps to reproduce
- Expected vs. actual behavior
- Relevant logs or screenshots

## Requesting Features

Use the [Feature Request](https://github.com/khpbvo/ProSSHMac/issues/new?template=feature_request.yml) issue template. Describe:

- The problem you're trying to solve
- Your proposed solution
- Any alternatives you've considered

## Project Structure

Here's a quick guide to where things live:

| Area | Directory | What to Find |
|---|---|---|
| App bootstrap | `App/` | Entry point, dependency injection, navigation |
| Data models | `Models/` | Host, Session, SSHKey, Transfer, etc. |
| ViewModels | `ViewModels/` | HostListViewModel, KeyForgeViewModel, CertificatesViewModel |
| UI views | `UI/` | SwiftUI views grouped by feature tab |
| Services | `Services/` | SSH transport, session management, encryption, key management |
| Terminal | `Terminal/` | GPU renderer, VT parser, grid model, input handling |
| Terminal tests | `Terminal/Tests/` | Unit and integration tests for the terminal subsystem |
| C bridge | `CLibSSH/` | C wrapper for libssh |
| Vendored libs | `Vendor/` | Pre-built xcframeworks for libssh and OpenSSL |

## Questions?

Open a [discussion](https://github.com/khpbvo/ProSSHMac/discussions) or an issue if you need help getting started.
