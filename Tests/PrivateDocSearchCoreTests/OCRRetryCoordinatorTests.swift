import Foundation
import Testing
@testable import PrivateDocSearchCore

@Test
func ocrRetryStrategiesAreBoundedUniqueAndProgressivelyPrepared() {
    let strategies = OCRRetryStrategy.defaults(
        baseLanguages: ["deu"],
        baseEngine: .automatic
    )
    #expect(strategies.count == 8)
    #expect(Set(strategies.map(\.id)).count == strategies.count)
    #expect(strategies[0].renderDPI == 144)
    #expect(strategies[1].renderDPI == 300)
    #expect(strategies[2].enhanceContrast)
    #expect(strategies[3].binarize)
    #expect(strategies[5].languages == ["deu", "eng"])
    #expect(strategies[6].engineSelection == .tesseractOCRmyPDF)
    #expect(strategies[7].renderDPI == 400)
    #expect(OCRRetryPolicy.default.maximumAttempts == 8)
    #expect(OCRRetryPolicy.default.maximumDuration == .seconds(120))
    #expect(
        !OCRRetryStrategy.defaults(
            baseLanguages: ["deu"],
            baseEngine: .appleVision
        ).contains { $0.engineSelection == .tesseractOCRmyPDF }
    )
}

@Test
func ocrRetrySelectsBestVariantAndNeverLetsWorseLaterResultReplaceIt() async throws {
    let strategies = [
        retryStrategy(id: "weak", name: "Schwach"),
        retryStrategy(id: "best", name: "Beste Variante", contrast: true),
        retryStrategy(id: "best", name: "Duplikat wird übersprungen"),
        retryStrategy(id: "worse", name: "Später schlechter")
    ]
    let processor = ScriptedOCRProcessor(
        responses: [
            "weak": .quality(text: "x", confidence: 12, status: .likelyFailed),
            "best": .quality(
                text: "Sehr guter synthetischer OCR Text mit vielen plausiblen Wörtern 2026",
                confidence: 94,
                status: .good
            ),
            "worse": .quality(
                text: "schwacher späterer Text",
                confidence: 42,
                status: .review
            )
        ]
    )
    let outcome = try await OCRRetryCoordinator(
        provider: processor,
        baseConfiguration: .default,
        policy: OCRRetryPolicy(
            maximumAttempts: 8,
            maximumDuration: .seconds(120),
            automaticAcceptanceScore: 0.99
        ),
        strategies: strategies
    ).run(
        file: syntheticDiscoveredPDF(),
        baseConfiguration: .default,
        pageAnalyses: [syntheticContentAnalysis()]
    ) { _, _, _ in }

    #expect(await processor.strategyIDs() == ["weak", "best", "worse"])
    #expect(outcome.completedAttemptCount == 3)
    #expect(outcome.bestStrategyByPage[1]?.id == "best")
    #expect(outcome.result?.pages.first?.text.contains("Sehr guter") == true)
}

@Test
func ocrRetryStopsAfterFirstAcceptableImprovementAndHonorsAttemptLimit() async throws {
    let progressive = ScriptedOCRProcessor(
        responses: [
            "normal": .failure,
            "300": .quality(text: "kurzer text", confidence: 50, status: .review),
            "contrast": .quality(
                text: "Kontrast liefert einen klaren synthetischen Vertragstext 24.07.2026",
                confidence: 96,
                status: .good
            ),
            "unused": .quality(
                text: "Dieser Versuch darf nicht mehr laufen",
                confidence: 99,
                status: .good
            )
        ]
    )
    let strategies = [
        retryStrategy(id: "normal", name: "Normal"),
        retryStrategy(id: "300", name: "300 dpi", dpi: 300),
        retryStrategy(id: "contrast", name: "Kontrast", dpi: 300, contrast: true),
        retryStrategy(id: "unused", name: "Unbenutzt")
    ]
    let outcome = try await OCRRetryCoordinator(
        provider: progressive,
        baseConfiguration: .default,
        policy: OCRRetryPolicy(maximumAttempts: 4),
        strategies: strategies
    ).run(
        file: syntheticDiscoveredPDF(),
        baseConfiguration: .default,
        pageAnalyses: [syntheticContentAnalysis()]
    ) { _, _, _ in }
    #expect(await progressive.strategyIDs() == ["normal", "300", "contrast"])
    #expect(outcome.acceptedPageNumbers == [1])
    #expect(outcome.bestStrategyByPage[1]?.id == "contrast")

    let limited = ScriptedOCRProcessor(
        responses: Dictionary(
            uniqueKeysWithValues: (0..<6).map {
                ("s\($0)", .quality(text: "x", confidence: 1, status: .likelyFailed))
            }
        )
    )
    let limitedOutcome = try await OCRRetryCoordinator(
        provider: limited,
        baseConfiguration: .default,
        policy: OCRRetryPolicy(maximumAttempts: 3),
        strategies: (0..<6).map { retryStrategy(id: "s\($0)", name: "S\($0)") }
    ).run(
        file: syntheticDiscoveredPDF(),
        baseConfiguration: .default,
        pageAnalyses: [syntheticContentAnalysis()]
    ) { _, _, _ in }
    #expect(limitedOutcome.completedAttemptCount == 3)
    #expect(await limited.strategyIDs().count == 3)
}

