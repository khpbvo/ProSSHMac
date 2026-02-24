// SSHConfigParserTests.swift
// Tests for SSH config import/export

import XCTest
@testable import ProSSHMac

final class SSHConfigParserTests: XCTestCase {

    private let parser = SSHConfigParser()

    // MARK: - Basic Parsing

    func testParseSingleHost() {
        let config = """
        Host webserver
            HostName 10.0.0.1
            User admin
            Port 2222
        """

        let result = parser.parse(config)

        XCTAssertEqual(result.entries.count, 1)
        XCTAssertTrue(result.warnings.isEmpty)

        let entry = result.entries[0]
        XCTAssertEqual(entry.patterns, ["webserver"])
        XCTAssertFalse(entry.isMatchBlock)
        XCTAssertEqual(entry.firstValue(for: "hostname"), "10.0.0.1")
        XCTAssertEqual(entry.firstValue(for: "user"), "admin")
        XCTAssertEqual(entry.firstValue(for: "port"), "2222")
    }

    func testParseMultipleHosts() {
        let config = """
        Host web
            HostName web.example.com
            User deploy

        Host db
            HostName db.example.com
            User postgres
            Port 5432
        """

        let result = parser.parse(config)

        XCTAssertEqual(result.entries.count, 2)
        XCTAssertEqual(result.entries[0].patterns, ["web"])
        XCTAssertEqual(result.entries[1].patterns, ["db"])
        XCTAssertEqual(result.entries[1].firstValue(for: "port"), "5432")
    }

    func testParseGlobalDefaults() {
        let config = """
        Host *
            ServerAliveInterval 60
            ServerAliveCountMax 3

        Host myhost
            HostName 10.0.0.1
        """

        let result = parser.parse(config)

        XCTAssertEqual(result.entries.count, 2)
        XCTAssertNotNil(result.globalDefaults)
        XCTAssertTrue(result.globalDefaults!.isGlobalDefaults)
        XCTAssertEqual(result.globalDefaults!.firstValue(for: "serveraliveinterval"), "60")

        XCTAssertEqual(result.concreteHosts.count, 1)
        XCTAssertEqual(result.concreteHosts[0].patterns, ["myhost"])
    }

    func testParseImplicitGlobalDefaults() {
        // Directives before any Host line are implicitly Host *.
        let config = """
        ServerAliveInterval 30

        Host myhost
            HostName 10.0.0.1
        """

        let result = parser.parse(config)

        XCTAssertEqual(result.entries.count, 2)
        XCTAssertNotNil(result.globalDefaults)
        XCTAssertEqual(result.globalDefaults!.firstValue(for: "serveraliveinterval"), "30")
    }

    // MARK: - Comments and Whitespace

