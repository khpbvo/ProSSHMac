// SessionRecorderTests.swift
// ProSSHV2
//
// E.3 — Unit coverage for encrypted capture, playback schedule, and .cast export.

#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

final class SessionRecorderTests: XCTestCase {

    @MainActor
    func testRecordingPersistsEncryptedPayloadWithTimestampedChunks() async throws {
        let directory = makeTempDirectory(suffix: "persist")
        let recorder = SessionRecorder(recordingsDirectoryURL: directory)
        let session = makeSession()

        try recorder.startRecording(for: session)
        recorder.recordInput(sessionID: session.id, text: "ls -la\n")
        try await Task.sleep(nanoseconds: 2_000_000)
        recorder.recordOutput(sessionID: session.id, text: "total 64\n")

        let recordingURL = try recorder.stopRecording(sessionID: session.id)

        let raw = try Data(contentsOf: recordingURL)
        XCTAssertTrue(raw.starts(with: Data("PSSHENC1".utf8)))

        let recording = try recorder.loadRecording(from: recordingURL)
        let chunks = recording.chunks
        let firstStream = chunks[0].stream
        let secondStream = chunks[1].stream
        let firstOffset = chunks[0].offsetNanoseconds
        let secondOffset = chunks[1].offsetNanoseconds
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(firstStream, .input)
        XCTAssertEqual(secondStream, .output)
        XCTAssertGreaterThanOrEqual(secondOffset, firstOffset)
    }

    @MainActor
    func testPlaybackScheduleSupportsSpeedMultiplier() throws {
        let recorder = SessionRecorder(recordingsDirectoryURL: makeTempDirectory(suffix: "schedule"))
        let recording = SessionRecording(
            id: UUID(),
            sessionID: UUID(),
            hostLabel: "host",
            username: "user",
            hostname: "example.com",
            port: 22,
            startedAt: Date(),
            endedAt: Date(),
            chunks: [
                SessionRecordingChunk(offsetNanoseconds: 1_000_000_000, stream: .output, payload: Data("a".utf8)),
                SessionRecordingChunk(offsetNanoseconds: 3_000_000_000, stream: .output, payload: Data("b".utf8))
            ]
        )

        let steps = try recorder.playbackSchedule(recording: recording, speed: 2.0)
        let firstDelay = steps[0].delayNanoseconds
        let secondDelay = steps[1].delayNanoseconds
        let secondText = steps[1].text

        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(firstDelay, 500_000_000)
        XCTAssertEqual(secondDelay, 1_000_000_000)
        XCTAssertEqual(secondText, "b")
    }

    @MainActor
    func testExportAsciinemaCastWritesHeaderAndEvents() async throws {
        let directory = makeTempDirectory(suffix: "cast")
        let recorder = SessionRecorder(recordingsDirectoryURL: directory)
        let recording = SessionRecording(
            id: UUID(),
            sessionID: UUID(),
            hostLabel: "host",
            username: "user",
            hostname: "example.com",
            port: 22,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_005),
            chunks: [
                SessionRecordingChunk(offsetNanoseconds: 250_000_000, stream: .output, payload: Data("hello\n".utf8))
            ]
        )

        let castURL = try recorder.exportAsciinemaCast(
            recording: recording,
            columns: 90,
            rows: 30,
            destinationURL: directory.appendingPathComponent("test.cast")
        )

        let lines = try String(contentsOf: castURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)

        XCTAssertEqual(lines.count, 2)

        let headerData = Data(lines[0].utf8)
        let header = try XCTUnwrap(try JSONSerialization.jsonObject(with: headerData) as? [String: Any])
        XCTAssertEqual(header["version"] as? Int, 2)
        XCTAssertEqual(header["width"] as? Int, 90)
        XCTAssertEqual(header["height"] as? Int, 30)

        let eventData = Data(lines[1].utf8)
        let event = try XCTUnwrap(try JSONSerialization.jsonObject(with: eventData) as? [Any])
        XCTAssertEqual(event.count, 3)
        XCTAssertEqual(event[1] as? String, "o")
        XCTAssertEqual(event[2] as? String, "hello\n")
    }

    @MainActor
    private func makeSession() -> Session {
        Session(
            id: UUID(),
            kind: .ssh(hostID: UUID()),
            hostLabel: "lab",
            username: "ops",
            hostname: "router.local",
            port: 22,
            state: .connected,
            negotiatedKEX: nil,
            negotiatedCipher: nil,
            negotiatedHostKeyType: nil,
            negotiatedHostFingerprint: nil,
            usesLegacyCrypto: false,
            usesAgentForwarding: false,
            securityAdvisory: nil,
            transportBackend: nil,
            jumpHostLabel: nil,
            startedAt: Date(),
            endedAt: nil,
            errorMessage: nil
        )
    }

    private func makeTempDirectory(suffix: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionRecorderTests.\(suffix).\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
#endif
