#if canImport(XCTest)
import XCTest
import Darwin
import Network
@testable import ProSSHMac

@MainActor
final class PortForwardingManagerTests: XCTestCase {
    func testPendingOpenClosesChannelAfterForwardStops() async throws {
        let transport = DelayedForwardTransport()
        let manager = PortForwardingManager(transport: transport)
        let sessionID = UUID()
        let rule = PortForwardingRule(localPort: try LoopbackSockets.freePort(), remoteHost: "localhost", remotePort: 22)
        await manager.activateRules([rule], sessionID: sessionID)
        let forwardID = try XCTUnwrap(manager.activeForwards.first?.id)
        XCTAssertEqual(manager.activeForwards.first?.state, .listening)
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: 9)!, using: .tcp)

        let openTask = Task {
            await manager.handleNewConnection(
                connection,
                forwardID: forwardID,
                sessionID: sessionID,
                rule: rule,
                transport: transport,
                maxConnections: 32
            )
        }
        await transport.waitUntilOpening()
        let stopTask = Task { await manager.stopForward(id: forwardID) }
        await Task.yield()

        let channel = ClosingForwardChannel()
        transport.finishOpen(with: channel)
        await openTask.value
        await stopTask.value

        XCTAssertTrue(channel.wasClosed)
        XCTAssertTrue(manager.activeForwards.isEmpty)
    }

    /// Bug 97: a local forward must accept 127.0.0.1 and ::1, and nothing from the network.
    func testForwardAcceptsLoopbackOnly() async throws {
        let transport = RecordingForwardTransport()
        let manager = PortForwardingManager(transport: transport)
        let sessionID = UUID()
        let port = try LoopbackSockets.freePort()
        await manager.activateRules([PortForwardingRule(localPort: port, remoteHost: "localhost", remotePort: 22)], sessionID: sessionID)
        addTeardownBlock { await manager.deactivateAll(for: sessionID) }

        for (index, host) in ["127.0.0.1", "::1"].enumerated() {
            try await waitUntil("\(host) connects") { await LoopbackSockets.connects(host: host, port: port) }
            try await waitUntil("\(host) reaches the transport") { transport.openCount == index + 1 }
        }

        guard let address = LoopbackSockets.nonLoopbackAddress() else {
            throw XCTSkip("This machine has no non-loopback address to connect from.")
        }
        let connected = await LoopbackSockets.connects(host: address, port: port)
        XCTAssertFalse(connected, "The forward accepted a connection on \(address).")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(transport.openCount, 2, "A connection on \(address) reached the transport.")
    }

    func testPortInUseOnOneFamilyFailsTheRule() async throws {
        let manager = PortForwardingManager(transport: RecordingForwardTransport())
        let sessionID = UUID()
        let port = try LoopbackSockets.freePort()
        let holder = try LoopbackSockets.listenOnIPv6Loopback(port: port)
        defer { close(holder) }

        await manager.activateRules([PortForwardingRule(localPort: port, remoteHost: "localhost", remotePort: 22)], sessionID: sessionID)
        addTeardownBlock { await manager.deactivateAll(for: sessionID) }

        try await waitUntil("the rule fails") { manager.activeForwards.first?.state == .error }
        // The other family's listener is cancelled; its cancellation must not report `.stopped`.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(manager.activeForwards.first?.state, .error)
        XCTAssertNotNil(manager.activeForwards.first?.errorMessage)
        let connected = await LoopbackSockets.connects(host: "127.0.0.1", port: port)
        XCTAssertFalse(connected, "The IPv4 listener stayed open after the rule failed.")
    }

    private func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(3),
        _ condition: () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Not met within \(timeout): \(description)", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// Plain BSD sockets, so the tests see what any other process on the machine would.
nonisolated private enum LoopbackSockets {
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
        await Task.detached { connectBlocking(host: host, port: port) }.value
    }

    private static func connectBlocking(host: String, port: UInt16) -> Bool {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = AI_NUMERICHOST
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let address = info else { return false }
        defer { freeaddrinfo(info) }
        let fd = socket(address.pointee.ai_family, SOCK_STREAM, 0)
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        if connect(fd, address.pointee.ai_addr, address.pointee.ai_addrlen) == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&poller, 1, 1000) > 0 else { return false }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
        return error == 0
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

