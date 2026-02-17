// ScrollIndicator.swift
// ProSSHV2
//
// Scroll position indicator and jump-to-bottom visibility state.

import Foundation
import SwiftUI
import Combine

@MainActor
final class ScrollIndicatorController: ObservableObject {
    @Published private(set) var thumbOpacity: Double = 0
    @Published private(set) var thumbFraction: CGFloat = 1
    @Published private(set) var thumbOffsetFraction: CGFloat = 0
    @Published private(set) var showJumpToBottom: Bool = false
    @Published private(set) var isNearBottom: Bool = true
    @Published private(set) var shouldShowThumb: Bool = false

    private let hideDelaySeconds: Double = 1.0
    private let nearBottomThreshold: CGFloat = 24
    private var lastOffset: CGFloat = 0
    private var hideTask: Task<Void, Never>?

    deinit {
        hideTask?.cancel()
    }

    func update(contentOffset: CGFloat, contentHeight: CGFloat, viewportHeight: CGFloat) {
        let safeViewport = max(1, viewportHeight)
        let safeContent = max(contentHeight, safeViewport)
        let maxOffset = max(0, safeContent - safeViewport)
        let clampedOffset = min(max(0, contentOffset), maxOffset)

        shouldShowThumb = maxOffset > 1
        isNearBottom = (maxOffset - clampedOffset) <= nearBottomThreshold
        showJumpToBottom = shouldShowThumb && !isNearBottom

        let fraction = min(1, safeViewport / safeContent)
        thumbFraction = max(0.08, fraction)
        let travel = max(0, 1 - thumbFraction)
        thumbOffsetFraction = maxOffset > 0 ? (clampedOffset / maxOffset) * travel : 0

        if abs(clampedOffset - lastOffset) > 0.5 {
            revealTemporarily()
        }
        lastOffset = clampedOffset
    }

    func reset() {
        hideTask?.cancel()
        hideTask = nil
        thumbOpacity = 0
        thumbFraction = 1
        thumbOffsetFraction = 0
        showJumpToBottom = false
        isNearBottom = true
        shouldShowThumb = false
        lastOffset = 0
    }

    private func revealTemporarily() {
        hideTask?.cancel()

        withAnimation(.easeOut(duration: 0.12)) {
            thumbOpacity = shouldShowThumb ? 1 : 0
        }

        hideTask = Task { [weak self] in
            guard let self else { return }
            let nanoseconds = UInt64(hideDelaySeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.22)) {
                thumbOpacity = 0
            }
        }
    }
}
