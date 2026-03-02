// Extracted from OpenAIResponsesService.swift
import Foundation
import os.log

extension OpenAIResponsesService {

    func createResponseStreaming(
        _ request: OpenAIResponsesRequest,
        onEvent: @escaping @Sendable (OpenAIResponsesStreamEvent) -> Void
    ) async throws -> OpenAIResponsesResponse {
        let apiKey = await apiKeyProvider.apiKey(for: .openai)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let apiKey, !apiKey.isEmpty else {
            throw OpenAIResponsesServiceError.missingAPIKey
        }

        let traceID = Self.shortTraceID()
        Self.logger.debug(
            "[\(traceID, privacy: .public)] stream_request_start messages=\(request.messages.count) tools=\(request.tools.count) tool_outputs=\(request.toolOutputs.count) prev_id_present=\(request.previousResponseID != nil)"
        )

        var attempt = 0
        while true {
            let attemptStart = DispatchTime.now().uptimeNanoseconds
            do {
                let response = try await performStreamingRequest(
                    apiKey: apiKey,
                    request: request,
                    onEvent: onEvent,
                    traceID: traceID
                )
                let ms = Self.elapsedMillis(since: attemptStart)
                Self.logger.info(
                    "[\(traceID, privacy: .public)] stream_request_ok attempt=\(attempt + 1) ms=\(ms) response_id=\(response.id, privacy: .public) output_items=\(response.output.count)"
                )
                return response
            } catch let serviceError as OpenAIResponsesServiceError {
                let ms = Self.elapsedMillis(since: attemptStart)
                var effectiveError = serviceError

                if case .invalidResponse = serviceError {
                    Self.logger.warning(
                        "[\(traceID, privacy: .public)] stream_fallback_start attempt=\(attempt + 1) reason=invalid_response"
                    )
                    do {
                        let fallbackResponse = try await performRequest(
                            apiKey: apiKey,
                            request: request,
                            traceID: traceID
                        )
                        let fallbackText = fallbackResponse.text
                        if !fallbackText.isEmpty {
                            onEvent(.outputTextDone(fallbackText))
                        }
                        Self.logger.info(
                            "[\(traceID, privacy: .public)] stream_fallback_ok attempt=\(attempt + 1) response_id=\(fallbackResponse.id, privacy: .public)"
                        )
                        return fallbackResponse
                    } catch let fallbackError as OpenAIResponsesServiceError {
                        effectiveError = fallbackError
                        Self.logger.warning(
                            "[\(traceID, privacy: .public)] stream_fallback_failed attempt=\(attempt + 1) reason=\(fallbackError.localizedDescription, privacy: .public)"
                        )
                    }
                }

                let willRetry = shouldRetry(after: effectiveError, attempt: attempt)
                if willRetry {
                    let nextAttempt = attempt + 2
                    Self.logger.warning(
                        "[\(traceID, privacy: .public)] stream_request_retry attempt=\(attempt + 1) ms=\(ms) next_attempt=\(nextAttempt) reason=\(effectiveError.localizedDescription, privacy: .public)"
                    )
                } else {
                    Self.logger.error(
                        "[\(traceID, privacy: .public)] stream_request_failed attempt=\(attempt + 1) ms=\(ms) reason=\(effectiveError.localizedDescription, privacy: .public)"
                    )
                }
                guard willRetry else {
                    throw effectiveError
                }
                attempt += 1
                try await sleepBeforeRetry(attempt: attempt)
            }
        }
    }

