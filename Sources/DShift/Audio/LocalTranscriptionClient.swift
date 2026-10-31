import Foundation

struct LocalTranscriptionClient {
    var endpoint: URL
    var model: String
    var session: URLSession = LocalAudioConnection.session

    static func configured() throws -> Self {
        Self(
            endpoint: try LocalAudioConnection.endpoint(
                setting: "DSHIFT_STT_URL", defaultPath: "v1/audio/transcriptions"),
            model: Config.value("DSHIFT_STT_MODEL") ?? "mlx-community/whisper-large-v3-turbo-asr-fp16")
    }

    func transcribe(_ audio: Data) async throws -> String {
        let boundary = "DShift-\(UUID().uuidString)"
        var body = Data()
        for (name, value) in [("model", model), ("response_format", "json"), ("stream", "false")] {
            body.append(
                Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(
            Data(
                "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\nContent-Type: audio/wav\r\n\r\n"
                    .utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: endpoint, timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ToolError.failed("The local voice service couldn’t transcribe this recording. Please try again.")
        }
        struct Transcript: Decodable { let text: String }
        let text = try JSONDecoder().decode(Transcript.self, from: data).text.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ToolError.failed("No speech was recognized. Please try again.") }
        return text
    }
}
