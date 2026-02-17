// ResizeEffect.swift
// ProSSHV2
//
// Visual-only transition when terminal viewport dimensions change.

import Foundation
import SwiftUI
import Combine

@MainActor
final class ResizeEffectController: ObservableObject {
    @Published private(set) var contentScale: CGFloat = 1
    @Published private(set) var contentOpacity: Double = 1

    private let minimumDimensionDelta: CGFloat = 6
    private let compressedScale: CGFloat = 0.985
    private let compressedOpacity: Double = 0.9
    private let contractDurationSeconds: Double = 0.08
    private let restoreDurationSeconds: Double = 0.16

    private var restoreTask: Task<Void, Never>?

    deinit {
        restoreTask?.cancel()
    }

    func handleViewportChange(from oldSize: CGSize, to newSize: CGSize) {
        guard oldSize.width > 0, oldSize.height > 0 else { return }
        let widthDelta = abs(newSize.width - oldSize.width)
        let heightDelta = abs(newSize.height - oldSize.height)
        guard max(widthDelta, heightDelta) >= minimumDimensionDelta else { return }
        trigger()
    }

    func reset() {
        restoreTask?.cancel()
        restoreTask = nil
        contentScale = 1
        contentOpacity = 1
    }

    private func trigger() {
        restoreTask?.cancel()

        withAnimation(.easeOut(duration: contractDurationSeconds)) {
            contentScale = compressedScale
            contentOpacity = compressedOpacity
        }

        restoreTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let nanoseconds = UInt64(contractDurationSeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: restoreDurationSeconds)) {
                contentScale = 1
                contentOpacity = 1
            }
        }
    }
}
