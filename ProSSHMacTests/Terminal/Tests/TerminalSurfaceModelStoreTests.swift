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

    // MARK: - A session shown in two panes

    func testDuplicatePaneGetsItsOwnModel() {
        let store = TerminalSurfaceModelStore()
        let session = UUID()
        let pane = UUID()
        let primary = store.model(for: session)

        let duplicate = store.model(for: session, duplicateInPane: pane)

        XCTAssertFalse(duplicate === primary, "A second pane showing a session needs its own renderer")
        XCTAssertTrue(store.model(for: session, duplicateInPane: pane) === duplicate)
        XCTAssertTrue(store.model(for: session) === primary)
    }

    func testReleaseDropsTheSessionsDuplicates() async {
        let store = TerminalSurfaceModelStore()
        let session = UUID()
        let pane = UUID()
        weak var duplicate: MetalTerminalSurfaceModel?
        do {
            duplicate = store.model(for: session, duplicateInPane: pane)
        }

        store.release(sessionID: session)

        await waitForDeallocation { duplicate == nil }
        XCTAssertNil(duplicate, "Releasing a session must free its duplicate-pane models too")
    }

    func testPruneDropsDuplicatesOfClosedPanesAndSessions() async {
        let store = TerminalSurfaceModelStore()
        let (live, closed) = (UUID(), UUID())
        let (keptPane, closedPane, closedSessionPane) = (UUID(), UUID(), UUID())
        let kept = store.model(for: live, duplicateInPane: keptPane)
        weak var inClosedPane: MetalTerminalSurfaceModel?
        weak var ofClosedSession: MetalTerminalSurfaceModel?
        do {
            inClosedPane = store.model(for: live, duplicateInPane: closedPane)
            ofClosedSession = store.model(for: closed, duplicateInPane: closedSessionPane)
        }

        store.prune(keeping: [live], panes: [keptPane, closedSessionPane])

        await waitForDeallocation { inClosedPane == nil && ofClosedSession == nil }
        XCTAssertNil(inClosedPane, "Pruning must free the model of a pane that is gone")
        XCTAssertNil(ofClosedSession, "Pruning must free a closed session's duplicate models")
        XCTAssertTrue(store.model(for: live, duplicateInPane: keptPane) === kept)
    }

    func testPruneWithoutPanesKeepsLiveSessionsDuplicates() {
        let store = TerminalSurfaceModelStore()
        let session = UUID()
        let pane = UUID()
        let duplicate = store.model(for: session, duplicateInPane: pane)

        store.prune(keeping: [session])

        XCTAssertTrue(store.model(for: session, duplicateInPane: pane) === duplicate)
    }

    // MARK: - Attach / detach

    /// A rebuilt surface attaches before the old one disappears; the old one must not detach it.
    func testOnlyTheAttachedSurfaceCanDetach() {
        let model = MetalTerminalSurfaceModel()
        let (old, new) = (UUID(), UUID())

        model.attach(surface: old)
        model.attach(surface: new)

        XCTAssertFalse(model.detach(surface: old), "A replaced surface must not detach its replacement")
        XCTAssertTrue(model.detach(surface: new))
        XCTAssertFalse(model.detach(surface: new), "Detaching twice must be a no-op")
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
