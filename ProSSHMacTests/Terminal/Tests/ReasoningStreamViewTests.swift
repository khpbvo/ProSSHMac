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

    // Bug 94: a chain replaced inside mouseDown's tracking loop left AppKit's selection
    // anchor in the old, longer text. The update must wait for the mouse to come up.
    func testChainReplacementDuringClickWaitsForMouseUp() throws {
        let view = ReasoningStreamScrollView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 296, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view
        resize(view, width: 296, height: 200)
        view.update(summary: "", details: String(repeating: "A long thinking chain fills and scrolls the panel.\n", count: 400))
        let textView = view.reasoningTextView
        let oldText = textView.string
        let manager = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)

        // Click on the last line, where the panel has scrolled to.
        let glyph = manager.glyphIndexForCharacter(at: (oldText as NSString).length - 2)
        let rect = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        let down = textView.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let drag = NSPoint(x: down.x - 20, y: down.y)
        var textDuringClick: String?
        Task { @MainActor in
            view.update(summary: "", details: "Next chain.")
            textDuringClick = textView.string
            NSApp.postEvent(self.mouseEvent(.leftMouseDragged, at: drag, in: window), atStart: false)
            NSApp.postEvent(self.mouseEvent(.leftMouseUp, at: drag, in: window), atStart: false)
        }
        textView.mouseDown(with: mouseEvent(.leftMouseDown, at: down, in: window))

        XCTAssertTrue(textDuringClick == oldText, "The chain was replaced while the mouse was down")
        XCTAssertFalse(textView.isTrackingMouse)
        XCTAssertEqual(textView.string, "THINKING\nNext chain.")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 0))
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
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
