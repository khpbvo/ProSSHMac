// SessionTabManager.swift
// ProSSHV2
//
// Manages terminal session tabs, ordering, selection, and persistence.

import Foundation
import SwiftUI
import Combine

struct SessionTab: Identifiable, Hashable {
    var session: Session
    var isPinned: Bool = false

    var id: UUID { session.id }
    var label: String {
        if session.isLocal, let shellPath = session.shellPath {
            let shellName = (shellPath as NSString).lastPathComponent
            return "Local: \(shellName)"
        }
        return session.hostLabel
    }
    var statusColor: Color {
        switch session.state {
        case .connecting: return .orange
        case .connected: return .green
        case .disconnected: return .gray
        case .failed: return .red
        }
    }
}

@MainActor
final class SessionTabManager: ObservableObject {
    @Published private(set) var tabs: [SessionTab] = []
    @Published private(set) var selectedSessionID: UUID?

    private let defaults: UserDefaults
    private let orderedSessionIDsKey: String
    private let selectedSessionIDKey: String
    private let pinnedSessionIDsKey: String

    init(defaults: UserDefaults = .standard, keyPrefix: String = "terminal.tabs") {
        self.defaults = defaults
        self.orderedSessionIDsKey = "\(keyPrefix).orderedSessionIDs"
        self.selectedSessionIDKey = "\(keyPrefix).selectedSessionID"
        self.pinnedSessionIDsKey = "\(keyPrefix).pinnedSessionIDs"
        self.selectedSessionID = Self.decodeUUID(from: defaults.string(forKey: selectedSessionIDKey))
    }

    func sync(with sessions: [Session]) {
        let activeIDs = Set(sessions.map(\.id))
        var orderedIDs = loadOrderedSessionIDs().filter { activeIDs.contains($0) }
        for session in sessions where !orderedIDs.contains(session.id) {
            orderedIDs.append(session.id)
        }

        let pinnedIDs = loadPinnedSessionIDs()
        let sessionsByID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        tabs = orderedIDs.compactMap { id in
            guard let session = sessionsByID[id] else { return nil }
            return SessionTab(session: session, isPinned: pinnedIDs.contains(id))
        }

        if let selectedSessionID, activeIDs.contains(selectedSessionID) {
            // Keep current selection.
        } else if let persistedSelected = Self.decodeUUID(from: defaults.string(forKey: selectedSessionIDKey)),
                  activeIDs.contains(persistedSelected) {
            selectedSessionID = persistedSelected
        } else {
            selectedSessionID = tabs.first?.id
        }

        persistState()
    }

    func select(sessionID: UUID?) {
        guard let sessionID else {
            selectedSessionID = nil
            persistState()
            return
        }
        guard tabs.contains(where: { $0.id == sessionID }) else { return }
        selectedSessionID = sessionID
        persistState()
    }

    func tab(atOneBasedIndex index: Int) -> SessionTab? {
        let zeroBased = index - 1
        guard zeroBased >= 0, zeroBased < tabs.count else { return nil }
        return tabs[zeroBased]
    }

    func stepSelection(direction: Int) {
        guard !tabs.isEmpty else { return }
        let ids = tabs.map(\.id)
        guard let selectedSessionID,
              let currentIndex = ids.firstIndex(of: selectedSessionID) else {
            select(sessionID: ids.first)
            return
        }

        let newIndex = (currentIndex + direction + ids.count) % ids.count
        select(sessionID: ids[newIndex])
    }

    func moveTab(sessionID: UUID, by direction: Int) {
        guard let index = tabs.firstIndex(where: { $0.id == sessionID }) else { return }
        let target = index + direction
        guard target >= 0, target < tabs.count else { return }
        let tab = tabs.remove(at: index)
        tabs.insert(tab, at: target)
        persistState()
    }

    /// Move a tab from its current position to before a target tab (for drag-and-drop reorder).
    func moveTab(from sourceID: UUID, before targetID: UUID) {
        guard sourceID != targetID else { return }
        guard let sourceIndex = tabs.firstIndex(where: { $0.id == sourceID }),
              let targetIndex = tabs.firstIndex(where: { $0.id == targetID }) else { return }
        let tab = tabs.remove(at: sourceIndex)
        let insertIndex = targetIndex > sourceIndex ? targetIndex - 1 : targetIndex
        tabs.insert(tab, at: max(0, insertIndex))
        persistState()
    }

    func canMoveTab(sessionID: UUID, direction: Int) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == sessionID }) else { return false }
        let target = index + direction
        return target >= 0 && target < tabs.count
    }

    func removeTab(sessionID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == sessionID }) else { return }
        // Pinned tabs cannot be closed.
        guard !tabs[index].isPinned else { return }
        tabs.remove(at: index)

        if selectedSessionID == sessionID {
            if tabs.isEmpty {
                selectedSessionID = nil
            } else {
                let newIndex = min(index, tabs.count - 1)
                selectedSessionID = tabs[newIndex].id
            }
        }
        persistState()
    }

    // MARK: - Pin

    func togglePin(sessionID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == sessionID }) else { return }
        tabs[index].isPinned.toggle()
        persistState()
    }

    func isPinned(sessionID: UUID) -> Bool {
        tabs.first(where: { $0.id == sessionID })?.isPinned ?? false
    }

    // MARK: - Persistence

    private func loadOrderedSessionIDs() -> [UUID] {
        guard let stored = defaults.array(forKey: orderedSessionIDsKey) as? [String] else {
            return []
        }
        return stored.compactMap(Self.decodeUUID(from:))
    }

    private func loadPinnedSessionIDs() -> Set<UUID> {
        guard let stored = defaults.array(forKey: pinnedSessionIDsKey) as? [String] else {
            return []
        }
        return Set(stored.compactMap(Self.decodeUUID(from:)))
    }

    private func persistState() {
        defaults.set(tabs.map(\.id.uuidString), forKey: orderedSessionIDsKey)
        defaults.set(selectedSessionID?.uuidString, forKey: selectedSessionIDKey)
        let pinnedIDs = tabs.filter(\.isPinned).map(\.id.uuidString)
        defaults.set(pinnedIDs, forKey: pinnedSessionIDsKey)
    }

    private static func decodeUUID(from string: String?) -> UUID? {
        guard let string else { return nil }
        return UUID(uuidString: string)
    }
}
