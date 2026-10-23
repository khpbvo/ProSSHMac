#if canImport(XCTest)
import XCTest
import Darwin
@testable import ProSSHMac

/// Local forwards through the real transport and a loopback `sshd`, to an echo server (Bug 109).
@MainActor
final class LibSSHPortForwardingTests: XCTestCase {
    func testForwardCarriesDataWithShellOpen() async throws {
        let sshd = try await LocalSSHD.start()
        addTeardownBlock { sshd.stop() }
        let echo = try LoopbackEchoServer()
        addTeardownBlock { echo.stop() }
        var farewell = Data(count: 300_000)
        farewell.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        let closing = try LoopbackEchoServer(farewell: farewell)
        addTeardownBlock { closing.stop() }

        let transport = LibSSHTransport(credentialResolver: sshd.credentialResolver)
        let sessionID = UUID()
        _ = try await transport.connect(sessionID: sessionID, to: sshd.host)
        addTeardownBlock { await transport.disconnect(sessionID: sessionID) }
        try await transport.authenticate(sessionID: sessionID, to: sshd.host)
        // The app opens the shell before it activates forwards, which leaves the session non-blocking.
        let shell = try await transport.openShell(sessionID: sessionID, pty: .default)
        addTeardownBlock { await shell.close() }

        let manager = PortForwardingManager(transport: transport)
        let port = try LoopbackSockets.freePort()
        let closingPort = try LoopbackSockets.freePort()
        await manager.activateRules([
            PortForwardingRule(localPort: port, remoteHost: "127.0.0.1", remotePort: echo.port),
            PortForwardingRule(localPort: closingPort, remoteHost: "127.0.0.1", remotePort: closing.port),
        ], sessionID: sessionID)
        addTeardownBlock { await manager.deactivateAll(for: sessionID) }
        try await waitUntil("both listeners accept") {
            let v4 = await LoopbackSockets.connects(host: "127.0.0.1", port: port)
            let v6 = await LoopbackSockets.connects(host: "::1", port: port)
            return v4 && v6
        }

        for (index, host) in ["127.0.0.1", "::1", "127.0.0.1"].enumerated() {
            let line = Data("connection \(index + 1) over \(host)\n".utf8)
            let reply = try await LoopbackSockets.exchange(host: host, port: port, payload: line)
            XCTAssertEqual(String(decoding: reply, as: UTF8.self), String(decoding: line, as: UTF8.self))
        }

        let first = Data(repeating: 0x41, count: 100_000)
        let second = Data(repeating: 0x42, count: 100_000)
        async let firstReply = LoopbackSockets.exchange(host: "127.0.0.1", port: port, payload: first)
        async let secondReply = LoopbackSockets.exchange(host: "::1", port: port, payload: second)
        let (firstEcho, secondEcho) = try await (firstReply, secondReply)
        XCTAssertTrue(firstEcho == first, "Concurrent connection 1 got \(firstEcho.count) of \(first.count) bytes back.")
        XCTAssertTrue(secondEcho == second, "Concurrent connection 2 got \(secondEcho.count) of \(second.count) bytes back.")

        // More than OpenSSH's 2 MB channel window, so the transport has to wait for it to grow.
        var large = Data(count: 4 * 1024 * 1024)
        large.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        let largeEcho = try await LoopbackSockets.exchange(host: "127.0.0.1", port: port, payload: large, timeout: 20)
        XCTAssertEqual(largeEcho.count, large.count)
        XCTAssertTrue(largeEcho == large, "4 MB through the forward came back different.")

        // The target closes first: the bytes that arrive with its EOF must still be delivered.
        for _ in 0..<3 {
            let received = try await LoopbackSockets.receiveUntilClosed(host: "127.0.0.1", port: closingPort)
            XCTAssertTrue(received == farewell, "Got \(received.count) of \(farewell.count) bytes before the server closed.")
        }
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
#endif
