import CoreGraphics
import Foundation
@preconcurrency import Vision

private struct VisionRecognizedBox: Sendable {
    let text: String
    let boundingBox: CGRect
    let confidence: Double
}

private struct VisionPageRecognition: Sendable {
    let text: String
    let meanConfidence: Double?
    let boxes: [VisionRecognizedBox]
    let rotation: Int
}

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
            throw FindoraError.cancelled
        }
        guard configuration.persistenceMode == .nonDestructive else {
            throw FindoraError.dependencyMissing(
                "Apple Vision kann PDFs nicht dauerhaft um eine Textschicht erweitern."
            )
        }
        guard Self.isAvailable else {
            throw FindoraError.dependencyMissing(
                "Apple Vision ist auf diesem macOS-System nicht verfügbar."
            )
        }

        let started = ContinuousClock.now
        let inputHash = try hasher.hash(fileAt: file.url)
        guard let document = CGPDFDocument(file.url as CFURL), document.numberOfPages > 0 else {
            throw FindoraError.invalidPDF("Apple Vision konnte die PDF nicht öffnen.")
        }

        var pages: [ExtractedPage] = []
        var confidences: [Int: Double] = [:]
        var messages: [String] = []
        var textBoxes: [OCRTextBox] = []
        pages.reserveCapacity(document.numberOfPages)
        let existingPages = try extractor.assessPages(from: file.url)
        let targets = configuration.targetPageNumbers

        for pageNumber in 1...document.numberOfPages {
            try Task.checkCancellation()
            if let targets, !targets.contains(pageNumber),
               let existing = existingPages.first(where: {
                   $0.pageNumber == pageNumber
               }) {
                pages.append(
                    ExtractedPage(
                        pageNumber: pageNumber,
                        text: existing.text,
                        source: existing.isUsable ? .nativePDF : .none,
                        qualityScore: existing.qualityScore
                    )
                )
                continue
            }
            if targets == nil,
               let existing = existingPages.first(where: {
                   $0.pageNumber == pageNumber
               }),
               existing.isUsable {
                pages.append(
                    ExtractedPage(
                        pageNumber: pageNumber,
                        text: existing.text,
                        source: .nativePDF,
                        qualityScore: existing.qualityScore
                    )
                )
                continue
            }
            do {
                guard let page = document.page(at: pageNumber) else {
                    throw FindoraError.invalidPDF(
                        "Apple Vision konnte Seite \(pageNumber) nicht laden."
                    )
                }
                let renderedPage = try render(
                    page,
                    configuration: configuration
                )
                let rotations = configuration.manualRotationDegrees == 0
                    && configuration.rotatePages
                    ? [0, 90, 180, 270]
                    : [configuration.manualRotationDegrees]
                let recognized = try rotations.map { rotation in
                    try recognize(
                        renderedPage.image,
                        configuredLanguages: configuration.languages,
                        rotationDegrees: rotation
                    )
                }.max { lhs, rhs in
                    let left = Double(lhs.text.count) + (lhs.meanConfidence ?? 0)
                    let right = Double(rhs.text.count) + (rhs.meanConfidence ?? 0)
                    return left < right
                } ?? VisionPageRecognition(
                    text: "",
                    meanConfidence: nil,
                    boxes: [],
                    rotation: 0
                )
                pages.append(
                    ExtractedPage(
                        pageNumber: pageNumber,
                        text: recognized.text,
                        source: configuration.retryStrategyID == nil
                            ? .visionOCR
                            : .postprocessedOCR
                    )
                )
                textBoxes.append(contentsOf: recognized.boxes.map {
                    let unrotated = VisionOCRGeometry.unrotated(
                        $0.boundingBox,
                        rotationDegrees: recognized.rotation
                    )
                    let rect = VisionOCRGeometry.mapToFullPage(
                        unrotated,
                        renderedContentRect: renderedPage.contentRect
                    )
                    return OCRTextBox(
                        pageNumber: pageNumber,
                        text: $0.text,
                        normalizedX: rect.minX,
                        normalizedY: rect.minY,
                        normalizedWidth: rect.width,
                        normalizedHeight: rect.height,
                        confidence: $0.confidence
                    )
                })
                if let confidence = recognized.meanConfidence {
                    confidences[pageNumber] = confidence
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                pages.append(ExtractedPage(pageNumber: pageNumber, text: ""))
                messages.append(
                    "Seite \(pageNumber) konnte nicht per OCR verarbeitet werden: "
                        + error.localizedDescription
                )
            }
        }

        guard try hasher.hash(fileAt: file.url) == inputHash else {
            throw FindoraError.unstableFile(file.url.path)
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
            messages: messages,
            textBoxes: textBoxes,
            completedAt: .now
        )
    }

    private func render(
        _ page: CGPDFPage,
        configuration: OCRConfiguration
    ) throws -> (image: CGImage, contentRect: CGRect) {
        let bounds = page.getBoxRect(.mediaBox)
        let longestEdge = max(bounds.width, bounds.height)
        let requestedScale = max(rendererScale, CGFloat(configuration.renderDPI) / 72)
        let maximumPixels: CGFloat = configuration.renderDPI >= 600 ? 6_000 : 4_500
        let scale = min(
            requestedScale,
            longestEdge > 0 ? maximumPixels / longestEdge : 1
        )
        let width = max(1, Int(ceil(bounds.width * scale)))
        let height = max(1, Int(ceil(bounds.height * scale)))
        let cropInsetX = configuration.cropBorders
            ? max(1, width / 100)
            : 0
        let cropInsetY = configuration.cropBorders
            ? max(1, height / 100)
            : 0
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw FindoraError.processFailed(
                "Apple Vision konnte keinen Farbraum anlegen."
            )
        }
        let image = pixels.withUnsafeMutableBytes { bytes -> CGImage? in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return nil
            }
            let pixelBounds = CGRect(
                x: 0,
                y: 0,
                width: width,
                height: height
            )
            let pageBounds = CGRect(
                x: 0,
                y: 0,
                width: bounds.width,
                height: bounds.height
            )
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(pixelBounds)
            context.scaleBy(x: scale, y: scale)
            context.concatenate(
                page.getDrawingTransform(
                    .mediaBox,
                    rect: pageBounds,
                    rotate: 0,
                    preserveAspectRatio: true
                )
            )
            context.drawPDFPage(page)
            if configuration.enhanceContrast
                || configuration.binarize
                || configuration.adaptiveBinarize
                || configuration.backgroundLightening
                || configuration.reduceShadows
                || configuration.denoise
                || configuration.sharpen {
                let buffer = bytes.bindMemory(to: UInt8.self)
                var luminances = [UInt8](repeating: 255, count: width * height)
                let blockSize = 64
                let blockColumns = (width + blockSize - 1) / blockSize
                let blockRows = (height + blockSize - 1) / blockSize
                var blockSums = [Int](repeating: 0, count: blockColumns * blockRows)
                var blockCounts = [Int](repeating: 0, count: blockColumns * blockRows)
                for pixelIndex in 0..<(width * height) {
                    let index = pixelIndex * 4
                    let luminance = (
                        299 * Int(buffer[index])
                            + 587 * Int(buffer[index + 1])
                            + 114 * Int(buffer[index + 2])
                    ) / 1_000
                    luminances[pixelIndex] = UInt8(luminance)
                    let x = pixelIndex % width
                    let y = pixelIndex / width
                    let block = (y / blockSize) * blockColumns + x / blockSize
                    blockSums[block] += luminance
                    blockCounts[block] += 1
                }
                for index in stride(from: 0, to: buffer.count, by: 4) {
                    let pixelIndex = index / 4
                    let x = pixelIndex % width
                    let y = pixelIndex / width
                    let luminance = Int(luminances[pixelIndex])
                    var adjusted = luminance
                    if configuration.enhanceContrast {
                        adjusted = min(255, max(0, (luminance - 128) * 17 / 10 + 128))
                    }
                    if configuration.sharpen, x > 0, x + 1 < width, y > 0, y + 1 < height {
                        let neighborAverage = (
                            Int(luminances[pixelIndex - 1])
                                + Int(luminances[pixelIndex + 1])
                                + Int(luminances[pixelIndex - width])
                                + Int(luminances[pixelIndex + width])
                        ) / 4
                        adjusted = min(255, max(0, adjusted * 2 - neighborAverage))
                    }
                    if configuration.backgroundLightening, adjusted >= 210 {
                        adjusted = 255
                    }
                    if configuration.reduceShadows, adjusted >= 145 {
                        adjusted = min(255, adjusted + (255 - adjusted) / 2)
                    }
                    if configuration.binarize || configuration.adaptiveBinarize {
                        let block = (y / blockSize) * blockColumns + x / blockSize
                        let localMean = blockSums[block] / max(1, blockCounts[block])
                        let threshold = configuration.adaptiveBinarize
                            ? max(100, min(220, localMean - 12))
                            : 180
                        adjusted = adjusted < threshold ? 0 : 255
                    }
                    if configuration.denoise, adjusted == 0,
                       x > 0, x + 1 < width, y > 0, y + 1 < height {
                        let darkNeighbors = [
                            luminances[pixelIndex - 1],
                            luminances[pixelIndex + 1],
                            luminances[pixelIndex - width],
                            luminances[pixelIndex + width]
                        ].filter { $0 < 180 }.count
                        if darkNeighbors == 0 {
                            adjusted = 255
                        }
                    }
                    let value = UInt8(adjusted)
                    buffer[index] = value
                    buffer[index + 1] = value
                    buffer[index + 2] = value
                    buffer[index + 3] = 255
                }
            }
            guard let rendered = context.makeImage() else { return nil }
            if configuration.cropBorders {
                return rendered.cropping(
                    to: CGRect(
                        x: cropInsetX,
                        y: cropInsetY,
                        width: rendered.width - cropInsetX * 2,
                        height: rendered.height - cropInsetY * 2
                    )
                )
            }
            return rendered
        }
        guard let image else {
            throw FindoraError.processFailed(
                "Apple Vision konnte die PDF-Seite nicht rendern."
            )
        }
        if configuration.cropBorders {
            let contentRect = CGRect(
                x: CGFloat(cropInsetX) / CGFloat(width),
                y: CGFloat(cropInsetY) / CGFloat(height),
                width: CGFloat(width - cropInsetX * 2)
                    / CGFloat(width),
                height: CGFloat(height - cropInsetY * 2)
                    / CGFloat(height)
            )
            return (image, contentRect)
        }
        return (
            image,
            CGRect(x: 0, y: 0, width: 1, height: 1)
        )
    }

    private func recognize(
        _ image: CGImage,
        configuredLanguages: [String],
        rotationDegrees: Int
    ) throws -> VisionPageRecognition {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let requested = configuredLanguages.map(Self.visionLanguage)
        let supported = try request.supportedRecognitionLanguages()
        let usable = requested.filter(supported.contains)
        if !usable.isEmpty {
            request.recognitionLanguages = usable
        }

        let orientation: CGImagePropertyOrientation = switch rotationDegrees {
        case 90: .right
        case 180: .down
        case 270: .left
        default: .up
        }
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation)
        try handler.perform([request])
        let observations = (request.results ?? []).sorted {
            if abs($0.boundingBox.maxY - $1.boundingBox.maxY) > 0.015 {
                return $0.boundingBox.maxY > $1.boundingBox.maxY
            }
            return $0.boundingBox.minX < $1.boundingBox.minX
        }
        let recognized = observations.compactMap { observation in
            observation.topCandidates(1).first.map {
                (observation: observation, candidate: $0)
            }
        }
        let text = recognized.map(\.candidate.string).joined(separator: "\n")
        let meanConfidence = recognized.isEmpty
            ? nil
            : recognized.reduce(0) {
                $0 + Double($1.candidate.confidence)
            } / Double(recognized.count) * 100
        let boxes = recognized.map {
            VisionRecognizedBox(
                text: $0.candidate.string,
                boundingBox: $0.observation.boundingBox,
                confidence: Double($0.candidate.confidence)
            )
        }
        return VisionPageRecognition(
            text: text,
            meanConfidence: meanConfidence,
            boxes: boxes,
            rotation: rotationDegrees
        )
    }

}

