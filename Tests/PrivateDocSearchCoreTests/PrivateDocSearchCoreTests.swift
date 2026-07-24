import AppKit
import CoreText
import Foundation
import PDFKit
import PrivateDocSearchMLX
import Testing
@testable import PrivateDocSearchCore

@Test
func temporaryFileNamesAreIgnored() {
    #expect(RecursivePDFScanner.isTemporary(name: ".scan.pdf"))
    #expect(RecursivePDFScanner.isTemporary(name: "~$scan.pdf"))
    #expect(RecursivePDFScanner.isTemporary(name: "scan.pdf.part"))
    #expect(!RecursivePDFScanner.isTemporary(name: "scan.pdf"))
}

@Test
func abandonedOCRTemporaryFilesAreRemovedConservatively() throws {
    let root = temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let oldTemporary = root.appending(path: ".privatedocsearch-ocr-old.pdf")
    let recentTemporary = root.appending(path: ".privatedocsearch-ocr-recent.pdf")
    let unrelated = root.appending(path: ".other-temp.pdf")
    for url in [oldTemporary, recentTemporary, unrelated] {
        try Data("%PDF-1.4\n%%EOF".utf8).write(to: url)
    }
    let now = Date()
    try FileManager.default.setAttributes(
        [.modificationDate: now.addingTimeInterval(-48 * 60 * 60)],
        ofItemAtPath: oldTemporary.path
    )

    let removed = try OCRTemporaryFileCleaner().removeAbandonedFiles(
        below: root,
        olderThan: 24 * 60 * 60,
        now: now
    )

    #expect(removed.count == 1)
    #expect(removed.first?.lastPathComponent == oldTemporary.lastPathComponent)
    #expect(!FileManager.default.fileExists(atPath: oldTemporary.path))
    #expect(FileManager.default.fileExists(atPath: recentTemporary.path))
    #expect(FileManager.default.fileExists(atPath: unrelated.path))
}

@Test(.timeLimit(.minutes(1)))
func memoryPressureHandlerHopsFromBackgroundQueueToMainActor() async throws {
    let state = await MainActor.run { MemoryPressureTestState() }
    let (events, continuation) = AsyncStream<MemoryPressureLevel>.makeStream()
    let sourceQueue = DispatchQueue(
        label: "de.privatedocsearch.tests.memory-pressure-source",
        qos: .utility
    )
    let callbackQueue = DispatchQueue(
        label: "de.privatedocsearch.tests.memory-pressure-callback",
        qos: .utility
    )
    let monitor = MemoryPressureMonitor(queue: sourceQueue) { level in
        state.level = level
        state.wasUpdatedOnMainActor = true
        continuation.yield(level)
    }

    #expect(monitor.start())
    #expect(!monitor.start())
    let ranAwayFromMainThread = await monitor.simulateForDiagnostics(
        .critical,
        from: callbackQueue
    )
    #expect(ranAwayFromMainThread)

    var iterator = events.makeAsyncIterator()
    let received = await iterator.next()
    #expect(received == .critical)
    let result = await MainActor.run {
        (state.level, state.wasUpdatedOnMainActor)
    }
    #expect(result.0 == .critical)
    #expect(result.1)

    monitor.stop()
    #expect(!monitor.isRunning)
    monitor.stop()
    #expect(monitor.start())
    monitor.stop()

    weak var releasedMonitor: MemoryPressureMonitor?
    do {
        let disposableMonitor = MemoryPressureMonitor { _ in }
        #expect(disposableMonitor.start())
        releasedMonitor = disposableMonitor
    }
    #expect(releasedMonitor == nil)
}

@Test
func appFileLoggerCreatesReadablePrivateLog() async throws {
    let root = temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let logger = try AppFileLogger(logDirectory: root)

    try await logger.log(
        .warning,
        category: "Speicherdruck",
        message: "Kritisch\nAntwortmodell entladen."
    )
    let contents = try await logger.contents()
    let fileURL = await logger.fileURL
    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue

    #expect(fileURL.lastPathComponent == "PrivateDocSearch.log")
    #expect(contents.contains("[WARN] [Speicherdruck]"))
    #expect(contents.contains("Kritisch Antwortmodell entladen."))
    #expect(permissions == 0o600)
}

