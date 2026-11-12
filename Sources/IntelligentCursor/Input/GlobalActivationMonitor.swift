import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation

final class GlobalActivationMonitor: TriggerSource {
    var onEvent: ((TriggerEvent) -> Void)?
    var mouseButtonNumber: Int64

    /// Set by the coordinator from the active policy. While false the pointer's
    /// clicks and scrolling are never touched, so the Mac behaves normally
    /// whenever no interaction is in progress.
    var capturesPointerInput = false

    /// The controller's own frame. Clicks inside it belong to the controller, not
    /// to targeting, so they are passed through untouched.
    var passthroughRect: CGRect?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fallbackMonitor: Any?
    private var interceptsEvents = false
    private var scrollAccumulator = 0.0

    /// False while running on a listen-only tap or the NSEvent fallback, which is
    /// what happens when Accessibility was not yet granted at start time.
    var isIntercepting: Bool { interceptsEvents }

    init(mouseButtonNumber: Int64) {
        self.mouseButtonNumber = mouseButtonNumber
    }

    func start() {
        guard eventTap == nil, fallbackMonitor == nil else { return }

        let mask = eventMask(
            .otherMouseDown,
            .otherMouseUp,
            .leftMouseDown,
            .leftMouseUp,
            .leftMouseDragged,
            .scrollWheel,
            .keyDown,
            .keyUp
        )
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        if AXIsProcessTrusted(), let activeTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.eventTapCallback,
            userInfo: userInfo
        ) {
            eventTap = activeTap
            interceptsEvents = true
        } else if let passiveTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: Self.eventTapCallback,
            userInfo: userInfo
        ) {
            eventTap = passiveTap
            interceptsEvents = false
        }

        if let eventTap {
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
            Diagnostics.trigger.notice(
                "event tap active (intercepting: \(self.interceptsEvents, privacy: .public)) button \(self.mouseButtonNumber, privacy: .public)"
            )
        } else {
            installNSEventFallback()
            Diagnostics.trigger.warning(
                "no event tap; using NSEvent global monitor. Input Monitoring is probably not granted."
            )
        }
    }

    func stop() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let fallbackMonitor { NSEvent.removeMonitor(fallbackMonitor) }
        eventTap = nil
        runLoopSource = nil
        fallbackMonitor = nil
        interceptsEvents = false
        capturesPointerInput = false
        scrollAccumulator = 0
    }

    deinit { stop() }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<GlobalActivationMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        return monitor.handle(type: type, event: event)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let passThrough = Unmanaged.passUnretained(event)
        let input: TriggerInput?
        var kind = TriggerKind.directMouseButton

        switch type {
        case .otherMouseDown, .otherMouseUp:
            guard event.getIntegerValueField(.mouseEventButtonNumber) == mouseButtonNumber else {
                return passThrough
            }
            input = .activationButton(type == .otherMouseDown ? .pressed : .released)

        case .keyDown, .keyUp:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return passThrough }
            if keyCode == Int64(kVK_F18) {
                kind = .mappedFunctionKey
                input = .activationButton(type == .keyDown ? .pressed : .released)
            } else if keyCode == Int64(kVK_Escape), capturesPointerInput, type == .keyDown {
                kind = .mappedFunctionKey
                input = .cancelKey
            } else {
                return passThrough
            }

        case .leftMouseDown, .leftMouseUp, .leftMouseDragged, .scrollWheel:
            guard capturesPointerInput else { return passThrough }
            if let passthroughRect, passthroughRect.contains(NSEvent.mouseLocation) { return passThrough }
            switch type {
            case .leftMouseDown: input = .primaryButton(.pressed)
            case .leftMouseUp: input = .primaryButton(.released)
            case .leftMouseDragged: input = .primaryDrag
            default: input = scrollInput(from: event)
            }

        default:
            input = nil
        }

        guard let input else { return passThrough }

        let point = NSEvent.mouseLocation
        let resolvedKind = kind
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(TriggerEvent(input: input, point: point, date: Date(), kind: resolvedKind))
        }
        return interceptsEvents ? nil : passThrough
    }

    /// Wheels report whole lines, trackpads report pixels. Accumulate the pixel
    /// case so a slow two-finger drag still produces discrete granularity steps.
    private func scrollInput(from event: CGEvent) -> TriggerInput? {
        let lines = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        if lines != 0 {
            scrollAccumulator = 0
            return .scroll(steps: Int(lines))
        }

        scrollAccumulator += Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
        let stride = 24.0
        guard abs(scrollAccumulator) >= stride else { return .scroll(steps: 0) }
        let steps = Int((scrollAccumulator / stride).rounded(.towardZero))
        scrollAccumulator -= Double(steps) * stride
        return .scroll(steps: steps)
    }

    private func installNSEventFallback() {
        fallbackMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.otherMouseDown, .otherMouseUp, .keyDown, .keyUp]
        ) { [weak self] event in
            guard let self else { return }
            let input: TriggerInput
            let kind: TriggerKind

            switch event.type {
            case .otherMouseDown, .otherMouseUp:
                guard Int64(event.buttonNumber) == mouseButtonNumber else { return }
                input = .activationButton(event.type == .otherMouseDown ? .pressed : .released)
                kind = .directMouseButton
            case .keyDown, .keyUp:
                guard event.keyCode == UInt16(kVK_F18), !event.isARepeat else { return }
                input = .activationButton(event.type == .keyDown ? .pressed : .released)
                kind = .mappedFunctionKey
            default:
                return
            }

            onEvent?(TriggerEvent(input: input, point: NSEvent.mouseLocation, date: Date(), kind: kind))
        }
    }

    private func eventMask(_ types: CGEventType...) -> CGEventMask {
        types.reduce(CGEventMask(0)) { partial, type in
            partial | (CGEventMask(1) << CGEventMask(type.rawValue))
        }
    }
}
