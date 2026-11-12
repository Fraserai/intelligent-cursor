import AppKit
import Combine
import CoreGraphics
import Foundation

@MainActor
final class ApplicationCoordinator: ObservableObject {
    @Published private(set) var phase: InteractionPhase = .idle
    @Published private(set) var statusMessage = "Ready"
    @Published var selectedProfile: ModelProfileID {
        didSet {
            UserDefaults.standard.set(selectedProfile.rawValue, forKey: Self.selectedProfileKey)
            activePanelModel?.selectedProfile = selectedProfile
        }
    }
    @Published var reasoningEffort: ReasoningEffort {
        didSet {
            UserDefaults.standard.set(reasoningEffort.rawValue, forKey: Self.reasoningEffortKey)
            activePanelModel?.reasoningEffort = reasoningEffort
        }
    }
    @Published var activationMouseButton: Int64 {
        didSet {
            UserDefaults.standard.set(activationMouseButton, forKey: Self.mouseButtonKey)
            activationMonitor.mouseButtonNumber = activationMouseButton
        }
    }

    let permissionManager: PermissionManager

    /// A short list of conversations that can be reopened from the menu. This is
    /// the whole of conversation management on purpose.
    @Published private(set) var recentConversations: [ConversationSummary] = []

    private static let selectedProfileKey = "selected-model-profile"
    private static let mouseButtonKey = "activation-mouse-button"
    private static let reasoningEffortKey = "reasoning-effort"
    private static let requestedPermissionsKey = "has-requested-context-permissions"

    private let configuration: AppConfiguration
    private let contextEngine: ContextAcquiring
    private let feedbackController: RecognitionFeedbackController
    private let targetTracker: SemanticTargetTracker
    private let panelController = AssistantPanelController()
    private let speechController: SpeechInputController
    private let activationMonitor: GlobalActivationMonitor
    private let gesturePolicy: ActivationGesturePolicy
    private let intelligenceRouter: IntelligenceRouter
    private let conversationStore = ConversationStore()

    private var reducer = InteractionReducer()
    private var acquisitionTask: Task<Void, Never>?
    private var invocationTask: Task<Void, Never>?
    private var activeContext: ContextBundle?
    private var activePanelModel: AssistantPanelViewModel?
    private var history: [ConversationTurn] = []
    private var workspaceObserver: NSObjectProtocol?
    private var lastExternalApplication: AppIdentity?
    private var permissionPollTimer: Timer?
    private var lastAimFrame: CGRect?
    private var panelCancellables = Set<AnyCancellable>()
    private var activeConversation: StoredConversation?

    init(
        configuration: AppConfiguration = ConfigurationLoader.load(),
        contextEngine: ContextAcquiring = ContextAcquisitionEngine(),
        gesturePolicy: ActivationGesturePolicy = TapToArmGesturePolicy()
    ) {
        self.configuration = configuration
        self.contextEngine = contextEngine
        self.gesturePolicy = gesturePolicy

        let permissionManager = PermissionManager()
        self.permissionManager = permissionManager
        speechController = SpeechInputController(permissionManager: permissionManager)

        let feedbackController = RecognitionFeedbackController()
        self.feedbackController = feedbackController
        targetTracker = SemanticTargetTracker(contextEngine: contextEngine, feedback: feedbackController)

        let storedButton = UserDefaults.standard.object(forKey: Self.mouseButtonKey) as? NSNumber
        let resolvedButton = storedButton?.int64Value ?? configuration.activationMouseButton
        activationMouseButton = resolvedButton
        activationMonitor = GlobalActivationMonitor(mouseButtonNumber: resolvedButton)
        intelligenceRouter = IntelligenceRouter(configuration: configuration)

        if let storedProfile = UserDefaults.standard.string(forKey: Self.selectedProfileKey),
           let profile = ModelProfileID(rawValue: storedProfile) {
            selectedProfile = profile
        } else {
            selectedProfile = .gpt56SolMax
        }

        // Balanced, not Max. Most questions asked at the cursor are quick ones,
        // and the wait is what stops the interaction feeling immediate.
        if let storedEffort = UserDefaults.standard.string(forKey: Self.reasoningEffortKey),
           let effort = ReasoningEffort(rawValue: storedEffort) {
            reasoningEffort = effort
        } else {
            reasoningEffort = .balanced
        }

        targetTracker.onResolution = { [weak self] sessionID, resolution in
            self?.trackerResolved(sessionID: sessionID, resolution: resolution)
        }
    }

