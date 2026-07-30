import Foundation

public enum FindoraAgentRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case planner
    case importAgent = "import"
    case ocr
    case vision
    case extraction
    case communication
    case project
    case quality
    case experience
    case answer
    case maintenance

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .planner: "Planner-Agent"
        case .importAgent: "Import-Agent"
        case .ocr: "OCR-Agent"
        case .vision: "Vision-Agent"
        case .extraction: "Extraktions-Agent"
        case .communication: "Kommunikations-Agent"
        case .project: "Projekt-Agent"
        case .quality: "Qualitäts-Agent"
        case .experience: "Erfahrungs-Agent"
        case .answer: "Antwort-Agent"
        case .maintenance: "Wartungs-Agent"
        }
    }
}

public enum FindoraAgentState: String, Codable, CaseIterable, Sendable {
    case idle
    case waitingForModel = "waiting_for_model"
    case running
    case paused
    case succeeded
    case failed
}

public struct FindoraAgentSnapshot: Identifiable, Equatable, Sendable {
    public let role: FindoraAgentRole
    public let state: FindoraAgentState
    public let currentJobKind: KnowledgeJobKind?
    public let currentJobID: String?
    public let detail: String
    public let processedItemCount: Int
    public let updatedAt: Date

    public var id: FindoraAgentRole { role }

    public init(
        role: FindoraAgentRole,
        state: FindoraAgentState = .idle,
        currentJobKind: KnowledgeJobKind? = nil,
        currentJobID: String? = nil,
        detail: String = "",
        processedItemCount: Int = 0,
        updatedAt: Date = .now
    ) {
        self.role = role
        self.state = state
        self.currentJobKind = currentJobKind
        self.currentJobID = currentJobID
        self.detail = detail
        self.processedItemCount = processedItemCount
        self.updatedAt = updatedAt
    }
}

public struct KnowledgeOntologyType: Identifiable, Equatable, Sendable {
    public let key: KnowledgeEntityType
    public let domain: String
    public let displayName: String
    public let description: String
    public let isBuiltIn: Bool
    public let isEnabled: Bool
    public let revision: Int

    public var id: String { key.rawValue }

    public init(
        key: KnowledgeEntityType,
        domain: String,
        displayName: String,
        description: String,
        isBuiltIn: Bool,
        isEnabled: Bool,
        revision: Int
    ) {
        self.key = key
        self.domain = domain
        self.displayName = displayName
        self.description = description
        self.isBuiltIn = isBuiltIn
        self.isEnabled = isEnabled
        self.revision = revision
    }
}

public enum KnowledgeAgentSystemError: LocalizedError, Equatable, Sendable {
    case missingPrimaryModel
    case missingDocument
    case missingSourceText
    case incompleteValidatedExtraction(KnowledgeJobKind)

    public var errorDescription: String? {
        switch self {
        case .missingPrimaryModel:
            "Für die lokale Wissensanalyse ist kein primäres Extraktionsmodell aktiviert."
        case .missingDocument:
            "Das Dokument des Wissensjobs ist nicht mehr vorhanden."
        case .missingSourceText:
            "Das Dokument besitzt keinen belegbaren Seiten- oder Abschnittstext."
        case .incompleteValidatedExtraction(let kind):
            "Die validierte Extraktion erfüllt die Folgestufe \(kind.rawValue) nicht."
        }
    }
}

/// Process-wide serialization boundary for large generative runtimes. It is
/// shared by background agents and foreground answers so Phi, Qwen and a
/// vision model cannot execute concurrently on an 8-GB Mac.
public actor LocalGenerativeTaskGate {
    private var isAcquired = false
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }
    private var waiters: [Waiter] = []

    public init() {}

    public func withExclusiveAccess<T: Sendable>(
        _ operation: @Sendable () async throws -> T,
        cleanup: (@Sendable () async -> Void)? = nil
    ) async throws -> T {
        try await acquire()
        do {
            let result = try await operation()
            if let cleanup {
                await cleanup()
            }
            release()
            return result
        } catch {
            if let cleanup {
                await cleanup()
            }
            release()
            throw error
        }
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if !isAcquired {
            isAcquired = true
            if Task.isCancelled {
                release()
                throw CancellationError()
            }
            return
        }
        let waiterID = UUID()
        let ownsGate = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append(Waiter(id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: waiterID)
            }
        }
        guard ownsGate else {
            throw CancellationError()
        }
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    private func release() {
        guard !waiters.isEmpty else {
            isAcquired = false
            return
        }
        let next = waiters.removeFirst()
        next.continuation.resume(returning: true)
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }
}

