import CoreGraphics
import Foundation
@preconcurrency import Vision

public actor VisionOCRProvider: OCRProvider {
    public nonisolated let engine = OCREngine.appleVision

    private let hasher: SHA256Hasher
    private let qualityEvaluator: OCRQualityEvaluator
    private let extractor: PDFKitTextExtractor
    private let rendererScale: CGFloat

    public init(
        hasher: SHA256Hasher = SHA256Hasher(),
        qualityEvaluator: OCRQualityEvaluator = OCRQualityEvaluator(),
        extractor: PDFKitTextExtractor = PDFKitTextExtractor(),
        rendererScale: CGFloat = 2
    ) {
        self.hasher = hasher
        self.qualityEvaluator = qualityEvaluator
        self.extractor = extractor
        self.rendererScale = max(1, rendererScale)
    }

    public nonisolated static var isAvailable: Bool {
        if #available(macOS 13.0, *) {
            return true
        }
        return false
    }

    public func process(
        _ file: DiscoveredPDF,
        configuration: OCRConfiguration
    ) async throws -> OCRResult {
        try Task.checkCancellation()
        guard configuration.isEnabled else {
            throw PrivateDocSearchError.cancelled
        }
        guard configuration.persistenceMode == .nonDestructive else {
            throw PrivateDocSearchError.dependencyMissing(
                "Apple Vision kann PDFs nicht dauerhaft um eine Textschicht erweitern."
            )
        }
        guard Self.isAvailable else {
            throw PrivateDocSearchError.dependencyMissing(
                "Apple Vision ist auf diesem macOS-System nicht verfügbar."
            )
        }

        let started = ContinuousClock.now
        let inputHash = try hasher.hash(fileAt: file.url)
        guard let document = CGPDFDocument(file.url as CFURL), document.numberOfPages > 0 else {
            throw PrivateDocSearchError.invalidPDF("Apple Vision konnte die PDF nicht öffnen.")
        }

        var pages: [ExtractedPage] = []
        var confidences: [Int: Double] = [:]
        pages.reserveCapacity(document.numberOfPages)
        let existingPages = try extractor.extractPages(from: file.url)

        for pageNumber in 1...document.numberOfPages {
            try Task.checkCancellation()
            if let existing = existingPages.first(where: { $0.pageNumber == pageNumber }),
               existing.text.filter({ !$0.isWhitespace }).count >= 20 {
                pages.append(existing)
                continue
            }
            guard let page = document.page(at: pageNumber) else {
                throw PrivateDocSearchError.invalidPDF(
                    "Apple Vision konnte Seite \(pageNumber) nicht laden."
                )
            }
            let image = try render(page)
            let recognized = try recognize(
                image,
                configuredLanguages: configuration.languages
            )
            pages.append(
                ExtractedPage(
                    pageNumber: pageNumber,
                    text: recognized.text
                )
            )
            if let confidence = recognized.meanConfidence {
                confidences[pageNumber] = confidence
            }
        }

        guard try hasher.hash(fileAt: file.url) == inputHash else {
            throw PrivateDocSearchError.unstableFile(file.url.path)
        }
        guard pages.contains(where: {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            throw PrivateDocSearchError.invalidPDF(
                "Apple Vision hat keinen verwertbaren Text erkannt."
            )
        }

        return OCRResult(
            inputHash: inputHash,
            outputHash: inputHash,
            pageCount: document.numberOfPages,
            pages: pages,
            persistedToOriginal: false,
            pageQualities: qualityEvaluator.evaluate(
                pages: pages,
                configuredLanguages: configuration.languages,
                meanConfidences: confidences
            ),
            engine: engine,
            duration: started.duration(to: .now),
            completedAt: .now
        )
    }

    private func render(_ page: CGPDFPage) throws -> CGImage {
        let bounds = page.getBoxRect(.mediaBox)
        let longestEdge = max(bounds.width, bounds.height)
        let scale = min(rendererScale, longestEdge > 0 ? 3_000 / longestEdge : 1)
        let width = max(1, Int(ceil(bounds.width * scale)))
        let height = max(1, Int(ceil(bounds.height * scale)))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw PrivateDocSearchError.processFailed(
                "Apple Vision konnte keinen Bildpuffer anlegen."
            )
        }
        let target = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(target)
        context.concatenate(
            page.getDrawingTransform(
                .mediaBox,
                rect: target,
                rotate: 0,
                preserveAspectRatio: true
            )
        )
        context.drawPDFPage(page)
        guard let image = context.makeImage() else {
            throw PrivateDocSearchError.processFailed(
                "Apple Vision konnte die PDF-Seite nicht rendern."
            )
        }
        return image
    }

    private func recognize(
        _ image: CGImage,
        configuredLanguages: [String]
    ) throws -> (text: String, meanConfidence: Double?) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let requested = configuredLanguages.map(Self.visionLanguage)
        let supported = try request.supportedRecognitionLanguages()
        let usable = requested.filter(supported.contains)
        if !usable.isEmpty {
            request.recognitionLanguages = usable
        }

        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        try handler.perform([request])
        let observations = (request.results ?? []).sorted {
            if abs($0.boundingBox.maxY - $1.boundingBox.maxY) > 0.015 {
                return $0.boundingBox.maxY > $1.boundingBox.maxY
            }
            return $0.boundingBox.minX < $1.boundingBox.minX
        }
        let candidates = observations.compactMap { $0.topCandidates(1).first }
        let text = candidates.map(\.string).joined(separator: "\n")
        let meanConfidence = candidates.isEmpty
            ? nil
            : candidates.reduce(0) { $0 + Double($1.confidence) } / Double(candidates.count) * 100
        return (text, meanConfidence)
    }

    private nonisolated static func visionLanguage(_ language: String) -> String {
        switch language {
        case "deu": "de-DE"
        case "eng": "en-US"
        default: language
        }
    }
}

