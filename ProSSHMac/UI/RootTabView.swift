import SwiftUI

struct RootTabView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var navigationCoordinator: AppNavigationCoordinator
    @State private var selectedTab: AppNavigationSection = .hosts
    @State private var selectedSidebarDestination: AppNavigationSection? = .hosts

    var body: some View {
        ZStack {
            if useSplitLayout {
                NavigationSplitView {
                    List(AppNavigationSection.allCases, selection: $selectedSidebarDestination) { destination in
                        Label(destination.title, systemImage: destination.systemImage)
                            .tag(destination)
                    }
                    .labelStyle(.titleAndIcon)
                    .navigationTitle("ProSSH")
                    .listStyle(.sidebar)
                    .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 220)
                } detail: {
                    NavigationStack {
                        destinationView(for: selectedSidebarDestination ?? .hosts)
                    }
                }
                .navigationSplitViewStyle(.prominentDetail)
                .onAppear {
                    if selectedSidebarDestination == nil {
                        selectedSidebarDestination = .hosts
                    }
                }
            } else {
                TabView(selection: $selectedTab) {
                    ForEach(AppNavigationSection.allCases) { destination in
                        NavigationStack {
                            destinationView(for: destination)
                        }
                        .tabItem {
                            Label(destination.title, systemImage: destination.systemImage)
                        }
                        .tag(destination)
                    }
                }
            }

            destinationShortcutLayer
                .frame(width: 0, height: 0)
                .opacity(0.001)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
        .onAppear {
            selectDestination(navigationCoordinator.requestedSection)
        }
        .onChange(of: navigationCoordinator.navigationNonce) { _, _ in
            selectDestination(navigationCoordinator.requestedSection)
        }
    }

    @ViewBuilder
    private func destinationView(for destination: AppNavigationSection) -> some View {
        switch destination {
        case .hosts:
            HostsView()
        case .terminal:
            TerminalView()
        case .keyForge:
            KeyForgeView()
        case .certificates:
            CertificatesView()
        case .transfers:
            TransfersView()
        case .settings:
            SettingsView()
        }
    }

    private var useSplitLayout: Bool {
        horizontalSizeClass == .regular
    }

    private var destinationShortcutLayer: some View {
        Group {
            Button("Hosts") { selectDestination(.hosts) }
                .keyboardShortcut("1", modifiers: [.command])
            Button("Terminal") { selectDestination(.terminal) }
                .keyboardShortcut("2", modifiers: [.command])
            Button("KeyForge") { selectDestination(.keyForge) }
                .keyboardShortcut("3", modifiers: [.command])
            Button("Certificates") { selectDestination(.certificates) }
                .keyboardShortcut("4", modifiers: [.command])
            Button("Transfers") { selectDestination(.transfers) }
                .keyboardShortcut("5", modifiers: [.command])
            Button("Settings") { selectDestination(.settings) }
                .keyboardShortcut("6", modifiers: [.command])
        }
    }

    private func selectDestination(_ destination: AppNavigationSection) {
        if useSplitLayout {
            selectedSidebarDestination = destination
        } else {
            selectedTab = destination
        }
    }
}

#Preview {
    RootTabPreview()
}

private struct RootTabPreview: View {
    @StateObject private var dependencies = AppDependencies()

    var body: some View {
        RootTabView()
            .environmentObject(dependencies.hostListViewModel)
            .environmentObject(dependencies.sessionManager)
            .environmentObject(dependencies.auditLogManager)
            .environmentObject(dependencies.transferManager)
            .environmentObject(dependencies.keyForgeViewModel)
            .environmentObject(dependencies.certificatesViewModel)
            .environmentObject(dependencies.portForwardingManager)
            .environmentObject(dependencies.navigationCoordinator)
    }
}

private extension AppNavigationSection {
    var title: String {
        switch self {
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

    var systemImage: String {
        switch self {
        case .hosts:
            return "server.rack"
        case .terminal:
            return "terminal"
        case .keyForge:
            return "key.horizontal"
        case .certificates:
            return "checkmark.seal"
        case .transfers:
            return "arrow.left.arrow.right.circle"
        case .settings:
            return "gearshape"
        }
    }
}
