import AppKit
import SwiftUI

struct AssistantPanelView: View {
    @ObservedObject var viewModel: AssistantPanelViewModel
    @ObservedObject var speech: SpeechInputController

    /// Placement is automatic until the panel is moved by hand, after which it
    /// stays where it was put.
    var onMoveBy: (CGSize) -> Void = { _ in }

    @State private var lastTranslation: CGSize = .zero

    private let accent = Color(red: 0.49, green: 0.57, blue: 1)

    var body: some View {
        VStack(spacing: 10) {
            header

            if viewModel.hasResponse {
                response
            } else {
                modelPicker
            }

            if let error = viewModel.errorMessage {
                errorRow(error)
            }

            composer
        }
        .padding(12)
        .frame(width: PanelMetrics.size(hasResponse: viewModel.hasResponse).width)
        .frame(height: PanelMetrics.size(hasResponse: viewModel.hasResponse).height)
        .background(panelBackground)
        .preferredColorScheme(.dark)
        .animation(.easeOut(duration: 0.14), value: viewModel.hasResponse)
    }

    private var header: some View {
        HStack(spacing: 8) {
            // The drag area is a real AppKit view, so it is scoped to the title
            // region only. Spanning the whole header would put it underneath the
            // close button and swallow the click.
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent)
                Text("Intelligent Cursor")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.96))
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        // Deltas, because translation is cumulative from the start
                        // of the drag while the window moves as we go.
                        onMoveBy(CGSize(
                            width: value.translation.width - lastTranslation.width,
                            height: value.translation.height - lastTranslation.height
                        ))
                        lastTranslation = value.translation
                    }
                    .onEnded { _ in lastTranslation = .zero }
            )
            .onHover { inside in
                if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
            .accessibilityLabel("Intelligent Cursor. Drag to move the panel.")

            Button(action: { viewModel.onDismiss?() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.55))
            .accessibilityLabel("Dismiss Intelligent Cursor")
        }
        .frame(height: 26)
    }

    private var modelPicker: some View {
        VStack(spacing: 7) {
            ForEach(ModelProfileID.allCases) { profile in
                Button {
                    viewModel.selectedProfile = profile
                    viewModel.clearError()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: profile.systemImage)
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 19)
                            .foregroundStyle(viewModel.selectedProfile == profile ? accent : .white.opacity(0.62))
                        Text(profile.displayName(effort: viewModel.reasoningEffort))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.94))
                        Spacer()
                        if viewModel.configuredProfiles.contains(profile) {
                            Circle()
                                .fill(Color.green.opacity(0.8))
                                .frame(width: 6, height: 6)
                        }
                        if viewModel.selectedProfile == profile {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(accent)
                        }
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 43)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(viewModel.selectedProfile == profile ? accent.opacity(0.09) : .white.opacity(0.045))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(viewModel.selectedProfile == profile ? accent.opacity(0.92) : .white.opacity(0.075), lineWidth: viewModel.selectedProfile == profile ? 1.4 : 1)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(profile.displayName)
                .accessibilityValue(viewModel.selectedProfile == profile ? "Selected" : "")
            }

            effortControl
        }
    }

    private var effortControl: some View {
        HStack(spacing: 3) {
            ForEach(ReasoningEffort.allCases) { effort in
                Button {
                    viewModel.reasoningEffort = effort
                } label: {
                    Text(effort.displayName)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(
                            viewModel.reasoningEffort == effort ? .white.opacity(0.95) : .white.opacity(0.45)
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(viewModel.reasoningEffort == effort ? accent.opacity(0.22) : .clear)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(effort.displayName) reasoning")
                .accessibilityAddTraits(viewModel.reasoningEffort == effort ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.045))
        )
    }

    /// The current turn, and only the current turn: what was just asked, what came
    /// back, and the field to follow up in. The question is pinned rather than
    /// scrolled with the answer, so the relationship between the two stays visible
    /// while a long response streams past. Asking again replaces the turn — this
    /// is deliberately not a transcript.
    private var response: some View {
        VStack(alignment: .leading, spacing: 6) {
            speakerLabel("You", color: .white.opacity(0.45))
            Text(viewModel.askedQuestion)
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.87))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            speakerLabel(viewModel.selectedProfile.shortName, color: accent)
                .padding(.top, 2)

            answer
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(.white.opacity(0.06), lineWidth: 1))
    }

    private func speakerLabel(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .bold))
            .tracking(0.7)
            .foregroundStyle(color)
    }

    private var answer: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if viewModel.responseText.isEmpty && viewModel.isInvoking {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small).tint(accent)
                            Text(viewModel.statusText ?? "Thinking…")
                                .font(.system(size: 12.5))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    } else {
                        MarkdownText(markdown: viewModel.responseText)
                    }
                    Color.clear.frame(height: 1).id("response-end")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: viewModel.responseText) {
                withAnimation(.linear(duration: 0.08)) { proxy.scrollTo("response-end", anchor: .bottom) }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topLeading) {
                PromptTextView(text: $viewModel.prompt, shouldFocus: true, onSubmit: viewModel.submit)
                    .frame(minHeight: 38, maxHeight: viewModel.hasResponse ? 62 : 46)
                if viewModel.prompt.isEmpty {
                    Text(viewModel.hasResponse ? "Ask a follow-up…" : "Ask about this…")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.34))
                        .padding(.leading, 8)
                        .padding(.top, 7)
                        .allowsHitTesting(false)
                }
            }

            HStack {
                Text(speech.isRecording ? "Listening…" : "Return to send · ⌥Return for a line")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(speech.isRecording ? accent : .white.opacity(0.32))
                Spacer()
                Button(action: { viewModel.onToggleVoice?() }) {
                    Image(systemName: speech.isRecording ? "waveform" : "mic")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .background(speech.isRecording ? accent.opacity(0.18 + speech.level * 0.18) : .white.opacity(0.04), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(speech.isRecording ? accent : .white.opacity(0.64))
                .accessibilityLabel(speech.isRecording ? "Stop dictation" : "Start dictation")

                Button(action: viewModel.submit) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 30, height: 30)
                        .background(viewModel.canSubmit ? accent : .white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(viewModel.canSubmit ? .white : .white.opacity(0.3))
                .disabled(!viewModel.canSubmit)
                .accessibilityLabel("Send question")
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(speech.isRecording ? accent.opacity(0.7) : .white.opacity(0.12), lineWidth: 1))
    }

    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.circle.fill")
            Text(message).lineLimit(3)
            Spacer(minLength: 0)
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(Color(red: 1, green: 0.58, blue: 0.46))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(RoundedRectangle(cornerRadius: 16).fill(Color(red: 0.055, green: 0.063, blue: 0.082).opacity(0.72)))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.15), lineWidth: 1))
            .shadow(color: .black.opacity(0.38), radius: 24, x: 0, y: 15)
    }
}

