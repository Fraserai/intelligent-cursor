import Foundation

/// Decides whether a question needs the live web, before the model is asked.
///
/// The tool is gated deliberately rather than always attached. Measured against
/// `gpt-5.6-sol`, a model holding a web search tool will reach for it even on an
/// ordinary question like "why would NVIDIA buy Hugging Face now?", which turns
/// every cursor question into a slow one. A system instruction is not enough to
/// stop that, so availability is the control.
///
/// This is deliberately blunt and readable: it matches the way the user actually
/// asks for verification. When it says no, the model cannot search and is told to
/// say so rather than invent current facts.
enum ResearchIntent {
    /// Phrases that only make sense if the answer must come from outside the
    /// captured context.
    private static let signals = [
        "verify", "verified", "verification", "fact check", "fact-check", "factcheck",
        "is this true", "is that true", "is this real", "is this legit", "is it legit",
        "legit?", "true?", "real?", "actually true", "actually happen", "did this happen",
        "research", "look up", "look into", "dig into", "investigate",
        "find the source", "the source", "sources", "citation", "cite", "link to",
        "latest", "most recent", "up to date", "up-to-date", "current price",
        "what's new", "whats new", "any news", "news on", "recent news",
        "who else", "confirm this", "double check", "double-check",
        "search for", "search the web", "google this", "browse"
    ]

    static func requiresLiveInformation(_ prompt: String) -> Bool {
        let normalized = prompt
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return signals.contains { normalized.contains($0) }
    }
}
