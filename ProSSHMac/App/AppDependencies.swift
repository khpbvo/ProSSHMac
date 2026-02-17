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

    init() {
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
        self.hostListViewModel = HostListViewModel(
            hostStore: FileHostStore(),
            sessionManager: sessionManager,
            auditLogManager: auditLogManager,
            searchIndexer: HostSpotlightIndexer(),
            biometricPasswordStore: BiometricPasswordStore(),
            biometricPassphraseStore: BiometricPasswordStore(service: "nl.budgetsoft.ProSSHV2.key-passphrases")
        )
        let transferManager = TransferManager()
        transferManager.configure(sessionManager: sessionManager)
        self.transferManager = transferManager

        self.keyForgeViewModel = KeyForgeViewModel(
            keyStore: FileKeyStore(),
            keyForgeService: KeyForgeService()
        )

        self.certificatesViewModel = CertificatesViewModel(
            service: CertificateAuthorityService(
                authorityStore: FileCertificateAuthorityStore(),
                certificateStore: FileCertificateStore(),
                secureEnclaveKeyManager: SecureEnclaveKeyManager()
            )
        )
    }
}
