import AppKit
import SwiftUI

struct ReasoningStreamView: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    let summary: String
    let details: String

    func makeNSView(context: Context) -> ReasoningStreamScrollView {
        ReasoningStreamScrollView()
    }

    func updateNSView(_ view: ReasoningStreamScrollView, context: Context) {
        view.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        view.update(summary: summary, details: details)
    }
}

/// Owns the text container's width and document height explicitly. Stream updates,
/// chain replacements and sidebar resizes all go through the same TextKit layout.
final class ReasoningStreamScrollView: NSScrollView {
    let reasoningTextView: NSTextView
    private var followAfterLayout = true

    init() {
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        reasoningTextView = NSTextView(frame: .zero, textContainer: container)
        super.init(frame: .zero)

        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay

        reasoningTextView.drawsBackground = false
        reasoningTextView.isEditable = false
        reasoningTextView.isSelectable = true
        reasoningTextView.isHorizontallyResizable = false
        reasoningTextView.isVerticallyResizable = false
        reasoningTextView.textContainerInset = .zero
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        reasoningTextView.setAccessibilityLabel("Reasoning Stream")
        documentView = reasoningTextView
    }

    required init?(coder: NSCoder) { nil }

    func update(summary: String, details: String) {
        let text = Self.attributedText(summary: summary, details: details)
        guard let storage = reasoningTextView.textStorage, !storage.isEqual(to: text) else { return }
        let selection = reasoningTextView.selectedRange()
        let isAppend = text.string.hasPrefix(storage.string)
        storage.setAttributedString(text)
        let location = isAppend ? min(selection.location, text.length) : 0
        let length = isAppend ? min(selection.length, text.length - location) : 0
        reasoningTextView.setSelectedRange(NSRange(location: location, length: length))
        followAfterLayout = true
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        guard let container = reasoningTextView.textContainer,
              let manager = reasoningTextView.layoutManager else { return }
        let viewport = contentView.bounds.size
        guard viewport.width > 0 else { return }

        container.containerSize = NSSize(width: viewport.width, height: CGFloat.greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let height = max(viewport.height, ceil(manager.usedRect(for: container).maxY))
        reasoningTextView.setFrameSize(NSSize(width: viewport.width, height: height))
        if followAfterLayout {
            contentView.scroll(to: NSPoint(x: 0, y: max(0, height - viewport.height)))
            reflectScrolledClipView(contentView)
            followAfterLayout = false
        }
    }

    private static func attributedText(summary: String, details: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.lineBreakMode = .byWordWrapping
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        let result = NSMutableAttributedString(string: "")
        for (title, text) in [("SUMMARY", summary), ("THINKING", details)] where !text.isEmpty {
            if result.length > 0 { result.append(NSAttributedString(string: "\n\n")) }
            result.append(NSAttributedString(string: title + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
                .kern: 0.4,
            ]))
            let markdown = AIAssistantRenderer.markdownText(text)
            let body = NSMutableAttributedString(string: String(markdown.characters), attributes: bodyAttributes)
            var offset = 0
            for run in markdown.runs {
                let length = String(markdown[run.range].characters).utf16.count
                let range = NSRange(location: offset, length: length)
                let intent = run.inlinePresentationIntent ?? []
                var font = intent.contains(.code)
                    ? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
                    : NSFont.systemFont(ofSize: 13)
                if intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                body.addAttribute(.font, value: font, range: range)
                if intent.contains(.strikethrough) { body.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
                if let link = run.link { body.addAttribute(.link, value: link, range: range) }
                offset += length
            }
            result.append(body)
        }
        if result.length == 0 {
            result.append(NSAttributedString(string: "Reasoning summaries will appear here while the assistant is working.", attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        return result
    }
}
