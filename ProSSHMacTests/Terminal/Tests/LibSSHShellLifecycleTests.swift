#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

@MainActor
final class LibSSHShellLifecycleTests: XCTestCase {
    func testLocalSSHDRepeatedShellOpenAndDisconnect() async throws {
        let sshd = try await LocalSSHD.start()
        defer { sshd.stop() }
        let transport = LibSSHTransport(credentialResolver: sshd.credentialResolver)
        let host = sshd.host

        for _ in 0..<5 {
            let sessionID = UUID()
            do {
                _ = try await transport.connect(sessionID: sessionID, to: host)
                try await transport.authenticate(sessionID: sessionID, to: host)
                let shell = try await transport.openShell(sessionID: sessionID, pty: .default)
                await transport.disconnect(sessionID: sessionID)
                try await shell.send("echo after disconnect\n")
            } catch {
                await transport.disconnect(sessionID: sessionID)
                throw error
            }
        }

        for _ in 0..<5 {
            let sessionID = UUID()
            _ = try await transport.connect(sessionID: sessionID, to: host)
            try await transport.authenticate(sessionID: sessionID, to: host)
            let opening = Task {
                try await transport.openShell(sessionID: sessionID, pty: .default)
            }
            await Task.yield()
            await transport.disconnect(sessionID: sessionID)
            do {
                let shell = try await opening.value
                await shell.close()
            } catch SSHTransportError.sessionNotFound {
                // Disconnect won the race before the shell could be returned.
            }
        }
    }
}
#endif
