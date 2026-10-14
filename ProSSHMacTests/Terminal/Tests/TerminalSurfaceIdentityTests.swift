// TerminalSurfaceIdentityTests.swift
// ProSSHMac
//
// The terminal surface model owns the session's Metal renderer (selection, smooth-scroll and
// cursor state, glyph atlas). Layout changes that keep a session on screen must reuse it rather
// than build a new one. See Docs/bugs.md Bugs 82 and 84, and Docs/Bug84.md.

#if canImport(XCTest)
import XCTest
import SwiftUI
import AppKit
@testable import ProSSHMac

final class TerminalSurfaceIdentityTests: XCTestCase {

    @MainActor
    func testMaximizeTerminalKeepsTheSameRenderer() async throws {
        let harness = try await SurfaceHarness.make()
        defer { harness.close() }

        // Strong references, so a freed renderer's address cannot be reused by its replacement.
        let original = try await harness.renderers(count: 1)[0]

        harness.navigationCoordinator.isTerminalMaximized = true
        try await harness.settle()
        let maximized = try await harness.renderers(count: 1)[0]
        XCTAssertTrue(maximized === original, "Maximizing the terminal rebuilt its surface and renderer")

        harness.navigationCoordinator.isTerminalMaximized = false
        try await harness.settle()
        let restored = try await harness.renderers(count: 1)[0]
        XCTAssertTrue(restored === original, "Restoring the sidebar rebuilt the terminal surface and renderer")
    }

    @MainActor
    func testTabSwitchKeepsEachSessionsRenderer() async throws {
        let harness = try await SurfaceHarness.make()
        defer { harness.close() }
        let (a, b) = (harness.sessionIDs[0], harness.sessionIDs[1])

        try await harness.select(a)
        let a0 = try await harness.renderers(count: 1)[0]
        try await harness.select(b)
        let b0 = try await harness.renderers(count: 1)[0]
        XCTAssertFalse(b0 === a0, "Each session needs its own renderer")

        try await harness.select(a)
        let a1 = try await harness.renderers(count: 1)[0]
        XCTAssertTrue(a1 === a0, "Switching back to a tab rebuilt its renderer")

        try await harness.select(b)
        let b1 = try await harness.renderers(count: 1)[0]
        XCTAssertTrue(b1 === b0, "Switching back to a tab rebuilt its renderer")
    }

    @MainActor
    func testSplitUnsplitAndMoveToNewTabKeepTheRenderers() async throws {
        let harness = try await SurfaceHarness.make()
        defer { harness.close() }
        let (a, b) = (harness.sessionIDs[0], harness.sessionIDs[1])

        try await harness.select(a)
        let a0 = try await harness.renderers(count: 1)[0]

        let paneB = try await harness.split(with: b)
        let split = try await harness.renderers(count: 2)
        XCTAssertTrue(split.contains { $0 === a0 }, "Splitting rebuilt the existing session's renderer")
        let b0 = try XCTUnwrap(split.first { $0 !== a0 })

        harness.paneManager.closePane(paneB)
        try await harness.settle()
        let unsplit = try await harness.renderers(count: 1)[0]
        XCTAssertTrue(unsplit === a0, "Unsplitting rebuilt the remaining session's renderer")

        // Split again, then move B's pane to its own tab (TerminalView.moveToNewTab). Closing the
        // pane moves focus to A's pane, and TerminalView's focus handler then selects A, so B is
        // selected only once that has settled. This test is about renderers, not that race.
        let paneB2 = try await harness.split(with: b)
        let resplit = try await harness.renderers(count: 2)
        XCTAssertTrue(resplit.contains { $0 === b0 }, "Splitting with B again rebuilt B's renderer")
        harness.paneManager.closePane(paneB2)
        try await harness.settle()
        try await harness.select(b)
        let moved = try await harness.renderers(count: 1)[0]
        XCTAssertTrue(moved === b0, "Moving a pane to a new tab rebuilt its renderer")
    }

    @MainActor
    func testPaneMaximizeAndRestoreKeepTheRenderers() async throws {
        let harness = try await SurfaceHarness.make()
        defer { harness.close() }
        let (a, b) = (harness.sessionIDs[0], harness.sessionIDs[1])

        try await harness.select(a)
        let paneA = harness.paneManager.focusedPaneId
        _ = try await harness.split(with: b)
        let before = try await harness.renderers(count: 2)

        harness.paneManager.maximizePane(paneA)
        try await harness.settle()
        let maximized = try await harness.renderers(count: 1)[0]
        XCTAssertTrue(before.contains { $0 === maximized }, "Maximizing a pane rebuilt its renderer")

        harness.paneManager.restoreMaximize()
        try await harness.settle()
        let restored = try await harness.renderers(count: 2)
        for renderer in before {
            XCTAssertTrue(restored.contains { $0 === renderer }, "Restoring a maximized pane rebuilt a renderer")
        }
    }

