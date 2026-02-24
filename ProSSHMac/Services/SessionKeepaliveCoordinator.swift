// Extracted from SessionManager.swift
import Foundation

@MainActor final class SessionKeepaliveCoordinator {
    weak var manager: SessionManager?
    var keepaliveTask: Task<Void, Never>?

    private var keepaliveEnabled: Bool {
        UserDefaults.standard.bool(forKey: "ssh.keepalive.enabled")
    }

    private var keepaliveInterval: TimeInterval {
        let stored = UserDefaults.standard.integer(forKey: "ssh.keepalive.interval")
        return stored > 0 ? TimeInterval(stored) : 30
    }

    init() {}

    nonisolated deinit {}

    func startIfNeeded() {
        guard keepaliveEnabled, keepaliveTask == nil else { return }
        keepaliveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.keepaliveInterval ?? 30))
                guard !Task.isCancelled else { break }
                await self?.sendKeepalives()
            }
        }
    }

    func stopIfIdle() {
        guard let manager else {
            keepaliveTask?.cancel()
            keepaliveTask = nil
            return
        }
        let hasConnectedSSHSession = manager.sessions.contains { $0.state == .connected && !$0.isLocal }
        if !hasConnectedSSHSession {
            keepaliveTask?.cancel()
            keepaliveTask = nil
        }
    }

    private func sendKeepalives() async {
        guard let manager else { return }
        let connectedSSHSessions = manager.sessions.filter { $0.state == .connected && !$0.isLocal }
        for session in connectedSSHSessions {
            let lastActivity = manager.lastActivityBySessionID[session.id] ?? .distantPast
            if Date.now.timeIntervalSince(lastActivity) < keepaliveInterval * 0.8 {
                continue
            }

            let alive = await manager.transport.sendKeepalive(sessionID: session.id)
            if !alive {
                await manager.handleShellStreamEndedInternal(sessionID: session.id)
            }
        }
    }
}
