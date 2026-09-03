// ZshStartupWarningFilter.swift
// ProSSHMac
//
// Strips the one-off zsh "can't set tty pgrp" warning from the opening bytes of
// a local shell session.
//
// zsh emits this warning once, during startup, when it cannot take the
// controlling terminal. The scan used to run on every chunk for the entire
// session, because its "stop scanning" flag was only ever set if the warning
// was actually found — under a shell that never emits it (sh, bash) the filter
// decoded, concatenated, case-insensitively searched, lowercased and re-encoded
// every byte of output forever. The 2026-09-03 stage budget measured that at
// **93% of local-shell wall time**.
//
// The scan is therefore bounded: after `byteBudget` bytes it switches off for
// good. The warning appears within the first ~100 bytes of a session, so the
// default budget is several hundred times larger than it needs to be.

import Foundation

nonisolated struct ZshStartupWarningFilter {

    static let defaultByteBudget = 32 * 1024
    private static let marker = "zsh: can't set tty pgrp:"

    private let byteBudget: Int
    private var isActive = true
    private var bytesScanned = 0
    private var carry = ""

    init(byteBudget: Int = ZshStartupWarningFilter.defaultByteBudget) {
        self.byteBudget = byteBudget
    }

    /// False once the filter has switched off — the caller can then pass data
    /// straight through with no per-chunk work at all.
    var isScanning: Bool { isActive }

    /// Feed one chunk. `emit` is called with the data to forward, in order, and
    /// may be called more than once (a buffered partial match is flushed first).
    mutating func process(_ data: Data, emit: (Data) -> Void) {
        guard isActive else {
            emit(data)
            return
        }

        bytesScanned += data.count
        if bytesScanned > byteBudget {
            deactivate(emit: emit)
            emit(data)
            return
        }

        // A chunk boundary that splits a multi-byte character fails to decode.
        // Flush any buffered partial match first so bytes stay in order.
        guard let chunk = String(data: data, encoding: .utf8) else {
            deactivate(emit: emit)
            emit(data)
            return
        }

        var text = carry + chunk
        carry.removeAll(keepingCapacity: false)

        if let markerRange = text.range(of: Self.marker, options: [.caseInsensitive]) {
            // Drop the whole line the warning sits on.
            let lineStart = text[..<markerRange.lowerBound].lastIndex(of: "\n")
                .map { text.index(after: $0) } ?? text.startIndex
            let lineEnd = text[markerRange.upperBound...].firstIndex(of: "\n")
                .map { text.index(after: $0) } ?? text.endIndex

            text.removeSubrange(lineStart..<lineEnd)
            isActive = false
            if !text.isEmpty {
                emit(Data(text.utf8))
            }
            return
        }

        // Hold back the longest suffix that could be the start of the marker
        // split across this chunk boundary. Compared in the same Character
        // domain the split uses, so the two can never disagree.
        let maxSuffixLength = min(text.count, Self.marker.count - 1)
        var carryLength = 0
        if maxSuffixLength > 0 {
            for length in stride(from: maxSuffixLength, through: 1, by: -1) {
                if text.suffix(length).lowercased() == Self.marker.prefix(length).lowercased() {
                    carryLength = length
                    break
                }
            }
        }

        if carryLength == 0 {
            emit(Data(text.utf8))
            return
        }

        let emitCount = text.count - carryLength
        if emitCount > 0 {
            emit(Data(text.prefix(emitCount).utf8))
        }
        carry = String(text.suffix(carryLength))
    }

    /// Flush anything still buffered. Call when the stream ends.
    mutating func finish(emit: (Data) -> Void) {
        guard !carry.isEmpty else { return }
        emit(Data(carry.utf8))
        carry.removeAll(keepingCapacity: false)
    }

    private mutating func deactivate(emit: (Data) -> Void) {
        isActive = false
        if !carry.isEmpty {
            emit(Data(carry.utf8))
            carry.removeAll(keepingCapacity: false)
        }
    }
}
