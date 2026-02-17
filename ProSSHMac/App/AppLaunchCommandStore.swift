import Foundation

enum AppLaunchCommandKind: String, Codable {
    case openSection
    case connectHostQuery
}

struct AppLaunchCommand: Codable {
    var kind: AppLaunchCommandKind
    var value: String
    var issuedAt: Date

    init(kind: AppLaunchCommandKind, value: String, issuedAt: Date = .now) {
        self.kind = kind
        self.value = value
        self.issuedAt = issuedAt
    }
}

@MainActor
final class AppLaunchCommandStore {
    static let shared = AppLaunchCommandStore()

    private let storageKey = "prossh.app.launch.command"
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func enqueue(_ command: AppLaunchCommand) {
        guard let encoded = try? JSONEncoder().encode(command) else {
            return
        }
        userDefaults.set(encoded, forKey: storageKey)
    }

    func consume() -> AppLaunchCommand? {
        guard let data = userDefaults.data(forKey: storageKey) else {
            return nil
        }
        userDefaults.removeObject(forKey: storageKey)
        return try? JSONDecoder().decode(AppLaunchCommand.self, from: data)
    }
}
