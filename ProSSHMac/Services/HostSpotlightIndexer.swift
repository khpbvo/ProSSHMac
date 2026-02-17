import Foundation
import CoreSpotlight
import UniformTypeIdentifiers

protocol HostSearchIndexing {
    func reindex(hosts: [Host]) async
}

final class HostSpotlightIndexer: HostSearchIndexing {
    static let hostDomainIdentifier = "prossh.hosts"
    private static let hostIdentifierPrefix = "prossh.host."

    func reindex(hosts: [Host]) async {
        let index = CSSearchableIndex.default()
        let items = hosts.map(searchableItem(for:))

        do {
            try await index.deleteSearchableItems(withDomainIdentifiers: [Self.hostDomainIdentifier])
            guard !items.isEmpty else { return }
            try await index.indexSearchableItems(items)
        } catch {
            // Spotlight indexing should not interrupt host management.
        }
    }

    static func hostID(from userActivity: NSUserActivity) -> UUID? {
        guard let identifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String else {
            return nil
        }
        guard identifier.hasPrefix(hostIdentifierPrefix) else {
            return nil
        }
        let uuidString = String(identifier.dropFirst(hostIdentifierPrefix.count))
        return UUID(uuidString: uuidString)
    }

    private func searchableItem(for host: Host) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .item)
        attributes.title = host.label
        attributes.displayName = host.label
        attributes.contentDescription = "\(host.username)@\(host.hostname):\(host.port)"
        attributes.keywords = spotlightKeywords(for: host)
        attributes.domainIdentifier = Self.hostDomainIdentifier
        attributes.lastUsedDate = host.lastConnected
        attributes.identifier = host.id.uuidString

        let identifier = Self.hostIdentifierPrefix + host.id.uuidString
        return CSSearchableItem(uniqueIdentifier: identifier, domainIdentifier: Self.hostDomainIdentifier, attributeSet: attributes)
    }

    private func spotlightKeywords(for host: Host) -> [String] {
        var keywords: [String] = [
            host.label,
            host.hostname,
            host.username
        ]
        if let folder = host.folder, !folder.isEmpty {
            keywords.append(folder)
        }
        keywords.append(contentsOf: host.tags)
        return keywords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private extension CSSearchableIndex {
    func deleteSearchableItems(withDomainIdentifiers domainIdentifiers: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            deleteSearchableItems(withDomainIdentifiers: domainIdentifiers) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func indexSearchableItems(_ items: [CSSearchableItem]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            indexSearchableItems(items) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
