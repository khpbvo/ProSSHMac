import Foundation

enum AppNavigationSection: String, CaseIterable, Hashable, Codable, Identifiable {
    case hosts
    case terminal
    case keyForge
    case certificates
    case transfers
    case settings

    var id: String { rawValue }
}
