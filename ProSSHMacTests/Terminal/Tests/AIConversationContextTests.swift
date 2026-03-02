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

    func testStateReturnsNilForUnknownSession() {
        let id = UUID()
        XCTAssertNil(context.state(for: id))
    }

    func testUpdateAndRetrieveState() {
        let id = UUID()
        context.update(state: .string("resp_1", provider: .openai), for: id)
        XCTAssertEqual(context.state(for: id)?.stringValue, "resp_1")
    }

    func testUpdateWithNilSetsNil() {
        let id = UUID()
        context.update(state: .string("resp_1", provider: .openai), for: id)
        context.update(state: nil, for: id)
        XCTAssertNil(context.state(for: id))
    }

    func testClearRemovesEntry() {
        let id = UUID()
        context.update(state: .string("resp_1", provider: .openai), for: id)
        context.clear(sessionID: id)
        XCTAssertNil(context.state(for: id))
    }

    func testClearNonexistentSessionIsSafe() {
        // Should not crash
        context.clear(sessionID: UUID())
    }

    func testMultipleSessionsAreIndependent() {
        let id1 = UUID()
        let id2 = UUID()
        context.update(state: .string("resp_A", provider: .openai), for: id1)
        context.update(state: .string("resp_B", provider: .openai), for: id2)
        XCTAssertEqual(context.state(for: id1)?.stringValue, "resp_A")
        XCTAssertEqual(context.state(for: id2)?.stringValue, "resp_B")
    }

    func testStateBySessionIDReflectsState() {
        let id1 = UUID()
        let id2 = UUID()
        context.update(state: .string("resp_X", provider: .openai), for: id1)
        context.update(state: .string("resp_Y", provider: .openai), for: id2)
        XCTAssertEqual(context.stateBySessionID.count, 2)
        XCTAssertEqual(context.stateBySessionID[id1]?.stringValue, "resp_X")
        XCTAssertEqual(context.stateBySessionID[id2]?.stringValue, "resp_Y")
        context.clear(sessionID: id1)
        XCTAssertEqual(context.stateBySessionID.count, 1)
    }
}

#endif
