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
func nonDestructiveOCRKeepsOriginalAndReturnsRecognizedPages() async throws {
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

    #expect(result.pageCount == 1)
    #expect(try Data(contentsOf: pdf) == before)
    #expect(result.persistedToOriginal == false)
    #expect(result.engine == .tesseract)
    #expect(result.pages.first?.text.uppercased().contains("SYNTHETIC") == true)
    #expect(result.pageQualities.first?.wordCount ?? 0 > 0)
    #expect(FileManager.default.fileExists(atPath: pdf.path))
}

@Test(.timeLimit(.minutes(1)))
func appleVisionOCRKeepsOriginalAndReturnsUnifiedQualityResult() async throws {
    let root = temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let pdf = root.appending(path: "vision-scan.pdf")
    try createImagePDF(at: pdf, text: "APPLE VISION TEST 24680")
    let before = try Data(contentsOf: pdf)

    let result = try await VisionOCRProvider().process(
        discoveredPDF(pdf),
        configuration: OCRConfiguration(
            languages: ["eng"],
            rotatePages: false,
            deskew: false,
            engineSelection: .appleVision
        )
    )

    #expect(result.engine == .appleVision)
    #expect(!result.persistedToOriginal)
    #expect(result.pageCount == 1)
    #expect(result.pages.first?.text.uppercased().contains("VISION") == true)
    #expect(result.pageQualities.first?.meanConfidence != nil)
    #expect(result.pageQualities.first?.recognizedLanguage == "eng")
    #expect(try Data(contentsOf: pdf) == before)
}

@Test
func oldOCRConfigurationDefaultsToAutomaticEngine() throws {
    let data = Data(
        """
        {
          "isEnabled": true,
          "languages": ["deu", "eng"],
          "persistenceMode": "nonDestructive"
        }
        """.utf8
    )
    let configuration = try JSONDecoder().decode(OCRConfiguration.self, from: data)
    #expect(configuration.engineSelection == .automatic)
    #expect(!configuration.requiresTesseractComponents)
    #expect(configuration.initiallyReportedEngine == .appleVision)
}

@Test
func automaticOCRUsesVisionWithoutTesseractAndFallsBackWhenNeeded() async throws {
    let root = temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let pdf = root.appending(path: "router.pdf")
    try createImagePDF(at: pdf, text: "ROUTER TEST")
    let file = discoveredPDF(pdf)
    let probe = OCRProviderProbe()
    let vision = StubOCRProvider(
        engine: .appleVision,
        behavior: .success("IDENTISCHER SUCHTEXT"),
        probe: probe
    )
    let tesseract = StubOCRProvider(
        engine: .tesseract,
        behavior: .success("IDENTISCHER SUCHTEXT"),
        probe: probe
    )

    let dependencyCheckProbe = SynchronousCallProbe()
    let visionOnly = OCRProviderRouter(
        visionProvider: vision,
        tesseractProviderFactory: {
            dependencyCheckProbe.record()
            return tesseract
        }
    )
    let first = try await visionOnly.process(
        file,
        configuration: OCRConfiguration(engineSelection: .automatic)
    )
    #expect(first.engine == .appleVision)
    #expect(await probe.calls(for: .appleVision) == 1)
    #expect(await probe.calls(for: .tesseract) == 0)
    #expect(dependencyCheckProbe.count == 0)

    let failingVision = StubOCRProvider(
        engine: .appleVision,
        behavior: .failure("synthetischer Vision-Fehler"),
        probe: probe
    )
    let automatic = OCRProviderRouter(
        visionProvider: failingVision,
        tesseractProvider: tesseract
    )
    let engineChanges = OCREngineRecorder()
    let fallback = try await automatic.process(
        file,
        configuration: OCRConfiguration(engineSelection: .automatic)
    ) { engine in
        await engineChanges.append(engine)
    }
    #expect(fallback.engine == .tesseract)
    #expect(await engineChanges.values == [.appleVision, .tesseract])
    #expect(fallback.messages.first?.contains("Vision") == true)
    #expect(await probe.calls(for: .tesseract) == 1)
}

@Test
func persistentOCRAlwaysRoutesToTesseract() async throws {
    let root = temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let pdf = root.appending(path: "persistent-router.pdf")
    try createImagePDF(at: pdf, text: "PERSISTENT ROUTER")
    let probe = OCRProviderProbe()
    let router = OCRProviderRouter(
        visionProvider: StubOCRProvider(
            engine: .appleVision,
            behavior: .success("VISION"),
            probe: probe
        ),
        tesseractProvider: StubOCRProvider(
            engine: .tesseract,
            behavior: .success("TESSERACT"),
            probe: probe
        )
    )

    let result = try await router.process(
        discoveredPDF(pdf),
        configuration: OCRConfiguration(
            persistenceMode: .persistent,
            engineSelection: .appleVision
        )
    )

    #expect(result.engine == .tesseract)
    #expect(await probe.calls(for: .appleVision) == 0)
    #expect(await probe.calls(for: .tesseract) == 1)
}

