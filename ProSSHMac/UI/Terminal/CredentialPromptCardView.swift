import SwiftUI

/// Shown above the composer while a copilot command waits at a password prompt. The password is
/// typed in the terminal, never here. See Docs/CredentialPrompt.md.
struct CredentialPromptCardView: View {
    @Environment(\.colorScheme) private var colorScheme
    let request: CredentialPromptRequest
    /// Why "Enter password" cannot bring the session forward, if it cannot.
    let revealNote: String?
    var onEnterPassword: () -> Void
    var onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .foregroundStyle(.orange)
                Text(Self.title(for: request))
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(request.command)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
                )

            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text(Self.status(for: request))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let revealNote {
                Text(revealNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Decline", role: .destructive, action: onDecline)
                    .buttonStyle(.bordered)
                Spacer()
                Button("Enter password", action: onEnterPassword)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(colorScheme == .dark ? Color.orange.opacity(0.14) : Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.orange.opacity(0.45), lineWidth: 1)
        )
    }

    static func title(for request: CredentialPromptRequest) -> String {
        let host = request.hostLabel
        switch request.kind {
        case .sudo: return "\(host) is asking for your sudo password"
        case .password: return "\(host) is asking for a password"
        case .sshPassword: return "\(host) is asking for an SSH password"
        case .keyPassphrase: return "\(host) is asking for a key passphrase"
        }
    }

    static func status(for request: CredentialPromptRequest) -> String {
        switch request.phase {
        case .waiting: return "Waiting for your password on \(request.hostLabel)…"
        case .verifying: return "Checking…"
        }
    }
}
