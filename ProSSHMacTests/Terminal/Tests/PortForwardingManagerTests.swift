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
