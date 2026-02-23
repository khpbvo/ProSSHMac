import SwiftUI
import AppKit

struct TerminalAIAssistantPane: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var viewModel: TerminalAIAssistantViewModel
    @FocusState private var isComposerFocused: Bool
    var session: Session?
    var onClose: () -> Void
    var onSend: (UUID) -> Void
    var onComposerFocusChanged: (Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messagesView
            Divider()
            composer
        }
        .background(
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color(red: 0.07, green: 0.09, blue: 0.16), Color(red: 0.04, green: 0.05, blue: 0.09)]
                    : [Color(red: 0.96, green: 0.98, blue: 1.0), Color(red: 0.93, green: 0.95, blue: 0.99)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(colorScheme == .dark ? Color.white.opacity(0.15) : Color.black.opacity(0.12))
                .frame(width: 1)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("AI Terminal Copilot", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
            }

            Text("Mode: Ask")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(session.map { "Session: \($0.hostLabel)" } ?? "Select a connected session to start.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private var messagesView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if viewModel.messages.isEmpty {
                        emptyState
                    } else {
                        ForEach(viewModel.messages) { message in
                            AIAssistantMessageCard(message: message)
                                .id(message.id)
                        }
                    }
                }
                .padding(12)
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                guard let lastID = viewModel.messages.last?.id else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
            .onChange(of: viewModel.messages.last?.content) { _, _ in
                guard let last = viewModel.messages.last, last.isStreaming else { return }
                withAnimation(.linear(duration: 0.06)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask anything about this terminal session.")
                .font(.subheadline.weight(.semibold))
            Text("Code examples render as copyable blocks with highlighting and stream into the pane.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.accentColor.opacity(colorScheme == .dark ? 0.14 : 0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Ask about logs, commands, errors, or ask for runnable examples...", text: $viewModel.draftPrompt)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.send)
                .autocorrectionDisabled(true)
                .focused($isComposerFocused)
                .onSubmit {
                    submitComposer()
                }
                .disabled(session == nil || viewModel.isSending)

            HStack(spacing: 8) {
                Button("Clear") {
                    viewModel.clearConversation(sessionID: session?.id)
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.messages.isEmpty)

                Spacer()

                Button {
                    submitComposer()
                } label: {
                    if viewModel.isSending {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Send", systemImage: "arrow.up.circle.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    session == nil
                    || viewModel.isSending
                    || viewModel.draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }

            if let lastError = viewModel.lastError, !lastError.isEmpty {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .onChange(of: isComposerFocused) { _, isFocused in
            onComposerFocusChanged(isFocused)
        }
        .onDisappear {
            onComposerFocusChanged(false)
        }
    }

    private func submitComposer() {
        guard let session else { return }
        guard !viewModel.isSending else { return }
        guard !viewModel.draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onSend(session.id)
    }
}

private struct AIAssistantMessageCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let message: TerminalAIAssistantMessage

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
            HStack(spacing: 6) {
                if message.role == .assistant {
                    Image(systemName: "cpu")
                        .font(.caption)
                    Text("Assistant")
                        .font(.caption.weight(.semibold))
                } else {
                    Image(systemName: "person.fill")
                        .font(.caption)
                    Text("You")
                        .font(.caption.weight(.semibold))
                }
                if message.isStreaming {
                    ProgressView()
                        .controlSize(.mini)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)

            ForEach(AIAssistantRenderer.parseSegments(from: message.content)) { segment in
                switch segment.kind {
                case let .text(text):
                    Text(verbatim: text)
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                case let .code(language, code):
                    AIAssistantCodeBlock(language: language, code: code)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.08), lineWidth: 1)
        )
    }

    private var backgroundColor: Color {
        switch message.role {
        case .user:
            return Color.accentColor.opacity(colorScheme == .dark ? 0.22 : 0.14)
        case .assistant, .system:
            return colorScheme == .dark ? Color.white.opacity(0.05) : Color.white.opacity(0.72)
        }
    }
}

private struct AIAssistantCodeBlock: View {
    @Environment(\.colorScheme) private var colorScheme
    let language: String?
    let code: String
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(language?.isEmpty == false ? language!.uppercased() : "CODE")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(didCopy ? "Copied" : "Copy") {
                    _ = PlatformClipboard.writeString(code)
                    didCopy = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        didCopy = false
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption2.weight(.semibold))
            }

            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                Text(AIAssistantRenderer.highlightedCode(code, language: language, darkMode: colorScheme == .dark))
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 40, maxHeight: 220)
            .background(codeBackground, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var codeBackground: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.44)
            : Color.black.opacity(0.05)
    }
}

private enum AIAssistantRenderer {
    struct Segment: Identifiable {
        enum Kind {
            case text(String)
            case code(language: String?, code: String)
        }

        let id = UUID()
        let kind: Kind
    }

