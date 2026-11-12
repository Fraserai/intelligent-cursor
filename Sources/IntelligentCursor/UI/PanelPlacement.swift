import CoreGraphics

enum PanelMetrics {
    static let controllerSize = CGSize(width: 296, height: 44)
    static let promptSize = CGSize(width: 318, height: 357)
    static let responseSize = CGSize(width: 390, height: 462)

    static func size(hasResponse: Bool) -> CGSize {
        hasResponse ? responseSize : promptSize
    }
}

enum PanelPlacement {
    /// While aiming, the controller must never sit on top of the thing being
    /// inspected, so it is pinned out of the way rather than near the pointer.
    static func controllerOrigin(
        size: CGSize,
        visibleFrame: CGRect,
        margin: CGFloat = 16
    ) -> CGPoint {
        CGPoint(
            x: visibleFrame.maxX - size.width - margin,
            y: visibleFrame.maxY - size.height - margin
        )
    }

    static func origin(
        panelSize: CGSize,
        targetRect: CGRect,
        anchor: CGPoint,
        visibleFrame: CGRect,
        gap: CGFloat = 12,
        margin: CGFloat = 16
    ) -> CGPoint {
        let safe = visibleFrame.insetBy(dx: margin, dy: margin)
        let candidates = [
            CGPoint(x: targetRect.maxX + gap, y: targetRect.midY - panelSize.height / 2),
            CGPoint(x: targetRect.midX - panelSize.width / 2, y: targetRect.minY - gap - panelSize.height),
            CGPoint(x: targetRect.minX - gap - panelSize.width, y: targetRect.midY - panelSize.height / 2),
            CGPoint(x: targetRect.midX - panelSize.width / 2, y: targetRect.maxY + gap)
        ]

        for candidate in candidates {
            let frame = CGRect(origin: candidate, size: panelSize)
            if safe.contains(frame) { return candidate }
        }

        let fallback = CGPoint(x: anchor.x + 18, y: anchor.y - panelSize.height - 18)
        return CGRect(origin: fallback, size: panelSize).clamped(to: safe).origin
    }
}

