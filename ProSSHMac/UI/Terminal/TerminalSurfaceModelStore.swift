// TerminalSurfaceModelStore.swift
// ProSSHMac
//
// One surface model (and so one Metal renderer) per session for a window.

import Foundation
import Combine

/// Owns each session's `MetalTerminalSurfaceModel`, so that layout changes which rebuild the
/// surface view (tab switch, split, unsplit, pane maximize) keep the session's renderer and with
/// it the selection, scroll state and glyph atlas. See Docs/Bug84.md.
///
/// One renderer drives one view, so a session shown in two panes at once gets a second model for
/// the later pane (`duplicateInPane`). Which pane is "later" is the caller's decision, made from
/// pane state rather than view lifecycle.
///
/// An `ObservableObject` only so a window can own it as a `@StateObject`; nothing is published,
/// because views create models from `body`.
@MainActor
final class TerminalSurfaceModelStore: ObservableObject {
    private var models: [UUID: MetalTerminalSurfaceModel] = [:]
    private var duplicates: [UUID: (sessionID: UUID, model: MetalTerminalSurfaceModel)] = [:]

    nonisolated deinit {}

    /// The session's model, created on first use. With `paneID`, the model for that pane's second
    /// view of the session instead.
    func model(for sessionID: UUID, duplicateInPane paneID: UUID? = nil) -> MetalTerminalSurfaceModel {
        if let paneID {
            if let entry = duplicates[paneID], entry.sessionID == sessionID {
                return entry.model
            }
            let model = MetalTerminalSurfaceModel()
            duplicates[paneID] = (sessionID, model)
            return model
        }
        if let model = models[sessionID] {
            return model
        }
        let model = MetalTerminalSurfaceModel()
        models[sessionID] = model
        return model
    }

    /// Drops the session's models, freeing their renderers once no view holds them.
    func release(sessionID: UUID) {
        models.removeValue(forKey: sessionID)
        duplicates = duplicates.filter { $0.value.sessionID != sessionID }
    }

    /// Drops the models of every session not in `activeSessionIDs`, and, when `activePaneIDs` is
    /// given, the duplicate models of panes not in it.
    func prune(keeping activeSessionIDs: Set<UUID>, panes activePaneIDs: Set<UUID>? = nil) {
        models = models.filter { activeSessionIDs.contains($0.key) }
        duplicates = duplicates.filter { paneID, entry in
            activeSessionIDs.contains(entry.sessionID) && (activePaneIDs?.contains(paneID) ?? true)
        }
    }
}
