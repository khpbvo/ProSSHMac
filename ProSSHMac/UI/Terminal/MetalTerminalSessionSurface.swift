// MetalTerminalSessionSurface.swift
// ProSSHV2
//
// Metal-backed terminal rendering surface, extracted from TerminalView.

import SwiftUI
import Metal
@preconcurrency import Combine
@preconcurrency import ObjectiveC

struct MetalTerminalSessionSurface: View {
    let sessionID: UUID
    let snapshot: GridSnapshot?
    let snapshotNonce: Int
    let fontSize: Double
    let backgroundOpacityPercent: Double
    let onTap: ((CGPoint) -> Void)?
    var onTerminalResize: ((Int, Int) -> Void)?
    var onScroll: ((Int) -> Void)?
    var isFocused: Bool = true
    var isLocalSession: Bool = false
    var selectionCoordinator: TerminalSelectionCoordinator?

    @StateObject private var model = MetalTerminalSurfaceModel()

    var body: some View {
        Group {
            if let renderer = model.renderer {
                TerminalMetalView(
                    renderer: renderer,
                    onTerminalResize: onTerminalResize,
                    onTap: { point in
                        model.clearSelection()
                        onTap?(point)
                    },
                    onDrag: { point, phase in
                        model.handleDrag(point: point, phase: phase)
                    },
                    onDoubleTap: { point in
                        model.handleDoubleTap(at: point)
                    },
                    onTripleTap: { point in
                        model.handleTripleTap(at: point)
                    },
                    onScroll: onScroll,
                    accessibilityLabel: "Terminal \(sessionID.uuidString.prefix(6))",
                    accessibilityHint: "Interactive SSH terminal",
                    backgroundOpacityPercent: backgroundOpacityPercent
                )
                .onAppear {
                    model.renderer?.isLocalSession = isLocalSession
                    model.updateFontSize(CGFloat(fontSize))
                    model.apply(snapshot: snapshot)
                    model.setRendererPaused(false)
                    model.updateFPS(isFocused: isFocused)
                    selectionCoordinator?.register(sessionID: sessionID, model: model)
                }
                .onDisappear {
                    model.setRendererPaused(true)
                    selectionCoordinator?.unregister(sessionID: sessionID)
                }
                .onChange(of: snapshotNonce) { _, _ in
                    model.apply(snapshot: snapshot)
                }
                .onChange(of: isFocused) { _, newValue in
                    model.updateFPS(isFocused: newValue)
                }
                .onChange(of: fontSize) { _, newValue in
                    model.updateFontSize(CGFloat(newValue))
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Metal Renderer Unavailable")
                        .font(.headline)
                    Text("Falling back is unavailable on this device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(10)
            }
        }
    }
}

/// Shared coordinator allowing TerminalView to access selection from any active surface model.
@MainActor
final class TerminalSelectionCoordinator: ObservableObject {
    private var models: [UUID: WeakModel] = [:]

    private struct WeakModel {
        weak var model: MetalTerminalSurfaceModel?
    }

    func register(sessionID: UUID, model: MetalTerminalSurfaceModel) {
        models[sessionID] = WeakModel(model: model)
    }

    func unregister(sessionID: UUID) {
        models.removeValue(forKey: sessionID)
    }

    func copySelection(sessionID: UUID) -> String? {
        models[sessionID]?.model?.copySelection()
    }

    func hasSelection(sessionID: UUID) -> Bool {
        models[sessionID]?.model?.hasSelection ?? false
    }

    func selectAll(sessionID: UUID) {
        models[sessionID]?.model?.selectAll()
    }

    func clearSelection(sessionID: UUID) {
        models[sessionID]?.model?.clearSelection()
    }
}

@MainActor
final class MetalTerminalSurfaceModel: ObservableObject {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    let renderer: MetalTerminalRenderer?
    private var dragStart: SelectionPoint?

    /// Observer token for UserDefaults change notifications.
    /// Marked `nonisolated(unsafe)` so deinit can access it without
    /// crossing the MainActor isolation boundary.
    nonisolated(unsafe) private var settingsObserver: NSObjectProtocol?

    init() {
        if let device = MTLCreateSystemDefaultDevice() {
            renderer = MetalTerminalRenderer(device: device, fontManager: FontManager())
        } else {
            renderer = nil
        }
        // Observe settings changes (gradient, CRT, etc.) and reload on the main actor.
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.renderer?.reloadGradientBackgroundSettings()
                self?.renderer?.reloadCRTEffectSettings()
                self?.renderer?.reloadScannerEffectSettings()
            }
        }
    }

    deinit {
        if let observer = settingsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func apply(snapshot: GridSnapshot?) {
        guard let renderer, let snapshot else { return }
        renderer.updateSnapshot(snapshot)
    }

    func setRendererPaused(_ paused: Bool) {
        renderer?.setPaused(paused)
    }

    func updateFPS(isFocused: Bool) {
        renderer?.setPreferredFPS(isFocused ? 0 : 30)
    }

    func updateFontSize(_ size: CGFloat) {
        renderer?.setFontSize(size)
    }

    // MARK: - Selection

    func handleDrag(point: CGPoint, phase: TerminalPointerPhase) {
        guard let renderer else { return }
        guard let cell = renderer.gridCell(at: point) else { return }

        switch phase {
        case .began:
            dragStart = cell
            renderer.setSelection(start: cell, end: cell, type: .character)
        case .changed:
            guard let start = dragStart else { return }
            renderer.setSelection(start: start, end: cell, type: .character)
        case .ended:
            dragStart = nil
        case .cancelled:
            dragStart = nil
            renderer.clearSelection()
        }
    }

    func handleDoubleTap(at point: CGPoint) {
        guard let renderer else { return }
        guard let cell = renderer.gridCell(at: point) else { return }
        renderer.setSelection(start: cell, end: cell, type: .word)
    }

    func handleTripleTap(at point: CGPoint) {
        guard let renderer else { return }
        guard let cell = renderer.gridCell(at: point) else { return }
        renderer.setSelection(start: cell, end: cell, type: .line)
    }

    func selectAll() {
        renderer?.selectAll()
    }

    func clearSelection() {
        renderer?.clearSelection()
    }

    func copySelection() -> String? {
        renderer?.selectedText()
    }

    var hasSelection: Bool {
        renderer?.hasSelection ?? false
    }
}