@Test
func OCRProvidersProduceEquivalentSearchResultsAndDatabaseShape() async throws {
    let vision = try await indexedSyntheticOCRResult(engine: .appleVision)
    let tesseract = try await indexedSyntheticOCRResult(engine: .tesseract)

    #expect(vision.resultCount == tesseract.resultCount)
    #expect(vision.excerpt == tesseract.excerpt)
    #expect(vision.pageNumber == tesseract.pageNumber)
    #expect(vision.statistics.totalChunks == tesseract.statistics.totalChunks)
    #expect(vision.statistics.embeddedChunks == tesseract.statistics.embeddedChunks)
    #expect(vision.statistics.ocrProcessedPDFs == tesseract.statistics.ocrProcessedPDFs)
}

@Test(.timeLimit(.minutes(1)))
func persistentOCRAtomicallyAddsValidatedTextLayer() async throws {
    let dependencies = OCRDependencyChecker().check()
    guard dependencies.isReady else { return }
    let root = temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let pdf = root.appending(path: "scan.pdf")
    try createImagePDF(at: pdf, text: "PERSISTENT OCR TEST 67890")
    let before = try Data(contentsOf: pdf)

    let result = try await OCRmyPDFProcessor(dependencies: dependencies).process(
        discoveredPDF(pdf),
        configuration: OCRConfiguration(
            languages: ["eng"],
            rotatePages: false,
            deskew: false,
            persistenceMode: .persistent
        )
    )

    #expect(result.persistedToOriginal)
    #expect(result.engine == .tesseract)
    #expect(try Data(contentsOf: pdf) != before)
    #expect(
        try PDFKitTextExtractor().extractPages(from: pdf)
            .first?.text.uppercased().contains("PERSISTENT") == true
    )
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
    #expect(statistics.indexedPDFs == 2)
}

@Test
func bundledModelCatalogIsPinnedAndFitsEightGigabyteProfile() throws {
    let catalog = try ModelCatalog.bundled()
    #expect(catalog.models.count == 4)
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
    let experimental = try #require(catalog.models.first { $0.id.contains("8B-4bit") })
    #expect(profile.compatibility(for: compact) == .recommended)
    #expect(profile.compatibility(for: larger) == .compatible)
    #expect(profile.compatibility(for: experimental) == .experimental)
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
func ruleBasedSearchPlanRecognizesNicoAndTrainingAsMandatoryContext() throws {
    let planner = RuleBasedSearchPlanner()
    let plan = planner.plan(
        query: "Suche mir Dokumente heraus, die mit Nicos Ausbildung zu tun haben."
    )

    #expect(plan.requiredEntities == ["Nico"])
    #expect(plan.topics == ["Ausbildung"])
    #expect(plan.mustMatchAll)
    #expect(plan.optionalTerms.contains("ausbildungsvertrag"))
    #expect(planner.needsModelPlanning(
        "Suche mir Dokumente heraus, die mit Nicos Ausbildung zu tun haben."
    ))

    let followUp = planner.plan(
        query: "Welche davon betreffen die Probezeit?",
        previousPlan: plan
    )
    #expect(followUp.requiredEntities == ["Nico"])
    #expect(followUp.topics.contains("Ausbildung"))

    let independent = planner.plan(
        query: "Zeige Rechnungen aus 2025",
        previousPlan: plan
    )
    #expect(!independent.requiredEntities.contains("Nico"))
    #expect(independent.topics.contains("Rechnung"))
}

@Test
func invalidOrUnsafeModelPlanFallsBackToRuleBasedPlan() throws {
    let query = "Suche mir Dokumente heraus, die mit Nicos Ausbildung zu tun haben."
    let fallback = RuleBasedSearchPlanner().plan(query: query)
    let invalid = """
    {"intent":"find_documents","required_entities":["Nico"],"sql":"DELETE FROM documents"}
    """
    let resolved = (try? SearchPlanValidator().decode(invalid)) ?? fallback
    #expect(resolved == fallback)

    let unsafe = """
    {
      "intent":"find_documents",
      "required_entities":["Nico"],
      "organizations":[],
      "locations":[],
      "time_ranges":[],
      "amounts":[],
      "document_types":[],
      "topics":["SELECT * FROM chunks"],
      "must_match_all":true,
      "optional_terms":[]
    }
    """
    #expect(throws: SearchPlanValidationError.self) {
        try SearchPlanValidator().decode(unsafe)
    }
}