    func testParseWithInlineComments() {
        let config = """
        Host webserver  # Production web
            HostName 10.0.0.1  # Internal IP
            User admin
        """

        let result = parser.parse(config)

        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.entries[0].patterns, ["webserver"])
        XCTAssertEqual(result.entries[0].firstValue(for: "hostname"), "10.0.0.1")
    }

    func testHashInsideQuotesIsLiteral() {
        let config = """
        Host myhost
            HostName 10.0.0.1
            IdentityFile "~/.ssh/key#2"
        """

        let result = parser.parse(config)

        XCTAssertEqual(result.entries[0].firstValue(for: "identityfile"), "~/.ssh/key#2")
    }

    func testBlankLinesAreSkipped() {
        let config = """

        Host webserver

            HostName 10.0.0.1

            User admin

        """

        let result = parser.parse(config)

        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.entries[0].directives.count, 2)
    }

    // MARK: - Equals Separator

    func testParseEqualsSeparatedDirectives() {
        let config = """
        Host myhost
            HostName=10.0.0.1
            User=admin
            Port = 2222
        """

        let result = parser.parse(config)

        XCTAssertEqual(result.entries[0].firstValue(for: "hostname"), "10.0.0.1")
        XCTAssertEqual(result.entries[0].firstValue(for: "user"), "admin")
        XCTAssertEqual(result.entries[0].firstValue(for: "port"), "2222")
    }

    // MARK: - Multiple Patterns

    func testMultiplePatternsOnHostLine() {
        let config = """
        Host web-01 web-02 web-03
            HostName 10.0.0.1
            User deploy
        """

        let result = parser.parse(config)

        XCTAssertEqual(result.entries[0].patterns, ["web-01", "web-02", "web-03"])
    }

    func testQuotedHostPatterns() {
        let config = """
        Host "my server" other-server
            HostName 10.0.0.1
        """

        let result = parser.parse(config)

        XCTAssertEqual(result.entries[0].patterns, ["my server", "other-server"])
    }

    // MARK: - Wildcards and Concrete Hosts

    func testWildcardHostsExcludedFromConcreteHosts() {
        let config = """
        Host web-*
            User deploy

        Host db-prod
            HostName db.example.com
        """

        let result = parser.parse(config)

        XCTAssertEqual(result.entries.count, 2)
        XCTAssertEqual(result.concreteHosts.count, 1)
        XCTAssertEqual(result.concreteHosts[0].patterns, ["db-prod"])
    }

    // MARK: - Match Blocks

    func testMatchBlockCapturedWithWarning() {
        let config = """
        Match host *.example.com
            User special

        Host regular
            HostName 10.0.0.1
        """

        let result = parser.parse(config)

        XCTAssertEqual(result.entries.count, 2)
        XCTAssertTrue(result.entries[0].isMatchBlock)
        XCTAssertFalse(result.entries[1].isMatchBlock)

        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].reason.contains("Match"))
    }

    // MARK: - Include Directive

    func testIncludeDirectiveWarning() {
        let config = """
        Include ~/.ssh/config.d/*.conf

        Host myhost
            HostName 10.0.0.1
        """

        let result = parser.parse(config)

        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].reason.contains("Include"))
    }

    // MARK: - Multi-Value Directives

    func testMultipleLocalForwards() {
        let config = """
        Host tunnel
            HostName 10.0.0.1
            LocalForward 8080 web.internal:80
            LocalForward 5432 db.internal:5432
            LocalForward 6379 redis.internal:6379
        """

        let result = parser.parse(config)

        let forwards = result.entries[0].allValues(for: "localforward")
        XCTAssertEqual(forwards.count, 3)
        XCTAssertEqual(forwards[0], "8080 web.internal:80")
        XCTAssertEqual(forwards[1], "5432 db.internal:5432")
        XCTAssertEqual(forwards[2], "6379 redis.internal:6379")
    }

    func testMultipleIdentityFiles() {
        let config = """
        Host myhost
            HostName 10.0.0.1
            IdentityFile ~/.ssh/id_ed25519
            IdentityFile ~/.ssh/id_rsa
        """

        let result = parser.parse(config)

        let files = result.entries[0].allValues(for: "identityfile")
        XCTAssertEqual(files.count, 2)
    }

    // MARK: - First-Value Semantics

    func testFirstValueWins() {
        let config = """
        Host myhost
            HostName first.example.com
            HostName second.example.com
        """

        let result = parser.parse(config)

        // SSH config uses first-match-wins.
        XCTAssertEqual(result.entries[0].firstValue(for: "hostname"), "first.example.com")
    }

    // MARK: - Case Insensitivity

    func testKeywordCaseInsensitivity() {
        let config = """
        Host myhost
            HOSTNAME 10.0.0.1
            user ADMIN
            PORT 2222
        """

        let result = parser.parse(config)

        XCTAssertEqual(result.entries[0].firstValue(for: "hostname"), "10.0.0.1")
        XCTAssertEqual(result.entries[0].firstValue(for: "user"), "ADMIN")
        XCTAssertEqual(result.entries[0].firstValue(for: "port"), "2222")
    }

    // MARK: - Line Numbers

    func testDirectiveLineNumbers() {
        let config = """
        Host myhost
            HostName 10.0.0.1
            User admin
        """

        let result = parser.parse(config)

        XCTAssertEqual(result.entries[0].startLine, 1)
        XCTAssertEqual(result.entries[0].directives[0].lineNumber, 2)
        XCTAssertEqual(result.entries[0].directives[1].lineNumber, 3)
    }
}

// MARK: - Token Expansion Tests

final class SSHConfigTokenExpanderTests: XCTestCase {

    private let expander = SSHConfigTokenExpander()

    func testHostnameToken() {
        let ctx = SSHConfigTokenExpander.Context(hostname: "web.example.com", username: "deploy")
        XCTAssertEqual(expander.expand("%h", context: ctx), "web.example.com")
        XCTAssertEqual(expander.expand("%n", context: ctx), "web.example.com")
    }

