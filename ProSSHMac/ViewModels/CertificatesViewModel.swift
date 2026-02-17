import Foundation
import Combine

struct CertificateAuthorityDraft: Equatable {
    var label = ""
    var certificateType: CertificateType = .both
    var defaultValidityDays = 30
    var notes = ""

    var validationError: String? {
        if label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "A CA label is required."
        }
        if defaultValidityDays < 1 || defaultValidityDays > 3650 {
            return "Default validity must be between 1 and 3650 days."
        }
        return nil
    }

    func toRequest() -> CertificateAuthorityGenerationRequest {
        CertificateAuthorityGenerationRequest(
            label: label.trimmingCharacters(in: .whitespacesAndNewlines),
            certificateType: certificateType,
            defaultValidityDuration: TimeInterval(defaultValidityDays) * 86_400,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

struct UserCertificateDraft: Equatable {
    var authorityID: UUID?
    var subjectPublicKeyAuthorized = ""
    var associatedKeyID: UUID?
    var keyID = ""
    var serialNumber = ""
    var principals = ""
    var validAfter = Date()
    var validBefore = Date().addingTimeInterval(30 * 86_400)
    var criticalOptions = ""
    var extensions = ""

    func toRequest() throws -> UserCertificateSigningRequest {
        guard let authorityID else {
            throw CertificateAuthorityError.signingFailed(message: "Please select a certificate authority.")
        }

        let normalizedSubjectKey = subjectPublicKeyAuthorized.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedSubjectKey.isEmpty {
            throw CertificateAuthorityError.signingFailed(message: "A subject public key is required.")
        }

        let normalizedKeyID = keyID.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedKeyID.isEmpty {
            throw CertificateAuthorityError.signingFailed(message: "A certificate key ID is required.")
        }

        guard let parsedSerial = UInt64(serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw CertificateAuthorityError.signingFailed(message: "Serial number must be an unsigned integer.")
        }

        if validBefore <= validAfter {
            throw CertificateAuthorityError.signingFailed(message: "Certificate validity end must be after start.")
        }

        return UserCertificateSigningRequest(
            authorityID: authorityID,
            subjectPublicKeyAuthorized: normalizedSubjectKey,
            associatedKeyID: associatedKeyID,
            keyID: normalizedKeyID,
            serialNumber: parsedSerial,
            principals: parseList(principals),
            validAfter: validAfter,
            validBefore: validBefore,
            criticalOptions: try parseNameValueMap(criticalOptions, label: "critical options"),
            extensions: try parseNameValueMap(extensions, label: "extensions")
        )
    }

    mutating func applyAuthorityDefaults(_ authority: CertificateAuthorityModel?) {
        guard let authority else { return }
        validBefore = validAfter.addingTimeInterval(authority.defaultValidityDuration)
        if serialNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            serialNumber = String(authority.nextSerialNumber)
        }
    }

    private func parseList(_ value: String) -> [String] {
        value
            .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == "\r" || $0 == "\t" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func parseNameValueMap(_ value: String, label: String) throws -> [String: String] {
        var mapped: [String: String] = [:]

        for rawLine in value.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                continue
            }

            if let separator = line.firstIndex(of: "=") {
                let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
                let mapValue = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if key.isEmpty {
                    throw CertificateAuthorityError.signingFailed(
                        message: "Invalid \(label) line: '\(line)'. Use 'name=value'."
                    )
                }
                mapped[key] = mapValue
            } else {
                mapped[line] = ""
            }
        }

        return mapped
    }
}

struct HostCertificateDraft: Equatable {
    var authorityID: UUID?
    var subjectPublicKeyAuthorized = ""
    var associatedKeyID: UUID?
    var keyID = ""
    var serialNumber = ""
    var hostPrincipals = ""
    var validAfter = Date()
    var validBefore = Date().addingTimeInterval(30 * 86_400)
    var criticalOptions = ""
    var extensions = ""

    func toRequest() throws -> HostCertificateSigningRequest {
        guard let authorityID else {
            throw CertificateAuthorityError.signingFailed(message: "Please select a certificate authority.")
        }

        let normalizedSubjectKey = subjectPublicKeyAuthorized.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedSubjectKey.isEmpty {
            throw CertificateAuthorityError.signingFailed(message: "A host public key is required.")
        }

        let normalizedKeyID = keyID.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedKeyID.isEmpty {
            throw CertificateAuthorityError.signingFailed(message: "A certificate key ID is required.")
        }

        guard let parsedSerial = UInt64(serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw CertificateAuthorityError.signingFailed(message: "Serial number must be an unsigned integer.")
        }

        if validBefore <= validAfter {
            throw CertificateAuthorityError.signingFailed(message: "Certificate validity end must be after start.")
        }

        return HostCertificateSigningRequest(
            authorityID: authorityID,
            subjectPublicKeyAuthorized: normalizedSubjectKey,
            associatedKeyID: associatedKeyID,
            keyID: normalizedKeyID,
            serialNumber: parsedSerial,
            principals: parseList(hostPrincipals),
            validAfter: validAfter,
            validBefore: validBefore,
            criticalOptions: try parseNameValueMap(criticalOptions, label: "critical options"),
            extensions: try parseNameValueMap(extensions, label: "extensions")
        )
    }

