import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var idleScreensaverManager: IdleScreensaverManager

    var body: some View {
        ZStack {
            RootTabView()

            if idleScreensaverManager.isActive {
                MatrixScreensaverView(
                    config: idleScreensaverManager.config,
                    onDismiss: { idleScreensaverManager.dismiss() }
                )
                .transition(.opacity.animation(.easeInOut(duration: 0.5)))
                .zIndex(1000)
            }
        }
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
            .environmentObject(dependencies.idleScreensaverManager)
    }
}
