import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

struct CapturedVisual {
    let image: CGImage
    let encoded: EncodedImage
}

protocol ScreenCapturing {
    func capture(appKitRect: CGRect) async throws -> CapturedVisual
}

struct ScreenCaptureAdapter: ScreenCapturing {
    private let maximumPixelDimension = 1_800

    func capture(appKitRect: CGRect) async throws -> CapturedVisual {
        guard CGPreflightScreenCaptureAccess() else {
            throw IntelligentCursorError.permissionRequired(
                "Screen Recording is off. Semantic context still works; enable Screen Recording to understand images, charts, and inaccessible content."
            )
        }

        let displayRect = ScreenCoordinateSpace.appKitToDisplay(appKitRect.integral)
        let captured: CGImage = try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(in: displayRect) { image, error in
                if let error {
                    continuation.resume(throwing: IntelligentCursorError.captureFailed(error.localizedDescription))
                } else if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: IntelligentCursorError.captureFailed("macOS returned no image for this item."))
                }
            }
        }

        let image = downscaledIfNeeded(captured)
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw IntelligentCursorError.captureFailed("The captured image could not be encoded.")
        }

        return CapturedVisual(
            image: image,
            encoded: EncodedImage(
                data: data,
                mimeType: "image/png",
                pixelWidth: image.width,
                pixelHeight: image.height,
                displayRect: displayRect
            )
        )
    }

    private func downscaledIfNeeded(_ image: CGImage) -> CGImage {
        let maximum = max(image.width, image.height)
        guard maximum > maximumPixelDimension else { return image }

        let scale = CGFloat(maximumPixelDimension) / CGFloat(maximum)
        let width = max(Int(CGFloat(image.width) * scale), 1)
        let height = max(Int(CGFloat(image.height) * scale), 1)
        guard let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return image
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }
}

