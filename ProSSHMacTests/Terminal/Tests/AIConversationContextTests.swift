#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

@MainActor
final class AIConversationContextTests: XCTestCase {
    private var context: AIConversationContext!

    override func setUp() async throws {
        context = AIConversationContext()
    }

    override func tearDown() async throws {
        context = nil
    }

    func testResponseIDReturnsNilForUnknownSession() {
        let id = UUID()
        XCTAssertNil(context.responseID(for: id))
    }

    func testUpdateAndRetrieveResponseID() {
        let id = UUID()
        context.update(responseID: "resp_1", for: id)
        XCTAssertEqual(context.responseID(for: id), "resp_1")
    }

    func testUpdateWithNilSetsNil() {
        let id = UUID()
        context.update(responseID: "resp_1", for: id)
        context.update(responseID: nil, for: id)
        XCTAssertNil(context.responseID(for: id))
    }

    func testClearRemovesEntry() {
        let id = UUID()
        context.update(responseID: "resp_1", for: id)
        context.clear(sessionID: id)
        XCTAssertNil(context.responseID(for: id))
    }

    func testClearNonexistentSessionIsSafe() {
        // Should not crash
        context.clear(sessionID: UUID())
    }

    func testMultipleSessionsAreIndependent() {
        let id1 = UUID()
        let id2 = UUID()
        context.update(responseID: "resp_A", for: id1)
        context.update(responseID: "resp_B", for: id2)
        XCTAssertEqual(context.responseID(for: id1), "resp_A")
        XCTAssertEqual(context.responseID(for: id2), "resp_B")
    }

    func testPreviousResponseIDBySessionIDReflectsState() {
        let id1 = UUID()
        let id2 = UUID()
        context.update(responseID: "resp_X", for: id1)
        context.update(responseID: "resp_Y", for: id2)
        XCTAssertEqual(context.previousResponseIDBySessionID.count, 2)
        XCTAssertEqual(context.previousResponseIDBySessionID[id1], "resp_X")
        XCTAssertEqual(context.previousResponseIDBySessionID[id2], "resp_Y")
        context.clear(sessionID: id1)
        XCTAssertEqual(context.previousResponseIDBySessionID.count, 1)
    }
}

#endif
