import Foundation

typealias JSON = [String: Any]

struct OpenAIIncompleteResponse: LocalizedError {
    let reason: String
    let usage: TokenUsage

    var errorDescription: String? { "OpenAI response incomplete: \(reason)" }
}

enum OpenAIStreamEvent {
    case text(index: Int, delta: String)
    case itemAdded(index: Int, item: JSON)
    case itemDone(index: Int, item: JSON)
    case completed(OpenAIResponse)
}

/// Completed output is kept intact, including encrypted reasoning and message phases, for the next request.
struct OpenAIResponse {
    let output: [JSON]
    let usage: TokenUsage

    init(_ response: JSON) throws {
        guard let output = response["output"] as? [JSON], !output.isEmpty else {
            throw ToolError.failed("OpenAI returned an empty response.")
        }
        self.output = output
        usage = TokenUsage(response["usage"] as? JSON ?? [:])
    }

    var functionCalls: [JSON] { output.filter { $0["type"] as? String == "function_call" } }

    /// Converts web annotations to clickable citations while leaving the stored API output untouched.
    static func text(in item: JSON) -> String {
        (item["content"] as? [JSON] ?? []).compactMap { part -> String? in
            if let refusal = part["refusal"] as? String { return refusal }
            guard var text = part["text"] as? String else { return nil }
            let annotations = (part["annotations"] as? [JSON] ?? []).sorted {
                ($0["start_index"] as? Int ?? 0) > ($1["start_index"] as? Int ?? 0)
            }
            for annotation in annotations where annotation["type"] as? String == "url_citation" {
                guard let url = annotation["url"] as? String,
                    let target = URL(string: url), ["https", "http"].contains(target.scheme ?? ""),
                    let start = annotation["start_index"] as? Int, let end = annotation["end_index"] as? Int,
                    start >= 0, end >= start, end <= text.unicodeScalars.count
                else { continue }
                let lower = text.unicodeScalars.index(text.startIndex, offsetBy: start)
                let upper = text.unicodeScalars.index(text.startIndex, offsetBy: end)
                let label = start == end ? (annotation["title"] as? String ?? "Source") : String(text[lower..<upper])
                let escaped = label.replacingOccurrences(of: "[", with: "\\[")
                    .replacingOccurrences(of: "]", with: "\\]")
                text.replaceSubrange(lower..<upper, with: "[\(escaped)](<\(target.absoluteString)>)")
            }
            return text
        }.joined(separator: "\n\n")
    }
}

/// One Responses API client for chat, on-screen graphics, and 3D models.
enum OpenAIClient {
    static let model = "gpt-6.1-sol"
    static let contextWindow = 1_050_000
    private static let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    static func stream(
        instructions: String, input: [JSON], tools: [JSON] = [], effort: String = "low", maxOutputTokens: Int = 64000
    ) -> AsyncThrowingStream<OpenAIStreamEvent, Error> {
        ServerSentEvents.stream(
            {
                guard let key = Config.value("OPENAI_API_KEY") else {
                    throw ToolError.failed("Add your OpenAI API key from the menu bar > Change OpenAI API Key.")
                }
                return try makeRequest(
                    instructions: instructions, input: input, tools: tools, effort: effort,
                    maxOutputTokens: maxOutputTokens, apiKey: key)
            },
            httpError: { ToolError.failed("OpenAI HTTP \($0): \($1)") },
            parse: { try parseEvent($0).map { [$0] } ?? [] },
            isComplete: { if case .completed = $0 { true } else { false } }
        )
    }

    static func makeRequest(
        instructions: String, input: [JSON], tools: [JSON], effort: String, maxOutputTokens: Int, apiKey: String
    ) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        var body: JSON = [
            "model": model,
            "service_tier": "default",
            "instructions": instructions,
            "input": input,
            "reasoning": ["effort": effort],
            "max_output_tokens": maxOutputTokens,
            "stream": true,
            "store": false,
        ]
        if !tools.isEmpty { body["tools"] = tools }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func userMessage(_ text: String, jpeg: Data? = nil) -> JSON {
        var content: [JSON] = [["type": "input_text", "text": text]]
        if let jpeg { content.append(image(jpeg)) }
        return ["type": "message", "role": "user", "content": content]
    }

    static func image(_ jpeg: Data) -> JSON {
        ["type": "input_image", "image_url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"]
    }

    static func parseEvent(_ line: String) throws -> OpenAIStreamEvent? {
        guard let event = try ServerSentEvents.payload(line) else { return nil }
        let index = event["output_index"] as? Int ?? 0
        switch event["type"] as? String {
        case "response.output_text.delta", "response.refusal.delta":
            return (event["delta"] as? String).map { .text(index: index, delta: $0) }
        case "response.output_item.added":
            return (event["item"] as? JSON).map { .itemAdded(index: index, item: $0) }
        case "response.output_item.done":
            return (event["item"] as? JSON).map { .itemDone(index: index, item: $0) }
        case "response.completed":
            return .completed(try OpenAIResponse(event["response"] as? JSON ?? [:]))
        case "response.incomplete":
            let response = event["response"] as? JSON ?? [:]
            let details = response["incomplete_details"] as? JSON
            throw OpenAIIncompleteResponse(
                reason: details?["reason"] as? String ?? "unknown reason",
                usage: TokenUsage(response["usage"] as? JSON ?? [:]))
        case "response.failed":
            let message = ((event["response"] as? JSON)?["error"] as? JSON)?["message"] as? String
            throw ToolError.failed("OpenAI: \(message ?? "response failed")")
        case "error":
            let details = event["error"] as? JSON ?? event
            let message = details["message"] as? String ?? details["code"] as? String ?? "streaming error"
            throw ToolError.failed("OpenAI: \(message)")
        default:
            return nil
        }
    }
}
