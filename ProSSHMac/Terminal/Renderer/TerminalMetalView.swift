// TerminalMetalView.swift
// ProSSHV2
//
// SwiftUI wrapper for MTKView on macOS.

import SwiftUI
import MetalKit
import AppKit

struct TerminalMetalView: NSViewRepresentable {
    let renderer: MetalTerminalRenderer
    var onTerminalResize: ((Int, Int) -> Void)?
    /// Left-button press with AppKit's click count (2 = double-click, 3 = triple-click).
    var onMouseDown: ((CGPoint, Int) -> Void)?
    var onMouseDragged: ((CGPoint) -> Void)?
    var onMouseUp: (() -> Void)?
    /// Called when user scrolls (positive = up/scrollback, negative = down/toward live).
    var onScroll: ((Int) -> Void)?
    /// Decide whether the current wheel event should drive emulator scrollback
    /// instead of being left to any app-owned mouse reporting path.
    var shouldRouteWheelToViewport: ((CGFloat) -> Bool)? = nil
    var accessibilityLabel: String = "Terminal"
    var accessibilityHint: String = "Interactive SSH terminal"
    var backgroundOpacityPercent: Double = TransparencyManager.defaultBackgroundOpacityPercent

    func makeNSView(context: Context) -> TerminalMetalContainerView {
        let container = TerminalMetalContainerView(frame: .zero)
        let mtkView = container.metalView
        renderer.configureView(mtkView)
        renderer.onGridSizeChange = onTerminalResize

        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        // Mouse events, not gesture recognizers: a pan recognizer claimed every trackpad click
        // (sub-pixel movement), so click, double- and triple-click never fired (Bug 85).
        mtkView.onMouseDown = onMouseDown
        mtkView.onMouseDragged = onMouseDragged
        mtkView.onMouseUp = onMouseUp

        container.onScroll = onScroll
        container.shouldRouteWheelToViewport = shouldRouteWheelToViewport
        container.cellHeight = renderer.currentCellHeight
        container.renderer = renderer
        renderer.smoothScrollEngine.onScrollLineChange = { [weak container] lines in
            container?.onScroll?(lines)
        }
        container.setBackgroundOpacity(backgroundOpacity)
        return container
    }

    func updateNSView(_ nsView: TerminalMetalContainerView, context: Context) {
        nsView.metalView.onMouseDown = onMouseDown
        nsView.metalView.onMouseDragged = onMouseDragged
        nsView.metalView.onMouseUp = onMouseUp
        renderer.onGridSizeChange = onTerminalResize
        nsView.onScroll = onScroll
        nsView.shouldRouteWheelToViewport = shouldRouteWheelToViewport
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
}

/// The terminal's Metal view. Reports left-button events in its own coordinate space, then passes
/// them up the responder chain as `MTKView` does, so enclosing SwiftUI tap gestures still see them.
final class TerminalMTKView: MTKView {
    var onMouseDown: ((CGPoint, Int) -> Void)?
    var onMouseDragged: ((CGPoint) -> Void)?
    var onMouseUp: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onMouseDown?(convert(event.locationInWindow, from: nil), event.clickCount)
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        onMouseDragged?(convert(event.locationInWindow, from: nil))
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        onMouseUp?()
        super.mouseUp(with: event)
    }
}

final class TerminalMetalContainerView: NSView {
    let blurView = NSVisualEffectView(frame: .zero)
    let metalView = TerminalMTKView(frame: .zero)
    var onScroll: ((Int) -> Void)?
    var shouldRouteWheelToViewport: ((CGFloat) -> Bool)?
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
        guard shouldRouteWheelToViewport?(event.scrollingDeltaY) ?? true else {
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
