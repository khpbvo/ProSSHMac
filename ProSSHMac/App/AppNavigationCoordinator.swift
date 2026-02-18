import Foundation
import Combine

@MainActor
final class AppNavigationCoordinator: ObservableObject {
    @Published var requestedSection: AppNavigationSection = .hosts

    /// Incremented on every `navigate(to:)` call so that repeated
    /// navigations to the same section still trigger `onChange`.
    @Published var navigationNonce: UInt = 0

    /// When `true` the sidebar is hidden and the terminal fills the window.
    @Published var isTerminalMaximized: Bool = false

    func navigate(to section: AppNavigationSection) {
        requestedSection = section
        navigationNonce &+= 1
    }

    func toggleTerminalMaximize() {
        isTerminalMaximized.toggle()
    }

    func restoreTerminalMaximize() {
        isTerminalMaximized = false
    }
}