@Test
func ocrRetryCanBeCancelledDuringAnAttempt() async {
    let processor = ScriptedOCRProcessor(
        responses: ["slow": .delayed],
        delay: .seconds(5)
    )
    let task = Task {
        try await OCRRetryCoordinator(
            provider: processor,
            baseConfiguration: .default,
            strategies: [retryStrategy(id: "slow", name: "Langsam")]
        ).run(
            file: syntheticDiscoveredPDF(),
            baseConfiguration: .default,
            pageAnalyses: [syntheticContentAnalysis()]
        ) { _, _, _ in }
    }
    try? await Task.sleep(for: .milliseconds(30))
    task.cancel()
    do {
        _ = try await task.value
        Issue.record("Der OCR-Versuch hätte abgebrochen werden müssen.")
    } catch is CancellationError {
        // Erwarteter kontrollierter Abbruch.
    } catch {
        Issue.record("Unerwarteter Abbruchfehler: \(error)")
    }
}

private enum ScriptedOCRResponse: Sendable {
    case failure
    case delayed
    case quality(text: String, confidence: Double, status: OCRQualityStatus)
}

private actor ScriptedOCRProcessor: OCRProcessing {
    private let responses: [String: ScriptedOCRResponse]
    private let delay: Duration
    private var observedStrategyIDs: [String] = []

    init(
        responses: [String: ScriptedOCRResponse],
        delay: Duration = .milliseconds(1)
    ) {
        self.responses = responses
        self.delay = delay
    }

    func strategyIDs() -> [String] {
        observedStrategyIDs
    }

    func process(
        _ file: DiscoveredPDF,
        configuration: OCRConfiguration
    ) async throws -> OCRResult {
        let strategyID = configuration.retryStrategyID ?? "unknown"
        observedStrategyIDs.append(strategyID)
        guard let response = responses[strategyID] else {
            throw PrivateDocSearchError.processFailed("Fehlende Teststrategie")
        }
        switch response {
        case .failure:
            throw PrivateDocSearchError.processFailed("Synthetischer OCR-Fehler")
        case .delayed:
            try await Task.sleep(for: delay)
            throw PrivateDocSearchError.processFailed("Unerwartetes Testende")
        case .quality(let text, let confidence, let status):
            let words = text.split(whereSeparator: \.isWhitespace).count
            let quality = OCRPageQuality(
                pageNumber: 1,
                meanConfidence: confidence,
                characterCount: text.count,
                wordCount: words,
                unusualCharacterCount: 0,
                suspectedBrokenWordCount: 0,
                recognizedLanguage: configuration.languages.joined(separator: "+"),
                isEmpty: text.isEmpty,
                imageToTextRatio: 1,
                status: status
            )
            return OCRResult(
                inputHash: "synthetic-hash",
                outputHash: "synthetic-hash",
                pageCount: 1,
                pages: [ExtractedPage(pageNumber: 1, text: text)],
                persistedToOriginal: false,
                pageQualities: [quality],
                engine: configuration.engineSelection == .tesseractOCRmyPDF
                    ? .tesseract
                    : .appleVision,
                duration: .milliseconds(1),
                completedAt: .now
            )
        }
    }
}

private func retryStrategy(
    id: String,
    name: String,
    dpi: Int = 144,
    contrast: Bool = false
) -> OCRRetryStrategy {
    OCRRetryStrategy(
        id: id,
        displayName: name,
        preprocessing: name,
        renderDPI: dpi,
        enhanceContrast: contrast
    )
}

private func syntheticDiscoveredPDF() -> DiscoveredPDF {
    DiscoveredPDF(
        url: URL(filePath: "/tmp/synthetic-ocr-retry.pdf"),
        relativePath: "synthetic-ocr-retry.pdf",
        fileName: "synthetic-ocr-retry.pdf",
        size: 1,
        modifiedAt: .now,
        resourceIdentifier: nil,
        volumeIdentifier: nil
    )
}

private func syntheticContentAnalysis() -> PageContentAnalysis {
    PageContentAnalysis(
        pageNumber: 1,
        pageCount: 1,
        status: .contentDetected,
        confidence: 1,
        reason: "Synthetischer sichtbarer Inhalt",
        metrics: PageVisualMetrics(
            renderSucceeded: true,
            pixelWidth: 100,
            pixelHeight: 100,
            whiteRatio: 0.9,
            darkPixelRatio: 0.1,
            variance: 0.1,
            edgeRatio: 0.1,
            contrast: 0.5,
            characterCount: 0,
            wordCount: 0,
            ocrConfidence: nil,
            embeddedImageCount: 0,
            annotationCount: 0,
            hasSmallText: false
        )
    )
}
