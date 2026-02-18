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
    @State private var isHovered = false

    private var isVerticalSplit: Bool {
        direction == .vertical
    }

    var body: some View {
        ZStack {
            // Core divider bar
            Rectangle()
                .fill(Color.accentColor.opacity(isHovered ? 0.9 : 0.6))
                .frame(
                    width: isVerticalSplit ? 3 : nil,
                    height: isVerticalSplit ? nil : 3
                )

            // Grip dots
            gripDots
                .opacity(isHovered ? 0.9 : 0.4)
        }
        .padding(isVerticalSplit ? .horizontal : .vertical, -4)
        .contentShape(Rectangle().inset(by: -4))
        .frame(
            width: isVerticalSplit ? 10 : nil,
            height: isVerticalSplit ? nil : 10
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
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

    @ViewBuilder
    private var gripDots: some View {
        let dotSize: CGFloat = 3
        let dotSpacing: CGFloat = 4
        if isVerticalSplit {
            VStack(spacing: dotSpacing) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: dotSize, height: dotSize)
                }
            }
        } else {
            HStack(spacing: dotSpacing) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: dotSize, height: dotSize)
                }
            }
        }
    }
}