public actor OCRProviderRouter: OCRProcessing {
    private let visionProvider: (any OCRProvider)?
    private let tesseractProvider: (any OCRProvider)?
    private let tesseractProviderFactory: (@Sendable () -> (any OCRProvider)?)?

    public init(
        visionProvider: (any OCRProvider)?,
        tesseractProvider: (any OCRProvider)?
    ) {
        self.visionProvider = visionProvider
        self.tesseractProvider = tesseractProvider
        self.tesseractProviderFactory = nil
    }

    public init(
        visionProvider: (any OCRProvider)?,
        tesseractProviderFactory: @escaping @Sendable () -> (any OCRProvider)?
    ) {
        self.visionProvider = visionProvider
        self.tesseractProvider = nil
        self.tesseractProviderFactory = tesseractProviderFactory
    }

    public func process(
        _ file: DiscoveredPDF,
        configuration: OCRConfiguration
    ) async throws -> OCRResult {
        try await process(file, configuration: configuration) { _ in }
    }

    public func process(
        _ file: DiscoveredPDF,
        configuration: OCRConfiguration,
        onEngineChange: @Sendable (OCREngine) async -> Void
    ) async throws -> OCRResult {
        if configuration.persistenceMode == .persistent {
            guard let tesseractProvider = resolvedTesseractProvider() else {
                throw PrivateDocSearchError.dependencyMissing(
                    "Für dauerhaft durchsuchbare PDFs wird OCRmyPDF benötigt."
                )
            }
            await onEngineChange(.tesseract)
            return try await tesseractProvider.process(file, configuration: configuration)
        }

        switch configuration.engineSelection {
        case .appleVision:
            guard let visionProvider else {
                throw PrivateDocSearchError.dependencyMissing(
                    "Apple Vision ist auf diesem System nicht verfügbar."
                )
            }
            await onEngineChange(.appleVision)
            return try await visionProvider.process(file, configuration: configuration)

        case .tesseractOCRmyPDF:
            guard let tesseractProvider = resolvedTesseractProvider() else {
                throw PrivateDocSearchError.dependencyMissing(
                    "Tesseract und OCRmyPDF sind nicht verfügbar."
                )
            }
            await onEngineChange(.tesseract)
            return try await tesseractProvider.process(file, configuration: configuration)

        case .automatic:
            #if os(macOS)
            if let visionProvider {
                do {
                    await onEngineChange(.appleVision)
                    return try await visionProvider.process(file, configuration: configuration)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    let visionFailure = error.localizedDescription
                    guard let tesseractProvider = resolvedTesseractProvider() else {
                        throw PrivateDocSearchError.processFailed(
                            "Apple Vision ist fehlgeschlagen: \(visionFailure) "
                                + "Tesseract ist nicht verfügbar."
                        )
                    }
                    do {
                        await onEngineChange(.tesseract)
                        let fallback = try await tesseractProvider.process(
                            file,
                            configuration: configuration
                        )
                        return OCRResult(
                            inputHash: fallback.inputHash,
                            outputHash: fallback.outputHash,
                            pageCount: fallback.pageCount,
                            pages: fallback.pages,
                            persistedToOriginal: fallback.persistedToOriginal,
                            pageQualities: fallback.pageQualities,
                            engine: fallback.engine,
                            duration: fallback.duration,
                            messages: fallback.messages + [
                                "Apple Vision ist fehlgeschlagen; Tesseract wurde automatisch verwendet: \(visionFailure)"
                            ],
                            completedAt: fallback.completedAt
                        )
                    } catch {
                        throw PrivateDocSearchError.processFailed(
                            "Apple Vision ist fehlgeschlagen: \(visionFailure) "
                                + "Auch Tesseract ist fehlgeschlagen: \(error.localizedDescription)"
                        )
                    }
                }
            }
            #endif
            guard let tesseractProvider = resolvedTesseractProvider() else {
                throw PrivateDocSearchError.dependencyMissing(
                    "Keine verfügbare OCR-Engine gefunden."
                )
            }
            await onEngineChange(.tesseract)
            return try await tesseractProvider.process(file, configuration: configuration)
        }
    }

    private func resolvedTesseractProvider() -> (any OCRProvider)? {
        tesseractProvider ?? tesseractProviderFactory?()
    }
}