enum VisionOCRGeometry {
    nonisolated static func unrotated(
        _ rect: CGRect,
        rotationDegrees: Int
    ) -> CGRect {
        let transformed: CGRect = switch rotationDegrees {
        case 90:
            CGRect(
                x: 1 - rect.maxY,
                y: rect.minX,
                width: rect.height,
                height: rect.width
            )
        case 180:
            CGRect(
                x: 1 - rect.maxX,
                y: 1 - rect.maxY,
                width: rect.width,
                height: rect.height
            )
        case 270:
            CGRect(
                x: rect.minY,
                y: 1 - rect.maxX,
                width: rect.height,
                height: rect.width
            )
        default:
            rect
        }
        return transformed.intersection(
            CGRect(x: 0, y: 0, width: 1, height: 1)
        )
    }

    nonisolated static func mapToFullPage(
        _ rect: CGRect,
        renderedContentRect: CGRect
    ) -> CGRect {
        CGRect(
            x: renderedContentRect.minX
                + rect.minX * renderedContentRect.width,
            y: renderedContentRect.minY
                + rect.minY * renderedContentRect.height,
            width: rect.width * renderedContentRect.width,
            height: rect.height * renderedContentRect.height
        ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}

extension VisionOCRProvider {
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
                throw FindoraError.dependencyMissing(
                    "Für dauerhaft durchsuchbare PDFs wird OCRmyPDF benötigt."
                )
            }
            await onEngineChange(.tesseract)
            return try await tesseractProvider.process(file, configuration: configuration)
        }

