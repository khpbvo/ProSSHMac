// TerminalSurfaceIdentityTests.swift
// ProSSHMac
//
// The terminal surface owns the session's Metal renderer (selection, smooth-scroll and cursor
// state, glyph atlas). Layout changes that keep the session on screen must reuse it rather than
// make SwiftUI build a new surface. See Docs/bugs.md Bug 82.

#if canImport(XCTest)
import XCTest
import SwiftUI
import AppKit
@testable import ProSSHMac

final class TerminalSurfaceIdentityTests: XCTestCase {

    @MainActor
    func testMaximizeTerminalKeepsTheSameRenderer() async throws {
        let suiteName = "TerminalSurfaceIdentityTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let sessionManager = SessionManager(
            transport: MockSSHTransport(),
            knownHostsStore: TrustingKnownHostsStore()
        )
        await sessionManager.injectScreenshotSessions()
        let navigationCoordinator = AppNavigationCoordinator()

        let rootView = TerminalView()
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
        defer { window.close() }
        window.contentView = NSHostingView(rootView: rootView)

        // Strong references, so a freed renderer's address cannot be reused by its replacement.
        let original = try await waitForRenderer(in: window)

        navigationCoordinator.isTerminalMaximized = true
        try await settle(window)
        let maximized = try await waitForRenderer(in: window)
        XCTAssertTrue(maximized === original, "Maximizing the terminal rebuilt its surface and renderer")

        navigationCoordinator.isTerminalMaximized = false
        try await settle(window)
        let restored = try await waitForRenderer(in: window)
        XCTAssertTrue(restored === original, "Restoring the sidebar rebuilt the terminal surface and renderer")
    }

    // MARK: - Helpers

    @MainActor
    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<10 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @MainActor
    private func waitForRenderer(
        in window: NSWindow,
        timeout: TimeInterval = 5
    ) async throws -> MetalTerminalRenderer {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            let renderers = metalContainers(in: window.contentView).compactMap(\.renderer)
            if renderers.count == 1 {
                return renderers[0]
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let found = metalContainers(in: window.contentView).count
        XCTFail("Expected exactly one terminal surface in the window, found \(found)")
        throw CancellationError()
    }

    @MainActor
    private func metalContainers(in view: NSView?) -> [TerminalMetalContainerView] {
        guard let view else { return [] }
        if let container = view as? TerminalMetalContainerView {
            return [container]
        }
        return view.subviews.flatMap { metalContainers(in: $0) }
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
