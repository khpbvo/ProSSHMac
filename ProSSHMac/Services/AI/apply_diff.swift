// apply_diff.swift
// Swift port of docs/apply_diff.py — V4A diff format parser and applier
//
// Ported from docs/apply_diff.py.
// Handles both "create" and "update" diff modes for the V4A diff format
// used by the ProSSHMac AI agent apply_patch tool.
//
// Public API: applyDiff(input:diff:mode:) throws -> String

import Foundation

// MARK: - Public Types

enum V4ADiffMode {
    /// Normal update mode — includes context hunks that must match the original.
    case `default`
    /// Create-file mode — diff contains only "+" prefixed lines.
    case create
}

// MARK: - Errors

enum V4ADiffError: LocalizedError, Sendable {
    case invalidAddFileLine(String)
    case invalidLine(String)
    case invalidContext(cursor: Int, context: String)
    case invalidEOFContext(cursor: Int, context: String)
    case emptySection(index: Int, nextLine: String)
    case chunkOutOfBounds(origIndex: Int, inputLength: Int)
    case overlappingChunk(origIndex: Int, cursor: Int)

    var errorDescription: String? {
        switch self {
        case .invalidAddFileLine(let line):
            return "Invalid Add File Line: \(line)"
        case .invalidLine(let line):
            return "Invalid Line:\n\(line)"
        case .invalidContext(let cursor, let context):
            return "Invalid Context \(cursor):\n\(context)"
        case .invalidEOFContext(let cursor, let context):
            return "Invalid EOF Context \(cursor):\n\(context)"
        case .emptySection(let index, let nextLine):
            return "Nothing in this section - index=\(index) \(nextLine)"
        case .chunkOutOfBounds(let origIndex, let inputLength):
            return "applyDiff: chunk.origIndex \(origIndex) > input length \(inputLength)"
        case .overlappingChunk(let origIndex, let cursor):
            return "applyDiff: overlapping chunk at \(origIndex) (cursor \(cursor))"
        }
    }
}

// MARK: - Public Entry Point

/// Apply a V4A diff to the provided text.
///
/// This parser understands both the create-file syntax (only "+" prefixed
/// lines) and the default update syntax that includes context hunks.
///
/// - Parameters:
///   - input: The original file content (empty for new files in create mode).
///   - diff: The V4A diff string.
///   - mode: `.default` for update diffs, `.create` for new-file diffs.
/// - Returns: The patched file content with newlines restored to match the original.
func applyDiff(input: String, diff: String, mode: V4ADiffMode = .default) throws -> String {
    let newline = v4aDetectNewline(input: input, diff: diff, mode: mode)
    let diffLines = v4aNormalizeDiffLines(diff)

    if mode == .create {
        return try v4aParseCreateDiff(lines: diffLines, newline: newline)
    }

    let normalizedInput = v4aNormalizeTextNewlines(input)
    let parsed = try v4aParseUpdateDiff(lines: diffLines, input: normalizedInput)
    return try v4aApplyChunks(input: normalizedInput, chunks: parsed.chunks, newline: newline)
}

// MARK: - Internal Data Structures

private struct V4AChunk {
    var origIndex: Int
    var delLines: [String]
    var insLines: [String]
}

private struct V4AParsedUpdate {
    var chunks: [V4AChunk]
    var fuzz: Int
}

private struct V4AReadSectionResult {
    var nextContext: [String]
    var sectionChunks: [V4AChunk]
    var endIndex: Int
    var eof: Bool
}

private struct V4AContextMatch {
    var newIndex: Int
    var fuzz: Int
}

// MARK: - Parser State

/// Mutable parser state — uses a class so it can be shared and mutated
/// across helper functions without inout threading through every call site.
private final class V4AParserState {
    var lines: [String]
    var index: Int
    var fuzz: Int

    init(lines: [String], index: Int = 0, fuzz: Int = 0) {
        self.lines = lines
        self.index = index
        self.fuzz = fuzz
    }
}

// MARK: - Constants

private let kV4AEndPatch = "*** End Patch"
private let kV4AEndFile  = "*** End of File"
private let kV4ASectionTerminators = [
    kV4AEndPatch,
    "*** Update File:",
    "*** Delete File:",
    "*** Add File:",
]
private let kV4AEndSectionMarkers = kV4ASectionTerminators + [kV4AEndFile]

