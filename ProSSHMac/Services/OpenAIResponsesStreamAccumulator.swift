// Extracted from OpenAIResponsesService.swift
import Foundation

struct StreamingResponseAccumulator {
    var responseID: String?
    var status: String?
    private var outputItemsByID: [String: OpenAIResponsesResponse.OutputItem] = [:]
    private var outputItemsNoID: [OpenAIResponsesResponse.OutputItem] = []
    private var outputOrderByItemID: [String: Int] = [:]
    private var fallbackText = ""
    private var fallbackTextFinal: String?
    private var functionCallArgumentsByItemID: [String: String] = [:]

    var assembledResponse: OpenAIResponsesResponse? {
        guard let responseID else { return nil }
        return OpenAIResponsesResponse(
            id: responseID,
            status: status,
            outputText: nil,
            output: buildOutputItems()
        )
    }

    mutating func ingest(type: String, payload: [String: Any]) {
        if responseID == nil {
            responseID = payload["response_id"] as? String
        }
        if responseID == nil {
            responseID = payload["id"] as? String
        }
        if let outputIndex = payload["output_index"] as? Int,
           let itemID = payload["item_id"] as? String {
            outputOrderByItemID[itemID] = outputIndex
        }

        if let responseObject = payload["response"] as? [String: Any] {
            ingestResponseObject(responseObject)
        }

        switch type {
        case "response.created":
            status = "created"
        case "response.in_progress":
            status = "in_progress"
        case "response.completed":
            status = "completed"
        case "response.failed":
            status = "failed"
        case "response.output_item.added",
             "response.output_item.done":
            if let itemObject = payload["item"] {
                ingestOutputItem(itemObject, outputIndex: payload["output_index"] as? Int)
            }
        case "response.function_call_arguments.delta":
            ingestFunctionCallArgumentsDelta(payload)
        case "response.function_call_arguments.done":
            ingestFunctionCallArgumentsDone(payload)
        case "response.text.delta",
             "response.output_text.delta":
            ingestTextDelta(payload)
        case "response.text.done",
             "response.output_text.done":
            ingestTextDone(payload)
        case "response.refusal.delta":
            ingestRefusalDelta(payload)
        case "response.refusal.done":
            ingestRefusalDone(payload)
        case "response.content_part.added":
            ingestContentPart(payload, isDone: false)
        case "response.content_part.done":
            ingestContentPart(payload, isDone: true)
        default:
            break
        }
    }

    private mutating func ingestResponseObject(_ responseObject: [String: Any]) {
        if let id = responseObject["id"] as? String, !id.isEmpty {
            responseID = id
        }
        if let statusValue = responseObject["status"] as? String, !statusValue.isEmpty {
            status = statusValue
        }
        if let outputValue = responseObject["output"] as? [Any], !outputValue.isEmpty {
            for (index, itemObject) in outputValue.enumerated() {
                ingestOutputItem(itemObject, outputIndex: index)
            }
        }
    }

    private mutating func ingestOutputItem(_ itemObject: Any, outputIndex: Int?) {
        guard let item = parseOutputItem(itemObject) else { return }
        if let itemID = item.id {
            outputItemsByID[itemID] = item
            if let outputIndex {
                outputOrderByItemID[itemID] = outputIndex
            }
        } else {
            outputItemsNoID.append(item)
        }
    }

    private mutating func ingestFunctionCallArgumentsDelta(_ payload: [String: Any]) {
        guard let itemID = payload["item_id"] as? String else { return }
        let delta = payload["delta"] as? String ?? ""
        guard !delta.isEmpty else { return }
        functionCallArgumentsByItemID[itemID, default: ""] += delta
    }

    private mutating func ingestFunctionCallArgumentsDone(_ payload: [String: Any]) {
        guard let itemID = payload["item_id"] as? String else { return }
        let doneArgs = payload["arguments"] as? String
        if let doneArgs {
            functionCallArgumentsByItemID[itemID] = doneArgs
        } else if functionCallArgumentsByItemID[itemID] == nil {
            functionCallArgumentsByItemID[itemID] = ""
        }
    }

    private mutating func ingestTextDelta(_ payload: [String: Any]) {
        guard let delta = payload["delta"] as? String, !delta.isEmpty else { return }
        if let itemID = payload["item_id"] as? String {
            appendText(delta, toMessageItemID: itemID)
        } else {
            fallbackText += delta
        }
    }

    private mutating func ingestTextDone(_ payload: [String: Any]) {
        guard let text = payload["text"] as? String, !text.isEmpty else { return }
        if let itemID = payload["item_id"] as? String {
            setText(text, toMessageItemID: itemID)
        } else {
            fallbackTextFinal = text
        }
    }

    private mutating func ingestRefusalDelta(_ payload: [String: Any]) {
        guard let delta = payload["delta"] as? String, !delta.isEmpty else { return }
        if let itemID = payload["item_id"] as? String {
            appendText(delta, toMessageItemID: itemID)
        } else {
            fallbackText += delta
        }
    }

