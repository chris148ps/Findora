import Foundation

public enum ProcessingState: String, Codable, Sendable {
    case discovered
    case waitingForStability
    case extracting
    case ocrQueued
    case ocrRunning
    case indexing
    case indexed
    case failed
    case unavailable
    case retired

    public var displayName: String {
        switch self {
        case .discovered: "Erkannt"
        case .waitingForStability: "Dateistabilität wird geprüft"
        case .extracting: "Textschicht wird analysiert"
        case .ocrQueued: "OCR wartet"
        case .ocrRunning: "OCR läuft"
        case .indexing: "Index und Embeddings werden erstellt"
        case .indexed: "Indexiert"
        case .failed: "Fehlgeschlagen"
        case .unavailable: "Datei nicht verfügbar"
        case .retired: "Übersprungen"
        }
    }
}

public enum DocumentStatusChange: String, Sendable {
    case scanCompleted
    case jobChanged
    case documentIndexed
    case embeddingsChanged
    case locationsChanged
    case processingPaused
    case maintenanceCompleted
    case errorRecorded
}

public struct DiscoveredPDF: Identifiable, Hashable, Sendable {
    public let id: String
    public let url: URL
    public let relativePath: String
    public let fileName: String
    public let size: Int64
    public let modifiedAt: Date
    public let resourceIdentifier: String?
    public let volumeIdentifier: String?
    public let isLocallyAvailable: Bool
    public let availabilityError: String?

    public init(
        url: URL,
        relativePath: String,
        fileName: String,
        size: Int64,
        modifiedAt: Date,
        resourceIdentifier: String?,
        volumeIdentifier: String?,
        isLocallyAvailable: Bool = true,
        availabilityError: String? = nil
    ) {
        self.id = url.standardizedFileURL.path
        self.url = url
        self.relativePath = relativePath
        self.fileName = fileName
        self.size = size
        self.modifiedAt = modifiedAt
        self.resourceIdentifier = resourceIdentifier
        self.volumeIdentifier = volumeIdentifier
        self.isLocallyAvailable = isLocallyAvailable
        self.availabilityError = availabilityError
    }
}

public struct ExtractedPage: Hashable, Sendable {
    public let pageNumber: Int
    public let text: String

    public init(pageNumber: Int, text: String) {
        self.pageNumber = pageNumber
        self.text = text
    }
}

public struct TextChunk: Identifiable, Hashable, Sendable {
    public let id: String
    public let pageNumber: Int
    public let ordinal: Int
    public let text: String

    public init(id: String, pageNumber: Int, ordinal: Int, text: String) {
        self.id = id
        self.pageNumber = pageNumber
        self.ordinal = ordinal
        self.text = text
    }
}

public enum SearchRelevance: String, Codable, CaseIterable, Hashable, Sendable {
    case veryRelevant
    case relevant
    case possiblyRelevant

    public var displayName: String {
        switch self {
        case .veryRelevant: "Sehr passend"
        case .relevant: "Passend"
        case .possiblyRelevant: "Möglicherweise passend"
        }
    }
}

public enum SearchMatchKind: String, Codable, CaseIterable, Hashable, Sendable {
    case exact
    case semantic
    case fileName
    case sameChunk
    case sameDocument

    public var displayName: String {
        switch self {
        case .exact: "Exakter Treffer"
        case .semantic: "Semantischer Treffer"
        case .fileName: "Dateiname"
        case .sameChunk: "Im selben Textabschnitt"
        case .sameDocument: "Im selben Dokument"
        }
    }
}

public struct SearchSource: Identifiable, Hashable, Sendable {
    public let id: String
    public let documentID: Int64
    public let chunkID: String
    public let fileName: String
    public let absolutePath: String
    public let relativePath: String
    public let pageNumber: Int
    public let excerpt: String
    public let score: Double
    public let relevance: SearchRelevance
    public let matchedEntities: [String]
    public let matchedTopics: [String]
    public let reason: String
    public let ocrQuality: String?
    public let textSource: String
    public let matchKinds: [SearchMatchKind]

