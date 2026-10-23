import Combine

/// Output-rate state observed only by views of this terminal session.
/// SessionManager keeps the corresponding lookup values for tools and nonreactive callers.
@MainActor
final class SessionLiveState: ObservableObject {
    @Published private(set) var snapshotNonce: Int
    @Published private(set) var scrollState: TerminalScrollState
    @Published private(set) var shellBuffer: [String]

    init(snapshotNonce: Int = 0, scrollState: TerminalScrollState = TerminalScrollState(), shellBuffer: [String] = []) {
        self.snapshotNonce = snapshotNonce
        self.scrollState = scrollState
        self.shellBuffer = shellBuffer
    }

    func setSnapshotNonce(_ value: Int) {
        snapshotNonce = value
    }

    func setScrollState(_ value: TerminalScrollState) {
        guard scrollState != value else { return }
        scrollState = value
    }

    func setShellBuffer(_ value: [String]) {
        guard shellBuffer != value else { return }
        shellBuffer = value
    }
}
