import SwiftUI

struct SettingsView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var auditLogManager: AuditLogManager
    @AppStorage("app.appearance") private var appAppearanceRawValue = AppAppearance.system.rawValue
    @AppStorage("terminal.effects.crtEnabled") private var terminalCRTEffectEnabled = false
    @AppStorage(BellEffectController.settingsKey) private var terminalBellFeedbackMode = BellFeedbackMode.none.rawValue
    @AppStorage(TransparencyManager.backgroundOpacityKey) private var terminalBackgroundOpacityPercent = TransparencyManager.defaultBackgroundOpacityPercent
    @State private var allowLegacyByDefault = false
    @AppStorage("terminal.scrollback.maxLines") private var terminalScrollback = 10_000
    @AppStorage("ssh.keepalive.enabled") private var keepaliveEnabled = false
    @AppStorage("ssh.keepalive.interval") private var keepaliveInterval = 30
    @State private var operationMessage: String?
    @State private var showingClearAuditConfirmation = false

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appAppearanceRawValue) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Text("System follows iOS. Use Dark for always-on low-light operation.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Algorithms") {
                Toggle("Allow Legacy Algorithms by Default", isOn: $allowLegacyByDefault)
            }

            Section("Terminal") {
                Stepper("Scrollback: \(terminalScrollback) lines", value: $terminalScrollback, in: 1_000...50_000, step: 1_000)
                Toggle("Enable CRT Effect (Experimental)", isOn: $terminalCRTEffectEnabled)

                NavigationLink {
                    GradientBackgroundSettingsView()
                } label: {
                    HStack {
                        Label("Gradient Background", systemImage: "paintpalette")
                        Spacer()
                        if GradientBackgroundConfiguration.load().isEnabled {
                            Text("On")
                                .font(.subheadline)
                                .foregroundStyle(.purple)
                        }
                    }
                }

                NavigationLink {
                    ScannerEffectSettingsView()
                } label: {
                    HStack {
                        Label("Scanner Effect (KITT)", systemImage: "light.max")
                        Spacer()
                        if ScannerEffectConfiguration.load().isEnabled {
                            Text("On")
                                .font(.subheadline)
                                .foregroundStyle(.red)
                        }
                    }
                }

                NavigationLink {
                    PromptAppearanceSettingsView()
                } label: {
                    HStack {
                        Label("Prompt Colors", systemImage: "textformat.abc")
                        Spacer()
                        Text(PromptAppearanceConfiguration.load().usernameStyle.title)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                NavigationLink {
                    MatrixScreensaverSettingsView()
                } label: {
                    let screensaverConfig = MatrixScreensaverConfiguration.load()
                    HStack {
                        Label("Matrix Screensaver", systemImage: "sparkles.tv")
                        Spacer()
                        if screensaverConfig.isEnabled {
                            Text("\(screensaverConfig.idleTimeoutMinutes) min")
                                .font(.subheadline)
                                .foregroundStyle(.green)
                        } else {
                            Text("Off")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Background Opacity")
                        Spacer()
                        Text("\(Int(TransparencyManager.clampBackgroundOpacityPercent(terminalBackgroundOpacityPercent).rounded()))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: terminalBackgroundOpacityBinding, in: 0...100, step: 1)
                }

                Picker("Bell Feedback", selection: $terminalBellFeedbackMode) {
                    ForEach(BellFeedbackMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
            }

            Section("SSH Keepalive") {
                Toggle("Enable Keepalive", isOn: $keepaliveEnabled)

                Picker("Interval", selection: $keepaliveInterval) {
                    Text("15 seconds").tag(15)
                    Text("30 seconds").tag(30)
                    Text("60 seconds").tag(60)
                }
                .disabled(!keepaliveEnabled)

                Text("Sends periodic packets to keep connections alive and detect dead sessions early. Takes effect on new connections.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if supportsMultitaskingControls {
                Section("Multitasking") {
                    Button("Open Terminal in New Window", systemImage: "rectangle.on.rectangle") {
                        openWindow(id: ProSSHMacApp.externalTerminalWindowID)
                    }

                    Text("Use this with iPad Split View, Slide Over, or move the new window to an external display.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Hardware Keyboard") {
                Text("Navigation: ⌘1 Hosts, ⌘2 Terminal, ⌘3 KeyForge, ⌘4 Certificates, ⌘5 Transfers, ⌘6 Settings")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Terminal: ⌘↩ send, ⌃C interrupt, ⌃D EOF, ⇧⌘[ previous session, ⇧⌘] next session, ⇧⌘X disconnect/close, ⌘K clear buffer")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Security") {
                Label("Secure Enclave integration coming in KeyForge/CertAuthority phases.", systemImage: "lock.shield")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Audit Log") {
                Toggle("Enable Audit Log", isOn: $auditLogManager.isEnabled)

                Text("Recent Entries: \(auditLogManager.entries.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if auditLogManager.entries.isEmpty {
                    Text("No audit entries recorded yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(auditLogManager.entries.prefix(10))) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(entry.category.title) • \(entry.action)")
                                .font(.subheadline)
                            Text(entry.timestamp.formatted(date: .abbreviated, time: .standard))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let details = entry.details, !details.isEmpty {
                                Text(details)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }

                Button("Copy Audit Export (Text)", systemImage: "doc.on.doc") {
                    Task {
                        PlatformClipboard.writeString(await auditLogManager.exportPlainText())
                        operationMessage = "Audit log text export copied."
                    }
                }

                Button("Copy Audit Export (CSV)", systemImage: "tablecells") {
                    Task {
                        PlatformClipboard.writeString(await auditLogManager.exportCSV())
                        operationMessage = "Audit log CSV export copied."
                    }
                }

                Button("Copy Audit Export (JSON)", systemImage: "curlybraces") {
                    Task {
                        PlatformClipboard.writeString(await auditLogManager.exportJSON())
                        operationMessage = "Audit log JSON export copied."
                    }
                }

                Button("Clear Audit Log", role: .destructive) {
                    showingClearAuditConfirmation = true
                }
            }

            Section("Known Hosts") {
                Text("Trusted Entries: \(sessionManager.knownHosts.count)")

                if sessionManager.knownHosts.isEmpty {
                    Text("No trusted hosts yet. You will be prompted to trust a host key after a successful SSH handshake.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sessionManager.knownHosts) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(entry.hostname):\(entry.port)")
                                .font(.subheadline)
                            Text("\(entry.hostKeyType) • \(entry.fingerprint)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                }

                if !sessionManager.knownHosts.isEmpty {
                    Button("Clear Known Hosts", role: .destructive) {
                        Task {
                            await sessionManager.clearKnownHosts()
                        }
                    }
                }
            }
        }
        .navigationTitle("Settings")
        .task {
            await auditLogManager.refresh()
            await sessionManager.refreshKnownHosts()
        }
        .confirmationDialog(
            "Clear audit log?",
            isPresented: $showingClearAuditConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                Task {
                    await auditLogManager.clearAll()
                    operationMessage = "Audit log cleared."
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes all recorded audit entries.")
        }
        .alert(
            "Settings",
            isPresented: Binding(
                get: { operationMessage != nil },
                set: { if !$0 { operationMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                operationMessage = nil
            }
        } message: {
            Text(operationMessage ?? "")
        }
    }

    private var supportsMultitaskingControls: Bool {
        horizontalSizeClass == .regular && PlatformDevice.isPad
    }

    private var terminalBackgroundOpacityBinding: Binding<Double> {
        Binding(
            get: {
                TransparencyManager.clampBackgroundOpacityPercent(terminalBackgroundOpacityPercent)
            },
            set: { newValue in
                terminalBackgroundOpacityPercent = TransparencyManager.clampBackgroundOpacityPercent(newValue)
            }
        )
    }
}
