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
    nonisolated let output: AsyncStream<String>

    // MARK: - Internal state

    private let masterFD: Int32
    private let childPID: pid_t
    private let slaveDevicePath: String
    private var rawContinuation: AsyncStream<Data>.Continuation
    private var textContinuation: AsyncStream<String>.Continuation
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
        var slave: Int32 = -1
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

        guard openpty(&master, &slave, &slaveName, &tio, &size) == 0 else {
            throw LocalShellError.ptyAllocationFailed
        }

        let slaveDevicePath = slaveName.withUnsafeBufferPointer {
            String(decoding: $0.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }

        // Close slave in parent -- child will open it by path via posix_spawn
        Darwin.close(slave)

        // Build environment for child
        let childEnv = buildChildEnvironment(base: environment)
        let envStrings = childEnv.map { "\($0.key)=\($0.value)" }

        // Set up posix_spawn file actions:
        // - close master in child
        // - open slave device as stdin (also sets controlling terminal)
        // - dup stdin to stdout and stderr
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_addclose(&fileActions, master)
        posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, slaveDevicePath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&fileActions, STDIN_FILENO, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, STDIN_FILENO, STDERR_FILENO)

        // Set up posix_spawn attributes: start a new session (like setsid())
        var spawnAttr: posix_spawnattr_t?
        posix_spawnattr_init(&spawnAttr)
        posix_spawnattr_setflags(&spawnAttr, Int16(POSIX_SPAWN_SETSID))

        // Change working directory -- use real home, not sandbox container
        let cwd = workingDirectory ?? childEnv["HOME"] ?? realHome
        if #available(macOS 26.0, *) {
            posix_spawn_file_actions_addchdir(&fileActions, cwd)
        } else {
            posix_spawn_file_actions_addchdir_np(&fileActions, cwd)
        }

        // Build argv -- login shell (prefix with -)
        let shellName = (resolvedShell as NSString).lastPathComponent
        let loginName = "-" + shellName

        // Build C string arrays for argv and envp
        let cArgv: [UnsafeMutablePointer<CChar>?] = [strdup(loginName), nil]
        let cEnvp: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) } + [nil]

        defer {
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&spawnAttr)
            for ptr in cArgv { free(ptr) }
            for ptr in cEnvp { free(ptr) }
        }

        var pid: pid_t = 0
        let spawnResult = posix_spawn(&pid, resolvedShell, &fileActions, &spawnAttr, cArgv, cEnvp)

        guard spawnResult == 0 else {
            Darwin.close(master)
            throw LocalShellError.forkFailed
        }

        // Non-blocking mode for async reads with coalescing
        let flags = fcntl(master, F_GETFL)
        if flags >= 0 {
            _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)
        }

        // Create streams
        var capturedRawContinuation: AsyncStream<Data>.Continuation?
        let rawStream = AsyncStream<Data> { continuation in
            capturedRawContinuation = continuation
        }
        var capturedTextContinuation: AsyncStream<String>.Continuation?
        let textStream = AsyncStream<String> { continuation in
            capturedTextContinuation = continuation
        }

        guard let rawCont = capturedRawContinuation,
              let textCont = capturedTextContinuation else {
            Darwin.close(master)
            kill(pid, SIGHUP)
            throw LocalShellError.ptyAllocationFailed
        }

        let channel = LocalShellChannel(
            masterFD: master,
            childPID: pid,
            slaveDevicePath: slaveDevicePath,
            rawContinuation: rawCont,
            textContinuation: textCont,
            rawOutput: rawStream,
            output: textStream
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
        textContinuation: AsyncStream<String>.Continuation,
        rawOutput: AsyncStream<Data>,
        output: AsyncStream<String>
    ) {
        self.masterFD = masterFD
        self.childPID = childPID
        self.slaveDevicePath = slaveDevicePath
        self.rawContinuation = rawContinuation
        self.textContinuation = textContinuation
        self.rawOutput = rawOutput
        self.output = output
    }

    // MARK: - SSHShellChannel methods

    func send(_ input: String) async throws {
        guard !isClosed else { return }
        let data = Array(input.utf8)
        guard !data.isEmpty else { return }

        // For signal-generating characters (Ctrl-C, Ctrl-Z, Ctrl-\),
        // temporarily force ISIG on and ensure the correct control
        // character mappings (VINTR, VQUIT, VSUSP) on the slave PTY
        // so the kernel's line discipline delivers the correct signal
        // to the foreground process group.  Shells like zsh may
        // disable ISIG or remap these characters during their
        // line-editor; we fix both and restore immediately after.
        let isSignalChar = data.count == 1
            && (data[0] == 0x03 || data[0] == 0x1A || data[0] == 0x1C)
        var savedTermios: Darwin.termios?
        var termiosFD: Int32 = -1

        if isSignalChar {
            // Line discipline and signal-generating control chars are owned
            // by the slave side of the PTY, not the master side.
            termiosFD = open(slaveDevicePath, O_RDWR | O_NOCTTY)
            if termiosFD >= 0 {
                var tio = Darwin.termios()
                if tcgetattr(termiosFD, &tio) == 0 {
                    savedTermios = tio
                    // Always force ISIG on and set the standard control
                    // character mappings.  The shell may have disabled
                    // ISIG or remapped VINTR/VQUIT/VSUSP.
                    tio.c_lflag |= tcflag_t(ISIG)
                    withUnsafeMutablePointer(to: &tio.c_cc) { ccPtr in
                        let cc = UnsafeMutableRawPointer(ccPtr)
                            .assumingMemoryBound(to: cc_t.self)
                        cc[Int(VINTR)] = 0x03  // Ctrl-C  -> SIGINT
                        cc[Int(VQUIT)] = 0x1C  // Ctrl-\  -> SIGQUIT
                        cc[Int(VSUSP)] = 0x1A  // Ctrl-Z  -> SIGTSTP
                    }
                    _ = tcsetattr(termiosFD, TCSANOW, &tio)
                }
            }

            // Use TIOCSIG to ask the kernel to deliver the signal
            // directly to the PTY's foreground process group.  This
            // is the most reliable mechanism as it bypasses the line
            // discipline entirely.
            let sig: Int32
            switch data[0] {
            case 0x03: sig = SIGINT
            case 0x1A: sig = SIGTSTP
            case 0x1C: sig = SIGQUIT
            default:   sig = 0
            }
            if sig != 0 {
                var sigValue = sig
                _ = ioctl(masterFD, TIOCSIG, &sigValue)
            }
        }

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

        if var restore = savedTermios, termiosFD >= 0 {
            _ = tcsetattr(termiosFD, TCSANOW, &restore)
        }
        if termiosFD >= 0 {
            Darwin.close(termiosFD)
        }

        // Additional safety net: also send the signal directly to the
        // terminal's foreground process group via kill().
        if isSignalChar {
            switch data[0] {
            case 0x03: sendSignalToForegroundGroup(SIGINT)
            case 0x1A: sendSignalToForegroundGroup(SIGTSTP)
            case 0x1C: sendSignalToForegroundGroup(SIGQUIT)
            default: break
            }
        }
    }

    /// Send a signal to the foreground process group of the terminal.
    private func sendSignalToForegroundGroup(_ sig: Int32) {
        var targetedGroups = Set<pid_t>()

        func signalProcessGroup(_ pgrp: pid_t) {
            guard pgrp > 0, !targetedGroups.contains(pgrp) else { return }
            _ = kill(-pgrp, sig)
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
                _ = kill(pid, sig)
                signalProcessGroup(getpgid(pid))
            }
        }

        // 5) Last resort: direct shell signal.
        _ = kill(childPID, sig)
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
        textContinuation.finish()
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

                    let text = String(decoding: accumulated, as: UTF8.self)
                    await self?.yieldOutput(data: accumulated, text: text)
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
            await self?.yieldOutput(data: exitData, text: exitMessage)
            await self?.finishStreams()
        }
    }

    private func yieldOutput(data: Data, text: String) {
        rawContinuation.yield(data)
        textContinuation.yield(text)
    }

    private func finishStreams() {
        rawContinuation.finish()
        textContinuation.finish()
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
