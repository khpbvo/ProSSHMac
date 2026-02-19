// VTParserTables.swift
// ProSSHV2
//
// Precomputed 256-entry lookup tables per parser state.
// Auto-generated at init time from the VT500 state machine byte range rules.
// Each table maps an input byte (0x00–0xFF) to a (ParserAction, ParserState) pair.
//
// Using tables instead of switch statements gives O(1) lookup per byte
// with no branch misprediction — critical for parsing throughput at 120fps.

import Foundation

// MARK: - Table Entry

/// A single entry in a parser transition table: action + next state.
nonisolated struct VTTransition: Sendable {
    let action: ParserAction
    let nextState: ParserState

    static let none = VTTransition(action: .none, nextState: .ground)
}

// MARK: - VTParserTables

/// Precomputed state transition tables for the VT parser.
/// Call `VTParserTables.shared` to access the singleton with all tables generated.
nonisolated struct VTParserTables: Sendable {

    /// Singleton instance with all tables generated at first access.
    static let shared = VTParserTables()

    /// Number of parser states (rawValue 0..<stateCount).
    private static let stateCount = 14

    /// Flat packed transition table: stateCount * 256 entries.
    /// Each UInt16 packs action (high byte) | nextState (low byte).
    /// Indexed as: flatTable[state.rawValue * 256 + byte]
    let flatTable: ContiguousArray<UInt16>

    /// All parser states in order.
    private static let allStates: [ParserState] = [
        .ground, .escape, .escapeIntermediate,
        .csiEntry, .csiParam, .csiIntermediate, .csiIgnore,
        .dcsEntry, .dcsParam, .dcsIntermediate, .dcsPassthrough, .dcsIgnore,
        .oscString, .sosPmApcString
    ]

    // MARK: - Initialization (Auto-Generation)

    private init() {
        var flat = ContiguousArray<UInt16>(repeating: 0, count: VTParserTables.stateCount * 256)
        for state in VTParserTables.allStates {
            let table = VTParserTables.generateTable(for: state)
            let base = Int(state.rawValue) * 256
            for byte in 0..<256 {
                let t = table[byte]
                flat[base + byte] = UInt16(t.action.rawValue) << 8 | UInt16(t.nextState.rawValue)
            }
        }
        self.flatTable = flat
    }

    /// Look up the transition for a given state and byte.
    /// Returns action and nextState unpacked from the flat table.
    @inline(__always)
    func transition(state: ParserState, byte: UInt8) -> (action: ParserAction, nextState: ParserState) {
        let packed = flatTable[Int(state.rawValue) &* 256 &+ Int(byte)]
        let action = ParserAction(rawValue: UInt8(packed >> 8)) ?? .none
        let nextState = ParserState(rawValue: UInt8(packed & 0xFF)) ?? .ground
        return (action, nextState)
    }

    // MARK: - Table Generation

    /// Generate a 256-entry table for a single parser state.
    /// Based on the VT500 state machine byte range rules from the spec.
    private static func generateTable(for state: ParserState) -> [VTTransition] {
        var table = [VTTransition](repeating: .none, count: 256)

        switch state {
        case .ground:
            generateGround(&table)
        case .escape:
            generateEscape(&table)
        case .escapeIntermediate:
            generateEscapeIntermediate(&table)
        case .csiEntry:
            generateCSIEntry(&table)
        case .csiParam:
            generateCSIParam(&table)
        case .csiIntermediate:
            generateCSIIntermediate(&table)
        case .csiIgnore:
            generateCSIIgnore(&table)
        case .dcsEntry:
            generateDCSEntry(&table)
        case .dcsParam:
            generateDCSParam(&table)
        case .dcsIntermediate:
            generateDCSIntermediate(&table)
        case .dcsPassthrough:
            generateDCSPassthrough(&table)
        case .dcsIgnore:
            generateDCSIgnore(&table)
        case .oscString:
            generateOSCString(&table)
        case .sosPmApcString:
            generateSosPmApc(&table)
        }

        return table
    }

    // MARK: - Helper

    private static func set(_ table: inout [VTTransition],
                            range: ClosedRange<UInt8>,
                            action: ParserAction, next: ParserState) {
        for byte in range {
            table[Int(byte)] = VTTransition(action: action, nextState: next)
        }
    }

    private static func set(_ table: inout [VTTransition],
                            byte: UInt8,
                            action: ParserAction, next: ParserState) {
        table[Int(byte)] = VTTransition(action: action, nextState: next)
    }

    // MARK: - Ground State

    private static func generateGround(_ table: inout [VTTransition]) {
        // C0 controls: execute
        set(&table, range: 0x00...0x17, action: .execute, next: .ground)
        set(&table, byte: 0x19, action: .execute, next: .ground)
        set(&table, range: 0x1C...0x1F, action: .execute, next: .ground)

        // Printable ASCII
        set(&table, range: 0x20...0x7E, action: .print, next: .ground)

        // DEL: ignored
        set(&table, byte: 0x7F, action: .none, next: .ground)

        // High bytes: print (UTF-8 start bytes or Latin-1)
        set(&table, range: 0xA0...0xFF, action: .print, next: .ground)
    }

    // MARK: - Escape State

    private static func generateEscape(_ table: inout [VTTransition]) {
        // C0 controls: execute
        set(&table, range: 0x00...0x17, action: .execute, next: .escape)
        set(&table, byte: 0x19, action: .execute, next: .escape)
        set(&table, range: 0x1C...0x1F, action: .execute, next: .escape)

        // Intermediate bytes → escapeIntermediate
        set(&table, range: 0x20...0x2F, action: .collect, next: .escapeIntermediate)

        // Dispatch bytes (most 0x30–0x7E)
        set(&table, range: 0x30...0x4F, action: .escDispatch, next: .ground)
        // 0x50 = 'P' → DCS
        set(&table, byte: 0x50, action: .clear, next: .dcsEntry)
        set(&table, range: 0x51...0x57, action: .escDispatch, next: .ground)
        // 0x58 = 'X' → SOS
        set(&table, byte: 0x58, action: .none, next: .sosPmApcString)
        set(&table, byte: 0x59, action: .escDispatch, next: .ground)
        set(&table, byte: 0x5A, action: .escDispatch, next: .ground)
        // 0x5B = '[' → CSI
        set(&table, byte: 0x5B, action: .clear, next: .csiEntry)
        set(&table, byte: 0x5C, action: .escDispatch, next: .ground) // '\' = ST
        // 0x5D = ']' → OSC
        set(&table, byte: 0x5D, action: .oscStart, next: .oscString)
        // 0x5E = '^' → PM
        set(&table, byte: 0x5E, action: .none, next: .sosPmApcString)
        // 0x5F = '_' → APC
        set(&table, byte: 0x5F, action: .none, next: .sosPmApcString)
        set(&table, range: 0x60...0x7E, action: .escDispatch, next: .ground)

        // DEL: ignored
        set(&table, byte: 0x7F, action: .none, next: .escape)
    }

    // MARK: - Escape Intermediate State

    private static func generateEscapeIntermediate(_ table: inout [VTTransition]) {
        set(&table, range: 0x00...0x17, action: .execute, next: .escapeIntermediate)
        set(&table, byte: 0x19, action: .execute, next: .escapeIntermediate)
        set(&table, range: 0x1C...0x1F, action: .execute, next: .escapeIntermediate)
        set(&table, range: 0x20...0x2F, action: .collect, next: .escapeIntermediate)
        set(&table, range: 0x30...0x7E, action: .escDispatch, next: .ground)
        set(&table, byte: 0x7F, action: .none, next: .escapeIntermediate)
    }

    // MARK: - CSI Entry State

    private static func generateCSIEntry(_ table: inout [VTTransition]) {
        set(&table, range: 0x00...0x17, action: .execute, next: .csiEntry)
        set(&table, byte: 0x19, action: .execute, next: .csiEntry)
        set(&table, range: 0x1C...0x1F, action: .execute, next: .csiEntry)
        set(&table, range: 0x20...0x2F, action: .collect, next: .csiIntermediate)
        // Digits and ';' start param collection
        set(&table, range: 0x30...0x39, action: .param, next: .csiParam)
        set(&table, byte: 0x3A, action: .param, next: .csiParam)  // ':'
        set(&table, byte: 0x3B, action: .param, next: .csiParam)  // ';'
        // Private markers
        set(&table, range: 0x3C...0x3F, action: .collect, next: .csiParam)
        // Final bytes → dispatch
        set(&table, range: 0x40...0x7E, action: .csiDispatch, next: .ground)
        set(&table, byte: 0x7F, action: .none, next: .csiEntry)
    }

    // MARK: - CSI Param State

    private static func generateCSIParam(_ table: inout [VTTransition]) {
        set(&table, range: 0x00...0x17, action: .execute, next: .csiParam)
        set(&table, byte: 0x19, action: .execute, next: .csiParam)
        set(&table, range: 0x1C...0x1F, action: .execute, next: .csiParam)
        set(&table, range: 0x20...0x2F, action: .collect, next: .csiIntermediate)
        // Continue collecting params
        set(&table, range: 0x30...0x39, action: .param, next: .csiParam)
        set(&table, byte: 0x3A, action: .param, next: .csiParam)
        set(&table, byte: 0x3B, action: .param, next: .csiParam)
        // Invalid: private marker in param state
        set(&table, range: 0x3C...0x3F, action: .none, next: .csiIgnore)
        // Final bytes → dispatch
        set(&table, range: 0x40...0x7E, action: .csiDispatch, next: .ground)
        set(&table, byte: 0x7F, action: .none, next: .csiParam)
    }

    // MARK: - CSI Intermediate State

    private static func generateCSIIntermediate(_ table: inout [VTTransition]) {
        set(&table, range: 0x00...0x17, action: .execute, next: .csiIntermediate)
        set(&table, byte: 0x19, action: .execute, next: .csiIntermediate)
        set(&table, range: 0x1C...0x1F, action: .execute, next: .csiIntermediate)
        set(&table, range: 0x20...0x2F, action: .collect, next: .csiIntermediate)
        // Invalid: param bytes after intermediate
        set(&table, range: 0x30...0x3F, action: .none, next: .csiIgnore)
        // Final bytes → dispatch
        set(&table, range: 0x40...0x7E, action: .csiDispatch, next: .ground)
        set(&table, byte: 0x7F, action: .none, next: .csiIntermediate)
    }

    // MARK: - CSI Ignore State

    private static func generateCSIIgnore(_ table: inout [VTTransition]) {
        set(&table, range: 0x00...0x17, action: .execute, next: .csiIgnore)
        set(&table, byte: 0x19, action: .execute, next: .csiIgnore)
        set(&table, range: 0x1C...0x1F, action: .execute, next: .csiIgnore)
        set(&table, range: 0x20...0x3F, action: .none, next: .csiIgnore)
        // Final byte exits
        set(&table, range: 0x40...0x7E, action: .none, next: .ground)
        set(&table, byte: 0x7F, action: .none, next: .csiIgnore)
    }

    // MARK: - DCS Entry State

    private static func generateDCSEntry(_ table: inout [VTTransition]) {
        set(&table, range: 0x00...0x17, action: .none, next: .dcsEntry)
        set(&table, byte: 0x19, action: .none, next: .dcsEntry)
        set(&table, range: 0x1C...0x1F, action: .none, next: .dcsEntry)
        set(&table, range: 0x20...0x2F, action: .collect, next: .dcsIntermediate)
        set(&table, range: 0x30...0x39, action: .param, next: .dcsParam)
        set(&table, byte: 0x3A, action: .none, next: .dcsIgnore)
        set(&table, byte: 0x3B, action: .param, next: .dcsParam)
        set(&table, range: 0x3C...0x3F, action: .collect, next: .dcsParam)
        set(&table, range: 0x40...0x7E, action: .dcsHook, next: .dcsPassthrough)
        set(&table, byte: 0x7F, action: .none, next: .dcsEntry)
    }

    // MARK: - DCS Param State

    private static func generateDCSParam(_ table: inout [VTTransition]) {
        set(&table, range: 0x00...0x17, action: .none, next: .dcsParam)
        set(&table, byte: 0x19, action: .none, next: .dcsParam)
        set(&table, range: 0x1C...0x1F, action: .none, next: .dcsParam)
        set(&table, range: 0x20...0x2F, action: .collect, next: .dcsIntermediate)
        set(&table, range: 0x30...0x39, action: .param, next: .dcsParam)
        set(&table, byte: 0x3A, action: .none, next: .dcsIgnore)
        set(&table, byte: 0x3B, action: .param, next: .dcsParam)
        set(&table, range: 0x3C...0x3F, action: .none, next: .dcsIgnore)
        set(&table, range: 0x40...0x7E, action: .dcsHook, next: .dcsPassthrough)
        set(&table, byte: 0x7F, action: .none, next: .dcsParam)
    }

    // MARK: - DCS Intermediate State

    private static func generateDCSIntermediate(_ table: inout [VTTransition]) {
        set(&table, range: 0x00...0x17, action: .none, next: .dcsIntermediate)
        set(&table, byte: 0x19, action: .none, next: .dcsIntermediate)
        set(&table, range: 0x1C...0x1F, action: .none, next: .dcsIntermediate)
        set(&table, range: 0x20...0x2F, action: .collect, next: .dcsIntermediate)
        set(&table, range: 0x30...0x3F, action: .none, next: .dcsIgnore)
        set(&table, range: 0x40...0x7E, action: .dcsHook, next: .dcsPassthrough)
        set(&table, byte: 0x7F, action: .none, next: .dcsIntermediate)
    }

    // MARK: - DCS Passthrough State

    private static func generateDCSPassthrough(_ table: inout [VTTransition]) {
        // C0 controls: put
        set(&table, range: 0x00...0x17, action: .put, next: .dcsPassthrough)
        set(&table, byte: 0x19, action: .put, next: .dcsPassthrough)
        set(&table, range: 0x1C...0x1F, action: .put, next: .dcsPassthrough)
        // Printable: dcsPut
        set(&table, range: 0x20...0x7E, action: .dcsPut, next: .dcsPassthrough)
        set(&table, byte: 0x7F, action: .none, next: .dcsPassthrough)
        // 0x80-0x9F: Collect for UTF-8 support. Actual C1 controls (ST etc.)
        // are intercepted by anywhereTransition before reaching this table.
        set(&table, range: 0x80...0x9F, action: .dcsPut, next: .dcsPassthrough)
        // High bytes: pass through
        set(&table, range: 0xA0...0xFF, action: .dcsPut, next: .dcsPassthrough)
    }

    // MARK: - DCS Ignore State

    private static func generateDCSIgnore(_ table: inout [VTTransition]) {
        // Everything is consumed/ignored except ST
        set(&table, range: 0x00...0x7F, action: .none, next: .dcsIgnore)
        set(&table, range: 0x80...0x9B, action: .none, next: .dcsIgnore)
        set(&table, byte: 0x9C, action: .none, next: .ground) // ST
        set(&table, range: 0x9D...0xFF, action: .none, next: .dcsIgnore)
    }

    // MARK: - OSC String State

    private static func generateOSCString(_ table: inout [VTTransition]) {
        // Ignore most C0 controls
        set(&table, range: 0x00...0x06, action: .none, next: .oscString)
        // BEL terminates OSC (xterm extension)
        set(&table, byte: 0x07, action: .oscEnd, next: .ground)
        set(&table, range: 0x08...0x17, action: .none, next: .oscString)
        set(&table, byte: 0x19, action: .none, next: .oscString)
        set(&table, range: 0x1C...0x1F, action: .none, next: .oscString)
        // Printable bytes are collected
        set(&table, range: 0x20...0x7F, action: .oscPut, next: .oscString)
        // 0x80-0x9F: Collect as part of the OSC string to support UTF-8
        // continuation bytes (0x80-0xBF). Actual C1 controls (ST, CSI, etc.)
        // are intercepted by anywhereTransition before reaching this table.
        set(&table, range: 0x80...0x9F, action: .oscPut, next: .oscString)
        // High bytes also collected (UTF-8 in OSC strings)
        set(&table, range: 0xA0...0xFF, action: .oscPut, next: .oscString)
    }

    // MARK: - SOS/PM/APC String State

    private static func generateSosPmApc(_ table: inout [VTTransition]) {
        // Consume everything until ST
        set(&table, range: 0x00...0x7F, action: .none, next: .sosPmApcString)
        set(&table, range: 0x80...0x9B, action: .none, next: .sosPmApcString)
        set(&table, byte: 0x9C, action: .none, next: .ground) // ST
        set(&table, range: 0x9D...0xFF, action: .none, next: .sosPmApcString)
    }
}