    func testUsernameToken() {
        let ctx = SSHConfigTokenExpander.Context(hostname: "host", username: "kevin")
        XCTAssertEqual(expander.expand("%u", context: ctx), "kevin")
        XCTAssertEqual(expander.expand("%r", context: ctx), "kevin")
    }

    func testPortToken() {
        let ctx = SSHConfigTokenExpander.Context(hostname: "host", username: "kevin", port: 2222)
        XCTAssertEqual(expander.expand("%p", context: ctx), "2222")
    }

    func testHomeDirectoryToken() {
        let ctx = SSHConfigTokenExpander.Context(
            hostname: "host", username: "kevin",
            homeDirectory: "/Users/kevin"
        )
        XCTAssertEqual(expander.expand("%d/.ssh/config", context: ctx), "/Users/kevin/.ssh/config")
    }

    func testLocalHostnameTokens() {
        let ctx = SSHConfigTokenExpander.Context(
            hostname: "host", username: "kevin",
            localHostname: "macbook.local"
        )
        XCTAssertEqual(expander.expand("%l", context: ctx), "macbook")
        XCTAssertEqual(expander.expand("%L", context: ctx), "macbook.local")
    }

    func testLiteralPercent() {
        let ctx = SSHConfigTokenExpander.Context(hostname: "host", username: "kevin")
        XCTAssertEqual(expander.expand("100%%", context: ctx), "100%")
    }

    func testMixedTokens() {
        let ctx = SSHConfigTokenExpander.Context(
            hostname: "web.prod", username: "deploy", port: 22,
            homeDirectory: "/home/deploy"
        )
        let result = expander.expand("%d/.ssh/keys/%h_%u", context: ctx)
        XCTAssertEqual(result, "/home/deploy/.ssh/keys/web.prod_deploy")
    }

    func testUnknownTokenPreserved() {
        let ctx = SSHConfigTokenExpander.Context(hostname: "host", username: "kevin")
        XCTAssertEqual(expander.expand("%z", context: ctx), "%z")
    }

    func testNoTokensPassedThrough() {
        let ctx = SSHConfigTokenExpander.Context(hostname: "host", username: "kevin")
        XCTAssertEqual(expander.expand("plain-string", context: ctx), "plain-string")
    }
}

// MARK: - Mapper Tests

final class SSHConfigMapperTests: XCTestCase {

    private let mapper = SSHConfigMapper()
    private let parser = SSHConfigParser()

    // MARK: - Core Field Mapping

    func testBasicHostMapping() {
        let config = """
        Host webserver
            HostName 10.0.0.1
            User admin
            Port 2222
        """

        let result = parser.parse(config)
        let mapped = mapper.importAll(from: result)

        XCTAssertEqual(mapped.count, 1)
        let host = mapped[0].host
        XCTAssertEqual(host.label, "webserver")
        XCTAssertEqual(host.hostname, "10.0.0.1")
        XCTAssertEqual(host.username, "admin")
        XCTAssertEqual(host.port, 2222)
    }

    func testHostnameFallsBackToLabel() {
        let config = """
        Host web.example.com
            User deploy
        """

        let result = parser.parse(config)
        let mapped = mapper.importAll(from: result)

        XCTAssertEqual(mapped[0].host.hostname, "web.example.com")
    }

    func testDefaultPort22() {
        let config = """
        Host myhost
            HostName 10.0.0.1
        """

        let result = parser.parse(config)
        let mapped = mapper.importAll(from: result)

        XCTAssertEqual(mapped[0].host.port, 22)
    }

    // MARK: - Global Defaults Inheritance

    func testGlobalDefaultsApplied() {
        let config = """
        Host *
            User globaluser
            Port 2222

        Host myhost
            HostName 10.0.0.1
        """

        let result = parser.parse(config)
        let mapped = mapper.importAll(from: result)

        XCTAssertEqual(mapped.count, 1)
        XCTAssertEqual(mapped[0].host.username, "globaluser")
        XCTAssertEqual(mapped[0].host.port, 2222)
    }

