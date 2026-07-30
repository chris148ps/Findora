import Foundation

public struct LocalKnowledgeAPIStatus: Equatable, Sendable {
    public let knowledge: KnowledgeStatistics
    public let ontologyTypeCount: Int
    public let agentRunCount: Int
    public let auditEventCount: Int

    public init(
        knowledge: KnowledgeStatistics,
        ontologyTypeCount: Int,
        agentRunCount: Int,
        auditEventCount: Int
    ) {
        self.knowledge = knowledge
        self.ontologyTypeCount = ontologyTypeCount
        self.agentRunCount = agentRunCount
        self.auditEventCount = auditEventCount
    }
}

/// Transport-neutral local facade for future MCP, REST, Shortcuts and plugin
/// adapters. It exposes typed operations only and never opens a listener,
/// performs network I/O or accepts SQL/model prompts.
public protocol LocalKnowledgeAPI: Sendable {
    func status() async throws -> LocalKnowledgeAPIStatus
    func reviewSnapshot(limitPerSection: Int) async throws -> KnowledgeReviewSnapshot
    func graph(
        startingAt entityID: String,
        maximumDepth: Int,
        maximumEdges: Int
    ) async throws -> [KnowledgeGraphEdge]
    func ontology(enabledOnly: Bool) async throws -> [KnowledgeOntologyType]
    func enqueueReanalysis() async throws
}

public actor FindoraLocalKnowledgeAPI: LocalKnowledgeAPI {
    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    public func status() async throws -> LocalKnowledgeAPIStatus {
        async let knowledge = database.knowledgeStatistics()
        async let ontology = database.ontologyTypes()
        async let agentRuns = database.agentRunCount()
        async let auditEvents = database.auditEventCount()
        let values = try await (knowledge, ontology, agentRuns, auditEvents)
        return LocalKnowledgeAPIStatus(
            knowledge: values.0,
            ontologyTypeCount: values.1.count,
            agentRunCount: values.2,
            auditEventCount: values.3
        )
    }

    public func reviewSnapshot(
        limitPerSection: Int = 50
    ) async throws -> KnowledgeReviewSnapshot {
        try await database.knowledgeReviewSnapshot(
            limitPerSection: limitPerSection
        )
    }

    public func graph(
        startingAt entityID: String,
        maximumDepth: Int = 3,
        maximumEdges: Int = 200
    ) async throws -> [KnowledgeGraphEdge] {
        try await database.knowledgeGraph(
            startingAt: entityID,
            maximumDepth: maximumDepth,
            maximumEdges: maximumEdges
        )
    }

    public func ontology(enabledOnly: Bool = false) async throws
        -> [KnowledgeOntologyType] {
        try await database.ontologyTypes(enabledOnly: enabledOnly)
    }

    public func enqueueReanalysis() async throws {
        try await database.enqueueAllKnowledgeReanalysis()
    }
}
