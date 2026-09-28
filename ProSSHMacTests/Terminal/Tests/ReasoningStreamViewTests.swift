import AppKit
import XCTest
@testable import ProSSHMac

@MainActor
final class ReasoningStreamViewTests: XCTestCase {
    func testRepeatedChainsWrapToViewportAfterLongShortAndEmptyReplacements() {
        let view = ReasoningStreamScrollView()
        // SwiftUI can deliver the first update before assigning any geometry.
        view.update(summary: "", details: "Hello")
        resize(view, width: 296, height: 100)
        let sentence = "Hello how can I help you?"

        for chain in 1...10 {
            view.update(summary: "", details: String(repeating: "A long thinking chain fills and scrolls the panel. ", count: chain * 10))
            view.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(lineCount(view), 2)
            XCTAssertGreaterThan(view.contentView.bounds.origin.y, 0)

            view.update(summary: "", details: "")
            var streamed = ""
            for fragment in ["Hel", "lo ", "how ", "can ", "I ", "help ", "you?"] {
                streamed += fragment
                view.update(summary: "", details: streamed)
                view.layoutSubtreeIfNeeded()
                XCTAssertEqual(lineCount(view), 2, "Chain \(chain), prefix \(streamed)")
                XCTAssertEqual(view.reasoningTextView.textContainer?.containerSize.width, view.contentView.bounds.width)
            }
            XCTAssertEqual(view.reasoningTextView.string, "THINKING\n" + sentence)
            XCTAssertEqual(view.contentView.bounds.origin.y, 0, accuracy: 0.5)
        }
    }

    func testSidebarResizeReflowsActualLineFragments() {
        let view = ReasoningStreamScrollView()
        resize(view, width: 296, height: 100)
        view.update(summary: "", details: "Hello how can I help you?")
        XCTAssertEqual(lineCount(view), 2)

        resize(view, width: 90, height: 100)
        XCTAssertGreaterThan(lineCount(view), 2)

        resize(view, width: 400, height: 100)
        XCTAssertEqual(lineCount(view), 2)
    }

    func testBothSectionsPreserveNewlinesAndInlineMarkdown() throws {
        let view = ReasoningStreamScrollView()
        resize(view, width: 400, height: 150)
        view.update(summary: "A **bold** summary.", details: "First line.\nSecond with `code` and [a link](https://example.com).")
        let expected = "SUMMARY\nA bold summary.\n\nTHINKING\nFirst line.\nSecond with code and a link."
        XCTAssertEqual(view.reasoningTextView.string, expected)
        let storage = try XCTUnwrap(view.reasoningTextView.textStorage)
        let boldRange = (expected as NSString).range(of: "bold")
        let bold = try XCTUnwrap(storage.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
        let linkRange = (expected as NSString).range(of: "a link")
        XCTAssertEqual(storage.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL, URL(string: "https://example.com"))
        XCTAssertTrue(view.reasoningTextView.isSelectable)
        XCTAssertFalse(view.reasoningTextView.isEditable)
    }

    func testAppendingKeepsSelectionAndChainReplacementClearsIt() {
        let view = ReasoningStreamScrollView()
        resize(view, width: 296, height: 100)
        view.update(summary: "", details: "Hello")
        let selection = NSRange(location: 9, length: 5)
        view.reasoningTextView.setSelectedRange(selection)
        view.update(summary: "", details: "Hello how can I help you?")
        XCTAssertEqual(view.reasoningTextView.selectedRange(), selection)
        view.update(summary: "", details: "Next chain.")
        XCTAssertEqual(view.reasoningTextView.selectedRange(), NSRange(location: 0, length: 0))
    }

    private func resize(_ view: ReasoningStreamScrollView, width: CGFloat, height: CGFloat) {
        view.setFrameSize(NSSize(width: width, height: height))
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
    }

    private func lineCount(_ view: ReasoningStreamScrollView) -> Int {
        guard let container = view.reasoningTextView.textContainer,
              let manager = view.reasoningTextView.layoutManager else { return 0 }
        manager.ensureLayout(for: container)
        var count = 0
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, _, _, _, _ in count += 1 }
        return count
    }
}
