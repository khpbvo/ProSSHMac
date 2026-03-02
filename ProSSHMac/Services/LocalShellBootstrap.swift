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
    static func buildEnvironment(shellPath: String) -> [String: String] {
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

        return env
    }
}
