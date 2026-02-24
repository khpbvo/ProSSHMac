// Extracted from TerminalView.swift
import SwiftUI
import Metal

struct TerminalSessionActionsBar: View {
    let session: Session
    var onRestartLocal: (Session) -> Void

    @EnvironmentObject private var sessionManager: SessionManager
    @AppStorage("terminal.renderer.useMetal") private var useMetalRenderer = true

    var body: some View {
        let isRecording = sessionManager.isRecordingBySessionID[session.id, default: false]
        let hasRecording = sessionManager.hasRecordingBySessionID[session.id, default: false]
        let isPlaybackRunning = sessionManager.isPlaybackRunningBySessionID[session.id, default: false]

        HStack {
            if session.state == .connected {
                Button {
                    sessionManager.clearShellBuffer(sessionID: session.id)
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .buttonStyle(.bordered)

                if isRecording {
                    Button {
                        Task {
                            await sessionManager.toggleRecording(sessionID: session.id)
                        }
                    } label: {
                        Label("Stop Rec", systemImage: "stop.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else {
                    Button {
                        Task {
                            await sessionManager.toggleRecording(sessionID: session.id)
                        }
                    } label: {
                        Label("Record", systemImage: "record.circle")
                    }
                    .buttonStyle(.bordered)
                }
            }

            Menu {
                Button("Play 1x") {
                    Task {
                        await sessionManager.playLastRecording(sessionID: session.id, speed: 1.0)
                    }
                }
                Button("Play 2x") {
                    Task {
                        await sessionManager.playLastRecording(sessionID: session.id, speed: 2.0)
                    }
                }
                Button("Play 4x") {
                    Task {
                        await sessionManager.playLastRecording(sessionID: session.id, speed: 4.0)
                    }
                }
                Divider()
                Button("Export .cast") {
                    Task {
                        await sessionManager.exportLastRecordingAsCast(sessionID: session.id)
                    }
                }
            } label: {
                Label(isPlaybackRunning ? "Playing" : "Playback", systemImage: "play.circle")
            }
            .disabled(!hasRecording || isRecording || isPlaybackRunning)

            Menu {
                Button(useMetalRenderer ? "Switch to Classic" : "Switch to Metal") {
                    useMetalRenderer.toggle()
                }
                .disabled(!isMetalRendererToggleEnabled)

                if !isMetalRendererAvailable {
                    Text("Metal unavailable on this device")
                }
            } label: {
                Label("Display", systemImage: useMetalRenderer ? "display.2" : "display")
            }

            Spacer()

            if session.state == .connected {
                Button(role: .destructive) {
                    Task {
                        await sessionManager.disconnect(sessionID: session.id)
                    }
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
            } else {
                if session.isLocal {
                    Button {
                        onRestartLocal(session)
                    } label: {
                        Label("Restart Shell", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                }

                Button(role: .destructive) {
                    Task {
                        await sessionManager.closeSession(sessionID: session.id)
                    }
                } label: {
                    Label("Close", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var isMetalRendererAvailable: Bool {
        MTLCreateSystemDefaultDevice() != nil
    }

    private var isMetalRendererToggleEnabled: Bool {
        isMetalRendererAvailable
    }
}
