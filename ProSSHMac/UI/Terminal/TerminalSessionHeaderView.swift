// Extracted from TerminalView.swift
import SwiftUI

struct TerminalSessionHeaderView: View {
    let session: Session

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                if session.isLocal {
                    HStack(spacing: 6) {
                        Image(systemName: "terminal.fill")
                            .foregroundStyle(.secondary)
                        Text("Local Terminal")
                            .font(.headline)
                    }

                    let shellName = session.shellPath.map { ($0 as NSString).lastPathComponent } ?? "shell"
                    Text("\(session.username)@localhost (\(shellName))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 6) {
                        Text(session.hostLabel)
                            .font(.headline)

                        if session.usesLegacyCrypto {
                            Label("Legacy", systemImage: "shield.lefthalf.filled")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }

                        if session.usesAgentForwarding {
                            Label("Agent Fwd", systemImage: "arrow.triangle.branch")
                                .font(.caption)
                                .foregroundStyle(.teal)
                        }
                    }

                    Text("\(session.username)@\(session.hostname):\(session.port)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text(session.state.rawValue.capitalized)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(stateColor(for: session.state).opacity(0.15), in: Capsule())
                .foregroundStyle(stateColor(for: session.state))
        }
    }

    private func stateColor(for state: SessionState) -> Color {
        switch state {
        case .connecting: return .orange
        case .connected: return .green
        case .disconnected: return .gray
        case .failed: return .red
        }
    }
}
