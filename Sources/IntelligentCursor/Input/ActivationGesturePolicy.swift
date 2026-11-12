import CoreGraphics
import Foundation

enum TriggerPhase: Sendable {
    case pressed
    case released
}

enum TriggerKind: Sendable {
    case directMouseButton
    case mappedFunctionKey
    case menu
}

/// Raw physical input. Deliberately says nothing about product meaning — the
/// activation policy alone decides what, if anything, each of these means.
enum TriggerInput: Sendable {
    case activationButton(TriggerPhase)
    case primaryButton(TriggerPhase)
    case primaryDrag
    case scroll(steps: Int)
    case cancelKey
}

struct TriggerEvent: Sendable {
    let input: TriggerInput
    let point: CGPoint
    let date: Date
    let kind: TriggerKind
}

enum ActivationIntent: Equatable {
    case beginInspection
    case commitInspection
    case restartInspection
    case cancel
    /// Walk the semantic ancestry. Positive widens toward the containing element.
    case adjustGranularity(Int)
    case confirmTarget
    case beginRegion(origin: CGPoint)
    case updateRegion
    case commitRegion
}

protocol ActivationGesturePolicy: AnyObject {
    func intent(for event: TriggerEvent, currentPhase: InteractionPhase) -> ActivationIntent?

    /// True while the policy needs the pointer's ordinary clicks and scrolling for
    /// itself. The trigger source passes them through untouched otherwise, so the
    /// Mac behaves completely normally whenever no interaction is in progress.
    func capturesPointerInput(in phase: InteractionPhase) -> Bool
}

/// Codex's original v1 policy. Side button down begins inspection, side button up
/// commits whatever is under the pointer. Deterministic and self-cancelling, but
/// the release chooses the target, so there is no chance to aim.
///
/// Kept intact and swappable so real use can decide which interaction wins.
final class HoldReleaseGesturePolicy: ActivationGesturePolicy {
    func intent(for event: TriggerEvent, currentPhase: InteractionPhase) -> ActivationIntent? {
        switch (event.input, currentPhase) {
        case (.activationButton(.pressed), .idle):
            .beginInspection
        case (.activationButton(.released), .armed):
            .commitInspection
        case (.cancelKey, _) where currentPhase != .idle:
            .cancel
        case (.activationButton(.pressed), .acquiring),
             (.activationButton(.pressed), .prompting),
             (.activationButton(.pressed), .invoking),
             (.activationButton(.pressed), .responding),
             (.activationButton(.pressed), .failed):
            .restartInspection
        default:
            nil
        }
    }

    func capturesPointerInput(in phase: InteractionPhase) -> Bool { false }
}

/// The working policy. A tap arms AI mode and leaves the pointer completely free,
/// so aiming becomes its own phase instead of something the release decides:
///
///     tap to arm → move to aim → scroll to size → click to lock → drag to override
///
/// Distinguishing a click from a drag is gesture mechanics, so the press origin
/// lives here rather than leaking into interaction state.
final class TapToArmGesturePolicy: ActivationGesturePolicy {
    private let dragThreshold: CGFloat = 6
    private var primaryPressOrigin: CGPoint?
    private var isDraggingRegion = false

    func intent(for event: TriggerEvent, currentPhase: InteractionPhase) -> ActivationIntent? {
        switch event.input {
        case .activationButton(.pressed):
            switch currentPhase {
            case .idle: return .beginInspection
            case .armed: return .cancel
            default: return .restartInspection
            }

        case .activationButton(.released):
            // A tap arms on the press. The release is deliberately inert, which is
            // the whole difference from hold/release.
            return nil

        case .cancelKey:
            return currentPhase == .idle ? nil : .cancel

        case let .scroll(steps):
            guard currentPhase == .armed, steps != 0 else { return nil }
            return .adjustGranularity(steps)

        case .primaryButton(.pressed):
            guard currentPhase == .armed else { return nil }
            primaryPressOrigin = event.point
            isDraggingRegion = false
            return nil

        case .primaryDrag:
            guard currentPhase == .armed, let origin = primaryPressOrigin else { return nil }
            guard exceededDragThreshold(from: origin, to: event.point) else { return nil }
            if isDraggingRegion { return .updateRegion }
            isDraggingRegion = true
            return .beginRegion(origin: origin)

        case .primaryButton(.released):
            guard currentPhase == .armed, let origin = primaryPressOrigin else { return nil }
            defer {
                primaryPressOrigin = nil
                isDraggingRegion = false
            }
            return exceededDragThreshold(from: origin, to: event.point) ? .commitRegion : .confirmTarget
        }
    }

    func capturesPointerInput(in phase: InteractionPhase) -> Bool { phase == .armed }

    private func exceededDragThreshold(from origin: CGPoint, to point: CGPoint) -> Bool {
        hypot(point.x - origin.x, point.y - origin.y) > dragThreshold
    }
}

protocol TriggerSource: AnyObject {
    var onEvent: ((TriggerEvent) -> Void)? { get set }
    func start()
    func stop()
}
