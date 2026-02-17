// PaneDividerView.swift
// ProSSHV2
//
// Draggable divider between split panes.

import SwiftUI

struct PaneDividerView: View {
    let containerID: UUID
    let direction: SplitDirection
    let totalLength: CGFloat
    let currentRatio: CGFloat
    let onResize: (UUID, CGFloat) -> Void

    @State private var dragStartRatio: CGFloat?

    private var isVerticalSplit: Bool {
        direction == .vertical
    }

    var body: some View {
        Rectangle()
            .fill(Color.accentColor.opacity(0.6))
            .frame(
                width: isVerticalSplit ? 2 : nil,
                height: isVerticalSplit ? nil : 2
            )
            .padding(isVerticalSplit ? .horizontal : .vertical, -4)
            .contentShape(Rectangle().inset(by: -4))
            .frame(
                width: isVerticalSplit ? 10 : nil,
                height: isVerticalSplit ? nil : 10
            )
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = dragStartRatio ?? currentRatio
                        dragStartRatio = start
                        let translation = isVerticalSplit ? value.translation.width : value.translation.height
                        let ratio = start + (translation / max(totalLength, 1))
                        onResize(containerID, ratio)
                    }
                    .onEnded { _ in
                        dragStartRatio = nil
                    }
            )
            .onTapGesture(count: 2) {
                onResize(containerID, 0.5)
            }
    }
}
