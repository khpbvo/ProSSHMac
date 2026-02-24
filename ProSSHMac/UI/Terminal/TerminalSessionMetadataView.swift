// Extracted from TerminalView.swift
import SwiftUI

struct TerminalSessionMetadataView: View {
    let session: Session
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var portForwardingManager: PortForwardingManager
    @State private var expandedSessions: Set<UUID> = []

    var body: some View {
        if session.isLocal {
            let cwd = sessionManager.workingDirectoryBySessionID[session.id] ?? "~"
            let displayCwd = cwd.replacingOccurrences(
                of: ProcessInfo.processInfo.environment["HOME"] ?? "/nonexistent",
                with: "~"
            )
            Text("Shell: \(session.shellPath ?? "/bin/zsh")  |  CWD: \(displayCwd)  |  TERM: xterm-256color")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        } else {
            if let kex = session.negotiatedKEX,
               let cipher = session.negotiatedCipher,
               let hostKey = session.negotiatedHostKeyType {
                let fingerprint = session.negotiatedHostFingerprint ?? "unknown"
                let isExpanded = expandedSessions.contains(session.id)
                let isLegacy = session.usesLegacyCrypto

                HStack(spacing: 4) {
                    Image(systemName: isLegacy ? "lock.trianglebadge.exclamationmark" : "lock.fill")
                        .font(.caption)
                        .foregroundStyle(isLegacy ? .orange : .green)
                    Text(isLegacy ? "Legacy Crypto" : "Secure")
                        .font(.caption)
                        .foregroundStyle(isLegacy ? .orange : .secondary)
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if isExpanded {
                                expandedSessions.remove(session.id)
                            } else {
                                expandedSessions.insert(session.id)
                            }
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                if isExpanded {
                    VStack(alignment: .leading, spacing: 2) {
                        metadataRow(label: "KEX", value: kex)
                        metadataRow(label: "Cipher", value: cipher)
                        metadataRow(label: "Host Key", value: hostKey)
                        metadataRow(label: "FP", value: fingerprint)
                    }
                    .padding(.leading, 4)
                }
            }

            if let advisory = session.securityAdvisory {
                Label(advisory, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            let forwards = portForwardingManager.activeForwards.filter { $0.sessionID == session.id }
            if !forwards.isEmpty {
                let listeningCount = forwards.filter { $0.state == .listening }.count
                Label("\(listeningCount)/\(forwards.count) forwards active", systemImage: "arrow.right.arrow.left")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }

        if session.state == .connected {
            TimelineView(.periodic(from: .now, by: 60)) { _ in
                let duration = Date.now.timeIntervalSince(session.startedAt)
                let hours = Int(duration) / 3600
                let minutes = (Int(duration) % 3600) / 60
                Text("Duration: \(hours > 0 ? "\(hours)h " : "")\(minutes)m")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if session.state == .connected, !session.isLocal {
            let lastActivity = sessionManager.lastActivityBySessionID[session.id]
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                let idleSeconds = lastActivity.map { Date.now.timeIntervalSince($0) } ?? 0
                if idleSeconds > 600 {
                    let idleMinutes = Int(idleSeconds) / 60
                    Label("Idle for \(idleMinutes)m — session may time out", systemImage: "clock.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }

        if let errorMessage = session.errorMessage {
            Text(errorMessage)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func metadataRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label + ":")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 60, alignment: .trailing)
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}
