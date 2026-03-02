// LocalPTYProcess.swift
// ProSSHMac
//
// Minimal PTY process: forkpty, read loop, write, resize, close.

import Foundation
import Darwin

actor LocalPTYProcess {
    nonisolated let rawOutput: AsyncStream<Data>

    private let masterFD: Int32
    private let childPID: pid_t
    private let continuation: AsyncStream<Data>.Continuation
    private var readerTask: Task<Void, Never>?
    private var isClosed = false

    // MARK: - Spawn

    static func spawn(
        columns: Int,
        rows: Int,
        shellPath: String,
        environment: [String: String],
        workingDirectory: String
    ) async throws -> LocalPTYProcess {
        var master: Int32 = -1
        var size = winsize(
            ws_row: UInt16(rows),
            ws_col: UInt16(columns),
            ws_xpixel: 0,
            ws_ypixel: 0
        )

        // Build a proper cooked-mode termios.
        // Passing nil to forkpty on a GUI process (which has no controlling tty)
        // produces a zeroed struct with a zero baud rate, causing zsh to fail
        // tcsetpgrp with "can't set tty pgrp: Operation not permitted".
        // We construct the flags explicitly to match what Terminal.app passes.
        var tio = Darwin.termios()
        tio.c_iflag = tcflag_t(ICRNL | IXON | IXANY | IMAXBEL | IUTF8)
        tio.c_oflag = tcflag_t(OPOST | ONLCR)
        tio.c_cflag = tcflag_t(CS8 | CREAD | HUPCL)
        tio.c_lflag = tcflag_t(ICANON | ISIG | IEXTEN | ECHO | ECHOE | ECHOK | ECHOKE | ECHOCTL)
        withUnsafeMutablePointer(to: &tio.c_cc) { ccPtr in
            let cc = UnsafeMutableRawPointer(ccPtr).assumingMemoryBound(to: cc_t.self)
            cc[Int(VEOF)]   = 0x04  // Ctrl-D
            cc[Int(VERASE)] = 0x7F  // DEL
            cc[Int(VKILL)]  = 0x15  // Ctrl-U
            cc[Int(VINTR)]  = 0x03  // Ctrl-C
            cc[Int(VQUIT)]  = 0x1C  // Ctrl-\
            cc[Int(VSUSP)]  = 0x1A  // Ctrl-Z
            cc[Int(VSTART)] = 0x11  // Ctrl-Q
            cc[Int(VSTOP)]  = 0x13  // Ctrl-S
            cc[Int(VMIN)]   = 1
            cc[Int(VTIME)]  = 0
        }
        _ = cfsetispeed(&tio, speed_t(B38400))
        _ = cfsetospeed(&tio, speed_t(B38400))

        let pid = forkpty(&master, nil, &tio, &size)
        guard pid >= 0 else {
            if master >= 0 { Darwin.close(master) }
            throw LocalShellError.forkFailed
        }

        if pid == 0 {
            // ── Child process ──────────────────────────────────────────────
            //
            // Become a new session leader so we own the PTY as our controlling
            // terminal. forkpty already called setsid() for us, but we call it
            // again defensively. Then TIOCSCTTY acquires the slave pty as the
            // controlling terminal, which is what lets tcsetpgrp succeed.
            _ = setsid()
            _ = ioctl(0, TIOCSCTTY, 1)

            _ = chdir(workingDirectory)

            // Replace the entire environment with our clean set.
            // clearenv() is essential: the GUI app inherits vars like ZDOTDIR,
            // __CF_USER_TEXT_ENCODING, DYLD_* etc. that corrupt zsh startup.
            clearenv()
            for (key, value) in environment {
                key.withCString { k in
                    value.withCString { v in
                        _ = setenv(k, v, 1)
                    }
                }
            }

            // Launch as a login shell: argv[0] = "-zsh"
            let shellName = (shellPath as NSString).lastPathComponent
            let loginName = "-" + shellName
            var argv: [UnsafeMutablePointer<CChar>?] = [strdup(loginName), nil]
            shellPath.withCString { shellPtr in
                argv.withUnsafeMutableBufferPointer { buf in
                    _ = execv(shellPtr, buf.baseAddress)
                }
            }
            free(argv[0])
            _exit(127)
        }

        // Parent: set master fd non-blocking
        let flags = fcntl(master, F_GETFL)
        if flags >= 0 {
            _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)
        }

        var capturedContinuation: AsyncStream<Data>.Continuation?
        let stream = AsyncStream<Data> { cont in capturedContinuation = cont }
        guard let cont = capturedContinuation else {
            Darwin.close(master)
            kill(pid, SIGHUP)
            throw LocalShellError.ptyAllocationFailed
        }

        let process = LocalPTYProcess(masterFD: master, childPID: pid, continuation: cont, rawOutput: stream)
        await process.startReader()
        return process
    }

    private init(
        masterFD: Int32,
        childPID: pid_t,
        continuation: AsyncStream<Data>.Continuation,
        rawOutput: AsyncStream<Data>
    ) {
        self.masterFD = masterFD
        self.childPID = childPID
        self.continuation = continuation
        self.rawOutput = rawOutput
    }

    // MARK: - Write

    func send(bytes: [UInt8]) async throws {
        guard !isClosed, !bytes.isEmpty else { return }
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBufferPointer { buf -> Int in
                guard let base = buf.baseAddress else { return -1 }
                return Darwin.write(masterFD, base + offset, bytes.count - offset)
            }
            if n > 0 { offset += n; continue }
            if n == 0 { continue }
            let err = errno
            if err == EINTR { continue }
            if err == EAGAIN || err == EWOULDBLOCK {
                try await Task.sleep(for: .milliseconds(1))
                continue
            }
            throw LocalShellError.writeFailed(err)
        }
    }

    // MARK: - Resize

    func resizePTY(columns: Int, rows: Int) async throws {
        guard !isClosed else { return }
        var size = winsize(
            ws_row: UInt16(rows),
            ws_col: UInt16(columns),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        if ioctl(masterFD, TIOCSWINSZ, &size) != 0 {
            throw LocalShellError.resizeFailed(errno)
        }
    }

    // MARK: - Close

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        readerTask?.cancel()
        readerTask = nil
        kill(childPID, SIGHUP)
        let pid = childPID
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                var status: Int32 = 0
                _ = waitpid(pid, &status, 0)
                cont.resume()
            }
        }
        Darwin.close(masterFD)
        continuation.finish()
    }

    // MARK: - Reader

    private func startReader() {
        let fd = masterFD
        let pid = childPID

        readerTask = Task.detached { [weak self] in
            let bufSize = 65536
            var buf = [UInt8](repeating: 0, count: bufSize)

            outer: while !Task.isCancelled {
                // Wait up to 100 ms for data
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let pollRet = withUnsafeMutablePointer(to: &pfd) { Darwin.poll($0, 1, 100) }

                if pollRet == 0 { continue }   // timeout
                if pollRet < 0 {
                    if errno == EINTR { continue }
                    break
                }

                // Drain all available data in one pass
                var chunk = Data()
                inner: while true {
                    let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
                        guard let base = ptr.baseAddress else { return -1 }
                        return Darwin.read(fd, base, ptr.count)
                    }
                    if n > 0 { chunk.append(contentsOf: buf.prefix(n)); continue }
                    if n == 0 { break outer }
                    let err = errno
                    if err == EINTR { continue }
                    if err == EAGAIN || err == EWOULDBLOCK { break inner }
                    if err == EIO { break outer }
                    break outer
                }

                if !chunk.isEmpty {
                    await self?.yield(chunk)
                }
            }

            var status: Int32 = 0
            let exitCode: Int32
            if waitpid(pid, &status, WNOHANG) > 0, status & 0x7F == 0 {
                exitCode = (status >> 8) & 0xFF
            } else {
                exitCode = 0
            }
            let msg = "\r\n[Process completed with exit code \(exitCode)]\r\n"
            await self?.yield(Data(msg.utf8))
            await self?.finish()
        }
    }

    private func yield(_ data: Data) { continuation.yield(data) }
    private func finish() { continuation.finish() }
}
