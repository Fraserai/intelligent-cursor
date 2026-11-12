import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

protocol ContextAcquiring {
    func preview(at appKitPoint: CGPoint, sourceApplication: AppIdentity?, level: Int) async -> SemanticResolution?
    func acquire(
        sessionID: UUID,
        selection: TargetSelection,
        sourceApplication: AppIdentity?
    ) async throws -> ContextBundle
}

final class ContextAcquisitionEngine: ContextAcquiring {
    /// Above this much accessibility text, reading the same pixels back mostly
    /// reproduces what is already known.
    ///
    /// Measured over a day of real use, recognition costs 164–750ms against
    /// 63–85ms for the capture itself, so it is the expensive half of visual
    /// context by an order of magnitude.
    ///
    /// The threshold sits in the gap that same data left: every case where
    /// recognition added several times more text than the accessibility tree had
    /// 338 characters or fewer of it, and every case where it returned a subset or
    /// a near-duplicate had 574 or more. The image is still captured either way,
    /// so charts, photographs, and video frames are unaffected.
    private let semanticTextSupersedingRecognition = 500

    private let semanticResolver: SemanticTargetResolving
    private let screenCapture: ScreenCapturing
    private let ocr: OCRAdapter
    private let fileExtractor: FileContextExtractor

    init(
        semanticResolver: SemanticTargetResolving = AccessibilitySemanticResolver(),
        screenCapture: ScreenCapturing = ScreenCaptureAdapter(),
        ocr: OCRAdapter = OCRAdapter(),
        fileExtractor: FileContextExtractor = FileContextExtractor()
    ) {
        self.semanticResolver = semanticResolver
        self.screenCapture = screenCapture
        self.ocr = ocr
        self.fileExtractor = fileExtractor
    }

    func preview(at appKitPoint: CGPoint, sourceApplication: AppIdentity?, level: Int) async -> SemanticResolution? {
        await semanticResolver.preview(at: appKitPoint, sourceApplication: sourceApplication, level: level)
    }

    func acquire(
        sessionID: UUID,
        selection: TargetSelection,
        sourceApplication: AppIdentity?
    ) async throws -> ContextBundle {
        switch selection {
        case let .semantic(appKitPoint, level):
            return try await acquireSemantic(
                sessionID: sessionID,
                at: appKitPoint,
                level: level,
                sourceApplication: sourceApplication
            )
        case let .region(appKitRect):
            return try await acquireRegion(
                sessionID: sessionID,
                appKitRect: appKitRect,
                sourceApplication: sourceApplication
            )
        }
    }

    private func acquireSemantic(
        sessionID: UUID,
        at appKitPoint: CGPoint,
        level: Int,
        sourceApplication: AppIdentity?
    ) async throws -> ContextBundle {
        let displayPoint = ScreenCoordinateSpace.appKitToDisplay(appKitPoint)
        let resolution = await semanticResolver.resolve(
            at: appKitPoint,
            sourceApplication: sourceApplication,
            level: level
        )
        let semantic = resolution?.snapshot
        let target = PointedTarget(
            id: sessionID,
            gesture: .semanticPoint,
            appKitPoint: appKitPoint,
            displayPoint: displayPoint,
            sourceApplication: sourceApplication,
            semantic: semantic,
            capturedAt: Date()
        )

        var items: [ContextItem] = []
        let now = Date()
        let bundleID = sourceApplication?.bundleIdentifier

        var metadata: [String: String] = [
            "target_gesture": TargetGesture.semanticPoint.rawValue,
            "context_priority": "semantic-first"
        ]
        if let app = sourceApplication?.name { metadata["source_app"] = app }
        if let bundleID { metadata["source_bundle_id"] = bundleID }
        if let role = semantic?.role { metadata["accessibility_role"] = role }
        if let label = semantic?.recognitionLabel { metadata["recognized_as"] = label }
        items.append(ContextItem(
            payload: .metadata(metadata),
            provenance: provenance("frontmost-app", at: now, bundleID: bundleID, confidence: 1)
        ))

        if let semanticText = semantic?.bestText, !semanticText.isEmpty {
            items.append(ContextItem(
                payload: .text(TextExcerpt(kind: semantic?.selectedText?.isEmpty == false ? "selected text" : "semantic element", text: semanticText)),
                provenance: provenance("macos-accessibility", at: now, bundleID: bundleID, confidence: semantic?.confidence ?? 0.6)
            ))
        }

        if let url = semantic?.url ?? semantic?.documentURL, !url.isFileURL {
            items.append(ContextItem(
                payload: .web(WebContext(url: url, title: semantic?.title, visibleText: semantic?.bestText)),
                provenance: provenance("accessibility-url", at: now, bundleID: bundleID, confidence: semantic?.confidence ?? 0.65)
            ))
        }

        if let file = await fileExtractor.extract(from: semantic) {
            items.append(ContextItem(
                payload: .file(file),
                provenance: provenance("pointed-file", at: now, bundleID: bundleID, confidence: 0.94)
            ))
        }

        if shouldAcquireVisualFallback(semantic: semantic, existingItems: items),
           CGPreflightScreenCaptureAccess() {
            let appKitRect = ScreenCoordinateSpace.automaticCaptureRect(
                around: appKitPoint,
                semanticFrame: semantic?.appKitFrame
            )
            do {
                try await appendVisualContext(
                    to: &items,
                    appKitRect: appKitRect,
                    at: now,
                    bundleID: bundleID,
                    imageConfidence: semantic == nil ? 0.72 : 0.82,
                    duplicateOf: semantic?.bestText
                )
            } catch {
                if semantic?.bestText == nil && items.count <= 1 { throw error }
            }
        }

        return try validated(ContextBundle(target: target, items: items))
    }

