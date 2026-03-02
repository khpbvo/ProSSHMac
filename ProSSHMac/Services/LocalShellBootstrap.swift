// LocalShellBootstrap.swift
// ProSSHMac
//
// Builds the minimal child environment for a local PTY shell session.
// No custom ZDOTDIR, no overlay files — the user's real shell config loads as normal.

import Foundation
import Darwin

enum LocalShellBootstrap {

    /// Returns (home, user, shell) from the real passwd entry, falling back to env vars.
    static func resolveUserInfo() -> (home: String, user: String, shell: String) {
        if let pw = getpwuid(getuid()) {
            return (
                home: String(cString: pw.pointee.pw_dir),
                user: String(cString: pw.pointee.pw_name),
                shell: String(cString: pw.pointee.pw_shell)
            )
        }
        let env = ProcessInfo.processInfo.environment
        return (
            home: env["HOME"] ?? NSHomeDirectory(),
            user: env["USER"] ?? NSUserName(),
            shell: env["SHELL"] ?? "/bin/zsh"
        )
    }

    /// Builds a clean environment for the child shell process.
    /// Inherits locale, PATH, and TMPDIR from the parent, sets standard terminal vars.
    /// Injects custom prompt overlay via ZDOTDIR (zsh) or BASH_ENV (bash).
    static func buildEnvironment(shellPath: String, shellIntegration: ShellIntegrationConfig = .init()) -> [String: String] {
        let parentEnv = ProcessInfo.processInfo.environment
        let info = resolveUserInfo()

        var env: [String: String] = [:]

        // Locale / encoding
        if let lang = parentEnv["LANG"]   { env["LANG"]   = lang }
        if let tmp  = parentEnv["TMPDIR"] { env["TMPDIR"] = tmp }
        for (key, value) in parentEnv where key.hasPrefix("LC_") {
            env[key] = value
        }

        // Identity
        env["HOME"]    = info.home
        env["USER"]    = info.user
        env["LOGNAME"] = info.user
        env["SHELL"]   = shellPath

        // PATH — inherit from parent so user tools (brew, nvm, etc.) all work
        env["PATH"] = parentEnv["PATH"] ?? "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

        // Terminal type
        env["TERM"]             = "xterm-256color"
        env["COLORTERM"]        = "truecolor"
        env["TERM_PROGRAM"]     = "ProSSH"
        env["TERM_PROGRAM_VERSION"] = "2.0"
        env["CLICOLOR"]         = "1"
        env["CLICOLOR_FORCE"]   = "1"

        // Inject custom prompt overlay via shell-specific mechanisms
        if let promptDir = ensurePromptOverlay(
            shell: shellPath,
            home: info.home,
            user: info.user,
            shellIntegration: shellIntegration
        ) {
            let shellName = (shellPath as NSString).lastPathComponent
            if shellName == "zsh" {
                env["ZDOTDIR"] = promptDir
            } else if shellName == "bash" || shellName == "sh" {
                let rcPath = (promptDir as NSString).appendingPathComponent(".bashrc")
                env["BASH_ENV"] = rcPath
            }
        }

        return env
    }

    // MARK: - Prompt Overlay