    @MainActor
    func testHiddenRendererReleasesOffscreenTexturesAndRecreatesThem() async throws {
        let harness = try await SurfaceHarness.make()
        defer { harness.close() }
        let (a, b) = (harness.sessionIDs[0], harness.sessionIDs[1])

        try await harness.select(a)
        let a0 = try await harness.renderers(count: 1)[0]
        try await harness.waitUntil("A draws once") { a0.postProcessTexture != nil }
        XCTAssertNotNil(a0.previousFrameTexture)

        try await harness.select(b)
        _ = try await harness.renderers(count: 1)
        XCTAssertNil(a0.postProcessTexture, "A hidden renderer must release its post-process texture")
        XCTAssertNil(a0.previousFrameTexture, "A hidden renderer must release its CRT frame texture")
        XCTAssertNil(a0.bloomBrightTexture)
        XCTAssertNil(a0.bloomBlurH)
        XCTAssertNil(a0.bloomBlurV)
        XCTAssertFalse(a0.hasCapturedPreviousFrame)
        XCTAssertGreaterThan(a0.glyphAtlas.pageCount, 0, "A hidden renderer must keep its glyph atlas")

        try await harness.select(a)
        let a1 = try await harness.renderers(count: 1)[0]
        XCTAssertTrue(a1 === a0)
        try await harness.waitUntil("A recreates its textures when shown again") {
            a0.postProcessTexture != nil && a0.previousFrameTexture != nil
        }
    }

    /// Guard: the store must not keep a closed session's renderer alive.
    @MainActor
    func testClosedSessionsRendererIsReleased() async throws {
        let harness = try await SurfaceHarness.make()
        defer { harness.close() }
        let (a, b) = (harness.sessionIDs[0], harness.sessionIDs[1])

        try await harness.select(a)
        weak var closedRenderer: MetalTerminalRenderer?
        do {
            closedRenderer = try await harness.renderers(count: 1, retain: false)[0]
        }
        try await harness.select(b)
        await harness.sessionManager.closeSession(sessionID: a)
        try await harness.settle()

        try await harness.waitUntil("A's renderer is freed", timeout: 2) { closedRenderer == nil }
    }

    /// Guard: one renderer can only drive one view, so a session shown in two panes needs two.
    @MainActor
    func testSameSessionInTwoPanesGetsTwoRenderers() async throws {
        let harness = try await SurfaceHarness.make()
        defer { harness.close() }
        let a = harness.sessionIDs[0]

        try await harness.select(a)
        _ = try await harness.split(with: a)
        let renderers = try await harness.renderers(count: 2)
        XCTAssertFalse(renderers[0] === renderers[1], "Two panes showing one session shared a renderer")
    }
}

// MARK: - Pop-out window

extension TerminalSurfaceIdentityTests {

    /// A pop-out has its own store, so it builds its own renderer and leaves the main window's
    /// alone (Bug 84 Phase 4).
    @MainActor
    func testPopOutGetsItsOwnRendererAndTheMainWindowKeepsItsOwn() async throws {
        let harness = try await SurfaceHarness.make()
        defer { harness.close() }
        let a = harness.sessionIDs[0]

        try await harness.select(a)
        let main = try await harness.renderers(count: 1)[0]
        let popOut = try await harness.popOut(a)
        let popped = try await harness.renderers(count: 1, in: popOut)[0]

        XCTAssertFalse(popped === main, "The pop-out must not drive the main window's renderer")
        let mainAfter = try await harness.renderers(count: 1)[0]
        XCTAssertTrue(mainAfter === main, "Popping out rebuilt the main window's renderer")
    }

