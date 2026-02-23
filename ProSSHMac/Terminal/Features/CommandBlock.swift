import Foundation

enum CommandBoundarySource: String, Codable, Hashable, Sendable {
    case osc133
    case heuristicPrompt
    case userInput
    case rawInput
}

struct CommandBlock: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let sessionID: UUID
    let command: String
    let output: String
    let startedAt: Date
    let completedAt: Date
    let exitCode: Int?
    let boundarySource: CommandBoundarySource
}

enum SemanticPromptEvent: Equatable, Sendable {
    case promptStart
    case promptEnd
    case commandStart
    case commandEnd(exitCode: Int?)
}
