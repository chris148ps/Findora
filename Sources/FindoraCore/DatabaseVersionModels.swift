import Foundation

public enum DocumentAnalysisKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case ocr
    case parser
    case chunks
    case embeddings
    case aiAnalysis
    case peopleAnalysis
    case projectAnalysis
    case summary

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .ocr: "OCR"
        case .parser: "Parser"
        case .chunks: "Textabschnitte"
        case .embeddings: "Embeddings"
        case .aiAnalysis: "KI-Analyse"
        case .peopleAnalysis: "Personen"
        case .projectAnalysis: "Projekte"
        case .summary: "Zusammenfassungen"
        }
    }
}

public enum AnalysisUpgradeState: String, Codable, CaseIterable, Sendable {
    case pending
    case running
    case paused
    case completed
    case failed
}

public struct AnalysisVersionCount: Identifiable, Equatable, Sendable {
    public let kind: DocumentAnalysisKind
    public let currentVersion: String
    public let currentDocuments: Int
    public let outdatedDocuments: Int
    public let missingDocuments: Int

    public var id: DocumentAnalysisKind { kind }
}

public struct DatabaseVersionSnapshot: Equatable, Sendable {
    public let schemaVersion: Int
    public let expectedSchemaVersion: Int
    public let lastMigrationAt: Date?
    public let versions: [AnalysisVersionCount]
    public let pendingUpgrades: Int
    public let failedUpgrades: Int
    public let upgradePaused: Bool

    public init(
        schemaVersion: Int,
        expectedSchemaVersion: Int,
        lastMigrationAt: Date?,
        versions: [AnalysisVersionCount],
        pendingUpgrades: Int,
        failedUpgrades: Int,
        upgradePaused: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.expectedSchemaVersion = expectedSchemaVersion
        self.lastMigrationAt = lastMigrationAt
        self.versions = versions
        self.pendingUpgrades = pendingUpgrades
        self.failedUpgrades = failedUpgrades
        self.upgradePaused = upgradePaused
    }
}

public enum FindoraAnalysisVersions {
    public static let schema = 15
    public static let ocr = "ocr-v2-multistage"
    public static let parser = "pdfkit-hybrid-v2"
    public static let chunks = PageChunker.version
    public static let aiAnalysis = "local-ai-v1"
    public static let peopleAnalysis = "communication-people-v1"
    public static let projectAnalysis = "communication-project-v1"
    public static let summary = "summary-v1"
    public static let knowledge = "knowledge-v1"
}
