// PaneLayoutStore.swift
// ProSSHV2
//
// Persists and restores split-pane layouts via UserDefaults.

import Foundation

@MainActor
final class PaneLayoutStore {

    // MARK: - Keys

    private static let lastLayoutKey = "paneLayout.last"
    private static let savedLayoutsKey = "paneLayout.saved"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Last Layout (auto-save / auto-restore)

    func saveLastLayout(_ node: SplitNode) {
        guard let data = try? JSONEncoder().encode(node) else { return }
        defaults.set(data, forKey: Self.lastLayoutKey)
    }

    func loadLastLayout() -> SplitNode? {
        guard let data = defaults.data(forKey: Self.lastLayoutKey) else { return nil }
        return try? JSONDecoder().decode(SplitNode.self, from: data)
    }

    func clearLastLayout() {
        defaults.removeObject(forKey: Self.lastLayoutKey)
    }

    // MARK: - Named Layouts

    func saveNamedLayout(_ name: String, node: SplitNode) {
        var layouts = loadAllNamedLayouts()
        layouts[name] = node
        persist(layouts)
    }

    func loadNamedLayout(_ name: String) -> SplitNode? {
        loadAllNamedLayouts()[name]
    }

    func deleteNamedLayout(_ name: String) {
        var layouts = loadAllNamedLayouts()
        layouts.removeValue(forKey: name)
        persist(layouts)
    }

    func namedLayoutNames() -> [String] {
        Array(loadAllNamedLayouts().keys).sorted()
    }

    // MARK: - Presets

    enum Preset: String, CaseIterable, Sendable {
        case sideBySide = "Side by Side"
        case threeColumn = "Three Column"
        case quadGrid = "Quad Grid"
        case mainPlusSidebar = "Main + Sidebar"

        var node: SplitNode {
            switch self {
            case .sideBySide:
                return .split(SplitContainer(
                    direction: .vertical,
                    ratio: 0.5,
                    first: .terminal(TerminalPane(title: "Left")),
                    second: .terminal(TerminalPane(title: "Right"))
                ))

            case .threeColumn:
                return .split(SplitContainer(
                    direction: .vertical,
                    ratio: 0.333,
                    first: .terminal(TerminalPane(title: "Left")),
                    second: .split(SplitContainer(
                        direction: .vertical,
                        ratio: 0.5,
                        first: .terminal(TerminalPane(title: "Center")),
                        second: .terminal(TerminalPane(title: "Right"))
                    ))
                ))

            case .quadGrid:
                return .split(SplitContainer(
                    direction: .vertical,
                    ratio: 0.5,
                    first: .split(SplitContainer(
                        direction: .horizontal,
                        ratio: 0.5,
                        first: .terminal(TerminalPane(title: "Top Left")),
                        second: .terminal(TerminalPane(title: "Bottom Left"))
                    )),
                    second: .split(SplitContainer(
                        direction: .horizontal,
                        ratio: 0.5,
                        first: .terminal(TerminalPane(title: "Top Right")),
                        second: .terminal(TerminalPane(title: "Bottom Right"))
                    ))
                ))

            case .mainPlusSidebar:
                return .split(SplitContainer(
                    direction: .vertical,
                    ratio: 0.65,
                    first: .terminal(TerminalPane(title: "Main")),
                    second: .split(SplitContainer(
                        direction: .horizontal,
                        ratio: 0.5,
                        first: .terminal(TerminalPane(title: "Top Side")),
                        second: .terminal(TerminalPane(title: "Bottom Side"))
                    ))
                ))
            }
        }
    }

    // MARK: - Private

    private func loadAllNamedLayouts() -> [String: SplitNode] {
        guard let data = defaults.data(forKey: Self.savedLayoutsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: SplitNode].self, from: data)) ?? [:]
    }

    private func persist(_ layouts: [String: SplitNode]) {
        guard let data = try? JSONEncoder().encode(layouts) else { return }
        defaults.set(data, forKey: Self.savedLayoutsKey)
    }
}
