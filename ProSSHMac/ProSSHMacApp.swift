import SwiftUI
import CoreSpotlight
import Foundation

@main
struct ProSSHMacApp: App {
    static let externalTerminalWindowID = "external-terminal-window"

    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("app.appearance") private var appAppearanceRawValue = AppAppearance.system.rawValue
    @StateObject private var dependencies = AppDependencies()

    init() {
        CrashDiagnostics.installUncaughtExceptionHandler()
    }

    var body: some Scene {
        WindowGroup {
            configuredRoot(content: ContentView())
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .active:
                        dependencies.sessionManager.applicationDidBecomeActive()
                        Task {
                            await handlePendingLaunchCommandIfNeeded()
                        }
                    case .background:
                        dependencies.sessionManager.applicationDidEnterBackground()
                    case .inactive:
                        break
                    @unknown default:
                        break
                    }
                }
                .onOpenURL { url in
                    guard url.isFileURL else { return }
                    Task {
                        await dependencies.keyForgeViewModel.importAirDroppedKeyFile(at: url)
                    }
                }
                .onContinueUserActivity(CSSearchableItemActionType) { userActivity in
                    Task {
                        await handleSpotlightSelection(userActivity)
                    }
                }
                .task {
                    await handlePendingLaunchCommandIfNeeded()
                }
        }
        .defaultSize(width: 1100, height: 750)

        WindowGroup("Terminal Display", id: Self.externalTerminalWindowID) {
            configuredRoot(content: ExternalTerminalWindowView())
        }
        .defaultSize(width: 900, height: 600)
    }

    private var currentAppearance: AppAppearance {
        AppAppearance(rawValue: appAppearanceRawValue) ?? .system
    }

    private func configuredRoot<Content: View>(content: Content) -> some View {
        content
            .environmentObject(dependencies.navigationCoordinator)
            .environmentObject(dependencies.hostListViewModel)
            .environmentObject(dependencies.sessionManager)
            .environmentObject(dependencies.auditLogManager)
            .environmentObject(dependencies.transferManager)
            .environmentObject(dependencies.keyForgeViewModel)
            .environmentObject(dependencies.certificatesViewModel)
            .environmentObject(dependencies.portForwardingManager)
            .environmentObject(dependencies.idleScreensaverManager)
            .preferredColorScheme(currentAppearance.preferredColorScheme)
    }

    private func handlePendingLaunchCommandIfNeeded() async {
        guard let command = AppLaunchCommandStore.shared.consume() else {
            return
        }
        await executeLaunchCommand(command)
    }

    private func handleSpotlightSelection(_ userActivity: NSUserActivity) async {
        guard let hostID = HostSpotlightIndexer.hostID(from: userActivity) else {
            return
        }
        await dependencies.hostListViewModel.loadHostsIfNeeded()
        guard let host = dependencies.hostListViewModel.host(withID: hostID) else {
            return
        }
        dependencies.navigationCoordinator.navigate(to: .hosts)
        await dependencies.hostListViewModel.connect(to: host)
        if dependencies.sessionManager.activeSession(for: host.id) != nil {
            dependencies.navigationCoordinator.navigate(to: .terminal)
        }
    }

    private func executeLaunchCommand(_ command: AppLaunchCommand) async {
        switch command.kind {
        case .openSection:
            if let section = AppNavigationSection(rawValue: command.value) {
                dependencies.navigationCoordinator.navigate(to: section)
            }
        case .connectHostQuery:
            await dependencies.hostListViewModel.loadHostsIfNeeded()
            let query = command.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let host = dependencies.hostListViewModel.host(matchingShortcutQuery: query) else {
                dependencies.hostListViewModel.errorMessage = "No host matched shortcut query '\(query)'."
                dependencies.navigationCoordinator.navigate(to: .hosts)
                return
            }

            dependencies.navigationCoordinator.navigate(to: .hosts)
            await dependencies.hostListViewModel.connect(to: host)
            if dependencies.sessionManager.activeSession(for: host.id) != nil {
                dependencies.navigationCoordinator.navigate(to: .terminal)
            }
        }
    }
}

private enum CrashDiagnostics {
    private static var didInstall = false

    static func installUncaughtExceptionHandler() {
        guard !didInstall else { return }
        didInstall = true

        NSSetUncaughtExceptionHandler { exception in
            let name = exception.name.rawValue
            let reason = exception.reason ?? "Unknown reason"
            let callStack = exception.callStackSymbols.joined(separator: "\n")
            let payload = """
            [ProSSHMac] Uncaught NSException
            name: \(name)
            reason: \(reason)
            stack:
            \(callStack)
            """

            fputs(payload + "\n", stderr)

            let logURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ProSSHMac-uncaught-exception.log")
            try? (payload + "\n\n").appendLine(to: logURL)
        }
    }
}

private extension String {
    func appendLine(to fileURL: URL) throws {
        let data = Data(utf8)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: fileURL, options: .atomic)
        }
    }
}
