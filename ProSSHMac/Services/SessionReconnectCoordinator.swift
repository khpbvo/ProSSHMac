// Extracted from SessionManager.swift
import Foundation
import Network

@MainActor final class SessionReconnectCoordinator {
    weak var manager: SessionManager?

    var pendingReconnectHosts: [UUID: (host: Host, jumpHost: Host?)] = [:]
    var reconnectTask: Task<Void, Never>?
    // `nonisolated let` so networkMonitor can be safely cancelled in nonisolated deinit.
    nonisolated let networkMonitor: NWPathMonitor
    nonisolated let networkMonitorQueue: DispatchQueue
    var isNetworkReachable: Bool = true

    init() {
        self.networkMonitor = NWPathMonitor()
        self.networkMonitorQueue = DispatchQueue(label: "prosshv2.network.monitor")
    }

    // safe: networkMonitor is a nonisolated let constant; reconnectTask terminates naturally via [weak self].
    nonisolated deinit {
        networkMonitor.cancel()
    }

    func start() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.handleNetworkStatusChange(isReachable: path.status == .satisfied)
            }
        }
        networkMonitor.start(queue: networkMonitorQueue)
    }

    func stop() {
        reconnectTask?.cancel()
        reconnectTask = nil
        networkMonitor.cancel()
    }

    func applicationDidEnterBackground() {
        guard let manager else { return }
        for session in manager.sessions where session.state == .connected {
            if let host = manager.hostBySessionID[session.id] {
                pendingReconnectHosts[session.id] = (host: host, jumpHost: manager.jumpHostBySessionID[session.id])
            }
        }
    }

    func applicationDidBecomeActive() {
        scheduleReconnectAttempt(after: .milliseconds(0))
    }

    func cancelPending(sessionID: UUID) {
        pendingReconnectHosts.removeValue(forKey: sessionID)
    }

    func removePendingForHost(_ hostID: UUID) {
        let keysToRemove = pendingReconnectHosts.filter { $0.value.host.id == hostID }.map(\.key)
        for key in keysToRemove {
            pendingReconnectHosts.removeValue(forKey: key)
        }
    }

    func scheduleReconnect(for sessionID: UUID, host: Host?, jumpHost: Host?) {
        if let host {
            pendingReconnectHosts[sessionID] = (host: host, jumpHost: jumpHost)
        }
        scheduleReconnectAttempt(after: .seconds(1))
    }

    private func handleNetworkStatusChange(isReachable: Bool) {
        let wasReachable = isNetworkReachable
        isNetworkReachable = isReachable

        if isReachable && !wasReachable {
            scheduleReconnectAttempt(after: .milliseconds(250))
        }
    }

    private func scheduleReconnectAttempt(after delay: Duration) {
        guard reconnectTask == nil else {
            return
        }

        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }

            await self.attemptPendingReconnects()
            self.reconnectTask = nil

            if self.isNetworkReachable && !self.pendingReconnectHosts.isEmpty {
                self.scheduleReconnectAttempt(after: .seconds(5))
            }
        }
    }

    private func attemptPendingReconnects() async {
        guard isNetworkReachable, let manager else {
            return
        }

        let snapshot = pendingReconnectHosts
        for (oldSessionID, entry) in snapshot {
            if manager.activeSession(for: entry.host.id) != nil {
                pendingReconnectHosts.removeValue(forKey: oldSessionID)
                continue
            }

            do {
                _ = try await manager.reconnectConnect(host: entry.host, jumpHost: entry.jumpHost)
                pendingReconnectHosts.removeValue(forKey: oldSessionID)
            } catch SessionConnectionError.hostVerificationRequired {
                pendingReconnectHosts.removeValue(forKey: oldSessionID)
            } catch {
                // Keep entry in pending queue for a later retry.
            }
        }
    }
}
