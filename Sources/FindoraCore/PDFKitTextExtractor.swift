import Foundation
import PDFKit

public enum PDFTextLayerClassification: String, Codable, Sendable {
    case usable
    case insufficient
    case corrupt
    case missing
}

public struct PDFPageTextAssessment: Equatable, Sendable {
    public let pageNumber: Int
    public let text: String
    public let classification: PDFTextLayerClassification
    public let qualityScore: Double
    public let characterCount: Int
    public let wordCount: Int
    public let plausibleWordRatio: Double
    public let alphanumericRatio: Double
    public let selectionAvailable: Bool
    public let reason: String

    public var isUsable: Bool { classification == .usable }
}

public struct PDFKitTextExtractor: PDFTextExtracting {
    public init() {}

    public func extractPages(from url: URL) throws -> [ExtractedPage] {
        try assessPages(from: url).map { assessment in
            ExtractedPage(
                pageNumber: assessment.pageNumber,
                text: assessment.text,
                source: assessment.isUsable ? .nativePDF : .none,
                qualityScore: assessment.qualityScore
            )
        }
    }

    public func assessPages(from url: URL) throws -> [PDFPageTextAssessment] {
        guard let document = PDFDocument(url: url), !document.isLocked else {
            throw FindoraError.invalidPDF("Dokument ist beschädigt oder passwortgeschützt.")
        }
        guard document.pageCount > 0 else {
            throw FindoraError.invalidPDF("Das Dokument enthält keine lesbare Seite.")
        }

        return (0..<document.pageCount).map { index in
            guard let page = document.page(at: index) else {
                return PDFPageTextAssessment(
                    pageNumber: index + 1,
                    text: "",
                    classification: .missing,
                    qualityScore: 0,
                    characterCount: 0,
                    wordCount: 0,
                    plausibleWordRatio: 0,
                    alphanumericRatio: 0,
                    selectionAvailable: false,
                    reason: "PDFKit konnte die Seite nicht öffnen."
                )
            }
            return Self.assess(page: page, pageNumber: index + 1)
        }
    }

    public func pageCount(of url: URL) throws -> Int {
        guard let document = PDFDocument(url: url), !document.isLocked else {
            throw FindoraError.invalidPDF("Dokument ist beschädigt oder passwortgeschützt.")
        }
        return document.pageCount
    }

    public func hasUsableTextLayer(_ pages: [ExtractedPage]) -> Bool {
        !pages.isEmpty && pages.allSatisfy {
            $0.source == .nativePDF || $0.text.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
        } && pages.contains(where: { $0.source == .nativePDF })
    }

    public func needsMixedDocumentOCR(_ pages: [ExtractedPage]) -> Bool {
        pages.contains(where: { $0.source == .nativePDF })
            && pages.contains(where: { $0.source != .nativePDF })
    }

    public func assessTextLayer(
        pageNumber: Int,
        text: String,
        selectionAvailable: Bool
    ) -> PDFPageTextAssessment {
        Self.assessText(
            text,
            pageNumber: pageNumber,
            selectionAvailable: selectionAvailable
        )
    }

    private static func assess(
        page: PDFPage,
        pageNumber: Int
    ) -> PDFPageTextAssessment {
        let raw = page.string ?? ""
        let selectionAvailable: Bool
        if !raw.isEmpty {
            selectionAvailable = page.selection(
                for: NSRange(location: 0, length: min(1, raw.utf16.count))
            ) != nil
        } else {
            selectionAvailable = false
        }
        return assessText(
            raw,
            pageNumber: pageNumber,
            selectionAvailable: selectionAvailable
        )
    }

