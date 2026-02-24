import SwiftUI

struct PatchApprovalCardView: View {
    @Environment(\.colorScheme) private var colorScheme
    let operation: String
    let path: String
    let diffPreview: String
    let state: PatchApprovalState
    var onApprove: (Bool) -> Void   // Bool = remember
    var onDeny: () -> Void

    @State private var remember = false

    private static let previewLineLimit = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: operationIcon)
                    .foregroundStyle(operationColor)
                Text(headerLabel)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(state == .pending ? "Approval Required" : state.rawValue.capitalized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(stateForeground)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(stateBackground))
            }

            // Path
            Text(path)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)

            // Diff preview (only for create/update)
            if !diffLines.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(previewLines.enumerated()), id: \.offset) { _, line in
                            DiffLineView(line: line)
                        }
                        if diffLines.count > Self.previewLineLimit {
                            Text("… and \(diffLines.count - Self.previewLineLimit) more lines")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 4)
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(colorScheme == .dark ? Color.black.opacity(0.3) : Color.gray.opacity(0.08)))
                }
                .frame(maxHeight: 200)
            }

            // Remember checkbox + buttons (pending only)
            if state == .pending {
                Toggle("Remember this decision for this session", isOn: $remember)
                    .font(.caption)
                    .toggleStyle(.checkbox)

                HStack {
                    Button("Deny", role: .destructive) { onDeny() }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("Approve & Apply") { onApprove(remember) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(colorScheme == .dark ? Color.orange.opacity(0.08) : Color.orange.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(borderColor, lineWidth: 1))
    }

    // MARK: - Helpers

    private var diffLines: [String] {
        diffPreview.components(separatedBy: "\n").filter { !$0.isEmpty }
    }
    private var previewLines: [String] { Array(diffLines.prefix(Self.previewLineLimit)) }

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
        default:       return "AI wants to patch a file"
        }
    }
    private var stateForeground: Color {
        switch state {
        case .pending:  return .orange
        case .approved: return .green
        case .denied:   return .red
        }
    }
    private var stateBackground: Color { stateForeground.opacity(0.15) }
    private var borderColor: Color { stateForeground.opacity(colorScheme == .dark ? 0.35 : 0.25) }
}

// Single diff line renderer
private struct DiffLineView: View {
    let line: String
    var body: some View {
        Text(line)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(foregroundColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 1)
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
