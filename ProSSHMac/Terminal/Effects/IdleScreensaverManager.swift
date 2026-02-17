// IdleScreensaverManager.swift
// ProSSHV2
//
// Monitors user activity and activates the Matrix screensaver
// after the configured idle timeout. Listens for key presses,
// mouse movement, and clicks to reset the idle timer.

import Foundation
import AppKit
import Combine

@MainActor
final class IdleScreensaverManager: ObservableObject {

    /// Whether the screensaver is currently displayed.
    @Published private(set) var isActive = false

    private var idleTimer: Timer?
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    private var configObserver: AnyCancellable?

    /// Current configuration, reloaded from UserDefaults.
    private(set) var config: MatrixScreensaverConfiguration

    init() {
        self.config = MatrixScreensaverConfiguration.load()
        startMonitoring()

        // Observe changes to the screensaver configuration in UserDefaults
        configObserver = NotificationCenter.default.publisher(
            for: UserDefaults.didChangeNotification
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            self?.reloadConfiguration()
        }
    }

    // MARK: - Public

    /// Dismiss the screensaver and restart the idle timer.
    func dismiss() {
        guard isActive else { return }
        isActive = false
        resetIdleTimer()
    }

    /// Force-activate the screensaver (e.g. from a menu action).
    func activate() {
        guard config.isEnabled else { return }
        idleTimer?.invalidate()
        idleTimer = nil
        isActive = true
    }

    // MARK: - Configuration

    private func reloadConfiguration() {
        let newConfig = MatrixScreensaverConfiguration.load()
        let wasEnabled = config.isEnabled
        config = newConfig

        if !newConfig.isEnabled {
            // Screensaver was disabled — dismiss and stop timer
            isActive = false
            idleTimer?.invalidate()
            idleTimer = nil
        } else if !wasEnabled && newConfig.isEnabled {
            // Screensaver was just enabled — start timer
            resetIdleTimer()
        } else if newConfig.isEnabled {
            // Timeout may have changed
            resetIdleTimer()
        }
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        // Global monitor catches events even when the app is not focused
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleUserActivity()
            }
        }

        // Local monitor catches events within the app
        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]
        ) { [weak self] event in
            Task { @MainActor in
                self?.handleUserActivity()
            }
            return event
        }

        if config.isEnabled {
            resetIdleTimer()
        }
    }

    private func stopMonitoring() {
        idleTimer?.invalidate()
        idleTimer = nil

        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
    }

    // MARK: - Idle Timer

    private func handleUserActivity() {
        if isActive {
            dismiss()
        } else {
            resetIdleTimer()
        }
    }

    private func resetIdleTimer() {
        idleTimer?.invalidate()

        guard config.isEnabled else {
            idleTimer = nil
            return
        }

        let timeout = TimeInterval(max(1, config.idleTimeoutMinutes)) * 60.0

        idleTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.activateScreensaver()
            }
        }
    }

    private func activateScreensaver() {
        guard config.isEnabled, !isActive else { return }
        isActive = true
    }
}