    func testLocalOverridesGlobal() {
        let config = """
        Host *
            User globaluser
            Port 2222

        Host myhost
            HostName 10.0.0.1
            User localuser
        """

        let result = parser.parse(config)
        let mapped = mapper.importAll(from: result)

        // Local User overrides global; Port falls through from global.
        XCTAssertEqual(mapped[0].host.username, "localuser")
        XCTAssertEqual(mapped[0].host.port, 2222)
    }

    // MARK: - Port Forwarding

    func testLocalForwardParsed() {
        let config = """
        Host tunnel
            HostName 10.0.0.1
            LocalForward 8080 web.internal:80
            LocalForward 5432 db.internal:5432
        """

        let result = parser.parse(config)
        let mapped = mapper.importAll(from: result)

        let rules = mapped[0].host.portForwardingRules
        XCTAssertEqual(rules.count, 2)
        XCTAssertEqual(rules[0].localPort, 8080)
        XCTAssertEqual(rules[0].remoteHost, "web.internal")
        XCTAssertEqual(rules[0].remotePort, 80)
        XCTAssertEqual(rules[1].localPort, 5432)
        XCTAssertEqual(rules[1].remotePort, 5432)
    }

    func testLocalForwardWithBindAddress() {
        let config = """
        Host tunnel
            HostName 10.0.0.1
            LocalForward 127.0.0.1:9090 internal:8080
        """

        let result = parser.parse(config)
        let mapped = mapper.importAll(from: result)

        let rules = mapped[0].host.portForwardingRules
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].localPort, 9090)
        XCTAssertEqual(rules[0].remoteHost, "internal")
        XCTAssertEqual(rules[0].remotePort, 8080)
    }

    func testRemoteForwardGeneratesNote() {
        let config = """
        Host tunnel
            HostName 10.0.0.1
            RemoteForward 9090 localhost:80
        """

        let result = parser.parse(config)
        let mapped = mapper.importAll(from: result)

        XCTAssertTrue(mapped[0].notes.contains(where: { $0.contains("RemoteForward") }))
    }

    // MARK: - Agent Forwarding

    func testAgentForwarding() {
        let config = """
        Host myhost
            HostName 10.0.0.1
            ForwardAgent yes
        """

        let result = parser.parse(config)
        let mapped = mapper.importAll(from: result)

        XCTAssertTrue(mapped[0].host.agentForwardingEnabled)
    }

    func testAgentForwardingDisabled() {
        let config = """
        Host myhost
            HostName 10.0.0.1
            ForwardAgent no
        """

        let result = parser.parse(config)
        let mapped = mapper.importAll(from: result)

        XCTAssertFalse(mapped[0].host.agentForwardingEnabled)
    }

    // MARK: - Jump Host Resolution

    func testProxyJumpResolvesToExistingHost() {
        let config = """
        Host appserver
            HostName 10.0.0.2
            ProxyJump bastion
        """

        let existingBastion = Host(
            id: UUID(),
            label: "bastion",
            folder: nil,
            hostname: "bastion.example.com",
            port: 22,
            username: "ops",
            authMethod: .publicKey,
            keyReference: nil,
            certificateReference: nil,
            passwordReference: nil,
            jumpHost: nil,
            algorithmPreferences: nil,
            pinnedHostKeyAlgorithms: [],
            legacyModeEnabled: false,
            tags: [],
            notes: nil,
            lastConnected: nil,
            createdAt: .now
        )

        let result = parser.parse(config)
        let mapped = mapper.importAll(from: result, existingHosts: [existingBastion])

        XCTAssertEqual(mapped[0].host.jumpHost, existingBastion.id)
    }

    func testProxyJumpResolvesToImportedHost() {
        let config = """
        Host bastion
            HostName bastion.example.com
            User ops

        Host appserver
            HostName 10.0.0.2
            ProxyJump bastion
        """

        let result = parser.parse(config)
        let mapped = mapper.importAll(from: result)

        // bastion is imported first, then appserver references it.
        XCTAssertEqual(mapped.count, 2)
        XCTAssertEqual(mapped[1].host.jumpHost, mapped[0].host.id)
    }

    func testProxyJumpUnresolvedGeneratesNote() {
        let config = """
        Host appserver
            HostName 10.0.0.2
            ProxyJump unknown-bastion
        """

        let result = parser.parse(config)
        let mapped = mapper.importAll(from: result)

        XCTAssertNil(mapped[0].host.jumpHost)
        XCTAssertTrue(mapped[0].notes.contains(where: { $0.contains("ProxyJump") }))
    }

    func testProxyJumpChainTakesFirstHop() {
        let config = """
        Host deep-server
            HostName 10.0.0.3
            ProxyJump bastion1,bastion2,bastion3
        """

        let result = parser.parse(config)
        let mapped = mapper.importAll(from: result)

        // Should note that chain was truncated.
        XCTAssertTrue(mapped[0].notes.contains(where: { $0.contains("chain") }))
    }

    // MARK: - Key Reference Resolution

    func testIdentityFileResolvesToKeyByFilename() {
        let config = """
        Host myhost
            HostName 10.0.0.1
            IdentityFile ~/.ssh/id_ed25519
        """

        let mockKey = StoredSSHKey(
            metadata: SSHKey(
                id: UUID(),
                label: "My Ed25519 Key",
                type: .ed25519,
                bitLength: 256,
                fingerprint: "SHA256:abc",
                fingerprintMD5: "MD5:abc",
                publicKeyAuthorizedFormat: "ssh-ed25519 AAAA...",
                storageLocation: .encryptedStorage,
                format: .openssh,
                isPassphraseProtected: false,
                comment: nil,
                associatedCertificates: [],
                createdAt: .now,
                importedFrom: "/Users/kevin/.ssh/id_ed25519"
            ),
            privateKey: "...",
            publicKey: "..."
        )

        let result = parser.parse(config)
        let mapped = mapper.importAll(from: result, existingKeys: [mockKey])

        XCTAssertEqual(mapped[0].host.keyReference, mockKey.metadata.id)
    }

    func testIdentityFileUnresolvedGeneratesNote() {
        let config = """
        Host myhost
            HostName 10.0.0.1
            IdentityFile ~/.ssh/nonexistent_key
        """

        let result = parser.parse(config)
        let mapped = mapper.importAll(from: result)

        XCTAssertNil(mapped[0].host.keyReference)
        XCTAssertTrue(mapped[0].notes.contains(where: { $0.contains("IdentityFile") }))
    }

    // MARK: - Algorithm Preferences

    func testAlgorithmPreferencesParsed() {
        let config = """
        Host legacy-server
            HostName 10.0.0.1
            KexAlgorithms diffie-hellman-group14-sha256,diffie-hellman-group16-sha512
            Ciphers aes256-ctr,aes128-ctr
            MACs hmac-sha2-256,hmac-sha2-512
            HostKeyAlgorithms ssh-ed25519,rsa-sha2-256
        """

        let result = parser.parse(config)
        let mapped = mapper.importAll(from: result)

        let algPrefs = mapped[0].host.algorithmPreferences
        XCTAssertNotNil(algPrefs)
        XCTAssertEqual(algPrefs?.keyExchange, ["diffie-hellman-group14-sha256", "diffie-hellman-group16-sha512"])
        XCTAssertEqual(algPrefs?.ciphers, ["aes256-ctr", "aes128-ctr"])
        XCTAssertEqual(algPrefs?.macs, ["hmac-sha2-256", "hmac-sha2-512"])

        XCTAssertEqual(mapped[0].host.pinnedHostKeyAlgorithms, ["ssh-ed25519", "rsa-sha2-256"])
    }

    func testAlgorithmModifiersStripped() {
        let config = """
        Host myhost
            HostName 10.0.0.1
            KexAlgorithms +diffie-hellman-group1-sha1
            Ciphers -3des-cbc
        """

        let result = parser.parse(config)
        let mapped = mapper.importAll(from: result)

        let algPrefs = mapped[0].host.algorithmPreferences
        XCTAssertEqual(algPrefs?.keyExchange, ["diffie-hellman-group1-sha1"])
        XCTAssertEqual(algPrefs?.ciphers, ["3des-cbc"])
    }

    // MARK: - Legacy Mode Detection

    func testLegacyModeDetected() {
        let config = """
        Host old-switch
            HostName 10.0.0.1
            KexAlgorithms diffie-hellman-group1-sha1
            Ciphers 3des-cbc
            HostKeyAlgorithms ssh-rsa
        """

        let result = parser.parse(config)
        let mapped = mapper.importAll(from: result)

        XCTAssertTrue(mapped[0].host.legacyModeEnabled)
    }

    func testModernAlgorithmsNotLegacy() {
        let config = """
        Host modern-server
            HostName 10.0.0.1
            KexAlgorithms curve25519-sha256
            Ciphers chacha20-poly1305@openssh.com
        """

        let result = parser.parse(config)
        let mapped = mapper.importAll(from: result)

        XCTAssertFalse(mapped[0].host.legacyModeEnabled)
    }

    // MARK: - Auth Method from PreferredAuthentications

    func testPreferredAuthenticationsPassword() {
        let config = """
        Host myhost
            HostName 10.0.0.1
            PreferredAuthentications password
        """

        let result = parser.parse(config)
        let mapped = mapper.importAll(from: result)

        XCTAssertEqual(mapped[0].host.authMethod, .password)
    }

    func testPreferredAuthenticationsKeyboardInteractive() {
        let config = """
        Host myhost
            HostName 10.0.0.1
            PreferredAuthentications keyboard-interactive,password
        """

        let result = parser.parse(config)
        let mapped = mapper.importAll(from: result)

        XCTAssertEqual(mapped[0].host.authMethod, .keyboardInteractive)
    }

    // MARK: - Folder Extraction

    func testFolderExtractedFromSlashLabel() {
        let config = """
        Host prod/web-01
            HostName 10.0.0.1
        """

        let result = parser.parse(config)
        let mapped = mapper.importAll(from: result)

        XCTAssertEqual(mapped[0].host.folder, "prod")
        XCTAssertEqual(mapped[0].host.label, "web-01")
    }

    func testNoSlashMeansNoFolder() {
        let config = """
        Host web-01
            HostName 10.0.0.1
        """

        let result = parser.parse(config)
        let mapped = mapper.importAll(from: result)

        XCTAssertNil(mapped[0].host.folder)
        XCTAssertEqual(mapped[0].host.label, "web-01")
    }

    // MARK: - Extra Patterns as Tags

    func testExtraPatternsBecomeTags() {
        let config = """
        Host web-01 web-alias production
            HostName 10.0.0.1
        """

        let result = parser.parse(config)
        let mapped = mapper.importAll(from: result)

        XCTAssertEqual(mapped[0].host.tags, ["web-alias", "production"])
    }

    // MARK: - Unsupported Directives

    func testUnsupportedDirectivesNoted() {
        let config = """
        Host myhost
            HostName 10.0.0.1
            SendEnv LANG LC_*
            Compression yes
            ControlMaster auto
            ControlPath ~/.ssh/sockets/%r@%h-%p
        """

        let result = parser.parse(config)
        let mapped = mapper.importAll(from: result)

        let notes = mapped[0].notes
        XCTAssertTrue(notes.contains(where: { $0.contains("Skipped directives") }))
    }
}