@Test
func scannerFindsNestedPDFsAndSkipsSymlinks() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "PrivateDocSearchScanner-\(UUID().uuidString)", directoryHint: .isDirectory)
    let nested = root.appending(path: "A/B", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try Data("%PDF-1.4\n%%EOF".utf8).write(to: nested.appending(path: "synthetic.pdf"))
    try Data("ignored".utf8).write(to: nested.appending(path: ".hidden.pdf"))
    try FileManager.default.createSymbolicLink(
        at: root.appending(path: "loop"),
        withDestinationURL: root
    )

    let results = try await RecursivePDFScanner().scan(root: root)
    #expect(results.count == 1)
    #expect(results.first?.relativePath == "A/B/synthetic.pdf")
}

@Test
func chunkerKeepsPageBoundaryAndOverlap() {
    let page1 = ExtractedPage(pageNumber: 1, text: String(repeating: "Erster Satz. ", count: 120))
    let page2 = ExtractedPage(pageNumber: 2, text: "Kurze zweite Seite.")
    let chunks = PageChunker(targetCharacters: 300, overlapCharacters: 40)
        .chunks(for: [page1, page2], documentHash: "hash")

    #expect(chunks.count > 2)
    #expect(chunks.filter { $0.pageNumber == 2 }.count == 1)
    #expect(chunks.allSatisfy { $0.id.contains("p\($0.pageNumber)") })
}

@Test
func tokenHashEmbeddingIsDeterministicAndNormalized() async throws {
    let embedder = TokenHashEmbedding(dimensions: 64)
    let first = try await embedder.embed(query: "Jugendamt und Kindeswohl")
    let second = try await embedder.embed(query: "Jugendamt und Kindeswohl")
    #expect(first == second)
    let magnitude = sqrt(first.reduce(Float.zero) { $0 + $1 * $1 })
    #expect(abs(magnitude - 1) < 0.0001)
}

@Test
func pdfExtractionPreservesOneBasedPageNumbers() throws {
    let root = temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let pdf = root.appending(path: "text.pdf")
    try createTextPDF(at: pdf, pages: ["Erste synthetische Seite", "Zweite synthetische Seite"])

    let pages = try PDFKitTextExtractor().extractPages(from: pdf)
    #expect(pages.count == 2)
    #expect(pages[0].pageNumber == 1)
    #expect(pages[1].pageNumber == 2)
    #expect(pages[0].text.contains("Erste synthetische Seite"))
}

@Test
func corruptPDFIsNeverChangedByOCR() async throws {
    let dependencies = OCRDependencyChecker().check()
    guard dependencies.isReady else { return }
    let root = temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let pdf = root.appending(path: "corrupt.pdf")
    let original = Data("%PDF-not-a-real-document".utf8)
    try original.write(to: pdf)

    let file = discoveredPDF(pdf)
    do {
        _ = try await OCRmyPDFProcessor(dependencies: dependencies).process(
            file,
            configuration: OCRConfiguration(
                languages: ["eng"],
                rotatePages: false,
                deskew: false
            )
        )
        Issue.record("Beschädigte PDF hätte abgewiesen werden müssen.")
    } catch {
        #expect(try Data(contentsOf: pdf) == original)
    }
}

@Test(.timeLimit(.minutes(1)))
func ocrAddsTextLayerToSyntheticScan() async throws {
    let dependencies = OCRDependencyChecker().check()
    guard dependencies.isReady else { return }
    let root = temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let pdf = root.appending(path: "scan.pdf")
    try createImagePDF(at: pdf, text: "SYNTHETIC OCR TEST 12345")

    let before = try Data(contentsOf: pdf)
    let result = try await OCRmyPDFProcessor(dependencies: dependencies).process(
        discoveredPDF(pdf),
        configuration: OCRConfiguration(
            languages: ["eng"],
            rotatePages: false,
            deskew: false
        )
    )

    let pages = try PDFKitTextExtractor().extractPages(from: pdf)
    #expect(result.pageCount == 1)
    #expect(try Data(contentsOf: pdf) != before)
    #expect(pages.first?.text.uppercased().contains("SYNTHETIC") == true)
    #expect(FileManager.default.fileExists(atPath: pdf.path))
}