// MARK: - Normalization Helpers

private func v4aNormalizeDiffLines(_ diff: String) -> [String] {
    // Split on \n, strip trailing \r from each line (handles both \r\n and \n).
    var lines = diff.components(separatedBy: "\n").map { line -> String in
        line.hasSuffix("\r") ? String(line.dropLast()) : line
    }
    if lines.last == "" {
        lines.removeLast()
    }
    return lines
}

private func v4aDetectNewlineFromText(_ text: String) -> String {
    return text.contains("\r\n") ? "\r\n" : "\n"
}

private func v4aDetectNewline(input: String, diff: String, mode: V4ADiffMode) -> String {
    // Create-file diffs have no input to infer from; use the diff's style.
    if mode != .create && input.contains("\n") {
        return v4aDetectNewlineFromText(input)
    }
    return v4aDetectNewlineFromText(diff)
}

private func v4aNormalizeTextNewlines(_ text: String) -> String {
    // Normalize CRLF → LF for parsing/matching. Restored when emitting.
    return text.replacingOccurrences(of: "\r\n", with: "\n")
}

// MARK: - Parser Helpers

private func v4aIsDone(_ state: V4AParserState, prefixes: [String]) -> Bool {
    if state.index >= state.lines.count { return true }
    let current = state.lines[state.index]
    return prefixes.contains { current.hasPrefix($0) }
}

/// Attempt to read a line with the given prefix, advancing the parser index.
/// Returns the line content after the prefix, or "" if the line doesn't start
/// with `prefix` (index is NOT advanced in that case).
@discardableResult
private func v4aReadStr(_ state: V4AParserState, prefix: String) -> String {
    guard state.index < state.lines.count else { return "" }
    let current = state.lines[state.index]
    guard current.hasPrefix(prefix) else { return "" }
    state.index += 1
    return String(current.dropFirst(prefix.count))
}

// MARK: - Create Mode

private func v4aParseCreateDiff(lines: [String], newline: String) throws -> String {
    let parser = V4AParserState(lines: lines + [kV4AEndPatch])
    var output: [String] = []

    while !v4aIsDone(parser, prefixes: kV4ASectionTerminators) {
        guard parser.index < parser.lines.count else { break }
        let line = parser.lines[parser.index]
        parser.index += 1
        guard line.hasPrefix("+") else {
            throw V4ADiffError.invalidAddFileLine(line)
        }
        output.append(String(line.dropFirst()))
    }

    return output.joined(separator: newline)
}

// MARK: - Update Mode

private func v4aParseUpdateDiff(lines: [String], input: String) throws -> V4AParsedUpdate {
    let parser = V4AParserState(lines: lines + [kV4AEndPatch])
    let inputLines = input.components(separatedBy: "\n")
    var chunks: [V4AChunk] = []
    var cursor = 0

    while !v4aIsDone(parser, prefixes: kV4AEndSectionMarkers) {
        let anchor = v4aReadStr(parser, prefix: "@@ ")

        // Support bare "@@ " (no content after the marker)
        let hasBareAnchor = anchor == ""
            && parser.index < parser.lines.count
            && parser.lines[parser.index] == "@@"
        if hasBareAnchor {
            parser.index += 1
        }

        // Must have an anchor, bare anchor, or be at the very start of the file
        if !(anchor != "" || hasBareAnchor || cursor == 0) {
            let currentLine = parser.index < parser.lines.count
                ? parser.lines[parser.index]
                : ""
            throw V4ADiffError.invalidLine(currentLine)
        }

        // Non-empty anchor: advance cursor to the anchor line in the input
        if !anchor.trimmingCharacters(in: .whitespaces).isEmpty {
            cursor = v4aAdvanceCursorToAnchor(
                anchor: anchor,
                inputLines: inputLines,
                cursor: cursor,
                parser: parser
            )
        }

        let section = try v4aReadSection(lines: parser.lines, startIndex: parser.index)
        let findResult = v4aFindContext(
            lines: inputLines,
            context: section.nextContext,
            start: cursor,
            eof: section.eof
        )

        if findResult.newIndex == -1 {
            let ctxText = section.nextContext.joined(separator: "\n")
            if section.eof {
                throw V4ADiffError.invalidEOFContext(cursor: cursor, context: ctxText)
            }
            throw V4ADiffError.invalidContext(cursor: cursor, context: ctxText)
        }

        cursor = findResult.newIndex + section.nextContext.count
        parser.fuzz += findResult.fuzz
        parser.index = section.endIndex

        for ch in section.sectionChunks {
            chunks.append(V4AChunk(
                origIndex: ch.origIndex + findResult.newIndex,
                delLines: ch.delLines,
                insLines: ch.insLines
            ))
        }
    }

    return V4AParsedUpdate(chunks: chunks, fuzz: parser.fuzz)
}

