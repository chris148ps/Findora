import Foundation

/// Extensible ontology key. Built-in values remain source-compatible while
/// additional locally registered types can be decoded without a schema
/// migration or a new app binary.
public struct KnowledgeEntityType:
    RawRepresentable,
    Codable,
    CaseIterable,
    Hashable,
    Sendable
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let person = Self(rawValue: "person")
    public static let company = Self(rawValue: "company")
    public static let organization = Self(rawValue: "organization")
    public static let project = Self(rawValue: "project")
    public static let `case` = Self(rawValue: "case")
    public static let property = Self(rawValue: "property")
    public static let address = Self(rawValue: "address")
    public static let document = Self(rawValue: "document")
    public static let invoice = Self(rawValue: "invoice")
    public static let contract = Self(rawValue: "contract")
    public static let offer = Self(rawValue: "offer")
    public static let product = Self(rawValue: "product")
    public static let device = Self(rawValue: "device")
    public static let technicalSystem = Self(rawValue: "technical_system")
    public static let pvSystem = Self(rawValue: "pv_system")
    public static let battery = Self(rawValue: "battery")
    public static let wallbox = Self(rawValue: "wallbox")
    public static let inverter = Self(rawValue: "inverter")
    public static let authority = Self(rawValue: "authority")
    public static let gridOperator = Self(rawValue: "grid_operator")
    public static let standard = Self(rawValue: "standard")
    public static let appointment = Self(rawValue: "appointment")
    public static let task = Self(rawValue: "task")
    public static let topic = Self(rawValue: "topic")
    public static let location = Self(rawValue: "location")

    public static let allCases: [Self] = [
        .person, .company, .organization, .project, .case, .property,
        .address, .document, .invoice, .contract, .offer, .product, .device,
        .technicalSystem, .pvSystem, .battery, .wallbox, .inverter,
        .authority, .gridOperator, .standard, .appointment, .task, .topic,
        .location
    ]

    public var isSyntacticallyValid: Bool {
        rawValue.range(
            of: #"^[a-z][a-z0-9_]{1,63}$"#,
            options: .regularExpression
        ) != nil
    }
}

public enum KnowledgeClaimType: String, Codable, CaseIterable, Sendable {
    case explicitFact = "explicit_fact"
    case calculatedFact = "calculated_fact"
    case modelInference = "model_inference"
    case userConfirmed = "user_confirmed"
    case externallyVerified = "externally_verified"
    case deprecated
    case conflicted
    case rejected

    public var mayBecomeActiveAutomatically: Bool {
        self == .explicitFact || self == .calculatedFact
    }
}

public enum KnowledgeValidationStatus: String, Codable, CaseIterable, Sendable {
    case verified
    case supported
    case uncertain
    case contradicted
    case unverifiable
    case rejected

    public var maySupportActiveKnowledge: Bool {
        self == .verified || self == .supported
    }
}

public enum KnowledgeValueType: String, Codable, CaseIterable, Sendable {
    case string
    case integer
    case decimal
    case boolean
    case date
    case dateTime = "date_time"
    case money
    case measurement
    case entityReference = "entity_reference"
}

public enum KnowledgeEvidenceSource: String, Codable, CaseIterable, Sendable {
    case nativePDF = "native_pdf"
    case visionOCR = "vision_ocr"
    case tesseractOCR = "tesseract_ocr"
    case manualText = "manual_text"
    case emailBody = "email_body"
    case emailHeader = "email_header"
    case attachmentText = "attachment_text"
    case visualModel = "visual_model"
}

public enum KnowledgeEvidenceStatus: String, Codable, CaseIterable, Sendable {
    case valid
    case stale
    case missing
    case rejected
}

public struct NormalizedBoundingBox: Codable, Equatable, Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var isValid: Bool {
        [x, y, width, height].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }
            && x + width <= 1.000_001
            && y + height <= 1.000_001
            && width > 0
            && height > 0
    }
}

public struct KnowledgeEntityCandidate: Codable, Equatable, Sendable {
    public let candidateID: String
    public let type: KnowledgeEntityType
    public let canonicalName: String
    public let aliases: [String]
    public let identifiers: [String: String]
    public let shortDescription: String?
    public let confidence: Double
    public let evidenceIDs: [String]

    enum CodingKeys: String, CodingKey {
        case candidateID = "candidateId"
        case type
        case canonicalName
        case aliases
        case identifiers
        case shortDescription
        case confidence
        case evidenceIDs = "evidenceIds"
    }

