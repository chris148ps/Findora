import CoreGraphics
import Foundation
import PDFKit

public struct PageContentAnalyzer: Sendable {
    private let maximumRenderDimension: Int

    public init(maximumRenderDimension: Int = 320) {
        self.maximumRenderDimension = max(128, maximumRenderDimension)
    }

    public func analyze(
        fileAt url: URL,
        textPages: [ExtractedPage] = [],
        ocrQualities: [OCRPageQuality] = []
    ) throws -> [PageContentAnalysis] {
        guard let document = PDFDocument(url: url),
              !document.isLocked,
              let graphicsDocument = CGPDFDocument(url as CFURL),
              document.pageCount == graphicsDocument.numberOfPages,
              document.pageCount > 0 else {
            throw PrivateDocSearchError.invalidPDF(
                "Die Seiten konnten für die Leerseitenprüfung nicht sicher geöffnet werden."
            )
        }

        let texts = Dictionary(uniqueKeysWithValues: textPages.map {
            ($0.pageNumber, $0.text)
        })
        let qualities = Dictionary(uniqueKeysWithValues: ocrQualities.map {
            ($0.pageNumber, $0)
        })
        return (1...document.pageCount).map { pageNumber in
            guard let pdfPage = document.page(at: pageNumber - 1),
                  let graphicsPage = graphicsDocument.page(at: pageNumber) else {
                return Self.technicalFailure(
                    pageNumber: pageNumber,
                    pageCount: document.pageCount,
                    reason: "Die Seite konnte nicht gerendert werden."
                )
            }
            let text = texts[pageNumber] ?? pdfPage.string ?? ""
            return analyze(
                pdfPage: pdfPage,
                graphicsPage: graphicsPage,
                pageNumber: pageNumber,
                pageCount: document.pageCount,
                text: text,
                quality: qualities[pageNumber]
            )
        }
    }

    private func analyze(
        pdfPage: PDFPage,
        graphicsPage: CGPDFPage,
        pageNumber: Int,
        pageCount: Int,
        text: String,
        quality: OCRPageQuality?
    ) -> PageContentAnalysis {
        guard let raster = render(graphicsPage) else {
            return Self.technicalFailure(
                pageNumber: pageNumber,
                pageCount: pageCount,
                reason: "Das Rendering der Seite ist fehlgeschlagen."
            )
        }

        let characters = text.filter { !$0.isWhitespace }.count
        let words = text.split(whereSeparator: \.isWhitespace).count
        let xObjects = Self.xObjectCount(on: graphicsPage)
        let annotations = pdfPage.annotations.count
        let hasSmallText = characters > 0
            && (characters <= 24 || raster.darkPixelRatio < 0.0015)
        let metrics = PageVisualMetrics(
            renderSucceeded: true,
            pixelWidth: raster.width,
            pixelHeight: raster.height,
            whiteRatio: raster.whiteRatio,
            darkPixelRatio: raster.darkPixelRatio,
            variance: raster.variance,
            edgeRatio: raster.edgeRatio,
            contrast: raster.contrast,
            characterCount: characters,
            wordCount: words,
            ocrConfidence: quality?.meanConfidence,
            embeddedImageCount: xObjects,
            annotationCount: annotations,
            hasSmallText: hasSmallText
        )

        let status: PageContentStatus
        let confidence: Double
        let reason: String
        if characters > 0 {
            status = .content
            confidence = hasSmallText ? 0.92 : 0.99
            reason = hasSmallText
                ? "Text wurde erkannt; auch kleiner oder randnaher Text wird als Inhalt behandelt."
                : "\(words) Wörter und \(characters) Zeichen wurden erkannt."
        } else if annotations > 0 {
            status = .needsOCRReview
            confidence = 0.98
            reason = "Die Seite enthält \(annotations) Annotation(en), etwa Stempel, Unterschrift oder Formularinhalt."
        } else if xObjects > 0,
                  raster.darkPixelRatio > 0.00015 || raster.edgeRatio > 0.00015 {
            status = .imageWithoutText
            confidence = 0.96
            reason = "Eingebettete Bild- oder Grafikobjekte sind sichtbar, aber es wurde kein Text erkannt."
        } else if raster.whiteRatio >= 0.9995,
                  raster.darkPixelRatio < 0.00008,
                  raster.edgeRatio < 0.00008,
                  raster.variance < 0.00002,
                  xObjects == 0 {
            status = .fullyEmpty
            confidence = min(1, 0.995 + (raster.whiteRatio - 0.9995) * 10)
            reason = String(
                format: "%.3f %% Weißfläche; keine Text-, Bild-, Kanten- oder Annotationsstruktur.",
                raster.whiteRatio * 100
            )
        } else if raster.whiteRatio >= 0.995,
                  raster.darkPixelRatio < 0.001,
                  raster.edgeRatio < 0.0008,
                  xObjects == 0 {
            status = .probablyEmpty
            confidence = min(0.99, max(0.80, raster.whiteRatio))
            reason = String(
                format: "%.2f %% Weißfläche; nur sehr geringe Pixel- und Kantenstruktur.",
                raster.whiteRatio * 100
            )
        } else if raster.contrast < 0.10 {
            status = .needsOCRReview
            confidence = 0.90
            reason = "Kontrastarme Strukturen sind vorhanden; die Seite wird nicht als leer eingestuft."
        } else {
            status = .needsOCRReview
            confidence = 0.94
            reason = "Grafische Strukturen oder dunkle Pixel sind vorhanden, obwohl kein Text erkannt wurde."
        }
        return PageContentAnalysis(
            pageNumber: pageNumber,
            pageCount: pageCount,
            status: status,
            confidence: confidence,
            reason: reason,
            metrics: metrics
        )
    }

