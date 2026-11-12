import SwiftUI

/// The compact state of the panel while the user is aiming. It says which
/// intelligence is listening and how to express intent, and nothing else — the
/// screen itself carries the feedback about what is currently understood.
struct ControllerBarView: View {
    @ObservedObject var viewModel: AssistantPanelViewModel
    @ObservedObject var speech: SpeechInputController

    private let accent = Color(red: 0.49, green: 0.57, blue: 1)

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "scope")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent)

            Text("\(viewModel.selectedProfile.shortName) · \(viewModel.reasoningEffort.displayName)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))

            Divider().frame(height: 14).overlay(Color.white.opacity(0.12))

            Text(speech.isRecording ? "Listening… click to lock" : "Scroll to resize · Click to lock")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(speech.isRecording ? accent : .white.opacity(0.5))
                .lineLimit(1)

            Spacer(minLength: 0)

            Button(action: { viewModel.onToggleVoice?() }) {
                Image(systemName: speech.isRecording ? "waveform" : "mic")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(
                        speech.isRecording ? accent.opacity(0.2) : Color.white.opacity(0.05),
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(speech.isRecording ? accent : .white.opacity(0.6))
            .accessibilityLabel(speech.isRecording ? "Stop dictation" : "Start dictation")
        }
        .padding(.horizontal, 11)
        .frame(width: PanelMetrics.controllerSize.width, height: PanelMetrics.controllerSize.height)
        .background(controllerBackground)
        .preferredColorScheme(.dark)
    }

    private var controllerBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.055, green: 0.063, blue: 0.082).opacity(0.7)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.14), lineWidth: 1))
            .shadow(color: .black.opacity(0.34), radius: 18, x: 0, y: 10)
    }
}