@Test(.timeLimit(.minutes(1)))
func configuredParallelOCRProcessesMoreThanOneFileAtOnce() async throws {
    let root = temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        applicationSupport: root.appending(path: "Support"),
        logs: root.appending(path: "Logs")
    )
    let database = SQLiteDatabase(url: paths.database)
    try await database.initialize()

    let first = root.appending(path: "Scan-1.pdf")
    let second = root.appending(path: "Scan-2.pdf")
    try createImagePDF(at: first, text: "SCAN ONE")
    try createImagePDF(at: second, text: "SCAN TWO")
    let replacement = root.appending(path: "Replacement.pdf")
    try createTextPDF(
        at: replacement,
        pages: [String(repeating: "Synthetischer Text für den Parallelitätstest. ", count: 5)]
    )
    let replacementData = try Data(contentsOf: replacement)
    try FileManager.default.removeItem(at: replacement)

    let scanner = RecursivePDFScanner(excludedRoots: [paths.applicationSupport])
    let files = try await scanner.scan(root: root)
    try await database.saveScan(files: files, root: root)
    let probe = OCRConcurrencyProbe()
    let processor = DocumentProcessor(
        database: database,
        stabilityChecker: FileStabilityChecker(delay: .zero),
        embedder: TokenHashEmbedding(dimensions: 64),
        ocrProcessorFactory: {
            SyntheticOCRProcessor(replacementData: replacementData, probe: probe)
        }
    )

    await processor.processPending(
        ocrConfiguration: OCRConfiguration(
            languages: ["eng"],
            rotatePages: false,
            deskew: false,
            maximumParallelFiles: 2,
            cpuMode: .normal
        )
    ) { _ in }

    let peak = await probe.peak
    #expect(peak == 2)
    let statistics = try await database.statistics()
    #expect(statistics.totalPDFs == 2)
    #expect(statistics.indexedPDFs == 1)
}

@Test
func bundledModelCatalogIsPinnedAndFitsEightGigabyteProfile() throws {
    let catalog = try ModelCatalog.bundled()
    #expect(catalog.models.count == 3)
    #expect(catalog.models.allSatisfy { !$0.files.isEmpty })
    #expect(catalog.models.allSatisfy { $0.files.allSatisfy { $0.checksumSHA256.count == 64 } })

    let profile = HardwareProfile(
        isAppleSilicon: true,
        chipName: "Synthetic Apple Silicon",
        physicalMemoryBytes: 8_589_934_592,
        availableStorageBytes: 40_000_000_000
    )
    let compact = try #require(catalog.models.first { $0.id.contains("1.7B") })
    let larger = try #require(catalog.models.first { $0.id.contains("4B-4bit") })
    #expect(profile.compatibility(for: compact) == .recommended)
    #expect(profile.compatibility(for: larger) == .compatible)
}

@Test
func unavailableCloudPlaceholderRemainsVisibleWithoutProcessing() async throws {
    let root = temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        applicationSupport: root.appending(path: "Support"),
        logs: root.appending(path: "Logs")
    )
    let database = SQLiteDatabase(url: paths.database)
    try await database.initialize()
    let placeholderURL = root.appending(path: "Cloud.pdf")
    let placeholder = DiscoveredPDF(
        url: placeholderURL,
        relativePath: "Cloud.pdf",
        fileName: "Cloud.pdf",
        size: 0,
        modifiedAt: .now,
        resourceIdentifier: nil,
        volumeIdentifier: nil,
        isLocallyAvailable: false,
        availabilityError: "Die Cloud-Datei ist derzeit nur als Platzhalter vorhanden."
    )

    try await database.saveScan(files: [placeholder], root: root)

    #expect((try await database.pendingFiles()).isEmpty)
    #expect((try await database.recentErrors()).contains {
        $0.1 == "Verfügbarkeit" && $0.3 == placeholderURL.path
    })
}