    private mutating func ingestRefusalDone(_ payload: [String: Any]) {
        let text = (payload["refusal"] as? String) ?? (payload["text"] as? String) ?? ""
        guard !text.isEmpty else { return }
        if let itemID = payload["item_id"] as? String {
            setText(text, toMessageItemID: itemID)
        } else {
            fallbackTextFinal = text
        }
    }

    private mutating func ingestContentPart(_ payload: [String: Any], isDone: Bool) {
        guard let itemID = payload["item_id"] as? String,
              let part = payload["part"] as? [String: Any] else {
            return
        }
        let type = part["type"] as? String
        guard type == "text" || type == "output_text" else { return }
        let text = part["text"] as? String ?? ""
        guard !text.isEmpty else { return }
        if isDone {
            setText(text, toMessageItemID: itemID)
        } else {
            appendText(text, toMessageItemID: itemID)
        }
    }

    private mutating func appendText(_ delta: String, toMessageItemID itemID: String) {
        var item = messageItem(for: itemID)
        let existing = item.content?.first?.text ?? ""
        item.content = [.init(type: "output_text", text: existing + delta)]
        outputItemsByID[itemID] = item
    }

    private mutating func setText(_ text: String, toMessageItemID itemID: String) {
        var item = messageItem(for: itemID)
        item.content = [.init(type: "output_text", text: text)]
        outputItemsByID[itemID] = item
    }

    private func messageItem(for itemID: String) -> OpenAIResponsesResponse.OutputItem {
        if let existing = outputItemsByID[itemID] {
            return existing
        }
        return OpenAIResponsesResponse.OutputItem(
            type: "message",
            id: itemID,
            role: "assistant",
            content: [.init(type: "output_text", text: "")],
            name: nil,
            callID: nil,
            arguments: nil
        )
    }

    private func parseOutputItem(_ value: Any) -> OpenAIResponsesResponse.OutputItem? {
        if let decoded = OpenAIResponsesService.decodeJSONValue(
            value,
            as: OpenAIResponsesResponse.OutputItem.self
        ) {
            return decoded
        }

        guard let itemDict = value as? [String: Any] else { return nil }
        let type = itemDict["type"] as? String ?? "message"
        let id = itemDict["id"] as? String
        let role = itemDict["role"] as? String
        let name = itemDict["name"] as? String
        let callID = (itemDict["call_id"] as? String) ?? (itemDict["callID"] as? String)
        let arguments = itemDict["arguments"] as? String

        var contentItems: [OpenAIResponsesResponse.ContentItem] = []
        if let contentArray = itemDict["content"] as? [Any] {
            for part in contentArray {
                guard let partDict = part as? [String: Any] else { continue }
                let partType = partDict["type"] as? String ?? "text"
                let text = partDict["text"] as? String
                contentItems.append(.init(type: partType, text: text))
            }
        } else if let text = itemDict["text"] as? String {
            contentItems = [.init(type: "output_text", text: text)]
        }

        return OpenAIResponsesResponse.OutputItem(
            type: type,
            id: id,
            role: role,
            content: contentItems.isEmpty ? nil : contentItems,
            name: name,
            callID: callID,
            arguments: arguments
        )
    }

    private func buildOutputItems() -> [OpenAIResponsesResponse.OutputItem] {
        var mergedByID = outputItemsByID
        var orderByItemID = outputOrderByItemID

        for (itemID, arguments) in functionCallArgumentsByItemID {
            var item = mergedByID[itemID] ?? OpenAIResponsesResponse.OutputItem(
                type: "function_call",
                id: itemID,
                role: nil,
                content: nil,
                name: nil,
                callID: nil,
                arguments: nil
            )
            if item.type != "function_call" {
                item.type = "function_call"
                item.role = nil
                item.content = nil
            }
            item.arguments = arguments
            mergedByID[itemID] = item
        }

        let fallbackFinalText = fallbackTextFinal ?? (fallbackText.isEmpty ? nil : fallbackText)
        if let fallbackFinalText, !fallbackFinalText.isEmpty {
            if let firstMessageID = mergedByID.first(where: { $0.value.type == "message" })?.key {
                var item = mergedByID[firstMessageID]!
                item.content = [.init(type: "output_text", text: fallbackFinalText)]
                mergedByID[firstMessageID] = item
            } else if mergedByID.isEmpty {
                let syntheticID = "msg_stream_text"
                mergedByID[syntheticID] = OpenAIResponsesResponse.OutputItem(
                    type: "message",
                    id: syntheticID,
                    role: "assistant",
                    content: [.init(type: "output_text", text: fallbackFinalText)],
                    name: nil,
                    callID: nil,
                    arguments: nil
                )
                if orderByItemID[syntheticID] == nil {
                    orderByItemID[syntheticID] = 0
                }
            }
        }

        var result = mergedByID
            .sorted { lhs, rhs in
                let l = orderByItemID[lhs.key] ?? Int.max
                let r = orderByItemID[rhs.key] ?? Int.max
                if l == r { return lhs.key < rhs.key }
                return l < r
            }
            .map(\.value)
        result.append(contentsOf: outputItemsNoID)
        return result
    }
}