    public init(
        candidateID: String,
        type: KnowledgeEntityType,
        canonicalName: String,
        aliases: [String] = [],
        identifiers: [String: String] = [:],
        shortDescription: String? = nil,
        confidence: Double,
        evidenceIDs: [String]
    ) {
        self.candidateID = candidateID
        self.type = type
        self.canonicalName = canonicalName
        self.aliases = aliases
        self.identifiers = identifiers
        self.shortDescription = shortDescription
        self.confidence = confidence
        self.evidenceIDs = evidenceIDs
    }
}

public struct KnowledgeFactCandidate: Codable, Equatable, Sendable {
    public let candidateID: String
    public let subjectEntityID: String
    public let predicate: String
    public let objectEntityID: String?
    public let literalValue: String?
    public let valueType: KnowledgeValueType
    public let unit: String?
    public let validFrom: String?
    public let validUntil: String?
    public let claimType: KnowledgeClaimType
    public let confidence: Double
    public let evidenceIDs: [String]

    enum CodingKeys: String, CodingKey {
        case candidateID = "candidateId"
        case subjectEntityID = "subjectEntityId"
        case predicate
        case objectEntityID = "objectEntityId"
        case literalValue
        case valueType
        case unit
        case validFrom
        case validUntil
        case claimType
        case confidence
        case evidenceIDs = "evidenceIds"
    }

    public init(
        candidateID: String,
        subjectEntityID: String,
        predicate: String,
        objectEntityID: String? = nil,
        literalValue: String? = nil,
        valueType: KnowledgeValueType = .string,
        unit: String? = nil,
        validFrom: String? = nil,
        validUntil: String? = nil,
        claimType: KnowledgeClaimType,
        confidence: Double,
        evidenceIDs: [String]
    ) {
        self.candidateID = candidateID
        self.subjectEntityID = subjectEntityID
        self.predicate = predicate
        self.objectEntityID = objectEntityID
        self.literalValue = literalValue
        self.valueType = valueType
        self.unit = unit
        self.validFrom = validFrom
        self.validUntil = validUntil
        self.claimType = claimType
        self.confidence = confidence
        self.evidenceIDs = evidenceIDs
    }
}

public struct KnowledgeRelationCandidate: Codable, Equatable, Sendable {
    public let candidateID: String
    public let subjectEntityID: String
    public let predicate: String
    public let objectEntityID: String
    public let validFrom: String?
    public let validUntil: String?
    public let claimType: KnowledgeClaimType
    public let confidence: Double
    public let evidenceIDs: [String]

    enum CodingKeys: String, CodingKey {
        case candidateID = "candidateId"
        case subjectEntityID = "subjectEntityId"
        case predicate
        case objectEntityID = "objectEntityId"
        case validFrom
        case validUntil
        case claimType
        case confidence
        case evidenceIDs = "evidenceIds"
    }

    public init(
        candidateID: String,
        subjectEntityID: String,
        predicate: String,
        objectEntityID: String,
        validFrom: String? = nil,
        validUntil: String? = nil,
        claimType: KnowledgeClaimType,
        confidence: Double,
        evidenceIDs: [String]
    ) {
        self.candidateID = candidateID
        self.subjectEntityID = subjectEntityID
        self.predicate = predicate
        self.objectEntityID = objectEntityID
        self.validFrom = validFrom
        self.validUntil = validUntil
        self.claimType = claimType
        self.confidence = confidence
        self.evidenceIDs = evidenceIDs
    }
}

public struct KnowledgeEvidenceCandidate: Codable, Equatable, Sendable {
    public let id: String
    public let pageID: Int64
    public let pageNumber: Int
    public let chunkID: String?
    public let quote: String
    public let characterStart: Int?
    public let characterEnd: Int?
    public let boundingBox: NormalizedBoundingBox?
    public let source: KnowledgeEvidenceSource
    public let confidence: Double

    enum CodingKeys: String, CodingKey {
        case id
        case pageID = "pageId"
        case pageNumber
        case chunkID = "chunkId"
        case quote
        case characterStart
        case characterEnd
        case boundingBox
        case source
        case confidence
    }

    public init(
        id: String,
        pageID: Int64,
        pageNumber: Int,
        chunkID: String? = nil,
        quote: String,
        characterStart: Int? = nil,
        characterEnd: Int? = nil,
        boundingBox: NormalizedBoundingBox? = nil,
        source: KnowledgeEvidenceSource,
        confidence: Double
    ) {
        self.id = id
        self.pageID = pageID
        self.pageNumber = pageNumber
        self.chunkID = chunkID
        self.quote = quote
        self.characterStart = characterStart
        self.characterEnd = characterEnd
        self.boundingBox = boundingBox
        self.source = source
        self.confidence = confidence
    }
}

public struct KnowledgeProjectSignal: Codable, Equatable, Sendable {
    public let kind: String
    public let value: String
    public let weight: Double
    public let evidenceIDs: [String]

    enum CodingKeys: String, CodingKey {
        case kind
        case value
        case weight
        case evidenceIDs = "evidenceIds"
    }

