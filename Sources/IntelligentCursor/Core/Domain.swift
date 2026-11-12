import AppKit
import CoreGraphics
import Foundation

enum InteractionPhase: String {
    case idle
    case armed
    case acquiring
    case prompting
    case invoking
    case responding
    case failed
}

struct AppIdentity: Equatable, Sendable {
    let processIdentifier: pid_t
    let name: String
    let bundleIdentifier: String?
}

enum TargetGesture: String, Sendable {
    case semanticPoint
    case selectedText
    case currentMoment
    case regionFallback
}

struct SemanticSnapshot: Sendable {
    let role: String?
    let subrole: String?
    let title: String?
    let value: String?
    let elementDescription: String?
    let selectedText: String?
    let hierarchyText: String?
    let url: URL?
    let documentURL: URL?
    let appKitFrame: CGRect?
    let recognitionLabel: String
    let confidence: Double

    /// A short human noun for the on-screen outline. Returns nil when the element
    /// is not confidently nameable, so the outline stays silent rather than
    /// narrating accessibility roles at the user.
    var humanName: String? {
        switch role {
        case AXRole.image: return "Image"
        case AXRole.link: return "Link"
        case AXRole.heading: return "Heading"
        case AXRole.button: return "Control"
        case AXRole.row, AXRole.cell: return "Item"
        case AXRole.textArea, AXRole.textField: return "Text"
        case AXRole.staticText:
            let length = bestText?.count ?? 0
            return length > 220 ? "Passage" : "Line"
        case AXRole.group:
            guard let length = bestText?.count, length > 40 else { return nil }
            return url != nil ? "Post" : "Block"
        default: return nil
        }
    }

    var bestText: String? {
        let candidates = [selectedText, hierarchyText, value, title, elementDescription]
        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }
}

/// What the user meant, independent of how they expressed it.
///
/// The gesture layer produces this and the context engine consumes it, so the
/// engine never learns about mice, clicks, or wheels. It also stops the engine
/// re-deriving intent from "wherever the pointer happened to be".
enum TargetSelection: Sendable, Equatable {
    /// A semantic element under a point. `level` is an offset from the element the
    /// resolver scores best: 0 is that element, positive widens toward its
    /// ancestors, negative narrows toward the exact element under the tip.
    case semantic(appKitPoint: CGPoint, level: Int)

    /// An explicit screen region, for when semantics cannot express the intent.
    case region(appKitRect: CGRect)

    var appKitPoint: CGPoint {
        switch self {
        case let .semantic(point, _): point
        case let .region(rect): CGPoint(x: rect.midX, y: rect.midY)
        }
    }
}

/// A resolved rung of the semantic ancestry, plus how far it can still travel.
struct SemanticResolution: Sendable {
    let snapshot: SemanticSnapshot
    let level: Int
    let minimumLevel: Int
    let maximumLevel: Int

    var canWiden: Bool { level < maximumLevel }
    var canNarrow: Bool { level > minimumLevel }
}

struct PointedTarget: Identifiable, Sendable {
    let id: UUID
    let gesture: TargetGesture
    let appKitPoint: CGPoint
    let displayPoint: CGPoint
    let sourceApplication: AppIdentity?
    let semantic: SemanticSnapshot?
    let capturedAt: Date
}

struct ContextProvenance: Sendable {
    let adapterID: String
    let capturedAt: Date
    let sourceBundleIdentifier: String?
    let confidence: Double
}

struct EncodedImage: Sendable {
    let data: Data
    let mimeType: String
    let pixelWidth: Int
    let pixelHeight: Int
    let displayRect: CGRect
}

struct TextExcerpt: Sendable {
    let kind: String
    let text: String
}

struct WebContext: Sendable {
    let url: URL
    let title: String?
    let visibleText: String?
}

struct FileContext: Sendable {
    let url: URL
    let name: String
    let contentType: String?
    let extractedText: String?
}

enum ContextPayload: Sendable {
    case image(EncodedImage)
    case text(TextExcerpt)
    case web(WebContext)
    case file(FileContext)
    case metadata([String: String])
}

struct ContextItem: Identifiable, Sendable {
    let id: UUID
    let payload: ContextPayload
    let provenance: ContextProvenance

    init(payload: ContextPayload, provenance: ContextProvenance) {
        self.id = UUID()
        self.payload = payload
        self.provenance = provenance
    }
}

struct ContextBundle: Sendable {
    let target: PointedTarget
    let items: [ContextItem]

