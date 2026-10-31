import Foundation
import Testing

@testable import DShift

private final class VoiceProtocol: URLProtocol {
    static let wave = Data(base64Encoded: "UklGRiYAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQIAAAAAAA==")!

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "voice.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: request.url!.path == "/unavailable" ? 503 : 200,
            httpVersion: nil, headerFields: ["Content-Type": "audio/wav"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: request.url!.path == "/invalid" ? Data("not audio".utf8) : Self.wave)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct LocalSpeechClientTests {
    @Test(arguments: ["speech", "unavailable", "invalid"])
    func returnsPlayableDataOrAnActionableError(_ scenario: String) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [VoiceProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = LocalSpeechClient(
            endpoint: URL(string: "https://voice.test/\(scenario)")!, model: "local-model", voice: "local-voice",
            session: session)
        do {
            let audio = try await client.audio(for: "Interest earns more interest.")
            #expect(scenario == "speech")
            #expect(audio == VoiceProtocol.wave)
        } catch {
            #expect(scenario != "speech")
            #expect(
                error.localizedDescription.contains(scenario == "invalid" ? "invalid audio" : "local voice service"))
        }
    }
}
