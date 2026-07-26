import Foundation

public struct PageChunker: Chunking {
    public static let version = "page-v1-900-150"

    public let targetCharacters: Int
    public let overlapCharacters: Int

    public init(targetCharacters: Int = 900, overlapCharacters: Int = 150) {
        precondition(targetCharacters >= 200)
        precondition(overlapCharacters >= 0 && overlapCharacters < targetCharacters)
        self.targetCharacters = targetCharacters
        self.overlapCharacters = overlapCharacters
    }

    public func chunks(for pages: [ExtractedPage], documentHash: String) -> [TextChunk] {
        pages.flatMap { page in
            split(page.text).enumerated().map { index, text in
                TextChunk(
                    id: "\(documentHash)-p\(page.pageNumber)-c\(index)",
                    pageNumber: page.pageNumber,
                    ordinal: index,
                    text: text
                )
            }
        }
    }

    private func split(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard trimmed.count > targetCharacters else { return [trimmed] }

        let paragraphs = trimmed
            .components(separatedBy: "\n\n")
            .flatMap { paragraph -> [String] in
                let value = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
                guard value.count > targetCharacters else { return value.isEmpty ? [] : [value] }
                return splitLongParagraph(value)
            }

        var chunks: [String] = []
        var current = ""
        for paragraph in paragraphs {
            let proposed = current.isEmpty ? paragraph : current + "\n\n" + paragraph
            if proposed.count <= targetCharacters {
                current = proposed
            } else {
                if !current.isEmpty { chunks.append(current) }
                let overlap = current.isEmpty ? "" : String(current.suffix(overlapCharacters))
                current = overlap.isEmpty ? paragraph : overlap + "\n\n" + paragraph
                if current.count > targetCharacters + overlapCharacters {
                    chunks.append(String(current.prefix(targetCharacters)))
                    current = String(current.suffix(overlapCharacters))
                }
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func splitLongParagraph(_ paragraph: String) -> [String] {
        let sentences = paragraph.split(
            omittingEmptySubsequences: true,
            whereSeparator: { ".!?;".contains($0) }
        )
        guard sentences.count > 1 else {
            return stride(from: 0, to: paragraph.count, by: targetCharacters - overlapCharacters)
                .map { offset in
                    let start = paragraph.index(paragraph.startIndex, offsetBy: offset)
                    let end = paragraph.index(
                        start,
                        offsetBy: min(targetCharacters, paragraph.distance(from: start, to: paragraph.endIndex)),
                        limitedBy: paragraph.endIndex
                    ) ?? paragraph.endIndex
                    return String(paragraph[start..<end])
                }
        }

        var result: [String] = []
        var current = ""
        for sentencePart in sentences {
            let sentence = String(sentencePart).trimmingCharacters(in: .whitespacesAndNewlines) + "."
            if current.count + sentence.count + 1 <= targetCharacters {
                current += (current.isEmpty ? "" : " ") + sentence
            } else {
                if !current.isEmpty { result.append(current) }
                current = sentence
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

