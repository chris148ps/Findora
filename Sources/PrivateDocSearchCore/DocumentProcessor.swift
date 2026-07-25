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
        if try await database.reuseIndexedDocument(file: stable, observedHash: inputHash) {
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
        var ocrPerformed = false
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
            let result = try await selectedOCRProcessor.process(
                stable,
                configuration: ocrConfiguration
            ) { [database] engine in
                try? await database.updateJob(
                    path: file.id,
                    state: .ocrRunning,
                    ocrEngine: engine
                )
            }
            try await database.updateJob(
                path: file.id,
                state: .ocrRunning,
                ocrEngine: result.engine
            )
            ocrPerformed = true
            pages = result.pages
            pageQualities = result.pageQualities
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
            guard extractor.hasUsableTextLayer(pages) else {
                throw PrivateDocSearchError.invalidPDF("OCR-Ausgabe enthält keine brauchbare Textschicht.")
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
        }

        guard extractor.hasUsableTextLayer(pages) else {
            throw PrivateDocSearchError.invalidPDF("Keine brauchbare Textschicht vorhanden.")
        }

        try await database.updateJob(path: file.id, state: .indexing)
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
            pageQualities: pageQualities
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
}