    var image: EncodedImage? {
        for item in items {
            if case let .image(image) = item.payload {
                return image
            }
        }
        return nil
    }

    func untrustedText(maximumCharacters: Int = 24_000) -> String {
        var sections: [String] = []

        for item in items {
            switch item.payload {
            case let .text(excerpt):
                sections.append("[\(excerpt.kind)]\n\(excerpt.text)")
            case let .web(web):
                var value = "URL: \(web.url.absoluteString)"
                if let title = web.title, !title.isEmpty { value += "\nTitle: \(title)" }
                if let text = web.visibleText, !text.isEmpty { value += "\nVisible text:\n\(text)" }
                sections.append("[web]\n\(value)")
            case let .file(file):
                var value = "File: \(file.name)\nURL: \(file.url.path)"
                if let type = file.contentType { value += "\nType: \(type)" }
                if let text = file.extractedText, !text.isEmpty { value += "\nExtracted content:\n\(text)" }
                sections.append("[file]\n\(value)")
            case let .metadata(metadata):
                let value = metadata.keys.sorted().map { "\($0): \(metadata[$0] ?? "")" }.joined(separator: "\n")
                sections.append("[metadata]\n\(value)")
            case .image:
                continue
            }
        }

        let joined = sections.joined(separator: "\n\n")
        return String(joined.prefix(maximumCharacters))
    }
}

enum ProviderID: String, Sendable {
    case openAI
    case anthropic
    case xAI
    case council
}

/// How hard the chosen intelligence should think. Speed against depth is a real
/// daily trade-off at the cursor, so it is part of the model configuration rather
/// than a fixed property of a profile.
///
/// Each provider spells this differently; the translation table lives here so the
/// three vocabularies can be compared in one place.
enum ReasoningEffort: String, CaseIterable, Identifiable, Sendable {
    case fast
    case balanced
    case max

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fast: "Fast"
        case .balanced: "Balanced"
        case .max: "Max"
        }
    }

    var openAIValue: String {
        switch self {
        case .fast: "low"
        case .balanced: "medium"
        case .max: "max"
        }
    }

    var anthropicValue: String {
        switch self {
        case .fast: "low"
        case .balanced: "medium"
        case .max: "max"
        }
    }

    var xAIValue: String {
        switch self {
        case .fast: "low"
        case .balanced: "high"
        case .max: "xhigh"
        }
    }
}

enum ModelProfileID: String, CaseIterable, Identifiable, Sendable {
    case gpt56SolMax
    case opus5Max
    case grok46Heavy
    case allThree

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gpt56SolMax: "GPT-5.6 Sol"
        case .opus5Max: "Opus 5"
        case .grok46Heavy: "Grok 4.6"
        case .allThree: "All 3"
        }
    }

    func displayName(effort: ReasoningEffort) -> String {
        self == .allThree ? "All 3 · \(effort.displayName)" : "\(displayName) · \(effort.displayName)"
    }

    var shortName: String {
        switch self {
        case .gpt56SolMax: "GPT"
        case .opus5Max: "Claude"
        case .grok46Heavy: "Grok"
        case .allThree: "All 3"
        }
    }

    var providerID: ProviderID {
        switch self {
        case .gpt56SolMax: .openAI
        case .opus5Max: .anthropic
        case .grok46Heavy: .xAI
        case .allThree: .council
        }
    }

    var systemImage: String {
        switch self {
        case .gpt56SolMax: "sparkles"
        case .opus5Max: "sun.max"
        case .grok46Heavy: "scope"
        case .allThree: "circle.hexagongrid"
        }
    }
}

struct ConversationTurn: Sendable {
    let profile: ModelProfileID
    let prompt: String
    let response: String
}

struct IntelligenceRequest: Sendable {
    let profile: ModelProfileID
    let effort: ReasoningEffort
    let prompt: String
    let context: ContextBundle
    let history: [ConversationTurn]
}

enum IntelligentCursorError: LocalizedError {
    case permissionRequired(String)
    case noContext
    case missingCredential(String)
    case unsupported(String)
    case captureFailed(String)
    case provider(String)

    var errorDescription: String? {
        switch self {
        case let .permissionRequired(message),
             let .missingCredential(message),
             let .unsupported(message),
             let .captureFailed(message),
             let .provider(message):
            message
        case .noContext:
            "I couldn’t understand what is under the cursor. Try pointing more precisely."
        }
    }
}