    var configuredProfiles: Set<ModelProfileID> {
        Set(ModelProfileID.allCases.filter(configuration.isConfigured))
    }

    func start() {
        guard activationMonitor.onEvent == nil else { return }
        rememberExternalApplication(FrontmostApplicationProvider.snapshot())
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let identity = AppIdentity(
                processIdentifier: app.processIdentifier,
                name: app.localizedName ?? "Unknown app",
                bundleIdentifier: app.bundleIdentifier
            )
            Task { @MainActor in self?.rememberExternalApplication(identity) }
        }

        activationMonitor.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        activationMonitor.start()
        permissionManager.refresh()
        Diagnostics.lifecycle.notice(
            """
            started. accessibility=\(self.permissionManager.accessibility.rawValue, privacy: .public) \
            inputMonitoring=\(self.permissionManager.inputMonitoring.rawValue, privacy: .public) \
            screenRecording=\(self.permissionManager.screenRecording.rawValue, privacy: .public) \
            configuredProfiles=\(self.configuredProfiles.count, privacy: .public)
            """
        )
        requestContextPermissionsOnFirstLaunch()
        startPermissionPollingIfNeeded()
        refreshRecentConversations()
        statusMessage = readinessMessage()
    }

    /// The app is semantic-first, so Accessibility is what makes it work at all.
    /// Without it the cursor silently understands nothing, so ask again on any
    /// launch where it is still missing rather than only the very first one. That
    /// also recovers on its own when a stale Accessibility grant stops matching
    /// the app's code signature, which otherwise reads as "enabled but ignored".
    /// Screen Recording is only the visual fallback, so it is asked for once and
    /// a deliberate refusal is then respected.
    private func requestContextPermissionsOnFirstLaunch() {
        let essentialMissing = permissionManager.accessibility != .granted
            || permissionManager.inputMonitoring != .granted
        let askedBefore = UserDefaults.standard.bool(forKey: Self.requestedPermissionsKey)

        guard essentialMissing || !askedBefore else { return }
        guard essentialMissing || permissionManager.screenRecording != .granted else { return }

        UserDefaults.standard.set(true, forKey: Self.requestedPermissionsKey)
        Diagnostics.lifecycle.notice("requesting context permissions (essential missing: \(essentialMissing, privacy: .public))")
        permissionManager.requestContextPermissions()
    }

    /// Permissions are granted in System Settings while this app is already
    /// running, so poll until the essentials arrive rather than requiring a
    /// relaunch the user has no reason to know about. Stops once satisfied.
    private func startPermissionPollingIfNeeded() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
        guard permissionManager.accessibility != .granted
            || permissionManager.inputMonitoring != .granted else { return }

        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollPermissions() }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionPollTimer = timer
    }

    private func pollPermissions() {
        permissionManager.refresh()

        // The tap mode is chosen once at start. Granting Accessibility later has
        // to upgrade the listen-only tap, or the side button keeps reaching the
        // app that is underneath the cursor as well.
        if permissionManager.accessibility == .granted, !activationMonitor.isIntercepting {
            Diagnostics.trigger.notice("accessibility granted; upgrading to an intercepting event tap")
            activationMonitor.stop()
            activationMonitor.start()
            syncPointerCapture()
        }

        if reducer.state.phase == .idle {
            statusMessage = readinessMessage()
        }

        if permissionManager.accessibility == .granted,
           permissionManager.inputMonitoring == .granted {
            Diagnostics.lifecycle.notice("all essential permissions granted")
            permissionPollTimer?.invalidate()
            permissionPollTimer = nil
        }
    }

    /// Names the missing essential rather than claiming to be ready.
    private func readinessMessage() -> String {
        if permissionManager.accessibility != .granted {
            return "Accessibility off · cannot read what you point at"
        }
        if permissionManager.inputMonitoring != .granted {
            return "Input Monitoring off · side button may not reach the app"
        }
        return "Ready · side button or F18"
    }

    func stop() {
        dismissInteraction()
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
        activationMonitor.stop()
        activationMonitor.onEvent = nil
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        workspaceObserver = nil
    }

    func activateAtCursor() {
        dismissInteraction()
        let point = NSEvent.mouseLocation
        apply(reducer.commitImmediately(at: point, sourceApplication: currentSourceApplication()))
    }

    func requestContextPermissions() {
        permissionManager.requestContextPermissions()
    }

    func setMouseButton(_ button: Int64) {
        activationMouseButton = button
        statusMessage = "Activation set to mouse button \(button) · F18 also works"
    }

    func dismissInteraction() {
        apply(reducer.dismiss())
    }

    private func handle(_ event: TriggerEvent) {
        guard let intent = gesturePolicy.intent(for: event, currentPhase: reducer.state.phase) else { return }
        Diagnostics.trigger.debug(
            "intent \(String(describing: intent), privacy: .public) from phase \(self.reducer.state.phase.rawValue, privacy: .public)"
        )

        switch intent {
        case .beginInspection:
            apply(reducer.beginInspection(
                at: event.point,
                date: event.date,
                sourceApplication: currentSourceApplication()
            ))
        case .commitInspection:
            apply(reducer.commitInspection(at: event.point))
        case .restartInspection:
            apply(reducer.dismiss())
            apply(reducer.beginInspection(
                at: event.point,
                date: event.date,
                sourceApplication: currentSourceApplication()
            ))
        case .cancel:
            dismissInteraction()
        case let .adjustGranularity(delta):
            apply(reducer.adjustGranularity(by: delta))
        case .confirmTarget:
            apply(reducer.confirmTarget(at: event.point))
        case let .beginRegion(origin):
            apply(reducer.beginRegion(origin: origin, current: event.point))
        case .updateRegion:
            apply(reducer.updateRegion(to: event.point))
        case .commitRegion:
            apply(reducer.commitRegion())
        }
    }

    private func apply(_ effect: InteractionEffect) {
        switch effect {
        case .none:
            break

        case let .beginTracking(session):
            // Arming always means "I am choosing new context". Any open
            // conversation ends here rather than competing with the new target for
            // attention; it has already been saved after each completed turn, so it
            // stays reachable from Recent Conversations.
            cancelTransientWork()
            activeContext = nil
            activeConversation = nil
            history.removeAll(keepingCapacity: false)
            lastAimFrame = nil
            let viewModel = makePanelModel(sessionID: session.id)
            activePanelModel = viewModel
            targetTracker.start(sessionID: session.id, sourceApplication: session.sourceApplication)
            panelController.showController(viewModel: viewModel, speech: speechController)
            statusMessage = "Point at something · scroll to resize"

        case let .updateGranularity(_, level):
            targetTracker.setLevel(level)

        case let .updateRegion(_, rect):
            lastAimFrame = rect
            targetTracker.setRegion(rect)

        case let .commit(sessionID, selection, sourceApplication):
            targetTracker.stop()
            // Confirm the lock, then clear it. The outline belongs to aiming; left
            // on screen it makes the page look like it is still in selection mode,
            // and it would otherwise sit over whatever the user navigates to next.
            feedbackController.lock()
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard let self, self.reducer.state.phase != .armed else { return }
                self.feedbackController.hide()
            }
            acquireContext(sessionID: sessionID, selection: selection, sourceApplication: sourceApplication)

        case .cancel:
            cancelTransientWork()
            activeContext = nil
            activePanelModel = nil
            activeConversation = nil
            lastAimFrame = nil
            history.removeAll(keepingCapacity: false)
            statusMessage = readinessMessage()
        }

        phase = reducer.state.phase
        syncPointerCapture()
    }

    /// The trigger source only takes over the pointer while the active policy
    /// actually needs it, so an idle Mac behaves exactly as it always did.
    private func syncPointerCapture() {
        activationMonitor.capturesPointerInput = gesturePolicy.capturesPointerInput(in: reducer.state.phase)
        activationMonitor.passthroughRect = panelController.panelFrame
    }

    private func trackerResolved(sessionID: UUID, resolution: SemanticResolution?) {
        lastAimFrame = resolution?.snapshot.appKitFrame
        if let resolution {
            reducer.setGranularity(resolution.level, sessionID: sessionID)
        }
    }

    private func acquireContext(sessionID: UUID, selection: TargetSelection, sourceApplication: AppIdentity?) {
        acquisitionTask?.cancel()
        statusMessage = "Understanding what you pointed at…"

        let anchor = selection.appKitPoint
        expandPanel(sessionID: sessionID, anchor: anchor)

        acquisitionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let context = try await contextEngine.acquire(
                    sessionID: sessionID,
                    selection: selection,
                    sourceApplication: sourceApplication
                )
                try Task.checkCancellation()
                guard reducer.state.sessionID == sessionID else { return }
                Diagnostics.context.notice(
                    """
                    acquired role=\(context.target.semantic?.role ?? "none", privacy: .public) \
                    confidence=\(context.target.semantic?.confidence ?? 0, privacy: .public) \
                    items=[\(context.diagnosticSummary, privacy: .public)]
                    """
                )
                present(context: context, sessionID: sessionID)
            } catch is CancellationError {
                return
            } catch {
                guard reducer.state.sessionID == sessionID else { return }
                Diagnostics.context.error("acquisition failed: \(error.localizedDescription, privacy: .public)")
                presentAcquisitionFailure(error, sessionID: sessionID)
            }
        }
    }

    private func expandPanel(sessionID: UUID, anchor: CGPoint) {
        let viewModel = activePanelModel ?? makePanelModel(sessionID: sessionID)
        activePanelModel = viewModel
        panelController.expand(
            viewModel: viewModel,
            speech: speechController,
            targetRect: lastAimFrame ?? .zero,
            anchor: anchor
        )
        syncPointerCapture()
    }

    private func present(context: ContextBundle, sessionID: UUID) {
        activeContext = context
        activeConversation = nil
        history.removeAll(keepingCapacity: true)
        reducer.markPrompting(sessionID: sessionID)
        phase = reducer.state.phase
        statusMessage = context.target.semantic?.recognitionLabel ?? "Visual context ready"
        activePanelModel?.contextLabel = statusMessage
    }

    private func presentAcquisitionFailure(_ error: Error, sessionID: UUID) {
        reducer.markFailed(sessionID: sessionID)
        phase = reducer.state.phase
        let message = error.localizedDescription
        statusMessage = message
        activePanelModel?.fail(message)
    }

    private func makePanelModel(sessionID: UUID) -> AssistantPanelViewModel {
        let viewModel = AssistantPanelViewModel(
            selectedProfile: selectedProfile,
            reasoningEffort: reasoningEffort,
            contextLabel: "",
            configuredProfiles: configuredProfiles
        )
        viewModel.onDismiss = { [weak self] in self?.dismissInteraction() }
        viewModel.onSubmit = { [weak self, weak viewModel] prompt, profile, effort in
            self?.selectedProfile = profile
            self?.reasoningEffort = effort
            self?.submit(prompt: prompt, profile: profile, effort: effort, sessionID: sessionID, viewModel: viewModel)
        }

        // Remember the setting the moment it changes, not only once a question is
        // sent, so the choice survives a cancelled interaction.
        panelCancellables.removeAll()
        viewModel.$reasoningEffort
            .dropFirst()
            .sink { [weak self] effort in
                guard let self, self.reasoningEffort != effort else { return }
                self.reasoningEffort = effort
            }
            .store(in: &panelCancellables)
        viewModel.onToggleVoice = { [weak self, weak viewModel] in
            guard let self, let viewModel else { return }
            speechController.toggle(
                onTranscript: { [weak viewModel] transcript in viewModel?.prompt = transcript },
                onError: { [weak viewModel] message in viewModel?.fail(message) }
            )
        }
        return viewModel
    }

    private func submit(
        prompt: String,
        profile: ModelProfileID,
        effort: ReasoningEffort,
        sessionID: UUID,
        viewModel: AssistantPanelViewModel?
    ) {
        guard let viewModel, reducer.state.sessionID == sessionID else { return }
        guard let context = activeContext else {
            viewModel.fail("There is no locked context to send. Point again and click to lock.")
            return
        }
        guard configuration.isConfigured(profile) else {
            viewModel.fail(missingCredentialMessage(for: profile))
            return
        }

        speechController.stop()
        invocationTask?.cancel()
        reducer.markInvoking(sessionID: sessionID)
        phase = reducer.state.phase
        statusMessage = "Thinking with \(profile.displayName(effort: effort))…"
        viewModel.beginResponse()

        let request = IntelligenceRequest(
            profile: profile,
            effort: effort,
            prompt: prompt,
            context: context,
            history: history
        )

        Diagnostics.intelligence.notice(
            "invoking \(profile.rawValue, privacy: .public) effort=\(effort.rawValue, privacy: .public) with [\(context.diagnosticSummary, privacy: .public)]"
        )

        invocationTask = Task { [weak self, weak viewModel] in
            guard let self, let viewModel else { return }
            var completeResponse = ""
            var receivedFirstDelta = false
            do {
                for try await event in intelligenceRouter.stream(request) {
                    try Task.checkCancellation()
                    guard reducer.state.sessionID == sessionID else { return }
                    switch event {
                    case let .status(text):
                        viewModel.setStatus(text)
                        statusMessage = text
                    case let .delta(delta):
                        if !receivedFirstDelta {
                            receivedFirstDelta = true
                            reducer.markResponding(sessionID: sessionID)
                            phase = reducer.state.phase
                        }
                        completeResponse += delta
                        viewModel.append(delta)
                    }
                }
                try Task.checkCancellation()
                guard reducer.state.sessionID == sessionID else { return }
                viewModel.finish()
                history.append(ConversationTurn(profile: profile, prompt: prompt, response: completeResponse))
                persistConversation(context: context)
                Diagnostics.intelligence.notice(
                    "\(profile.rawValue, privacy: .public) answered (\(completeResponse.count, privacy: .public) characters)"
                )
                statusMessage = "Answer ready"
            } catch is CancellationError {
                return
            } catch {
                guard reducer.state.sessionID == sessionID else { return }
                reducer.markFailed(sessionID: sessionID)
                phase = reducer.state.phase
                Diagnostics.intelligence.error(
                    "\(profile.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
                statusMessage = error.localizedDescription
                viewModel.fail(error.localizedDescription)
            }
        }
    }

    private func persistConversation(context: ContextBundle) {
        guard let first = history.first else { return }
        let now = Date()
        var conversation = activeConversation ?? StoredConversation(
            id: UUID(),
            title: StoredConversation.title(from: first.prompt),
            createdAt: now,
            updatedAt: now,
            originLabel: context.target.semantic?.recognitionLabel
                ?? context.target.sourceApplication?.name
                ?? "Pointed target",
            contextText: context.untrustedText(),
            imageMimeType: context.image?.mimeType,
            imagePixelWidth: context.image?.pixelWidth,
            imagePixelHeight: context.image?.pixelHeight,
            turns: []
        )
        conversation.updatedAt = now
        conversation.turns = history.map {
            StoredTurn(profile: $0.profile.rawValue, prompt: $0.prompt, response: $0.response)
        }
        activeConversation = conversation

        conversationStore.save(conversation, image: context.image?.data)
        refreshRecentConversations()
    }

    private func refreshRecentConversations() {
        recentConversations = conversationStore.summaries()
    }

    /// Reopens a saved conversation with no target involved. It restores into the
    /// prompting phase, so follow-ups, dismissal, and persistence all run through
    /// exactly the same path as a conversation started from the cursor.
    func reopen(_ summary: ConversationSummary) {
        guard let loaded = conversationStore.load(id: summary.id) else {
            statusMessage = "That conversation could not be reopened."
            return
        }

        dismissInteraction()

        let sessionID = reducer.restoreConversation()
        phase = reducer.state.phase
        activeConversation = loaded.conversation
        history = loaded.conversation.turns.compactMap { turn in
            guard let profile = ModelProfileID(rawValue: turn.profile) else { return nil }
            return ConversationTurn(profile: profile, prompt: turn.prompt, response: turn.response)
        }
        activeContext = restoredBundle(from: loaded.conversation, image: loaded.image, sessionID: sessionID)

        let viewModel = makePanelModel(sessionID: sessionID)
        if let last = history.last {
            viewModel.restore(question: last.prompt, response: last.response)
        }
        activePanelModel = viewModel
        lastAimFrame = nil
        statusMessage = loaded.conversation.title

        panelController.expand(
            viewModel: viewModel,
            speech: speechController,
            targetRect: .zero,
            anchor: NSEvent.mouseLocation
        )
        syncPointerCapture()
        Diagnostics.lifecycle.notice(
            "reopened conversation with \(self.history.count, privacy: .public) turns"
        )
    }

    private func restoredBundle(from conversation: StoredConversation, image: Data?, sessionID: UUID) -> ContextBundle {
        let provenance = ContextProvenance(
            adapterID: "reopened-conversation",
            capturedAt: conversation.createdAt,
            sourceBundleIdentifier: nil,
            confidence: 0.9
        )
        var items: [ContextItem] = []
        if !conversation.contextText.isEmpty {
            items.append(ContextItem(
                payload: .text(TextExcerpt(kind: "original pointed context", text: conversation.contextText)),
                provenance: provenance
            ))
        }
        if let image, let mimeType = conversation.imageMimeType {
            items.append(ContextItem(
                payload: .image(EncodedImage(
                    data: image,
                    mimeType: mimeType,
                    pixelWidth: conversation.imagePixelWidth ?? 0,
                    pixelHeight: conversation.imagePixelHeight ?? 0,
                    displayRect: .zero
                )),
                provenance: provenance
            ))
        }
        let target = PointedTarget(
            id: sessionID,
            gesture: .semanticPoint,
            appKitPoint: .zero,
            displayPoint: .zero,
            sourceApplication: nil,
            semantic: nil,
            capturedAt: conversation.createdAt
        )
        return ContextBundle(target: target, items: items)
    }

    private func cancelTransientWork() {
        acquisitionTask?.cancel()
        invocationTask?.cancel()
        acquisitionTask = nil
        invocationTask = nil
        speechController.stop()
        targetTracker.stop()
        feedbackController.hide()
        panelController.hide()
    }

    private func currentSourceApplication() -> AppIdentity? {
        let current = FrontmostApplicationProvider.snapshot()
        if current?.bundleIdentifier != Bundle.main.bundleIdentifier {
            rememberExternalApplication(current)
            return current
        }
        return lastExternalApplication
    }

    private func rememberExternalApplication(_ application: AppIdentity?) {
        guard let application,
              application.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        lastExternalApplication = application
    }

    private func missingCredentialMessage(for profile: ModelProfileID) -> String {
        switch profile {
        case .gpt56SolMax:
            "Add OPENAI_API_KEY to .env.local or the app Keychain."
        case .opus5Max:
            "Add ANTHROPIC_API_KEY to .env.local or the app Keychain."
        case .grok46Heavy:
            "Add XAI_API_KEY to .env.local or the app Keychain."
        case .allThree:
            "All 3 needs OPENAI_API_KEY, ANTHROPIC_API_KEY, and XAI_API_KEY."
        }
    }
}
