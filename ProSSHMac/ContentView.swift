import SwiftUI

struct ContentView: View {
    var body: some View {
        RootTabView()
    }
}

#Preview {
    ContentViewPreview()
}

private struct ContentViewPreview: View {
    @StateObject private var dependencies = AppDependencies()

    var body: some View {
        ContentView()
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