/// Persistent local worker for the knowledge job graph. Agents exchange only
/// typed jobs and validated database state. No model receives database access.
public actor KnowledgeAgentSystem {
    public typealias SnapshotHandler =
        @Sendable ([FindoraAgentSnapshot]) async -> Void

    private let database: SQLiteDatabase
    private var policy: KnowledgeExtractionPolicy
    private let generativeTaskGate: LocalGenerativeTaskGate
    private var primary: (any StructuredKnowledgeGenerating)?
    private var reviewer: (any StructuredKnowledgeGenerating)?
    private var snapshots: [FindoraAgentRole: FindoraAgentSnapshot]
    private var workerTask: Task<Void, Never>?
    private var snapshotHandler: SnapshotHandler?
    private var externalRunIDs: [FindoraAgentRole: String] = [:]
    private var isPaused = false

    public init(
        database: SQLiteDatabase,
        policy: KnowledgeExtractionPolicy = .init(),
        generativeTaskGate: LocalGenerativeTaskGate = .init()
    ) {
        self.database = database
        self.policy = policy
        self.generativeTaskGate = generativeTaskGate
        self.snapshots = Dictionary(
            uniqueKeysWithValues: FindoraAgentRole.allCases.map {
                ($0, FindoraAgentSnapshot(role: $0))
            }
        )
    }

    deinit {
        workerTask?.cancel()
    }

    public func setSnapshotHandler(_ handler: SnapshotHandler?) async {
        snapshotHandler = handler
        await publishSnapshots()
    }

    public func setModels(
        primary: (any StructuredKnowledgeGenerating)?,
        reviewer: (any StructuredKnowledgeGenerating)?
    ) async {
        self.primary = primary
        self.reviewer = reviewer
        if primary != nil {
            try? await database.resumeKnowledgeJobsWaitingForModel()
        }
        await publishSnapshots()
    }

    public func setPolicy(_ policy: KnowledgeExtractionPolicy) {
        self.policy = policy
    }

    public func setPaused(_ paused: Bool) async {
        isPaused = paused
        if paused {
            for role in FindoraAgentRole.allCases {
                update(
                    role,
                    state: .paused,
                    detail: "Lokale Wissensverarbeitung ist pausiert."
                )
            }
        } else {
            for role in FindoraAgentRole.allCases
            where snapshots[role]?.state == .paused {
                update(role, state: .idle, detail: "")
            }
        }
        await publishSnapshots()
    }

    public func reportExternalActivity(
        role: FindoraAgentRole,
        state: FindoraAgentState,
        detail: String,
        processedItemCount: Int = 0
    ) async {
        if state == .running, externalRunIDs[role] == nil {
            externalRunIDs[role] = try? await database.beginStandaloneAgentRun(
                role: role
            )
        } else if state != .running, let runID = externalRunIDs.removeValue(
            forKey: role
        ) {
            try? await database.finishAgentRun(
                id: runID,
                state: state,
                processedItemCount: processedItemCount,
                errorCategory: state == .failed ? "external_agent" : nil
            )
        }
        update(
            role,
            state: state,
            detail: detail,
            processedItemCount: processedItemCount
        )
        await publishSnapshots()
    }

    public func currentSnapshots() -> [FindoraAgentSnapshot] {
        orderedSnapshots()
    }

    public func start() {
        guard workerTask == nil else { return }
        workerTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    public func stop() {
        workerTask?.cancel()
        workerTask = nil
    }

    /// Executes one ready job and is also used by deterministic integration
    /// tests. Returns false when no dependency-ready work exists.
    @discardableResult
    public func runNextJob(now: Date = .now) async -> Bool {
        guard !isPaused else { return false }
        let job: KnowledgeJob
        do {
            guard let next = try await database.nextKnowledgeJob(now: now) else {
                return false
            }
            job = next
        } catch {
            return false
        }

        let role = Self.role(for: job.kind)
        update(
            role,
            state: .running,
            job: job,
            detail: "Lokale Stufe \(job.kind.rawValue) wird ausgeführt."
        )
        await publishSnapshots()
        let runID = try? await database.beginAgentRun(role: role, job: job, now: now)

        do {
            let processed = try await execute(job)
            try await database.completeKnowledgeJob(
                id: job.id,
                succeeded: true,
                now: .now
            )
            if let runID {
                try await database.finishAgentRun(
                    id: runID,
                    state: .succeeded,
                    processedItemCount: processed,
                    errorCategory: nil,
                    now: .now
                )
            }
            update(
                role,
                state: .succeeded,
                detail: "\(job.kind.rawValue) abgeschlossen.",
                processedItemCount: processed
            )
        } catch KnowledgeAgentSystemError.missingPrimaryModel {
            try? await database.waitKnowledgeJobForModel(
                id: job.id,
                reason: "primary_model_unavailable",
                now: .now
            )
            if let runID {
                try? await database.finishAgentRun(
                    id: runID,
                    state: .waitingForModel,
                    processedItemCount: 0,
                    errorCategory: "primary_model_unavailable",
                    now: .now
                )
            }
            update(
                role,
                state: .waitingForModel,
                detail: "Qwen 3.5 ist nicht installiert oder nicht aktiviert."
            )
        } catch {
            let mayRetry = job.attemptCount < 3
            try? await database.completeKnowledgeJob(
                id: job.id,
                succeeded: false,
                errorCategory: Self.errorCategory(error),
                retryAfter: mayRetry
                    ? Date().addingTimeInterval(Double(job.attemptCount) * 15)
                    : nil,
                now: .now
            )
            if let runID {
                try? await database.finishAgentRun(
                    id: runID,
                    state: .failed,
                    processedItemCount: 0,
                    errorCategory: Self.errorCategory(error),
                    now: .now
                )
            }
            update(
                role,
                state: .failed,
                detail: error.localizedDescription
            )
        }
        await publishSnapshots()
        return true
    }

    private func runLoop() async {
        while !Task.isCancelled {
            if await runNextJob() {
                await Task.yield()
            } else {
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func execute(_ job: KnowledgeJob) async throws -> Int {
        guard let documentID = job.documentID else {
            if job.kind == .refreshExperience {
                return try await database.performKnowledgePostprocessing(
                    kind: job.kind,
                    documentID: nil,
                    inputHash: job.inputHash
                )
            }
            throw KnowledgeAgentSystemError.missingDocument
        }

        if job.kind == .classifyDocument {
            guard let primary else {
                throw KnowledgeAgentSystemError.missingPrimaryModel
            }
            guard let context = try await database.knowledgeExtractionContext(
                documentID: documentID,
                modelID: primary.modelID,
                modelVersion: primary.modelVersion,
                promptVersion: "knowledge-agent-v2"
            ) else {
                throw KnowledgeAgentSystemError.missingDocument
            }
            guard !context.pages.isEmpty else {
                throw KnowledgeAgentSystemError.missingSourceText
            }
            let database = database
            let reviewer = reviewer
            let policy = policy
            let extraction = try await generativeTaskGate.withExclusiveAccess {
                let coordinator = KnowledgeExtractionCoordinator(
                    database: database,
                    primary: primary,
                    independentReviewer: reviewer,
                    policy: policy
                )
                return try await coordinator.extractAndStore(context: context)
            }
            return extraction.envelope.entities.count
                + extraction.envelope.facts.count
                + extraction.envelope.relations.count
        }

        return try await database.performKnowledgePostprocessing(
            kind: job.kind,
            documentID: documentID,
            inputHash: job.inputHash
        )
    }

    private func update(
        _ role: FindoraAgentRole,
        state: FindoraAgentState,
        job: KnowledgeJob? = nil,
        detail: String,
        processedItemCount: Int = 0
    ) {
        snapshots[role] = FindoraAgentSnapshot(
            role: role,
            state: state,
            currentJobKind: job?.kind,
            currentJobID: job?.id,
            detail: detail,
            processedItemCount: processedItemCount,
            updatedAt: .now
        )
    }

    private func publishSnapshots() async {
        await snapshotHandler?(orderedSnapshots())
    }

    private func orderedSnapshots() -> [FindoraAgentSnapshot] {
        FindoraAgentRole.allCases.compactMap { snapshots[$0] }
    }

    private static func role(for kind: KnowledgeJobKind) -> FindoraAgentRole {
        switch kind {
        case .classifyDocument:
            .planner
        case .extractEntities, .extractFacts, .buildRelations, .refreshSummaries:
            .extraction
        case .resolveEntities, .validateKnowledge, .detectConflicts:
            .quality
        case .proposeProjects:
            .project
        case .analyzeCommunication:
            .communication
        case .refreshExperience:
            .experience
        case .removeStaleKnowledge, .rebuildAffectedSubgraph:
            .maintenance
        }
    }

    private static func errorCategory(_ error: Error) -> String {
        switch error {
        case is KnowledgeValidationError: "knowledge_validation"
        case is KnowledgePipelineError: "knowledge_pipeline"
        case is CancellationError: "cancelled"
        default: "knowledge_agent"
        }
    }
}
