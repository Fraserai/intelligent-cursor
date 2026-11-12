import AppKit
import Combine
import CoreGraphics
import Foundation
import SwiftUI

/// One window with two states. It appears compact and out of the way when AI mode
/// is armed, then expands in place once a target is locked, so the panel is the
/// controller and the screen stays the canvas.
@MainActor
final class AssistantPanelController {
    private var panel: IntelligentAssistantPanel?
    private var clickAwayMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var targetRect: CGRect = .zero
    private var anchor: CGPoint = .zero
    private var isExpanded = false
    private var hasBeenMoved = false

    /// The controller's own frame, so the trigger source can let clicks through to
    /// it instead of reading them as targeting.
    var panelFrame: CGRect? { panel?.frame }

    func showController(viewModel: AssistantPanelViewModel, speech: SpeechInputController) {
        hide()
        isExpanded = false
        hasBeenMoved = false

        let panel = makePanel(viewModel: viewModel)
        panel.contentView = NSHostingView(
            rootView: ControllerBarView(viewModel: viewModel, speech: speech)
        )
        self.panel = panel

        let screen = ScreenCoordinateSpace.screen(containing: NSEvent.mouseLocation)
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = PanelPlacement.controllerOrigin(
            size: PanelMetrics.controllerSize,
            visibleFrame: visible
        )
        panel.setFrame(CGRect(origin: origin, size: PanelMetrics.controllerSize), display: true)

        // Never activates the app: aiming must not disturb whatever is underneath.
        panel.orderFrontRegardless()
    }

    /// Expands the controller into the full panel beside the locked target.
    func expand(
        viewModel: AssistantPanelViewModel,
        speech: SpeechInputController,
        targetRect: CGRect,
        anchor: CGPoint
    ) {
        self.targetRect = targetRect
        self.anchor = anchor

        let panel = self.panel ?? makePanel(viewModel: viewModel)
        self.panel = panel
        isExpanded = true

        panel.contentView = NSHostingView(
            rootView: AssistantPanelView(
                viewModel: viewModel,
                speech: speech,
                onMoveBy: { [weak self] delta in self?.move(by: delta) }
            )
        )

        cancellables.removeAll()
        Publishers.CombineLatest(viewModel.$responseText, viewModel.$isInvoking)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.layout(animated: true) }
            .store(in: &cancellables)

        layout(animated: true)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        if clickAwayMonitor == nil {
            clickAwayMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak viewModel] _ in
                guard let self, let panel = self.panel, let viewModel, self.isExpanded else { return }
                // Once a question has been asked this is a conversation, and
                // changing tabs, scrolling a page, or switching applications must
                // not end it. Only a deliberate close does.
                guard viewModel.askedQuestion.isEmpty else { return }
                if !panel.frame.contains(NSEvent.mouseLocation) {
                    DispatchQueue.main.async { viewModel.onDismiss?() }
                }
            }
        }
    }

    /// SwiftUI's y grows downward and a window's origin grows upward, so the
    /// vertical delta is inverted on the way through.
    private func move(by delta: CGSize) {
        guard let panel else { return }
        hasBeenMoved = true
        panel.setFrameOrigin(CGPoint(
            x: panel.frame.origin.x + delta.width,
            y: panel.frame.origin.y - delta.height
        ))
    }

    func hide() {
        if let clickAwayMonitor { NSEvent.removeMonitor(clickAwayMonitor) }
        clickAwayMonitor = nil
        cancellables.removeAll()
        panel?.orderOut(nil)
        panel = nil
        isExpanded = false
    }

    private func makePanel(viewModel: AssistantPanelViewModel) -> IntelligentAssistantPanel {
        let panel = IntelligentAssistantPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.onCancel = { viewModel.onDismiss?() }
        return panel
    }

    private func layout(animated: Bool) {
        guard let panel, isExpanded,
              let viewModel = (panel.contentView as? NSHostingView<AssistantPanelView>)?.rootView.viewModel else { return }
        let size = PanelMetrics.size(hasResponse: viewModel.hasResponse)
        let reference = hasBeenMoved ? panel.frame.origin : anchor
        let screen = ScreenCoordinateSpace.screen(containing: reference)
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        let origin: CGPoint
        if hasBeenMoved {
            // Keep the header under the pointer by growing downward from where the
            // panel was put, instead of snapping back to the computed placement.
            let current = panel.frame
            origin = CGRect(
                x: current.minX,
                y: current.maxY - size.height,
                width: size.width,
                height: size.height
            ).clamped(to: visible).origin
        } else {
            origin = PanelPlacement.origin(
                panelSize: size,
                targetRect: targetRect.isEmpty ? CGRect(origin: anchor, size: CGSize(width: 1, height: 1)) : targetRect,
                anchor: anchor,
                visibleFrame: visible
            )
        }
        panel.setFrame(CGRect(origin: origin, size: size), display: true, animate: animated)
    }
}

private final class IntelligentAssistantPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
