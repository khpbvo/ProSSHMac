// Extracted from TerminalView.swift
import Foundation

// caseless enum prevents Swift 6 @MainActor inference on static members
enum TerminalSidebarLayoutStore {

    struct SidebarLayoutValues {
        var showFileBrowser: Bool?
        var fileBrowserWidth: Double?
        var showAIAssistant: Bool?
        var aiAssistantWidth: Double?
    }

    nonisolated static func contextKey(for session: Session) -> String {
        switch session.kind {
        case let .ssh(hostID): return "host:\(hostID.uuidString.lowercased())"
        case .local:           return "session:\(session.id.uuidString.lowercased())"
        }
    }

    nonisolated static func storageKey(_ suffix: String, context: String) -> String {
        "terminal.sidebar.layout.\(context).\(suffix)"
    }

    nonisolated static func restore(contextKey: String) -> SidebarLayoutValues {
        let d = UserDefaults.standard
        func key(_ s: String) -> String { storageKey(s, context: contextKey) }
        var v = SidebarLayoutValues()
        if d.object(forKey: key("fileBrowser.visible")) != nil  { v.showFileBrowser   = d.bool(forKey: key("fileBrowser.visible")) }
        if d.object(forKey: key("fileBrowser.width"))   != nil  { v.fileBrowserWidth  = d.double(forKey: key("fileBrowser.width")) }
        if d.object(forKey: key("aiAssistant.visible")) != nil  { v.showAIAssistant   = d.bool(forKey: key("aiAssistant.visible")) }
        if d.object(forKey: key("aiAssistant.width"))   != nil  { v.aiAssistantWidth  = d.double(forKey: key("aiAssistant.width")) }
        return v
    }

    nonisolated static func persist(
        contextKey: String,
        showFileBrowser: Bool, fileBrowserWidth: Double,
        showAIAssistant: Bool, aiAssistantWidth: Double
    ) {
        let d = UserDefaults.standard
        func key(_ s: String) -> String { storageKey(s, context: contextKey) }
        d.set(showFileBrowser,   forKey: key("fileBrowser.visible"))
        d.set(fileBrowserWidth,  forKey: key("fileBrowser.width"))
        d.set(showAIAssistant,   forKey: key("aiAssistant.visible"))
        d.set(aiAssistantWidth,  forKey: key("aiAssistant.width"))
    }
}