    private static func assessText(
        _ raw: String,
        pageNumber: Int,
        selectionAvailable: Bool
    ) -> PDFPageTextAssessment {
        let text = normalize(raw)
        let scalars = Array(text.unicodeScalars)
        let meaningful = scalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }
        let characterCount = meaningful.count
        let words = text.split(whereSeparator: {
            $0.isWhitespace || $0.isNewline
        }).map(String.init)
        let alphanumeric = meaningful.count {
            $0.properties.isAlphabetic || $0.properties.numericType != nil
        }
        let invalid = meaningful.count {
            CharacterSet.controlCharacters.contains($0)
                || $0.value == 0xFFFD
                || $0.value == 0
        }
        let alphanumericRatio = characterCount > 0
            ? Double(alphanumeric) / Double(characterCount)
            : 0
        let plausibleWords = words.count(where: plausibleWord)
        let plausibleWordRatio = words.isEmpty
            ? 0
            : Double(plausibleWords) / Double(words.count)
        let singleCharacterRatio = words.isEmpty
            ? 0
            : Double(words.count(where: { $0.count == 1 })) / Double(words.count)
        let repeatedArtifacts = text.range(
            of: #"(.)\1{5,}|(?:[|_~^�]\s*){4,}"#,
            options: .regularExpression
        ) != nil
        let replacementRatio = characterCount > 0
            ? Double(invalid) / Double(characterCount)
            : 0
        let identifierLike = text.range(
            of: #"\b[\p{L}\p{N}][\p{L}\p{N}./:+_-]{3,}\b"#,
            options: .regularExpression
        ) != nil
        let lengthScore = min(1, Double(characterCount) / 80)
        let wordScore = min(1, Double(words.count) / 12)
        var score = lengthScore * 0.20
            + wordScore * 0.15
            + alphanumericRatio * 0.25
            + plausibleWordRatio * 0.30
            + (selectionAvailable ? 0.10 : 0)
        score -= min(0.5, replacementRatio * 2)
        score -= min(0.25, max(0, singleCharacterRatio - 0.35))
        if repeatedArtifacts { score -= 0.35 }
        score = min(1, max(0, score))

        let classification: PDFTextLayerClassification
        let reason: String
        if characterCount == 0 {
            classification = .missing
            reason = "Die Seite enthält keine native PDF-Textschicht."
        } else if replacementRatio > 0.03
                    || repeatedArtifacts
                    || alphanumericRatio < 0.45
                    || (words.count >= 4 && plausibleWordRatio < 0.35)
                    || singleCharacterRatio > 0.65 {
            classification = .corrupt
            reason = "Die native Textschicht enthält wahrscheinlich Zeichenmüll oder stark fragmentierten Text."
        } else if score >= 0.58,
                  selectionAvailable,
                  (words.count >= 2 || identifierLike) {
            classification = .usable
            reason = "\(words.count) plausible Wörter, Qualitätswert \(score.formatted(.percent.precision(.fractionLength(0)))); PDFKit-Selektion verfügbar."
        } else {
            classification = .insufficient
            reason = "Die native Textschicht ist zu kurz, unvollständig oder nicht zuverlässig selektierbar."
        }

        return PDFPageTextAssessment(
            pageNumber: pageNumber,
            text: text,
            classification: classification,
            qualityScore: score,
            characterCount: characterCount,
            wordCount: words.count,
            plausibleWordRatio: plausibleWordRatio,
            alphanumericRatio: alphanumericRatio,
            selectionAvailable: selectionAvailable,
            reason: reason
        )
    }

    private static func plausibleWord(_ word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: .punctuationCharacters)
        guard !trimmed.isEmpty else { return false }
        if trimmed.allSatisfy(\.isNumber) {
            return trimmed.count >= 2
        }
        let letters = trimmed.unicodeScalars.count {
            $0.properties.isAlphabetic
        }
        let numbers = trimmed.unicodeScalars.count {
            $0.properties.numericType != nil
        }
        guard letters + numbers >= max(2, trimmed.count * 2 / 3) else {
            return false
        }
        if letters >= 3 {
            let lowercase = trimmed.lowercased()
            let vowels = CharacterSet(charactersIn: "aeiouyäöüAEIOUYÄÖÜ")
            return lowercase.unicodeScalars.contains(where: vowels.contains)
                || trimmed.range(of: #"\d"#, options: .regularExpression) != nil
        }
        return numbers > 0 || letters == trimmed.count
    }

    private static func normalize(_ text: String) -> String {
        let normalized = text.precomposedStringWithCanonicalMapping
        let lines = normalized
            .components(separatedBy: .newlines)
            .map { line in
                line
                    .unicodeScalars
                    .filter {
                        !CharacterSet.controlCharacters.contains($0)
                            || $0 == "\t"
                    }
                    .map(String.init)
                    .joined()
                    .replacingOccurrences(
                        of: #"[ \t]+"#,
                        with: " ",
                        options: .regularExpression
                    )
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
        return output.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