    public init(kind: String, value: String, weight: Double, evidenceIDs: [String]) {
        self.kind = kind
        self.value = value
        self.weight = weight
        self.evidenceIDs = evidenceIDs
    }
}

public struct KnowledgeUncertainty: Codable, Equatable, Sendable {
    public let kind: String
    public let description: String
    public let relatedCandidateIDs: [String]

    enum CodingKeys: String, CodingKey {
        case kind
        case description
        case relatedCandidateIDs = "relatedCandidateIds"
    }

    public init(kind: String, description: String, relatedCandidateIDs: [String] = []) {
        self.kind = kind
        self.description = description
        self.relatedCandidateIDs = relatedCandidateIDs
    }
}

public struct KnowledgeExtractionEnvelope: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let documentType: String?
    public let documentTypeConfidence: Double?
    public let entities: [KnowledgeEntityCandidate]
    public let facts: [KnowledgeFactCandidate]
    public let relations: [KnowledgeRelationCandidate]
    public let evidence: [KnowledgeEvidenceCandidate]
    public let projectSignals: [KnowledgeProjectSignal]
    public let uncertainties: [KnowledgeUncertainty]

    public init(
        schemaVersion: Int = 1,
        documentType: String? = nil,
        documentTypeConfidence: Double? = nil,
        entities: [KnowledgeEntityCandidate] = [],
        facts: [KnowledgeFactCandidate] = [],
        relations: [KnowledgeRelationCandidate] = [],
        evidence: [KnowledgeEvidenceCandidate] = [],
        projectSignals: [KnowledgeProjectSignal] = [],
        uncertainties: [KnowledgeUncertainty] = []
    ) {
        self.schemaVersion = schemaVersion
        self.documentType = documentType
        self.documentTypeConfidence = documentTypeConfidence
        self.entities = entities
        self.facts = facts
        self.relations = relations
        self.evidence = evidence
        self.projectSignals = projectSignals
        self.uncertainties = uncertainties
    }
}

public struct KnowledgeSourcePage: Equatable, Sendable {
    public let pageID: Int64
    public let pageNumber: Int
    public let text: String
    public let validChunkIDs: Set<String>

    public init(
        pageID: Int64,
        pageNumber: Int,
        text: String,
        validChunkIDs: Set<String> = []
    ) {
        self.pageID = pageID
        self.pageNumber = pageNumber
        self.text = text
        self.validChunkIDs = validChunkIDs
    }
}

public struct KnowledgeExtractionContext: Equatable, Sendable {
    public let documentID: Int64
    public let documentHash: String
    public let pages: [KnowledgeSourcePage]
    public let extractionModelID: String
    public let extractionModelVersion: String
    public let promptVersion: String
    public let schemaVersion: Int

    public init(
        documentID: Int64,
        documentHash: String,
        pages: [KnowledgeSourcePage],
        extractionModelID: String,
        extractionModelVersion: String,
        promptVersion: String,
        schemaVersion: Int = 1
    ) {
        self.documentID = documentID
        self.documentHash = documentHash
        self.pages = pages
        self.extractionModelID = extractionModelID
        self.extractionModelVersion = extractionModelVersion
        self.promptVersion = promptVersion
        self.schemaVersion = schemaVersion
    }
}

public struct ValidatedKnowledgeExtraction: Equatable, Sendable {
    public let envelope: KnowledgeExtractionEnvelope
    public let context: KnowledgeExtractionContext

    public init(
        envelope: KnowledgeExtractionEnvelope,
        context: KnowledgeExtractionContext
    ) {
        self.envelope = envelope
        self.context = context
    }
}

public enum KnowledgeJobKind: String, Codable, CaseIterable, Sendable {
    case classifyDocument
    case extractEntities
    case extractFacts
    case resolveEntities
    case buildRelations
    case proposeProjects
    case validateKnowledge
    case refreshSummaries
    case detectConflicts
    case removeStaleKnowledge
    case rebuildAffectedSubgraph
    case analyzeCommunication
    case refreshExperience
}

public enum KnowledgeJobState: String, Codable, CaseIterable, Sendable {
    case pending
    case running
    case paused
    case waitingForModel = "waiting_for_model"
    case completed
    case failed
    case cancelled
}

public struct KnowledgeJob: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: KnowledgeJobKind
    public let documentID: Int64?
    public let targetKey: String
    public let inputHash: String
    public let priority: Int
    public let state: KnowledgeJobState
    public let attemptCount: Int
    public let lastErrorCategory: String?
    public let createdAt: Date
    public let updatedAt: Date
}

