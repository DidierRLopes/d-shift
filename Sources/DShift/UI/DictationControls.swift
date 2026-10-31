import AppKit
import SwiftUI

struct DictationControls: View {
    @ObservedObject private var dictation = DictationController.shared

    var body: some View {
        if dictation.isActive {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    if dictation.phase == .recording {
                        Image(systemName: "mic.fill").foregroundStyle(.orange)
                        Text("Listening").foregroundStyle(.orange)
                        Text(String(format: "%d:%02d", Int(dictation.elapsed) / 60, Int(dictation.elapsed) % 60))
                            .monospacedDigit().foregroundStyle(.secondary)
                        GeometryReader { geometry in
                            Capsule().fill(.orange.opacity(0.15))
                            Capsule().fill(.orange)
                                .frame(width: geometry.size.width * dictation.level)
                        }
                        .frame(width: 48, height: 4)
                        .accessibilityLabel("Microphone input level")
                    } else {
                        ProgressView().controlSize(.mini)
                        Text(dictation.phase == .authorizing ? "Waiting for microphone…" : "Transcribing…")
                    }
                    Spacer(minLength: 0)
                    IconButton(systemName: "xmark", help: "Cancel voice input") { dictation.cancel() }
                }
                .scaledFont(12, weight: .medium)
                if dictation.phase == .recording {
                    Text("Double-Shift to send · Esc to cancel")
                        .scaledFont(11).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .contain)
        } else if let error = dictation.error {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 6) {
                    Text(error).scaledFont(11).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    IconButton(systemName: "xmark", help: "Dismiss voice input error") { dictation.cancel() }
                }
                if dictation.needsPermission {
                    Button("Open Microphone Settings") {
                        if let url = URL(
                            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                        {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.link).scaledFont(11)
                }
            }
        }
    }
}
