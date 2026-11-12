import Foundation
import PDFKit
import UniformTypeIdentifiers

struct FileContextExtractor {
    private let maximumTextBytes = 1_500_000
    private let maximumExtractedCharacters = 36_000

    func extract(from semantic: SemanticSnapshot?) async -> FileContext? {
        guard let semantic else { return nil }
        let candidates = [semantic.url, semantic.documentURL].compactMap { $0 }
        guard let url = candidates.first(where: { $0.isFileURL }) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            extractSynchronously(url: url)
        }.value
    }

    private func extractSynchronously(url: URL) -> FileContext? {
        guard url.isFileURL else { return nil }
        let resourceValues = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isDirectoryKey,
            .fileSizeKey,
            .contentTypeKey,
            .nameKey
        ])
        let name = resourceValues?.name ?? url.lastPathComponent
        let contentType = resourceValues?.contentType

        guard resourceValues?.isDirectory != true else {
            return FileContext(url: url, name: name, contentType: contentType?.identifier, extractedText: nil)
        }

        var extractedText: String?
        if contentType?.conforms(to: .pdf) == true || url.pathExtension.lowercased() == "pdf" {
            extractedText = extractPDF(url: url)
        } else if isTextual(contentType: contentType, extension: url.pathExtension),
                  (resourceValues?.fileSize ?? 0) <= maximumTextBytes {
            extractedText = extractText(url: url)
        }

        return FileContext(
            url: url,
            name: name,
            contentType: contentType?.identifier,
            extractedText: extractedText
        )
    }

    private func isTextual(contentType: UTType?, extension pathExtension: String) -> Bool {
        if contentType?.conforms(to: .text) == true || contentType?.conforms(to: .sourceCode) == true {
            return true
        }
        let known = Set([
            "md", "txt", "json", "jsonl", "yaml", "yml", "toml", "xml", "csv", "tsv",
            "swift", "m", "mm", "h", "c", "cc", "cpp", "py", "js", "jsx", "ts", "tsx",
            "html", "css", "scss", "rs", "go", "java", "kt", "sh", "zsh", "sql", "log"
        ])
        return known.contains(pathExtension.lowercased())
    }

    private func extractText(url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumTextBytes) else { return nil }
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
        return text.map { String($0.prefix(maximumExtractedCharacters)) }
    }

    private func extractPDF(url: URL) -> String? {
        guard let document = PDFDocument(url: url) else { return nil }
        var text = ""
        let pageLimit = min(document.pageCount, 40)
        for index in 0..<pageLimit {
            guard text.count < maximumExtractedCharacters else { break }
            if let pageText = document.page(at: index)?.string {
                text += "\n\n[Page \(index + 1)]\n"
                text += pageText
            }
        }
        let result = String(text.prefix(maximumExtractedCharacters)).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}
