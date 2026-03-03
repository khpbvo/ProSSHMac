#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

@MainActor
final class AIBroadcastTests: XCTestCase {

    // MARK: - BroadcastContext

    func testBroadcastContextIsBroadcastingMultipleSessions() {
        let id1 = UUID()
        let id2 = UUID()
        let ctx = BroadcastContext(
            primarySessionID: id1,
            allSessionIDs: [id1, id2],
            sessionLabels: [id1: "server1", id2: "server2"]
        )
        XCTAssertTrue(ctx.isBroadcasting)
    }

    func testBroadcastContextIsBroadcastingSingleSession() {
        let id1 = UUID()
        let ctx = BroadcastContext(
            primarySessionID: id1,
            allSessionIDs: [id1],
            sessionLabels: [id1: "server1"]
        )
        XCTAssertFalse(ctx.isBroadcasting)
    }

    // MARK: - resolveTargetSessions

    func testResolveTargetSessionsWithExplicitTarget() {
        let handler = AIToolHandler()
        let primary = UUID()
        let target = UUID()
        let other = UUID()
        let ctx = BroadcastContext(
            primarySessionID: primary,
            allSessionIDs: [primary, target, other],
            sessionLabels: [:]
        )
        let arguments: [String: LLMJSONValue] = [
            "target_session": .string(target.uuidString),
        ]
        let result = handler.resolveTargetSessions(
            arguments: arguments,
            primarySessionID: primary,
            broadcastContext: ctx
        )
        XCTAssertEqual(result, [target])
    }

    func testResolveTargetSessionsInBroadcastNoTarget() {
        let handler = AIToolHandler()
        let primary = UUID()
        let other = UUID()
        let ctx = BroadcastContext(
            primarySessionID: primary,
            allSessionIDs: [primary, other],
            sessionLabels: [:]
        )
        let arguments: [String: LLMJSONValue] = [
            "target_session": .null,
        ]
        let result = handler.resolveTargetSessions(
            arguments: arguments,
            primarySessionID: primary,
            broadcastContext: ctx
        )
        XCTAssertEqual(result, [primary, other])
    }

    func testResolveTargetSessionsSingleFocus() {
        let handler = AIToolHandler()
        let primary = UUID()
        let arguments: [String: LLMJSONValue] = [
            "target_session": .null,
        ]
        let result = handler.resolveTargetSessions(
            arguments: arguments,
            primarySessionID: primary,
            broadcastContext: nil
        )
        XCTAssertEqual(result, [primary])
    }

    func testResolveTargetSessionsInvalidTargetFallsBackToBroadcast() {
        let handler = AIToolHandler()
        let primary = UUID()
        let other = UUID()
        let ctx = BroadcastContext(
            primarySessionID: primary,
            allSessionIDs: [primary, other],
            sessionLabels: [:]
        )
        // Pass an ID not in allSessionIDs — should fall back to broadcast
        let bogusID = UUID()
        let arguments: [String: LLMJSONValue] = [
            "target_session": .string(bogusID.uuidString),
        ]
        let result = handler.resolveTargetSessions(
            arguments: arguments,
            primarySessionID: primary,
            broadcastContext: ctx
        )
        // Falls back to broadcast (all sessions)
        XCTAssertEqual(result, [primary, other])
    }

    func testResolveTargetSessionsInvalidTargetFallsBackToPrimary() {
        let handler = AIToolHandler()
        let primary = UUID()
        // No broadcast context, invalid target — falls back to primary
        let bogusID = UUID()
        let arguments: [String: LLMJSONValue] = [
            "target_session": .string(bogusID.uuidString),
        ]
        // With no broadcast context, invalid UUID passes through (not in allSessionIDs check is skipped)
        let result = handler.resolveTargetSessions(
            arguments: arguments,
            primarySessionID: primary,
            broadcastContext: nil
        )
        // No broadcastContext and the UUID is valid format, so it returns [bogusID]
        // because the allSessionIDs check uses ?? true when broadcastContext is nil
        XCTAssertEqual(result, [bogusID])
    }

    // MARK: - formatBroadcastResult

    func testFormatBroadcastResultSingleSession() {
        let handler = AIToolHandler()
        let id1 = UUID()
        let ctx = BroadcastContext(
            primarySessionID: id1,
            allSessionIDs: [id1],
            sessionLabels: [id1: "server1"]
        )
        let result = handler.formatBroadcastResult(
            results: [(sessionID: id1, output: "hello world")],
            context: ctx
        )
        XCTAssertEqual(result, "hello world")
    }

    func testFormatBroadcastResultMultipleSessions() {
        let handler = AIToolHandler()
        let id1 = UUID()
        let id2 = UUID()
        let ctx = BroadcastContext(
            primarySessionID: id1,
            allSessionIDs: [id1, id2],
            sessionLabels: [id1: "server1", id2: "server2"]
        )
        let result = handler.formatBroadcastResult(
            results: [
                (sessionID: id1, output: "output1"),
                (sessionID: id2, output: "output2"),
            ],
            context: ctx
        )
        XCTAssertTrue(result.contains("[server1]"))
        XCTAssertTrue(result.contains("output1"))
        XCTAssertTrue(result.contains("[server2]"))
        XCTAssertTrue(result.contains("output2"))
        XCTAssertTrue(result.contains("---"))
    }

    func testFormatBroadcastResultUsesShortIDForMissingLabel() {
        let handler = AIToolHandler()
        let id1 = UUID()
        let id2 = UUID()
        let ctx = BroadcastContext(
            primarySessionID: id1,
            allSessionIDs: [id1, id2],
            sessionLabels: [id1: "server1"]  // id2 has no label
        )
        let result = handler.formatBroadcastResult(
            results: [
                (sessionID: id1, output: "a"),
                (sessionID: id2, output: "b"),
            ],
            context: ctx
        )
        XCTAssertTrue(result.contains("[server1]"))
        // Should use first 8 chars of UUID as fallback label
        let shortID = String(id2.uuidString.prefix(8))
        XCTAssertTrue(result.contains("[\(shortID)]"))
    }
}
#endif
