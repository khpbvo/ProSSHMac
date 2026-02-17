// BellEffect.swift
// ProSSHMac
//
// Visual and sound feedback for terminal BEL events.

import Foundation
import SwiftUI
import Combine
#if canImport(AudioToolbox)
import AudioToolbox
#endif

enum BellFeedbackMode: String, CaseIterable, Identifiable, Sendable {
    case none
    case visual
    case haptic
    case sound

    nonisolated var id: String { rawValue }

    var title: String {
        switch self {
        case .none:
            return "None"
        case .visual:
            return "Visual"
        case .haptic:
            return "Haptic"
        case .sound:
            return "Sound"
        }
    }
}

@MainActor
final class BellEffectController: ObservableObject {
    nonisolated static let settingsKey = "terminal.effects.bellMode"

    /// C.3.1: 10% white flash that fades out over 100ms.
    let flashPeakOpacity: Double = 0.10
    let flashFadeDurationSeconds: Double = 0.10

    /// C.3.3: subtle click.
    private let soundID: UInt32 = 1104

    @Published private(set) var flashOpacity: Double = 0

    private var flashTask: Task<Void, Never>?

    deinit {
        flashTask?.cancel()
    }

    func trigger(mode: BellFeedbackMode) {
        switch mode {
        case .none:
            break
        case .visual:
            triggerVisualFlash()
        case .haptic:
            triggerHapticFeedback()
        case .sound:
            triggerSound()
        }
    }

    private func triggerVisualFlash() {
        flashTask?.cancel()
        flashTask = Task { @MainActor [weak self] in
            guard let self else { return }
            flashOpacity = flashPeakOpacity
            withAnimation(.easeOut(duration: flashFadeDurationSeconds)) {
                flashOpacity = 0
            }

            // Keep task alive for the fade duration so repeated rings restart cleanly.
            let ns = UInt64(flashFadeDurationSeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ns)
        }
    }

    private func triggerHapticFeedback() {
        // No haptic feedback on macOS
    }

    private func triggerSound() {
        #if canImport(AudioToolbox)
        AudioServicesPlaySystemSound(SystemSoundID(soundID))
        #endif
    }
}
