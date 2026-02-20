// TerminalSearch.swift
// ProSSHV2
//
// E.2 — terminal search model with regex and case-sensitivity options.

import Foundation
import Combine

struct TerminalSearchMatch: Identifiable, Hashable, Sendable {
    let lineIndex: Int
    let location: Int
    let length: Int

    var id: String { "\(lineIndex):\(location):\(length)" }

    var range: NSRange {
        NSRange(location: location, length: length)
    }

    func stringRange(in line: String) -> Range<String.Index>? {
        Range(range, in: line)
    }
}

@MainActor
final class TerminalSearch: ObservableObject {
    @Published var isPresented = false
    @Published var query = "" {
        didSet { refreshMatches() }
    }
    @Published var isRegexEnabled = false {
        didSet { refreshMatches() }
    }
    @Published var isCaseSensitive = false {
        didSet { refreshMatches() }
    }

    @Published private(set) var matches: [TerminalSearchMatch] = []
    @Published private(set) var selectedMatchIndex: Int?
    @Published private(set) var validationError: String?

    var selectedMatch: TerminalSearchMatch? {
        guard let selectedMatchIndex,
              matches.indices.contains(selectedMatchIndex) else {
            return nil
        }
        return matches[selectedMatchIndex]
    }

    var resultSummary: String {
        guard !matches.isEmpty else { return "0" }
        let current = (selectedMatchIndex ?? 0) + 1
        return "\(current)/\(matches.count)"
    }

    private var lines: [String] = []
    private var matchesByLineIndex: [Int: [TerminalSearchMatch]] = [:]

    func present() {
        isPresented = true
    }

    func dismiss() {
        isPresented = false
    }

    func updateLines(_ lines: [String]) {
        self.lines = lines
        refreshMatches()
    }

    func selectNextMatch() {
        guard !matches.isEmpty else { return }
        let next = ((selectedMatchIndex ?? -1) + 1) % matches.count
        selectedMatchIndex = next
    }

    func selectPreviousMatch() {
        guard !matches.isEmpty else { return }
        let previous = ((selectedMatchIndex ?? matches.count) - 1 + matches.count) % matches.count
        selectedMatchIndex = previous
    }

    func matches(forLineIndex lineIndex: Int) -> [TerminalSearchMatch] {
        matchesByLineIndex[lineIndex] ?? []
    }

    func isSelected(_ match: TerminalSearchMatch) -> Bool {
        selectedMatch == match
    }

    /// Validates that a match range is still within bounds for the given line content.
    /// Returns true if the match can be safely applied.
    func isMatchValid(_ match: TerminalSearchMatch, in currentLines: [String]) -> Bool {
        guard match.lineIndex >= 0, match.lineIndex < currentLines.count else {
            return false
        }
        let line = currentLines[match.lineIndex]
        let lineLength = (line as NSString).length
        let endLocation = match.location + match.length
        return match.location >= 0 && endLocation <= lineLength
    }

    /// Returns only those matches whose ranges are still valid against the given live content.
    func validMatches(for currentLines: [String]) -> [TerminalSearchMatch] {
        matches.filter { isMatchValid($0, in: currentLines) }
    }

    private func refreshMatches() {
        let previousSelection = selectedMatch
        matches.removeAll(keepingCapacity: true)
        matchesByLineIndex.removeAll(keepingCapacity: true)
        validationError = nil
        selectedMatchIndex = nil

        guard !query.isEmpty else {
            return
        }

        if isRegexEnabled {
            let options: NSRegularExpression.Options = isCaseSensitive ? [] : [.caseInsensitive]
            do {
                let regex = try NSRegularExpression(pattern: query, options: options)
                for (lineIndex, line) in lines.enumerated() {
                    let range = NSRange(line.startIndex..<line.endIndex, in: line)
                    let lineMatches = regex.matches(in: line, options: [], range: range)
                    for match in lineMatches where match.range.length > 0 {
                        appendMatch(
                            TerminalSearchMatch(
                                lineIndex: lineIndex,
                                location: match.range.location,
                                length: match.range.length
                            )
                        )
                    }
                }
            } catch {
                validationError = error.localizedDescription
                return
            }
        } else {
            let options: String.CompareOptions = isCaseSensitive ? [] : [.caseInsensitive]
            for (lineIndex, line) in lines.enumerated() {
                var searchRange = line.startIndex..<line.endIndex
                while let found = line.range(of: query, options: options, range: searchRange),
                      !found.isEmpty {
                    let nsRange = NSRange(found, in: line)
                    appendMatch(
                        TerminalSearchMatch(
                            lineIndex: lineIndex,
                            location: nsRange.location,
                            length: nsRange.length
                        )
                    )
                    searchRange = found.upperBound..<line.endIndex
                }
            }
        }

        guard !matches.isEmpty else {
            return
        }

        if let previousSelection,
           let restoredIndex = matches.firstIndex(of: previousSelection) {
            selectedMatchIndex = restoredIndex
        } else {
            selectedMatchIndex = 0
        }
    }

    private func appendMatch(_ match: TerminalSearchMatch) {
        matches.append(match)
        matchesByLineIndex[match.lineIndex, default: []].append(match)
    }
}
