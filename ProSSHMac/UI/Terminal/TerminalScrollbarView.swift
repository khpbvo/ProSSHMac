// TerminalScrollbarView.swift
// ProSSHV2
//
// Auto-hiding scrollbar overlay for the Metal terminal surface.
// Shows scroll position within the scrollback buffer and supports
// drag-to-scroll interaction.

import SwiftUI

struct TerminalScrollbarView: View {
    let sessionID: UUID
    @ObservedObject var sessionManager: SessionManager

    /// Track height for thumb position calculations.
    private let trackInset: CGFloat = 4
    private let thumbWidth: CGFloat = 3
    private let minThumbHeight: CGFloat = 18

    @State private var thumbOpacity: Double = 0
    @State private var hideTask: Task<Void, Never>?
    @State private var isDragging: Bool = false

    private var scrollState: TerminalScrollState {
        sessionManager.scrollStateBySessionID[sessionID] ?? TerminalScrollState()
    }

    private var totalRows: Int {
        scrollState.scrollbackCount + scrollState.visibleRows
    }

    private var shouldShow: Bool {
        scrollState.scrollbackCount > 0
    }

    var body: some View {
        GeometryReader { proxy in
            let trackHeight = proxy.size.height
            let thumbFraction = totalRows > 0
                ? CGFloat(scrollState.visibleRows) / CGFloat(totalRows)
                : 1.0
            let thumbHeight = max(minThumbHeight, trackHeight * min(1, thumbFraction))
            let travel = max(0, trackHeight - thumbHeight)
            // scrollOffset 0 = bottom (live), max = top of scrollback
            // Scrollbar: top of track = top of scrollback, bottom = live
            let offsetFraction = scrollState.scrollbackCount > 0
                ? CGFloat(scrollState.scrollbackCount - scrollState.scrollOffset) / CGFloat(scrollState.scrollbackCount)
                : 1.0
            let thumbY = travel * min(1, max(0, offsetFraction))

            Capsule(style: .continuous)
                .fill(Color.white.opacity(isDragging ? 0.72 : 0.58))
                .frame(width: thumbWidth, height: thumbHeight)
                .offset(y: thumbY)
                .padding(.trailing, trackInset)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .contentShape(Rectangle().inset(by: -8))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDragging = true
                            cancelHide()
                            thumbOpacity = 1
                            let fraction = value.location.y / max(1, trackHeight)
                            let clampedFraction = min(1, max(0, fraction))
                            // Convert: fraction 0 = top of scrollback, 1 = bottom (live)
                            let targetRow = Int(CGFloat(scrollState.scrollbackCount) * (1.0 - clampedFraction))
                            sessionManager.scrollToRow(sessionID: sessionID, row: targetRow)
                        }
                        .onEnded { _ in
                            isDragging = false
                            scheduleHide()
                        }
                )
                .opacity(thumbOpacity)
                .animation(.easeOut(duration: 0.16), value: thumbOpacity)
                .animation(.easeOut(duration: 0.1), value: isDragging)
        }
        .allowsHitTesting(shouldShow)
        .onChange(of: scrollState) { _, _ in
            guard shouldShow else {
                thumbOpacity = 0
                return
            }
            revealTemporarily()
        }
    }

    private func revealTemporarily() {
        cancelHide()
        thumbOpacity = 1
        if !isDragging {
            scheduleHide()
        }
    }

    private func cancelHide() {
        hideTask?.cancel()
        hideTask = nil
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.0))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.22)) {
                thumbOpacity = 0
            }
        }
    }
}
