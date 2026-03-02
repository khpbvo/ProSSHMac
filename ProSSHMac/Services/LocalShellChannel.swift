// LocalShellChannel.swift
// ProSSHMac
//
// PTY-backed local shell channel for macOS.
// Conforms to SSHShellChannel so SessionManager's existing parser
// pipeline (grid -> VTParser -> snapshot -> renderer) works unchanged.

import Foundation
import Darwin

actor LocalShellChannel: SSHShellChannel {

    // MARK: - SSHShellChannel conformance

    nonisolated let rawOutput: AsyncStream<Data>

    // MARK: - Internal state

    private let masterFD: Int32
    private let childPID: pid_t
    private let slaveDevicePath: String
    private var rawContinuation: AsyncStream<Data>.Continuation
    private var readerTask: Task<Void, Never>?
    private var isClosed = false

    // MARK: - Factory

    static func spawn(
        columns: Int = 80,
        rows: Int = 24,
        shellPath: String? = nil,
        environment: [String: String]? = nil,
        workingDirectory: String? = nil,
        shellIntegration: ShellIntegrationConfig = .init()
    ) async throws -> LocalShellChannel {
        let (realHome, _, realShell) = resolveRealUserInfo()
        let resolvedShell = shellPath ?? realShell
        guard FileManager.default.isExecutableFile(atPath: resolvedShell) else {
            throw LocalShellError.shellNotFound(resolvedShell)
        }

        // Create PTY pair
        var master: Int32 = -1
        var slaveName = [CChar](repeating: 0, count: 128)
        var size = winsize(
            ws_row: UInt16(rows),
            ws_col: UInt16(columns),
            ws_xpixel: 0,
            ws_ypixel: 0
        )

        // Use system-default termios — the kernel provides correct cooked-mode
        // settings (ICANON, ISIG, ECHO, standard control characters, proper
        // baud rate, etc.).  The shell will switch to raw mode for its line
        // editor (ZLE/readline) on startup, then restore cooked mode when
        // running foreground jobs.  This matches iTerm2/Terminal.app/Alacritty.

        // Build environment for child
        let childEnv = buildChildEnvironment(base: environment, shellIntegration: shellIntegration)
        // Change working directory -- use real home, not sandbox container
        let cwd = workingDirectory ?? childEnv["HOME"] ?? realHome

        // Build argv -- login shell (prefix with -)
        let shellName = (resolvedShell as NSString).lastPathComponent
        let loginName = "-" + shellName

        let pid = forkpty(&master, &slaveName, nil, &size)
        guard pid >= 0 else {
            Darwin.close(master)
            throw LocalShellError.ptyAllocationFailed
        }

        let slaveDevicePath = slaveName.withUnsafeBufferPointer {
            String(decoding: $0.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }

        if pid == 0 {
            _ = chdir(cwd)

            for (key, value) in childEnv {
                key.withCString { keyPtr in
                    value.withCString { valuePtr in
                        _ = setenv(keyPtr, valuePtr, 1)
                    }
                }
            }

            var childArgv: [UnsafeMutablePointer<CChar>?] = [strdup(loginName), nil]
            resolvedShell.withCString { shellPtr in
                childArgv.withUnsafeMutableBufferPointer { argvBuffer in
                    _ = execv(shellPtr, argvBuffer.baseAddress)
                }
            }

            for ptr in childArgv where ptr != nil {
                free(ptr)
            }
            _exit(127)
        }

        // Non-blocking mode for async reads with coalescing
        let flags = fcntl(master, F_GETFL)
        if flags >= 0 {
            _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)
        }

        // Create raw output stream
        var capturedRawContinuation: AsyncStream<Data>.Continuation?
        let rawStream = AsyncStream<Data> { continuation in
            capturedRawContinuation = continuation
        }

        guard let rawCont = capturedRawContinuation else {
            Darwin.close(master)
            kill(pid, SIGHUP)
            throw LocalShellError.ptyAllocationFailed
        }

        let channel = LocalShellChannel(
            masterFD: master,
            childPID: pid,
            slaveDevicePath: slaveDevicePath,
            rawContinuation: rawCont,
            rawOutput: rawStream
        )

        await channel.startReaderTask()
        return channel
    }

    static func respawn(from previous: LocalShellChannel) async throws -> LocalShellChannel {
        await previous.close()
        return try await spawn()
    }

    // MARK: - Init

    private init(
        masterFD: Int32,
        childPID: pid_t,
        slaveDevicePath: String,
        rawContinuation: AsyncStream<Data>.Continuation,
        rawOutput: AsyncStream<Data>
    ) {
        self.masterFD = masterFD
        self.childPID = childPID
        self.slaveDevicePath = slaveDevicePath
        self.rawContinuation = rawContinuation
        self.rawOutput = rawOutput
    }

    // MARK: - SSHShellChannel methods

    func send(_ input: String) async throws {
        guard !isClosed else { return }
        let data = Array(input.utf8)
        guard !data.isEmpty else { return }

        // Write raw bytes to the PTY master — the kernel line discipline
        // handles everything (signal delivery when ISIG is set, echo when
        // ECHO is set, etc.).  This matches how LibSSHShellChannel.send()
        // works and how every standard terminal emulator passes input.
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBufferPointer { buffer -> Int in
                guard let ptr = buffer.baseAddress else { return -1 }
                return Darwin.write(masterFD, ptr + offset, data.count - offset)
            }

            if written > 0 {
                offset += written
                continue
            }

            if written == 0 {
                continue
            }

            let err = errno
            if err == EINTR {
                continue
            }
            if err == EAGAIN || err == EWOULDBLOCK {
                try await Task.sleep(for: .milliseconds(1))
                continue
            }
            throw LocalShellError.writeFailed(err)
        }
    }

    @discardableResult
    private func sendSignalToForegroundGroup(_ sig: Int32) -> Bool {
        var targetedGroups = Set<pid_t>()
        var delivered = false

        func signalProcessGroup(_ pgrp: pid_t) {
            guard pgrp > 0, !targetedGroups.contains(pgrp) else { return }
            if kill(-pgrp, sig) == 0 {
                delivered = true
            }
            targetedGroups.insert(pgrp)
        }

        // 1) Foreground group reported by master side.
        signalProcessGroup(tcgetpgrp(masterFD))

        // 2) Foreground group reported by slave side.
        let slaveFD = open(slaveDevicePath, O_RDONLY | O_NOCTTY)
        if slaveFD >= 0 {
            signalProcessGroup(tcgetpgrp(slaveFD))
            Darwin.close(slaveFD)
        }

        // 3) Shell process group as baseline.
        signalProcessGroup(getpgid(childPID))

        // 4) Child jobs and their process groups.
        var childPIDs = [pid_t](repeating: 0, count: 128)
        let bufSize = Int32(childPIDs.count * MemoryLayout<pid_t>.stride)
        let filled = proc_listchildpids(childPID, &childPIDs, bufSize)
        if filled > 0 {
            let count = Int(filled) / MemoryLayout<pid_t>.stride
            for i in 0..<count {
                let pid = childPIDs[i]
                guard pid > 0 else { continue }
                if kill(pid, sig) == 0 {
                    delivered = true
                }
                signalProcessGroup(getpgid(pid))
            }
        }

        // 5) Last resort: direct shell signal.
        if kill(childPID, sig) == 0 {
            delivered = true
        }

        return delivered
    }

    func resizePTY(columns: Int, rows: Int) async throws {
        guard !isClosed else { return }
        var size = winsize(
            ws_row: UInt16(rows),
            ws_col: UInt16(columns),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        _ = ioctl(masterFD, TIOCSWINSZ, &size)
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true

        readerTask?.cancel()
        readerTask = nil

        kill(childPID, SIGHUP)

        // Dispatch waitpid to a non-cooperative thread to avoid blocking
        // the Swift concurrency cooperative thread pool.
        let pid = childPID
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var status: Int32 = 0
                waitpid(pid, &status, 0)
                continuation.resume(returning: ())
            }
        }

        Darwin.close(masterFD)
        rawContinuation.finish()
    }

    // MARK: - Reader

    private func startReaderTask() {
        let fd = masterFD
        let pid = childPID

        readerTask = Task.detached { [weak self] in
            // 64KB buffer to reduce chunk fragmentation for full-screen TUIs.
            let bufferSize = 65536
            // Keep collecting for a short idle window so full-screen TUIs
            // are rendered as coherent frames rather than tiny fragments.
            let coalesceIdlePollMS = 2
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            var shouldExit = false

            while !Task.isCancelled && !shouldExit {
                var pollFD = pollfd(
                    fd: fd,
                    events: Int16(POLLIN),
                    revents: 0
                )
                let pollResult = withUnsafeMutablePointer(to: &pollFD) { ptr in
                    Darwin.poll(ptr, 1, 100)
                }

                if pollResult == 0 {
                    continue
                }
                if pollResult < 0 {
                    if errno == EINTR {
                        continue
                    }
                    break
                }

                var accumulated = Data()
                while true {
                    let bytesRead = buffer.withUnsafeMutableBufferPointer { ptr -> Int in
                        guard let base = ptr.baseAddress else { return -1 }
                        return Darwin.read(fd, base, ptr.count)
                    }

                    if bytesRead > 0 {
                        accumulated.append(contentsOf: buffer.prefix(bytesRead))
                        continue
                    }

                    if bytesRead == 0 {
                        shouldExit = true
                        break
                    }

                    let err = errno
                    if err == EINTR {
                        continue
                    }
                    if err == EAGAIN || err == EWOULDBLOCK {
                        // Briefly wait for follow-up bytes from the same redraw burst.
                        var coalescePollFD = pollfd(
                            fd: fd,
                            events: Int16(POLLIN),
                            revents: 0
                        )
                        let coalesceResult = withUnsafeMutablePointer(to: &coalescePollFD) { ptr in
                            Darwin.poll(ptr, 1, Int32(coalesceIdlePollMS))
                        }
                        if coalesceResult > 0 {
                            continue
                        }
                        if coalesceResult < 0, errno == EINTR {
                            continue
                        }
                        break
                    }
                    if err == EIO {
                        shouldExit = true
                        break
                    }

                    shouldExit = true
                    break
                }

                if !accumulated.isEmpty {
                    await self?.yieldOutput(data: accumulated)
                }

                if shouldExit {
                    break
                }

                let hasHangupOrError = (pollFD.revents & Int16(POLLHUP | POLLERR | POLLNVAL)) != 0
                if hasHangupOrError {
                    // Drain once more if needed, then exit.
                    var tail = Data()
                    while true {
                        let bytesRead = buffer.withUnsafeMutableBufferPointer { ptr -> Int in
                            guard let base = ptr.baseAddress else { return -1 }
                            return Darwin.read(fd, base, ptr.count)
                        }
                        if bytesRead > 0 {
                            tail.append(contentsOf: buffer.prefix(bytesRead))
                            continue
                        }
                        if bytesRead < 0, errno == EINTR {
                            continue
                        }
                        if bytesRead < 0, (errno == EAGAIN || errno == EWOULDBLOCK) {
                            break
                        }
                        break
                    }

                    if !tail.isEmpty {
                        await self?.yieldOutput(data: tail)
                    }
                    break
                }
            }

            // Get exit code
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            let exitCode: Int32
            if result > 0 {
                if status & 0x7F == 0 { // WIFEXITED
                    exitCode = (status >> 8) & 0xFF // WEXITSTATUS
                } else {
                    exitCode = -1
                }
            } else {
                exitCode = 0
            }

            let exitMessage = "\r\n[Process completed with exit code \(exitCode)]"
            let exitData = Data(exitMessage.utf8)
            await self?.yieldOutput(data: exitData)
            await self?.finishStreams()
        }
    }

    private func yieldOutput(data: Data) {
        rawContinuation.yield(data)
    }

    private func finishStreams() {
        rawContinuation.finish()
    }

    // MARK: - Environment

    static func buildChildEnvironment(base: [String: String]? = nil, shellIntegration: ShellIntegrationConfig = .init()) -> [String: String] {
        let parentEnv = ProcessInfo.processInfo.environment
        var env: [String: String] = [:]

        let (realHome, realUser, realShell) = resolveRealUserInfo()

        // Inherit locale and temp dir from parent
        let inheritKeys = ["LANG", "TMPDIR"]
        for key in inheritKeys {
            if let value = parentEnv[key] {
                env[key] = value
            }
        }

        // Inherit LC_* variables
        for (key, value) in parentEnv where key.hasPrefix("LC_") {
            env[key] = value
        }

        // Set real user identity
        env["HOME"] = realHome
        env["USER"] = realUser
        env["LOGNAME"] = realUser
        env["SHELL"] = realShell
        env["PATH"] = parentEnv["PATH"] ?? "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

        // Apply base overrides
        if let base {
            for (key, value) in base {
                env[key] = value
            }
        }

        // Set terminal identification
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "ProSSH"
        env["TERM_PROGRAM_VERSION"] = "2.0"

        // Enable color output for common macOS/BSD tools (ls, grep, etc.)
        env["CLICOLOR"] = "1"
        env["CLICOLOR_FORCE"] = "1"

        // Inject rainbow prompt and shell integration via shell-specific mechanisms.
        let promptDir = Self.ensurePromptOverlay(
            shell: realShell,
            home: realHome,
            user: realUser,
            shellIntegration: shellIntegration
        )
        if let promptDir {
            let shellName = (realShell as NSString).lastPathComponent
            if shellName == "zsh" {
                env["ZDOTDIR"] = promptDir
            } else if shellName == "bash" || shellName == "sh" {
                let rcPath = (promptDir as NSString).appendingPathComponent(".bashrc")
                env["BASH_ENV"] = rcPath
            }
        }

        return env
    }

    // MARK: - Rainbow Prompt

    private static func ensurePromptOverlay(shell: String, home: String, user: String, shellIntegration: ShellIntegrationConfig = .init()) -> String? {
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

            let zshrc = """
# ProSSH shell overlay -- sources real .zshrc then sets custom prompt.
export REAL_ZDOTDIR="$HOME"
\(safeZshSourceLine(path: userRC))
\(pathFunction)
setopt prompt_subst
PROMPT='\(promptStr)'
\(zshCompletionFallback)
"""
            // Append shell integration script if configured for zsh
            if shellIntegration.type == .zsh, let integrationScript = ShellIntegrationScripts.script(for: .zsh) {
                let fullZshrc = zshrc + "\n" + integrationScript
                try? fullZshrc.write(toFile: rcPath, atomically: true, encoding: .utf8)
            } else {
                try? zshrc.write(toFile: rcPath, atomically: true, encoding: .utf8)
            }

            let envPath = (overlayDir as NSString).appendingPathComponent(".zshenv")
            let userEnv = (home as NSString).appendingPathComponent(".zshenv")
            let zshenv = """
# ProSSH shell overlay -- sources real .zshenv.
\(safeZshSourceLine(path: userEnv))
"""
            try? zshenv.write(toFile: envPath, atomically: true, encoding: .utf8)

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

            let bashrc = """
# ProSSH shell overlay -- sources real .bashrc then sets custom prompt.
\(safeBashSourceLine(path: userRC))
\(pathFunction)
PS1='\(promptStr)'
"""
            // Append shell integration script if configured for bash
            if shellIntegration.type == .bash, let integrationScript = ShellIntegrationScripts.script(for: .bash) {
                let fullBashrc = bashrc + "\n" + integrationScript
                try? fullBashrc.write(toFile: rcPath, atomically: true, encoding: .utf8)
            } else {
                try? bashrc.write(toFile: rcPath, atomically: true, encoding: .utf8)
            }
            return overlayDir
        }
    }

    private static func resolveRealUserInfo() -> (home: String, user: String, shell: String) {
        guard let pw = getpwuid(getuid()) else {
            let env = ProcessInfo.processInfo.environment
            return (
                home: env["HOME"] ?? NSHomeDirectory(),
                user: env["USER"] ?? "unknown",
                shell: env["SHELL"] ?? "/bin/zsh"
            )
        }
        return (
            home: String(cString: pw.pointee.pw_dir),
            user: String(cString: pw.pointee.pw_name),
            shell: String(cString: pw.pointee.pw_shell)
        )
    }

    nonisolated static func safeZshSourceLine(path: String) -> String {
        let escaped = path.replacingOccurrences(of: "\"", with: "\\\"")
        return "if [[ -r \"\(escaped)\" ]]; then ZDOTDIR=\"$HOME\" source \"\(escaped)\" 2>/dev/null; fi"
    }

    nonisolated static func safeBashSourceLine(path: String) -> String {
        let escaped = path.replacingOccurrences(of: "\"", with: "\\\"")
        return "if [[ -r \"\(escaped)\" ]]; then source \"\(escaped)\" 2>/dev/null; fi"
    }

    nonisolated static var zshCompletionFallback: String {
        """
        # Fallback completion when sandbox restrictions block user dotfiles.
        if [[ -o interactive ]]; then
          if ! typeset -f _main_complete >/dev/null 2>&1; then
            autoload -Uz compinit
            compinit -u -d "${TMPDIR:-/tmp}/.zcompdump-prossh-${UID}" >/dev/null 2>&1
          fi
          bindkey '^I' expand-or-complete >/dev/null 2>&1
        fi
        """
    }
}

// MARK: - Errors

enum LocalShellError: LocalizedError {
    case ptyAllocationFailed
    case forkFailed
    case shellNotFound(String)
    case writeFailed(Int32)
    case platformUnsupported

    var errorDescription: String? {
        switch self {
        case .ptyAllocationFailed:
            return "Failed to allocate pseudo-terminal (PTY)."
        case .forkFailed:
            return "Failed to fork child process for local shell."
        case let .shellNotFound(path):
            return "Shell not found at path: \(path)"
        case let .writeFailed(code):
            let message = String(cString: Darwin.strerror(code))
            return "Failed to send input to local PTY (\(code)): \(message)"
        case .platformUnsupported:
            return "Local terminal is not supported on this platform."
        }
    }
}
