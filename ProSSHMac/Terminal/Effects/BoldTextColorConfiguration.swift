import Foundation
import simd

/// Configuration for overriding the foreground color of bold terminal text.
/// Applied at render time so VT parsing and stored cell colors remain unchanged.
struct BoldTextColorConfiguration: Codable, Sendable, Equatable {
    /// Master toggle for the custom bold-text color override.
    var isEnabled: Bool

    /// Override color applied to cells carrying the bold attribute.
    var customColor: GradientColor

    static let `default` = BoldTextColorConfiguration(
        isEnabled: false,
        customColor: GradientColor(red: 1.0, green: 0.12, blue: 0.08)
    )

    var uniformColor: SIMD4<Float> {
        SIMD4<Float>(customColor.red, customColor.green, customColor.blue, customColor.alpha)
    }
}

extension BoldTextColorConfiguration {
    static let defaultsKey = "terminal.text.boldColor"

    static func load(from defaults: UserDefaults = .standard) -> BoldTextColorConfiguration {
        guard let data = defaults.data(forKey: defaultsKey),
              let config = try? JSONDecoder().decode(BoldTextColorConfiguration.self, from: data) else {
            return .default
        }
        return config
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
