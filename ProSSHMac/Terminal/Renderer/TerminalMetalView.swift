// TerminalMetalView.swift
// ProSSHV2
//
// SwiftUI wrapper for MTKView on macOS.

import SwiftUI
import MetalKit
import AppKit

enum TerminalPointerPhase {
    case began
    case changed
    case ended
    case cancelled
}

struct TerminalMetalView: NSViewRepresentable {
    let renderer: MetalTerminalRenderer
    var onTerminalResize: ((Int, Int) -> Void)?
    var onTap: ((CGPoint) -> Void)?
    var onDrag: ((CGPoint, TerminalPointerPhase) -> Void)?
    var onDoubleTap: ((CGPoint) -> Void)?
    var onTripleTap: ((CGPoint) -> Void)?
    /// Called when user scrolls (positive = up/scrollback, negative = down/toward live).
    var onScroll: ((Int) -> Void)?
    /// Whether emulator viewport scrolling is currently allowed.
    /// Alternate-screen TUIs should disable this and either ignore the wheel
    /// or handle it through mouse reporting overlays instead.
    var allowsViewportScrolling: (() -> Bool)? = nil
    var accessibilityLabel: String = "Terminal"
    var accessibilityHint: String = "Interactive SSH terminal"
    var backgroundOpacityPercent: Double = TransparencyManager.defaultBackgroundOpacityPercent

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> TerminalMetalContainerView {
        let container = TerminalMetalContainerView(frame: .zero)
        let mtkView = container.metalView
        renderer.configureView(mtkView)
        renderer.onGridSizeChange = onTerminalResize

        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        let tripleClick = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTripleClick(_:)))
        tripleClick.numberOfClicksRequired = 3

        let doubleClick = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleClick(_:)))
        doubleClick.numberOfClicksRequired = 2

        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleClick(_:)))
        click.numberOfClicksRequired = 1

        let pan = NSPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))

        mtkView.addGestureRecognizer(tripleClick)
        mtkView.addGestureRecognizer(doubleClick)
        mtkView.addGestureRecognizer(click)
        mtkView.addGestureRecognizer(pan)

        container.onScroll = onScroll
        container.allowsViewportScrolling = allowsViewportScrolling
        container.cellHeight = renderer.currentCellHeight
        container.renderer = renderer
        renderer.smoothScrollEngine.onScrollLineChange = { [weak container] lines in
            container?.onScroll?(lines)
        }
        container.setBackgroundOpacity(backgroundOpacity)
        return container
    }

    func updateNSView(_ nsView: TerminalMetalContainerView, context: Context) {
        context.coordinator.parent = self
        renderer.onGridSizeChange = onTerminalResize
        nsView.onScroll = onScroll
        nsView.allowsViewportScrolling = allowsViewportScrolling
        nsView.cellHeight = renderer.currentCellHeight
        nsView.renderer = renderer
        renderer.smoothScrollEngine.onScrollLineChange = { [weak nsView] lines in
            nsView?.onScroll?(lines)
        }
        nsView.setBackgroundOpacity(backgroundOpacity)
    }

    private var backgroundOpacity: CGFloat {
        CGFloat(TransparencyManager.normalizedOpacity(fromPercent: backgroundOpacityPercent))
    }

    final class Coordinator: NSObject {
        var parent: TerminalMetalView

        init(parent: TerminalMetalView) {
            self.parent = parent
        }

        @objc
        func handleClick(_ recognizer: NSClickGestureRecognizer) {
            guard let view = recognizer.view else { return }
            parent.onTap?(recognizer.location(in: view))
        }

        @objc
        func handleDoubleClick(_ recognizer: NSClickGestureRecognizer) {
            guard let view = recognizer.view else { return }
            parent.onDoubleTap?(recognizer.location(in: view))
        }

        @objc
        func handleTripleClick(_ recognizer: NSClickGestureRecognizer) {
            guard let view = recognizer.view else { return }
            parent.onTripleTap?(recognizer.location(in: view))
        }

        @objc
        func handlePan(_ recognizer: NSPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let phase: TerminalPointerPhase
            switch recognizer.state {
            case .began: phase = .began
            case .changed: phase = .changed
            case .ended: phase = .ended
            default: phase = .cancelled
            }
            parent.onDrag?(recognizer.location(in: view), phase)
        }
    }
}