// MARK: - Anchor Advancement

private func v4aAdvanceCursorToAnchor(
    anchor: String,
    inputLines: [String],
    cursor: Int,
    parser: V4AParserState
) -> Int {
    var cursor = cursor

    // Pass 1: exact-string match
    // Only search forward if the anchor hasn't already appeared before the cursor.
    let preceedingLines = inputLines.prefix(cursor)
    if !preceedingLines.contains(anchor) {
        var foundExact = false
        for i in cursor..<inputLines.count where inputLines[i] == anchor {
            cursor = i + 1
            foundExact = true
            break
        }
        if foundExact { return cursor }
    }

    // Pass 2: stripped match (fuzz)
    let anchorStripped = anchor.trimmingCharacters(in: .whitespaces)
    let hasStrippedBefore = preceedingLines.contains {
        $0.trimmingCharacters(in: .whitespaces) == anchorStripped
    }
    if !hasStrippedBefore {
        for i in cursor..<inputLines.count {
            if inputLines[i].trimmingCharacters(in: .whitespaces) == anchorStripped {
                cursor = i + 1
                parser.fuzz += 1
                break
            }
        }
    }

    return cursor
}

// MARK: - Section Reading

private func v4aReadSection(lines: [String], startIndex: Int) throws -> V4AReadSectionResult {
    var context: [String] = []
    var delLines: [String] = []
    var insLines: [String] = []
    var sectionChunks: [V4AChunk] = []

    enum SectionMode { case keep, add, delete }
    var mode: SectionMode = .keep
    var index = startIndex
    let origIndex = startIndex

    while index < lines.count {
        let raw = lines[index]

        // Stop at any section terminator or end-of-file marker
        if raw.hasPrefix("@@")
            || raw.hasPrefix(kV4AEndPatch)
            || raw.hasPrefix("*** Update File:")
            || raw.hasPrefix("*** Delete File:")
            || raw.hasPrefix("*** Add File:")
            || raw.hasPrefix(kV4AEndFile) {
            break
        }
        // Bare "***" is also a terminator
        if raw == "***" { break }
        // Any other "***" prefix is invalid
        if raw.hasPrefix("***") {
            throw V4ADiffError.invalidLine(raw)
        }

        index += 1
        let lastMode = mode

        // Empty lines are treated as a context (space-prefixed) line with empty content
        let line = raw.isEmpty ? " " : raw
        guard let firstChar = line.first else {
            throw V4ADiffError.invalidLine(line)
        }

        switch firstChar {
        case "+": mode = .add
        case "-": mode = .delete
        case " ": mode = .keep
        default:  throw V4ADiffError.invalidLine(String(line))
        }

        let lineContent = String(line.dropFirst())

        // When switching back to context, flush any pending del/ins into a chunk
        let switchingToContext = mode == .keep && lastMode != .keep
        if switchingToContext && (!delLines.isEmpty || !insLines.isEmpty) {
            sectionChunks.append(V4AChunk(
                origIndex: context.count - delLines.count,
                delLines: delLines,
                insLines: insLines
            ))
            delLines = []
            insLines = []
        }

        switch mode {
        case .delete:
            delLines.append(lineContent)
            context.append(lineContent)   // deleted lines count toward context position
        case .add:
            insLines.append(lineContent)  // additions don't advance the original position
        case .keep:
            context.append(lineContent)
        }
    }

    // Flush any remaining pending chunk
    if !delLines.isEmpty || !insLines.isEmpty {
        sectionChunks.append(V4AChunk(
            origIndex: context.count - delLines.count,
            delLines: delLines,
            insLines: insLines
        ))
    }

    // Check for end-of-file marker
    if index < lines.count && lines[index] == kV4AEndFile {
        return V4AReadSectionResult(
            nextContext: context,
            sectionChunks: sectionChunks,
            endIndex: index + 1,
            eof: true
        )
    }

    // A section must consume at least one line
    if index == origIndex {
        let nextLine = index < lines.count ? lines[index] : ""
        throw V4ADiffError.emptySection(index: index, nextLine: nextLine)
    }

    return V4AReadSectionResult(
        nextContext: context,
        sectionChunks: sectionChunks,
        endIndex: index,
        eof: false
    )
}

