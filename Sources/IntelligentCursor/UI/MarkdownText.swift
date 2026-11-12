import SwiftUI

/// Renders model output as text rather than as its markup.
///
/// Models answer in Markdown whether or not they are asked to, so showing the raw
/// string leaks asterisks, hashes, and backticks into what should read as a native
/// answer. This handles the block structure models actually use — headings, both
/// kinds of list, fenced code, paragraphs — and defers inline spans to Foundation.
///
/// It is re-parsed on every streamed delta, so it has to tolerate a half-written
/// document: an unterminated fence simply renders as code until it closes.
struct MarkdownText: View {
    let markdown: String
    var textColor: Color = .white.opacity(0.93)

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(MarkdownBlock.blocks(from: markdown)) { block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block.kind {
        case let .heading(level):
            Text(MarkdownBlock.inline(block.text))
                .font(.system(size: level <= 1 ? 15 : 13.5, weight: .semibold))
                .foregroundStyle(textColor)
                .padding(.top, 2)

        case .paragraph:
            Text(MarkdownBlock.inline(block.text))
                .font(.system(size: 13))
                .foregroundStyle(textColor)
                .lineSpacing(3)
                .textSelection(.enabled)

        case let .listItem(marker, indent):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(marker)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(textColor.opacity(0.55))
                    .frame(minWidth: 13, alignment: .trailing)
                Text(MarkdownBlock.inline(block.text))
                    .font(.system(size: 13))
                    .foregroundStyle(textColor)
                    .lineSpacing(3)
                    .textSelection(.enabled)
            }
            .padding(.leading, CGFloat(indent) * 13)

        case .code:
            Text(block.text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(textColor.opacity(0.92))
                .textSelection(.enabled)
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }
}

struct MarkdownBlock: Identifiable {
    enum Kind: Equatable {
        case heading(level: Int)
        case paragraph
        case listItem(marker: String, indent: Int)
        case code
    }

    let id: Int
    let kind: Kind
    let text: String

    /// Inline spans are Foundation's job. `inlineOnlyPreservingWhitespace` keeps
    /// bold, italics, code spans, and links without trying to interpret the block
    /// structure that has already been handled above.
    static func inline(_ text: String) -> AttributedString {
        guard var attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return AttributedString(text)
        }

        // Code spans arrive tagged but unstyled, so give them a monospaced face.
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].font = .system(size: 12, design: .monospaced)
        }
        return attributed
    }

    static func blocks(from markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var codeLines: [String] = []
        var inCode = false
        var identifier = 0

        func nextID() -> Int {
            identifier += 1
            return identifier
        }

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(MarkdownBlock(id: nextID(), kind: .paragraph, text: paragraph.joined(separator: " ")))
            paragraph.removeAll()
        }

        func flushCode() {
            guard !codeLines.isEmpty || inCode else { return }
            blocks.append(MarkdownBlock(id: nextID(), kind: .code, text: codeLines.joined(separator: "\n")))
            codeLines.removeAll()
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCode {
                    flushCode()
                    inCode = false
                } else {
                    flushParagraph()
                    inCode = true
                }
                continue
            }

            if inCode {
                codeLines.append(line)
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            if let heading = headingLevel(of: trimmed) {
                flushParagraph()
                let text = String(trimmed.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
                blocks.append(MarkdownBlock(id: nextID(), kind: .heading(level: heading), text: text))
                continue
            }

            if let item = listItem(of: line) {
                flushParagraph()
                blocks.append(MarkdownBlock(
                    id: nextID(),
                    kind: .listItem(marker: item.marker, indent: item.indent),
                    text: item.text
                ))
                continue
            }

            paragraph.append(trimmed)
        }

        flushParagraph()
        // An unterminated fence is normal mid-stream; render what has arrived.
        if inCode { flushCode() }
        return blocks
    }

    private static func headingLevel(of line: String) -> Int? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), line.dropFirst(hashes).hasPrefix(" ") else { return nil }
        return hashes
    }

    private static func listItem(of line: String) -> (marker: String, indent: Int, text: String)? {
        let leadingSpaces = line.prefix(while: { $0 == " " }).count
        let indent = min(leadingSpaces / 2, 3)
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        for bullet in ["- ", "* ", "+ "] where trimmed.hasPrefix(bullet) {
            return ("•", indent, String(trimmed.dropFirst(bullet.count)))
        }

        let digits = trimmed.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let afterDigits = trimmed.dropFirst(digits.count)
        guard afterDigits.hasPrefix(". ") || afterDigits.hasPrefix(") ") else { return nil }
        return ("\(digits).", indent, String(afterDigits.dropFirst(2)))
    }
}
