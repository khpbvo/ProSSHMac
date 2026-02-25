// Extracted from OpenAIResponsesService.swift
import Foundation

struct CreateRequestPayload: Encodable {
    struct Reasoning: Encodable {
        var summary: String
    }

    var model: String
    var input: [CreateInputItem]
    var tools: [OpenAIResponsesToolDefinition]?
    var previousResponseID: String?
    var stream: Bool?
    var reasoning: Reasoning?

    enum CodingKeys: String, CodingKey {
        case model
        case input
        case tools
        case previousResponseID = "previous_response_id"
        case stream
        case reasoning
    }
}

enum CreateInputItem: Encodable {
    case message(CreateInputMessage)
    case functionCallOutput(CreateFunctionCallOutput)

    func encode(to encoder: any Encoder) throws {
        switch self {
        case let .message(message):
            try message.encode(to: encoder)
        case let .functionCallOutput(output):
            try output.encode(to: encoder)
        }
    }
}

struct CreateInputMessage: Encodable {
    struct Content: Encodable {
        var type = "input_text"
        var text: String
    }

    var type = "message"
    var role: String
    var content: [Content]

    init(message: OpenAIResponsesMessage) {
        self.role = message.role.rawValue
        self.content = [Content(text: message.text)]
    }
}

struct CreateFunctionCallOutput: Encodable {
    var type = "function_call_output"
    var callID: String
    var output: String

    enum CodingKeys: String, CodingKey {
        case type
        case callID = "call_id"
        case output
    }

    init(output: OpenAIResponsesToolOutput) {
        callID = output.callID
        self.output = output.output
    }
}

struct OpenAIErrorEnvelope: Decodable {
    struct APIError: Decodable {
        var message: String
        var type: String?
        var code: String?
    }

    var error: APIError
}
