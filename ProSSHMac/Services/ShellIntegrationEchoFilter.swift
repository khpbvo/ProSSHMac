// ShellIntegrationEchoFilter.swift
// ProSSHMac
//
// Hides the echo of the shell-integration line typed into a remote shell (Bug 90).
//
// A remote shell gets its OSC 133 integration as a typed line, and the shell echoes it:
// readline (or ZLE) redraws the whole line, wrapped over several rows, then prints CR LF
// before running it. The line ends by printing a private marker with its own token
// (`ShellIntegrationScripts.sshInjectionLine`). From the send until that marker, output is
// held back; at the marker the held bytes (echo, CR LF, the script's own OSC 133 marks) are
// dropped and everything after it passes, starting with the line's CR + erase-line.
//
// The hold is bounded on both sides, so a shell that never prints the marker (wrong shell
// type, a menu, a syntax error) costs at most `byteCap` bytes or the release timeout, after
// which every held byte is passed on in order: the terminal then shows what it always did.

import Foundation

nonisolated struct ShellIntegrationEchoFilter {

    static let defaultByteCap = 16 * 1024

    let token: String
    private let marker: [UInt8]
    private let byteCap: Int
    private var held: [UInt8] = []
    private var releaseRequested = false

    init(token: String, byteCap: Int = ShellIntegrationEchoFilter.defaultByteCap) {
        self.token = token
        self.marker = ShellIntegrationScripts.injectionEndMarker(token: token)
        self.byteCap = byteCap
    }

    /// Feeds one chunk. Returns nil while the output is held back. Once it returns data the
    /// filter is done: that data and everything after it go to the terminal unfiltered.
    mutating func process(_ chunk: Data) -> Data? {
        // Resume the search where a marker split across chunks could start.
        let searchStart = max(0, held.count - (marker.count - 1))
        held.append(contentsOf: chunk)
        if let range = held[searchStart...].firstRange(of: marker) {
            let visible = Data(held[range.upperBound...])
            held.removeAll()
            return visible
        }
        if releaseRequested || held.count > byteCap {
            return drain()
        }
        return nil
    }

    /// The release timeout passed: the next `process` call passes everything held.
    mutating func requestRelease() {
        releaseRequested = true
    }

    /// Everything held so far, in order.
    mutating func drain() -> Data {
        defer { held.removeAll() }
        return Data(held)
    }
}

/// When a shell is ready for the integration line, and how long its echo may be held back.
nonisolated struct ShellIntegrationInjectionTiming: Sendable {
    /// Output must have been quiet this long before the line is sent.
    var quietPeriod: Duration
    /// A shell that never looks ready within this gets no integration: nothing is sent.
    var readinessTimeout: Duration
    /// Held output is released after this if the end marker never arrives.
    var releaseTimeout: Duration
    var pollInterval: Duration

    static let standard = ShellIntegrationInjectionTiming(
        quietPeriod: .milliseconds(300),
        readinessTimeout: .seconds(10),
        releaseTimeout: .seconds(3),
        pollInterval: .milliseconds(50)
    )
}

nonisolated enum ShellIntegrationInjectionResult: Equatable, Sendable {
    case injected
    case skipped(SkipReason)

    enum SkipReason: Equatable, Sendable {
        /// No script for this shell type.
        case unsupportedType
        /// The session closed or its channel went away.
        case sessionGone
        /// The user typed before the prompt was ready: the line would join their input.
        case userInput
        /// Output never went quiet at a prompt-like cursor within the readiness timeout.
        case notReady
        case sendFailed
    }
}