    mutating func applyAuthorityDefaults(_ authority: CertificateAuthorityModel?) {
        guard let authority else { return }
        validBefore = validAfter.addingTimeInterval(authority.defaultValidityDuration)
        if serialNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            serialNumber = String(authority.nextSerialNumber)
        }
    }

    private func parseList(_ value: String) -> [String] {
        value
            .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == "\r" || $0 == "\t" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func parseNameValueMap(_ value: String, label: String) throws -> [String: String] {
        var mapped: [String: String] = [:]

        for rawLine in value.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                continue
            }

            if let separator = line.firstIndex(of: "=") {
                let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
                let mapValue = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if key.isEmpty {
                    throw CertificateAuthorityError.signingFailed(
                        message: "Invalid \(label) line: '\(line)'. Use 'name=value'."
                    )
                }
                mapped[key] = mapValue
            } else {
                mapped[line] = ""
            }
        }

        return mapped
    }
}

struct KRLGenerationDraft: Equatable {
    var authorityID: UUID?
    var revokedSerials = ""
    var includeExpiredCertificates = true

    func toRequest() throws -> KRLGenerationRequest {
        let normalized = revokedSerials.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            return KRLGenerationRequest(
                authorityID: authorityID,
                revokedSerials: [],
                includeExpiredCertificates: includeExpiredCertificates
            )
        }

        var parsedSerials: [UInt64] = []
        let tokens = normalized
            .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == "\r" || $0 == "\t" || $0 == " " })
            .map(String.init)

        for token in tokens {
            guard let serial = UInt64(token) else {
                throw CertificateAuthorityError.signingFailed(
                    message: "Invalid serial value '\(token)'. Use unsigned integer serial numbers."
                )
            }
            parsedSerials.append(serial)
        }

        return KRLGenerationRequest(
            authorityID: authorityID,
            revokedSerials: parsedSerials,
            includeExpiredCertificates: includeExpiredCertificates
        )
    }
}

@MainActor
final class CertificatesViewModel: ObservableObject {
    @Published private(set) var authorities: [CertificateAuthorityModel] = []
    @Published private(set) var certificates: [SSHCertificate] = []
    @Published var isLoading = false
    @Published var isGeneratingAuthority = false
    @Published var isSigningCertificate = false
    @Published var isImportingCertificate = false
    @Published var isGeneratingKRL = false
    @Published var errorMessage: String?

    private let service: CertificateAuthorityService
    private var hasLoaded = false

    init(service: CertificateAuthorityService) {
        self.service = service
    }

    func loadAuthoritiesIfNeeded() async {
        guard !hasLoaded else { return }
        await loadAuthorities()
    }

    func loadAuthorities() async {
        isLoading = true
        defer { isLoading = false }

        do {
            async let loadedAuthorities = service.loadAuthorities()
            async let loadedCertificates = service.loadCertificates()

            authorities = try await loadedAuthorities.sorted { $0.createdAt > $1.createdAt }
            certificates = try await loadedCertificates.sorted { $0.createdAt > $1.createdAt }
            hasLoaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createAuthority(from draft: CertificateAuthorityDraft) async -> Bool {
        if let validationError = draft.validationError {
            errorMessage = validationError
            return false
        }

        isGeneratingAuthority = true
        defer { isGeneratingAuthority = false }

        do {
            authorities = try await service.createAuthority(
                request: draft.toRequest(),
                existingAuthorities: authorities
            )
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func signUserCertificate(from draft: UserCertificateDraft) async -> Bool {
        let request: UserCertificateSigningRequest
        do {
            request = try draft.toRequest()
        } catch {
            errorMessage = error.localizedDescription
            return false
        }

        isSigningCertificate = true
        defer { isSigningCertificate = false }

        do {
            let updated = try await service.signUserCertificate(
                request: request,
                existingAuthorities: authorities,
                existingCertificates: certificates
            )
            authorities = updated.authorities
            certificates = updated.certificates
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func signHostCertificate(from draft: HostCertificateDraft) async -> Bool {
        let request: HostCertificateSigningRequest
        do {
            request = try draft.toRequest()
        } catch {
            errorMessage = error.localizedDescription
            return false
        }

        isSigningCertificate = true
        defer { isSigningCertificate = false }

        do {
            let updated = try await service.signHostCertificate(
                request: request,
                existingAuthorities: authorities,
                existingCertificates: certificates
            )
            authorities = updated.authorities
            certificates = updated.certificates
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func importExternalCertificate(from authorizedCertificate: String) async -> Bool {
        let normalized = authorizedCertificate.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            errorMessage = "Paste an OpenSSH certificate first."
            return false
        }

        isImportingCertificate = true
        defer { isImportingCertificate = false }

        do {
            certificates = try await service.importExternalCertificate(
                authorizedCertificate: normalized,
                existingCertificates: certificates
            )
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func generateKRL(from draft: KRLGenerationDraft) -> GeneratedKRLBundle? {
        let request: KRLGenerationRequest
        do {
            request = try draft.toRequest()
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }

        isGeneratingKRL = true
        defer { isGeneratingKRL = false }

        do {
            return try service.generateKRL(
                request: request,
                authorities: authorities,
                certificates: certificates
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func authority(for id: UUID?) -> CertificateAuthorityModel? {
        guard let id else { return nil }
        return authorities.first(where: { $0.id == id })
    }

    func deleteAuthorities(at offsets: IndexSet) async {
        let ids = offsets.map { authorities[$0].id }
        do {
            authorities = try await service.deleteAuthorities(ids: ids, existingAuthorities: authorities)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearError() {
        errorMessage = nil
    }
}