@Test
func mandatoryEntityFilteringAndRerankingExcludeUnrelatedDocuments() async throws {
    let root = temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        applicationSupport: root.appending(path: "Support"),
        logs: root.appending(path: "Logs")
    )
    let documents: [(String, [String])] = [
        (
            "Ausbildungsvertrag Nico.pdf",
            ["Nico beginnt seine Ausbildung im Ausbildungsbetrieb. Der Ausbildungsvertrag gilt ab September."]
        ),
        ("Nico Freizeit.pdf", ["Nico spielt am Wochenende Fußball im Verein."]),
        ("Ausbildung Laura.pdf", ["Laura beginnt eine Ausbildung und besucht die Berufsschule."]),
        ("Unpassend.pdf", ["Allgemeine Hinweise zum Sommerfest und zur Kantine."]),
        (
            "Nico-Unterlagen.pdf",
            ["Der Ausbildungsbetrieb bestätigt die Berufsausbildung und die Probezeit."]
        ),
        (
            "Getrennte Seiten.pdf",
            [
                "Nico wurde als Ansprechpartner genannt.",
                "Der Ausbildungsvertrag regelt Berufsschule und Probezeit."
            ]
        ),
        (
            "Mehrere Personen.pdf",
            ["Nico und Laura beginnen ihre Ausbildung."]
        )
    ]
    for document in documents {
        try createTextPDF(at: root.appending(path: document.0), pages: document.1)
    }

    let database = SQLiteDatabase(url: paths.database)
    try await database.initialize()
    let scanner = RecursivePDFScanner(excludedRoots: [paths.applicationSupport])
    try await database.saveScan(files: try await scanner.scan(root: root), root: root)
    let embedder = TokenHashEmbedding(dimensions: 64)
    await DocumentProcessor(
        database: database,
        stabilityChecker: FileStabilityChecker(delay: .zero),
        embedder: embedder
    ).processPending(ocrConfiguration: OCRConfiguration(isEnabled: false)) { _ in }

    let query = "Suche mir Dokumente heraus, die mit Nicos Ausbildung zu tun haben."
    let plan = RuleBasedSearchPlanner().plan(query: query)
    let outcome = try await HybridSearchService(database: database, embedder: embedder)
        .search(query, plan: plan, limit: 10)
    let directNames = Set(outcome.directMatches.map(\.fileName))

    #expect(directNames.contains("Ausbildungsvertrag Nico.pdf"))
    #expect(directNames.contains("Nico-Unterlagen.pdf"))
    #expect(directNames.contains("Getrennte Seiten.pdf"))
    #expect(directNames.contains("Mehrere Personen.pdf"))
    #expect(!directNames.contains("Nico Freizeit.pdf"))
    #expect(!directNames.contains("Ausbildung Laura.pdf"))
    #expect(!directNames.contains("Unpassend.pdf"))
    #expect(outcome.directMatches.count < 10)
    #expect(outcome.directMatches.allSatisfy { $0.matchedEntities.contains("Nico") })
    #expect(outcome.directMatches.allSatisfy { !$0.reason.isEmpty })
    #expect(outcome.directMatches.allSatisfy { $0.textSource == "extracted" })

    let sameChunk = try #require(outcome.directMatches.first {
        $0.fileName == "Ausbildungsvertrag Nico.pdf"
    })
    #expect(sameChunk.relevance == .veryRelevant)
    #expect(sameChunk.matchKinds.contains(.sameChunk))

    let sameDocument = try #require(outcome.directMatches.first {
        $0.fileName == "Getrennte Seiten.pdf"
    })
    #expect(sameDocument.relevance == .relevant)
    #expect(sameDocument.matchKinds.contains(.sameDocument))

    let fileNameMatch = try #require(outcome.directMatches.first {
        $0.fileName == "Nico-Unterlagen.pdf"
    })
    #expect(fileNameMatch.matchKinds.contains(.fileName))
    #expect(!outcome.possibleMatches.contains { $0.fileName == "Ausbildung Laura.pdf" })

    let fileNameQuery = "Nico-Unterlagen.pdf"
    let fileNamePlan = RuleBasedSearchPlanner().plan(query: fileNameQuery)
    #expect(fileNamePlan.requiredEntities.contains("Nico-Unterlagen"))
    #expect(
        try await database.fileNameSearch(terms: fileNamePlan.hardTerms, limit: 10)
            .first?.fileName == "Nico-Unterlagen.pdf"
    )
    let fileNameOutcome = try await HybridSearchService(database: database, embedder: embedder)
        .search(
            fileNameQuery,
            plan: fileNamePlan
        )
    #expect(fileNameOutcome.directMatches.first?.fileName == "Nico-Unterlagen.pdf")
}