// MARK: - Exporter Tests

final class SSHConfigExporterTests: XCTestCase {

    private let exporter = SSHConfigExporter()

    func testBasicExport() {
        let host = Host(
            id: UUID(),
            label: "webserver",
            folder: nil,
            hostname: "10.0.0.1",
            port: 2222,
            username: "admin",
            authMethod: .publicKey,
            keyReference: nil,
            certificateReference: nil,
            passwordReference: nil,
            jumpHost: nil,
            algorithmPreferences: nil,
            pinnedHostKeyAlgorithms: [],
            legacyModeEnabled: false,
            tags: [],
            notes: nil,
            lastConnected: nil,
            createdAt: .now
        )

        let output = exporter.export([host], options: .init(includeHeader: false, includeProSSHNotes: false))

        XCTAssertTrue(output.contains("Host webserver"))
        XCTAssertTrue(output.contains("HostName 10.0.0.1"))
        XCTAssertTrue(output.contains("User admin"))
        XCTAssertTrue(output.contains("Port 2222"))
    }

    func testPort22OmittedFromExport() {
        let host = Host(
            id: UUID(),
            label: "webserver",
            folder: nil,
            hostname: "10.0.0.1",
            port: 22,
            username: "admin",
            authMethod: .publicKey,
            keyReference: nil,
            certificateReference: nil,
            passwordReference: nil,
            jumpHost: nil,
            algorithmPreferences: nil,
            pinnedHostKeyAlgorithms: [],
            legacyModeEnabled: false,
            tags: [],
            notes: nil,
            lastConnected: nil,
            createdAt: .now
        )

        let output = exporter.export([host], options: .init(includeHeader: false, includeProSSHNotes: false))

        XCTAssertFalse(output.contains("Port"))
    }

