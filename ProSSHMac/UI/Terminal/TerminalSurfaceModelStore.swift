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
/// An `ObservableObject` only so a window can own it as a `@StateObject`; nothing is published,
/// because views create models from `body`.
@MainActor
final class TerminalSurfaceModelStore: ObservableObject {
    private var models: [UUID: MetalTerminalSurfaceModel] = [:]

    nonisolated deinit {}

    /// The session's model, created on first use.
    func model(for sessionID: UUID) -> MetalTerminalSurfaceModel {
        if let model = models[sessionID] {
            return model
        }
        let model = MetalTerminalSurfaceModel()
        models[sessionID] = model
        return model
    }

    /// Drops the session's model, freeing its renderer once no view holds it.
    func release(sessionID: UUID) {
        models.removeValue(forKey: sessionID)
    }

    /// Drops the models of every session not in `activeSessionIDs`.
    func prune(keeping activeSessionIDs: Set<UUID>) {
        models = models.filter { activeSessionIDs.contains($0.key) }
    }
}
