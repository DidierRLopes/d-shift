import SwiftUI

struct SpeechControls: View {
    @ObservedObject private var speech = SpeechController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    speech.enabled.toggle()
                } label: {
                    Label(
                        speech.enabled ? "Voice on" : "Voice off",
                        systemImage: speech.enabled ? "speaker.wave.2.fill" : "speaker.slash")
                }
                .buttonStyle(.plain)
                .help("Automatically read replies with your local voice model")
                .accessibilityValue(speech.enabled ? "On" : "Off")
                Spacer(minLength: 0)
                if speech.entryID != nil {
                    Text(speech.status)
                        .foregroundStyle(.secondary)
                    Button("Stop") { speech.stop() }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Stop speaking")
                }
            }
            if let error = speech.error {
                Text(error)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .scaledFont(11)
        .padding(.horizontal, 18)
        .padding(.top, 7)
    }
}