final class TerminalMetalContainerView: NSView {
    let blurView = NSVisualEffectView(frame: .zero)
    let metalView = MTKView(frame: .zero)
    var onScroll: ((Int) -> Void)?
    var allowsViewportScrolling: (() -> Bool)?
    var cellHeight: CGFloat = 16
    weak var renderer: MetalTerminalRenderer?
    private var accumulatedScrollY: CGFloat = 0
    private var preciseScrollGestureActive = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        blurView.translatesAutoresizingMaskIntoConstraints = false
        blurView.material = .underWindowBackground
        blurView.blendingMode = .withinWindow
        blurView.state = .active
        blurView.isEmphasized = false
        addSubview(blurView)

        metalView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(metalView)

        NSLayoutConstraint.activate([
            blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
            blurView.topAnchor.constraint(equalTo: topAnchor),
            blurView.bottomAnchor.constraint(equalTo: bottomAnchor),
            metalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            metalView.topAnchor.constraint(equalTo: topAnchor),
            metalView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setBackgroundOpacity(_ opacity: CGFloat) {
        let clamped = min(max(opacity, 0), 1)
        blurView.alphaValue = clamped
        blurView.isHidden = clamped >= 1.0
    }

    override func scrollWheel(with event: NSEvent) {
        guard cellHeight > 0 else { return }
        guard allowsViewportScrolling?() ?? true else {
            renderer?.scrollGestureEnded()
            renderer?.scrollMomentumEnded()
            return
        }

        if let renderer, renderer.smoothScrollConfiguration.isEnabled {
            if event.hasPreciseScrollingDeltas {
                handlePreciseScroll(event, renderer: renderer)
            } else {
                // Discrete mouse wheel: use fixed 3-row step
                let direction: CGFloat = event.scrollingDeltaY > 0 ? 1 : (event.scrollingDeltaY < 0 ? -1 : 0)
                renderer.scrollDelta(direction * cellHeight * 3)
            }
        } else {
            // Legacy integer accumulation fallback
            accumulatedScrollY += event.scrollingDeltaY
            let lines = Int(accumulatedScrollY / cellHeight)
            if lines != 0 {
                onScroll?(lines)
                accumulatedScrollY -= CGFloat(lines) * cellHeight
            }
            if event.phase == .ended || event.momentumPhase == .ended {
                accumulatedScrollY = 0
            }
        }
    }

    private func handlePreciseScroll(_ event: NSEvent, renderer: MetalTerminalRenderer) {
        let phase = event.phase
        let momentumPhase = event.momentumPhase

        let directGestureEvent = momentumPhase.isEmpty
        if directGestureEvent && !preciseScrollGestureActive {
            renderer.reloadSmoothScrollSettings()
            renderer.scrollGestureBegan()
            preciseScrollGestureActive = true
        }

        renderer.scrollDelta(event.scrollingDeltaY)

        if directGestureEvent && (phase == .ended || phase == .cancelled) {
            renderer.scrollGestureEnded()
            preciseScrollGestureActive = false
            if phase == .ended {
                renderer.scrollMomentumBegan()
            }
        }

        if momentumPhase == .began {
            if preciseScrollGestureActive {
                renderer.scrollGestureEnded()
                preciseScrollGestureActive = false
            }
            renderer.scrollMomentumBegan()
        } else if momentumPhase == .ended || momentumPhase == .cancelled {
            renderer.scrollMomentumEnded()
        }
    }
}
