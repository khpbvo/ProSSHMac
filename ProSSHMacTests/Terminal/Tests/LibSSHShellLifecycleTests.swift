#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

@MainActor
final class LibSSHShellLifecycleTests: XCTestCase {
    func testLocalSSHDRepeatedShellOpenAndDisconnect() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProSSHLibSSHTest.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let hostKey = directory.appendingPathComponent("host_key")
        let userKey = directory.appendingPathComponent("user_key")
        try runTool("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", hostKey.path])
        try runTool("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", userKey.path])
        let authorizedKeys = directory.appendingPathComponent("authorized_keys")
        try Data(contentsOf: userKey.appendingPathExtension("pub")).write(to: authorizedKeys)

        let port = UInt16.random(in: 40000...60000)
        let config = directory.appendingPathComponent("sshd_config")
        let log = directory.appendingPathComponent("sshd.log")
        let username = NSUserName()
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
        server.arguments = ["-D", "-f", config.path, "-E", log.path]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer {
            if server.isRunning { server.terminate() }
            server.waitUntilExit()
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(server.isRunning, "Local sshd exited; see its temporary log.")

        let keyReference = UUID()
        let privateKey = try String(contentsOf: userKey, encoding: .utf8)
        let transport = LibSSHTransport(credentialResolver: LocalSSHKeyResolver(keyReference: keyReference, privateKey: privateKey))
        let host = ProSSHMac.Host(
            id: UUID(), label: "local-test", folder: nil, hostname: "127.0.0.1", port: port,
            username: username, authMethod: .publicKey, keyReference: keyReference,
            certificateReference: nil, passwordReference: nil, jumpHost: nil,
            algorithmPreferences: nil, pinnedHostKeyAlgorithms: [], legacyModeEnabled: false,
            tags: [], notes: nil, lastConnected: nil, createdAt: Date()
        )

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

    private func runTool(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(path) failed")
    }
}

nonisolated private struct LocalSSHKeyResolver: SSHCredentialResolving {
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
#endif