    private func performStreamingRequest(
        apiKey: String,
        request: OpenAIResponsesRequest,
        onEvent: @escaping @Sendable (OpenAIResponsesStreamEvent) -> Void,
        traceID: String
    ) async throws -> OpenAIResponsesResponse {
        let payload = createPayload(request: request, stream: true)
        let encodedPayload: Data
        do {
            encodedPayload = try JSONEncoder().encode(payload)
        } catch {
            throw OpenAIResponsesServiceError.encodingFailure(error.localizedDescription)
        }

        var urlRequest = URLRequest(url: endpointURL)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 60
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = encodedPayload

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: urlRequest)
        } catch is OpenAIStreamingUnsupportedError {
            let response = try await performRequest(
                apiKey: apiKey,
                request: request,
                traceID: traceID
            )
            let text = response.text
            if !text.isEmpty {
                onEvent(.outputTextDone(text))
            }
            return response
        } catch {
            throw normalizeTransportError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            Self.logger.error("[\(traceID, privacy: .public)] stream_invalid_non_http_response")
            throw OpenAIResponsesServiceError.invalidResponse
        }

        if Self.shouldLogResponsePayloads() {
            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
            Self.logger.debug(
                "[\(traceID, privacy: .public)] stream_response_headers status=\(httpResponse.statusCode) content_type=\(contentType, privacy: .public)"
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
            }
            if Self.shouldLogResponsePayloads() {
                Self.logger.error(
                    "[\(traceID, privacy: .public)] stream_http_error_payload status=\(httpResponse.statusCode) body_preview=\(Self.logPreview(from: data), privacy: .public)"
                )
            }
            let message = Self.extractErrorMessage(from: data)
            throw OpenAIResponsesServiceError.httpError(
                statusCode: httpResponse.statusCode,
                message: message
            )
        }

        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let isSSEContentType = contentType.contains("text/event-stream")
        let isJSONContentType = contentType.contains("application/json")
        if isJSONContentType && !isSSEContentType {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
            }
            if Self.shouldLogResponsePayloads() {
                Self.logger.debug(
                    "[\(traceID, privacy: .public)] stream_json_success_payload body_preview=\(Self.logPreview(from: data), privacy: .public)"
                )
            }
            do {
                let decoded = try JSONDecoder().decode(OpenAIResponsesResponse.self, from: data)
                let text = decoded.text
                if !text.isEmpty {
                    onEvent(.outputTextDone(text))
                }
                return decoded
            } catch {
                throw OpenAIResponsesServiceError.decodingFailure(error.localizedDescription)
            }
        }

        var eventName: String?
        var dataLines: [String] = []
        var completedResponse: OpenAIResponsesResponse?
        var accumulator = StreamingResponseAccumulator()
        var nonSSELines: [String] = []

        func flushEvent() throws {
            guard !dataLines.isEmpty else {
                eventName = nil
                return
            }
            let payloadText = dataLines.joined(separator: "\n")
            let currentEventName = eventName
            dataLines.removeAll(keepingCapacity: true)
            eventName = nil
            if payloadText.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" {
                return
            }
            if Self.shouldLogResponsePayloads() {
                let eventForLog = currentEventName ?? "n/a"
                Self.logger.debug(
                    "[\(traceID, privacy: .public)] stream_event event=\(eventForLog, privacy: .public) payload_preview=\(Self.logPreview(from: payloadText), privacy: .public)"
                )
            }
            if let parsedResponse = try Self.consumeStreamPayload(
                payloadText,
                eventName: currentEventName,
                onEvent: onEvent,
                accumulator: &accumulator
            ) {
                completedResponse = parsedResponse
            }
        }

        do {
            var lineBuffer = Data()
            func consumeLine(_ rawLine: String) throws {
                var line = rawLine
                if line.hasSuffix("\r") {
                    line.removeLast()
                }
                if line.isEmpty {
                    try flushEvent()
                    return
                }
                if line.hasPrefix(":") {
                    return
                }
                if let value = Self.sseFieldValue(prefix: "event:", line: line) {
                    eventName = value
                    return
                }
                if let value = Self.sseFieldValue(prefix: "data:", line: line) {
                    dataLines.append(value)
                    return
                }
                nonSSELines.append(line)
            }

            for try await byte in bytes {
                if byte == 0x0A { // LF
                    let line = String(decoding: lineBuffer, as: UTF8.self)
                    try consumeLine(line)
                    lineBuffer.removeAll(keepingCapacity: true)
                } else {
                    lineBuffer.append(byte)
                }
            }
            if !lineBuffer.isEmpty {
                let line = String(decoding: lineBuffer, as: UTF8.self)
                try consumeLine(line)
            }
            try flushEvent()
        } catch let serviceError as OpenAIResponsesServiceError {
            throw serviceError
        } catch {
            throw OpenAIResponsesServiceError.transportFailure(error.localizedDescription)
        }

        if let completedResponse {
            return completedResponse
        }
        if let assembled = accumulator.assembledResponse {
            return assembled
        }
        if !nonSSELines.isEmpty {
            let body = nonSSELines.joined(separator: "\n")
            if Self.shouldLogResponsePayloads() {
                Self.logger.warning(
                    "[\(traceID, privacy: .public)] stream_non_sse_body_preview=\(Self.logPreview(from: body), privacy: .public)"
                )
            }
            if let data = body.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(OpenAIResponsesResponse.self, from: data) {
                let text = decoded.text
                if !text.isEmpty {
                    onEvent(.outputTextDone(text))
                }
                return decoded
            }
        }
        if Self.shouldLogResponsePayloads() {
            Self.logger.error(
                "[\(traceID, privacy: .public)] stream_invalid_response_no_completed_payload"
            )
        }
        throw OpenAIResponsesServiceError.invalidResponse
    }

    private static func consumeStreamPayload(
        _ payloadText: String,
        eventName: String?,
        onEvent: @escaping @Sendable (OpenAIResponsesStreamEvent) -> Void,
        accumulator: inout StreamingResponseAccumulator
    ) throws -> OpenAIResponsesResponse? {
        guard let data = payloadText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }

        let type = (dictionary["type"] as? String) ?? eventName ?? ""
        guard !type.isEmpty else { return nil }
        accumulator.ingest(type: type, payload: dictionary)

        switch type {
        case "response.text.delta":
            if let delta = stringField(in: dictionary, key: "delta"), !delta.isEmpty {
                onEvent(.outputTextDelta(delta))
            }
        case "response.text.done":
            if let text = stringField(in: dictionary, key: "text"), !text.isEmpty {
                onEvent(.outputTextDone(text))
            }
        case "response.output_text.delta":
            if let delta = stringField(in: dictionary, key: "delta"), !delta.isEmpty {
                onEvent(.outputTextDelta(delta))
            }
        case "response.output_text.done":
            if let text = stringField(in: dictionary, key: "text"), !text.isEmpty {
                onEvent(.outputTextDone(text))
            }
        case "response.reasoning_text.delta":
            if let delta = stringField(in: dictionary, key: "delta"), !delta.isEmpty {
                onEvent(.reasoningTextDelta(delta))
            }
        case "response.reasoning_text.done":
            if let text = stringField(in: dictionary, key: "text"), !text.isEmpty {
                onEvent(.reasoningTextDone(text))
            }
        case "response.reasoning_summary_text.delta":
            if let delta = stringField(in: dictionary, key: "delta"), !delta.isEmpty {
                onEvent(.reasoningSummaryTextDelta(delta))
            }
        case "response.reasoning_summary_text.done":
            if let text = stringField(in: dictionary, key: "text"), !text.isEmpty {
                onEvent(.reasoningSummaryTextDone(text))
            }
        case "response.reasoning_summary_part.added":
            if let text = reasoningSummaryText(from: dictionary), !text.isEmpty {
                onEvent(.reasoningSummaryTextDelta(text))
            }
        case "response.reasoning_summary_part.done":
            if let text = reasoningSummaryText(from: dictionary), !text.isEmpty {
                onEvent(.reasoningSummaryTextDone(text))
            }
        case "response.refusal.delta":
            if let delta = stringField(in: dictionary, key: "delta"), !delta.isEmpty {
                onEvent(.outputTextDelta(delta))
            }
        case "response.refusal.done":
            if let text = stringField(in: dictionary, key: "refusal")
                ?? stringField(in: dictionary, key: "text"),
               !text.isEmpty {
                onEvent(.outputTextDone(text))
            }
        case "error":
            let message = streamErrorMessage(from: dictionary)
            throw OpenAIResponsesServiceError.httpError(statusCode: 500, message: message)
        case "response.failed":
            let message = streamErrorMessage(from: dictionary)
            throw OpenAIResponsesServiceError.httpError(statusCode: 500, message: message)
        case "response.completed":
            if let response = completedResponse(from: dictionary) {
                return response
            }
        default:
            break
        }

        return nil
    }

    private static func completedResponse(from payload: [String: Any]) -> OpenAIResponsesResponse? {
        if let responseObject = payload["response"] {
            if let decoded = decodeJSONValue(responseObject, as: OpenAIResponsesResponse.self) {
                return decoded
            }
        }
        return decodeJSONValue(payload, as: OpenAIResponsesResponse.self)
    }

    private static func streamErrorMessage(from payload: [String: Any]) -> String {
        if let errorObject = payload["error"] as? [String: Any],
           let message = errorObject["message"] as? String,
           !message.isEmpty {
            return message
        }
        if let message = payload["message"] as? String, !message.isEmpty {
            return message
        }
        if let responseObject = payload["response"] as? [String: Any],
           let errorObject = responseObject["error"] as? [String: Any],
           let message = errorObject["message"] as? String,
           !message.isEmpty {
            return message
        }
        return "OpenAI streaming request failed."
    }

    private static func stringField(in payload: [String: Any], key: String) -> String? {
        payload[key] as? String
    }

    private static func reasoningSummaryText(from payload: [String: Any]) -> String? {
        guard let part = payload["part"] as? [String: Any] else {
            return nil
        }
        let type = part["type"] as? String
        guard type == "summary_text" || type == "text" || type == "output_text" else {
            return nil
        }
        return part["text"] as? String
    }
}