    static func parseSegments(from content: String) -> [Segment] {
        guard !content.isEmpty else { return [] }

        var segments: [Segment] = []
        var currentText: [String] = []
        var currentCode: [String] = []
        var currentLanguage: String?
        var inCodeBlock = false

        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let stringLine = String(line)
            let trimmed = stringLine.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCodeBlock {
                    let code = currentCode.joined(separator: "\n")
                    if !code.isEmpty {
                        segments.append(Segment(kind: .code(language: currentLanguage, code: code)))
                    }
                    currentCode.removeAll(keepingCapacity: true)
                    currentLanguage = nil
                    inCodeBlock = false
                } else {
                    if !currentText.isEmpty {
                        segments.append(Segment(kind: .text(currentText.joined(separator: "\n"))))
                        currentText.removeAll(keepingCapacity: true)
                    }
                    let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                    currentLanguage = lang.isEmpty ? nil : lang
                    inCodeBlock = true
                }
                continue
            }

            if inCodeBlock {
                currentCode.append(stringLine)
            } else {
                currentText.append(stringLine)
            }
        }

        if inCodeBlock {
            let code = currentCode.joined(separator: "\n")
            if !code.isEmpty {
                segments.append(Segment(kind: .code(language: currentLanguage, code: code)))
            }
        } else if !currentText.isEmpty {
            segments.append(Segment(kind: .text(currentText.joined(separator: "\n"))))
        }

        return segments.filter { segment in
            switch segment.kind {
            case let .text(text):
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case let .code(_, code):
                return !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
    }

    static func highlightedCode(_ code: String, language: String?, darkMode: Bool) -> AttributedString {
        let baseColor = darkMode
            ? NSColor(calibratedWhite: 0.86, alpha: 1)
            : NSColor(calibratedWhite: 0.16, alpha: 1)
        let commentColor = darkMode
            ? NSColor(calibratedRed: 0.46, green: 0.70, blue: 0.44, alpha: 1)
            : NSColor(calibratedRed: 0.22, green: 0.46, blue: 0.24, alpha: 1)
        let keywordColor = darkMode
            ? NSColor(calibratedRed: 0.94, green: 0.58, blue: 0.34, alpha: 1)
            : NSColor(calibratedRed: 0.62, green: 0.28, blue: 0.12, alpha: 1)
        let stringColor = darkMode
            ? NSColor(calibratedRed: 0.96, green: 0.83, blue: 0.45, alpha: 1)
            : NSColor(calibratedRed: 0.69, green: 0.44, blue: 0.08, alpha: 1)
        let numberColor = darkMode
            ? NSColor(calibratedRed: 0.55, green: 0.82, blue: 0.96, alpha: 1)
            : NSColor(calibratedRed: 0.10, green: 0.39, blue: 0.62, alpha: 1)

        let attributed = NSMutableAttributedString(
            string: code,
            attributes: [
                .foregroundColor: baseColor,
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            ]
        )

        applyRegex(#"(?m)//.*$|#.*$"#, color: commentColor, to: attributed)
        applyRegex(#"\"([^\"\\]|\\.)*\"|'([^'\\]|\\.)*'"#, color: stringColor, to: attributed)
        applyRegex(#"\b\d+(?:\.\d+)?\b"#, color: numberColor, to: attributed)

        let keywords = keywordList(for: language)
        if !keywords.isEmpty {
            let pattern = #"\b("# + keywords.joined(separator: "|") + #")\b"#
            applyRegex(pattern, color: keywordColor, to: attributed)
        }

        return AttributedString(attributed)
    }

    private static func applyRegex(_ pattern: String, color: NSColor, to attributed: NSMutableAttributedString) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return
        }
        let fullRange = NSRange(location: 0, length: attributed.string.utf16.count)
        regex.enumerateMatches(in: attributed.string, options: [], range: fullRange) { match, _, _ in
            guard let range = match?.range, range.location != NSNotFound else { return }
            attributed.addAttribute(.foregroundColor, value: color, range: range)
        }
    }

    private static func keywordList(for language: String?) -> [String] {
        let normalized = (language ?? "").lowercased()
        if normalized.contains("swift") {
            return ["let", "var", "func", "if", "else", "guard", "return", "struct", "class", "enum", "protocol", "import", "async", "await", "throw", "try"]
        }
        if normalized.contains("python") || normalized == "py" {
            return ["def", "class", "if", "else", "elif", "for", "while", "return", "import", "from", "as", "try", "except", "with", "pass", "lambda"]
        }
        if normalized.contains("json") {
            return ["true", "false", "null"]
        }
        if normalized.contains("bash") || normalized == "sh" || normalized == "zsh" || normalized == "shell" {
            return ["if", "then", "else", "fi", "for", "do", "done", "while", "case", "esac", "function", "export", "local", "echo", "grep", "awk", "sed"]
        }
        if normalized.contains("js") || normalized.contains("ts") || normalized.contains("javascript") || normalized.contains("typescript") {
            return ["const", "let", "var", "function", "if", "else", "return", "class", "import", "export", "async", "await", "try", "catch", "new"]
        }
        return ["if", "else", "for", "while", "return", "import", "class", "function", "const", "let", "var", "def"]
    }
}