@MainActor private final class ClosingForwardChannel: SSHForwardChannel {
    private(set) var wasClosed = false
    var isOpen: Bool { !wasClosed }
    func read() async throws -> Data? { nil }
    func write(_ data: Data) async throws {}
    func close() async { wasClosed = true }
}

/// Counts the connections the listener hands over, then refuses each one.
@MainActor private final class RecordingForwardTransport: SSHTransporting {
    private(set) var openCount = 0

    func openForwardChannel(sessionID: UUID, remoteHost: String, remotePort: UInt16, sourceHost: String, sourcePort: UInt16) async throws -> any SSHForwardChannel {
        openCount += 1
        throw SSHTransportError.sessionNotFound
    }

    func connect(sessionID: UUID, to host: ProSSHMac.Host, jumpHostConfig: JumpHostConfig?) async throws -> SSHConnectionDetails { throw SSHTransportError.sessionNotFound }
    func authenticate(sessionID: UUID, to host: ProSSHMac.Host, passwordOverride: String?, keyPassphraseOverride: String?) async throws { throw SSHTransportError.sessionNotFound }
    func openShell(sessionID: UUID, pty: PTYConfiguration, enableAgentForwarding: Bool) async throws -> any SSHShellChannel { throw SSHTransportError.sessionNotFound }
    func listDirectory(sessionID: UUID, path: String) async throws -> [SFTPDirectoryEntry] { throw SSHTransportError.sessionNotFound }
    func uploadFile(sessionID: UUID, localPath: String, remotePath: String) async throws -> SFTPTransferResult { throw SSHTransportError.sessionNotFound }
    func downloadFile(sessionID: UUID, remotePath: String, localPath: String) async throws -> SFTPTransferResult { throw SSHTransportError.sessionNotFound }
    func sendKeepalive(sessionID: UUID) async -> Bool { false }
    func disconnect(sessionID: UUID) async {}
}

@MainActor private final class DelayedForwardTransport: SSHTransporting {
    private var openContinuation: CheckedContinuation<any SSHForwardChannel, Error>?
    private var openingWaiter: CheckedContinuation<Void, Never>?

    func waitUntilOpening() async {
        if openContinuation != nil { return }
        await withCheckedContinuation { openingWaiter = $0 }
    }

    func finishOpen(with channel: any SSHForwardChannel) {
        openContinuation?.resume(returning: channel)
        openContinuation = nil
    }

    func openForwardChannel(sessionID: UUID, remoteHost: String, remotePort: UInt16, sourceHost: String, sourcePort: UInt16) async throws -> any SSHForwardChannel {
        try await withCheckedThrowingContinuation { continuation in
            openContinuation = continuation
            openingWaiter?.resume()
            openingWaiter = nil
        }
    }

    func connect(sessionID: UUID, to host: ProSSHMac.Host, jumpHostConfig: JumpHostConfig?) async throws -> SSHConnectionDetails { throw SSHTransportError.sessionNotFound }
    func authenticate(sessionID: UUID, to host: ProSSHMac.Host, passwordOverride: String?, keyPassphraseOverride: String?) async throws { throw SSHTransportError.sessionNotFound }
    func openShell(sessionID: UUID, pty: PTYConfiguration, enableAgentForwarding: Bool) async throws -> any SSHShellChannel { throw SSHTransportError.sessionNotFound }
    func listDirectory(sessionID: UUID, path: String) async throws -> [SFTPDirectoryEntry] { throw SSHTransportError.sessionNotFound }
    func uploadFile(sessionID: UUID, localPath: String, remotePath: String) async throws -> SFTPTransferResult { throw SSHTransportError.sessionNotFound }
    func downloadFile(sessionID: UUID, remotePath: String, localPath: String) async throws -> SFTPTransferResult { throw SSHTransportError.sessionNotFound }
    func sendKeepalive(sessionID: UUID) async -> Bool { false }
    func disconnect(sessionID: UUID) async {}
}
#endif
