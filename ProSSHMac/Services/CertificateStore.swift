import Foundation

@MainActor
protocol CertificateStoreProtocol {
    func loadCertificates() async throws -> [SSHCertificate]
    func saveCertificates(_ certificates: [SSHCertificate]) async throws
}
