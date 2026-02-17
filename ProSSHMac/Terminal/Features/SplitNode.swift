// SplitNode.swift
// ProSSHV2
//
// Recursive split-pane tree model for terminal pane management.

import Foundation

// MARK: - Supporting Types

enum SplitDirection: String, Codable, Sendable, CaseIterable {
    case horizontal
    case vertical
}

enum PaneSessionType: Codable, Hashable, Sendable {
    case ssh(hostID: UUID, hostLabel: String)
    case local
}

struct TerminalPane: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var sessionID: UUID?
    var sessionType: PaneSessionType
    var title: String
    var isFocused: Bool

    init(
        id: UUID = UUID(),
        sessionID: UUID? = nil,
        sessionType: PaneSessionType = .local,
        title: String = "Terminal",
        isFocused: Bool = false
    ) {
        self.id = id
        self.sessionID = sessionID
        self.sessionType = sessionType
        self.title = title
        self.isFocused = isFocused
    }
}

struct SplitContainer: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var direction: SplitDirection
    var ratio: CGFloat
    var first: SplitNode
    var second: SplitNode

    init(
        id: UUID = UUID(),
        direction: SplitDirection,
        ratio: CGFloat = 0.5,
        first: SplitNode,
        second: SplitNode
    ) {
        self.id = id
        self.direction = direction
        self.ratio = ratio
        self.first = first
        self.second = second
    }
}

// MARK: - SplitNode

indirect enum SplitNode: Codable, Hashable, Sendable {
    case terminal(TerminalPane)
    case split(SplitContainer)
}

// MARK: - Tree Traversal

extension SplitNode {

    var allPanes: [TerminalPane] {
        switch self {
        case .terminal(let pane):
            return [pane]
        case .split(let container):
            return container.first.allPanes + container.second.allPanes
        }
    }

    var paneCount: Int {
        switch self {
        case .terminal:
            return 1
        case .split(let container):
            return container.first.paneCount + container.second.paneCount
        }
    }

    var maxDepth: Int {
        switch self {
        case .terminal:
            return 0
        case .split(let container):
            return 1 + max(container.first.maxDepth, container.second.maxDepth)
        }
    }

    func findPane(id: UUID) -> TerminalPane? {
        switch self {
        case .terminal(let pane):
            return pane.id == id ? pane : nil
        case .split(let container):
            return container.first.findPane(id: id) ?? container.second.findPane(id: id)
        }
    }

    func findContainer(id: UUID) -> SplitContainer? {
        switch self {
        case .terminal:
            return nil
        case .split(let container):
            if container.id == id { return container }
            return container.first.findContainer(id: id) ?? container.second.findContainer(id: id)
        }
    }

    func findParentContainer(of paneID: UUID) -> SplitContainer? {
        switch self {
        case .terminal:
            return nil
        case .split(let container):
            if case .terminal(let first) = container.first, first.id == paneID {
                return container
            }
            if case .terminal(let second) = container.second, second.id == paneID {
                return container
            }
            return container.first.findParentContainer(of: paneID)
                ?? container.second.findParentContainer(of: paneID)
        }
    }

    func depthOf(paneID: UUID) -> Int? {
        switch self {
        case .terminal(let pane):
            return pane.id == paneID ? 0 : nil
        case .split(let container):
            if let d = container.first.depthOf(paneID: paneID) { return d + 1 }
            if let d = container.second.depthOf(paneID: paneID) { return d + 1 }
            return nil
        }
    }

    /// Replaces the pane with the given ID with a new node.
    func replacePane(_ paneID: UUID, with newNode: SplitNode) -> SplitNode {
        switch self {
        case .terminal(let pane):
            return pane.id == paneID ? newNode : self
        case .split(var container):
            container.first = container.first.replacePane(paneID, with: newNode)
            container.second = container.second.replacePane(paneID, with: newNode)
            return .split(container)
        }
    }

    /// Removes a pane by promoting its sibling.
    func removePane(_ paneID: UUID) -> SplitNode {
        switch self {
        case .terminal:
            return self
        case .split(var container):
            // Check if one of the direct children is the target pane.
            if case .terminal(let first) = container.first, first.id == paneID {
                return container.second
            }
            if case .terminal(let second) = container.second, second.id == paneID {
                return container.first
            }
            // Recurse into children.
            container.first = container.first.removePane(paneID)
            container.second = container.second.removePane(paneID)
            return .split(container)
        }
    }

    /// Updates a pane in-place using a closure.
    func updatePane(_ paneID: UUID, _ transform: (inout TerminalPane) -> Void) -> SplitNode {
        switch self {
        case .terminal(var pane):
            if pane.id == paneID {
                transform(&pane)
                return .terminal(pane)
            }
            return self
        case .split(var container):
            container.first = container.first.updatePane(paneID, transform)
            container.second = container.second.updatePane(paneID, transform)
            return .split(container)
        }
    }

    /// Updates the ratio of a split container.
    func updateContainerRatio(_ containerID: UUID, ratio: CGFloat) -> SplitNode {
        switch self {
        case .terminal:
            return self
        case .split(var container):
            if container.id == containerID {
                container.ratio = ratio
                return .split(container)
            }
            container.first = container.first.updateContainerRatio(containerID, ratio: ratio)
            container.second = container.second.updateContainerRatio(containerID, ratio: ratio)
            return .split(container)
        }
    }
}

// MARK: - Identifiable

extension SplitNode: Identifiable {
    var id: UUID {
        switch self {
        case .terminal(let pane): return pane.id
        case .split(let container): return container.id
        }
    }
}
