import AVFoundation

@MainActor
protocol VoiceRecording: AnyObject {
    var isRecording: Bool { get }
    var duration: TimeInterval { get }
    var power: Float { get }
    func authorize() async throws
    func start() throws
    func finish() throws -> Data
    func cancel()
}

enum MicrophoneError: LocalizedError {
    case denied, requiresApp, unavailable, noAudio

    var errorDescription: String? {
        switch self {
        case .denied: "Allow D-Shift to use your microphone in System Settings > Privacy & Security > Microphone."
        case .requiresApp:
            "Voice input requires the bundled D-Shift.app. Build it with scripts/bundle.sh, then open it."
        case .unavailable: "Couldn’t start the microphone. Check your Mac’s sound input settings."
        case .noAudio: "No audio was detected. Check your microphone and try again."
        }
    }
}

@MainActor
final class MicrophoneRecorder: VoiceRecording {
    private var recorder: AVAudioRecorder?
    private var file: URL?
    var isRecording: Bool { recorder?.isRecording ?? false }
    var duration: TimeInterval { recorder?.currentTime ?? 0 }
    var power: Float {
        recorder?.updateMeters()
        return recorder?.averagePower(forChannel: 0) ?? -160
    }

    func authorize() async throws {
        // A bare SwiftPM executable has no privacy-purpose string. Avoid a TCC termination in source runs.
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else {
            throw MicrophoneError.requiresApp
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw MicrophoneError.denied }
    }

    func start() throws {
        cancel()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DShift-voice-\(UUID().uuidString).wav")
        file = url
        do {
            let recorder = try AVAudioRecorder(
                url: url,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                    AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                ])
            recorder.isMeteringEnabled = true
            self.recorder = recorder
            guard recorder.record() else { throw MicrophoneError.unavailable }
        } catch {
            cancel()
            throw error
        }
    }

    func finish() throws -> Data {
        recorder?.stop()
        defer { cancel() }
        guard let file else { throw MicrophoneError.noAudio }
        return try Data(contentsOf: file)
    }

    func cancel() {
        recorder?.stop()
        recorder = nil
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
    }
}