    /// The manual override. Semantics are skipped entirely because the user has
    /// already said, by drawing, that no element expressed what they meant.
    private func acquireRegion(
        sessionID: UUID,
        appKitRect: CGRect,
        sourceApplication: AppIdentity?
    ) async throws -> ContextBundle {
        guard CGPreflightScreenCaptureAccess() else {
            throw IntelligentCursorError.permissionRequired(
                "Drawing a region captures pixels, so it needs Screen Recording. Semantic pointing still works without it."
            )
        }

        let anchor = CGPoint(x: appKitRect.midX, y: appKitRect.midY)
        let target = PointedTarget(
            id: sessionID,
            gesture: .regionFallback,
            appKitPoint: anchor,
            displayPoint: ScreenCoordinateSpace.appKitToDisplay(anchor),
            sourceApplication: sourceApplication,
            semantic: nil,
            capturedAt: Date()
        )

        let now = Date()
        let bundleID = sourceApplication?.bundleIdentifier
        var metadata: [String: String] = [
            "target_gesture": TargetGesture.regionFallback.rawValue,
            "context_priority": "user-drawn-region"
        ]
        if let app = sourceApplication?.name { metadata["source_app"] = app }
        if let bundleID { metadata["source_bundle_id"] = bundleID }

        var items: [ContextItem] = [ContextItem(
            payload: .metadata(metadata),
            provenance: provenance("frontmost-app", at: now, bundleID: bundleID, confidence: 1)
        )]

        try await appendVisualContext(
            to: &items,
            appKitRect: appKitRect,
            at: now,
            bundleID: bundleID,
            imageConfidence: 0.95,
            duplicateOf: nil
        )

        return try validated(ContextBundle(target: target, items: items))
    }

    private func appendVisualContext(
        to items: inout [ContextItem],
        appKitRect: CGRect,
        at date: Date,
        bundleID: String?,
        imageConfidence: Double,
        duplicateOf existingText: String?
    ) async throws {
        let captureStarted = Date()
        let visual = try await screenCapture.capture(appKitRect: appKitRect)
        let captureMilliseconds = Int(Date().timeIntervalSince(captureStarted) * 1000)
        items.append(ContextItem(
            payload: .image(visual.encoded),
            provenance: provenance("automatic-visual-fallback", at: date, bundleID: bundleID, confidence: imageConfidence)
        ))

        guard (existingText?.count ?? 0) < semanticTextSupersedingRecognition else {
            Diagnostics.context.debug(
                "visual cost capture=\(captureMilliseconds, privacy: .public)ms ocr=skipped (semantic text already covers it)"
            )
            return
        }

        let recognitionStarted = Date()
        let recognized = await ocr.recognizeText(in: visual.image)
        Diagnostics.context.debug(
            """
            visual cost capture=\(captureMilliseconds, privacy: .public)ms \
            ocr=\(Int(Date().timeIntervalSince(recognitionStarted) * 1000), privacy: .public)ms \
            pixels=\(visual.encoded.pixelWidth * visual.encoded.pixelHeight, privacy: .public)
            """
        )
        if let text = recognized, !text.isEmpty, text != existingText {
            items.append(ContextItem(
                payload: .text(TextExcerpt(kind: "visual OCR fallback", text: text)),
                provenance: provenance("vision-ocr", at: date, bundleID: bundleID, confidence: 0.68)
            ))
        }
    }

    private func validated(_ bundle: ContextBundle) throws -> ContextBundle {
        let hasMeaningfulContext = bundle.items.contains { item in
            switch item.payload {
            case .metadata: false
            default: true
            }
        }
        guard hasMeaningfulContext else {
            if !CGPreflightScreenCaptureAccess() {
                throw IntelligentCursorError.permissionRequired(
                    "I couldn’t read this item semantically. Enable Screen Recording so I can fall back to what it looks like, or scroll to widen the target."
                )
            }
            throw IntelligentCursorError.noContext
        }
        return bundle
    }

    private func shouldAcquireVisualFallback(semantic: SemanticSnapshot?, existingItems: [ContextItem]) -> Bool {
        guard let semantic else { return true }
        let textLength = semantic.bestText?.count ?? 0
        let hasExtractedFile = existingItems.contains { if case .file = $0.payload { true } else { false } }
        if hasExtractedFile && textLength > 80 { return false }

        switch semantic.role {
        case AXRole.image,
             AXRole.group,
             AXRole.scrollArea:
            return true
        case AXRole.staticText,
             AXRole.textArea,
             AXRole.textField,
             AXRole.link:
            return textLength < 80 || semantic.confidence < 0.55
        default:
            return textLength < 160 || semantic.confidence < 0.66
        }
    }

    private func provenance(
        _ adapterID: String,
        at date: Date,
        bundleID: String?,
        confidence: Double
    ) -> ContextProvenance {
        ContextProvenance(
            adapterID: adapterID,
            capturedAt: date,
            sourceBundleIdentifier: bundleID,
            confidence: confidence
        )
    }
}

enum FrontmostApplicationProvider {
    static func snapshot() -> AppIdentity? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return AppIdentity(
            processIdentifier: app.processIdentifier,
            name: app.localizedName ?? "Unknown app",
            bundleIdentifier: app.bundleIdentifier
        )
    }
}
