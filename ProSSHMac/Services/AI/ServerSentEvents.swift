import Foundation

/// Splits a server-sent event stream, byte by byte, into event `data` payloads. Lines end in
/// CR, LF or CRLF; a blank line completes an event; `event:`, `id:` and comment lines are
/// ignored, since both providers put the event type inside the JSON payload.
struct ServerSentEventDecoder {
    enum DecodingError: Error {
        case lineTooLong
        case invalidUTF8
    }

    static let maxLineBytes = 4_000_000

    private var dataLines: [String] = []
    private var lineBytes = Data()
    private var lastWasCR = false

    /// Feeds one byte; returns an event's payload (its `data:` lines joined by newlines) when
    /// this byte completes one.
    mutating func consume(_ byte: UInt8) throws -> String? {
        if byte == 13 {
            lastWasCR = true
            return try consumeLine()
        }
        if byte == 10 {
            defer { lastWasCR = false }
            return lastWasCR ? nil : try consumeLine()
        }
        lastWasCR = false
        lineBytes.append(byte)
        if lineBytes.count > Self.maxLineBytes { throw DecodingError.lineTooLong }
        return nil
    }

    /// Flushes a final event that the stream ended without a blank line for.
    mutating func finish() throws -> String? {
        if !lineBytes.isEmpty, let payload = try consumeLine() { return payload }
        return dispatch()
    }

    private mutating func consumeLine() throws -> String? {
        guard let line = String(data: lineBytes, encoding: .utf8) else { throw DecodingError.invalidUTF8 }
        lineBytes.removeAll(keepingCapacity: true)
        if line.isEmpty { return dispatch() }
        if line.hasPrefix("data:") {
            var value = String(line.dropFirst(5))
            if value.hasPrefix(" ") { value.removeFirst() }
            dataLines.append(value)
        }
        return nil
    }

    private mutating func dispatch() -> String? {
        guard !dataLines.isEmpty else { return nil }
        defer { dataLines.removeAll(keepingCapacity: true) }
        return dataLines.joined(separator: "\n")
    }
}