@Test
func mandatoryNameEvidenceWorksForOCRText() async throws {
    let root = temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        applicationSupport: root.appending(path: "Support"),
        logs: root.appending(path: "Logs")
    )
    let database = SQLiteDatabase(url: paths.database)
    try await database.initialize()
    let pdf = root.appending(path: "Scan ohne Namen im Dateinamen.pdf")
    try createImagePDF(at: pdf, text: "SYNTHETIC SCAN")
    let scanner = RecursivePDFScanner(excludedRoots: [paths.applicationSupport])
    try await database.saveScan(files: try await scanner.scan(root: root), root: root)
    let embedder = TokenHashEmbedding(dimensions: 64)
    await DocumentProcessor(
        database: database,
        stabilityChecker: FileStabilityChecker(delay: .zero),
        embedder: embedder,
        ocrProcessor: StubOCRProvider(
            engine: .appleVision,
            behavior: .success("Nico beginnt seine Ausbildung im Ausbildungsbetrieb"),
            probe: OCRProviderProbe()
        )
    ).processPending(
        ocrConfiguration: OCRConfiguration(engineSelection: .appleVision)
    ) { _ in }

    let query = "Nico Ausbildung"
    let outcome = try await HybridSearchService(database: database, embedder: embedder)
        .search(query, plan: RuleBasedSearchPlanner().plan(query: query))
    let source = try #require(outcome.directMatches.first)
    #expect(source.matchedEntities == ["Nico"])
    #expect(source.matchedTopics == ["Ausbildung"])
    #expect(source.textSource == "ocr")
    #expect(source.ocrQuality == OCRQualityStatus.good.rawValue)
}

@Test
func citationValidationRejectsInventedSourcesAndEmptyEvidence() {
    let validator = SourceCitationValidator()
    let valid = validator.validate(
        "Nico beginnt die Ausbildung [S-001].",
        sourceCount: 1
    )
    #expect(valid.contains("[1]"))
    #expect(
        validator.validate(
            "Nico beginnt die Ausbildung [S-001]. Eine erfundene Quelle [S-999].",
            sourceCount: 1
        ) == SourceCitationValidator.noEvidenceMessage
    )
    #expect(
        validator.validate("Unbelegte Behauptung [S-999].", sourceCount: 1)
            == SourceCitationValidator.noEvidenceMessage
    )
    #expect(
        validator.validate("Beliebige Antwort", sourceCount: 0)
            == SourceCitationValidator.noEvidenceMessage
    )
}

@Test
func searchSessionContextKeepsOnlyRecentPlans() {
    var context = SearchSessionContext(limit: 3)
    for index in 1...5 {
        context.record(
            SearchPlan(
                requiredEntities: ["Person \(index)"],
                topics: ["Thema \(index)"]
            )
        )
    }
    #expect(context.plans.count == 3)
    #expect(context.plans.first?.requiredEntities == ["Person 3"])
    #expect(context.latestPlan?.requiredEntities == ["Person 5"])
    context.reset()
    #expect(context.plans.isEmpty)
}

@Test
func documentStatusDetectsMixedEmbeddingIndex() async throws {
    let root = temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        applicationSupport: root.appending(path: "Support"),
        logs: root.appending(path: "Logs")
    )
    let database = SQLiteDatabase(url: paths.database)
    try await database.initialize()
    let pdf = root.appending(path: "Embeddings.pdf")
    try createTextPDF(
        at: pdf,
        pages: ["GEMISCHTER EMBEDDING INDEX " + String(repeating: "Text ", count: 60)]
    )
    let scanner = RecursivePDFScanner(excludedRoots: [paths.applicationSupport])
    let files = try await scanner.scan(root: root)
    try await database.saveScan(files: files, root: root)
    let fallback = TokenHashEmbedding(dimensions: 64)
    await DocumentProcessor(
        database: database,
        stabilityChecker: FileStabilityChecker(delay: .zero),
        embedder: fallback
    ).processPending(ocrConfiguration: OCRConfiguration(isEnabled: false)) { _ in }

    let file = try #require(files.first)
    let pages = try PDFKitTextExtractor().extractPages(from: pdf)
    let hash = try SHA256Hasher().hash(fileAt: pdf)
    let chunks = PageChunker().chunks(for: pages, documentHash: hash)
    let embeddings = try await fallback.embed(documents: chunks.map(\.text))
    _ = try await database.indexDocument(
        file: file,
        hash: hash,
        pages: pages,
        chunks: chunks,
        embeddings: embeddings,
        embeddingModelID: "multilingual-e5-small",
        embeddingModelVersion: "synthetic-test",
        ocrPerformed: false
    )
    let statistics = try await database.statistics()
    #expect(statistics.fallbackEmbeddedChunks == statistics.totalChunks)
    #expect(statistics.e5EmbeddedChunks == statistics.totalChunks)
    #expect(statistics.totalChunks > 0)
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

