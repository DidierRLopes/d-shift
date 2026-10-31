import Foundation
import Testing

@testable import DShift

@MainActor
private final class RecordingFixture: VoiceRecording {
    var duration: TimeInterval { 1 }
    var power: Float { -12 }
    private(set) var isRecording = false
    func authorize() async throws {}
    func start() throws { isRecording = true }
    func finish() throws -> Data {
        isRecording = false
        return Data("recorded audio".utf8)
    }
    func cancel() { isRecording = false }
}

@MainActor
struct DictationControllerTests {
    @Test(arguments: [true, false])
    func finishesOnceAndHonorsSendOrDraft(send: Bool) async throws {
        let recorder = RecordingFixture()
        let controller = DictationController(recorder: recorder) { audio in
            #expect(audio == Data("recorded audio".utf8))
            return "Explain this chart."
        }
        defer { controller.cancel() }
        var transcripts: [String] = []
        var submitted: Bool?
        controller.start(chatID: UUID()) { text, shouldSend in
            transcripts.append(text)
            submitted = shouldSend
        }
        try #require(await eventually { controller.phase == .recording })
        #expect(recorder.isRecording)
        controller.finish(send: send)
        controller.finish(send: send)
        try #require(await eventually { !controller.isActive })
        #expect(!recorder.isRecording)
        #expect(transcripts == ["Explain this chart."])
        #expect(submitted == send)
    }

    @Test func cancelledTranscriptionCannotReachAnotherChat() async throws {
        let recorder = RecordingFixture()
        var pending: CheckedContinuation<String, Never>?
        var next: CheckedContinuation<String, Never>?
        defer {
            pending?.resume(returning: "")
            next?.resume(returning: "")
        }
        var previousReturned = false
        var request = 0
        let controller = DictationController(recorder: recorder) { _ in
            request += 1
            if request == 1 {
                defer { previousReturned = true }
                return await withCheckedContinuation { pending = $0 }
            }
            return await withCheckedContinuation { next = $0 }
        }
        defer { controller.cancel() }
        var transcripts: [String] = []
        controller.start(chatID: UUID()) { text, _ in transcripts.append(text) }
        try #require(await eventually { controller.phase == .recording })
        controller.finish()
        try #require(await eventually { pending != nil })
        controller.cancel()
        controller.start(chatID: UUID()) { text, _ in transcripts.append(text) }
        try #require(await eventually { controller.phase == .recording })
        controller.finish()
        try #require(await eventually { next != nil })
        pending?.resume(returning: "The cancelled question.")
        pending = nil
        try #require(await eventually { previousReturned })
        await Task.yield()
        next?.resume(returning: "The new question.")
        next = nil
        try #require(await eventually { !controller.isActive })
        #expect(transcripts == ["The new question."])
        #expect(!recorder.isRecording)
    }

    @Test func stoppedMicrophoneEndsDictationWithAnError() async throws {
        let recorder = RecordingFixture()
        let controller = DictationController(recorder: recorder) { _ in
            Issue.record("An interrupted recording must not be transcribed.")
            return ""
        }
        defer { controller.cancel() }
        controller.start(chatID: UUID()) { _, _ in
            Issue.record("An interrupted recording must not send a message.")
        }
        try #require(await eventually { controller.phase == .recording })
        recorder.cancel()
        try #require(await eventually { !controller.isActive })
        #expect(controller.error != nil)
    }

    private func eventually(_ predicate: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate(), ContinuousClock.now < deadline {
            await Task.yield()
        }
        return predicate()
    }
}
