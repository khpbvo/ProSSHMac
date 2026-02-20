// SessionRecorder.swift
// ProSSHV2
//
// E.3 — Captures session byte streams with encrypted persistence,
// playback scheduling, and asciinema-compatible export.

import Foundation

enum SessionRecorderError: LocalizedError {
    case alreadyRecording
    case notRecording
    case recordingNotFound
    case invalidPlaybackSpeed

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "A recording is already active for this session."
        case .notRecording:
            return "No active recording for this session."
        case .recordingNotFound:
            return "No saved recording is available for this session."
        case .invalidPlaybackSpeed:
            return "Playback speed must be greater than zero."
        }
    }
}

enum SessionRecordingStream: String, Codable, Sendable {
    case input
    case output

    var asciinemaCode: String {
        switch self {
        case .input: return "i"
        case .output: return "o"
        }
    }
}

struct SessionRecordingChunk: Codable, Hashable, Sendable {
    let offsetNanoseconds: UInt64
    let stream: SessionRecordingStream
    let payloadBase64: String

    init(offsetNanoseconds: UInt64, stream: SessionRecordingStream, payload: Data) {
        self.offsetNanoseconds = offsetNanoseconds
        self.stream = stream
        self.payloadBase64 = payload.base64EncodedString()
    }

    var payload: Data {
        Data(base64Encoded: payloadBase64) ?? Data()
    }

    var text: String {
        String(decoding: payload, as: UTF8.self)
    }
}

struct SessionRecording: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let sessionID: UUID
    let hostLabel: String
    let username: String
    let hostname: String
    let port: UInt16
    let startedAt: Date
    var endedAt: Date
    var chunks: [SessionRecordingChunk]
}

struct SessionPlaybackStep: Sendable {
    let stream: SessionRecordingStream
    let delayNanoseconds: UInt64
    let relativeSeconds: Double
    let text: String
}

@MainActor
final class SessionRecorder {
    private struct ActiveRecording {
        var recording: SessionRecording
        let startUptimeNanoseconds: UInt64
    }

    private let fileManager: FileManager
    private let recordingsDirectoryURL: URL
    private var activeRecordingsBySessionID: [UUID: ActiveRecording] = [:]
    private var latestRecordingURLBySessionID: [UUID: URL] = [:]

    init(fileManager: FileManager = .default, recordingsDirectoryURL: URL? = nil) {
        self.fileManager = fileManager
        self.recordingsDirectoryURL = recordingsDirectoryURL ?? Self.defaultRecordingsDirectory(fileManager: fileManager)
    }

    func isRecording(sessionID: UUID) -> Bool {
        activeRecordingsBySessionID[sessionID] != nil
    }

    func hasSavedRecording(sessionID: UUID) -> Bool {
        latestRecordingURLBySessionID[sessionID] != nil
    }

    func latestRecordingURL(sessionID: UUID) -> URL? {
        latestRecordingURLBySessionID[sessionID]
    }