@Test
func contentIdentityHandlesCopyMetadataMoveAndChangedContent() async throws {
    let root = temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        applicationSupport: root.appending(path: "Support"),
        logs: root.appending(path: "Logs")
    )
    let database = SQLiteDatabase(url: paths.database)
    try await database.initialize()
    let scanner = RecursivePDFScanner(excludedRoots: [paths.applicationSupport])
    let embedder = TokenHashEmbedding(dimensions: 64)
    let processor = DocumentProcessor(
        database: database,
        stabilityChecker: FileStabilityChecker(delay: .zero),
        embedder: embedder
    )
    let original = root.appending(path: "Original.pdf")
    try createTextPDF(at: original, pages: ["ALPHAIDENTITAET " + String(repeating: "Text ", count: 80)])

    var files = try await scanner.scan(root: root)
    try await database.saveScan(files: files, root: root)
    await processor.processPending(ocrConfiguration: OCRConfiguration(isEnabled: false)) { _ in }
    let initial = try await database.embeddingCoverage(
        modelID: embedder.modelID,
        modelVersion: embedder.modelVersion
    )

    let copy = root.appending(path: "Kopie.pdf")
    try FileManager.default.copyItem(at: original, to: copy)
    files = try await scanner.scan(root: root)
    try await database.saveScan(files: files, root: root)
    await processor.processPending(ocrConfiguration: OCRConfiguration(isEnabled: false)) { _ in }
    let afterCopy = try await database.embeddingCoverage(
        modelID: embedder.modelID,
        modelVersion: embedder.modelVersion
    )
    #expect(afterCopy == initial)
    #expect((try await database.statistics()).totalPDFs == 2)

    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(120)],
        ofItemAtPath: copy.path
    )
    files = try await scanner.scan(root: root)
    try await database.saveScan(files: files, root: root)
    await processor.processPending(ocrConfiguration: OCRConfiguration(isEnabled: false)) { _ in }
    #expect(
        try await database.embeddingCoverage(
            modelID: embedder.modelID,
            modelVersion: embedder.modelVersion
        ) == initial
    )

    let movedFolder = root.appending(path: "Unterordner", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: movedFolder, withIntermediateDirectories: true)
    let moved = movedFolder.appending(path: "Verschoben.pdf")
    try FileManager.default.moveItem(at: original, to: moved)
    files = try await scanner.scan(root: root)
    try await database.saveScan(files: files, root: root)
    await processor.processPending(ocrConfiguration: OCRConfiguration(isEnabled: false)) { _ in }
    #expect(
        try await database.embeddingCoverage(
            modelID: embedder.modelID,
            modelVersion: embedder.modelVersion
        ) == initial
    )

    try FileManager.default.removeItem(at: copy)
    try FileManager.default.removeItem(at: moved)
    try createTextPDF(at: moved, pages: ["BETAINHALT " + String(repeating: "Neu ", count: 80)])
    files = try await scanner.scan(root: root)
    try await database.saveScan(files: files, root: root)
    await processor.processPending(ocrConfiguration: OCRConfiguration(isEnabled: false)) { _ in }
    let search = HybridSearchService(database: database, embedder: embedder)
    #expect((try await search.search("ALPHAIDENTITAET")).isEmpty)
    #expect(!(try await search.search("BETAINHALT")).isEmpty)
    #expect((try await database.statistics()).totalPDFs == 1)
}

