import Foundation
import AppIntents

@available(macOS 13.0, *)
enum ProSSHSectionOption: String, AppEnum {
    case hosts
    case terminal
    case keyForge
    case certificates
    case transfers
    case settings

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "ProSSH Section"

    static let caseDisplayRepresentations: [ProSSHSectionOption: DisplayRepresentation] = [
        .hosts: "Hosts",
        .terminal: "Terminal",
        .keyForge: "KeyForge",
        .certificates: "Certificates",
        .transfers: "Transfers",
        .settings: "Settings"
    ]

    var section: AppNavigationSection {
        switch self {
        case .hosts:
            return .hosts
        case .terminal:
            return .terminal
        case .keyForge:
            return .keyForge
        case .certificates:
            return .certificates
        case .transfers:
            return .transfers
        case .settings:
            return .settings
        }
    }
}

@available(macOS 13.0, *)
struct OpenProSSHSectionIntent: AppIntent {
    static let title: LocalizedStringResource = "Open ProSSH Section"
    static let description = IntentDescription("Open ProSSH directly to a specific section.")
    static let openAppWhenRun = true

    @Parameter(title: "Section")
    var section: ProSSHSectionOption

    init() {}

    init(section: ProSSHSectionOption) {
        self.section = section
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run {
            AppLaunchCommandStore.shared.enqueue(
                AppLaunchCommand(kind: .openSection, value: section.section.rawValue)
            )
        }
        return .result(dialog: "Opening \(sectionDisplayName) in ProSSH.")
    }

    private var sectionDisplayName: String {
        switch section {
        case .hosts:
            return "Hosts"
        case .terminal:
            return "Terminal"
        case .keyForge:
            return "KeyForge"
        case .certificates:
            return "Certificates"
        case .transfers:
            return "Transfers"
        case .settings:
            return "Settings"
        }
    }
}

@available(macOS 13.0, *)
struct ConnectHostShortcutIntent: AppIntent {
    static let title: LocalizedStringResource = "Connect Host in ProSSH"
    static let description = IntentDescription("Open ProSSH and connect to a host by label or hostname.")
    static let openAppWhenRun = true

    @Parameter(title: "Host")
    var hostQuery: String

    init() {}

    init(hostQuery: String) {
        self.hostQuery = hostQuery
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let query = hostQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return .result(dialog: "Enter a host label or hostname.")
        }

        await MainActor.run {
            AppLaunchCommandStore.shared.enqueue(
                AppLaunchCommand(kind: .connectHostQuery, value: query)
            )
        }
        return .result(dialog: "Opening ProSSH and connecting to \(query).")
    }
}

@available(macOS 13.0, *)
struct ProSSHShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenProSSHSectionIntent(),
            phrases: [
                "Open \(\.$section) in \(.applicationName)",
                "Show \(\.$section) in \(.applicationName)"
            ],
            shortTitle: "Open Section",
            systemImageName: "square.grid.2x2"
        )

        AppShortcut(
            intent: ConnectHostShortcutIntent(),
            phrases: [
                "Connect host in \(.applicationName)",
                "Start SSH in \(.applicationName)"
            ],
            shortTitle: "Connect Host",
            systemImageName: "terminal"
        )
    }

    static var shortcutTileColor: ShortcutTileColor {
        .blue
    }
}