@Test
func indexingSearchRenameAndDeletionStayConsistent() async throws {
    let root = temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let support = root.appending(path: "Support", directoryHint: .isDirectory)
    let paths = try AppPaths(
        applicationSupport: support,
        logs: root.appending(path: "Logs")
    )
    let database = SQLiteDatabase(url: paths.database)
    try await database.initialize()

    let pdf = root.appending(path: "Dokument.pdf")
    try createTextPDF(
        at: pdf,
        pages: [
            "Das Jugendamt prüft das Kindeswohl. Dieses Dokument ist vollständig synthetisch.",
            "Der Termin beim Amtsgericht ist am 12. März."
        ]
    )
    let scanner = RecursivePDFScanner(excludedRoots: [support])
    var files = try await scanner.scan(root: root)
    try await database.saveScan(files: files, root: root)
    let embedder = TokenHashEmbedding(dimensions: 64)
    let processor = DocumentProcessor(
        database: database,
        stabilityChecker: FileStabilityChecker(delay: .zero),
        embedder: embedder
    )
    await processor.processPending(
        ocrConfiguration: OCRConfiguration(isEnabled: false)
    ) { _ in }

    let search = HybridSearchService(database: database, embedder: embedder)
    var results = try await search.search("Jugendamt Kindeswohl")
    #expect(results.first?.pageNumber == 1)
    #expect(results.first?.fileName == "Dokument.pdf")
    let coverage = try await database.embeddingCoverage(
        modelID: embedder.modelID,
        modelVersion: embedder.modelVersion
    )
    #expect(coverage.embeddedChunks == coverage.totalChunks)

    let renamed = root.appending(path: "Umbenannt.pdf")
    try FileManager.default.moveItem(at: pdf, to: renamed)
    files = try await scanner.scan(root: root)
    try await database.saveScan(files: files, root: root)
    await processor.processPending(
        ocrConfiguration: OCRConfiguration(isEnabled: false)
    ) { _ in }
    results = try await search.search("Jugendamt Kindeswohl")
    #expect(results.first?.fileName == "Umbenannt.pdf")
    #expect((try await database.statistics()).totalPDFs == 1)

    try FileManager.default.removeItem(at: renamed)
    files = try await scanner.scan(root: root)
    try await database.saveScan(files: files, root: root)
    results = try await search.search("Jugendamt Kindeswohl")
    #expect(results.isEmpty)
    #expect((try await database.statistics()).totalPDFs == 0)
}

@Test(.timeLimit(.minutes(10)))
func realMLXEmbeddingModelCanDownloadValidateAndRunWhenRequested() async throws {
    let marker = URL(filePath: "/private/tmp/PrivateDocSearch-run-mlx-tests")
    guard ProcessInfo.processInfo.environment["PRIVATEDOCSEARCH_RUN_MODEL_TESTS"] == "1"
            || FileManager.default.fileExists(atPath: marker.path) else {
        return
    }
    let root = temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        applicationSupport: root.appending(path: "Support"),
        logs: root.appending(path: "Logs")
    )
    let catalog = try ModelCatalog.bundled()
    let descriptor = try #require(catalog.models.first { $0.kind == .embedding })
    let manager = LocalModelManager(catalog: catalog, paths: paths)
    let profile = HardwareProfile(
        isAppleSilicon: true,
        chipName: "Integrationstest",
        physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
        availableStorageBytes: 10_000_000_000
    )
    let directory = try await manager.install(
        modelID: descriptor.id,
        profile: profile
    ) { _ in }

    let provider = MLXEmbeddingProvider(
        modelID: descriptor.id,
        modelVersion: descriptor.modelVersion,
        directory: directory
    )
    try await provider.test()
    let vectors = try await provider.embed(documents: [
        "Das Jugendamt prüft das Kindeswohl.",
        "Eine Rechnung für das Fahrzeug."
    ])
    #expect(vectors.count == 2)
    #expect(vectors.allSatisfy { $0.count == 384 })
    await provider.unload()
}

