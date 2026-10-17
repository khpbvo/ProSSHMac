// SessionManager+CredentialPrompt.swift
// ProSSHMac
//
// The copilot's password-prompt wait as the chat sees it: one published request, plus decline
// and cancel. The state lives in SessionAIToolCoordinator. See Docs/CredentialPrompt.md.
import Foundation
@preconcurrency import Combine

/// A copilot command paused at a password prompt, for the card in the chat.
struct CredentialPromptRequest: Identifiable, Equatable, Sendable {
    /// The wait's id: a new wait on the same session is a new card.
    let id: UUID
    let sessionID: UUID
    let hostLabel: String
    let prompt: String
    let kind: CredentialPromptDetector.Kind
    let command: String
    let phase: CredentialWait.Phase
}

/// What the chat needs from the session layer to show and answer a password prompt.
@MainActor
protocol CredentialPromptHandling: AnyObject {
    var credentialPromptPublisher: AnyPublisher<CredentialPromptRequest?, Never> { get }
    func declineCredentialPrompt(sessionID: UUID) async
    func cancelCredentialPrompts() async
}

extension SessionManager: CredentialPromptHandling {
    var credentialPromptPublisher: AnyPublisher<CredentialPromptRequest?, Never> {
        $credentialPrompt.removeDuplicates().eraseToAnyPublisher()
    }

    /// Called by the coordinator on every change to its waits.
    func credentialWaitsDidChange() {
        // At most one wait today: tool calls run one after another.
        let request = aiToolCoordinator.awaitingCredential.values
            .min(by: { $0.startedAt < $1.startedAt })
            .map { wait in
                CredentialPromptRequest(
                    id: wait.id,
                    sessionID: wait.sessionID,
                    hostLabel: sessions.first(where: { $0.id == wait.sessionID })?.hostLabel ?? "this session",
                    prompt: wait.prompt,
                    kind: wait.kind,
                    command: wait.command,
                    phase: wait.phase
                )
            }
        if credentialPrompt != request {
            credentialPrompt = request
        }
    }

    /// Ctrl+C the prompt and return the paused command to the model as declined.
    func declineCredentialPrompt(sessionID: UUID) async {
        await aiToolCoordinator.declineCredentialPrompt(sessionID: sessionID)
    }

    /// Stop or Clear: Ctrl+C every waiting host.
    func cancelCredentialPrompts() async {
        await aiToolCoordinator.cancelCredentialPrompts()
    }

    /// Whether keys typed in this session now are a password. Broadcast input uses it so a
    /// password never reaches the other hosts.
    func isEnteringCredential(sessionID: UUID) -> Bool {
        aiToolCoordinator.isEnteringCredential(sessionID: sessionID)
    }
}