@Test
func switchingOCRModeDoesNotReprocessKnownDocument() async throws {
    let root = temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        applicationSupport: root.appending(path: "Support"),
        logs: root.appending(path: "Logs")
    )
    let database = SQLiteDatabase(url: paths.database)
    try await database.initialize()
    let pdf = root.appending(path: "Scan.pdf")
    try createImagePDF(at: pdf, text: "MODE SWITCH")
    let original = try Data(contentsOf: pdf)
    let replacement = root.appending(path: "Replacement.pdf")
    try createTextPDF(at: replacement, pages: [String(repeating: "Erkannter Text ", count: 30)])
    let replacementData = try Data(contentsOf: replacement)
    try FileManager.default.removeItem(at: replacement)
    let probe = OCRConcurrencyProbe()
    let scanner = RecursivePDFScanner(excludedRoots: [paths.applicationSupport])
    let processor = DocumentProcessor(
        database: database,
        stabilityChecker: FileStabilityChecker(delay: .zero),
        embedder: TokenHashEmbedding(dimensions: 64),
        ocrProcessorFactory: {
            SyntheticOCRProcessor(replacementData: replacementData, probe: probe)
        }
    )

    var files = try await scanner.scan(root: root)
    try await database.saveScan(files: files, root: root)
    await processor.processPending(
        ocrConfiguration: OCRConfiguration(persistenceMode: .nonDestructive)
    ) { _ in }
    files = try await scanner.scan(root: root)
    try await database.saveScan(files: files, root: root)
    await processor.processPending(
        ocrConfiguration: OCRConfiguration(persistenceMode: .persistent)
    ) { _ in }

    #expect(await probe.calls == 1)
    #expect(try Data(contentsOf: pdf) == original)

    try await database.resetOCRData()
    #expect((try await database.statistics()).indexedPDFs == 0)
    #expect((try await database.pendingFiles()).count == 1)
    #expect(try Data(contentsOf: pdf) == original)
}

@Test
func indexMaintenanceRebuildsFromStoredTextAndPreservesSettings() async throws {
    let root = temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        applicationSupport: root.appending(path: "Support"),
        logs: root.appending(path: "Logs")
    )
    let database = SQLiteDatabase(url: paths.database)
    try await database.initialize()
    try await database.setSetting(key: "test-setting", value: "bleibt")
    let pdf = root.appending(path: "Wartung.pdf")
    try createTextPDF(
        at: pdf,
        pages: ["WARTUNGSBEGRIFF " + String(repeating: "Gespeicherter Seitentext. ", count: 30)]
    )
    let scanner = RecursivePDFScanner(excludedRoots: [paths.applicationSupport])
    let files = try await scanner.scan(root: root)
    try await database.saveScan(files: files, root: root)
    let embedder = TokenHashEmbedding(dimensions: 64)
    let processor = DocumentProcessor(
        database: database,
        stabilityChecker: FileStabilityChecker(delay: .zero),
        embedder: embedder
    )
    await processor.processPending(ocrConfiguration: OCRConfiguration(isEnabled: false)) { _ in }

    try await processor.rebuildSearchIndex { _ in }
    let search = HybridSearchService(database: database, embedder: embedder)
    #expect(!(try await search.search("WARTUNGSBEGRIFF")).isEmpty)
    #expect((try await database.repairIndex()).contains("Integrität"))

    try await database.deleteDocumentIndex()
    #expect((try await database.statistics()).totalPDFs == 0)
    #expect(try await database.setting(key: "test-setting") == "bleibt")
    #expect(FileManager.default.fileExists(atPath: pdf.path))
}

