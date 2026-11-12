import CoreGraphics
import Foundation

struct ArmedSession: Equatable {
    let id: UUID
    let beganAt: Date
    let initialPoint: CGPoint
    let sourceApplication: AppIdentity?

    /// Offset from the automatically chosen element. Persists as the pointer
    /// moves, so a chosen size stays chosen while aiming at other things.
    var granularityLevel = 0

    var regionOrigin: CGPoint?
    var regionCurrent: CGPoint?

    var regionRect: CGRect? {
        guard let regionOrigin, let regionCurrent else { return nil }
        return CGRect(
            x: min(regionOrigin.x, regionCurrent.x),
            y: min(regionOrigin.y, regionCurrent.y),
            width: abs(regionCurrent.x - regionOrigin.x),
            height: abs(regionCurrent.y - regionOrigin.y)
        )
    }
}

enum InteractionState: Equatable {
    case idle
    case armed(ArmedSession)
    case acquiring(UUID)
    case prompting(UUID)
    case invoking(UUID)
    case responding(UUID)
    case failed(UUID?)

    var phase: InteractionPhase {
        switch self {
        case .idle: .idle
        case .armed: .armed
        case .acquiring: .acquiring
        case .prompting: .prompting
        case .invoking: .invoking
        case .responding: .responding
        case .failed: .failed
        }
    }

    var sessionID: UUID? {
        switch self {
        case .idle: nil
        case let .armed(session): session.id
        case let .acquiring(id), let .prompting(id), let .invoking(id), let .responding(id): id
        case let .failed(id): id
        }
    }

    var armedSession: ArmedSession? {
        if case let .armed(session) = self { return session }
        return nil
    }
}

enum InteractionEffect: Equatable {
    case none
    case beginTracking(ArmedSession)
    case updateGranularity(sessionID: UUID, level: Int)
    case updateRegion(sessionID: UUID, rect: CGRect?)
    case commit(sessionID: UUID, selection: TargetSelection, sourceApplication: AppIdentity?)
    case cancel(UUID?)
}

struct InteractionReducer {
    private(set) var state: InteractionState = .idle

    mutating func beginInspection(at point: CGPoint, date: Date, sourceApplication: AppIdentity?) -> InteractionEffect {
        let session = ArmedSession(
            id: UUID(),
            beganAt: date,
            initialPoint: point,
            sourceApplication: sourceApplication
        )
        state = .armed(session)
        return .beginTracking(session)
    }

    mutating func adjustGranularity(by delta: Int) -> InteractionEffect {
        guard var session = state.armedSession else { return .none }
        session.granularityLevel += delta
        state = .armed(session)
        return .updateGranularity(sessionID: session.id, level: session.granularityLevel)
    }

    /// Pulled back to what the resolver could actually honour, so scrolling past
    /// the end of the ancestry does not bank steps that must be undone later.
    mutating func setGranularity(_ level: Int, sessionID: UUID) {
        guard var session = state.armedSession, session.id == sessionID else { return }
        guard session.granularityLevel != level, session.regionOrigin == nil else { return }
        session.granularityLevel = level
        state = .armed(session)
    }

    mutating func beginRegion(origin: CGPoint, current: CGPoint) -> InteractionEffect {
        guard var session = state.armedSession else { return .none }
        session.regionOrigin = origin
        session.regionCurrent = current
        state = .armed(session)
        return .updateRegion(sessionID: session.id, rect: session.regionRect)
    }

    mutating func updateRegion(to point: CGPoint) -> InteractionEffect {
        guard var session = state.armedSession, session.regionOrigin != nil else { return .none }
        session.regionCurrent = point
        state = .armed(session)
        return .updateRegion(sessionID: session.id, rect: session.regionRect)
    }

    mutating func commitRegion() -> InteractionEffect {
        guard let session = state.armedSession, let rect = session.regionRect else { return .none }
        state = .acquiring(session.id)
        return .commit(
            sessionID: session.id,
            selection: .region(appKitRect: rect),
            sourceApplication: session.sourceApplication
        )
    }

    mutating func confirmTarget(at point: CGPoint) -> InteractionEffect {
        guard let session = state.armedSession else { return .none }
        state = .acquiring(session.id)
        return .commit(
            sessionID: session.id,
            selection: .semantic(appKitPoint: point, level: session.granularityLevel),
            sourceApplication: session.sourceApplication
        )
    }

    mutating func commitInspection(at point: CGPoint) -> InteractionEffect {
        confirmTarget(at: point)
    }

    mutating func commitImmediately(at point: CGPoint, sourceApplication: AppIdentity?) -> InteractionEffect {
        let id = UUID()
        state = .acquiring(id)
        return .commit(
            sessionID: id,
            selection: .semantic(appKitPoint: point, level: 0),
            sourceApplication: sourceApplication
        )
    }

    /// Enters the prompting phase directly, for a conversation reopened from disk.
    /// There is no target to acquire, but everything downstream — submit, follow
    /// ups, dismissal — is the same path as a freshly pointed-at one.
    mutating func restoreConversation() -> UUID {
        let id = UUID()
        state = .prompting(id)
        return id
    }

    mutating func markPrompting(sessionID: UUID) {
        guard state.sessionID == sessionID else { return }
        state = .prompting(sessionID)
    }

    mutating func markInvoking(sessionID: UUID) {
        guard state.sessionID == sessionID else { return }
        state = .invoking(sessionID)
    }

    mutating func markResponding(sessionID: UUID) {
        guard state.sessionID == sessionID else { return }
        state = .responding(sessionID)
    }

    mutating func markFailed(sessionID: UUID?) {
        guard sessionID == nil || state.sessionID == sessionID else { return }
        state = .failed(sessionID)
    }

    mutating func dismiss() -> InteractionEffect {
        let id = state.sessionID
        state = .idle
        return .cancel(id)
    }
}