    /// Creates shell overlay files with custom prompt colors and optional shell integration.
    /// Returns the overlay directory path, or nil if the shell is unsupported.
    private static func ensurePromptOverlay(
        shell: String,
        home: String,
        user: String,
        shellIntegration: ShellIntegrationConfig = .init()
    ) -> String? {
        let shellName = (shell as NSString).lastPathComponent
        guard shellName == "zsh" || shellName == "bash" else { return nil }

        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let overlayDir = appSupport
            .appendingPathComponent("ProSSH", isDirectory: true)
            .appendingPathComponent("shell-overlay", isDirectory: true)
            .path

        try? fm.createDirectory(atPath: overlayDir, withIntermediateDirectories: true)

        let promptConfig = PromptAppearanceConfiguration.load()

        if shellName == "zsh" {
            let rcPath = (overlayDir as NSString).appendingPathComponent(".zshrc")
            let userRC = (home as NSString).appendingPathComponent(".zshrc")

            let promptStr = promptConfig.zshPrompt(user: user)
            let pathFunction = promptConfig.zshPathFunction()

            var zshrc = """
            # ProSSH shell overlay -- sources real .zshrc then sets custom prompt.
            export REAL_ZDOTDIR="$HOME"
            \(safeZshSourceLine(path: userRC))
            \(pathFunction)
            setopt prompt_subst
            PROMPT='\(promptStr)'
            \(zshCompletionFallback)
            """

            if shellIntegration.type == .zsh,
               let integrationScript = ShellIntegrationScripts.script(for: .zsh) {
                zshrc += "\n" + integrationScript
            }
            try? zshrc.write(toFile: rcPath, atomically: true, encoding: .utf8)

            // .zshenv — sources user's real .zshenv
            let envPath = (overlayDir as NSString).appendingPathComponent(".zshenv")
            let userEnv = (home as NSString).appendingPathComponent(".zshenv")
            let zshenv = """
            # ProSSH shell overlay -- sources real .zshenv.
            \(safeZshSourceLine(path: userEnv))
            """
            try? zshenv.write(toFile: envPath, atomically: true, encoding: .utf8)

            // .zprofile — sources user's real .zprofile
            let profilePath = (overlayDir as NSString).appendingPathComponent(".zprofile")
            let userProfile = (home as NSString).appendingPathComponent(".zprofile")
            let zprofile = """
            # ProSSH shell overlay -- sources real .zprofile.
            \(safeZshSourceLine(path: userProfile))
            """
            try? zprofile.write(toFile: profilePath, atomically: true, encoding: .utf8)

            return overlayDir
        } else {
            // bash
            let rcPath = (overlayDir as NSString).appendingPathComponent(".bashrc")
            let userRC = (home as NSString).appendingPathComponent(".bashrc")

            let promptStr = promptConfig.bashPrompt(user: user)
            let pathFunction = promptConfig.bashPathFunction()

            var bashrc = """
            # ProSSH shell overlay -- sources real .bashrc then sets custom prompt.
            \(safeBashSourceLine(path: userRC))
            \(pathFunction)
            PS1='\(promptStr)'
            """

            if shellIntegration.type == .bash,
               let integrationScript = ShellIntegrationScripts.script(for: .bash) {
                bashrc += "\n" + integrationScript
            }
            try? bashrc.write(toFile: rcPath, atomically: true, encoding: .utf8)

            return overlayDir
        }
    }

    // MARK: - Shell Source Helpers

    static func safeZshSourceLine(path: String) -> String {
        let escaped = path.replacingOccurrences(of: "\"", with: "\\\"")
        return "if [[ -r \"\(escaped)\" ]]; then ZDOTDIR=\"$HOME\" source \"\(escaped)\" 2>/dev/null; fi"
    }

    static func safeBashSourceLine(path: String) -> String {
        let escaped = path.replacingOccurrences(of: "\"", with: "\\\"")
        return "if [[ -r \"\(escaped)\" ]]; then source \"\(escaped)\" 2>/dev/null; fi"
    }

    static var zshCompletionFallback: String {
        """
        # Fallback completion when sandbox restrictions block user dotfiles.
        if [[ -o interactive ]]; then
          autoload -Uz compinit
          compinit -u -d "${TMPDIR:-/tmp}/.zcompdump-prossh-${UID}" >/dev/null 2>&1
          autoload -Uz add-zsh-hook >/dev/null 2>&1
          __prossh_force_tab_completion() {
            bindkey '^I' expand-or-complete >/dev/null 2>&1
            bindkey -M viins '^I' expand-or-complete >/dev/null 2>&1
          }
          __prossh_force_tab_completion
          add-zsh-hook precmd __prossh_force_tab_completion >/dev/null 2>&1
        fi
        """
    }
}
