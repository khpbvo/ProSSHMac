import Foundation
import Combine

@MainActor
final class AppDependencies: ObservableObject {
    let navigationCoordinator: AppNavigationCoordinator
    let auditLogManager: AuditLogManager
    let sessionManager: SessionManager
    let portForwardingManager: PortForwardingManager
    let hostListViewModel: HostListViewModel
    let transferManager: TransferManager
    let keyForgeViewModel: KeyForgeViewModel
    let certificatesViewModel: CertificatesViewModel
    let idleScreensaverManager: IdleScreensaverManager

    static var isScreenshotMode: Bool {
        ProcessInfo.processInfo.arguments.contains("--screenshot-mode")
    }

    static var screenshotOutputDir: String? {
        guard let idx = ProcessInfo.processInfo.arguments.firstIndex(of: "--screenshot-dir"),
              idx + 1 < ProcessInfo.processInfo.arguments.count else {
            return nil
        }
        return ProcessInfo.processInfo.arguments[idx + 1]
    }

    init() {
        let screenshotMode = Self.isScreenshotMode

        self.navigationCoordinator = AppNavigationCoordinator()

        let auditLogManager = AuditLogManager(store: FileAuditLogStore())
        self.auditLogManager = auditLogManager

        let transport = SSHTransportFactory.makePreferredTransport()
        let portForwardingManager = PortForwardingManager(transport: transport, auditLogManager: auditLogManager)
        self.portForwardingManager = portForwardingManager

        let sessionManager = SessionManager(
            transport: transport,
            knownHostsStore: FileKnownHostsStore(),
            auditLogManager: auditLogManager,
            portForwardingManager: portForwardingManager
        )
        self.sessionManager = sessionManager

        if screenshotMode {
            self.hostListViewModel = HostListViewModel(
                hostStore: ScreenshotHostStore(),
                sessionManager: sessionManager
            )
        } else {
            self.hostListViewModel = HostListViewModel(
                hostStore: FileHostStore(),
                sessionManager: sessionManager,
                auditLogManager: auditLogManager,
                searchIndexer: HostSpotlightIndexer(),
                biometricPasswordStore: BiometricPasswordStore(),
                biometricPassphraseStore: BiometricPasswordStore(service: "nl.budgetsoft.ProSSHV2.key-passphrases")
            )
        }

        let transferManager = TransferManager()
        transferManager.configure(sessionManager: sessionManager)
        self.transferManager = transferManager

        if screenshotMode {
            self.keyForgeViewModel = KeyForgeViewModel(
                keyStore: ScreenshotKeyStore(),
                keyForgeService: KeyForgeService()
            )
        } else {
            self.keyForgeViewModel = KeyForgeViewModel(
                keyStore: FileKeyStore(),
                keyForgeService: KeyForgeService()
            )
        }

        self.certificatesViewModel = CertificatesViewModel(
            service: CertificateAuthorityService(
                authorityStore: FileCertificateAuthorityStore(),
                certificateStore: FileCertificateStore(),
                secureEnclaveKeyManager: SecureEnclaveKeyManager()
            )
        )

        self.idleScreensaverManager = IdleScreensaverManager()

        if screenshotMode {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                await self?.injectScreenshotData()
                try? await Task.sleep(for: .seconds(1))
                await self?.runScreenshotCapture()
            }
        }
    }

    private func injectScreenshotData() async {
        await sessionManager.injectScreenshotSessions()

        let firstSessionID = sessionManager.sessions.first?.id ?? UUID()
        transferManager.injectScreenshotTransfers(sessionID: firstSessionID)

        certificatesViewModel.injectScreenshotData()
    }

    private func runScreenshotCapture() async {
        let outputDir = ScreenshotCapture.screenshotsDirectory()

        let tabs: [(AppNavigationSection, String)] = [
            (.hosts, "01-Hosts"),
            (.terminal, "02-Terminal"),
            (.keyForge, "03-KeyForge"),
            (.certificates, "04-Certificates"),
            (.transfers, "05-Transfers"),
            (.settings, "06-Settings"),
        ]

        for (section, filename) in tabs {
            NSLog("[Screenshot] Navigating to \(section)...")
            navigationCoordinator.navigate(to: section)

            // Yield to the main run loop so SwiftUI can update the view hierarchy
            for _ in 0..<3 {
                try? await Task.sleep(for: .milliseconds(500))
                await MainActor.run { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
            }

            NSLog("[Screenshot] Capturing \(filename)...")
            ScreenshotCapture.captureKeyWindow(to: outputDir, filename: filename)
            NSLog("[Screenshot] Saved \(filename).png")
        }

        // Signal the script that we're done
        let doneMarker = outputDir.appendingPathComponent(".screenshots-done")
        FileManager.default.createFile(atPath: doneMarker.path, contents: nil)
        NSLog("[Screenshot] All done, terminating.")

        // Quit after a brief delay
        try? await Task.sleep(for: .milliseconds(500))
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Screenshot Window Capture

import AppKit

enum ScreenshotCapture {
    static func screenshotsDirectory() -> URL {
        // Check for explicit directory from launch argument
        if let argPath = AppDependencies.screenshotOutputDir {
            let url = URL(fileURLWithPath: argPath)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        // Default: Screenshots/ next to the project source
        let projectDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // App/
            .deletingLastPathComponent() // ProSSHMac/
            .deletingLastPathComponent() // ProSSHMac (project root)
        let dir = projectDir.appendingPathComponent("Screenshots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func captureKeyWindow(to directory: URL, filename: String) {
        guard let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first,
              let view = window.contentView else {
            return
        }

        let bounds = view.bounds
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            return
        }
        view.cacheDisplay(in: bounds, to: bitmap)

        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return
        }

        let fileURL = directory.appendingPathComponent("\(filename).png")
        try? pngData.write(to: fileURL, options: .atomic)
    }
}

// MARK: - Screenshot Mode Mock Stores

@MainActor
private final class ScreenshotHostStore: HostStoreProtocol {
    func loadHosts() async throws -> [Host] {
        return ScreenshotSampleData.hosts
    }

    func saveHosts(_ hosts: [Host]) async throws {}
}

@MainActor
private final class ScreenshotKeyStore: KeyStoreProtocol {
    func loadKeys() async throws -> [StoredSSHKey] {
        return ScreenshotSampleData.keys
    }

    func saveKeys(_ keys: [StoredSSHKey]) async throws {}
}

// MARK: - Screenshot Sample Data

enum ScreenshotSampleData {

    // Stable UUIDs for cross-referencing
    static let jumpHostID = UUID(uuidString: "A0000001-0001-0001-0001-000000000001")!
    static let webAlphaID = UUID(uuidString: "A0000001-0001-0001-0001-000000000002")!
    static let dbPrimaryID = UUID(uuidString: "A0000001-0001-0001-0001-000000000003")!
    static let deployKeyID = UUID(uuidString: "B0000001-0001-0001-0001-000000000001")!
    static let personalKeyID = UUID(uuidString: "B0000001-0001-0001-0001-000000000002")!
    static let ciKeyID = UUID(uuidString: "B0000001-0001-0001-0001-000000000003")!
    static let legacyKeyID = UUID(uuidString: "B0000001-0001-0001-0001-000000000004")!
    static let caID = UUID(uuidString: "C0000001-0001-0001-0001-000000000001")!

    // MARK: - Hosts

    static let hosts: [Host] = [
        // Production
        Host(
            id: webAlphaID, label: "Web Server Alpha", folder: "Production",
            hostname: "10.0.1.10", port: 22, username: "ops",
            authMethod: .publicKey, keyReference: deployKeyID,
            certificateReference: nil, passwordReference: nil, jumpHost: nil,
            algorithmPreferences: nil, pinnedHostKeyAlgorithms: ["ssh-ed25519"],
            agentForwardingEnabled: false,
            portForwardingRules: [
                PortForwardingRule(localPort: 8443, remoteHost: "localhost", remotePort: 443, label: "HTTPS Proxy"),
            ],
            legacyModeEnabled: false, tags: ["web", "nginx"],
            notes: "Primary web server behind HAProxy load balancer.",
            lastConnected: Date(timeIntervalSinceNow: -300),
            createdAt: Date(timeIntervalSinceNow: -86400 * 90)
        ),
        Host(
            id: dbPrimaryID, label: "Database Primary", folder: "Production",
            hostname: "db-primary.prod.internal", port: 22, username: "dba",
            authMethod: .publicKey, keyReference: deployKeyID,
            certificateReference: nil, passwordReference: nil, jumpHost: jumpHostID,
            algorithmPreferences: nil, pinnedHostKeyAlgorithms: [],
            agentForwardingEnabled: false,
            portForwardingRules: [
                PortForwardingRule(localPort: 5432, remoteHost: "localhost", remotePort: 5432, label: "PostgreSQL"),
            ],
            legacyModeEnabled: false, tags: ["postgres", "primary"],
            notes: "PostgreSQL 16 primary instance. Access via jump host only.",
            lastConnected: Date(timeIntervalSinceNow: -7200),
            createdAt: Date(timeIntervalSinceNow: -86400 * 60)
        ),
        Host(
            id: UUID(), label: "Load Balancer", folder: "Production",
            hostname: "lb-01.prod.internal", port: 22, username: "admin",
            authMethod: .certificate, keyReference: nil,
            certificateReference: nil, passwordReference: nil, jumpHost: nil,
            algorithmPreferences: nil, pinnedHostKeyAlgorithms: [],
            agentForwardingEnabled: false, portForwardingRules: [],
            legacyModeEnabled: false, tags: ["haproxy", "lb"],
            notes: "HAProxy load balancer for web tier.",
            lastConnected: Date(timeIntervalSinceNow: -86400 * 2),
            createdAt: Date(timeIntervalSinceNow: -86400 * 120)
        ),

        // Staging
        Host(
            id: UUID(), label: "API Gateway", folder: "Staging",
            hostname: "api.staging.internal", port: 22, username: "deploy",
            authMethod: .publicKey, keyReference: deployKeyID,
            certificateReference: nil, passwordReference: nil, jumpHost: nil,
            algorithmPreferences: nil, pinnedHostKeyAlgorithms: [],
            agentForwardingEnabled: true,
            portForwardingRules: [
                PortForwardingRule(localPort: 3000, remoteHost: "localhost", remotePort: 3000, label: "API Dev Port"),
            ],
            legacyModeEnabled: false, tags: ["api", "staging"],
            notes: "REST API gateway for staging environment.",
            lastConnected: Date(timeIntervalSinceNow: -43200),
            createdAt: Date(timeIntervalSinceNow: -86400 * 30)
        ),
        Host(
            id: UUID(), label: "Worker Node 01", folder: "Staging",
            hostname: "worker-01.staging.internal", port: 22, username: "deploy",
            authMethod: .publicKey, keyReference: deployKeyID,
            certificateReference: nil, passwordReference: nil, jumpHost: nil,
            algorithmPreferences: nil, pinnedHostKeyAlgorithms: [],
            agentForwardingEnabled: false, portForwardingRules: [],
            legacyModeEnabled: false, tags: ["worker", "sidekiq"],
            notes: nil, lastConnected: nil,
            createdAt: Date(timeIntervalSinceNow: -86400 * 30)
        ),

        // Network
        Host(
            id: UUID(), label: "Core Router", folder: "Network",
            hostname: "172.16.0.1", port: 22, username: "admin",
            authMethod: .password, keyReference: nil,
            certificateReference: nil, passwordReference: "saved", jumpHost: nil,
            algorithmPreferences: nil, pinnedHostKeyAlgorithms: [],
            agentForwardingEnabled: false, portForwardingRules: [],
            legacyModeEnabled: true, tags: ["network", "cisco"],
            notes: "Legacy Cisco IOS device. Requires legacy algorithm mode.",
            lastConnected: Date(timeIntervalSinceNow: -86400 * 14),
            createdAt: Date(timeIntervalSinceNow: -86400 * 180)
        ),
        Host(
            id: UUID(), label: "Edge Firewall", folder: "Network",
            hostname: "fw.edge.corp.io", port: 2222, username: "secops",
            authMethod: .publicKey, keyReference: personalKeyID,
            certificateReference: nil, passwordReference: nil, jumpHost: nil,
            algorithmPreferences: nil,
            pinnedHostKeyAlgorithms: ["ssh-ed25519", "ecdsa-sha2-nistp256"],
            agentForwardingEnabled: false, portForwardingRules: [],
            legacyModeEnabled: false, tags: ["firewall", "pfsense"],
            notes: "pf-based edge firewall. Non-standard port 2222.",
            lastConnected: Date(timeIntervalSinceNow: -86400),
            createdAt: Date(timeIntervalSinceNow: -86400 * 150)
        ),

        // Development
        Host(
            id: UUID(), label: "Dev Box", folder: "Development",
            hostname: "dev.local", port: 22, username: "kevin",
            authMethod: .password, keyReference: nil,
            certificateReference: nil, passwordReference: nil, jumpHost: nil,
            algorithmPreferences: nil, pinnedHostKeyAlgorithms: [],
            agentForwardingEnabled: true, portForwardingRules: [],
            legacyModeEnabled: false, tags: ["dev", "local"],
            notes: nil,
            lastConnected: Date(timeIntervalSinceNow: -1800),
            createdAt: Date(timeIntervalSinceNow: -86400 * 7)
        ),

        // Servers
        Host(
            id: jumpHostID, label: "Jump Host (Bastion)", folder: "Servers",
            hostname: "bastion.corp.io", port: 22, username: "ops",
            authMethod: .publicKey, keyReference: deployKeyID,
            certificateReference: nil, passwordReference: nil, jumpHost: nil,
            algorithmPreferences: nil, pinnedHostKeyAlgorithms: [],
            agentForwardingEnabled: false, portForwardingRules: [],
            legacyModeEnabled: false, tags: ["bastion", "jump"],
            notes: "Primary bastion host for internal network access.",
            lastConnected: Date(timeIntervalSinceNow: -3600),
            createdAt: Date(timeIntervalSinceNow: -86400 * 200)
        ),
    ]

    // MARK: - SSH Keys

    static let keys: [StoredSSHKey] = [
        StoredSSHKey(
            metadata: SSHKey(
                id: deployKeyID,
                label: "Production Deploy Key",
                type: .ed25519, bitLength: 256,
                fingerprint: "SHA256:q8B5Z9xM0wj+fW2Fa+ITQ4eD9P6rPUGL4uG53jA2H1g",
                fingerprintMD5: "MD5:4f:98:9c:35:7f:20:5a:77:b8:7a:03:20:3a:11:7f:2e",
                publicKeyAuthorizedFormat: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGq8B5Z9xM0wjK production-deploy@prossh",
                storageLocation: .encryptedStorage, format: .openssh,
                isPassphraseProtected: true, passphraseCipher: .chacha20Poly1305,
                comment: "Production deployment key",
                associatedCertificates: [],
                createdAt: Date(timeIntervalSinceNow: -86400 * 180),
                importedFrom: "Generated on device"
            ),
            privateKey: "-----BEGIN OPENSSH PRIVATE KEY-----\n[ENCRYPTED]\n-----END OPENSSH PRIVATE KEY-----",
            publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGq8B5Z9xM0wjK production-deploy@prossh"
        ),
        StoredSSHKey(
            metadata: SSHKey(
                id: personalKeyID,
                label: "Personal Laptop Key",
                type: .rsa, bitLength: 4096,
                fingerprint: "SHA256:xR3bK9pLvN2mQ7hT5fA8wE1cY6uI0oP4sD3gH7jK2lM",
                fingerprintMD5: "MD5:ab:cd:ef:01:23:45:67:89:ab:cd:ef:01:23:45:67:89",
                publicKeyAuthorizedFormat: "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQ kevin@macbook",
                storageLocation: .encryptedStorage, format: .openssh,
                isPassphraseProtected: false, passphraseCipher: nil,
                comment: "Kevin's MacBook Pro",
                associatedCertificates: [],
                createdAt: Date(timeIntervalSinceNow: -86400 * 365),
                importedFrom: "Imported from ~/.ssh/id_rsa"
            ),
            privateKey: "-----BEGIN OPENSSH PRIVATE KEY-----\n[PRIVATE]\n-----END OPENSSH PRIVATE KEY-----",
            publicKey: "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQ kevin@macbook"
        ),
        StoredSSHKey(
            metadata: SSHKey(
                id: ciKeyID,
                label: "CI/CD Pipeline Key",
                type: .ecdsa, bitLength: 256,
                fingerprint: "SHA256:mN4bV6cX8zA1sD3fG5hJ7kL9pQ2wE0rT4yU6iO8aS1d",
                fingerprintMD5: "MD5:12:34:56:78:9a:bc:de:f0:12:34:56:78:9a:bc:de:f0",
                publicKeyAuthorizedFormat: "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTY ci-pipeline@prossh",
                storageLocation: .secureEnclave, format: .openssh,
                isPassphraseProtected: false, passphraseCipher: nil,
                comment: "CI/CD pipeline — Secure Enclave backed",
                associatedCertificates: [],
                createdAt: Date(timeIntervalSinceNow: -86400 * 45),
                importedFrom: nil
            ),
            privateKey: "",
            publicKey: "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTY ci-pipeline@prossh",
            secureEnclaveTag: "com.prossh.secureenclave.ci-pipeline"
        ),
        StoredSSHKey(
            metadata: SSHKey(
                id: legacyKeyID,
                label: "Legacy Ops Key",
                type: .rsa, bitLength: 2048,
                fingerprint: "SHA256:fG5hJ7kL9pQ2wE0rT4yU6iO8aS1dMn4bV6cX8zA1sD3",
                fingerprintMD5: "MD5:fe:dc:ba:98:76:54:32:10:fe:dc:ba:98:76:54:32:10",
                publicKeyAuthorizedFormat: "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDfg legacy-ops@prossh",
                storageLocation: .encryptedStorage, format: .pem,
                isPassphraseProtected: true, passphraseCipher: .aes256ctr,
                comment: "Legacy operations key (PEM format)",
                associatedCertificates: [],
                createdAt: Date(timeIntervalSinceNow: -86400 * 500),
                importedFrom: "Imported from legacy system"
            ),
            privateKey: "-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\n[ENCRYPTED]\n-----END RSA PRIVATE KEY-----",
            publicKey: "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDfg legacy-ops@prossh"
        ),
    ]

    // MARK: - Sessions

    static let webAlphaSessionID = UUID(uuidString: "D0000001-0001-0001-0001-000000000001")!
    static let dbSessionID = UUID(uuidString: "D0000001-0001-0001-0001-000000000002")!
    static let localSessionID = UUID(uuidString: "D0000001-0001-0001-0001-000000000003")!

    static let sessions: [Session] = [
        Session(
            id: webAlphaSessionID,
            kind: .ssh(hostID: webAlphaID),
            hostLabel: "Web Server Alpha",
            username: "ops", hostname: "10.0.1.10", port: 22,
            state: .connected,
            negotiatedKEX: "curve25519-sha256",
            negotiatedCipher: "chacha20-poly1305@openssh.com",
            negotiatedHostKeyType: "ssh-ed25519",
            negotiatedHostFingerprint: "SHA256:q8B5Z9xM0wj+fW2Fa+ITQ4eD9P6rPUGL4uG53jA2H1g",
            usesLegacyCrypto: false, usesAgentForwarding: false,
            transportBackend: .libssh,
            startedAt: Date(timeIntervalSinceNow: -300)
        ),
        Session(
            id: dbSessionID,
            kind: .ssh(hostID: dbPrimaryID),
            hostLabel: "Database Primary",
            username: "dba", hostname: "db-primary.prod.internal", port: 22,
            state: .connected,
            negotiatedKEX: "curve25519-sha256",
            negotiatedCipher: "aes256-gcm@openssh.com",
            negotiatedHostKeyType: "ssh-ed25519",
            negotiatedHostFingerprint: "SHA256:xR3bK9pLvN2mQ7hT5fA8wE1cY6uI0oP4sD3gH7jK2lM",
            usesLegacyCrypto: false, usesAgentForwarding: false,
            transportBackend: .libssh,
            jumpHostLabel: "Jump Host (Bastion)",
            startedAt: Date(timeIntervalSinceNow: -7200)
        ),
        Session(
            id: localSessionID,
            kind: .local,
            hostLabel: "Local: zsh",
            username: NSUserName(), hostname: "localhost", port: 0,
            state: .connected,
            shellPath: "/bin/zsh",
            startedAt: Date(timeIntervalSinceNow: -600)
        ),
    ]

    // MARK: - Terminal Content

    static let terminalOutput: String = """
    Last login: Wed Feb 19 09:32:14 2026 from 10.0.1.5\r
    \u{1b}[32mops@web-alpha\u{1b}[0m:\u{1b}[34m~\u{1b}[0m$ uptime\r
     09:45:23 up 127 days, 14:22,  3 users,  load average: 0.42, 0.38, 0.35\r
    \u{1b}[32mops@web-alpha\u{1b}[0m:\u{1b}[34m~\u{1b}[0m$ df -h\r
    Filesystem      Size  Used Avail Use% Mounted on\r
    /dev/sda1       100G   42G   54G  44% /\r
    tmpfs           7.8G  1.2M  7.8G   1% /dev/shm\r
    /dev/sdb1       500G  312G  163G  66% /data\r
    \u{1b}[32mops@web-alpha\u{1b}[0m:\u{1b}[34m~\u{1b}[0m$ docker ps\r
    \u{1b}[1mCONTAINER ID   IMAGE              STATUS          PORTS                  NAMES\u{1b}[0m\r
    a3f2c1b89e4d   nginx:1.25         Up 3 days       0.0.0.0:443->443/tcp   proxy\r
    7d6e5f4a3b2c   api-server:2.1     Up 3 days       8080/tcp               api\r
    9c8b7a6d5e4f   redis:7.2          Up 3 days       6379/tcp               cache\r
    b1a2c3d4e5f6   postgres:16        Up 3 days       5432/tcp               db\r
    \u{1b}[32mops@web-alpha\u{1b}[0m:\u{1b}[34m~\u{1b}[0m$ \u{1b}[7m \u{1b}[0m
    """

    // MARK: - Transfers

    static func transfers(sessionID: UUID) -> [Transfer] {
        [
            Transfer(
                id: UUID(), sessionID: sessionID,
                sourcePath: "/etc/nginx/nginx.conf",
                destinationPath: "~/Downloads/nginx.conf",
                direction: .download,
                bytesTransferred: 4_821, totalBytes: 4_821,
                state: .completed,
                createdAt: Date(timeIntervalSinceNow: -120),
                updatedAt: Date(timeIntervalSinceNow: -115)
            ),
            Transfer(
                id: UUID(), sessionID: sessionID,
                sourcePath: "/var/backups/app-bundle.tar.gz",
                destinationPath: "~/Downloads/app-bundle.tar.gz",
                direction: .download,
                bytesTransferred: 48_234_567, totalBytes: 107_374_182,
                state: .running,
                createdAt: Date(timeIntervalSinceNow: -60),
                updatedAt: Date(timeIntervalSinceNow: -1)
            ),
            Transfer(
                id: UUID(), sessionID: sessionID,
                sourcePath: "~/scripts/deploy.sh",
                destinationPath: "/opt/deploy/deploy.sh",
                direction: .upload,
                bytesTransferred: 2_048, totalBytes: 2_048,
                state: .completed,
                createdAt: Date(timeIntervalSinceNow: -300),
                updatedAt: Date(timeIntervalSinceNow: -298)
            ),
            Transfer(
                id: UUID(), sessionID: sessionID,
                sourcePath: "/var/backups/database-backup.sql.gz",
                destinationPath: "~/Downloads/database-backup.sql.gz",
                direction: .download,
                bytesTransferred: 0, totalBytes: 524_288_000,
                state: .queued,
                createdAt: Date(timeIntervalSinceNow: -10),
                updatedAt: Date(timeIntervalSinceNow: -10)
            ),
        ]
    }

    // MARK: - Certificates

    static let authorities: [CertificateAuthorityModel] = [
        CertificateAuthorityModel(
            id: caID,
            label: "Infrastructure CA",
            keyType: .ecdsa,
            publicKeyFingerprint: "SHA256:pQ2wE0rT4yU6iO8aS1dMn4bV6cX8zA1sD3fG5hJ7kL9",
            publicKeyAuthorizedFormat: "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTY infra-ca@prossh",
            secureEnclaveReference: "com.prossh.ca.infrastructure",
            certificateType: .both,
            defaultValidityDuration: 30 * 86_400,
            nextSerialNumber: 5,
            issuedCertificateCount: 4,
            createdAt: Date(timeIntervalSinceNow: -86400 * 90),
            notes: "Primary CA for all infrastructure certificates."
        ),
    ]

    static let certificates: [SSHCertificate] = [
        SSHCertificate(
            id: UUID(),
            type: .user,
            serialNumber: 3,
            keyId: "ops-user-cert",
            principals: ["ops", "deploy"],
            validAfter: Date(timeIntervalSinceNow: -86400 * 15),
            validBefore: Date(timeIntervalSinceNow: 86400 * 15),
            criticalOptions: [:],
            extensions: ["permit-pty", "permit-agent-forwarding"],
            signingCAFingerprint: "SHA256:pQ2wE0rT4yU6iO8aS1dMn4bV6cX8zA1sD3fG5hJ7kL9",
            signedKeyFingerprint: "SHA256:q8B5Z9xM0wj+fW2Fa+ITQ4eD9P6rPUGL4uG53jA2H1g",
            signatureAlgorithm: "ecdsa-sha2-nistp256",
            associatedKeyId: deployKeyID,
            rawCertificateData: Data("ssh-ed25519-cert-v01@openssh.com [CERT DATA]".utf8),
            authorizedRepresentation: "ssh-ed25519-cert-v01@openssh.com AAAAI...",
            importedFrom: nil,
            createdAt: Date(timeIntervalSinceNow: -86400 * 15)
        ),
        SSHCertificate(
            id: UUID(),
            type: .host,
            serialNumber: 4,
            keyId: "web-alpha-host-cert",
            principals: ["10.0.1.10", "web-alpha.prod.internal"],
            validAfter: Date(timeIntervalSinceNow: -86400 * 10),
            validBefore: Date(timeIntervalSinceNow: 86400 * 20),
            criticalOptions: [:],
            extensions: [],
            signingCAFingerprint: "SHA256:pQ2wE0rT4yU6iO8aS1dMn4bV6cX8zA1sD3fG5hJ7kL9",
            signedKeyFingerprint: "SHA256:fG5hJ7kL9pQ2wE0rT4yU6iO8aS1dMn4bV6cX8zA1sD3",
            signatureAlgorithm: "ecdsa-sha2-nistp256",
            associatedKeyId: nil,
            rawCertificateData: Data("ssh-ed25519-cert-v01@openssh.com [HOST CERT]".utf8),
            authorizedRepresentation: "ssh-ed25519-cert-v01@openssh.com AAAAI...",
            importedFrom: nil,
            createdAt: Date(timeIntervalSinceNow: -86400 * 10)
        ),
    ]
}
