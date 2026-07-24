import Foundation
import PDFKit

public struct PDFKitTextExtractor: PDFTextExtracting {
    public init() {}

    public func extractPages(from url: URL) throws -> [ExtractedPage] {
        guard let document = PDFDocument(url: url), !document.isLocked else {
            throw PrivateDocSearchError.invalidPDF("Dokument ist beschädigt oder passwortgeschützt.")
        }

        return (0..<document.pageCount).map { index in
            let raw = document.page(at: index)?.string ?? ""
            return ExtractedPage(
                pageNumber: index + 1,
                text: Self.normalize(raw)
            )
        }
    }

    public func pageCount(of url: URL) throws -> Int {
        guard let document = PDFDocument(url: url), !document.isLocked else {
            throw PrivateDocSearchError.invalidPDF("Dokument ist beschädigt oder passwortgeschützt.")
        }
        return document.pageCount
    }

    public func hasUsableTextLayer(_ pages: [ExtractedPage]) -> Bool {
        let printableCounts = pages.map { page in
            page.text.unicodeScalars.reduce(into: 0) { count, scalar in
                if !CharacterSet.whitespacesAndNewlines.contains(scalar)
                    && !CharacterSet.controlCharacters.contains(scalar) {
                    count += 1
                }
            }
        }
        let total = printableCounts.reduce(0, +)
        let nonempty = printableCounts.filter { $0 > 0 }
        let useful = printableCounts.filter { $0 >= 20 }
        return total >= 80
            || (!nonempty.isEmpty && Double(useful.count) / Double(nonempty.count) >= 0.7)
    }

    public func needsMixedDocumentOCR(_ pages: [ExtractedPage]) -> Bool {
        guard !pages.isEmpty else { return false }
        let counts = pages.map { $0.text.filter { !$0.isWhitespace }.count }
        return counts.contains(where: { $0 < 20 }) && counts.contains(where: { $0 >= 20 })
    }

    private static func normalize(_ text: String) -> String {
        let normalized = text.precomposedStringWithCanonicalMapping
        let lines = normalized
            .components(separatedBy: .newlines)
            .map { line in
                line
                    .unicodeScalars
                    .filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\t" }
                    .map(String.init)
                    .joined()
                    .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
            }

        var output: [String] = []
        var previousWasBlank = false
        for line in lines {
            let blank = line.isEmpty
            if blank && previousWasBlank { continue }
            output.append(line)
            previousWasBlank = blank
        }
        return output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

