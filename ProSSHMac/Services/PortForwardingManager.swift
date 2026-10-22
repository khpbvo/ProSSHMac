import Foundation
import Combine
import Network

enum PortForwardState: String {
    case listening
    case error
    case stopped
}

struct ActivePortForward: Identifiable {
    let id: UUID
    let rule: PortForwardingRule
    let sessionID: UUID
    var state: PortForwardState
    var activeConnections: Int
    var errorMessage: String?
}

@MainActor
final class PortForwardingManager: ObservableObject {
    @Published private(set) var activeForwards: [ActivePortForward] = []

    private let transport: any SSHTransporting
    private let auditLogManager: AuditLogManager?
    private var listeners: [UUID: NWListener] = [:]
    private var connectionProxies: [UUID: [ForwardConnectionProxy]] = [:]
    private var openingConnections: [UUID: Int] = [:]
    private var openingDrainWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private let maxConnectionsPerRule = 32

    init(transport: any SSHTransporting, auditLogManager: AuditLogManager? = nil) {
        self.transport = transport
        self.auditLogManager = auditLogManager
    }

    func activateRules(_ rules: [PortForwardingRule], sessionID: UUID) async {
        for rule in rules where rule.isEnabled {
            let forwardID = UUID()
            var forward = ActivePortForward(
                id: forwardID,
                rule: rule,
                sessionID: sessionID,
                state: .listening,
                activeConnections: 0
            )

            do {
                let params = NWParameters.tcp
                guard let nwPort = NWEndpoint.Port(rawValue: rule.localPort) else {
                    forward.state = .error
                    forward.errorMessage = "Invalid local port \(rule.localPort)."
                    activeForwards.append(forward)
                    continue
                }

                let listener = try NWListener(using: params, on: nwPort)
                listeners[forwardID] = listener
                connectionProxies[forwardID] = []
                openingConnections[forwardID] = 0

                let capturedForwardID = forwardID
                let capturedSessionID = sessionID
                let capturedRule = rule
                let capturedTransport = transport
                let capturedMaxConnections = maxConnectionsPerRule

                listener.newConnectionHandler = { [weak self] connection in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.handleNewConnection(
                            connection,
                            forwardID: capturedForwardID,
                            sessionID: capturedSessionID,
                            rule: capturedRule,
                            transport: capturedTransport,
                            maxConnections: capturedMaxConnections
                        )
                    }
                }

                listener.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        switch state {
                        case .failed(let error):
                            self.updateForwardState(id: capturedForwardID, state: .error, errorMessage: error.localizedDescription)
                        case .cancelled:
                            self.updateForwardState(id: capturedForwardID, state: .stopped)
                        default:
                            break
                        }
                    }
                }

