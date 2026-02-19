// VTParser.swift
// ProSSHV2
//
// VT500-series compatible parser state machine.
// Based on Paul Flo Williams' state machine model (https://vt100.net/emu/dec_ansi_parser).
//
// Every byte from the SSH channel feeds into this parser via `feed(_:)`.
// The parser emits actions that modify the terminal grid. No rendering logic lives here.
// The parser and grid are separate actors — the parser calls grid methods across the actor boundary.

import Foundation
import os.log

// MARK: - VTParser Actor

actor VTParser {

    private static let parserLog = Logger(subsystem: "com.prossh", category: "VTParser")

    // MARK: - Grid Reference

    /// The terminal grid this parser drives.
    let grid: TerminalGrid

    // MARK: - Debug Logging

    /// Enable to log parser transitions for debugging escape sequence issues.
    /// Check Xcode console for output. Disable in production for performance.
    private static let debugLogging = false

    /// Optional shared input mode tracker, kept in sync with mode-changing sequences.
    private var inputModeState: InputModeState?

    // MARK: - Parser State

    /// Current state machine state.
    private(set) var state: ParserState = .ground

    /// State before the most recent ESC transition (for 7-bit ST detection).
    private var stateBeforeEscape: ParserState = .ground

    // MARK: - Parameter Collection (A.8.3)

    /// Collected numeric parameters for CSI/DCS sequences.
    /// Each top-level parameter is an array of subparameters.
    /// Semicolons separate top-level parameters; colons separate subparameters.
    /// Example: "4:3" → [[4, 3]], "38;2;255;0;0" → [[38],[2],[255],[0],[0]]
    /// Example: "38:2::255:0:0" → [[38,2,0,255,0,0]]
    private var params: [[Int]] = []

    /// The parameter currently being built (digits accumulated so far).
    private var currentParam: Int = 0

    /// Whether we've started collecting a parameter (to distinguish 0 from empty).
    private var hasCurrentParam: Bool = false

    /// Whether the sequence has a private marker ('?', '>', '<', '=').
    private var privateMarker: UInt8 = 0

    /// Whether we are currently inside a subparameter group (after a colon).
    private var inSubparam: Bool = false

    // MARK: - Intermediate Byte Collection (A.8.4)

    /// Collected intermediate bytes (0x20–0x2F).
    private var intermediates: [UInt8] = []

    // MARK: - OSC String Collection

    /// Collected OSC string data.
    private var oscString: [UInt8] = []

    // MARK: - DCS Collection

    /// Collected DCS passthrough data.
    private var dcsData: [UInt8] = []

    /// Expected UTF-8 continuation bytes remaining while collecting OSC/DCS
    /// string payloads. Used to disambiguate C1 ST (0x9C) from UTF-8
    /// continuation bytes in strings like "✳" (E2 9C B3).
    private var stringUTF8Remaining: Int = 0

    /// Saved params at DCS hook time (for dispatch during unhook).
    private var dcsParams: [[Int]] = []

    /// Saved intermediates at DCS hook time.
    private var dcsIntermediates: [UInt8] = []

    // MARK: - UTF-8 Multibyte Decoding (A.8.5)

    /// Buffer for accumulating UTF-8 multibyte sequences.
    private var utf8Buffer: [UInt8] = []

    /// Number of bytes remaining in the current UTF-8 sequence.
    private var utf8Remaining: Int = 0

    /// Expected total bytes for the current UTF-8 sequence.
    private var utf8Expected: Int = 0

    // MARK: - Reentrancy Guard

    /// Queue of data waiting to be processed. Reentrant calls to feed()
    /// append here instead of interleaving with the in-progress parse.
    private var feedQueue: [Data] = []
    /// Read head for `feedQueue`. Avoids `removeFirst()` in hot paths.
    private var feedQueueHead: Int = 0

    /// True while processByte() is running. Guards against Swift actor
    /// reentrancy: when feed() awaits a cross-actor grid call, the actor
    /// can accept another feed() message. Without this guard the second
    /// call would mutate parser state (state, params, intermediates, etc.)
    /// between the await and the state assignment in processByte().
    private var isFeeding: Bool = false

    // MARK: - Initialization

    init(grid: TerminalGrid) {
        self.grid = grid
    }

    // MARK: - A.8.6 Feed Method

    /// Feed raw bytes from the SSH channel into the parser.
    /// This is the main entry point — call this with each chunk of data received.
    ///
    /// Reentrancy-safe: if called while another feed() is in progress (possible
    /// because `processByte` awaits cross-actor grid calls, which suspends this
    /// actor and allows other messages through), the data is queued and processed
    /// in order after the current chunk completes. This prevents a concurrent
    /// `appendShellLine` or `applyPlaybackStep` from corrupting mid-sequence
    /// parser state.
    /// Returns `true` if this call drove the processing loop (data was
    /// processed immediately). Returns `false` if the data was queued
    /// behind an in-progress feed — the caller can skip snapshotting
    /// because the active feeder will process the queued data before
    /// returning.
    @discardableResult
    func feed(_ data: Data) async -> Bool {
        feedQueue.append(data)
        guard !isFeeding else { return false }
        isFeeding = true
        defer {
            isFeeding = false
            // Queue is fully drained at this point; keep capacity for future bursts.
            feedQueue.removeAll(keepingCapacity: true)
            feedQueueHead = 0
        }

        while feedQueueHead < feedQueue.count {
            let next = feedQueue[feedQueueHead]
            feedQueueHead += 1
            let bytes = ContiguousArray(next)
            var index = 0

            while index < bytes.count {
                let byte = bytes[index]

                if shouldFastPathGroundTextByte(byte) {
                    let start = index
                    index += 1
                    while index < bytes.count, shouldFastPathGroundTextByte(bytes[index]) {
                        index += 1
                    }
                    // Pass range to avoid second Array copy.
                    await grid.processGroundTextBytes(bytes, range: start..<index)
                    continue
                }

                await processByte(byte)
                index += 1
            }

            // Compact occasionally so long bursts don't retain a large head offset.
            if feedQueueHead >= 64, feedQueueHead * 2 >= feedQueue.count {
                feedQueue.removeFirst(feedQueueHead)
                feedQueueHead = 0
            }
        }
        return true
    }

    /// Fast-path condition for ground-state text bytes that can be
    /// processed in bulk without changing parser state.
    private func shouldFastPathGroundTextByte(_ byte: UInt8) -> Bool {
        state == .ground &&
        utf8Remaining == 0 &&
        (
            (byte >= 0x20 && byte <= 0x7E) || // printable ASCII
            byte == 0x0A ||                   // LF
            byte == 0x0D                      // CR
        )
    }

    /// Feed a single byte array into the parser.
    func feed(_ bytes: [UInt8]) async {
        await feed(Data(bytes))
    }

    // MARK: - Core State Machine (A.8.1, A.8.2)

    /// Process a single byte through the state machine.
    private func processByte(_ byte: UInt8) async {
        // UTF-8 continuation bytes go to the UTF-8 decoder when active
        if utf8Remaining > 0 {
            if byte & 0xC0 == 0x80 {
                // Valid continuation byte
                utf8Buffer.append(byte)
                utf8Remaining -= 1
                if utf8Remaining == 0 {
                    await flushUTF8()
                }
                return
            } else {
                // Invalid continuation — discard the incomplete sequence
                resetUTF8()
                // Fall through to process this byte normally
            }
        }

        // Anywhere transitions: CAN, SUB, ESC, and C1 controls
        // These override the current state regardless.
        if let anywhereResult = anywhereTransition(byte) {
            await executeAction(anywhereResult.action, byte: byte)
            state = anywhereResult.nextState
            return
        }

        // State-specific transition
        let transition = stateTransition(state: state, byte: byte)
        await executeAction(transition.action, byte: byte)
        state = transition.nextState
    }

    // MARK: - Anywhere Transitions

    /// Transitions that apply in any state (CAN, SUB, ESC, C1 controls).
    /// Returns nil if the byte doesn't trigger an anywhere transition.
    private func anywhereTransition(_ byte: UInt8) -> Transition? {
        // CAN, SUB, ESC are valid in ALL states (7-bit, no UTF-8 conflict)
        switch byte {
        case C0.CAN.rawValue: // 0x18 — Cancel
            return Transition(.none, .ground)

        case C0.SUB.rawValue: // 0x1A — Substitute
            return Transition(.execute, .ground)

        case C0.ESC.rawValue: // 0x1B — Escape
            stateBeforeEscape = state
            return Transition(.clear, .escape)

        default:
            break
        }

        // In string-collecting states (OSC, DCS passthrough, SOS/PM/APC),
        // bytes 0x80-0x9F must NOT be interpreted as C1 controls — they are
        // UTF-8 continuation bytes within the string payload. Only ST (0x9C)
        // is recognized to terminate the string. Without this guard, a UTF-8
        // character whose encoding contains e.g. 0x84 (IND) or 0x90 (DCS)
        // would abort the string mid-sequence, leaking remaining bytes as
        // visible text on screen.
        switch state {
        case .oscString, .dcsPassthrough, .sosPmApcString:
            if byte == C1.ST.rawValue { // 0x9C — terminate the string
                // In UTF-8 mode, 0x9C can be a continuation byte (e.g. "✳").
                // Only treat it as ST when we're not in the middle of a
                // multibyte sequence.
                if stringUTF8Remaining > 0 {
                    return nil
                }
                return handleStringTerminator()
            }
            return nil
        default:
            break
        }

        // C1 control characters (8-bit) — only in non-string states
        switch byte {
        case C1.CSI.rawValue: // 0x9B — CSI
            return Transition(.clear, .csiEntry)

        case C1.OSC.rawValue: // 0x9D — OSC
            return Transition(.oscStart, .oscString)

        case C1.DCS.rawValue: // 0x90 — DCS
            return Transition(.clear, .dcsEntry)

        case C1.ST.rawValue: // 0x9C — ST (String Terminator)
            return handleStringTerminator()

        case C1.SOS.rawValue, C1.PM.rawValue, C1.APC.rawValue:
            return Transition(.none, .sosPmApcString)

        // Other C1 that map to ESC sequences
        case C1.IND.rawValue:  return Transition(.execute, .ground)
        case C1.NEL.rawValue:  return Transition(.execute, .ground)
        case C1.HTS.rawValue:  return Transition(.execute, .ground)
        case C1.RI.rawValue:   return Transition(.execute, .ground)

        default:
            return nil
        }
    }

    // MARK: - State Transition Table (Precomputed)

    /// Reference to the precomputed flat transition table.
    private let transitionTable = VTParserTables.shared.flatTable

    /// Look up the transition for a given state and input byte.
    /// Uses a flat packed array for O(1) lookup with no dictionary hashing.
    @inline(__always)
    private func stateTransition(state: ParserState, byte: UInt8) -> Transition {
        let packed = transitionTable[Int(state.rawValue) &* 256 &+ Int(byte)]
        let action = ParserAction(rawValue: UInt8(packed >> 8)) ?? .none
        let nextState = ParserState(rawValue: UInt8(packed & 0xFF)) ?? .ground
        return Transition(action, nextState)
    }

    // MARK: - String Terminator Helper

    private func handleStringTerminator() -> Transition {
        switch state {
        case .oscString:
            return Transition(.oscEnd, .ground)
        case .dcsPassthrough:
            return Transition(.dcsUnhook, .ground)
        default:
            return Transition(.none, .ground)
        }
    }

    // MARK: - Action Execution

    /// Execute a parser action. This is where the parser drives the grid.
    private func executeAction(_ action: ParserAction, byte: UInt8) async {
        switch action {
        case .none:
            break

        case .print:
            await handlePrint(byte)

        case .execute:
            await handleExecute(byte)

        case .clear:
            clearParams()

        case .collect:
            handleCollect(byte)

        case .param:
            handleParam(byte)

        case .escDispatch:
            await handleEscDispatch(byte)

        case .csiDispatch:
            await handleCSIDispatch(byte)

        case .oscStart:
            oscString.removeAll(keepingCapacity: true)
            stringUTF8Remaining = 0
            if Self.debugLogging {
                Self.parserLog.debug("OSC START (state was \(String(describing: self.state)))")
            }

        case .oscPut:
            if oscString.count < ParserLimits.maxOSCLength {
                oscString.append(byte)
            }
            updateStringUTF8State(with: byte)

        case .oscEnd:
            if Self.debugLogging {
                let count = self.oscString.count
                let preview = String(bytes: self.oscString.prefix(80), encoding: .utf8) ?? "<binary>"
                Self.parserLog.debug("OSC END — dispatching \(count) bytes: \(preview)")
            }
            await handleOSCDispatch()
            stringUTF8Remaining = 0

        case .dcsHook:
            dcsData.removeAll(keepingCapacity: true)
            stringUTF8Remaining = 0
            // Save params/intermediates at hook time for DCS dispatch
            dcsParams = params
            dcsIntermediates = intermediates

        case .dcsPut:
            if dcsData.count < ParserLimits.maxDCSLength {
                dcsData.append(byte)
            }
            updateStringUTF8State(with: byte)

        case .dcsUnhook:
            await handleDCSDispatch()
            stringUTF8Remaining = 0

        case .put:
            // Generic put for passthrough modes
            break
        }
    }

    // MARK: - Print Handler (with UTF-8 decoding — A.8.5)

    /// Handle a printable byte. Starts UTF-8 multibyte decoding if needed.
    private func handlePrint(_ byte: UInt8) async {
        if byte < 0x80 {
            // ASCII — print directly, applying charset mapping via CharsetHandler
            let cs = await grid.charsetState()
            let ch = CharsetHandler.mapCharacter(byte, charsetState: cs)
            await grid.printCharacter(ch)
        } else if byte & 0xE0 == 0xC0 {
            // 2-byte UTF-8 sequence start
            utf8Buffer = [byte]
            utf8Remaining = 1
            utf8Expected = 2
        } else if byte & 0xF0 == 0xE0 {
            // 3-byte UTF-8 sequence start
            utf8Buffer = [byte]
            utf8Remaining = 2
            utf8Expected = 3
        } else if byte & 0xF8 == 0xF0 {
            // 4-byte UTF-8 sequence start
            utf8Buffer = [byte]
            utf8Remaining = 3
            utf8Expected = 4
        } else {
            // Invalid start byte — print replacement character
            await grid.printCharacter("\u{FFFD}")
        }
    }

    /// Flush a completed UTF-8 sequence and print the resulting character.
    private func flushUTF8() async {
        if Self.debugLogging {
            if let preview = String(bytes: utf8Buffer, encoding: .utf8) {
                let pos = await grid.cursorPosition()
                Self.parserLog.debug("PRINT UTF-8 '\(preview)' at (\(pos.row),\(pos.col)) state=\(String(describing: self.state))")
            }
        }
        if let str = String(bytes: utf8Buffer, encoding: .utf8),
           let ch = str.first {
            await grid.printCharacter(ch)
        } else {
            // Invalid UTF-8 — print replacement character
            await grid.printCharacter("\u{FFFD}")
        }
        resetUTF8()
    }

    /// Reset the UTF-8 decoder state.
    private func resetUTF8() {
        utf8Buffer.removeAll(keepingCapacity: true)
        utf8Remaining = 0
        utf8Expected = 0
    }

    // MARK: - Parameter Collection

    /// Handle a parameter byte (digit, semicolon, colon).
    private func handleParam(_ byte: UInt8) {
        switch byte {
        case 0x30...0x39: // '0'–'9'
            let digit = Int(byte - 0x30)
            currentParam = min(currentParam * 10 + digit, ParserLimits.maxParamValue)
            hasCurrentParam = true

        case 0x3B: // ';' — top-level parameter separator
            finalizeCurrentParam()
            inSubparam = false

        case 0x3A: // ':' — subparameter separator
            finalizeSubparam()

        case 0x3C...0x3F: // '<', '=', '>', '?' — private marker
            privateMarker = byte

        default:
            break
        }
    }

    /// Finalize the current value and append it as a subparam to the current group,
    /// then start a new subparam value within the same group.
    private func finalizeSubparam() {
        if inSubparam {
            // Already in a subparam group — append to the current group
            if var lastGroup = params.last {
                lastGroup.append(hasCurrentParam ? currentParam : ParserLimits.defaultParam)
                params[params.count - 1] = lastGroup
            }
        } else {
            // First colon — finalize as a new top-level group, then mark as subparam mode
            if params.count < ParserLimits.maxParams {
                params.append([hasCurrentParam ? currentParam : ParserLimits.defaultParam])
            }
            inSubparam = true
        }
        currentParam = 0
        hasCurrentParam = false
    }

    /// Finalize the current parameter and start a new one.
    private func finalizeCurrentParam() {
        let value = hasCurrentParam ? currentParam : ParserLimits.defaultParam
        if inSubparam {
            // We're in a subparam group — append the value to the last group
            if var lastGroup = params.last {
                lastGroup.append(value)
                params[params.count - 1] = lastGroup
            }
        } else {
            // Normal top-level parameter
            if params.count < ParserLimits.maxParams {
                params.append([value])
            }
        }
        currentParam = 0
        hasCurrentParam = false
        inSubparam = false
    }

    /// Clear all collected parameters and intermediates.
    private func clearParams() {
        params.removeAll(keepingCapacity: true)
        currentParam = 0
        hasCurrentParam = false
        inSubparam = false
        privateMarker = 0
        intermediates.removeAll(keepingCapacity: true)
    }

    // MARK: - Intermediate Collection

    /// Collect an intermediate byte.
    private func handleCollect(_ byte: UInt8) {
        // In CSI entry state, '?' etc. are private markers, not intermediates
        if state == .csiEntry && byte >= 0x3C && byte <= 0x3F {
            privateMarker = byte
        } else if intermediates.count < ParserLimits.maxIntermediates {
            intermediates.append(byte)
        }
    }

    // MARK: - C0 Control Execution

    /// Execute a C0 control character.
    private func handleExecute(_ byte: UInt8) async {
        // Also handle C1 8-bit controls that map to actions
        switch byte {
        case C0.BEL.rawValue:
            await handleBell()
        case C0.BS.rawValue:
            await grid.backspace()
        case C0.HT.rawValue:
            await grid.tabForward()
        case C0.LF.rawValue, C0.VT.rawValue, C0.FF.rawValue:
            await grid.lineFeed()
        case C0.CR.rawValue:
            if Self.debugLogging {
                let pos = await grid.cursorPosition()
                Self.parserLog.debug("CR executed — cursor at (\(pos.row),\(pos.col)), moving to col 0")
            }
            await grid.carriageReturn()
        case C0.SO.rawValue: // Shift Out — activate G1
            await CharsetHandler.invoke(1, grid: grid)
        case C0.SI.rawValue: // Shift In — activate G0
            await CharsetHandler.invoke(0, grid: grid)
        case C0.SUB.rawValue: // Substitute — abort sequence, print ⌧
            await grid.printCharacter("\u{2327}")
        case C1.IND.rawValue:
            await grid.index()
        case C1.NEL.rawValue:
            await grid.carriageReturn()
            await grid.index()
        case C1.HTS.rawValue:
            await grid.setTabStop()
        case C1.RI.rawValue:
            await grid.reverseIndex()
        default:
            break // Ignore other C0 controls
        }
    }

    /// Handle BEL (0x07). Increments a bell counter on the grid, which
    /// SessionManager reads each frame to trigger visual/haptic/audio feedback.
    private func handleBell() async {
        await grid.ringBell()
    }

    // MARK: - ESC Dispatch → ESCHandler (A.15)

    /// Dispatch an ESC sequence via ESCHandler.
    /// Special case: ESC `\` (0x5C) is the 7-bit String Terminator (ST).
    /// If we arrived here from an oscString or dcsPassthrough state,
    /// dispatch the accumulated string data instead of forwarding to ESCHandler.
    private func handleEscDispatch(_ byte: UInt8) async {
        if byte == 0x5C { // backslash — potential 7-bit ST
            switch stateBeforeEscape {
            case .oscString:
                await handleOSCDispatch()
                stringUTF8Remaining = 0
                stateBeforeEscape = .ground
                return
            case .dcsPassthrough:
                await handleDCSDispatch()
                stringUTF8Remaining = 0
                stateBeforeEscape = .ground
                return
            default:
                break
            }
        }

        await ESCHandler.dispatch(
            byte: byte,
            intermediates: intermediates,
            grid: grid,
            inputModeState: inputModeState
        )
        stateBeforeEscape = .ground
    }

    /// Track UTF-8 lead/continuation bytes while collecting OSC/DCS strings.
    /// This lets us distinguish real C1 ST (0x9C) from continuation bytes.
    private func updateStringUTF8State(with byte: UInt8) {
        if stringUTF8Remaining > 0 {
            if (0x80...0xBF).contains(byte) {
                stringUTF8Remaining -= 1
                return
            }
            // Invalid continuation; reset and re-evaluate as a potential lead.
            stringUTF8Remaining = 0
        }

        switch byte {
        case 0xC2...0xDF:
            stringUTF8Remaining = 1
        case 0xE0...0xEF:
            stringUTF8Remaining = 2
        case 0xF0...0xF4:
            stringUTF8Remaining = 3
        default:
            stringUTF8Remaining = 0
        }
    }

    // MARK: - CSI Dispatch → CSIHandler (A.10)

    /// Dispatch a CSI sequence. Finalizes parameters, then delegates to CSIHandler.
    private func handleCSIDispatch(_ byte: UInt8) async {
        // Finalize the last parameter being collected
        if hasCurrentParam || !params.isEmpty {
            finalizeCurrentParam()
        }

        if Self.debugLogging {
            let ch = Character(UnicodeScalar(byte))
            let pos = await grid.cursorPosition()
            let marker = privateMarker > 0 ? String(Character(UnicodeScalar(privateMarker))) : ""
            Self.parserLog.debug("CSI \(marker)\(self.params) \(ch) at (\(pos.row),\(pos.col))")
        }

        await CSIHandler.dispatch(
            byte: byte,
            params: params,
            privateMarker: privateMarker,
            intermediates: intermediates,
            grid: grid,
            responseHandler: responseHandler,
            inputModeState: inputModeState
        )
    }

    // MARK: - OSC Dispatch → OSCHandler (A.13)

    /// Dispatch a collected OSC string via OSCHandler.
    private func handleOSCDispatch() async {
        await OSCHandler.dispatch(
            oscString: oscString,
            grid: grid,
            responseHandler: responseHandler
        )
    }

    // MARK: - DCS Dispatch → DCSHandler (A.14)

    /// Dispatch collected DCS data via DCSHandler.
    private func handleDCSDispatch() async {
        await DCSHandler.unhook(
            data: dcsData,
            params: dcsParams,
            intermediates: dcsIntermediates,
            grid: grid,
            responseHandler: responseHandler
        )
    }

    // MARK: - Response Handler

    /// Send a response back through the SSH channel.
    private var responseHandler: (@Sendable ([UInt8]) async -> Void)?

    /// Set the handler for sending responses back to the remote host.
    func setResponseHandler(_ handler: @escaping @Sendable ([UInt8]) async -> Void) {
        self.responseHandler = handler
    }

    /// Set an optional mode tracker and initialize it from current grid state.
    func setInputModeState(_ state: InputModeState?) async {
        inputModeState = state
        if let state {
            await state.syncFromGrid(grid)
        }
    }
}

// MARK: - Transition Type

/// A state machine transition: action to perform + next state.
nonisolated private struct Transition {
    let action: ParserAction
    let nextState: ParserState

    init(_ action: ParserAction, _ nextState: ParserState) {
        self.action = action
        self.nextState = nextState
    }
}
