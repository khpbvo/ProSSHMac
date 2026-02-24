// UnifiedDiffPatcher.swift
// Unified diff parser and applier for ProSSHMac AI tool system
//
// Parses standard unified diff format (the kind `diff -u` and `git diff` produce)
// and applies hunks to source text. Used by the apply_patch AI tool to let agents
// modify files through structured diffs rather than raw shell commands.
//
// This is the Swift equivalent of `apply_diff()` from the OpenAI Agents SDK.

import Foundation

// MARK: - Errors

/// Errors that can occur during diff parsing or application.
enum DiffError: LocalizedError, Sendable, Equatable {
    case malformedHunkHeader(String)
    case contextMismatch(hunkIndex: Int, expectedLine: Int, expected: String, actual: String)
    case hunkOutOfBounds(hunkIndex: Int, startLine: Int, totalLines: Int)
    case noHunksFound
    case overlappingHunks(hunkIndex: Int)
    case trailingContent(String)

    var errorDescription: String? {
        switch self {
        case .malformedHunkHeader(let header):
            return "Malformed hunk header: '\(header)'"
        case .contextMismatch(let idx, let line, let expected, let actual):
            return "Hunk \(idx): context mismatch at line \(line) — expected '\(expected)', got '\(actual)'"
        case .hunkOutOfBounds(let idx, let start, let total):
            return "Hunk \(idx): start line \(start) exceeds file length (\(total) lines)"
        case .noHunksFound:
            return "No valid hunks found in diff"
        case .overlappingHunks(let idx):
            return "Hunk \(idx) overlaps with previous hunk"
        case .trailingContent(let content):
            return "Unexpected trailing content after diff: '\(content.prefix(80))'"
        }
    }
}

// MARK: - Parsed Hunk

/// A single hunk from a unified diff.
struct DiffHunk: Sendable, Equatable {
    /// 1-based start line in the original file.
    let originalStart: Int
    /// Number of lines from the original file in this hunk.
    let originalCount: Int
    /// 1-based start line in the modified file.
    let modifiedStart: Int
    /// Number of lines in the modified file after this hunk.
    let modifiedCount: Int
    /// The hunk lines: context (" "), removal ("-"), addition ("+").
    let lines: [HunkLine]
}

/// A single line within a hunk.
enum HunkLine: Sendable, Equatable {
    case context(String)   // " " prefix — unchanged line
    case removal(String)   // "-" prefix — line to remove
    case addition(String)  // "+" prefix — line to add

    var text: String {
        switch self {
        case .context(let s), .removal(let s), .addition(let s): return s
        }
    }
}

// MARK: - Unified Diff Patcher

/// Parses and applies unified diffs to source text.
///
/// Supports standard unified diff format as produced by `diff -u`, `git diff`,
/// and AI model outputs. Handles:
/// - Multiple hunks per diff
/// - Context lines for verification
/// - Pure additions (creating content where none existed)
/// - Fuzzy line matching with configurable tolerance
///
/// Usage:
/// ```swift
/// let patcher = UnifiedDiffPatcher()
///
/// // Apply a diff to existing content
/// let patched = try patcher.apply(diff: diffString, to: originalContent)
///
/// // Create a new file from a diff (no original content)
/// let created = try patcher.apply(diff: diffString, to: "", mode: .create)
/// ```
struct UnifiedDiffPatcher: Sendable {

    enum Mode: Sendable {
        /// Normal patch — original content must exist and context must match.
        case patch
        /// Create mode — treats diff as pure additions, ignores removals.
        case create
    }

    /// Maximum number of lines to search above/below for fuzzy context matching.
    var fuzzLines: Int = 3

    // MARK: - Public API

    /// Parse a unified diff string into structured hunks.
    ///
    /// Handles both full unified diffs (with `---`/`+++` headers) and
    /// bare hunk sequences (just `@@` headers and content).
    func parse(diff: String) throws -> [DiffHunk] {
        let rawLines = diff.components(separatedBy: "\n")

        // Strip trailing empty line (common in diffs).
        var lines = rawLines
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }

        var hunks: [DiffHunk] = []
        var index = 0