    private func render(_ page: CGPDFPage) -> RasterMetrics? {
        let box = page.getBoxRect(.mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = min(
            Double(maximumRenderDimension) / box.width,
            Double(maximumRenderDimension) / box.height
        )
        let width = max(1, Int((box.width * scale).rounded()))
        let height = max(1, Int((box.height * scale).rounded()))
        var pixels = [UInt8](repeating: 255, count: width * height)
        let created = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            let target = CGRect(x: 0, y: 0, width: width, height: height)
            context.setFillColor(gray: 1, alpha: 1)
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
            return true
        }
        guard created, !pixels.isEmpty else { return nil }

        let count = Double(pixels.count)
        let sum = pixels.reduce(0.0) { $0 + Double($1) }
        let mean = sum / count
        let variance = pixels.reduce(0.0) {
            let difference = Double($1) - mean
            return $0 + difference * difference
        } / count / (255 * 255)
        let white = Double(pixels.count(where: { $0 >= 250 })) / count
        let dark = Double(pixels.count(where: { $0 < 220 })) / count
        let minimum = pixels.min() ?? 255
        let maximum = pixels.max() ?? 255
        var edgeCount = 0
        var comparisons = 0
        if width > 1, height > 1 {
            for y in 0..<height {
                for x in 0..<width {
                    let index = y * width + x
                    if x + 1 < width {
                        comparisons += 1
                        if abs(Int(pixels[index]) - Int(pixels[index + 1])) >= 18 {
                            edgeCount += 1
                        }
                    }
                    if y + 1 < height {
                        comparisons += 1
                        if abs(Int(pixels[index]) - Int(pixels[index + width])) >= 18 {
                            edgeCount += 1
                        }
                    }
                }
            }
        }
        return RasterMetrics(
            width: width,
            height: height,
            whiteRatio: white,
            darkPixelRatio: dark,
            variance: variance,
            edgeRatio: comparisons > 0 ? Double(edgeCount) / Double(comparisons) : 0,
            contrast: Double(Int(maximum) - Int(minimum)) / 255
        )
    }

    private static func xObjectCount(on page: CGPDFPage) -> Int {
        guard let dictionary = page.dictionary else { return 0 }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(
            dictionary,
            "Resources",
            &resources
        ), let resources else { return 0 }
        var objects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(
            resources,
            "XObject",
            &objects
        ), let objects else { return 0 }
        return CGPDFDictionaryGetCount(objects)
    }

    private static func technicalFailure(
        pageNumber: Int,
        pageCount: Int,
        reason: String
    ) -> PageContentAnalysis {
        PageContentAnalysis(
            pageNumber: pageNumber,
            pageCount: pageCount,
            status: .technicalError,
            confidence: 1,
            reason: reason,
            metrics: PageVisualMetrics(
                renderSucceeded: false,
                pixelWidth: 0,
                pixelHeight: 0,
                whiteRatio: 0,
                darkPixelRatio: 0,
                variance: 0,
                edgeRatio: 0,
                contrast: 0,
                characterCount: 0,
                wordCount: 0,
                ocrConfidence: nil,
                embeddedImageCount: 0,
                annotationCount: 0,
                hasSmallText: false
            )
        )
    }
}

private struct RasterMetrics {
    let width: Int
    let height: Int
    let whiteRatio: Double
    let darkPixelRatio: Double
    let variance: Double
    let edgeRatio: Double
    let contrast: Double
}
