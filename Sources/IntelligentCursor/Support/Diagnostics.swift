import Foundation
import os

/// Diagnostics for a background app that has no window to inspect.
///
/// The interaction is meant to be invisible, so the only way to see what the
/// cursor understood is the log. Watch a live session with:
///
///     log stream --predicate 'subsystem == "com.caeseyfraser.intelligent-cursor"' --level debug
///
/// Captured screen content is untrusted and often private, so nothing here logs
/// context text, prompts, answers, URLs, or credentials — only shapes, roles,
/// counts, and outcomes.
enum Diagnostics {
    static let subsystem = "com.caeseyfraser.intelligent-cursor"

    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    static let trigger = Logger(subsystem: subsystem, category: "trigger")
    static let context = Logger(subsystem: subsystem, category: "context")
    static let intelligence = Logger(subsystem: subsystem, category: "intelligence")
}

extension ContextBundle {
    /// A privacy-safe description of what was captured: kinds and sizes only.
    var diagnosticSummary: String {
        let parts = items.map { item -> String in
            switch item.payload {
            case let .image(image):
                return "image(\(image.pixelWidth)x\(image.pixelHeight))"
            case let .text(excerpt):
                return "text[\(excerpt.kind)](\(excerpt.text.count)ch)"
            case let .web(web):
                return "web(\(web.url.host() ?? "?"))"
            case let .file(file):
                return "file(.\(file.url.pathExtension), \(file.extractedText?.count ?? 0)ch)"
            case let .metadata(metadata):
                return "metadata(\(metadata.count) keys)"
            }
        }
        return parts.joined(separator: ", ")
    }
}
