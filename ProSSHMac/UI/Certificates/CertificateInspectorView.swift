import SwiftUI
import AppKit

struct CertificateInspectorView: View {
    let certificate: SSHCertificate

    @State private var copiedMessage: String?

    var body: some View {
        List {
            Section("Summary") {
                LabeledContent("Key ID", value: certificate.keyId)
                LabeledContent("Type", value: certificate.type.rawValue.capitalized)
                LabeledContent("Serial", value: String(certificate.serialNumber))
                LabeledContent("Status", value: statusLabel)
                    .foregroundStyle(statusColor)
                LabeledContent("Signature", value: certificate.signatureAlgorithm)
                LabeledContent("Created", value: certificate.createdAt.formatted(date: .abbreviated, time: .shortened))
            }

            Section("Validity Timeline") {
                CertificateValidityTimelineView(
                    validAfter: certificate.validAfter,
                    validBefore: certificate.validBefore,
                    now: .now
                )
                .frame(height: 56)

                LabeledContent("Valid After", value: certificate.validAfter.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Valid Before", value: certificate.validBefore.formatted(date: .abbreviated, time: .shortened))
            }

            Section("Principals") {
                if certificate.principals.isEmpty {
                    Text("No principals encoded.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(certificate.principals, id: \.self) { principal in
                        Text(principal)
                            .font(.body.monospaced())
                    }
                }
            }

            Section("Critical Options") {
                if certificate.criticalOptions.isEmpty {
                    Text("No critical options set.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(certificate.criticalOptions.keys.sorted(), id: \.self) { key in
                        let value = certificate.criticalOptions[key] ?? ""
                        LabeledContent(key, value: value.isEmpty ? "(empty)" : value)
                            .font(.body.monospaced())
                    }
                }
            }

            Section("Extensions") {
                if certificate.extensions.isEmpty {
                    Text("No extensions set.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(certificate.extensions, id: \.self) { ext in
                        Text(ext)
                            .font(.body.monospaced())
                    }
                }
            }

            Section("Fingerprints") {
                Text("Signing CA: \(certificate.signingCAFingerprint)")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Text("Signed Key: \(certificate.signedKeyFingerprint)")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }

            Section("Data") {
                if let importedFrom = certificate.importedFrom, !importedFrom.isEmpty {
                    LabeledContent("Source", value: importedFrom)
                }

                Button("Copy Signed Certificate") {
                    let payload = certificate.authorizedRepresentation ?? certificate.rawCertificateData.base64EncodedString()
                    copiedMessage = copyToClipboard(payload)
                        ? "Signed certificate copied."
                        : "Clipboard is unavailable on this platform."
                }

                if let authorizedRepresentation = certificate.authorizedRepresentation, !authorizedRepresentation.isEmpty {
                    Text(authorizedRepresentation)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                } else {
                    Text(certificate.rawCertificateData.base64EncodedString())
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Certificate Inspector")
        .iosInlineNavigationBarTitleDisplayMode()
        .alert(
            "Certificate Inspector",
            isPresented: Binding(
                get: { copiedMessage != nil },
                set: { if !$0 { copiedMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                copiedMessage = nil
            }
        } message: {
            Text(copiedMessage ?? "")
        }
    }

    private var statusLabel: String {
        if Date() < certificate.validAfter {
            return "Not Yet Valid"
        }
        if Date() > certificate.validBefore {
            return "Expired"
        }
        return "Active"
    }

    private var statusColor: Color {
        switch statusLabel {
        case "Active":
            return .green
        case "Expired":
            return .red
        default:
            return .orange
        }
    }
}

private func copyToClipboard(_ value: String) -> Bool {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
    return true
}

private struct CertificateValidityTimelineView: View {
    let validAfter: Date
    let validBefore: Date
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                let width = geometry.size.width
                let markerX = markerPosition(width: width)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.22))
                        .frame(height: 8)

                    Capsule()
                        .fill(fillColor)
                        .frame(width: activeWidth(width: width), height: 8)

                    Circle()
                        .fill(fillColor)
                        .frame(width: 12, height: 12)
                        .offset(x: markerX - 6, y: -2)
                }
            }
            .frame(height: 12)

            HStack {
                Text(validAfter.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(validBefore.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var fillColor: Color {
        if now < validAfter {
            return .orange
        }
        if now > validBefore {
            return .red
        }
        return .green
    }

    private func markerPosition(width: CGFloat) -> CGFloat {
        let duration = validBefore.timeIntervalSince(validAfter)
        if duration <= 0 {
            return 0
        }

        let progress = (now.timeIntervalSince(validAfter) / duration).clamped(to: 0...1)
        return width * progress
    }

    private func activeWidth(width: CGFloat) -> CGFloat {
        if now < validAfter {
            return 0
        }
        if now > validBefore {
            return width
        }
        return markerPosition(width: width)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
