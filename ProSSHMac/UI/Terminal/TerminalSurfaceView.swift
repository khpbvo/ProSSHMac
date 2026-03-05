// Extracted from TerminalView.swift
import SwiftUI
import Metal
import UniformTypeIdentifiers

struct TerminalSurfaceView: View {
    let session: Session
    let isFocused: Bool
    let paneID: UUID?

    @ObservedObject var bellEffect: BellEffectController
    @ObservedObject var resizeEffect: ResizeEffectController
    @ObservedObject var selectionCoordinator: TerminalSelectionCoordinator
    @ObservedObject var terminalSearch: TerminalSearch
    @ObservedObject var paneManager: PaneManager
    @ObservedObject var tabManager: SessionTabManager

    @EnvironmentObject private var sessionManager: SessionManager
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow

    @AppStorage(BellEffectController.settingsKey) private var bellFeedbackModeRawValue = BellFeedbackMode.none.rawValue
    @AppStorage(TransparencyManager.backgroundOpacityKey) private var terminalBackgroundOpacityPercent = TransparencyManager.defaultBackgroundOpacityPercent
    @AppStorage("terminal.ui.fontSize") private var terminalUIFontSize = 12.0
    @AppStorage("terminal.ui.fontFamily") private var terminalUIFontFamily = FontManager.platformDefaultFontFamily
    @AppStorage("terminal.renderer.useMetal") private var useMetalRenderer = true

    var onFocusTap: () -> Void
    var onPaste: (UUID) -> Void
    var onCopy: (UUID) -> Bool
    var onSplitWithExisting: (UUID, UUID, SplitDirection) -> Void

    // Moved from TerminalView — only used inside terminalBuffer
    @StateObject private var scrollIndicator = ScrollIndicatorController()
    @State private var terminalContentHeight: CGFloat = 0
    @State private var terminalContentOffset: CGFloat = 0
    @State private var terminalViewportSize: CGSize = .zero

    private let linkDetector = LinkDetector()

