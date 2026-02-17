import SwiftUI
import UniformTypeIdentifiers

struct TransfersView: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var transferManager: TransferManager

    @State private var selectedSessionID: UUID?
    @State private var showFileImporter = false

    var body: some View {
        List {
            Section("Session") {
                if connectedSessions.isEmpty {
                    Text("Connect to a host first to use SFTP transfers.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Active SSH Session", selection: $selectedSessionID) {
                        ForEach(connectedSessions) { session in
                            Text("\(session.hostLabel) (\(session.username)@\(session.hostname))")
                                .tag(Optional(session.id))
                        }
                    }
                    .pickerStyle(.menu)
                }
            }

            Section("Remote Browser") {
                HStack {
                    Label(transferManager.currentRemotePath, systemImage: "folder")
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Button {
                        transferManager.navigateUp()
                    } label: {
                        Image(systemName: "arrow.up.to.line")
                    }
                    .disabled(transferManager.currentRemotePath == "/" || selectedSessionID == nil)

                    Button {
                        Task {
                            await transferManager.refreshDirectory()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(selectedSessionID == nil)

                    Button {
                        showFileImporter = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(selectedSessionID == nil)
                }

                if transferManager.isListing {
                    ProgressView("Loading directory...")
                } else if transferManager.remoteEntries.isEmpty {
                    Text(selectedSessionID == nil ? "No active session selected." : "Directory is empty.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(transferManager.remoteEntries) { entry in
                        remoteRow(for: entry)
                    }
                }
            }

            Section("Transfer Queue") {
                if transferManager.transfers.isEmpty {
                    Text("No transfers queued.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(transferManager.transfers) { transfer in
                        transferRow(transfer)
                    }

                    if transferManager.transfers.contains(where: isFinishedTransfer) {
                        Button("Clear Finished") {
                            transferManager.clearFinishedTransfers()
                        }
                    }
                }
            }
        }
        .navigationTitle("Transfers")
        .task {
            transferManager.configure(sessionManager: sessionManager)
            synchronizeSelectedSession()
        }
        .onChange(of: connectedSessionIDs) { _, _ in
            synchronizeSelectedSession()
        }
        .onChange(of: selectedSessionID) { _, newValue in
            transferManager.setActiveSession(newValue)
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.data, .item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                guard let url = urls.first else { return }
                transferManager.enqueueUpload(localFileURL: url)
            case let .failure(error):
                transferManager.errorMessage = "Unable to select file for upload: \(error.localizedDescription)"
            }
        }
        .alert(
            "Transfers",
            isPresented: Binding(
                get: { transferManager.errorMessage != nil },
                set: { if !$0 { transferManager.clearError() } }
            )
        ) {
            Button("OK", role: .cancel) {
                transferManager.clearError()
            }
        } message: {
            Text(transferManager.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func remoteRow(for entry: SFTPDirectoryEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(entry.isDirectory ? .blue : .secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .lineLimit(1)

                if entry.isDirectory == false {
                    Text(byteCount(entry.size))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if entry.isDirectory {
                Button("Open") {
                    transferManager.openDirectory(entry)
                }
                .buttonStyle(.bordered)
            } else {
                Button("Download") {
                    transferManager.enqueueDownload(entry: entry)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private func transferRow(_ transfer: Transfer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(transfer.direction == .download ? "Download" : "Upload")
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Text(transfer.state.rawValue.capitalized)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(stateColor(transfer.state).opacity(0.2), in: Capsule())
                    .foregroundStyle(stateColor(transfer.state))
            }

            Text(transferSummary(transfer))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if transfer.totalBytes > 0 {
                ProgressView(value: Double(transfer.bytesTransferred), total: Double(transfer.totalBytes))
                Text("\(byteCount(transfer.bytesTransferred)) / \(byteCount(transfer.totalBytes))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                if transfer.state == .queued {
                    Button("Pause") {
                        transferManager.pauseTransfer(transfer.id)
                    }
                    .buttonStyle(.bordered)
                }

                if transfer.state == .paused {
                    Button("Resume") {
                        transferManager.resumeTransfer(transfer.id)
                    }
                    .buttonStyle(.borderedProminent)
                }

                if transfer.state == .queued || transfer.state == .paused || transfer.state == .running {
                    Button("Cancel", role: .destructive) {
                        transferManager.cancelTransfer(transfer.id)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var connectedSessions: [Session] {
        sessionManager.sessions.filter { $0.state == .connected }
    }

    private var connectedSessionIDs: [UUID] {
        connectedSessions.map(\.id)
    }

    private func synchronizeSelectedSession() {
        if let selectedSessionID,
           connectedSessions.contains(where: { $0.id == selectedSessionID }) {
            return
        }

        selectedSessionID = connectedSessions.first?.id
        transferManager.setActiveSession(selectedSessionID)
    }

    private func transferSummary(_ transfer: Transfer) -> String {
        let source = URL(fileURLWithPath: transfer.sourcePath).lastPathComponent
        let destination = URL(fileURLWithPath: transfer.destinationPath).lastPathComponent
        if transfer.direction == .download {
            return "\(source) -> \(destination)"
        }
        return "\(source) -> \(transfer.destinationPath)"
    }

    private func byteCount(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func stateColor(_ state: TransferState) -> Color {
        switch state {
        case .queued:
            return .orange
        case .running:
            return .blue
        case .paused:
            return .yellow
        case .completed:
            return .green
        case .failed:
            return .red
        case .cancelled:
            return .gray
        }
    }

    private func isFinishedTransfer(_ transfer: Transfer) -> Bool {
        transfer.state == .completed || transfer.state == .failed || transfer.state == .cancelled
    }
}