    /// Guard: closing the pop-out frees its renderer, and only its renderer.
    @MainActor
    func testClosingPopOutFreesOnlyItsRenderer() async throws {
        let harness = try await SurfaceHarness.make()
        defer { harness.close() }
        let a = harness.sessionIDs[0]

        try await harness.select(a)
        let main = try await harness.renderers(count: 1)[0]
        let popOut = try await harness.popOut(a)
        weak var popped: MetalTerminalRenderer?
        do {
            popped = try await harness.renderers(count: 1, in: popOut, retain: false)[0]
        }

        harness.closePopOut(popOut)
        try await harness.settle()

        try await harness.waitUntil("the pop-out's renderer is freed", timeout: 2) { popped == nil }
        let mainAfter = try await harness.renderers(count: 1)[0]
        XCTAssertTrue(mainAfter === main, "Closing the pop-out rebuilt the main window's renderer")
    }

    /// Guard: removing a surface clears the callbacks it gave the renderer, even ones set after
    /// detach. Closing a `WindowGroup` window runs `onDisappear` (detach) and then one more
    /// `updateNSView`, which set the resize callback again; it captured the pop-out's view and so
    /// its store, a store -> renderer -> callback cycle that leaked every closed pop-out's
    /// renderer. A test window cannot produce that extra update, so this sets the callback
    /// directly, as it did.
    @MainActor
    func testRemovingTheSurfaceClearsCallbacksSetAfterDetach() async throws {
        let renderer = try XCTUnwrap(MetalTerminalSurfaceModel().renderer, "Metal is required for this test")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: TerminalMetalView(renderer: renderer))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertNotNil(renderer.configuredMTKView, "The hosted surface must configure the renderer")

        renderer.onGridSizeChange = { _, _ in }
        renderer.smoothScrollEngine.onScrollLineChange = { _ in }
        window.contentView = nil
        let deadline = Date().addingTimeInterval(1)
        while renderer.onGridSizeChange != nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertNil(renderer.onGridSizeChange, "A removed surface must not leave its resize callback on the renderer")
        XCTAssertNil(renderer.smoothScrollEngine.onScrollLineChange, "A removed surface must not leave its scroll callback on the renderer")
    }

    /// Guard: a pop-out left open on a closed session must not keep that session's renderer.
    @MainActor
    func testPopOutReleasesTheRendererWhenItsSessionCloses() async throws {
        let harness = try await SurfaceHarness.make()
        defer { harness.close() }
        let (a, b) = (harness.sessionIDs[0], harness.sessionIDs[1])

        try await harness.select(b)
        let popOut = try await harness.popOut(a)
        weak var popped: MetalTerminalRenderer?
        do {
            popped = try await harness.renderers(count: 1, in: popOut, retain: false)[0]
        }

        await harness.sessionManager.closeSession(sessionID: a)
        try await harness.settle()

        try await harness.waitUntil("the closed session's pop-out renderer is freed", timeout: 2) { popped == nil }
    }
}

// MARK: - Harness

/// Hosts the real `TerminalView` in a window with three screenshot sessions. Tab and pane
/// managers are injected on an isolated defaults suite, so the developer's layout is never read
/// or written.
@MainActor
private final class SurfaceHarness {
    let window: NSWindow
    let sessionManager: SessionManager
    let navigationCoordinator: AppNavigationCoordinator
    let tabManager: SessionTabManager
    let paneManager: PaneManager
    let sessionIDs: [UUID]
    private let suiteName: String
    private var retained: [MetalTerminalRenderer] = []
    private var popOuts: [NSWindow] = []

    private init(
        window: NSWindow,
        sessionManager: SessionManager,
        navigationCoordinator: AppNavigationCoordinator,
        tabManager: SessionTabManager,
        paneManager: PaneManager,
        suiteName: String
    ) {
        self.window = window
        self.sessionManager = sessionManager
        self.navigationCoordinator = navigationCoordinator
        self.tabManager = tabManager
        self.paneManager = paneManager
        self.sessionIDs = sessionManager.sessions.map(\.id)
        self.suiteName = suiteName
    }

