import CoreGraphics
import Foundation
import Vision

struct OCRAdapter {
    func recognizeText(in image: CGImage) async -> String? {
        await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.minimumTextHeight = 0.008

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return nil
            }

            let observations = (request.results ?? []).sorted { left, right in
                let lineDelta = abs(left.boundingBox.midY - right.boundingBox.midY)
                if lineDelta > 0.02 { return left.boundingBox.midY > right.boundingBox.midY }
                return left.boundingBox.minX < right.boundingBox.minX
            }
            let lines = observations.compactMap { $0.topCandidates(1).first?.string }
            let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : String(text.prefix(12_000))
        }.value
    }
}