@Test(.timeLimit(.minutes(20)))
func realMLXAnswerModelCanDownloadValidateAndGenerateWhenRequested() async throws {
    let marker = URL(filePath: "/private/tmp/PrivateDocSearch-run-llm-tests")
    guard FileManager.default.fileExists(atPath: marker.path) else {
        return
    }
    let root = temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        applicationSupport: root.appending(path: "Support"),
        logs: root.appending(path: "Logs")
    )
    let catalog = try ModelCatalog.bundled()
    let descriptor = try #require(catalog.models.first {
        $0.kind == .answer && $0.id.contains("1.7B")
    })
    let manager = LocalModelManager(catalog: catalog, paths: paths)
    let profile = HardwareProfile(
        isAppleSilicon: true,
        chipName: "Integrationstest",
        physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
        availableStorageBytes: 10_000_000_000
    )
    let directory = try await manager.install(
        modelID: descriptor.id,
        profile: profile
    ) { _ in }

    let generator = MLXAnswerGenerator(
        directory: directory,
        contextLength: descriptor.defaultContextLength
    )
    try await generator.test()
    await generator.unload()
}

private func temporaryTestDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "PrivateDocSearchTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func discoveredPDF(_ url: URL) -> DiscoveredPDF {
    let attributes = try! FileManager.default.attributesOfItem(atPath: url.path)
    return DiscoveredPDF(
        url: url,
        relativePath: url.lastPathComponent,
        fileName: url.lastPathComponent,
        size: (attributes[.size] as! NSNumber).int64Value,
        modifiedAt: attributes[.modificationDate] as! Date,
        resourceIdentifier: nil,
        volumeIdentifier: nil
    )
}

private actor OCRConcurrencyProbe {
    private var active = 0
    private(set) var peak = 0

    func begin() {
        active += 1
        peak = max(peak, active)
    }

    func end() {
        active -= 1
    }
}

@MainActor
private final class MemoryPressureTestState {
    var level: MemoryPressureLevel = .normal
    var wasUpdatedOnMainActor = false
}

private struct SyntheticOCRProcessor: OCRProcessing {
    let replacementData: Data
    let probe: OCRConcurrencyProbe

    func process(
        _ file: DiscoveredPDF,
        configuration: OCRConfiguration
    ) async throws -> OCRResult {
        let inputHash = try SHA256Hasher().hash(fileAt: file.url)
        await probe.begin()
        do {
            try await Task.sleep(for: .milliseconds(200))
            try replacementData.write(to: file.url, options: .atomic)
            await probe.end()
        } catch {
            await probe.end()
            throw error
        }
        return OCRResult(
            inputHash: inputHash,
            outputHash: try SHA256Hasher().hash(fileAt: file.url),
            pageCount: 1,
            completedAt: .now
        )
    }
}

private func createTextPDF(at url: URL, pages: [String]) throws {
    var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
    guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
        throw PrivateDocSearchError.invalidPDF("Test-PDF-Kontext konnte nicht angelegt werden.")
    }
    for text in pages {
        context.beginPDFPage(nil)
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 24),
                .foregroundColor: NSColor.black
            ]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: 72, y: 760)
        CTLineDraw(line, context)
        context.endPDFPage()
    }
    context.closePDF()
}

private func createImagePDF(at url: URL, text: String) throws {
    let image = NSImage(size: NSSize(width: 1_200, height: 1_600))
    image.lockFocus()
    NSColor.white.setFill()
    NSRect(origin: .zero, size: image.size).fill()
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.boldSystemFont(ofSize: 64),
        .foregroundColor: NSColor.black
    ]
    text.draw(
        in: NSRect(x: 90, y: 720, width: 1_020, height: 180),
        withAttributes: attributes
    )
    image.unlockFocus()

    guard let page = PDFPage(image: image) else {
        throw PrivateDocSearchError.invalidPDF("Synthetische Bildseite konnte nicht erstellt werden.")
    }
    let document = PDFDocument()
    document.insert(page, at: 0)
    guard document.write(to: url) else {
        throw PrivateDocSearchError.invalidPDF("Synthetische Scan-PDF konnte nicht geschrieben werden.")
    }
}
