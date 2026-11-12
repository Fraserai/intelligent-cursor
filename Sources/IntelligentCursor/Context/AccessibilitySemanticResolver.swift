import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

protocol SemanticTargetResolving {
    func preview(at appKitPoint: CGPoint, sourceApplication: AppIdentity?, level: Int) async -> SemanticResolution?
    func resolve(at appKitPoint: CGPoint, sourceApplication: AppIdentity?, level: Int) async -> SemanticResolution?
}

final class AccessibilitySemanticResolver: SemanticTargetResolving, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.caeseyfraser.intelligent-cursor.accessibility", qos: .userInitiated)

    /// Applications already asked to publish a full accessibility tree. Only
    /// touched from `queue`.
    private var treeRequested: Set<pid_t> = []

    func preview(at appKitPoint: CGPoint, sourceApplication: AppIdentity?, level: Int) async -> SemanticResolution? {
        await perform(at: appKitPoint, sourceApplication: sourceApplication, level: level, fullExtraction: false)
    }

    func resolve(at appKitPoint: CGPoint, sourceApplication: AppIdentity?, level: Int) async -> SemanticResolution? {
        await perform(at: appKitPoint, sourceApplication: sourceApplication, level: level, fullExtraction: true)
    }

    private func perform(
        at appKitPoint: CGPoint,
        sourceApplication: AppIdentity?,
        level: Int,
        fullExtraction: Bool
    ) async -> SemanticResolution? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: snapshot(
                    at: appKitPoint,
                    sourceApplication: sourceApplication,
                    level: level,
                    fullExtraction: fullExtraction
                ))
            }
        }
    }

    private func snapshot(
        at appKitPoint: CGPoint,
        sourceApplication: AppIdentity?,
        level: Int,
        fullExtraction: Bool
    ) -> SemanticResolution? {
        guard AXIsProcessTrusted() else { return nil }

        let root: AXUIElement
        if let sourceApplication {
            root = AXUIElementCreateApplication(sourceApplication.processIdentifier)
            AXUIElementSetMessagingTimeout(root, fullExtraction ? 0.22 : 0.08)
        } else {
            root = AXUIElementCreateSystemWide()
        }

        let displayPoint = ScreenCoordinateSpace.appKitToDisplay(appKitPoint)
        var hitElement: AXUIElement?
        let hitError = AXUIElementCopyElementAtPosition(
            root,
            Float(displayPoint.x),
            Float(displayPoint.y),
            &hitElement
        )
        guard hitError == .success, let hitElement else { return nil }

        let candidates = ancestorCandidates(startingAt: hitElement, maximumDepth: 10)
        guard !candidates.isEmpty else { return nil }

        let nodeBudget = fullExtraction ? 180 : 42
        let depthBudget = fullExtraction ? 3 : 1
        let scored = candidates.map {
            candidate(from: $0, point: appKitPoint, nodeBudget: nodeBudget, depthBudget: depthBudget)
        }
        guard let automaticIndex = scored.indices.max(by: { scored[$0].score < scored[$1].score }) else {
            return nil
        }

        // `level` is an offset from the automatic choice, so doing nothing yields
        // exactly the element that scored best and scrolling walks outward from
        // there. The ancestry runs narrow to wide, so widening moves up the array.
        let index = min(max(automaticIndex + level, 0), scored.count - 1)
        let best = scored[index]
        let resolvedLevel = index - automaticIndex

        if fullExtraction {
            let hitRole = stringAttribute(kAXRoleAttribute as CFString, from: hitElement) ?? "nil"
            let ladder = scored.enumerated()
                .map { "\($0.offset == index ? "*" : "")\($0.element.role ?? "nil"):\(Int($0.element.score))" }
                .joined(separator: " < ")
            Diagnostics.context.debug(
                "hit=\(hitRole, privacy: .public) level=\(resolvedLevel, privacy: .public) ancestry \(ladder, privacy: .public)"
            )
        }

        // Score accumulates positive evidence — text, URLs, informative roles —
        // and subtracts structural penalties. A non-positive score means nothing
        // semantic was found and the only candidates were containers such as the
        // application, a window, or the menu bar. Reporting that as a target sends
        // confident nonsense to the model, so decline and let the visual adapter
        // handle it. A level the user chose deliberately is always honoured: an
        // explicit intent outranks the scoring heuristic.
        guard best.score > 0 || resolvedLevel != 0 else {
            Diagnostics.context.debug(
                "declining structural-only target \(best.role ?? "nil", privacy: .public):\(Int(best.score), privacy: .public)"
            )
            if let pid = sourceApplication?.processIdentifier {
                requestFullAccessibilityTree(for: root, pid: pid)
            }
            return nil
        }

        let focusedSelectedText: String? = {
            guard fullExtraction,
                  let focused = elementAttribute(kAXFocusedUIElementAttribute as CFString, from: root) else {
                return nil
            }
            return stringAttribute(kAXSelectedTextAttribute as CFString, from: focused)
        }()

        let selectedText = best.selectedText ?? focusedSelectedText
        let url = best.url ?? best.documentURL
        let label = recognitionLabel(role: best.role, url: url, sourceApplication: sourceApplication)

        let snapshot = SemanticSnapshot(
            role: best.role,
            subrole: best.subrole,
            title: best.title,
            value: best.value,
            elementDescription: best.elementDescription,
            selectedText: selectedText,
            hierarchyText: best.hierarchyText,
            url: best.url,
            documentURL: best.documentURL,
            appKitFrame: best.frame,
            recognitionLabel: label,
            confidence: min(max(best.score / 100, 0.15), 0.98)
        )

        return SemanticResolution(
            snapshot: snapshot,
            level: resolvedLevel,
            minimumLevel: -automaticIndex,
            maximumLevel: scored.count - 1 - automaticIndex
        )
    }

    /// Chromium and Electron applications do not build a web-content accessibility
    /// tree until a client asks for one. Until then, hit testing anywhere inside
    /// Chrome, VS Code, Slack, or an Electron coding agent resolves to the window
    /// chrome or the menu bar rather than the thing on screen, which is how
    /// pointing at a post returns an unrelated bookmark.
    ///
    /// Asked for only after a resolution actually comes back structural, so
    /// well-behaved applications are never touched. Chromium reports an error for
    /// both attributes even when it honours them, so the result codes are logged
    /// but not trusted; the tree then takes roughly a second to populate and the
    /// next sample picks it up.
    private func requestFullAccessibilityTree(for application: AXUIElement, pid: pid_t) {
        guard !treeRequested.contains(pid) else { return }
        treeRequested.insert(pid)
        let manual = AXUIElementSetAttributeValue(
            application, "AXManualAccessibility" as CFString, kCFBooleanTrue
        )
        let enhanced = AXUIElementSetAttributeValue(
            application, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue
        )
        Diagnostics.context.debug(
            """
            requested full accessibility tree from pid \(pid, privacy: .public): \
            manual=\(manual == .success, privacy: .public) enhanced=\(enhanced == .success, privacy: .public)
            """
        )
    }

    private func ancestorCandidates(startingAt element: AXUIElement, maximumDepth: Int) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var cursor: AXUIElement? = element

        for _ in 0..<maximumDepth {
            guard let current = cursor else { break }
            result.append(current)
            cursor = elementAttribute(kAXParentAttribute as CFString, from: current)
        }
        return result
    }

    private struct Candidate {
        let role: String?
        let subrole: String?
        let title: String?
        let value: String?
        let elementDescription: String?
        let selectedText: String?
        let hierarchyText: String?
        let url: URL?
        let documentURL: URL?
        let frame: CGRect?
        let score: Double
    }

    private func candidate(
        from element: AXUIElement,
        point: CGPoint,
        nodeBudget: Int,
        depthBudget: Int
    ) -> Candidate {
        let role = stringAttribute(kAXRoleAttribute as CFString, from: element)
        let subrole = stringAttribute(kAXSubroleAttribute as CFString, from: element)
        let title = stringAttribute(kAXTitleAttribute as CFString, from: element)
        let value = stringValueAttribute(kAXValueAttribute as CFString, from: element)
        let elementDescription = stringAttribute(kAXDescriptionAttribute as CFString, from: element)
            ?? stringAttribute(kAXHelpAttribute as CFString, from: element)
        let selectedText = stringAttribute(kAXSelectedTextAttribute as CFString, from: element)
        let url = urlAttribute(kAXURLAttribute as CFString, from: element)
            ?? urlAttribute(kAXFilenameAttribute as CFString, from: element)
        let documentURL = urlAttribute(kAXDocumentAttribute as CFString, from: element)
        let frame = frameAttribute(from: element)

        var visited = 0
        var collected: [String] = []
        collectText(
            from: element,
            depth: 0,
            maximumDepth: depthBudget,
            maximumNodes: nodeBudget,
            visited: &visited,
            collected: &collected
        )
        let hierarchyText = deduplicatedText(collected)

        var score = 0.0
        let directTextLength = [selectedText, value, title, elementDescription]
            .compactMap { $0?.count }
            .reduce(0, +)
        let hierarchyLength = hierarchyText?.count ?? 0

        if selectedText?.isEmpty == false { score += 65 }
        if url != nil || documentURL != nil { score += 28 }
        if directTextLength > 0 { score += min(Double(directTextLength) / 8, 32) }
        if hierarchyLength > directTextLength { score += min(Double(hierarchyLength) / 28, 34) }

        switch role {
        case AXRole.staticText: score += 18
        case AXRole.link: score += 22
        case AXRole.image: score += 17
        case AXRole.textArea, AXRole.textField: score += 16
        case AXRole.row, AXRole.cell: score += 12
        case AXRole.group: score += hierarchyLength > 24 ? 14 : 2
        case AXRole.button: score += 5
        case AXRole.application, AXRole.window, AXRole.scrollArea, AXRole.menuBar:
            score -= 45
        default: break
        }

        if let frame {
            let screen = ScreenCoordinateSpace.screen(containing: point)
            let screenArea = max((screen?.frame.width ?? 1) * (screen?.frame.height ?? 1), 1)
            let ratio = (frame.width * frame.height) / screenArea
            if !frame.contains(point) { score -= 30 }
            if ratio > 0.72 { score -= 48 }
            else if ratio > 0.38 { score -= 18 }
            if frame.width < 14 || frame.height < 12 { score -= 18 }
        } else {
            score -= 12
        }

        return Candidate(
            role: role,
            subrole: subrole,
            title: title,
            value: value,
            elementDescription: elementDescription,
            selectedText: selectedText,
            hierarchyText: hierarchyText,
            url: url,
            documentURL: documentURL,
            frame: frame,
            score: score
        )
    }

    private func collectText(
        from element: AXUIElement,
        depth: Int,
        maximumDepth: Int,
        maximumNodes: Int,
        visited: inout Int,
        collected: inout [String]
    ) {
        guard visited < maximumNodes else { return }
        visited += 1

        let strings = [
            stringAttribute(kAXTitleAttribute as CFString, from: element),
            stringValueAttribute(kAXValueAttribute as CFString, from: element),
            stringAttribute(kAXDescriptionAttribute as CFString, from: element),
            stringAttribute(kAXSelectedTextAttribute as CFString, from: element)
        ]
        for value in strings.compactMap({ $0 }) where !value.isEmpty && value.count <= 12_000 {
            collected.append(value)
        }

        guard depth < maximumDepth else { return }
        for child in elementArrayAttribute(kAXChildrenAttribute as CFString, from: element) {
            collectText(
                from: child,
                depth: depth + 1,
                maximumDepth: maximumDepth,
                maximumNodes: maximumNodes,
                visited: &visited,
                collected: &collected
            )
            if visited >= maximumNodes { break }
        }
    }

    private func deduplicatedText(_ values: [String]) -> String? {
        var seen = Set<String>()
        var result: [String] = []
        var length = 0

        for raw in values {
            let value = raw
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.count > 1, !seen.contains(value) else { continue }
            seen.insert(value)
            let remaining = 12_000 - length
            guard remaining > 0 else { break }
            result.append(String(value.prefix(remaining)))
            length += min(value.count, remaining) + 1
        }
        let joined = result.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    private func stringAttribute(_ name: CFString, from element: AXUIElement) -> String? {
        guard let value = rawAttribute(name, from: element) else { return nil }
        if let string = value as? String { return string }
        if let url = value as? URL { return url.absoluteString }
        return nil
    }

    private func stringValueAttribute(_ name: CFString, from element: AXUIElement) -> String? {
        guard let value = rawAttribute(name, from: element) else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private func urlAttribute(_ name: CFString, from element: AXUIElement) -> URL? {
        guard let value = rawAttribute(name, from: element) else { return nil }
        if let url = value as? URL { return url }
        if let url = value as? NSURL { return url as URL }
        if let string = value as? String {
            if let url = URL(string: string), url.scheme != nil { return url }
            if string.hasPrefix("/") { return URL(fileURLWithPath: string) }
        }
        return nil
    }

    private func frameAttribute(from element: AXUIElement) -> CGRect? {
        guard let positionValue = rawAttribute(kAXPositionAttribute as CFString, from: element),
              let sizeValue = rawAttribute(kAXSizeAttribute as CFString, from: element),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        let positionAX = unsafeBitCast(positionValue, to: AXValue.self)
        let sizeAX = unsafeBitCast(sizeValue, to: AXValue.self)
        guard AXValueGetValue(positionAX, .cgPoint, &position),
              AXValueGetValue(sizeAX, .cgSize, &size) else {
            return nil
        }
        return ScreenCoordinateSpace.displayToAppKit(CGRect(origin: position, size: size))
    }

    private func elementAttribute(_ name: CFString, from element: AXUIElement) -> AXUIElement? {
        guard let value = rawAttribute(name, from: element),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func elementArrayAttribute(_ name: CFString, from element: AXUIElement) -> [AXUIElement] {
        guard let value = rawAttribute(name, from: element), let array = value as? [Any] else { return [] }
        return array.compactMap { item in
            let value = item as CFTypeRef
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(value, to: AXUIElement.self)
        }
    }

    private func rawAttribute(_ name: CFString, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
    }

    private func recognitionLabel(role: String?, url: URL?, sourceApplication: AppIdentity?) -> String {
        if url?.isFileURL == true { return "File" }
        let roleLabel: String
        switch role {
        case AXRole.staticText: roleLabel = "Text"
        case AXRole.link: roleLabel = "Link"
        case AXRole.image: roleLabel = "Image"
        case AXRole.button: roleLabel = "Control"
        case AXRole.textArea, AXRole.textField: roleLabel = "Text"
        case AXRole.row, AXRole.cell: roleLabel = "Item"
        case AXRole.group: roleLabel = "Content"
        default: roleLabel = "Item"
        }

        if let appName = sourceApplication?.name, !appName.isEmpty {
            return "\(roleLabel) · \(appName)"
        }
        return roleLabel
    }
}