@Test
func persistentStatusEventsAndSnapshotsTrackLiveProcessing() async throws {
    let root = temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        applicationSupport: root.appending(path: "Support"),
        logs: root.appending(path: "Logs")
    )
    let database = SQLiteDatabase(url: paths.database)
    try await database.initialize()
    let changes = await database.statusChanges()
    let firstEvent = Task {
        var iterator = changes.makeAsyncIterator()
        return await iterator.next()
    }
    let pdf = root.appending(path: "Live.pdf")
    try createTextPDF(
        at: pdf,
        pages: ["LIVE STATUS " + String(repeating: "Persistenter Text. ", count: 30)]
    )
    let scanner = RecursivePDFScanner(excludedRoots: [paths.applicationSupport])
    var files = try await scanner.scan(root: root)
    let eventStart = ContinuousClock.now
    try await database.saveScan(files: files, root: root)
    #expect(await firstEvent.value == .scanCompleted)
    #expect(eventStart.duration(to: .now) < .milliseconds(500))

    var status = try await database.statistics()
    #expect(status.totalPDFs == 1)
    #expect(status.pendingJobs == 1)
    #expect(status.processingJobs == 0)
    #expect(status.currentStep == ProcessingState.discovered.displayName)
    #expect(status.currentFile == "Live.pdf")

    let embedder = TokenHashEmbedding(dimensions: 64)
    let processor = DocumentProcessor(
        database: database,
        stabilityChecker: FileStabilityChecker(delay: .zero),
        embedder: embedder
    )
    await processor.processPending(ocrConfiguration: OCRConfiguration(isEnabled: false)) { _ in }
    status = try await database.statistics()
    #expect(status.indexedPDFs == 1)
    #expect(status.searchablePDFs == 1)
    #expect(status.withoutTextLayerPDFs == 0)
    #expect(status.totalChunks > 0)
    #expect(status.embeddedChunks == status.totalChunks)
    #expect(status.fallbackEmbeddedChunks == status.totalChunks)
    #expect(status.e5EmbeddedChunks == 0)
    #expect(status.processedJobs == status.totalJobs)
    #expect(status.progressFraction == 1)
    #expect(status.lastSuccessfulStep?.contains("Live.pdf") == true)

    let copy = root.appending(path: "Live-Kopie.pdf")
    try FileManager.default.copyItem(at: pdf, to: copy)
    files = try await scanner.scan(root: root)
    try await database.saveScan(files: files, root: root)
    await processor.processPending(ocrConfiguration: OCRConfiguration(isEnabled: false)) { _ in }
    status = try await database.statistics()
    #expect(status.totalPDFs == 2)
    #expect(status.indexedPDFs == 2)
    #expect(status.duplicateLocations == 1)

    let failing = root.appending(path: "OCR-Fehler.pdf")
    try createImagePDF(at: failing, text: "SYNTHETIC FAILURE")
    let waiting = root.appending(path: "Wartend.pdf")
    try createTextPDF(at: waiting, pages: ["Noch nicht verarbeitet"])
    files = try await scanner.scan(root: root)
    try await database.saveScan(files: files, root: root)
    try await database.updateJob(
        path: failing.path,
        state: .ocrRunning,
        ocrEngine: .appleVision
    )
    status = try await database.statistics()
    #expect(status.currentOCREngine == OCREngine.appleVision.displayName)
    try await database.updateJob(
        path: failing.path,
        state: .failed,
        error: "Synthetischer OCR-Fehler ohne Dokumentinhalt"
    )
    status = try await database.statistics()
    #expect(status.ocrFailedPDFs == 1)
    #expect(status.failedJobs == 1)
    #expect(status.lastProcessingError?.contains("Synthetischer OCR-Fehler") == true)
    try await database.saveScan(files: files, root: root)
    status = try await database.statistics()
    #expect(status.ocrFailedPDFs == 1)
    #expect(status.failedJobs == 1)

    let pauseChanges = await database.statusChanges()
    let pauseEvent = Task {
        var iterator = pauseChanges.makeAsyncIterator()
        return await iterator.next()
    }
    try await database.setProcessingPaused(true)
    #expect(await pauseEvent.value == .processingPaused)
    status = try await database.statistics()
    #expect(status.isPaused)
    #expect(status.pausedJobs >= 1)

    let reopened = SQLiteDatabase(url: paths.database)
    try await reopened.initialize()
    let reconstructed = try await reopened.statistics()
    #expect(reconstructed == status)
    #expect(reconstructed.isPaused)
    #expect(reconstructed.ocrFailedPDFs == 1)
}

@Test
func finderSafeToolResolutionAndMissingInstallerAreDeterministic() async throws {
    let dependencies = OCRDependencyChecker().check()
    #expect(dependencies.environmentPATH.hasPrefix("/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"))
    #expect(OCRDependencyChecker().check().ocrMyPDF == dependencies.ocrMyPDF)
    #expect(
        OCRComponentInstaller.packageArguments
            == ["install", "ocrmypdf", "tesseract-lang", "poppler"]
    )

    let missing = OCRDependencies(
        homebrew: nil,
        ocrMyPDF: nil,
        tesseract: nil,
        pdfText: nil,
        pdfInfo: nil,
        pdfToPPM: nil,
        environmentPATH: "/usr/bin:/bin",
        installedLanguages: [],
        versions: [:],
        selfTestPassed: false,
        messages: ["Homebrew fehlt."]
    )
    do {
        _ = try await OCRComponentInstaller().installMissing(from: missing)
        Issue.record("Installation ohne Homebrew hätte abgewiesen werden müssen.")
    } catch {
        #expect(error.localizedDescription.contains("Homebrew"))
    }
}