    public init(
        id: String,
        documentID: Int64,
        chunkID: String,
        fileName: String,
        absolutePath: String,
        relativePath: String,
        pageNumber: Int,
        excerpt: String,
        score: Double,
        relevance: SearchRelevance = .relevant,
        matchedEntities: [String] = [],
        matchedTopics: [String] = [],
        reason: String = "",
        ocrQuality: String? = nil,
        textSource: String = "extracted",
        matchKinds: [SearchMatchKind] = []
    ) {
        self.id = id
        self.documentID = documentID
        self.chunkID = chunkID
        self.fileName = fileName
        self.absolutePath = absolutePath
        self.relativePath = relativePath
        self.pageNumber = pageNumber
        self.excerpt = excerpt
        self.score = score
        self.relevance = relevance
        self.matchedEntities = matchedEntities
        self.matchedTopics = matchedTopics
        self.reason = reason
        self.ocrQuality = ocrQuality
        self.textSource = textSource
        self.matchKinds = matchKinds
    }
}

public struct SearchOutcome: Equatable, Sendable {
    public let plan: SearchPlan
    public let directMatches: [SearchSource]
    public let possibleMatches: [SearchSource]

    public init(
        plan: SearchPlan,
        directMatches: [SearchSource],
        possibleMatches: [SearchSource]
    ) {
        self.plan = plan
        self.directMatches = directMatches
        self.possibleMatches = possibleMatches
    }
}

public struct DocumentSearchEvidence: Sendable {
    public let documentID: Int64
    public let chunks: [SearchEvidenceChunk]

    public init(documentID: Int64, chunks: [SearchEvidenceChunk]) {
        self.documentID = documentID
        self.chunks = chunks
    }
}

public struct SearchEvidenceChunk: Sendable {
    public let chunkID: String
    public let pageNumber: Int
    public let text: String
    public let textSource: String
    public let ocrQuality: String?

    public init(
        chunkID: String,
        pageNumber: Int,
        text: String,
        textSource: String,
        ocrQuality: String?
    ) {
        self.chunkID = chunkID
        self.pageNumber = pageNumber
        self.text = text
        self.textSource = textSource
        self.ocrQuality = ocrQuality
    }
}

public struct DocumentStatistics: Equatable, Sendable {
    public var totalPDFs = 0
    public var indexedPDFs = 0
    public var searchablePDFs = 0
    public var withoutTextLayerPDFs = 0
    public var ocrRequiredPDFs = 0
    public var ocrProcessedPDFs = 0
    public var ocrFailedPDFs = 0
    public var pendingJobs = 0
    public var processingJobs = 0
    public var pausedJobs = 0
    public var skippedJobs = 0
    public var failedJobs = 0
    public var totalChunks = 0
    public var embeddedChunks = 0
    public var fallbackEmbeddedChunks = 0
    public var e5EmbeddedChunks = 0
    public var duplicateLocations = 0
    public var missingOrMovedFiles = 0
    public var ocrQualityGoodPages = 0
    public var ocrQualityReviewPages = 0
    public var ocrQualityFailedPages = 0
    public var emptyPageCandidates = 0
    public var fullyEmptyPDFs = 0
    public var processedJobs = 0
    public var totalJobs = 0
    public var currentStep: String?
    public var currentFile: String?
    public var currentOCREngine: String?
    public var isPaused = false
    public var lastSuccessfulStep: String?
    public var lastProcessingError: String?
    public var lastFullScan: Date?

    public var progressFraction: Double {
        guard totalJobs > 0 else { return indexedPDFs > 0 ? 1 : 0 }
        return min(1, max(0, Double(processedJobs) / Double(totalJobs)))
    }

    public init() {}
}

public enum DocumentStatusPrimaryMetric: String, CaseIterable, Identifiable, Sendable {
    case totalPDFs
    case indexedPDFs
    case pendingJobs
    case duplicates

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .totalPDFs: "PDFs insgesamt"
        case .indexedPDFs: "Indexiert"
        case .pendingJobs: "In Warteschlange"
        case .duplicates: "Duplikate"
        }
    }

    public func value(in statistics: DocumentStatistics) -> Int {
        switch self {
        case .totalPDFs: statistics.totalPDFs
        case .indexedPDFs: statistics.indexedPDFs
        case .pendingJobs: statistics.pendingJobs
        case .duplicates: statistics.duplicateLocations
        }
    }
}