    func startRecording(for session: Session) throws {
        guard activeRecordingsBySessionID[session.id] == nil else {
            throw SessionRecorderError.alreadyRecording
        }

        let startDate = Date()
        let recording = SessionRecording(
            id: UUID(),
            sessionID: session.id,
            hostLabel: session.hostLabel,
            username: session.username,
            hostname: session.hostname,
            port: session.port,
            startedAt: startDate,
            endedAt: startDate,
            chunks: []
        )
        activeRecordingsBySessionID[session.id] = ActiveRecording(
            recording: recording,
            startUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
    }

    @discardableResult
    func stopRecording(sessionID: UUID) throws -> URL {
        guard var active = activeRecordingsBySessionID.removeValue(forKey: sessionID) else {
            throw SessionRecorderError.notRecording
        }

        active.recording.endedAt = Date()
        let fileURL = recordingFileURL(recordingID: active.recording.id)
        try persistRecording(active.recording, to: fileURL)
        latestRecordingURLBySessionID[sessionID] = fileURL
        return fileURL
    }

    func recordInput(sessionID: UUID, text: String) {
        appendChunk(sessionID: sessionID, text: text, stream: .input)
    }

    func recordOutput(sessionID: UUID, text: String) {
        appendChunk(sessionID: sessionID, text: text, stream: .output)
    }

    func loadLatestRecording(sessionID: UUID) throws -> SessionRecording {
        guard let fileURL = latestRecordingURLBySessionID[sessionID] else {
            throw SessionRecorderError.recordingNotFound
        }
        return try loadRecording(from: fileURL)
    }

    func loadRecording(from fileURL: URL) throws -> SessionRecording {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let recording = try EncryptedStorage.loadJSON(
            SessionRecording.self,
            from: fileURL,
            fileManager: fileManager,
            decoder: decoder
        ) else {
            throw SessionRecorderError.recordingNotFound
        }
        return recording
    }

    func exportLatestRecordingAsCast(
        sessionID: UUID,
        columns: Int = 80,
        rows: Int = 24,
        destinationURL: URL? = nil
    ) throws -> URL {
        let recording = try loadLatestRecording(sessionID: sessionID)
        return try exportAsciinemaCast(
            recording: recording,
            columns: columns,
            rows: rows,
            destinationURL: destinationURL
        )
    }

    func exportAsciinemaCast(
        recording: SessionRecording,
        columns: Int = 80,
        rows: Int = 24,
        destinationURL: URL? = nil
    ) throws -> URL {
        let outputURL = destinationURL ?? recordingsDirectoryURL
            .appendingPathComponent(recording.id.uuidString)
            .appendingPathExtension("cast")

        var lines: [String] = []
        let header: [String: Any] = [
            "version": 2,
            "width": max(1, columns),
            "height": max(1, rows),
            "timestamp": Int(recording.startedAt.timeIntervalSince1970),
            "env": ["TERM": "xterm-256color", "SHELL": "ssh"]
        ]
        lines.append(try serializeJSONLine(header))

        for chunk in recording.chunks.sorted(by: { $0.offsetNanoseconds < $1.offsetNanoseconds }) {
            let event: [Any] = [
                Double(chunk.offsetNanoseconds) / 1_000_000_000,
                chunk.stream.asciinemaCode,
                chunk.text
            ]
            lines.append(try serializeJSONLine(event))
        }

        let output = lines.joined(separator: "\n") + "\n"
        try fileManager.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try output.write(to: outputURL, atomically: true, encoding: .utf8)
        return outputURL
    }

    func playbackSchedule(recording: SessionRecording, speed: Double = 1.0) throws -> [SessionPlaybackStep] {
        guard speed > 0 else {
            throw SessionRecorderError.invalidPlaybackSpeed
        }

        let sorted = recording.chunks.sorted(by: { $0.offsetNanoseconds < $1.offsetNanoseconds })
        var previousOffset: UInt64 = 0
        var steps: [SessionPlaybackStep] = []
        steps.reserveCapacity(sorted.count)

        for chunk in sorted {
            let delta = chunk.offsetNanoseconds &- previousOffset
            let delay = UInt64(Double(delta) / speed)
            let step = SessionPlaybackStep(
                stream: chunk.stream,
                delayNanoseconds: delay,
                relativeSeconds: Double(chunk.offsetNanoseconds) / 1_000_000_000,
                text: chunk.text
            )
            steps.append(step)
            previousOffset = chunk.offsetNanoseconds
        }

        return steps
    }

    func play(
        recording: SessionRecording,
        speed: Double = 1.0,
        onStep: @escaping @Sendable (SessionPlaybackStep) async -> Void
    ) async throws {
        let steps = try playbackSchedule(recording: recording, speed: speed)
        for step in steps {
            guard !Task.isCancelled else { break }
            if step.delayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: step.delayNanoseconds)
            }
            await onStep(step)
        }
    }

    func playLatestRecording(
        sessionID: UUID,
        speed: Double = 1.0,
        onStep: @escaping @Sendable (SessionPlaybackStep) async -> Void
    ) async throws {
        let recording = try loadLatestRecording(sessionID: sessionID)
        try await play(recording: recording, speed: speed, onStep: onStep)
    }

    private func appendChunk(sessionID: UUID, text: String, stream: SessionRecordingStream) {
        guard !text.isEmpty,
              var active = activeRecordingsBySessionID[sessionID] else {
            return
        }

        let offset = DispatchTime.now().uptimeNanoseconds &- active.startUptimeNanoseconds
        let chunk = SessionRecordingChunk(
            offsetNanoseconds: offset,
            stream: stream,
            payload: Data(text.utf8)
        )
        active.recording.chunks.append(chunk)
        activeRecordingsBySessionID[sessionID] = active
    }

    private func persistRecording(_ recording: SessionRecording, to fileURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        try EncryptedStorage.saveJSON(
            recording,
            to: fileURL,
            fileManager: fileManager,
            encoder: encoder
        )
    }

    private func recordingFileURL(recordingID: UUID) -> URL {
        recordingsDirectoryURL
            .appendingPathComponent(recordingID.uuidString)
            .appendingPathExtension("psshrec")
    }

    private func serializeJSONLine(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated private static func defaultRecordingsDirectory(fileManager: FileManager) -> URL {
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)

        return baseDirectory
            .appendingPathComponent("ProSSHV2", isDirectory: true)
            .appendingPathComponent("SessionRecordings", isDirectory: true)
    }
}
