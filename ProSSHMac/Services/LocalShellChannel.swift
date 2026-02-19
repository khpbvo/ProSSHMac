// LocalShellChannel.swift
// ProSSHMac
//
// PTY-backed local shell channel for macOS.
// Conforms to SSHShellChannel so SessionManager's existing parser
// pipeline (grid -> VTParser -> snapshot -> renderer) works unchanged.

import Foundation
import Darwin

// FIONREAD may not be exposed through the Darwin module overlay on all
// targets.  Define it from the BSD header constant.
private let _FIONREAD: CUnsignedLong = 0x4004_667F

actor LocalShellChannel: SSHShellChannel {

    // MARK: - SSHShellChannel conformance

    nonisolated let rawOutput: AsyncStream<Data>

    // MARK: - Internal state

    private let masterFD: Int32
    private let childPID: pid_t
    private var rawContinuation: AsyncStream<Data>.Continuation
    private var readerTask: Task<Void, Never>?
    private var isClosed = false

    // MARK: - Factory

    static func spawn(
        columns: Int = 80,
        rows: Int = 24,
        shellPath: String? = nil,
        environment: [String: String]? = nil,
        workingDirectory: String? = nil
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

        // Pass explicit termios to openpty so the slave PTY has correct
        // settings from the start.  Critically this ensures ISIG is set
        // (Ctrl-C -> SIGINT, Ctrl-Z -> SIGTSTP, etc.) and the standard
        // control characters (VINTR, VEOF, VSUSP ...) are defined.
        var tio = Darwin.termios()
        cfmakeraw(&tio)          // start from a clean raw base
        // Re-enable cooked-mode flags the login shell expects:
        tio.c_iflag |= tcflag_t(ICRNL | IXON | IXANY | IMAXBEL | IUTF8)
        tio.c_oflag |= tcflag_t(OPOST | ONLCR)
        tio.c_lflag |= tcflag_t(ICANON | ISIG | IEXTEN | ECHO | ECHOE | ECHOK | ECHOKE | ECHOCTL)
        // Set standard control characters via pointer reinterpretation
        // (c_cc is a tuple in Swift; subscript access requires casting).
        withUnsafeMutablePointer(to: &tio.c_cc) { ccPtr in
            let cc = UnsafeMutableRawPointer(ccPtr).assumingMemoryBound(to: cc_t.self)
            cc[Int(VEOF)]    = 0x04  // Ctrl-D
            cc[Int(VEOL)]    = 0xFF  // disabled
            cc[Int(VERASE)]  = 0x7F  // DEL (backspace)
            cc[Int(VKILL)]   = 0x15  // Ctrl-U
            cc[Int(VINTR)]   = 0x03  // Ctrl-C  -> SIGINT
            cc[Int(VQUIT)]   = 0x1C  // Ctrl-\  -> SIGQUIT
            cc[Int(VSUSP)]   = 0x1A  // Ctrl-Z  -> SIGTSTP
            cc[Int(VSTART)]  = 0x11  // Ctrl-Q  (XON)
            cc[Int(VSTOP)]   = 0x13  // Ctrl-S  (XOFF)
            cc[Int(VMIN)]    = 1
            cc[Int(VTIME)]   = 0
        }

        // Build environment for child
        let childEnv = buildChildEnvironment(base: environment)
        // Change working directory -- use real home, not sandbox container
        let cwd = workingDirectory ?? childEnv["HOME"] ?? realHome

        // Build argv -- login shell (prefix with -)
        let shellName = (resolvedShell as NSString).lastPathComponent
        let loginName = "-" + shellName

        let pid = forkpty(&master, &slaveName, &tio, &size)
        guard pid >= 0 else {
            Darwin.close(master)
            throw LocalShellError.ptyAllocationFailed
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
        rawContinuation: AsyncStream<Data>.Continuation,
        rawOutput: AsyncStream<Data>
    ) {
        self.masterFD = masterFD
        self.childPID = childPID
        self.rawContinuation = rawContinuation
        self.rawOutput = rawOutput
    }

    // MARK: - SSHShellChannel methods

    func send(_ input: String) async throws {
        guard !isClosed else { return }
        let data = Array(input.utf8)
        guard !data.isEmpty else { return }

        data.withUnsafeBufferPointer { buffer in
            guard let ptr = buffer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(masterFD, ptr + offset, data.count - offset)
                if written < 0 {
                    break
                }
                offset += written
            }
        }
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
        var status: Int32 = 0
        waitpid(childPID, &status, 0)

        Darwin.close(masterFD)
        rawContinuation.finish()
    }

    // MARK: - Reader

    private func startReaderTask() {
        let fd = masterFD
        let pid = childPID

        readerTask = Task.detached { [weak self] in
            // 32KB buffer -- large enough for full-screen TUI redraws
            let bufferSize = 32768
            var buffer = [UInt8](repeating: 0, count: bufferSize)

            while !Task.isCancelled {
                let bytesRead = buffer.withUnsafeMutableBufferPointer { ptr -> Int in
                    guard let base = ptr.baseAddress else { return -1 }
                    return Darwin.read(fd, base, ptr.count)
                }

                if bytesRead > 0 {
                    var accumulated = Data(buffer.prefix(bytesRead))

                    // Coalesce: drain any additional data immediately
                    // available in the kernel buffer.
                    var bytesAvailable: Int32 = 0
                    while await ioctl(fd, _FIONREAD, &bytesAvailable) == 0 && bytesAvailable > 0 {
                        let toRead = min(Int(bytesAvailable), bufferSize)
                        let extra = buffer.withUnsafeMutableBufferPointer { ptr -> Int in
                            guard let base = ptr.baseAddress else { return -1 }
                            return Darwin.read(fd, base, toRead)
                        }
                        if extra > 0 {
                            accumulated.append(contentsOf: buffer.prefix(extra))
                        } else {
                            break
                        }
                    }

                    await self?.yieldOutput(data: accumulated)
                } else if bytesRead == 0 {
                    // EOF
                    break
                } else {
                    let err = errno
                    if err == EAGAIN || err == EWOULDBLOCK {
                        try? await Task.sleep(for: .milliseconds(10))
                        continue
                    }
                    if err == EIO {
                        // Child exited
                        break
                    }
                    if err == EINTR {
                        // Interrupted by signal, retry
                        continue
                    }
                    // Other error
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

    static func buildChildEnvironment(base: [String: String]? = nil) -> [String: String] {
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

        // Inject rainbow prompt via shell-specific mechanisms.
        let promptDir = Self.ensurePromptOverlay(
            shell: realShell,
            home: realHome,
            user: realUser
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

    private static func ensurePromptOverlay(shell: String, home: String, user: String) -> String? {
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

            let zshrc = """
# ProSSH shell overlay -- sources real .zshrc then sets custom prompt.
export REAL_ZDOTDIR="$HOME"
[[ -f "\(userRC)" ]] && ZDOTDIR="$HOME" source "\(userRC)"
PROMPT='\(promptStr)'
"""
            try? zshrc.write(toFile: rcPath, atomically: true, encoding: .utf8)

            let envPath = (overlayDir as NSString).appendingPathComponent(".zshenv")
            let userEnv = (home as NSString).appendingPathComponent(".zshenv")
            let zshenv = """
# ProSSH shell overlay -- sources real .zshenv.
[[ -f "\(userEnv)" ]] && ZDOTDIR="$HOME" source "\(userEnv)"
"""
            try? zshenv.write(toFile: envPath, atomically: true, encoding: .utf8)

            let profilePath = (overlayDir as NSString).appendingPathComponent(".zprofile")
            let userProfile = (home as NSString).appendingPathComponent(".zprofile")
            let zprofile = """
# ProSSH shell overlay -- sources real .zprofile.
[[ -f "\(userProfile)" ]] && ZDOTDIR="$HOME" source "\(userProfile)"
"""
            try? zprofile.write(toFile: profilePath, atomically: true, encoding: .utf8)

            return overlayDir
        } else {
            // bash
            let rcPath = (overlayDir as NSString).appendingPathComponent(".bashrc")
            let userRC = (home as NSString).appendingPathComponent(".bashrc")

            let promptStr = promptConfig.bashPrompt(user: user)

            let bashrc = """
# ProSSH shell overlay -- sources real .bashrc then sets custom prompt.
[[ -f "\(userRC)" ]] && source "\(userRC)"
PS1='\(promptStr)'
"""
            try? bashrc.write(toFile: rcPath, atomically: true, encoding: .utf8)
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
}

// MARK: - Errors

enum LocalShellError: LocalizedError {
    case ptyAllocationFailed
    case forkFailed
    case shellNotFound(String)
    case platformUnsupported

    var errorDescription: String? {
        switch self {
        case .ptyAllocationFailed:
            return "Failed to allocate pseudo-terminal (PTY)."
        case .forkFailed:
            return "Failed to fork child process for local shell."
        case let .shellNotFound(path):
            return "Shell not found at path: \(path)"
        case .platformUnsupported:
            return "Local terminal is not supported on this platform."
        }
    }
}
