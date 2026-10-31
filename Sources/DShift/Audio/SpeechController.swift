import AVFoundation
import Foundation

/// One speaker for the app. A new question, chat switch, or Stop cancels synthesis and playback together.
@MainActor
final class SpeechController: ObservableObject {
    static let shared = SpeechController()

    @Published var enabled = UserDefaults.standard.bool(forKey: "spokenReplies") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "spokenReplies")
            if !enabled { stop() }
        }
    }
    @Published private(set) var entryID: UUID?
    @Published private(set) var status = ""
    @Published private(set) var error: String?
    private var chatID: UUID?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    func speak(_ text: String, entryID: UUID, chatID: UUID) {
        DictationController.shared.cancel()
        stop()
        let chunks = SpeechText.chunks(text)
        guard !chunks.isEmpty else { return }
        self.entryID = entryID
        self.chatID = chatID
        status = "Preparing voice…"
        let current = generation
        task = Task {
            do {
                let client = try LocalSpeechClient.configured()
                var audio = try await client.audio(for: chunks[0])
                for index in chunks.indices {
                    try Task.checkCancellation()
                    // Prepare one chunk ahead while the current audio plays. Memory stays bounded.
                    async let next: Data? =
                        index + 1 < chunks.count
                        ? client.audio(for: chunks[index + 1]) : nil
                    status = "Speaking…"
                    try await AudioPlayback(data: audio).play()
                    try Task.checkCancellation()
                    status = "Preparing voice…"
                    if let prepared = try await next { audio = prepared }
                }
            } catch  where Task.isCancelled {
                // Stopping speech is an ordinary user action.
            } catch {
                if current == generation {
                    self.error =
                        (error as? URLError) != nil
                        ? "Couldn’t reach the local voice service. Your text reply is still available."
                        : error.localizedDescription
                }
            }
            guard current == generation else { return }
            self.entryID = nil
            self.chatID = nil
            status = ""
            task = nil
        }
    }

    func stop(for chatID: UUID? = nil) {
        if let chatID, self.chatID != chatID { return }
        generation = UUID()
        task?.cancel()
        task = nil
        entryID = nil
        self.chatID = nil
        status = ""
        error = nil
    }
}

@MainActor
private final class AudioPlayback: NSObject, AVAudioPlayerDelegate {
    private let player: AVAudioPlayer
    private var completion: CheckedContinuation<Void, Error>?

    init(data: Data) throws {
        player = try AVAudioPlayer(data: data)
        super.init()
        player.delegate = self
    }

    func play() async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                completion = continuation
                if !player.play() { finish(ToolError.failed("Couldn’t play the generated voice.")) }
            }
        } onCancel: {
            Task { @MainActor in self.finish(CancellationError()) }
        }
    }

    private func finish(_ error: Error? = nil) {
        player.stop()
        let continuation = completion
        completion = nil
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.finish(flag ? nil : ToolError.failed("Voice playback was interrupted."))
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in self.finish(ToolError.failed("Couldn’t decode the generated voice.")) }
    }
}