    var body: some View {
        Group {
            if isMacOSTerminalSafetyModeEnabled {
                safeTerminalBuffer(for: session)
            } else if supportsMetalTerminalSurface {
                metalTerminalBuffer(for: session, isFocused: isFocused, paneID: paneID)
            } else {
                terminalBuffer(for: session)
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded { onFocusTap() }
        )
    }

    // MARK: - Private helpers

    private func sendControl(_ sequence: String, sessionID: UUID) {
        Task {
            await sessionManager.sendRawShellInput(sessionID: sessionID, input: sequence)
        }
    }

    private var bellFeedbackMode: BellFeedbackMode {
        BellFeedbackMode(rawValue: bellFeedbackModeRawValue) ?? .none
    }

    private var isMetalRendererAvailable: Bool {
        MTLCreateSystemDefaultDevice() != nil
    }

    private var supportsMetalTerminalSurface: Bool {
        useMetalRenderer && isMetalRendererAvailable
    }

    private var isMacOSTerminalSafetyModeEnabled: Bool { false }

    private func inputModeSnapshot(for sessionID: UUID) -> InputModeSnapshot {
        sessionManager.inputModeSnapshotsBySessionID[sessionID] ?? .default
    }

    private var terminalSurfaceColor: Color {
        let opacityMultiplier = TransparencyManager.normalizedOpacity(fromPercent: terminalBackgroundOpacityPercent)
        let baseOpacity = colorScheme == .dark ? 0.34 : 0.08
        return Color.black.opacity(baseOpacity * opacityMultiplier)
    }

    private var terminalSurfaceBorderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.12)
    }

    // MARK: - Safe terminal buffer (dead code: isMacOSTerminalSafetyModeEnabled = false)

    @ViewBuilder
    private func safeTerminalBuffer(for session: Session) -> some View {
        let renderedLines = safeTerminalDisplayLines(for: session)
        let scrollSpaceName = "terminal-scroll-safe-\(session.id.uuidString)"

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(renderedLines) { line in
                        Text(verbatim: line.text)
                            .font(.custom(terminalUIFontFamily, size: terminalUIFontSize))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(8)
            }
            .coordinateSpace(name: scrollSpaceName)
            .onAppear {
                guard let last = renderedLines.indices.last else { return }
                proxy.scrollTo(last, anchor: .bottom)
            }
            .onChange(of: renderedLines.count) { _, _ in
                guard let last = renderedLines.indices.last else { return }
                proxy.scrollTo(last, anchor: .bottom)
            }
        }
        .frame(minHeight: 220, maxHeight: .infinity)
        .background(terminalSurfaceColor, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(terminalSurfaceBorderColor, lineWidth: 1)
        )
    }

    private func safeTerminalDisplayLines(for session: Session) -> [SafeTerminalRenderedLine] {
        // stubs: directInputBufferBySessionID / shouldUseSecureInput / shouldEnableDirectTerminalInput
        // live in TerminalView; this entire function is unreachable (isMacOSTerminalSafetyModeEnabled = false)
        let lines = sessionManager.shellBuffers[session.id] ?? []

        return lines.enumerated().map { index, line in
            let stableID = "\(index)-\(line.hashValue)"
            return SafeTerminalRenderedLine(id: stableID, lineNumber: index, text: line)
        }
    }

    // MARK: - Metal terminal buffer

    @ViewBuilder
    private func metalTerminalBuffer(for session: Session, isFocused: Bool = true, paneID: UUID? = nil) -> some View {
        let snapshotNonce = sessionManager.gridSnapshotNonceBySessionID[session.id, default: 0]

        MetalTerminalSessionSurface(
            sessionID: session.id,
            snapshotProvider: { sessionManager.gridSnapshot(for: session.id) },
            snapshotNonce: snapshotNonce,
            fontSize: terminalUIFontSize,
            fontFamily: terminalUIFontFamily,
            backgroundOpacityPercent: terminalBackgroundOpacityPercent,
            onTap: { _ in
                selectionCoordinator.clearSelection(sessionID: session.id)
                onFocusTap()
            },
            onTerminalResize: { columns, rows in
                Task {
                    await sessionManager.resizeTerminal(
                        sessionID: session.id,
                        columns: columns,
                        rows: rows
                    )
                }
            },
            onScroll: { delta in
                sessionManager.scrollTerminal(sessionID: session.id, delta: delta)
            },
            isFocused: isFocused,
            isLocalSession: session.isLocal,
            selectionCoordinator: selectionCoordinator,
            scrollbackCountProvider: {
                sessionManager.cachedScrollbackCount(for: session.id)
            }
        )
        .id(session.id)
        .frame(minHeight: 220, maxHeight: .infinity)
        .scaleEffect(resizeEffect.contentScale)
        .opacity(resizeEffect.contentOpacity)
        .background(terminalSurfaceColor, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(terminalSurfaceBorderColor, lineWidth: 1)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(bellEffect.flashOpacity))
                .allowsHitTesting(false)
        }
        .overlay(alignment: .trailing) {
            TerminalScrollbarView(
                sessionID: session.id,
                sessionManager: sessionManager
            )
        }
        .overlay {
            mouseInputOverlay(for: session, contentPadding: 0)
        }
        .contextMenu {
            terminalSurfaceContextMenu(for: session)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    let escaped = url.path.replacingOccurrences(of: "'", with: "'\\''")
                    let escapedPath = "'\(escaped)'"
                    Task { @MainActor in
                        await sessionManager.sendShellInput(sessionID: session.id, input: escapedPath)
                    }
                }
            }
            return true
        }
        .onChange(of: sessionManager.bellEventNonceBySessionID[session.id, default: 0]) { _, _ in
            bellEffect.trigger(mode: bellFeedbackMode)
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private func terminalSurfaceContextMenu(for session: Session) -> some View {
        Button {
            _ = onCopy(session.id)
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }

        Button {
            onPaste(session.id)
        } label: {
            Label("Paste", systemImage: "doc.on.clipboard")
        }

        Button {
            openWindow(id: ProSSHMacApp.externalTerminalWindowID, value: session.id)
        } label: {
            Label("Pop Out to Window", systemImage: "rectangle.portrait.and.arrow.right")
        }

        Divider()

        Button {
            selectionCoordinator.selectAll(sessionID: session.id)
        } label: {
            Label("Select All", systemImage: "selection.pin.in.out")
        }

        if selectionCoordinator.hasSelection(sessionID: session.id) {
            Button {
                selectionCoordinator.clearSelection(sessionID: session.id)
            } label: {
                Label("Clear Selection", systemImage: "xmark.rectangle")
            }
        }

        let currentPaneID = paneManager.allPanes.first(where: { $0.sessionID == session.id })?.id
            ?? paneManager.focusedPaneId
        let otherSessions = tabManager.tabs
            .map(\.session)
            .filter { $0.id != session.id }

        if paneManager.canSplit(currentPaneID) && !otherSessions.isEmpty {
            Divider()

            Menu {
                ForEach(otherSessions, id: \.id) { other in
                    Button(other.hostLabel) {
                        onSplitWithExisting(other.id, currentPaneID, .vertical)
                    }
                }
            } label: {
                Label("Split Right With...", systemImage: "rectangle.split.2x1")
            }

            Menu {
                ForEach(otherSessions, id: \.id) { other in
                    Button(other.hostLabel) {
                        onSplitWithExisting(other.id, currentPaneID, .horizontal)
                    }
                }
            } label: {
                Label("Split Down With...", systemImage: "rectangle.split.1x2")
            }
        }
    }

    // MARK: - Classic SwiftUI terminal buffer

    @ViewBuilder
    private func terminalBuffer(for session: Session) -> some View {
        let lines = sessionManager.shellBuffers[session.id] ?? []
        let scrollSpaceName = "terminal-scroll-\(session.id.uuidString)"

        ScrollViewReader { proxy in
            GeometryReader { viewportProxy in
                ScrollView {
                    GeometryReader { offsetProxy in
                        Color.clear.preference(
                            key: TerminalScrollOffsetPreferenceKey.self,
                            value: -offsetProxy.frame(in: .named(scrollSpaceName)).minY
                        )
                    }
                    .frame(height: 0)

                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            terminalLineView(line, lineIndex: index)
                                .id("\(index)-\(line.hashValue)")
                        }
                    }
                    .padding(8)
                    .background(
                        GeometryReader { contentProxy in
                            Color.clear.preference(
                                key: TerminalScrollContentHeightPreferenceKey.self,
                                value: contentProxy.size.height
                            )
                        }
                    )
                }
                .coordinateSpace(name: scrollSpaceName)
                .onAppear {
                    terminalViewportSize = viewportProxy.size
                    terminalSearch.updateLines(lines)
                    scrollIndicator.update(
                        contentOffset: terminalContentOffset,
                        contentHeight: terminalContentHeight,
                        viewportHeight: terminalViewportSize.height
                    )
                    guard lines.count > 0 else { return }
                    proxy.scrollTo(lines.count - 1, anchor: .bottom)
                }
                .onChange(of: viewportProxy.size) { oldSize, newSize in
                    terminalViewportSize = newSize
                    resizeEffect.handleViewportChange(from: oldSize, to: newSize)
                    scrollIndicator.update(
                        contentOffset: terminalContentOffset,
                        contentHeight: terminalContentHeight,
                        viewportHeight: terminalViewportSize.height
                    )
                }
                .onPreferenceChange(TerminalScrollOffsetPreferenceKey.self) { offset in
                    terminalContentOffset = max(0, offset)
                    scrollIndicator.update(
                        contentOffset: terminalContentOffset,
                        contentHeight: terminalContentHeight,
                        viewportHeight: terminalViewportSize.height
                    )
                }
                .onPreferenceChange(TerminalScrollContentHeightPreferenceKey.self) { contentHeight in
                    terminalContentHeight = contentHeight
                    scrollIndicator.update(
                        contentOffset: terminalContentOffset,
                        contentHeight: terminalContentHeight,
                        viewportHeight: terminalViewportSize.height
                    )
                }
                .onChange(of: lines) { _, newLines in
                    terminalSearch.updateLines(newLines)
                    guard !newLines.isEmpty else { return }
                    guard scrollIndicator.isNearBottom else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(newLines.count - 1, anchor: .bottom)
                    }
                }
                .onChange(of: terminalSearch.selectedMatch) { _, selectedMatch in
                    guard let selectedMatch, selectedMatch.lineIndex < lines.count else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(selectedMatch.lineIndex, anchor: .center)
                    }
                }
                .overlay(alignment: .trailing) {
                    if scrollIndicator.shouldShowThumb {
                        GeometryReader { indicatorProxy in
                            let trackHeight = indicatorProxy.size.height
                            let thumbHeight = max(18, trackHeight * scrollIndicator.thumbFraction)
                            let travel = max(0, trackHeight - thumbHeight)
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity(colorScheme == .dark ? 0.58 : 0.42))
                                .frame(width: 3, height: thumbHeight)
                                .offset(y: travel * scrollIndicator.thumbOffsetFraction)
                                .padding(.trailing, 4)
                                .opacity(scrollIndicator.thumbOpacity)
                                .animation(.easeOut(duration: 0.16), value: scrollIndicator.thumbOpacity)
                        }
                        .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .bottom) {
                    if scrollIndicator.showJumpToBottom, !lines.isEmpty {
                        VStack(spacing: 6) {
                            if !scrollIndicator.isNearBottom {
                                Text("\u{2193} New output below")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(.ultraThinMaterial, in: Capsule())
                            }

                            Button {
                                withAnimation(.easeOut(duration: 0.16)) {
                                    proxy.scrollTo(lines.count - 1, anchor: .bottom)
                                }
                            } label: {
                                Label("Jump to Bottom", systemImage: "arrow.down.to.line")
                                    .labelStyle(.titleAndIcon)
                                    .font(.caption2.weight(.semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                        .padding(.bottom, 8)
                    }
                }
            }
            .frame(minHeight: 220, maxHeight: .infinity)
            .scaleEffect(resizeEffect.contentScale)
            .opacity(resizeEffect.contentOpacity)
            .background(terminalSurfaceColor, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(terminalSurfaceBorderColor, lineWidth: 1)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(bellEffect.flashOpacity))
                    .allowsHitTesting(false)
            }
            .overlay {
                mouseInputOverlay(for: session)
            }
            .onChange(of: sessionManager.bellEventNonceBySessionID[session.id, default: 0]) { _, _ in
                bellEffect.trigger(mode: bellFeedbackMode)
            }
        }
    }

    // MARK: - Terminal line view

    @ViewBuilder
    private func terminalLineView(_ line: String, lineIndex: Int) -> some View {
        let detectedLinks = linkDetector.detectLinks(in: line)
        let attributed = attributedTerminalLine(line, lineIndex: lineIndex)

        let base = Text(attributed)
            .font(.system(size: terminalUIFontSize, weight: .regular, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .environment(
                \.openURL,
                OpenURLAction { url in
                    PlatformURL.openInBrowser(url)
                    return .handled
                }
            )

        if detectedLinks.isEmpty {
            base
        } else {
            base
                .help(detectedLinks.map(\.previewLabel).joined(separator: "\n"))
                .contextMenu {
                    Text(detectedLinks.first?.previewLabel ?? "Detected Link")
                    Divider()
                    ForEach(detectedLinks) { link in
                        Button("Open \(link.text) in Browser") {
                            PlatformURL.openInBrowser(link.destinationURL)
                        }
                    }
                    Divider()
                    ForEach(detectedLinks) { link in
                        Button("Copy \(link.text)") {
                            PlatformClipboard.writeString(link.text)
                        }
                    }
                }
        }
    }

    // MARK: - Mouse overlay

    @ViewBuilder
    private func mouseInputOverlay(for session: Session, contentPadding: CGFloat = 8) -> some View {
        let isEnabled = session.state == .connected && isMouseTrackingEnabled(for: session.id)

        MouseInputHandler(
            isEnabled: isEnabled,
            modeSnapshot: {
                inputModeSnapshot(for: session.id)
            },
            locationToCell: { location in
                terminalCellCoordinates(from: location, contentPadding: contentPadding)
            },
            onSendSequence: { sequence in
                sendControl(sequence, sessionID: session.id)
            }
        )
        .opacity(0.001)
        .accessibilityHidden(true)
        .allowsHitTesting(isEnabled)
    }

    // MARK: - Attributed line / search highlighting

    private func attributedTerminalLine(_ line: String, lineIndex: Int) -> AttributedString {
        var attributed = linkDetector.attributedLine(line)
        guard terminalSearch.isPresented else { return attributed }

        let lineMatches = terminalSearch.matches(forLineIndex: lineIndex)
        guard !lineMatches.isEmpty else { return attributed }

        for match in lineMatches {
            guard let lineRange = match.stringRange(in: line),
                  let attributedRange = Range(lineRange, in: attributed) else {
                continue
            }

            if terminalSearch.isSelected(match) {
                attributed[attributedRange].backgroundColor = .orange.opacity(0.6)
                attributed[attributedRange].foregroundColor = colorScheme == .dark ? .black : .primary
            } else {
                attributed[attributedRange].backgroundColor = .yellow.opacity(0.35)
            }
        }

        return attributed
    }

    // MARK: - Cell coordinate helper

    private func isMouseTrackingEnabled(for sessionID: UUID) -> Bool {
        inputModeSnapshot(for: sessionID).mouseTracking != .none
    }

    private func terminalCellCoordinates(from location: CGPoint, contentPadding: CGFloat = 8) -> (row: Int, col: Int)? {
        let fontSize = CGFloat(terminalUIFontSize)
        let estimatedCellWidth = max(1, fontSize * 0.62)
        let estimatedLineHeight = max(1, fontSize * 1.35 + 2)

        let x = max(0, location.x - contentPadding)
        let y = max(0, location.y - contentPadding)
        let row = Int(y / estimatedLineHeight) + 1
        let col = Int(x / estimatedCellWidth) + 1
        return (row: max(1, row), col: max(1, col))
    }
}
