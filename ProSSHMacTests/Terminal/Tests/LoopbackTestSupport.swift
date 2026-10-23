#if canImport(XCTest)
import XCTest
import Darwin
@testable import ProSSHMac

/// A throwaway `sshd` on 127.0.0.1 that accepts one generated ed25519 user key.
@MainActor final class LocalSSHD {
    let host: ProSSHMac.Host
    let credentialResolver: LocalSSHKeyResolver
    private let directory: URL
    private let server: Process

    private init(host: ProSSHMac.Host, credentialResolver: LocalSSHKeyResolver, directory: URL, server: Process) {
        self.host = host
        self.credentialResolver = credentialResolver
        self.directory = directory
        self.server = server
    }

    static func start() async throws -> LocalSSHD {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProSSHLibSSHTest.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let hostKey = directory.appendingPathComponent("host_key")
            let userKey = directory.appendingPathComponent("user_key")
            try runTool("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", hostKey.path])
            try runTool("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", userKey.path])
            let authorizedKeys = directory.appendingPathComponent("authorized_keys")
            try Data(contentsOf: userKey.appendingPathExtension("pub")).write(to: authorizedKeys)

            let port = UInt16.random(in: 40000...60000)
            let config = directory.appendingPathComponent("sshd_config")
            let configText = """
            Port \(port)
            ListenAddress 127.0.0.1
            HostKey \(hostKey.path)
            AuthorizedKeysFile \(authorizedKeys.path)
            StrictModes no
            PasswordAuthentication no
            PubkeyAuthentication yes
            KbdInteractiveAuthentication no
            UsePAM no
            PermitRootLogin no
            PidFile \(directory.appendingPathComponent("sshd.pid").path)
            LogLevel ERROR
            """
            try configText.write(to: config, atomically: true, encoding: .utf8)
            try runTool("/usr/sbin/sshd", ["-t", "-f", config.path])

            let server = Process()
            server.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
            server.arguments = ["-D", "-f", config.path, "-E", directory.appendingPathComponent("sshd.log").path]
            server.standardOutput = FileHandle.nullDevice
            server.standardError = FileHandle.nullDevice
            try server.run()
            try await Task.sleep(for: .milliseconds(300))
            guard server.isRunning else {
                throw LocalSSHDError(message: "Local sshd exited; see its temporary log.")
            }

            let keyReference = UUID()
            let resolver = LocalSSHKeyResolver(
                keyReference: keyReference,
                privateKey: try String(contentsOf: userKey, encoding: .utf8)
            )
            let host = ProSSHMac.Host(
                id: UUID(), label: "local-test", folder: nil, hostname: "127.0.0.1", port: port,
                username: NSUserName(), authMethod: .publicKey, keyReference: keyReference,
                certificateReference: nil, passwordReference: nil, jumpHost: nil,
                algorithmPreferences: nil, pinnedHostKeyAlgorithms: [], legacyModeEnabled: false,
                tags: [], notes: nil, lastConnected: nil, createdAt: Date()
            )
            return LocalSSHD(host: host, credentialResolver: resolver, directory: directory, server: server)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func stop() {
        if server.isRunning { server.terminate() }
        server.waitUntilExit()
        try? FileManager.default.removeItem(at: directory)
    }

    private static func runTool(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw LocalSSHDError(message: "\(path) failed with status \(process.terminationStatus)")
        }
    }
}

nonisolated struct LocalSSHDError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

nonisolated struct LocalSSHKeyResolver: SSHCredentialResolving {
    let keyReference: UUID
    let privateKey: String

    nonisolated func privateKey(for reference: UUID) throws -> String {
        guard reference == keyReference else { throw SSHTransportError.sessionNotFound }
        return privateKey
    }

    nonisolated func certificate(for reference: UUID) throws -> String {
        throw SSHTransportError.sessionNotFound
    }
}