    func testPortForwardingExported() {
        let host = Host(
            id: UUID(),
            label: "tunnel",
            folder: nil,
            hostname: "10.0.0.1",
            port: 22,
            username: "ops",
            authMethod: .publicKey,
            keyReference: nil,
            certificateReference: nil,
            passwordReference: nil,
            jumpHost: nil,
            algorithmPreferences: nil,
            pinnedHostKeyAlgorithms: [],
            agentForwardingEnabled: false,
            portForwardingRules: [
                PortForwardingRule(localPort: 8080, remoteHost: "web.internal", remotePort: 80),
                PortForwardingRule(localPort: 5432, remoteHost: "db.internal", remotePort: 5432)
            ],
            legacyModeEnabled: false,
            tags: [],
            notes: nil,
            lastConnected: nil,
            createdAt: .now
        )

        let output = exporter.export([host], options: .init(includeHeader: false, includeProSSHNotes: false))

        XCTAssertTrue(output.contains("LocalForward 8080 web.internal:80"))
        XCTAssertTrue(output.contains("LocalForward 5432 db.internal:5432"))
    }

    func testJumpHostExported() {
        let bastion = Host(
            id: UUID(),
            label: "bastion",
            folder: nil,
            hostname: "bastion.example.com",
            port: 22,
            username: "ops",
            authMethod: .publicKey,
            keyReference: nil,
            certificateReference: nil,
            passwordReference: nil,
            jumpHost: nil,
            algorithmPreferences: nil,
            pinnedHostKeyAlgorithms: [],
            legacyModeEnabled: false,
            tags: [],
            notes: nil,
            lastConnected: nil,
            createdAt: .now
        )

        let app = Host(
            id: UUID(),
            label: "appserver",
            folder: nil,
            hostname: "10.0.0.2",
            port: 22,
            username: "deploy",
            authMethod: .publicKey,
            keyReference: nil,
            certificateReference: nil,
            passwordReference: nil,
            jumpHost: bastion.id,
            algorithmPreferences: nil,
            pinnedHostKeyAlgorithms: [],
            legacyModeEnabled: false,
            tags: [],
            notes: nil,
            lastConnected: nil,
            createdAt: .now
        )

        let output = exporter.export(
            [bastion, app],
            options: .init(includeHeader: false, includeProSSHNotes: false, allHosts: [bastion, app])
        )

        XCTAssertTrue(output.contains("ProxyJump bastion"))
    }

