#if canImport(XCTest)
import XCTest
import Network
@testable import ProSSHMac

@MainActor
final class PortForwardingManagerTests: XCTestCase {
    func testPendingOpenClosesChannelAfterForwardStops() async throws {
        let transport = DelayedForwardTransport()
        let manager = PortForwardingManager(transport: transport)
        let sessionID = UUID()
        let rule = PortForwardingRule(localPort: 0, remoteHost: "localhost", remotePort: 22)
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
}

@MainActor private final class ClosingForwardChannel: SSHForwardChannel {
    private(set) var wasClosed = false
    var isOpen: Bool { !wasClosed }
    func read() async throws -> Data? { nil }
    func write(_ data: Data) async throws {}
    func close() async { wasClosed = true }
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
