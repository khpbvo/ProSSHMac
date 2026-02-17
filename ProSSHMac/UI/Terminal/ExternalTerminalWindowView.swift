import SwiftUI

struct ExternalTerminalWindowView: View {
    var body: some View {
        NavigationStack {
            TerminalView()
        }
    }
}

#Preview {
    ExternalTerminalWindowPreview()
}

private struct ExternalTerminalWindowPreview: View {
    @StateObject private var dependencies = AppDependencies()

    var body: some View {
        ExternalTerminalWindowView()
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