    func testProSSHNotesIncluded() {
        let host = Host(
            id: UUID(),
            label: "myhost",
            folder: "Network",
            hostname: "10.0.0.1",
            port: 22,
            username: "admin",
            authMethod: .publicKey,
            keyReference: nil,
            certificateReference: nil,
            passwordReference: nil,
            jumpHost: nil,
            algorithmPreferences: nil,
            pinnedHostKeyAlgorithms: [],
            legacyModeEnabled: true,
            shellIntegration: ShellIntegrationConfig(type: .ciscoIOS),
            tags: ["network", "core"],
            notes: "Main backbone router",
            lastConnected: nil,
            createdAt: .now
        )

        let output = exporter.export([host], options: .init(includeHeader: false, includeProSSHNotes: true))

        XCTAssertTrue(output.contains("# ProSSHMac folder: Network"))
        XCTAssertTrue(output.contains("# ProSSHMac tags: network, core"))
        XCTAssertTrue(output.contains("# ProSSHMac legacy mode: enabled"))
        XCTAssertTrue(output.contains("# ProSSHMac shell integration: ciscoIOS"))
        XCTAssertTrue(output.contains("# Note: Main backbone router"))
    }
}

// MARK: - Import Service Tests

final class SSHConfigImportServiceTests: XCTestCase {

    private let service = SSHConfigImportService()

