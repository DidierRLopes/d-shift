import Foundation
import Testing

@testable import DShift

private final class TranscriptionProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "dictation.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let envelope = String(decoding: body, as: UTF8.self)
        let valid =
            request.value(forHTTPHeaderField: "Authorization") == nil
            && envelope.contains("name=\"model\"\r\n\r\nlocal-whisper")
            && envelope.contains("name=\"response_format\"\r\n\r\njson")
            && envelope.contains("filename=\"recording.wav\"")
            && envelope.contains("fixture-audio")
        let response = HTTPURLResponse(
            url: request.url!, statusCode: valid ? 200 : 400,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"text":" Explain this chart. "}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct LocalTranscriptionClientTests {
    @Test func sendsAudioLocallyAndReturnsTheTranscript() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TranscriptionProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = LocalTranscriptionClient(
            endpoint: URL(string: "https://dictation.test/transcriptions")!,
            model: "local-whisper", session: session)
        #expect(try await client.transcribe(Data("fixture-audio".utf8)) == "Explain this chart.")
    }
}