/// A TCP server on 127.0.0.1, one thread per connection, until `stop()`. It echoes, or with a
/// `farewell` sends that and closes the connection itself.
nonisolated final class LoopbackEchoServer: @unchecked Sendable {
    let port: UInt16
    private let source: DispatchSourceRead

    init(farewell: Data? = nil) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let listening = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && listen(fd, 16) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard listening else {
            close(fd)
            throw LocalSSHDError(message: "Echo server could not listen: \(String(cString: strerror(errno)))")
        }
        port = UInt16(bigEndian: address.sin_port)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        source.setEventHandler {
            while true {
                let connection = accept(fd, nil, nil)
                guard connection >= 0 else { break }
                _ = fcntl(connection, F_SETFL, fcntl(connection, F_GETFL) & ~O_NONBLOCK)
                LoopbackSockets.disableSIGPIPE(connection)
                Thread.detachNewThread {
                    if let farewell {
                        LoopbackSockets.sendAll(connection, farewell)
                        close(connection)
                    } else {
                        Self.echo(connection)
                    }
                }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    func stop() {
        source.cancel()
    }

    private static func echo(_ fd: Int32) {
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { return }
            guard LoopbackSockets.sendAll(fd, buffer[0..<count]) else { return }
        }
    }
}

/// Plain BSD sockets, so tests see what any other process on the machine would.
nonisolated enum LoopbackSockets {
    /// A port free on both 127.0.0.1 and ::1.
    static func freePort() throws -> UInt16 {
        for _ in 0..<20 {
            let v4 = socket(AF_INET, SOCK_STREAM, 0)
            defer { close(v4) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(v4, $0, length) == 0 && getsockname(v4, $0, &length) == 0
                }
            }
            guard bound else { continue }
            let port = UInt16(bigEndian: address.sin_port)
            guard let v6 = try? bindIPv6Loopback(port: port) else { continue }
            close(v6)
            return port
        }
        throw XCTSkip("No port free on both 127.0.0.1 and ::1.")
    }

    static func listenOnIPv6Loopback(port: UInt16) throws -> Int32 {
        let fd = try bindIPv6Loopback(port: port)
        guard listen(fd, 1) == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        return fd
    }

    private static func bindIPv6Loopback(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        var on: Int32 = 1
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        address.sin6_addr = in6addr_loopback
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        return fd
    }

    /// True when a TCP connection completes within one second. A refused or dropped
    /// connection is false: with the firewall in stealth mode nothing answers at all.
    static func connects(host: String, port: UInt16) async -> Bool {
        await Task.detached {
            guard let fd = connectBlocking(host: host, port: port, timeoutMilliseconds: 1000) else { return false }
            close(fd)
            return true
        }.value
    }

    /// Sends `payload` while reading the reply on another thread, until as many bytes came back,
    /// the peer closed, or nothing arrived for `timeout` seconds. Returns what came back.
    static func exchange(host: String, port: UInt16, payload: Data, timeout: Int = 10) async throws -> Data {
        try await Task.detached {
            guard let fd = connectBlocking(host: host, port: port, timeoutMilliseconds: 2000) else {
                throw LocalSSHDError(message: "Could not connect to \(host) port \(port).")
            }
            defer { close(fd) }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            var interval = timeval(tv_sec: timeout, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))

            let sent = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                _ = sendAll(fd, payload)
                sent.signal()
            }
            var received = Data()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while received.count < payload.count {
                let count = recv(fd, &buffer, buffer.count, 0)
                guard count > 0 else { break }
                received.append(contentsOf: buffer[0..<count])
            }
            shutdown(fd, SHUT_RDWR)
            sent.wait()
            return received
        }.value
    }

    /// Everything the server sends until it closes the connection.
    static func receiveUntilClosed(host: String, port: UInt16, timeout: Int = 10) async throws -> Data {
        try await Task.detached {
            guard let fd = connectBlocking(host: host, port: port, timeoutMilliseconds: 2000) else {
                throw LocalSSHDError(message: "Could not connect to \(host) port \(port).")
            }
            defer { close(fd) }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            var interval = timeval(tv_sec: timeout, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
            var received = Data()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = recv(fd, &buffer, buffer.count, 0)
                guard count > 0 else { break }
                received.append(contentsOf: buffer[0..<count])
            }
            return received
        }.value
    }

    @discardableResult
    static func sendAll<Bytes: DataProtocol>(_ fd: Int32, _ bytes: Bytes) -> Bool {
        let data = Data(bytes)
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let count = send(fd, base + offset, raw.count - offset, 0)
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }

    static func disableSIGPIPE(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// A connected socket, still non-blocking, or nil when refused, dropped or timed out.
    private static func connectBlocking(host: String, port: UInt16, timeoutMilliseconds: Int32) -> Int32? {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = AI_NUMERICHOST
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let address = info else { return nil }
        defer { freeaddrinfo(info) }
        let fd = socket(address.pointee.ai_family, SOCK_STREAM, 0)
        disableSIGPIPE(fd)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        if connect(fd, address.pointee.ai_addr, address.pointee.ai_addrlen) == 0 { return fd }
        guard errno == EINPROGRESS else {
            close(fd)
            return nil
        }
        var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard poll(&poller, 1, timeoutMilliseconds) > 0,
              getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0,
              error == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// An address of this machine that isn't loopback: IPv4 first, else a non-link-local IPv6.
    static func nonLoopbackAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var candidates: [(family: Int32, host: String)] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let address = entry.pointee.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            if family == AF_INET6, text.lowercased().hasPrefix("fe80") { continue }
            candidates.append((family, text))
        }
        return (candidates.first { $0.family == AF_INET } ?? candidates.first)?.host
    }
}
#endif
