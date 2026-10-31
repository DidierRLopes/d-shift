import Foundation

/// One microphone session, bound to the chat that started it. Cancelled sessions can never submit a late transcript.
@MainActor
final class DictationController: ObservableObject {
    enum Phase { case idle, authorizing, recording, transcribing }
    static let shared = DictationController(recorder: MicrophoneRecorder()) {
        try await LocalTranscriptionClient.configured().transcribe($0)
    }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Double = 0
    @Published private(set) var error: String?
    @Published private(set) var needsPermission = false
    var isActive: Bool { phase != .idle }

    private let recorder: VoiceRecording
    private let transcribe: (Data) async throws -> String
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var chatID: UUID?
    private var onTranscript: ((String, Bool) -> Void)?
    private var heardAudio = false

    init(recorder: VoiceRecording, transcribe: @escaping (Data) async throws -> String) {
        self.recorder = recorder
        self.transcribe = transcribe
    }

    func start(chatID: UUID, onTranscript: @escaping (String, Bool) -> Void) {
        cancel()
        self.chatID = chatID
        self.onTranscript = onTranscript
        phase = .authorizing
        let current = generation
        task = Task {
            do {
                try await recorder.authorize()
                try Task.checkCancellation()
                guard current == generation else { return }
                try recorder.start()
                phase = .recording
                while phase == .recording {
                    guard recorder.isRecording else { throw MicrophoneError.unavailable }
                    elapsed = recorder.duration
                    let power = recorder.power
                    level = min(1, max(0, Double(power + 60) / 60))
                    if power > -50 { heardAudio = true }
                    if elapsed >= 120 {
                        // Preserve long recordings as a draft instead of sending a cut-off question.
                        finish(send: false)
                        return
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
            } catch  where Task.isCancelled {
            } catch {
                guard current == generation else { return }
                fail(error)
            }
        }
    }

    func finish(send: Bool = true) {
        guard phase == .recording else { return }
        task?.cancel()
        let current = generation
        do {
            guard recorder.isRecording else { throw MicrophoneError.unavailable }
            guard heardAudio, recorder.duration >= 0.3 else { throw MicrophoneError.noAudio }
            let audio = try recorder.finish()
            phase = .transcribing
            level = 0
            task = Task {
                do {
                    let text = try await transcribe(audio)
                    try Task.checkCancellation()
                    guard current == generation else { return }
                    let deliver = onTranscript
                    cancel()
                    deliver?(text, send)
                } catch  where Task.isCancelled {
                } catch {
                    guard current == generation else { return }
                    fail(error)
                }
            }
        } catch { fail(error) }
    }

    func cancel(for chatID: UUID? = nil) {
        if let chatID, self.chatID != chatID { return }
        generation = UUID()
        task?.cancel()
        task = nil
        recorder.cancel()
        phase = .idle
        elapsed = 0
        level = 0
        heardAudio = false
        self.chatID = nil
        onTranscript = nil
        error = nil
        needsPermission = false
    }

    private func fail(_ failure: Error) {
        cancel()
        error =
            (failure as? URLError) != nil
            ? "Couldn’t reach the local voice service. Check that it’s running, then try again."
            : failure.localizedDescription
        if case MicrophoneError.denied = failure { needsPermission = true }
    }
}