    static func make() async throws -> SurfaceHarness {
        let suiteName = "TerminalSurfaceIdentityTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))

        let sessionManager = SessionManager(
            transport: MockSSHTransport(),
            knownHostsStore: TrustingKnownHostsStore()
        )
        await sessionManager.injectScreenshotSessions()
        XCTAssertGreaterThanOrEqual(sessionManager.sessions.count, 2)

        let navigationCoordinator = AppNavigationCoordinator()
        let tabManager = SessionTabManager(defaults: defaults)
        let paneManager = PaneManager(layoutStore: PaneLayoutStore(defaults: defaults))

        let rootView = TerminalView(tabManager: tabManager, paneManager: paneManager)
            .environmentObject(navigationCoordinator)
            .environmentObject(sessionManager)
            .environmentObject(TransferManager())
            .environmentObject(PortForwardingManager(transport: MockSSHTransport()))
            .environmentObject(TerminalAIAssistantViewModel(agentService: StubAgentService()))
            .defaultAppStorage(defaults)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 750),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: rootView)

        let harness = SurfaceHarness(
            window: window,
            sessionManager: sessionManager,
            navigationCoordinator: navigationCoordinator,
            tabManager: tabManager,
            paneManager: paneManager,
            suiteName: suiteName
        )
        try await harness.settle()
        return harness
    }

    func close() {
        popOuts.forEach(closePopOut)
        window.close()
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    func settle() async throws {
        for _ in 0..<10 {
            window.contentView?.layoutSubtreeIfNeeded()
            popOuts.forEach { $0.contentView?.layoutSubtreeIfNeeded() }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Hosts the real `ExternalTerminalWindowView` for `sessionID` in a second window, as
    /// "Pop Out to Window" does.
    func popOut(_ sessionID: UUID) async throws -> NSWindow {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let rootView = ExternalTerminalWindowView(sessionID: sessionID)
            .environmentObject(sessionManager)
            .defaultAppStorage(defaults)
        let popOut = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        popOut.isReleasedWhenClosed = false
        popOut.contentView = NSHostingView(rootView: rootView)
        popOuts.append(popOut)
        try await settle()
        return popOut
    }

    /// Tears the pop-out's view hierarchy down and closes it.
    func closePopOut(_ popOut: NSWindow) {
        popOut.contentView = nil
        popOut.close()
        popOuts.removeAll { $0 === popOut }
    }

    func select(_ sessionID: UUID) async throws {
        tabManager.select(sessionID: sessionID)
        try await settle()
    }

    /// Splits the focused pane and shows `sessionID` in the new pane, as
    /// `TerminalView.splitWithExistingSession` does. Returns the new pane's ID.
    func split(with sessionID: UUID) async throws -> UUID {
        let focused = paneManager.focusedPaneId
        if paneManager.rootNode.findPane(id: focused)?.sessionID == nil, let selected = tabManager.selectedSessionID {
            paneManager.assignSession(selected, to: focused)
        }
        paneManager.splitPane(focused, direction: .vertical)
        let newPane = paneManager.focusedPaneId
        paneManager.assignSession(sessionID, to: newPane)
        try await settle()
        return newPane
    }

    /// The renderers of the terminal surfaces in `searchWindow` (default: the main window), once
    /// there are exactly `count`.
    /// Retained by default, so a freed renderer's address cannot be reused by its replacement.
    func renderers(
        count: Int,
        in searchWindow: NSWindow? = nil,
        retain: Bool = true,
        timeout: TimeInterval = 5
    ) async throws -> [MetalTerminalRenderer] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let searched = searchWindow ?? window
            searched.contentView?.layoutSubtreeIfNeeded()
            let found = containers(in: searched.contentView).compactMap(\.renderer)
            if found.count == count {
                if retain { retained.append(contentsOf: found) }
                return found
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let found = containers(in: (searchWindow ?? window).contentView).count
        XCTFail("Expected \(count) terminal surfaces in the window, found \(found)")
        throw CancellationError()
    }

    func waitUntil(
        _ description: String,
        timeout: TimeInterval = 3,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting until: \(description)")
                return
            }
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func containers(in view: NSView?) -> [TerminalMetalContainerView] {
        guard let view else { return [] }
        if let container = view as? TerminalMetalContainerView {
            return [container]
        }
        return view.subviews.flatMap { containers(in: $0) }
    }
}

@MainActor
private final class TrustingKnownHostsStore: KnownHostsStoreProtocol {
    func allEntries() async throws -> [KnownHostEntry] { [] }

    func evaluate(
        hostname: String,
        port: UInt16,
        hostKeyType: String,
        presentedFingerprint: String
    ) async throws -> KnownHostVerificationResult {
        .trusted
    }

    func trust(challenge: KnownHostVerificationChallenge) async throws {}

    func clearAll() async throws {}
}

@MainActor
private final class StubAgentService: AIAgentServicing {
    var toolDefinitions: [LLMToolDefinition] = []

    nonisolated deinit {}

    func clearConversation(sessionID: UUID) {}

    func generateReply(
        sessionID: UUID,
        prompt: String,
        broadcastSessionIDs: [UUID]?
    ) async throws -> AIAgentReply {
        throw CancellationError()
    }
}
#endif