@Test
func bundledCatalogDetectsAnOlderInstalledModelVersion() async throws {
    let root = temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        applicationSupport: root.appending(path: "Support"),
        logs: root.appending(path: "Logs")
    )
    let catalog = try ModelCatalog.bundled()
    let descriptor = try #require(catalog.models.first)
    let old = paths.models
        .appending(path: descriptor.id.replacingOccurrences(of: "/", with: "_"))
        .appending(path: "older-app-catalog-version")
    try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
    let manager = LocalModelManager(catalog: catalog, paths: paths)
    let profile = HardwareProfile(
        isAppleSilicon: true,
        chipName: "Test",
        physicalMemoryBytes: 8_589_934_592,
        availableStorageBytes: 100_000_000_000
    )
    let model = try #require(await manager.models(profile: profile).first)
    #expect(model.updateAvailable)
    #expect(model.installedVersion == "older-app-catalog-version")
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
    private(set) var calls = 0

    func begin() {
        active += 1
        calls += 1
        peak = max(peak, active)
    }

    func end() {
        active -= 1
    }
}

private enum StubOCRBehavior: Sendable {
    case success(String)
    case failure(String)
}

private actor OCRProviderProbe {
    private var callCounts: [OCREngine: Int] = [:]

    func record(_ engine: OCREngine) {
        callCounts[engine, default: 0] += 1
    }

    func calls(for engine: OCREngine) -> Int {
        callCounts[engine, default: 0]
    }
}

private actor OCREngineRecorder {
    private(set) var values: [OCREngine] = []

    func append(_ engine: OCREngine) {
        values.append(engine)
    }
}

private final class SynchronousCallProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0

    var count: Int {
        lock.withLock { storedCount }
    }

    func record() {
        lock.withLock {
            storedCount += 1
        }
    }
}

private struct StubOCRProvider: OCRProvider {
    let engine: OCREngine
    let behavior: StubOCRBehavior
    let probe: OCRProviderProbe

    func process(
        _ file: DiscoveredPDF,
        configuration: OCRConfiguration
    ) async throws -> OCRResult {
        await probe.record(engine)
        switch behavior {
        case .failure(let message):
            throw PrivateDocSearchError.processFailed(message)
        case .success(let text):
            let page = ExtractedPage(
                pageNumber: 1,
                text: String(repeating: "\(text) ", count: 20)
            )
            let hash = try SHA256Hasher().hash(fileAt: file.url)
            return OCRResult(
                inputHash: hash,
                outputHash: hash,
                pageCount: 1,
                pages: [page],
                persistedToOriginal: configuration.persistenceMode == .persistent,
                pageQualities: OCRQualityEvaluator().evaluate(
                    pages: [page],
                    configuredLanguages: configuration.languages,
                    meanConfidences: [1: 92]
                ),
                engine: engine,
                duration: .milliseconds(1),
                completedAt: .now
            )
        }
    }
}

private func indexedSyntheticOCRResult(
    engine: OCREngine
) async throws -> (
    resultCount: Int,
    excerpt: String?,
    pageNumber: Int?,
    statistics: DocumentStatistics
) {
    let root = temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        applicationSupport: root.appending(path: "Support"),
        logs: root.appending(path: "Logs")
    )
    let database = SQLiteDatabase(url: paths.database)
    try await database.initialize()
    let pdf = root.appending(path: "Engine-\(engine.rawValue).pdf")
    try createImagePDF(at: pdf, text: "ENGINE SEARCH")
    let scanner = RecursivePDFScanner(excludedRoots: [paths.applicationSupport])
    try await database.saveScan(files: try await scanner.scan(root: root), root: root)
    let embedder = TokenHashEmbedding(dimensions: 64)
    let processor = DocumentProcessor(
        database: database,
        stabilityChecker: FileStabilityChecker(delay: .zero),
        embedder: embedder,
        ocrProcessor: StubOCRProvider(
            engine: engine,
            behavior: .success("GEMEINSAMER ENGINE SUCHBEGRIFF"),
            probe: OCRProviderProbe()
        )
    )
    await processor.processPending(
        ocrConfiguration: OCRConfiguration(
            languages: ["deu"],
            engineSelection: engine == .appleVision ? .appleVision : .tesseractOCRmyPDF
        )
    ) { _ in }
    let results = try await HybridSearchService(database: database, embedder: embedder)
        .search("GEMEINSAMER ENGINE SUCHBEGRIFF")
    return (
        results.count,
        results.first?.excerpt,
        results.first?.pageNumber,
        try await database.statistics()
    )
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
            if configuration.persistenceMode == .persistent {
                try replacementData.write(to: file.url, options: .atomic)
            }
            await probe.end()
        } catch {
            await probe.end()
            throw error
        }
        return OCRResult(
            inputHash: inputHash,
            outputHash: SHA256Hasher().hash(data: replacementData),
            pageCount: 1,
            pages: [
                ExtractedPage(
                    pageNumber: 1,
                    text: String(repeating: "Synthetischer Text für den Parallelitätstest. ", count: 5)
                )
            ],
            persistedToOriginal: configuration.persistenceMode == .persistent,
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
