import Foundation

public actor DocumentProcessor {
    public struct Progress: Sendable {
        public let currentFile: String?
        public let completed: Int
        public let total: Int

        public init(currentFile: String?, completed: Int, total: Int) {
            self.currentFile = currentFile
            self.completed = completed
            self.total = total
        }
    }

    private nonisolated let database: SQLiteDatabase
    private nonisolated let stabilityChecker: any FileStabilityChecking
    private nonisolated let extractor: PDFKitTextExtractor
    private nonisolated let chunker: any Chunking
    private nonisolated let embedder: any EmbeddingProviding
    private nonisolated let hasher: SHA256Hasher
    private nonisolated let pageContentAnalyzer: PageContentAnalyzer
    private nonisolated let ocrProcessor: (any OCRProcessing)?
    private nonisolated let ocrProcessorFactory: (@Sendable () -> any OCRProcessing)?
    private nonisolated let fileLogger: AppFileLogger?
    private var isPaused = false

    public init(
        database: SQLiteDatabase,
        stabilityChecker: any FileStabilityChecking = FileStabilityChecker(),
        extractor: PDFKitTextExtractor = PDFKitTextExtractor(),
        chunker: any Chunking = PageChunker(),
        embedder: any EmbeddingProviding,
        hasher: SHA256Hasher = SHA256Hasher(),
        pageContentAnalyzer: PageContentAnalyzer = PageContentAnalyzer(),
        ocrProcessor: (any OCRProcessing)? = nil,
        ocrProcessorFactory: (@Sendable () -> any OCRProcessing)? = nil,
        fileLogger: AppFileLogger? = nil
    ) {
        self.database = database
        self.stabilityChecker = stabilityChecker
        self.extractor = extractor
        self.chunker = chunker
        self.embedder = embedder
        self.hasher = hasher
        self.pageContentAnalyzer = pageContentAnalyzer
        self.ocrProcessor = ocrProcessor
        self.ocrProcessorFactory = ocrProcessorFactory
        self.fileLogger = fileLogger
    }

    public func setPaused(_ paused: Bool) {
        isPaused = paused
    }

    public func rebuildSearchIndex(
        onProgress: @Sendable (Progress) async -> Void
    ) async throws {
        let documents = try await database.storedDocumentTexts()
        var rebuilt: [RebuiltDocumentIndex] = []
        rebuilt.reserveCapacity(documents.count)
        for (offset, document) in documents.enumerated() {
            try Task.checkCancellation()
            let chunks = chunker.chunks(
                for: document.pages,
                documentHash: document.contentHash
            )
            let embeddings = try await embedder.embed(documents: chunks.map(\.text))
            rebuilt.append(
                RebuiltDocumentIndex(
                    document: document,
                    chunks: chunks,
                    embeddings: embeddings
                )
            )
            await onProgress(
                Progress(
                    currentFile: nil,
                    completed: offset + 1,
                    total: documents.count
                )
            )
        }
        try await database.replaceEntireSearchIndex(
            with: rebuilt,
            embeddingModelID: embedder.modelID,
            embeddingModelVersion: embedder.modelVersion
        )
        try? await fileLogger?.log(
            .info,
            category: "Indexwartung",
            message: "Suchindex wurde vollständig aus dem gespeicherten Datenbanktext neu aufgebaut."
        )
    }

    public func updatePageText(
        path: String,
        pageNumber: Int,
        text: String,
        kind: PageTextKind
    ) async throws {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind != .automatic, normalized.isEmpty {
            throw PrivateDocSearchError.processFailed(
                "Manuell geprüfter Seitentext darf nicht leer sein."
            )
        }
        guard let document = try await database.storedDocumentText(path: path) else {
            throw PrivateDocSearchError.database(
                "Das Dokument ist nicht mehr im aktiven Index vorhanden."
            )
        }
        guard try hasher.hash(fileAt: URL(filePath: path))
                == (document.currentFileHash ?? document.contentHash) else {
            throw PrivateDocSearchError.unstableFile(path)
        }
        let page = ExtractedPage(pageNumber: pageNumber, text: normalized)
        let chunks = chunker.chunks(
            for: [page],
            documentHash: document.contentHash
        )
        let embeddings = try await embedder.embed(documents: chunks.map(\.text))
        try await database.replacePageTextAndIndex(
            path: path,
            pageNumber: pageNumber,
            text: normalized,
            textKind: kind,
            chunks: chunks,
            embeddings: embeddings,
            embeddingModelID: embedder.modelID,
            embeddingModelVersion: embedder.modelVersion
        )
    }

    public func retryOCRPage(
        path: String,
        pageNumber: Int,
        configuration: OCRConfiguration,
        onProgress: @Sendable (Int, Int, OCRRetryStrategy) async -> Void
    ) async throws -> OCRRetryOutcome {
        guard let selectedOCRProcessor = ocrProcessorFactory?() ?? ocrProcessor else {
            throw PrivateDocSearchError.dependencyMissing(
                "OCR-Verarbeitung ist nicht verfügbar."
            )
        }
        let url = URL(filePath: path)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let hash = try hasher.hash(fileAt: url)
        guard let stored = try await database.storedDocumentText(path: path),
              (stored.currentFileHash ?? stored.contentHash) == hash else {
            throw PrivateDocSearchError.unstableFile(path)
        }
        let file = DiscoveredPDF(
            url: url,
            relativePath: url.lastPathComponent,
            fileName: url.lastPathComponent,
            size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            modifiedAt: attributes[.modificationDate] as? Date ?? .now,
            resourceIdentifier: nil,
            volumeIdentifier: nil
        )
        let analyses = try pageContentAnalyzer.analyze(
            fileAt: url,
            textPages: stored.pages
        )
        let manualStrategies = configuration.retryStrategyID.map { strategyID in
            [
                OCRRetryStrategy(
                    id: strategyID,
                    displayName: "Manuelle Einstellungen",
                    preprocessing: "Benutzerdefinierte Einzelseiten-Nachbearbeitung",
                    renderDPI: configuration.renderDPI,
                    enhanceContrast: configuration.enhanceContrast,
                    binarize: configuration.binarize,
                    adaptiveBinarize: configuration.adaptiveBinarize,
                    backgroundLightening: configuration.backgroundLightening,
                    reduceShadows: configuration.reduceShadows,
                    denoise: configuration.denoise,
                    sharpen: configuration.sharpen,
                    cropBorders: configuration.cropBorders,
                    rotatePages: configuration.rotatePages,
                    deskew: configuration.deskew,
                    languages: configuration.languages,
                    engineSelection: configuration.engineSelection
                )
            ]
        }
        let outcome = try await OCRRetryCoordinator(
            provider: selectedOCRProcessor,
            baseConfiguration: configuration,
            strategies: manualStrategies
        ).run(
            file: file,
            baseConfiguration: configuration,
            pageAnalyses: analyses.filter { $0.pageNumber == pageNumber },
            onProgress: onProgress
        )
        await logOCRRetryOutcome(outcome, path: path)
        try await database.saveOCRAttempts(
            path: path,
            originalHash: hash,
            attempts: outcome.attempts.filter { $0.pageNumber == pageNumber },
            bestStrategyByPage: outcome.bestStrategyByPage.filter {
                $0.key == pageNumber
            }
        )
        let pageAttempts = outcome.attempts.filter { $0.pageNumber == pageNumber }
        let accepted = outcome.acceptedPageNumbers.contains(pageNumber)
        let shouldApplyAutomatically = configuration.retryStrategyID == nil
        try await database.applyOCRPageStatuses(
            path: path,
            acceptedPageNumbers: accepted && shouldApplyAutomatically
                ? [pageNumber]
                : [],
            attemptedPageNumbers: [pageNumber],
            pagesWithAnyText: pageAttempts.contains {
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } ? [pageNumber] : []
        )
        if accepted,
           shouldApplyAutomatically,
           let best = pageAttempts.max(by: {
               $0.qualityScore < $1.qualityScore
           }) {
            try await updatePageText(
                path: path,
                pageNumber: pageNumber,
                text: best.text,
                kind: .automatic
            )
        }
        return outcome
    }

    public func processPending(
        ocrConfiguration: OCRConfiguration,
        onProgress: @Sendable (Progress) async -> Void
    ) async {
        do {
            let files = try await database.pendingFiles(limit: 10_000)
            var completed = 0
            var nextIndex = 0
            let limit = Self.parallelism(for: ocrConfiguration)

            await withTaskGroup(of: String.self) { group in
                func enqueueNext() {
                    guard nextIndex < files.count else { return }
                    let file = files[nextIndex]
                    nextIndex += 1
                    group.addTask { [self] in
                        await processAndRecord(file, ocrConfiguration: ocrConfiguration)
                        return file.fileName
                    }
                }

                for _ in 0..<min(limit, files.count) {
                    enqueueNext()
                }

                while let fileName = await group.next() {
                    completed += 1
                    await onProgress(
                        Progress(currentFile: fileName, completed: completed, total: files.count)
                    )
                    if isPaused || Task.isCancelled {
                        group.cancelAll()
                    } else {
                        enqueueNext()
                    }
                }
            }
            try await database.removeDocumentsWithoutActiveLocations()
            await onProgress(Progress(currentFile: nil, completed: completed, total: files.count))
        } catch {
            try? await database.recordError(category: "Indexierung", message: error.localizedDescription)
            try? await fileLogger?.log(
                .error,
                category: "Indexierung",
                message: error.localizedDescription
            )
        }
    }

    private nonisolated func processAndRecord(
        _ file: DiscoveredPDF,
        ocrConfiguration: OCRConfiguration
    ) async {
        do {
            try await process(file, ocrConfiguration: ocrConfiguration)
        } catch is CancellationError {
            try? await database.updateJob(path: file.id, state: .discovered)
        } catch {
            try? await database.updateJob(path: file.id, state: .failed, error: error.localizedDescription)
            try? await database.recordError(
                category: "Indexierung",
                message: error.localizedDescription,
                path: file.url.path
            )
            try? await fileLogger?.log(
                .error,
                category: "Indexierung",
                message: error.localizedDescription,
                path: file.url.path
            )
        }
    }

    private nonisolated func process(
        _ file: DiscoveredPDF,
        ocrConfiguration: OCRConfiguration
    ) async throws {
        try await database.updateJob(path: file.id, state: .waitingForStability)
        var stable = try await stabilityChecker.waitUntilStable(file)
        let inputHash = try hasher.hash(fileAt: stable.url)
        let manualPageTexts = Dictionary(
            uniqueKeysWithValues: try await database.manualPageTexts(
                path: stable.url.path
            ).map { ($0.pageNumber, $0) }
        )
        try await database.updateObservedHash(path: file.id, hash: inputHash)
        if try await database.reuseIndexedDocument(file: stable, observedHash: inputHash) {
            try await database.copyPageContentAnalyses(
                originalHash: inputHash,
                toPath: stable.url.path
            )
            try? await fileLogger?.log(
                .info,
                category: "Indexierung",
                message: "Bekanntes Dokument anhand des Inhalts wiederverwendet.",
                path: stable.url.path
            )
            return
        }

        try await database.updateJob(path: file.id, state: .extracting)
        var pages = try extractor.extractPages(from: stable.url)
        let originalExtractedPages = pages
        let initialPageAnalyses = try pageContentAnalyzer.analyze(
            fileAt: stable.url,
            textPages: pages
        )
        try await database.replacePageContentAnalyses(
            path: stable.url.path,
            originalHash: inputHash,
            analyses: initialPageAnalyses
        )
        var ocrPerformed = false
        var ocrPageNumbers: Set<Int> = []
        var currentFileHash = inputHash
        var pageQualities: [OCRPageQuality] = []

        let needsOCR = !extractor.hasUsableTextLayer(pages)
            || extractor.needsMixedDocumentOCR(pages)
        if needsOCR, ocrConfiguration.isEnabled {
            guard let selectedOCRProcessor = ocrProcessorFactory?() ?? ocrProcessor else {
                throw PrivateDocSearchError.dependencyMissing("OCR-Verarbeitung ist nicht verfügbar.")
            }
            try await database.updateJob(
                path: file.id,
                state: .ocrRunning,
                ocrEngine: ocrConfiguration.initiallyReportedEngine
            )
            try? await fileLogger?.log(
                .info,
                category: "OCR",
                message: ocrConfiguration.persistenceMode == .nonDestructive
                    ? "Nicht-destruktive OCR wurde gestartet."
                    : "Persistente OCR wurde gestartet.",
                path: stable.url.path
            )
            let retryOutcome = try await OCRRetryCoordinator(
                provider: selectedOCRProcessor,
                baseConfiguration: ocrConfiguration
            ).run(
                file: stable,
                baseConfiguration: ocrConfiguration,
                pageAnalyses: initialPageAnalyses
            ) { [database] attempt, total, strategy in
                try? await database.updateOCRRetryProgress(
                    path: file.id,
                    attempt: attempt,
                    total: total,
                    strategy: strategy.displayName
                )
            }
            ocrPageNumbers = retryOutcome.acceptedPageNumbers
            await logOCRRetryOutcome(retryOutcome, path: stable.url.path)
            try await database.saveOCRAttempts(
                path: file.id,
                originalHash: inputHash,
                attempts: retryOutcome.attempts,
                bestStrategyByPage: retryOutcome.bestStrategyByPage
            )
            let originalTextsByPage = Dictionary(
                uniqueKeysWithValues: originalExtractedPages.map {
                    ($0.pageNumber, $0.text)
                }
            )
            let attemptedPages = Set(initialPageAnalyses.compactMap { analysis in
                let originalCharacters = originalTextsByPage[analysis.pageNumber]?
                    .filter { !$0.isWhitespace }
                    .count ?? 0
                return analysis.status != .safelyEmpty && originalCharacters < 20
                    ? analysis.pageNumber
                    : nil
            })
            let pagesWithAnyText = Set(retryOutcome.attempts.compactMap {
                $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil
                    : $0.pageNumber
            })
            try await database.applyOCRPageStatuses(
                path: file.id,
                acceptedPageNumbers: retryOutcome.acceptedPageNumbers,
                attemptedPageNumbers: attemptedPages,
                pagesWithAnyText: pagesWithAnyText
            )
            var result: OCRResult
            if let retryResult = retryOutcome.result {
                result = retryResult
            } else {
                pages = originalExtractedPages
                pageQualities = []
                try? await fileLogger?.log(
                    .warning,
                    category: "OCR-Nachbearbeitung",
                    message: "Automatische OCR-Nachbearbeitung ohne ausreichendes Ergebnis.",
                    path: stable.url.path
                )
                try await database.updateOCRRetryProgress(
                    path: file.id,
                    attempt: retryOutcome.completedAttemptCount,
                    total: retryOutcome.completedAttemptCount,
                    strategy: "Ohne ausreichendes Ergebnis"
                )
                result = OCRResult(
                    inputHash: inputHash,
                    outputHash: inputHash,
                    pageCount: originalExtractedPages.count,
                    pages: originalExtractedPages,
                    persistedToOriginal: false,
                    completedAt: .now
                )
            }
            let originalByPage = Dictionary(uniqueKeysWithValues: originalExtractedPages.map {
                ($0.pageNumber, $0.text)
            })
            pages = result.pages.map { page in
                if retryOutcome.acceptedPageNumbers.contains(page.pageNumber) {
                    return page
                }
                return ExtractedPage(
                    pageNumber: page.pageNumber,
                    text: originalByPage[page.pageNumber] ?? ""
                )
            }
            pageQualities = result.pageQualities.filter {
                retryOutcome.acceptedPageNumbers.contains($0.pageNumber)
            }
            if ocrConfiguration.persistenceMode == .persistent,
               !retryOutcome.acceptedPageNumbers.isEmpty {
                let preferred = retryOutcome.attempts
                    .filter { attempt in
                        retryOutcome.bestStrategyByPage[attempt.pageNumber]?.id
                            == attempt.strategy.id
                    }
                    .max { lhs, rhs in
                        lhs.qualityScore < rhs.qualityScore
                    }?
                    .strategy
                if let preferred {
                    var persistentConfiguration = preferred.configuration(
                        from: ocrConfiguration
                    )
                    persistentConfiguration.persistenceMode = .persistent
                    persistentConfiguration.engineSelection = .tesseractOCRmyPDF
                    result = try await selectedOCRProcessor.process(
                        stable,
                        configuration: persistentConfiguration
                    )
                    pages = result.pages
                    pageQualities = result.pageQualities
                }
            }
            try await database.updateJob(
                path: file.id,
                state: .ocrRunning,
                ocrEngine: result.engine
            )
            ocrPerformed = true
            if result.persistedToOriginal {
                let attributes = try FileManager.default.attributesOfItem(atPath: stable.url.path)
                stable = DiscoveredPDF(
                    url: stable.url,
                    relativePath: stable.relativePath,
                    fileName: stable.fileName,
                    size: (attributes[.size] as? NSNumber)?.int64Value ?? stable.size,
                    modifiedAt: attributes[.modificationDate] as? Date ?? stable.modifiedAt,
                    resourceIdentifier: stable.resourceIdentifier,
                    volumeIdentifier: stable.volumeIdentifier,
                    isLocallyAvailable: true
                )
                currentFileHash = result.outputHash
            }
            try? await fileLogger?.log(
                .info,
                category: "OCR",
                message: "\(result.engine.displayName): " + (result.persistedToOriginal
                    ? "OCR wurde validiert und atomar in die PDF übernommen."
                    : "OCR wurde validiert; Text wird nur in der Datenbank gespeichert."),
                path: stable.url.path
            )
            for message in result.messages {
                try? await fileLogger?.log(
                    .warning,
                    category: "OCR-Fallback",
                    message: message,
                    path: stable.url.path
                )
            }
            let good = result.pageQualities.filter { $0.status == .good }.count
            let review = result.pageQualities.filter { $0.status == .review }.count
            let failed = result.pageQualities.filter { $0.status == .likelyFailed }.count
            try? await fileLogger?.log(
                failed > 0 ? .warning : .info,
                category: "OCR-Qualität",
                message: "Seiten: gut=\(good), prüfen=\(review), wahrscheinlich fehlgeschlagen=\(failed).",
                path: stable.url.path
            )
            try await database.replacePageContentAnalyses(
                path: stable.url.path,
                originalHash: inputHash,
                analyses: try pageContentAnalyzer.analyze(
                    fileAt: stable.url,
                    textPages: pages,
                    ocrQualities: pageQualities
                )
            )
            try await database.applyOCRPageStatuses(
                path: file.id,
                acceptedPageNumbers: retryOutcome.acceptedPageNumbers,
                attemptedPageNumbers: attemptedPages,
                pagesWithAnyText: pagesWithAnyText
            )
        }

        try await database.updateJob(path: file.id, state: .indexing)
        if !manualPageTexts.isEmpty {
            let automaticPages = Dictionary(
                uniqueKeysWithValues: pages.map { ($0.pageNumber, $0) }
            )
            pages = (1...max(
                pages.map(\.pageNumber).max() ?? 0,
                manualPageTexts.keys.max() ?? 0
            )).map { pageNumber in
                if let manual = manualPageTexts[pageNumber] {
                    return ExtractedPage(
                        pageNumber: pageNumber,
                        text: manual.text
                    )
                }
                return automaticPages[pageNumber]
                    ?? ExtractedPage(pageNumber: pageNumber, text: "")
            }
        }
        let unchangedIdentityHash = inputHash
        let chunks = chunker.chunks(for: pages, documentHash: unchangedIdentityHash)
        let embeddings = try await embedder.embed(documents: chunks.map(\.text))
        _ = try await database.indexDocument(
            file: stable,
            hash: unchangedIdentityHash,
            currentFileHash: currentFileHash,
            pages: pages,
            chunks: chunks,
            embeddings: embeddings,
            embeddingModelID: embedder.modelID,
            embeddingModelVersion: embedder.modelVersion,
            ocrPerformed: ocrPerformed,
            ocrPageNumbers: ocrPageNumbers,
            pageQualities: pageQualities,
            textLayerPresent: extractor.hasUsableTextLayer(pages),
            manualPageTexts: manualPageTexts
        )
    }

    private static func parallelism(for configuration: OCRConfiguration) -> Int {
        let configured = max(1, configuration.maximumParallelFiles)
        switch configuration.cpuMode {
        case .economical:
            return 1
        case .normal:
            return configured
        case .fast:
            return min(configured, max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
        }
    }

    private nonisolated func logOCRRetryOutcome(
        _ outcome: OCRRetryOutcome,
        path: String
    ) async {
        for (strategyID, records) in Dictionary(
            grouping: outcome.attempts,
            by: { $0.strategy.id }
        ).sorted(by: { $0.key < $1.key }) {
            guard let first = records.first else { continue }
            let bestScore = records.map(\.qualityScore).max() ?? 0
            try? await fileLogger?.log(
                .info,
                category: "OCR-Nachbearbeitung",
                message:
                    "\(first.strategy.displayName) [\(strategyID)]: "
                    + "\(records.count) Seite(n), bester Qualitätswert "
                    + bestScore.formatted(.number.precision(.fractionLength(3)))
                    + ", Engine \(first.engine.displayName).",
                path: path
            )
        }
        for failure in outcome.failedAttemptDescriptions {
            try? await fileLogger?.log(
                .warning,
                category: "OCR-Nachbearbeitung",
                message: failure,
                path: path
            )
        }
    }
}
