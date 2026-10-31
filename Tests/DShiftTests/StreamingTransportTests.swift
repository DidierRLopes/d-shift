import Foundation
import Testing

@testable import DShift

/// Only the network edge is replaced; parsing, completion checks, and URLSession streaming stay real.
private final class ResponseProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "dshift.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url!.path
        let status = path == "/unauthorized" ? 401 : 200
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        var body = "data: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"delta\":\"Hello\"}\n\n"
        if path == "/complete" {
            body +=
                "data: {\"type\":\"response.completed\",\"response\":{\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Hello\"}]}],\"usage\":{\"input_tokens\":3,\"output_tokens\":1}}}\n\n"
        } else if path == "/unauthorized" {
            body = "Invalid API key"
        }
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct StreamingTransportTests {
    @Test(arguments: ["complete", "truncated", "unauthorized"])
    func streamsOnlyCompletedResponsesSuccessfully(_ scenario: String) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ResponseProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: URL(string: "https://dshift.test/\(scenario)")!)
        let stream = ServerSentEvents.stream(
            { request }, httpError: { ToolError.failed("HTTP \($0): \($1)") },
            parse: { try OpenAIClient.parseEvent($0).map { [$0] } ?? [] },
            isComplete: { if case .completed = $0 { true } else { false } }, session: session)
        var text = ""
        var completed = false
        do {
            for try await event in stream {
                switch event {
                case .text(_, let delta): text += delta
                case .completed: completed = true
                default: break
                }
            }
            #expect(scenario == "complete")
            #expect(text == "Hello")
            #expect(completed)
        } catch {
            #expect(scenario != "complete")
            #expect(!completed)
            if scenario == "truncated" {
                #expect(text == "Hello")
                #expect(error.localizedDescription.contains("before completion"))
            } else {
                #expect(error.localizedDescription == "HTTP 401: Invalid API key")
            }
        }
    }
}
