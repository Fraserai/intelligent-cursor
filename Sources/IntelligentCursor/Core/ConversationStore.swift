import Foundation

/// A conversation that outlived the thing that started it.
///
/// The cursor is how intelligence is started from something in the world; the
/// conversation is not trapped inside that thing afterwards. Only what the model
/// actually receives is kept — the flattened context and the image — rather than
/// the full acquisition graph, because that is the boundary that matters once the
/// original element is gone.
struct StoredConversation: Codable, Sendable {
    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var originLabel: String
    var contextText: String
    var imageMimeType: String?
    var imagePixelWidth: Int?
    var imagePixelHeight: Int?
    var turns: [StoredTurn]
}

struct StoredTurn: Codable, Sendable {
    let profile: String
    let prompt: String
    let response: String
}

struct ConversationSummary: Identifiable, Sendable, Equatable {
    let id: UUID
    let title: String
    let updatedAt: Date
}

/// Deliberately small: a folder of files, no database, no index to fall out of
/// step with itself, and no management surface. The image lives beside its
/// conversation rather than inside it, so listing recent titles never has to read
/// megabytes of encoded pixels.
final class ConversationStore: @unchecked Sendable {
    private let directory: URL
    private let queue = DispatchQueue(label: "com.caeseyfraser.intelligent-cursor.conversations")
    private let retained: Int

    init(retained: Int = 20) {
        self.retained = retained
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        // Application Support is not synced, so a stalled file provider cannot
        // block a save the way it can in a synced project folder.
        directory = base
            .appendingPathComponent("The Intelligent Cursor", isDirectory: true)
            .appendingPathComponent("Conversations", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func save(_ conversation: StoredConversation, image: Data?) {
        queue.async { [self] in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(conversation) else { return }
            try? data.write(to: metadataURL(conversation.id), options: .atomic)
            if let image {
                try? image.write(to: imageURL(conversation.id), options: .atomic)
            }
            prune()
        }
    }

    func summaries(limit: Int = 8) -> [ConversationSummary] {
        queue.sync {
            metadataFiles()
                .prefix(limit)
                .compactMap { decode($0) }
                .map { ConversationSummary(id: $0.id, title: $0.title, updatedAt: $0.updatedAt) }
        }
    }

    func load(id: UUID) -> (conversation: StoredConversation, image: Data?)? {
        queue.sync {
            guard let conversation = decode(metadataURL(id)) else { return nil }
            return (conversation, try? Data(contentsOf: imageURL(id)))
        }
    }

    func delete(id: UUID) {
        queue.async { [self] in
            try? FileManager.default.removeItem(at: metadataURL(id))
            try? FileManager.default.removeItem(at: imageURL(id))
        }
    }

    private func metadataURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func imageURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).png")
    }

    private func decode(_ url: URL) -> StoredConversation? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(StoredConversation.self, from: data)
    }

    /// Newest first, by the conversation's own timestamp rather than the file's.
    private func metadataFiles() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return contents
            .filter { $0.pathExtension == "json" }
            .sorted { left, right in
                let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return leftDate > rightDate
            }
    }

    private func prune() {
        let stale = metadataFiles().dropFirst(retained)
        for url in stale {
            let id = url.deletingPathExtension().lastPathComponent
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id).png"))
        }
    }
}

extension StoredConversation {
    /// The question is the title. It is what the user would recognise the
    /// conversation by, and it needs no summarisation to produce.
    static func title(from question: String) -> String {
        let cleaned = question
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard cleaned.count > 52 else { return cleaned }
        return String(cleaned.prefix(51)) + "…"
    }
}
