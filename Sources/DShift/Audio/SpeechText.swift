import Foundation

enum SpeechText {
    /// Narrate prose, not source code, Markdown punctuation, or citation URLs.
    static func chunks(_ markdown: String) -> [String] {
        let prose = MessageSegment.split(markdown).compactMap { segment -> String? in
            if case .prose(let text) = segment { return text }
            return nil
        }.joined(separator: "\n\n")
        let unstyled = prose.replacingOccurrences(
            of: #"(?m)^\s{0,3}(?:#{1,6}\s+|[-*+]\s+|\d+[.)]\s+|>\s*)"#,
            with: "", options: .regularExpression)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let attributed = (try? AttributedString(markdown: unstyled, options: options)) ?? AttributedString(unstyled)
        let plain = String(attributed.characters)
            .replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")

        // Bound each synthesis request while keeping complete sentences together when possible.
        var chunks: [String] = []
        var current = ""
        plain.enumerateSubstrings(in: plain.startIndex..<plain.endIndex, options: .bySentences) { sentence, _, _, _ in
            guard let sentence = sentence?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            if current.count + sentence.count + 1 > 500, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            for word in sentence.split(whereSeparator: \.isWhitespace) {
                var remainder = String(word)
                while !remainder.isEmpty {
                    if current.count + remainder.count + 1 > 500, !current.isEmpty {
                        chunks.append(current)
                        current = ""
                    }
                    let part = String(remainder.prefix(500))
                    current += (current.isEmpty ? "" : " ") + part
                    remainder.removeFirst(part.count)
                }
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