// MARK: - Context Matching

private func v4aFindContext(
    lines: [String],
    context: [String],
    start: Int,
    eof: Bool
) -> V4AContextMatch {
    if eof {
        // For EOF sections, prefer a match near the end of the file
        let endStart = max(0, lines.count - context.count)
        let endMatch = v4aFindContextCore(lines: lines, context: context, start: endStart)
        if endMatch.newIndex != -1 { return endMatch }
        // Fall back to searching from `start`, but penalize heavily (fuzz +10000)
        let fallback = v4aFindContextCore(lines: lines, context: context, start: start)
        return V4AContextMatch(newIndex: fallback.newIndex, fuzz: fallback.fuzz + 10000)
    }
    return v4aFindContextCore(lines: lines, context: context, start: start)
}

private func v4aFindContextCore(
    lines: [String],
    context: [String],
    start: Int
) -> V4AContextMatch {
    if context.isEmpty {
        return V4AContextMatch(newIndex: start, fuzz: 0)
    }

    // Pass 1: exact match (fuzz = 0)
    for i in start..<lines.count {
        if v4aEqualsSlice(source: lines, target: context, start: i, mapFn: { $0 }) {
            return V4AContextMatch(newIndex: i, fuzz: 0)
        }
    }

    // Pass 2: trailing-whitespace-stripped match (fuzz = 1)
    for i in start..<lines.count {
        if v4aEqualsSlice(source: lines, target: context, start: i, mapFn: v4aRStrip) {
            return V4AContextMatch(newIndex: i, fuzz: 1)
        }
    }

    // Pass 3: full strip match (fuzz = 100)
    for i in start..<lines.count {
        if v4aEqualsSlice(source: lines, target: context, start: i,
                          mapFn: { $0.trimmingCharacters(in: .whitespaces) }) {
            return V4AContextMatch(newIndex: i, fuzz: 100)
        }
    }

    return V4AContextMatch(newIndex: -1, fuzz: 0)
}

/// Check whether `source[start ..< start+target.count]` equals `target`
/// after applying `mapFn` to every element.
private func v4aEqualsSlice(
    source: [String],
    target: [String],
    start: Int,
    mapFn: (String) -> String
) -> Bool {
    guard start + target.count <= source.count else { return false }
    for (offset, targetValue) in target.enumerated() {
        if mapFn(source[start + offset]) != mapFn(targetValue) { return false }
    }
    return true
}

/// Strip trailing whitespace — equivalent to Python's `str.rstrip()`.
private func v4aRStrip(_ s: String) -> String {
    var result = s
    while result.last?.isWhitespace == true {
        result.removeLast()
    }
    return result
}

// MARK: - Apply Chunks

private func v4aApplyChunks(
    input: String,
    chunks: [V4AChunk],
    newline: String
) throws -> String {
    let origLines = input.components(separatedBy: "\n")
    var destLines: [String] = []
    var cursor = 0

    for chunk in chunks {
        guard chunk.origIndex <= origLines.count else {
            throw V4ADiffError.chunkOutOfBounds(
                origIndex: chunk.origIndex,
                inputLength: origLines.count
            )
        }
        guard cursor <= chunk.origIndex else {
            throw V4ADiffError.overlappingChunk(origIndex: chunk.origIndex, cursor: cursor)
        }

        // Copy through unchanged lines before this chunk
        destLines.append(contentsOf: origLines[cursor..<chunk.origIndex])
        cursor = chunk.origIndex

        // Insert added lines (deletions are simply skipped)
        if !chunk.insLines.isEmpty {
            destLines.append(contentsOf: chunk.insLines)
        }

        // Advance past deleted lines
        cursor += chunk.delLines.count
    }

    // Copy any lines after the last chunk
    destLines.append(contentsOf: origLines[cursor...])
    return destLines.joined(separator: newline)
}