        switch configuration.engineSelection {
        case .appleVision:
            guard let visionProvider else {
                throw FindoraError.dependencyMissing(
                    "Apple Vision ist auf diesem System nicht verfügbar."
                )
            }
            await onEngineChange(.appleVision)
            return try await visionProvider.process(file, configuration: configuration)

        case .tesseractOCRmyPDF:
            guard let tesseractProvider = resolvedTesseractProvider() else {
                throw FindoraError.dependencyMissing(
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
                    let result = try await visionProvider.process(
                        file,
                        configuration: configuration
                    )
                    if result.pages.contains(where: {
                        !$0.text.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                    }) {
                        return result
                    }
                    throw FindoraError.processFailed(
                        "Apple Vision hat auf keiner Seite verwertbaren Text erkannt."
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    let visionFailure = error.localizedDescription
                    guard let tesseractProvider = resolvedTesseractProvider() else {
                        throw FindoraError.processFailed(
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
                            textBoxes: fallback.textBoxes,
                            completedAt: fallback.completedAt
                        )
                    } catch {
                        throw FindoraError.processFailed(
                            "Apple Vision ist fehlgeschlagen: \(visionFailure) "
                                + "Auch Tesseract ist fehlgeschlagen: \(error.localizedDescription)"
                        )
                    }
                }
            }
            #endif
            guard let tesseractProvider = resolvedTesseractProvider() else {
                throw FindoraError.dependencyMissing(
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
