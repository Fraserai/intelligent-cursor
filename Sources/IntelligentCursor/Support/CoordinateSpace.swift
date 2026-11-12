import AppKit
import CoreGraphics

enum ScreenCoordinateSpace {
    static var primaryScreenTop: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    static func appKitToDisplay(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenTop - point.y)
    }

    static func displayToAppKit(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenTop - point.y)
    }

    static func appKitToDisplay(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenTop - rect.maxY, width: rect.width, height: rect.height)
    }

    static func displayToAppKit(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenTop - rect.maxY, width: rect.width, height: rect.height)
    }

    static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
    }

    static func automaticCaptureRect(
        around point: CGPoint,
        semanticFrame: CGRect?,
        screen: NSScreen? = nil
    ) -> CGRect {
        let targetScreen = screen ?? self.screen(containing: point)
        let screenFrame = targetScreen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let maximum = CGSize(width: min(1_280, screenFrame.width - 24), height: min(900, screenFrame.height - 24))
        let minimum = CGSize(width: 240, height: 160)

        var rect: CGRect
        if let semanticFrame,
           semanticFrame.width >= 24,
           semanticFrame.height >= 18,
           semanticFrame.width <= screenFrame.width * 0.92,
           semanticFrame.height <= screenFrame.height * 0.92 {
            rect = semanticFrame.insetBy(dx: -12, dy: -12)
        } else {
            rect = CGRect(
                x: point.x - 320,
                y: point.y - 210,
                width: 640,
                height: 420
            )
        }

        if rect.width < minimum.width {
            rect = rect.insetBy(dx: -(minimum.width - rect.width) / 2, dy: 0)
        }
        if rect.height < minimum.height {
            rect = rect.insetBy(dx: 0, dy: -(minimum.height - rect.height) / 2)
        }
        if rect.width > maximum.width {
            rect = CGRect(x: rect.midX - maximum.width / 2, y: rect.minY, width: maximum.width, height: rect.height)
        }
        if rect.height > maximum.height {
            rect = CGRect(x: rect.minX, y: rect.midY - maximum.height / 2, width: rect.width, height: maximum.height)
        }

        return rect.clamped(to: screenFrame.insetBy(dx: 8, dy: 8))
    }
}

extension CGRect {
    func clamped(to bounds: CGRect) -> CGRect {
        var result = self
        if result.width > bounds.width { result.size.width = bounds.width }
        if result.height > bounds.height { result.size.height = bounds.height }
        result.origin.x = min(max(result.origin.x, bounds.minX), bounds.maxX - result.width)
        result.origin.y = min(max(result.origin.y, bounds.minY), bounds.maxY - result.height)
        return result
    }
}