public enum PageContentStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case fullyEmpty
    case probablyEmpty
    case imageWithoutText
    case needsOCRReview
    case content
    case technicalError

    public var displayName: String {
        switch self {
        case .fullyEmpty: "Vollständig leer"
        case .probablyEmpty: "Vermutlich leer"
        case .imageWithoutText: "Bild ohne erkannten Text"
        case .needsOCRReview: "OCR überprüfen"
        case .content: "Inhalt vorhanden"
        case .technicalError: "Technischer Fehler"
        }
    }

    public var isEmptyCandidate: Bool {
        self == .fullyEmpty || self == .probablyEmpty
    }
}

public enum PageReviewDecision: String, Codable, CaseIterable, Hashable, Sendable {
    case undecided
    case confirmedEmpty
    case notEmpty
    case excluded

    public var displayName: String {
        switch self {
        case .undecided: "Nicht geprüft"
        case .confirmedEmpty: "Als leer bestätigt"
        case .notEmpty: "Als nicht leer markiert"
        case .excluded: "Von Prüfungen ausgeschlossen"
        }
    }
}

public struct PageVisualMetrics: Codable, Equatable, Hashable, Sendable {
    public let renderSucceeded: Bool
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let whiteRatio: Double
    public let darkPixelRatio: Double
    public let variance: Double
    public let edgeRatio: Double
    public let contrast: Double
    public let characterCount: Int
    public let wordCount: Int
    public let ocrConfidence: Double?
    public let embeddedImageCount: Int
    public let annotationCount: Int
    public let hasSmallText: Bool

    public init(
        renderSucceeded: Bool,
        pixelWidth: Int,
        pixelHeight: Int,
        whiteRatio: Double,
        darkPixelRatio: Double,
        variance: Double,
        edgeRatio: Double,
        contrast: Double,
        characterCount: Int,
        wordCount: Int,
        ocrConfidence: Double?,
        embeddedImageCount: Int,
        annotationCount: Int,
        hasSmallText: Bool
    ) {
        self.renderSucceeded = renderSucceeded
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.whiteRatio = whiteRatio
        self.darkPixelRatio = darkPixelRatio
        self.variance = variance
        self.edgeRatio = edgeRatio
        self.contrast = contrast
        self.characterCount = characterCount
        self.wordCount = wordCount
        self.ocrConfidence = ocrConfidence
        self.embeddedImageCount = embeddedImageCount
        self.annotationCount = annotationCount
        self.hasSmallText = hasSmallText
    }
}

public struct PageContentAnalysis: Equatable, Hashable, Sendable {
    public let pageNumber: Int
    public let pageCount: Int
    public let status: PageContentStatus
    public let confidence: Double
    public let reason: String
    public let metrics: PageVisualMetrics

    public init(
        pageNumber: Int,
        pageCount: Int,
        status: PageContentStatus,
        confidence: Double,
        reason: String,
        metrics: PageVisualMetrics
    ) {
        self.pageNumber = pageNumber
        self.pageCount = pageCount
        self.status = status
        self.confidence = min(1, max(0, confidence))
        self.reason = reason
        self.metrics = metrics
    }
}

public struct EmptyPageCandidate: Identifiable, Equatable, Hashable, Sendable {
    public var id: String { "\(absolutePath)#\(pageNumber)" }
    public let absolutePath: String
    public let relativePath: String
    public let fileName: String
    public let originalHash: String
    public let pageNumber: Int
    public let pageCount: Int
    public let status: PageContentStatus
    public let confidence: Double
    public let reason: String
    public let metrics: PageVisualMetrics
    public let decision: PageReviewDecision

    public init(
        absolutePath: String,
        relativePath: String,
        fileName: String,
        originalHash: String,
        pageNumber: Int,
        pageCount: Int,
        status: PageContentStatus,
        confidence: Double,
        reason: String,
        metrics: PageVisualMetrics,
        decision: PageReviewDecision
    ) {
        self.absolutePath = absolutePath
        self.relativePath = relativePath
        self.fileName = fileName
        self.originalHash = originalHash
        self.pageNumber = pageNumber
        self.pageCount = pageCount
        self.status = status
        self.confidence = confidence
        self.reason = reason
        self.metrics = metrics
        self.decision = decision
    }
}