        // Skip file headers if present.
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("---") || line.hasPrefix("+++") || line.hasPrefix("diff ") ||
               line.hasPrefix("index ") || line.hasPrefix("new file") || line.hasPrefix("deleted file") {
                index += 1
                continue
            }
            break
        }

        // Parse hunks.
        while index < lines.count {
            // Skip blank lines between hunks.
            if lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                continue
            }

            guard lines[index].hasPrefix("@@") else {
                // If we already have hunks and hit non-hunk content, we're done.
                if !hunks.isEmpty { break }
                // Skip unexpected lines before first hunk.
                index += 1
                continue
            }

            let (hunk, nextIndex) = try parseHunk(lines: lines, startIndex: index)
            hunks.append(hunk)
            index = nextIndex
        }

        if hunks.isEmpty {
            throw DiffError.noHunksFound
        }

        return hunks
    }

    /// Apply a unified diff to source content.
    ///
    /// - Parameters:
    ///   - diff: The unified diff string.
    ///   - original: The original file content (empty string for new files).
    ///   - mode: `.patch` for normal patching, `.create` for new file creation.
    /// - Returns: The patched file content.
    func apply(diff: String, to original: String, mode: Mode = .patch) throws -> String {
        let hunks = try parse(diff: diff)

        switch mode {
        case .create:
            return applyCreate(hunks: hunks)
        case .patch:
            return try applyPatch(hunks: hunks, to: original)
        }
    }

    // MARK: - Hunk Parsing

    /// Regex for unified diff hunk headers: @@ -start[,count] +start[,count] @@
    private static let hunkHeaderPattern = try! NSRegularExpression(
        pattern: #"^@@\s+-(\d+)(?:,(\d+))?\s+\+(\d+)(?:,(\d+))?\s+@@"#
    )

    private func parseHunk(lines: [String], startIndex: Int) throws -> (DiffHunk, Int) {
        let headerLine = lines[startIndex]
        let nsHeader = headerLine as NSString
        let fullRange = NSRange(location: 0, length: nsHeader.length)

        guard let match = Self.hunkHeaderPattern.firstMatch(in: headerLine, range: fullRange),
              match.numberOfRanges >= 3 else {
            throw DiffError.malformedHunkHeader(headerLine)
        }

        let originalStart = Int(nsHeader.substring(with: match.range(at: 1)))!
        let originalCount: Int
        if match.range(at: 2).location != NSNotFound {
            originalCount = Int(nsHeader.substring(with: match.range(at: 2)))!
        } else {
            originalCount = 1
        }

        let modifiedStart = Int(nsHeader.substring(with: match.range(at: 3)))!
        let modifiedCount: Int
        if match.numberOfRanges > 4, match.range(at: 4).location != NSNotFound {
            modifiedCount = Int(nsHeader.substring(with: match.range(at: 4)))!
        } else {
            modifiedCount = 1
        }

        // Parse hunk body lines.
        var hunkLines: [HunkLine] = []
        var index = startIndex + 1
        var contextSeen = 0
        var removalSeen = 0
        var additionSeen = 0

        while index < lines.count {
            let line = lines[index]

            // Next hunk header or end of diff.
            if line.hasPrefix("@@") { break }
            // File header for next file in multi-file diff.
            if line.hasPrefix("---") || line.hasPrefix("+++") || line.hasPrefix("diff ") { break }

            if line.hasPrefix("-") {
                hunkLines.append(.removal(String(line.dropFirst())))
                removalSeen += 1
            } else if line.hasPrefix("+") {
                hunkLines.append(.addition(String(line.dropFirst())))
                additionSeen += 1
            } else if line.hasPrefix(" ") {
                hunkLines.append(.context(String(line.dropFirst())))
                contextSeen += 1
            } else if line == "\\ No newline at end of file" {
                // Git marker, skip.
            } else if line.isEmpty {
                // Empty line in diff usually means empty context line.
                hunkLines.append(.context(""))
                contextSeen += 1
            } else {
                // Unknown line format — treat as end of hunk.
                break
            }

            index += 1

            // Stop if we've consumed enough lines for this hunk.
            if contextSeen + removalSeen >= originalCount &&
               contextSeen + additionSeen >= modifiedCount {
                break
            }
        }

        let hunk = DiffHunk(
            originalStart: originalStart,
            originalCount: originalCount,
            modifiedStart: modifiedStart,
            modifiedCount: modifiedCount,
            lines: hunkLines
        )

        return (hunk, index)
    }

    // MARK: - Apply: Create Mode

    /// Create mode: extract only addition lines, ignoring removals and context.
    private func applyCreate(hunks: [DiffHunk]) -> String {
        var output: [String] = []
        for hunk in hunks {
            for line in hunk.lines {
                switch line {
                case .addition(let text):
                    output.append(text)
                case .context(let text):
                    output.append(text)
                case .removal:
                    continue
                }
            }
        }
        return output.joined(separator: "\n")
    }

    // MARK: - Apply: Patch Mode

    /// Normal patch mode: verify context, apply removals and additions.
    private func applyPatch(hunks: [DiffHunk], to original: String) throws -> String {
        // Empty string splits to [""] — use [] instead so pure additions work correctly.
        var sourceLines = original.isEmpty ? [] : original.components(separatedBy: "\n")

        // Remove trailing empty line if original ends with newline
        // (we'll re-add it at the end if needed).
        let endsWithNewline = original.hasSuffix("\n") && !original.isEmpty
        if endsWithNewline && sourceLines.last?.isEmpty == true {
            sourceLines.removeLast()
        }

        // Apply hunks in reverse order so line numbers stay valid.
        let sortedHunks = hunks.sorted { $0.originalStart > $1.originalStart }

        // Verify no overlaps.
        for i in 0..<sortedHunks.count - 1 {
            let current = sortedHunks[i]
            let next = sortedHunks[i + 1]
            if next.originalStart + next.originalCount > current.originalStart {
                throw DiffError.overlappingHunks(hunkIndex: hunks.firstIndex(of: current)!)
            }
        }

        for (reverseIdx, hunk) in sortedHunks.enumerated() {
            let hunkIndex = hunks.count - 1 - reverseIdx

            // Find the best matching position (exact or fuzzy).
            let matchStart = try findHunkPosition(
                hunk: hunk,
                hunkIndex: hunkIndex,
                in: sourceLines
            )

            // Build replacement lines.
            var replacement: [String] = []
            var sourceOffset = matchStart

            for line in hunk.lines {
                switch line {
                case .context(let text):
                    // Verify context matches (with whitespace tolerance).
                    if sourceOffset < sourceLines.count {
                        let sourceLine = sourceLines[sourceOffset]
                        if !linesMatch(sourceLine, text) {
                            throw DiffError.contextMismatch(
                                hunkIndex: hunkIndex,
                                expectedLine: sourceOffset + 1,
                                expected: text,
                                actual: sourceLine
                            )
                        }
                    }
                    replacement.append(text)
                    sourceOffset += 1

                case .removal(let text):
                    // Verify removal line matches.
                    if sourceOffset < sourceLines.count {
                        let sourceLine = sourceLines[sourceOffset]
                        if !linesMatch(sourceLine, text) {
                            throw DiffError.contextMismatch(
                                hunkIndex: hunkIndex,
                                expectedLine: sourceOffset + 1,
                                expected: text,
                                actual: sourceLine
                            )
                        }
                    }
                    // Don't add to replacement (it's being removed).
                    sourceOffset += 1

                case .addition(let text):
                    replacement.append(text)
                    // Don't advance sourceOffset (it's new content).
                }
            }

            // Replace the range in source.
            let removeCount = sourceOffset - matchStart
            sourceLines.replaceSubrange(matchStart..<(matchStart + removeCount), with: replacement)
        }

        var result = sourceLines.joined(separator: "\n")
        if endsWithNewline {
            result += "\n"
        }
        return result
    }

    // MARK: - Fuzzy Position Finding

    /// Find where a hunk should be applied, with fuzzy matching if exact position fails.
    private func findHunkPosition(
        hunk: DiffHunk,
        hunkIndex: Int,
        in sourceLines: [String]
    ) throws -> Int {
        // Unified diffs use 1-based line numbers.
        let exactStart = hunk.originalStart - 1

        // Try exact position first.
        if exactStart >= 0 && exactStart <= sourceLines.count {
            if verifyHunkContext(hunk: hunk, in: sourceLines, at: exactStart) {
                return exactStart
            }
        }

        // Fuzzy search: try positions near the expected start.
        for offset in 1...fuzzLines {
            // Try below.
            let below = exactStart + offset
            if below >= 0 && below <= sourceLines.count {
                if verifyHunkContext(hunk: hunk, in: sourceLines, at: below) {
                    return below
                }
            }
            // Try above.
            let above = exactStart - offset
            if above >= 0 && above <= sourceLines.count {
                if verifyHunkContext(hunk: hunk, in: sourceLines, at: above) {
                    return above
                }
            }
        }

        // Last resort: if the hunk is pure additions (no context or removals to verify),
        // use the exact position even if it's at the end of the file.
        let hasVerifiableLines = hunk.lines.contains { line in
            switch line {
            case .context, .removal: return true
            case .addition: return false
            }
        }

        if !hasVerifiableLines {
            return min(exactStart, sourceLines.count)
        }

        // Hunk has verifiable lines but no position matched.
        // If the exact position was within bounds, throw a contextMismatch so
        // callers get a diagnostic pointing at the mismatched line rather than
        // a misleading "out of bounds" error.
        if exactStart >= 0 && exactStart < sourceLines.count {
            // Find first verifiable line to build a helpful error.
            for line in hunk.lines {
                switch line {
                case .context(let expected), .removal(let expected):
                    let actual = exactStart < sourceLines.count ? sourceLines[exactStart] : ""
                    throw DiffError.contextMismatch(
                        hunkIndex: hunkIndex,
                        expectedLine: exactStart + 1,
                        expected: expected,
                        actual: actual
                    )
                case .addition:
                    continue
                }
            }
        }

        throw DiffError.hunkOutOfBounds(
            hunkIndex: hunkIndex,
            startLine: hunk.originalStart,
            totalLines: sourceLines.count
        )
    }

    /// Check if a hunk's context/removal lines match the source at a given position.
    private func verifyHunkContext(
        hunk: DiffHunk,
        in sourceLines: [String],
        at position: Int
    ) -> Bool {
        var sourceOffset = position

        for line in hunk.lines {
            switch line {
            case .context(let expected), .removal(let expected):
                guard sourceOffset < sourceLines.count else { return false }
                if !linesMatch(sourceLines[sourceOffset], expected) {
                    return false
                }
                sourceOffset += 1
            case .addition:
                continue
            }
        }

        return true
    }

    /// Compare two lines with whitespace tolerance.
    ///
    /// Tolerates trailing whitespace differences, which are common when
    /// AI models generate diffs (they often strip or add trailing spaces).
    private func linesMatch(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        // Trim trailing whitespace for fuzzy match.
        let trimA = a.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        let trimB = b.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        return trimA == trimB
    }
}