public struct KnowledgeStatistics: Equatable, Sendable {
    public let entities: Int
    public let facts: Int
    public let relations: Int
    public let projects: Int
    public let conflicts: Int
    public let uncertainCandidates: Int
    public let pendingJobs: Int
    public let communicationThreads: Int
    public let communicationEvents: Int
    public let patterns: Int

    public init(
        entities: Int = 0,
        facts: Int = 0,
        relations: Int = 0,
        projects: Int = 0,
        conflicts: Int = 0,
        uncertainCandidates: Int = 0,
        pendingJobs: Int = 0,
        communicationThreads: Int = 0,
        communicationEvents: Int = 0,
        patterns: Int = 0
    ) {
        self.entities = entities
        self.facts = facts
        self.relations = relations
        self.projects = projects
        self.conflicts = conflicts
        self.uncertainCandidates = uncertainCandidates
        self.pendingJobs = pendingJobs
        self.communicationThreads = communicationThreads
        self.communicationEvents = communicationEvents
        self.patterns = patterns
    }
}

public struct KnowledgeGraphEdge: Identifiable, Equatable, Sendable {
    public let id: String
    public let subjectEntityID: String
    public let predicate: String
    public let objectEntityID: String
    public let claimType: KnowledgeClaimType
    public let validationStatus: KnowledgeValidationStatus
    public let confidence: Double
    public let depth: Int
}

public struct KnowledgeReviewRecord: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let status: String
    public let confidence: Double
    public let sourceSummary: String?

    public init(
        id: String,
        title: String,
        detail: String,
        status: String,
        confidence: Double,
        sourceSummary: String? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.status = status
        self.confidence = confidence
        self.sourceSummary = sourceSummary
    }
}

public struct KnowledgeReviewSnapshot: Equatable, Sendable {
    public let projects: [KnowledgeReviewRecord]
    public let entities: [KnowledgeReviewRecord]
    public let claims: [KnowledgeReviewRecord]
    public let communicationThreads: [KnowledgeReviewRecord]
    public let patterns: [KnowledgeReviewRecord]

    public init(
        projects: [KnowledgeReviewRecord] = [],
        entities: [KnowledgeReviewRecord] = [],
        claims: [KnowledgeReviewRecord] = [],
        communicationThreads: [KnowledgeReviewRecord] = [],
        patterns: [KnowledgeReviewRecord] = []
    ) {
        self.projects = projects
        self.entities = entities
        self.claims = claims
        self.communicationThreads = communicationThreads
        self.patterns = patterns
    }
}

public struct SearchSplitLayout: Equatable, Sendable {
    public let defaultFraction: Double
    public let minimumLeading: Double
    public let minimumTrailing: Double
    public let compactWidthThreshold: Double
    public let compactHeightThreshold: Double

    public init(
        defaultFraction: Double = 0.43,
        minimumLeading: Double = 180,
        minimumTrailing: Double = 220,
        compactWidthThreshold: Double = 520,
        compactHeightThreshold: Double = 430
    ) {
        self.defaultFraction = min(max(defaultFraction, 0.2), 0.8)
        self.minimumLeading = max(minimumLeading, 1)
        self.minimumTrailing = max(minimumTrailing, 1)
        self.compactWidthThreshold = max(compactWidthThreshold, 1)
        self.compactHeightThreshold = max(compactHeightThreshold, 1)
    }

    public func usesCompactPresentation(width: Double, height: Double) -> Bool {
        width < compactWidthThreshold || height < compactHeightThreshold
    }

    public func dividerPosition(
        fraction: Double,
        availableLength: Double,
        dividerThickness: Double
    ) -> Double {
        let contentLength = max(0, availableLength - dividerThickness)
        let maximumLeading = max(minimumLeading, contentLength - minimumTrailing)
        let proposed = min(max(fraction, 0.05), 0.95) * contentLength
        return min(max(proposed, minimumLeading), maximumLeading)
    }
}

public enum CommunicationEventType: String, Codable, CaseIterable, Sendable {
    case decision
    case commitment
    case rejection
    case question
    case missingDocument = "missing_document"
    case appointmentChanged = "appointment_changed"
    case approval
    case requirement
    case technicalChange = "technical_change"
    case task
    case responsibility
}

public enum ExperiencePatternStatus: String, Codable, CaseIterable, Sendable {
    case proposed
    case validated
    case confirmed
    case rejected
    case stale
}

public enum KnowledgeAnswerClass: String, Codable, CaseIterable, Sendable {
    case secured
    case calculated
    case probability
    case experience
    case conflict
    case unknown

    public var displayName: String {
        switch self {
        case .secured: "Gesichert"
        case .calculated: "Berechnet"
        case .probability: "Wahrscheinlichkeit"
        case .experience: "Erfahrung"
        case .conflict: "Konflikt"
        case .unknown: "Unbekannt"
        }
    }
}
