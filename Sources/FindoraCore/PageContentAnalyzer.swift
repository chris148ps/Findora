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
            throw FindoraError.invalidPDF(
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
            status = .contentDetected
            confidence = hasSmallText ? 0.92 : 0.99
            reason = hasSmallText
                ? "Text wurde erkannt; auch kleiner oder randnaher Text wird als Inhalt behandelt."
                : "\(words) Wörter und \(characters) Zeichen wurden erkannt."
        } else if annotations > 0 {
            status = .contentDetected
            confidence = 0.98
            reason = "Die Seite enthält \(annotations) Annotation(en), etwa Stempel, Unterschrift oder Formularinhalt."
        } else if xObjects > 0,
                  raster.darkPixelRatio > 0.00015 || raster.edgeRatio > 0.00015 {
            status = .imageWithoutRecognizedText
            confidence = 0.96
            reason = "Eingebettete Bild- oder Grafikobjekte sind sichtbar, aber es wurde kein Text erkannt."
        } else if raster.whiteRatio >= 0.99999,
                  raster.darkPixelRatio == 0,
                  raster.edgeRatio == 0,
                  raster.variance < 0.0000001,
                  raster.contrast < 0.005,
                  raster.borderNonWhiteRatio == 0,
                  raster.largestStructurePixels == 0,
                  raster.contrastIslandPixels == 0,
                  xObjects == 0 {
            status = .safelyEmpty
            confidence = 0.999
            reason = String(
                format: "%.3f %% Weißfläche; keine Text-, Bild-, Kanten- oder Annotationsstruktur.",
                raster.whiteRatio * 100
            )
        } else if raster.whiteRatio >= 0.999,
                  raster.darkPixelRatio < 0.00002,
                  raster.edgeRatio < 0.00002,
                  raster.largestStructurePixels <= 1,
                  raster.contrastIslandPixels <= 1,
                  raster.borderNonWhiteRatio == 0,
                  xObjects == 0 {
            status = .probablyEmpty
            confidence = min(0.95, max(0.70, raster.whiteRatio))
            reason = String(
                format: "%.2f %% Weißfläche; nur sehr geringe Pixel- und Kantenstruktur.",
                raster.whiteRatio * 100
            )
        } else {
            status = .contentDetected
            confidence = 0.98
            reason = raster.borderNonWhiteRatio > 0
                ? "Sichtbare Rand- oder Eckinhalte wurden erkannt; die Seite ist nicht leer."
                : raster.contrast < 0.10
                    ? "Kontrastarme Strukturen wurden erkannt; die Seite ist nicht leer."
                    : "Zusammenhängende Grafik-, Linien-, Barcode- oder Kontraststrukturen wurden erkannt."
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
        let structureMask = pixels.map { $0 < 248 }
        let largestStructure = Self.largestConnectedComponent(
            mask: structureMask,
            width: width,
            height: height
        )
        let borderThickness = max(1, min(width, height) / 10)
        var borderPixels = 0
        var borderNonWhite = 0
        for y in 0..<height {
            for x in 0..<width
            where x < borderThickness
                || x >= width - borderThickness
                || y < borderThickness
                || y >= height - borderThickness {
                borderPixels += 1
                if pixels[y * width + x] < 250 {
                    borderNonWhite += 1
                }
            }
        }
        let contrastIslands = pixels.count {
            abs(Double($0) - mean) >= 8
        }
        return RasterMetrics(
            width: width,
            height: height,
            whiteRatio: white,
            darkPixelRatio: dark,
            variance: variance,
            edgeRatio: comparisons > 0 ? Double(edgeCount) / Double(comparisons) : 0,
            contrast: Double(Int(maximum) - Int(minimum)) / 255,
            borderNonWhiteRatio: borderPixels > 0
                ? Double(borderNonWhite) / Double(borderPixels)
                : 0,
            largestStructurePixels: largestStructure,
            contrastIslandPixels: contrastIslands
        )
    }

    private static func largestConnectedComponent(
        mask: [Bool],
        width: Int,
        height: Int
    ) -> Int {
        guard mask.contains(true) else { return 0 }
        var visited = [Bool](repeating: false, count: mask.count)
        var largest = 0
        for start in mask.indices where mask[start] && !visited[start] {
            var queue = [start]
            visited[start] = true
            var cursor = 0
            while cursor < queue.count {
                let index = queue[cursor]
                cursor += 1
                let x = index % width
                let y = index / width
                let neighbors = [
                    x > 0 ? index - 1 : -1,
                    x + 1 < width ? index + 1 : -1,
                    y > 0 ? index - width : -1,
                    y + 1 < height ? index + width : -1
                ]
                for neighbor in neighbors
                where neighbor >= 0
                    && mask[neighbor]
                    && !visited[neighbor] {
                    visited[neighbor] = true
                    queue.append(neighbor)
                }
            }
            largest = max(largest, queue.count)
        }
        return largest
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
            status: .technicalReviewError,
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
    let borderNonWhiteRatio: Double
    let largestStructurePixels: Int
    let contrastIslandPixels: Int
}
