import AppKit
import CoreGraphics
import Foundation

/// Drives the aiming phase: samples what the pointer means while the user moves,
/// resizes, or draws, and hands the result to the on-screen feedback.
@MainActor
final class SemanticTargetTracker {
    private let contextEngine: ContextAcquiring
    private let feedback: RecognitionFeedbackController
    private var timer: Timer?
    private var previewTask: Task<Void, Never>?
    private var sessionID: UUID?
    private var sourceApplication: AppIdentity?
    private var generation = 0
    private var lastPoint: CGPoint?
    private var level = 0
    private var regionRect: CGRect?

    /// Reports the level the resolver could actually honour, so the interaction
    /// state can be pulled back rather than banking scroll steps off the end.
    var onResolution: ((UUID, SemanticResolution?) -> Void)?

    init(contextEngine: ContextAcquiring, feedback: RecognitionFeedbackController) {
        self.contextEngine = contextEngine
        self.feedback = feedback
    }

    func start(sessionID: UUID, sourceApplication: AppIdentity?) {
        stop()
        self.sessionID = sessionID
        self.sourceApplication = sourceApplication
        level = 0
        regionRect = nil
        feedback.showRecognizing(at: NSEvent.mouseLocation, appName: sourceApplication?.name)
        sample(force: true)

        let timer = Timer(timeInterval: 1.0 / 13.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample(force: false) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func setLevel(_ level: Int) {
        guard self.level != level else { return }
        self.level = level
        sample(force: true)
    }

    /// Drawing overrides semantics entirely: once the user is describing a shape,
    /// highlighting elements underneath it would be noise.
    func setRegion(_ rect: CGRect?) {
        regionRect = rect
        previewTask?.cancel()
        if let rect {
            feedback.showRegion(rect)
        } else {
            sample(force: true)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        previewTask?.cancel()
        previewTask = nil
        sessionID = nil
        sourceApplication = nil
        lastPoint = nil
        level = 0
        regionRect = nil
        generation += 1
    }

    private func sample(force: Bool) {
        guard let sessionID, regionRect == nil else { return }
        let point = NSEvent.mouseLocation
        if !force, let lastPoint, hypot(point.x - lastPoint.x, point.y - lastPoint.y) < 2 { return }
        lastPoint = point
        generation += 1
        let currentGeneration = generation
        let sourceApplication = sourceApplication
        let level = level
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            guard let self else { return }
            let resolution = await contextEngine.preview(
                at: point,
                sourceApplication: sourceApplication,
                level: level
            )
            guard !Task.isCancelled,
                  self.sessionID == sessionID,
                  self.generation == currentGeneration,
                  self.regionRect == nil else { return }
            feedback.update(resolution: resolution, point: point, appName: sourceApplication?.name)
            onResolution?(sessionID, resolution)
        }
    }
}
