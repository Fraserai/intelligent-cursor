import AppKit
import CoreGraphics
import Foundation

/// The canvas. Everything the system currently believes about what the user means
/// is drawn on the screen itself rather than described in the panel.
@MainActor
final class RecognitionFeedbackController {
    private var panel: NSPanel?
    private var feedbackView: RecognitionFeedbackView?

    func showRecognizing(at point: CGPoint, appName: String?) {
        draw(frame: nil, point: point, label: nil, style: .aiming)
    }

    func update(resolution: SemanticResolution?, point: CGPoint, appName: String?) {
        draw(
            frame: resolution?.snapshot.appKitFrame,
            point: point,
            label: resolution?.snapshot.humanName,
            style: .aiming
        )
    }

    func showRegion(_ rect: CGRect) {
        draw(frame: rect, point: CGPoint(x: rect.midX, y: rect.midY), label: "Region", style: .region)
    }

    /// Keeps the outline on screen after the click so the locked target stays
    /// visible while the question is being asked.
    func lock() {
        guard let feedbackView else { return }
        feedbackView.style = .locked
        feedbackView.needsDisplay = true
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        feedbackView = nil
    }

    private func draw(frame: CGRect?, point: CGPoint, label: String?, style: RecognitionFeedbackView.Style) {
        let screen = ScreenCoordinateSpace.screen(containing: point)
        let visibleFrame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        let highlight: CGRect
        if let frame,
           frame.width >= 8,
           frame.height >= 8,
           frame.width <= visibleFrame.width * 0.98,
           frame.height <= visibleFrame.height * 0.94 {
            highlight = frame.insetBy(dx: -3, dy: -3).clamped(to: visibleFrame.insetBy(dx: 2, dy: 2))
        } else {
            highlight = CGRect(x: point.x - 17, y: point.y - 17, width: 34, height: 34)
        }

        let labelHeight: CGFloat = 22
        let showAbove = highlight.maxY + labelHeight + 10 < visibleFrame.maxY
        var windowFrame = highlight.insetBy(dx: -10, dy: -10)
        if label != nil {
            if showAbove {
                windowFrame.size.height += labelHeight + 4
            } else {
                windowFrame.origin.y -= labelHeight + 4
                windowFrame.size.height += labelHeight + 4
            }
        }
        windowFrame = windowFrame.clamped(to: visibleFrame)

        let localHighlight = CGRect(
            x: highlight.minX - windowFrame.minX,
            y: highlight.minY - windowFrame.minY,
            width: highlight.width,
            height: highlight.height
        )

        let panel = self.panel ?? makePanel()
        let view = feedbackView ?? RecognitionFeedbackView(frame: CGRect(origin: .zero, size: windowFrame.size))
        view.frame = CGRect(origin: .zero, size: windowFrame.size)
        view.highlightRect = localHighlight
        view.label = label
        view.labelAbove = showAbove
        view.style = style
        view.needsDisplay = true

        panel.contentView = view
        panel.setFrame(windowFrame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel
        self.feedbackView = view
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }
}

private final class RecognitionFeedbackView: NSView {
    enum Style {
        case aiming
        case locked
        case region
    }

    var highlightRect: CGRect = .zero
    var label: String?
    var labelAbove = true
    var style: Style = .aiming

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !highlightRect.isEmpty else { return }

        let accent = NSColor(calibratedRed: 0.52, green: 0.63, blue: 1, alpha: 1)
        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = accent.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 9
        shadow.shadowOffset = .zero
        shadow.set()

        let outline = NSBezierPath(roundedRect: highlightRect, xRadius: 6, yRadius: 6)
        accent.withAlphaComponent(style == .locked ? 0.12 : 0.07).setFill()
        outline.fill()
        accent.withAlphaComponent(style == .locked ? 1 : 0.85).setStroke()
        outline.lineWidth = style == .locked ? 2 : 1.5

        // Dashed while the target is still a proposal, solid once it is chosen.
        if style != .locked {
            outline.setLineDash([5, 3], count: 2, phase: 0)
        }
        outline.stroke()
        NSGraphicsContext.current?.restoreGraphicsState()

        guard let label else { return }
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let labelSize = label.size(withAttributes: [.font: font])
        let width = min(labelSize.width + 18, bounds.width)
        let y = labelAbove ? min(highlightRect.maxY + 4, bounds.maxY - 22) : max(highlightRect.minY - 26, 0)
        let labelRect = CGRect(x: max(min(highlightRect.minX, bounds.maxX - width), 0), y: y, width: width, height: 22)
        let pill = NSBezierPath(roundedRect: labelRect, xRadius: 11, yRadius: 11)
        NSColor(calibratedWhite: 0.07, alpha: 0.92).setFill()
        pill.fill()
        accent.withAlphaComponent(0.24).setStroke()
        pill.lineWidth = 1
        pill.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(calibratedWhite: 0.96, alpha: 1)
        ]
        String(label.prefix(24)).draw(in: labelRect.insetBy(dx: 9, dy: 4), withAttributes: attributes)
    }
}
