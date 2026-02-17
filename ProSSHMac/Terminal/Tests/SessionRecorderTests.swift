// SessionRecorderTests.swift
// ProSSHV2
//
// E.3 — Unit coverage for encrypted capture, playback schedule, and .cast export.

#if canImport(XCTest)
import XCTest

@MainActor
final class SessionRecorderTests: XCTestCase {

    func testRecordingPersistsEncryptedPayloadWithTimestampedChunks() throws {
        let directory = makeTempDirectory(suffix: "persist")
        let recorder = SessionRecorder(recordingsDirectoryURL: directory)
        let session = makeSession()

        try recorder.startRecording(for: session)
        recorder.recordInput(sessionID: session.id, text: "ls -la\n")
        Thread.sleep(forTimeInterval: 0.002)
        recorder.recordOutput(sessionID: session.id, text: "total 64\n")

        let recordingURL = try recorder.stopRecording(sessionID: session.id)

        let raw = try Data(contentsOf: recordingURL)
        XCTAssertTrue(raw.starts(with: Data("PSSHENC1".utf8)))

        let recording = try recorder.loadRecording(from: recordingURL)
        XCTAssertEqual(recording.chunks.count, 2)
        XCTAssertEqual(recording.chunks[0].stream, .input)
        XCTAssertEqual(recording.chunks[1].stream, .output)
        XCTAssertGreaterThanOrEqual(recording.chunks[1].offsetNanoseconds, recording.chunks[0].offsetNanoseconds)
    }

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

        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps[0].delayNanoseconds, 500_000_000)
        XCTAssertEqual(steps[1].delayNanoseconds, 1_000_000_000)
        XCTAssertEqual(steps[1].text, "b")
    }

    func testExportAsciinemaCastWritesHeaderAndEvents() throws {
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
