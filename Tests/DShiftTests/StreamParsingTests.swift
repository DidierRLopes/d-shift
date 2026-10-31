import Foundation
import Testing

@testable import DShift

struct StreamParsingTests {
    @Test func surfacesNestedStreamingErrors() {
        do {
            _ = try OpenAIClient.parseEvent(
                #"data: {"type":"error","error":{"type":"invalid_request_error","code":"model_not_found","message":"The requested model is not available."}}"#
            )
            Issue.record("Expected the API error")
        } catch {
            #expect(error.localizedDescription == "OpenAI: The requested model is not available.")
        }
    }

    @Test func incompleteResponsesRetainBillableUsage() throws {
        do {
            _ = try OpenAIClient.parseEvent(
                #"data: {"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"},"usage":{"input_tokens":1000,"output_tokens":64000}}}"#
            )
            Issue.record("Expected an incomplete-response error")
        } catch let error as OpenAIIncompleteResponse {
            #expect(error.reason == "max_output_tokens")
            #expect(error.usage.input == 1000)
            #expect(error.usage.output == 64000)
            #expect(error.usage.estimatedCost > 0)
        }
    }

    @Test func rejectsIncompleteResponses() {
        #expect(throws: OpenAIIncompleteResponse.self) {
            try OpenAIClient.parseEvent(
                #"data: {"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}}}"#
            )
        }
    }

    @Test func preservesCompletedOutputForToolContinuation() throws {
        let event = try OpenAIClient.parseEvent(
            #"data: {"type":"response.completed","response":{"output":[{"type":"reasoning","id":"rs_1","encrypted_content":"opaque","summary":[]},{"type":"message","id":"msg_1","role":"assistant","phase":"commentary","content":[{"type":"output_text","text":"Checking."}]},{"type":"function_call","id":"fc_1","call_id":"call_1","name":"read_screen","arguments":"{}"}],"usage":{"input_tokens":100,"output_tokens":20,"input_tokens_details":{"cached_tokens":80}}}}"#
        )
        guard case .completed(let response) = event else { Issue.record("Expected completed response"); return }
        #expect(response.output[0]["encrypted_content"] as? String == "opaque")
        #expect(response.output[1]["phase"] as? String == "commentary")
        #expect(response.functionCalls[0]["call_id"] as? String == "call_1")
        #expect(response.functionCalls[0]["arguments"] as? String == "{}")
        #expect(response.usage.input == 100)
        #expect(response.usage.cacheRead == 80)
        #expect(response.usage.output == 20)
    }

    @Test func parsesTextRefusalsAndCompletedToolArguments() throws {
        guard
            case .text(2, "abc") = try OpenAIClient.parseEvent(
                #"data: {"type":"response.output_text.delta","output_index":2,"delta":"abc"}"#)
        else { Issue.record("Expected text delta"); return }
        guard
            case .text(1, "I cannot") = try OpenAIClient.parseEvent(
                #"data: {"type":"response.refusal.delta","output_index":1,"delta":"I cannot"}"#)
        else { Issue.record("Expected refusal text"); return }
        guard
            case .itemDone(3, let item) = try OpenAIClient.parseEvent(
                #"data: {"type":"response.output_item.done","output_index":3,"item":{"type":"function_call","call_id":"call_2","name":"write_memory","arguments":"{\"path\":\"notes.md\"}"}}"#
            )
        else { Issue.record("Expected completed function call"); return }
        #expect(item["arguments"] as? String == #"{"path":"notes.md"}"#)
        #expect(item["call_id"] as? String == "call_2")
    }

    @Test func ignoresUnknownEventsButSurfacesMalformedDataAndErrors() throws {
        #expect(try OpenAIClient.parseEvent("event: x") == nil)
        #expect(try OpenAIClient.parseEvent(#"data: {"type":"response.created"}"#) == nil)
        #expect(throws: (any Error).self) { try OpenAIClient.parseEvent("data: {not json") }
        #expect(throws: ToolError.self) {
            try OpenAIClient.parseEvent(#"data: {"type":"response.failed","response":{}}"#)
        }
        #expect(throws: ToolError.self) { try OpenAIClient.parseEvent(#"data: {"type":"error","message":"x"}"#) }
        #expect(throws: ToolError.self) {
            try OpenAIClient.parseEvent(#"data: {"type":"response.completed","response":{"output":[]}}"#)
        }
    }

    @Test func serializesImagesAndToolResultsWithoutLosingCallIDs() throws {
        let image = Data([0xff, 0xd8, 0xff])
        let input: [JSON] = [
            OpenAIClient.userMessage("Read this", jpeg: image),
            ["type": "function_call", "call_id": "call_7", "name": "take_screenshot", "arguments": "{}"],
            ["type": "function_call_output", "call_id": "call_7", "output": [OpenAIClient.image(image)]],
        ]
        let request = try OpenAIClient.makeRequest(
            instructions: "Help", input: input, tools: [], effort: "low", maxOutputTokens: 500, apiKey: "test-key")
        let data = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? JSON)
        let messages = try #require(body["input"] as? [JSON])
        let content = try #require(messages[0]["content"] as? [JSON])
        #expect(content[0]["text"] as? String == "Read this")
        #expect(content[1]["image_url"] as? String == "data:image/jpeg;base64,/9j/")
        #expect(messages[2]["call_id"] as? String == "call_7")
        #expect((messages[2]["output"] as? [JSON])?.first?["type"] as? String == "input_image")
        #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer test-key")
        #expect(body["store"] as? Bool == false)
    }

    @Test func rendersClickableWebCitationsWithoutChangingAPIHistory() {
        let item: JSON = [
            "content": [
                [
                    "type": "output_text", "text": "📌 Hello [1]",
                    "annotations": [
                        ["type": "url_citation", "start_index": 8, "end_index": 11, "url": "https://example.com"]
                    ],
                ]
            ]
        ]
        #expect(OpenAIResponse.text(in: item) == "📌 Hello [\\[1\\]](<https://example.com>)")
        #expect((item["content"] as? [JSON])?.first?["text"] as? String == "📌 Hello [1]")
    }
}
