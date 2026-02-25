import SwiftUI

struct PatchApprovalSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    let operation: String
    let path: String
    let diffPreview: String
    var onApprove: (Bool) -> Void
    var onDeny: () -> Void

    @State private var remember = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: operationIcon)
                    .foregroundStyle(operationColor)
                    .font(.title3)
                Text(headerLabel)
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    onDeny()
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("Path")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(path)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
                    )

                Text("Patch Preview")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if diffLines.isEmpty {
                    Text("No diff preview is available for this operation.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.03))
                        )
                } else {
                    GeometryReader { proxy in
                        ScrollView([.vertical, .horizontal], showsIndicators: true) {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(diffLines.enumerated()), id: \.offset) { index, line in
                                    PatchDiffLineView(lineNumber: index + 1, line: line)
                                }
                            }
                            .frame(minWidth: proxy.size.width, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(colorScheme == .dark ? Color.black.opacity(0.3) : Color.gray.opacity(0.08))
                    )
                }
            }
            .padding(18)

            Divider()

            VStack(spacing: 10) {
                Toggle("Remember this decision for this session", isOn: $remember)
                    .font(.subheadline)
                    .toggleStyle(.checkbox)

                HStack {
                    Button("Reject", role: .destructive) {
                        onDeny()
                        dismiss()
                    }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("Approve & Apply") {
                        onApprove(remember)
                        dismiss()
                    }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .frame(minWidth: 840, idealWidth: 980, maxWidth: .infinity, minHeight: 600, idealHeight: 700, maxHeight: .infinity)
        .background(colorScheme == .dark ? Color(red: 0.08, green: 0.09, blue: 0.11) : Color(red: 0.98, green: 0.98, blue: 0.99))
    }

    private var diffLines: [String] {
        let normalized = diffPreview.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        return diffPreview.components(separatedBy: "\n")
    }

    private var operationIcon: String {
        switch operation {
        case "create": return "doc.badge.plus"
        case "update": return "doc.text"
        case "delete": return "trash"
        default:       return "doc"
        }
    }
    private var operationColor: Color {
        switch operation {
        case "create": return .green
        case "update": return .blue
        case "delete": return .red
        default:       return .secondary
        }
    }
    private var headerLabel: String {
        switch operation {
        case "create": return "AI wants to create a file"
        case "update": return "AI wants to modify a file"
        case "delete": return "AI wants to delete a file"
        default: return "AI wants to patch a file"
        }
    }
}

private struct PatchDiffLineView: View {
    let lineNumber: Int
    let line: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(lineNumber)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
            Text(line.isEmpty ? " " : line)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(foregroundColor)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
        .padding(.horizontal, 6)
        .background(backgroundColor)
    }

    private var foregroundColor: Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return .green }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return .red }
        if line.hasPrefix("@@") { return Color(red: 0.2, green: 0.6, blue: 0.9) }
        return .secondary
    }
    private var backgroundColor: Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return .green.opacity(0.08) }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return .red.opacity(0.08) }
        return .clear
    }
}