    func testFullImportPreview() {
        let config = """
        Host *
            ServerAliveInterval 60

        Host bastion
            HostName bastion.example.com
            User ops

        Host web-01
            HostName 10.0.0.1
            User deploy
            ProxyJump bastion
            LocalForward 8080 localhost:80
        """

        let preview = service.preview(configText: config)

        XCTAssertEqual(preview.results.count, 2)
        XCTAssertEqual(preview.skippedEntries, 1)  // Host *
        XCTAssertTrue(preview.parserWarnings.isEmpty)
        XCTAssertFalse(preview.summary.isEmpty)

        // web-01 should have resolved bastion as jump host.
        let webHost = preview.results[1].host
        XCTAssertEqual(webHost.jumpHost, preview.results[0].host.id)
        XCTAssertEqual(webHost.portForwardingRules.count, 1)
    }

    func testDuplicateDetection() {
        let existing = Host(
            id: UUID(),
            label: "webserver",
            folder: nil,
            hostname: "10.0.0.1",
            port: 22,
            username: "admin",
            authMethod: .publicKey,
            keyReference: nil,
            certificateReference: nil,
            passwordReference: nil,
            jumpHost: nil,
            algorithmPreferences: nil,
            pinnedHostKeyAlgorithms: [],
            legacyModeEnabled: false,
            tags: [],
            notes: nil,
            lastConnected: nil,
            createdAt: .now
        )

        let imported = Host(
            id: UUID(),
            label: "web",
            folder: nil,
            hostname: "10.0.0.1",
            port: 22,
            username: "admin",
            authMethod: .publicKey,
            keyReference: nil,
            certificateReference: nil,
            passwordReference: nil,
            jumpHost: nil,
            algorithmPreferences: nil,
            pinnedHostKeyAlgorithms: [],
            legacyModeEnabled: false,
            tags: [],
            notes: nil,
            lastConnected: nil,
            createdAt: .now
        )

        let dupes = service.findDuplicates(imported: [imported], existing: [existing])

        XCTAssertEqual(dupes.count, 1)
        XCTAssertEqual(dupes[0].existing.id, existing.id)
        XCTAssertEqual(dupes[0].imported.id, imported.id)
    }

    func testEmptyConfigReturnsNoHosts() {
        let preview = service.preview(configText: "")
        XCTAssertTrue(preview.results.isEmpty)
        XCTAssertEqual(preview.skippedEntries, 0)
    }

    func testCommentsOnlyConfigReturnsNoHosts() {
        let config = """
        # This is a comment
        # Another comment
        """
        let preview = service.preview(configText: config)
        XCTAssertTrue(preview.results.isEmpty)
    }
}

// MARK: - Round-Trip Tests

final class SSHConfigRoundTripTests: XCTestCase {

    func testParseExportRoundTrip() {
        let original = """
        Host bastion
            HostName bastion.example.com
            User ops
            Port 2222
            ForwardAgent yes

        Host web-01
            HostName 10.0.0.1
            User deploy
            ProxyJump bastion
            LocalForward 8080 localhost:80
            LocalForward 5432 db.internal:5432
            KexAlgorithms curve25519-sha256
            Ciphers chacha20-poly1305@openssh.com
        """

        // Parse → Map → Export → Parse again → verify key fields survived.
        let parser = SSHConfigParser()
        let mapper = SSHConfigMapper()
        let exporter = SSHConfigExporter()

        let firstParse = parser.parse(original)
        let hosts = mapper.importAll(from: firstParse).map(\.host)

        let exported = exporter.export(hosts, options: .init(
            includeHeader: false,
            includeProSSHNotes: false,
            allHosts: hosts
        ))

        let secondParse = parser.parse(exported)
        let roundTripped = mapper.importAll(from: secondParse).map(\.host)

        XCTAssertEqual(roundTripped.count, 2)

        // Bastion
        XCTAssertEqual(roundTripped[0].hostname, "bastion.example.com")
        XCTAssertEqual(roundTripped[0].username, "ops")
        XCTAssertEqual(roundTripped[0].port, 2222)
        XCTAssertTrue(roundTripped[0].agentForwardingEnabled)

        // Web-01
        XCTAssertEqual(roundTripped[1].hostname, "10.0.0.1")
        XCTAssertEqual(roundTripped[1].username, "deploy")
        XCTAssertEqual(roundTripped[1].portForwardingRules.count, 2)
        XCTAssertNotNil(roundTripped[1].jumpHost)  // Resolved to imported bastion
        XCTAssertEqual(roundTripped[1].algorithmPreferences?.ciphers, ["chacha20-poly1305@openssh.com"])
    }
}
