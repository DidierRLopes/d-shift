import Foundation

struct LocalSpeechClient {
    var endpoint: URL
    var model: String
    var voice: String
    var session: URLSession = LocalAudioConnection.session

    static func configured() throws -> Self {
        return Self(
            endpoint: try LocalAudioConnection.endpoint(setting: "DSHIFT_TTS_URL", defaultPath: "v1/audio/speech"),
            model: Config.value("DSHIFT_TTS_MODEL") ?? "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit",
            voice: Config.value("DSHIFT_TTS_VOICE") ?? "Aiden")
    }

    func audio(for text: String) async throws -> Data {
        var request = URLRequest(url: endpoint, timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "input": text, "voice": voice, "lang_code": "English",
            "instruct":
                "Speak clearly and conversationally, as a helpful teacher. Use natural emphasis and brief pauses between ideas.",
            "response_format": "wav", "stream": false, "max_tokens": 1200,
        ])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ToolError.failed(
                "The local voice service could not generate speech. Your text reply is still available.")
        }
        guard data.count > 44, data.prefix(4) == Data("RIFF".utf8),
            data.subdata(in: 8..<12) == Data("WAVE".utf8)
        else { throw ToolError.failed("The local voice service returned invalid audio.") }
        return data
    }
}