public struct EmptyPDFCandidate: Identifiable, Equatable, Hashable, Sendable {
    public var id: String { absolutePath }
    public let absolutePath: String
    public let relativePath: String
    public let fileName: String
    public let originalHash: String
    public let pageCount: Int
    public let confidence: Double

    public init(
        absolutePath: String,
        relativePath: String,
        fileName: String,
        originalHash: String,
        pageCount: Int,
        confidence: Double
    ) {
        self.absolutePath = absolutePath
        self.relativePath = relativePath
        self.fileName = fileName
        self.originalHash = originalHash
        self.pageCount = pageCount
        self.confidence = confidence
    }
}

public struct DuplicateLocation: Identifiable, Equatable, Hashable, Sendable {
    public var id: String { absolutePath }
    public let absolutePath: String
    public let relativePath: String
    public let fileName: String
    public let modifiedAt: Date
    public let fileSize: Int64

    public init(
        absolutePath: String,
        relativePath: String,
        fileName: String,
        modifiedAt: Date,
        fileSize: Int64
    ) {
        self.absolutePath = absolutePath
        self.relativePath = relativePath
        self.fileName = fileName
        self.modifiedAt = modifiedAt
        self.fileSize = fileSize
    }
}

public struct DuplicateGroup: Identifiable, Equatable, Hashable, Sendable {
    public var id: String { contentHash }
    public let contentHash: String
    public let locations: [DuplicateLocation]

    public init(contentHash: String, locations: [DuplicateLocation]) {
        self.contentHash = contentHash
        self.locations = locations
    }

    public var recommendedLocation: DuplicateLocation? {
        locations.sorted { lhs, rhs in
            let lhsScore = Self.archiveScore(lhs.absolutePath)
            let rhsScore = Self.archiveScore(rhs.absolutePath)
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt < rhs.modifiedAt }
            return lhs.absolutePath.count < rhs.absolutePath.count
        }.first
    }

    private static func archiveScore(_ path: String) -> Int {
        let lower = path.lowercased()
        if lower.contains("archiv") || lower.contains("dokument") { return 2 }
        if lower.contains("/downloads/") || lower.contains("/desktop/") { return 0 }
        return 1
    }
}

public struct StoredDocumentText: Sendable {
    public let documentID: Int64
    public let contentHash: String
    public let modifiedAt: Date
    public let pages: [ExtractedPage]

    public init(
        documentID: Int64,
        contentHash: String,
        modifiedAt: Date,
        pages: [ExtractedPage]
    ) {
        self.documentID = documentID
        self.contentHash = contentHash
        self.modifiedAt = modifiedAt
        self.pages = pages
    }
}

public struct RebuiltDocumentIndex: Sendable {
    public let document: StoredDocumentText
    public let chunks: [TextChunk]
    public let embeddings: [[Float]]

    public init(
        document: StoredDocumentText,
        chunks: [TextChunk],
        embeddings: [[Float]]
    ) {
        self.document = document
        self.chunks = chunks
        self.embeddings = embeddings
    }
}

public enum PrivateDocSearchError: LocalizedError, Sendable {
    case noDocumentFolder
    case folderUnavailable(String)
    case permissionDenied(String)
    case unstableFile(String)
    case invalidPDF(String)
    case dependencyMissing(String)
    case processFailed(String)
    case database(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noDocumentFolder:
            "Es wurde noch kein Dokumentenordner ausgewählt."
        case .folderUnavailable(let path):
            "Der Dokumentenordner ist derzeit nicht erreichbar: \(path)"
        case .permissionDenied(let path):
            "Die Berechtigung für den Dokumentenordner fehlt: \(path)"
        case .unstableFile(let path):
            "Die Datei wird noch geschrieben oder synchronisiert: \(path)"
        case .invalidPDF(let reason):
            "Die PDF konnte nicht sicher validiert werden: \(reason)"
        case .dependencyMissing(let detail):
            "Eine benötigte OCR-Komponente fehlt: \(detail)"
        case .processFailed(let detail):
            "Der lokale Prozess ist fehlgeschlagen: \(detail)"
        case .database(let detail):
            "Datenbankfehler: \(detail)"
        case .cancelled:
            "Der Vorgang wurde abgebrochen."
        }
    }
}
