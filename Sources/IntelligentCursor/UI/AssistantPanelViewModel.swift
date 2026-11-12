import Foundation

@MainActor
final class AssistantPanelViewModel: ObservableObject {
    @Published var selectedProfile: ModelProfileID
    @Published var reasoningEffort: ReasoningEffort
    @Published var prompt = ""
    @Published private(set) var askedQuestion = ""
    @Published private(set) var responseText = ""
    @Published private(set) var isInvoking = false
    @Published private(set) var isComplete = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var statusText: String?
    @Published var contextLabel: String

    let configuredProfiles: Set<ModelProfileID>
    var onSubmit: ((String, ModelProfileID, ReasoningEffort) -> Void)?
    var onDismiss: (() -> Void)?
    var onToggleVoice: (() -> Void)?

    init(
        selectedProfile: ModelProfileID,
        reasoningEffort: ReasoningEffort,
        contextLabel: String,
        configuredProfiles: Set<ModelProfileID>
    ) {
        self.selectedProfile = selectedProfile
        self.reasoningEffort = reasoningEffort
        self.contextLabel = contextLabel
        self.configuredProfiles = configuredProfiles
    }

    var hasResponse: Bool { isInvoking || !responseText.isEmpty || !askedQuestion.isEmpty }
    var canSubmit: Bool { !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isInvoking }

    func submit() {
        let value = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !isInvoking else { return }
        askedQuestion = value
        prompt = ""
        onSubmit?(value, selectedProfile, reasoningEffort)
    }

    func beginResponse() {
        responseText = ""
        statusText = nil
        errorMessage = nil
        isComplete = false
        isInvoking = true
    }

    func append(_ delta: String) {
        responseText += delta
        statusText = nil
        isInvoking = true
    }

    /// What the intelligence is doing while there is nothing to show yet.
    func setStatus(_ text: String) {
        guard responseText.isEmpty else { return }
        statusText = text
    }

    func finish() {
        isInvoking = false
        isComplete = true
    }

    func fail(_ message: String) {
        isInvoking = false
        isComplete = false
        errorMessage = message
    }

    /// Shows a completed turn from a reopened conversation.
    func restore(question: String, response: String) {
        askedQuestion = question
        responseText = response
        isInvoking = false
        isComplete = true
        errorMessage = nil
    }

    func clearError() { errorMessage = nil }
}

