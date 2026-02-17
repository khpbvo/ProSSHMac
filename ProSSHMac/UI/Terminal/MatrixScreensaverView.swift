// MatrixScreensaverView.swift
// ProSSHV2
//
// Matrix-style falling character screensaver overlay.
// Renders cascading green glyphs at 60fps using SwiftUI Canvas.
// Dismisses on any user interaction.

import SwiftUI
import AppKit

struct MatrixScreensaverView: View {
    let config: MatrixScreensaverConfiguration
    var onDismiss: () -> Void

    @State private var streams: [MatrixStream] = []
    @State private var isInitialized = false
    @State private var eventMonitor: Any?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            Canvas { context, size in
                // Black background
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .color(.black)
                )

                let elapsed = timeline.date.timeIntervalSinceReferenceDate
                let columns = Int(size.width / MatrixStream.cellWidth)
                let rows = Int(size.height / MatrixStream.cellHeight)

                if !isInitialized || streams.count != activeColumnCount(for: columns) {
                    DispatchQueue.main.async {
                        initializeStreams(columns: columns, rows: rows)
                    }
                    return
                }

                for stream in streams {
                    drawStream(stream, context: &context, size: size, elapsed: elapsed, rows: rows)
                }
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { onDismiss() }
        .onKeyPress { _ in
            onDismiss()
            return .handled
        }
        .focusable()
        .focusEffectDisabled()
        .onAppear {
            installEventMonitor()
        }
        .onDisappear {
            removeEventMonitor()
        }
    }

    // MARK: - Event Monitor

    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        let dismiss = onDismiss
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .scrollWheel, .leftMouseDown, .rightMouseDown]
        ) { event in
            dismiss()
            return event
        }
    }

    private func removeEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    // MARK: - Stream Initialization

    private func activeColumnCount(for columns: Int) -> Int {
        max(1, Int(Float(columns) * config.density))
    }

    private func initializeStreams(columns: Int, rows: Int) {
        let activeColumns = activeColumnCount(for: columns)
        let allColumns = Array(0..<columns).shuffled()
        let selectedColumns = Array(allColumns.prefix(activeColumns))
        let chars = config.characterSet.characters

        streams = selectedColumns.map { column in
            MatrixStream(
                column: column,
                rows: rows,
                speed: config.speed,
                trailLength: config.trailLength,
                characters: chars
            )
        }
        isInitialized = true
    }

    // MARK: - Drawing

    private func drawStream(
        _ stream: MatrixStream,
        context: inout GraphicsContext,
        size: CGSize,
        elapsed: TimeInterval,
        rows: Int
    ) {
        let headPosition = stream.headRow(at: elapsed)
        let trailLen = stream.trailLength

        for offset in 0..<trailLen {
            let row = headPosition - offset
            guard row >= 0, row < rows else { continue }

            let charIndex = (stream.column &* 31 &+ row &* 17 &+ Int(elapsed * 3)) % stream.characters.count
            let char = stream.characters[abs(charIndex) % stream.characters.count]

            let fade: Double
            if offset == 0 {
                fade = 1.0
            } else {
                fade = max(0.05, 1.0 - Double(offset) / Double(trailLen))
            }

            let x = CGFloat(stream.column) * MatrixStream.cellWidth
            let y = CGFloat(row) * MatrixStream.cellHeight

            let charColor: Color
            if offset == 0 {
                // Leading character is bright white-tinted
                charColor = Color(
                    red: Double(config.color.red) * 0.3 + 0.7,
                    green: Double(config.color.green) * 0.3 + 0.7,
                    blue: Double(config.color.blue) * 0.3 + 0.7
                )
            } else {
                charColor = Color(
                    red: Double(config.color.red) * fade,
                    green: Double(config.color.green) * fade,
                    blue: Double(config.color.blue) * fade
                )
            }

            let font = Font.system(size: 14, design: .monospaced).weight(.medium)
            let text = context.resolve(
                Text(String(char))
                    .font(font)
                    .foregroundColor(charColor.opacity(fade))
            )
            context.draw(text, at: CGPoint(x: x + MatrixStream.cellWidth / 2, y: y + MatrixStream.cellHeight / 2), anchor: .center)
        }
    }
}

// MARK: - MatrixStream

/// Represents a single column of falling characters.
struct MatrixStream {
    static let cellWidth: CGFloat = 14
    static let cellHeight: CGFloat = 18

    let column: Int
    let startOffset: Double
    let fallSpeed: Double
    let trailLength: Int
    let characters: [Character]
    let totalRows: Int

    init(column: Int, rows: Int, speed: Float, trailLength: Int, characters: [Character]) {
        self.column = column
        self.totalRows = rows
        self.startOffset = Double.random(in: -Double(rows * 2)...0)
        self.fallSpeed = Double(speed) * Double.random(in: 0.5...1.5) * 12.0
        self.trailLength = trailLength
        self.characters = characters.isEmpty ? Array("0") : characters
    }

    func headRow(at elapsed: TimeInterval) -> Int {
        let position = startOffset + elapsed * fallSpeed
        let cycleLength = Double(totalRows + trailLength)
        let wrapped = position.truncatingRemainder(dividingBy: cycleLength)
        let normalized = wrapped < 0 ? wrapped + cycleLength : wrapped
        return Int(normalized)
    }
}
