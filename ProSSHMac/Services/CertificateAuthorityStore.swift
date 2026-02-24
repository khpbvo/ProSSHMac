import Foundation

@MainActor
protocol CertificateAuthorityStoreProtocol {
    func loadAuthorities() async throws -> [CertificateAuthorityModel]
    func saveAuthorities(_ authorities: [CertificateAuthorityModel]) async throws
}
