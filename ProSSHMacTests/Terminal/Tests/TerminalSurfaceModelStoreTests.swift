// TerminalSurfaceModelStoreTests.swift
// ProSSHMac
//
// The store owns one surface model (and renderer) per session, so that layout changes which
// rebuild the surface view can keep the session's renderer. See Docs/Bug84.md.

#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

@MainActor
final class TerminalSurfaceModelStoreTests: XCTestCase {

    func testSameSessionReturnsSameModel() {
        let store = TerminalSurfaceModelStore()
        let a = UUID()
        let b = UUID()

        let first = store.model(for: a)
        XCTAssertTrue(store.model(for: a) === first, "A session must keep its model")
        XCTAssertFalse(store.model(for: b) === first, "Each session needs its own model")
    }

    func testReleasedModelAndRendererAreDeallocated() async {
        let store = TerminalSurfaceModelStore()
        let session = UUID()
        weak var model: MetalTerminalSurfaceModel?
        weak var renderer: MetalTerminalRenderer?
        do {
            let created = store.model(for: session)
            model = created
            renderer = created.renderer
        }
        XCTAssertNotNil(model)
        XCTAssertNotNil(renderer, "Metal is required for this test")

        store.release(sessionID: session)

        await waitForDeallocation { model == nil && renderer == nil }
        XCTAssertNil(model, "A released model must be freed")
        XCTAssertNil(renderer, "A released model's renderer must be freed")
    }

    func testModelAfterReleaseIsNew() {
        let store = TerminalSurfaceModelStore()
        let session = UUID()
        let first = store.model(for: session)

        store.release(sessionID: session)

        XCTAssertFalse(store.model(for: session) === first, "A released session must get a fresh model")
    }

    func testReleaseOfUnknownSessionIsANoOp() {
        let store = TerminalSurfaceModelStore()
        let session = UUID()
        let model = store.model(for: session)

        store.release(sessionID: UUID())

        XCTAssertTrue(store.model(for: session) === model)
    }

    func testPruneDropsClosedSessionsAndKeepsActiveOnes() async {
        let store = TerminalSurfaceModelStore()
        let (a, b, c) = (UUID(), UUID(), UUID())
        let kept = store.model(for: a)
        weak var closedB: MetalTerminalSurfaceModel?
        weak var closedC: MetalTerminalSurfaceModel?
        do {
            closedB = store.model(for: b)
            closedC = store.model(for: c)
        }
        XCTAssertNotNil(closedB)
        XCTAssertNotNil(closedC)

        store.prune(keeping: [a])

        await waitForDeallocation { closedB == nil && closedC == nil }
        XCTAssertNil(closedB, "Pruning must free a closed session's model")
        XCTAssertNil(closedC, "Pruning must free a closed session's model")
        XCTAssertTrue(store.model(for: a) === kept, "Pruning must keep an active session's model")
    }

    // MARK: - Helpers

    /// The renderer's `[weak self]` tasks can hold it for a moment after its last owner lets go.
    /// A failure after the full second means something still retains it.
    private func waitForDeallocation(_ isFreed: () -> Bool) async {
        let deadline = Date().addingTimeInterval(1)
        while !isFreed(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
#endif