                listener.start(queue: DispatchQueue(label: "prosshv2.portforward.\(forwardID.uuidString)"))
                activeForwards.append(forward)

            } catch {
                forward.state = .error
                forward.errorMessage = error.localizedDescription
                activeForwards.append(forward)
            }
        }
    }

    func deactivateAll(for sessionID: UUID) async {
        let forwardsToRemove = activeForwards.filter { $0.sessionID == sessionID }

        for forward in forwardsToRemove {
            await stopForward(id: forward.id)
        }
    }

    func stopForward(id: UUID) async {
        // Stop admitting connections before awaiting proxy shutdown. Pending opens
        // close their channels and drain before the owning SSH session is destroyed.
        if let listener = listeners.removeValue(forKey: id) {
            listener.cancel()
        }

        if let proxies = connectionProxies.removeValue(forKey: id) {
            for proxy in proxies {
                await proxy.stop()
            }
        }

        if openingConnections[id, default: 0] > 0 {
            await withCheckedContinuation { continuation in
                openingDrainWaiters[id, default: []].append(continuation)
            }
        }
        openingConnections.removeValue(forKey: id)

        activeForwards.removeAll(where: { $0.id == id })
    }

    func handleNewConnection(
        _ connection: NWConnection,
        forwardID: UUID,
        sessionID: UUID,
        rule: PortForwardingRule,
        transport: any SSHTransporting,
        maxConnections: Int
    ) async {
        guard let proxies = connectionProxies[forwardID],
              let openingCount = openingConnections[forwardID],
              listeners[forwardID] != nil,
              proxies.count + openingCount < maxConnections else {
            connection.cancel()
            return
        }
        openingConnections[forwardID] = openingCount + 1
        defer {
            if let pending = openingConnections[forwardID] {
                let remaining = max(0, pending - 1)
                openingConnections[forwardID] = remaining
                if remaining == 0 {
                    let waiters = openingDrainWaiters.removeValue(forKey: forwardID) ?? []
                    for waiter in waiters { waiter.resume() }
                }
            }
        }

        do {
            let channel = try await transport.openForwardChannel(
                sessionID: sessionID,
                remoteHost: rule.remoteHost,
                remotePort: rule.remotePort,
                sourceHost: "127.0.0.1",
                sourcePort: rule.localPort
            )

            guard connectionProxies[forwardID] != nil,
                  openingConnections[forwardID] != nil,
                  listeners[forwardID] != nil else {
                await channel.close()
                connection.cancel()
                return
            }

            let proxy = ForwardConnectionProxy(connection: connection, channel: channel)
            connectionProxies[forwardID]?.append(proxy)
            updateConnectionCount(forwardID: forwardID)

            await proxy.start { [weak self] in
                Task { @MainActor [weak self] in
                    self?.removeProxy(proxy, forwardID: forwardID)
                }
            }
        } catch {
            connection.cancel()
            await auditLogManager?.record(
                category: .portForwarding,
                action: "Forward channel open failed",
                outcome: .failure,
                sessionID: sessionID,
                details: "Rule \(rule.localPort) -> \(rule.remoteHost):\(rule.remotePort): \(error.localizedDescription)"
            )
        }
    }

    private func removeProxy(_ proxy: ForwardConnectionProxy, forwardID: UUID) {
        connectionProxies[forwardID]?.removeAll(where: { $0 === proxy })
        updateConnectionCount(forwardID: forwardID)
    }

    private func updateConnectionCount(forwardID: UUID) {
        guard let index = activeForwards.firstIndex(where: { $0.id == forwardID }) else { return }
        activeForwards[index].activeConnections = connectionProxies[forwardID]?.count ?? 0
    }

    private func updateForwardState(id: UUID, state: PortForwardState, errorMessage: String? = nil) {
        guard let index = activeForwards.firstIndex(where: { $0.id == id }) else { return }
        activeForwards[index].state = state
        activeForwards[index].errorMessage = errorMessage
    }
}

actor ForwardConnectionProxy {
    private let connection: NWConnection
    private let channel: any SSHForwardChannel
    private var localToRemoteTask: Task<Void, Never>?
    private var remoteToLocalTask: Task<Void, Never>?
    private var isStopped = false

    init(connection: NWConnection, channel: any SSHForwardChannel) {
        self.connection = connection
        self.channel = channel
    }

    func start(onComplete: @escaping @Sendable () -> Void) {
        guard !isStopped else {
            connection.cancel()
            onComplete()
            return
        }
        connection.start(queue: DispatchQueue(label: "prosshv2.fwdproxy.\(ObjectIdentifier(self))"))

        localToRemoteTask = Task { [weak self] in
            guard let self else { return }
            await self.runLocalToRemote()
            await self.stop()
            onComplete()
        }

        remoteToLocalTask = Task { [weak self] in
            guard let self else { return }
            await self.runRemoteToLocal()
            await self.stop()
            onComplete()
        }
    }

    func stop() async {
        guard !isStopped else { return }
        isStopped = true

        localToRemoteTask?.cancel()
        remoteToLocalTask?.cancel()
        localToRemoteTask = nil
        remoteToLocalTask = nil

        connection.cancel()
        await channel.close()
    }

    private func runLocalToRemote() async {
        while !Task.isCancelled && !isStopped {
            do {
                let data = try await receiveFromConnection()
                guard let data, !data.isEmpty else { break }
                try await channel.write(data)
            } catch {
                break
            }
        }
    }

    private func runRemoteToLocal() async {
        while !Task.isCancelled && !isStopped {
            do {
                guard await channel.isOpen else { break }
                let data = try await channel.read()
                guard let data else { break }
                if data.isEmpty { continue }
                try await sendToConnection(data)
            } catch {
                break
            }
        }
    }

    private nonisolated func receiveFromConnection() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) { content, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if isComplete && (content == nil || content!.isEmpty) {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: content)
            }
        }
    }

    private nonisolated func sendToConnection(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
}
