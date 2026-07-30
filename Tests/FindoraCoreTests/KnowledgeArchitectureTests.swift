import Foundation
import Testing
@testable import FindoraCore

@Test
func knowledgeValidationAcceptsExactEvidenceAndRejectsInventedEvidence() throws {
    let context = testKnowledgeContext()
    let valid = testEnvelope(context: context)
    let validator = KnowledgeExtractionValidator()
    let encoded = try JSONEncoder().encode(valid)

    let result = try validator.decodeAndValidate(encoded, context: context)
    #expect(result.envelope.facts.count == 1)
    #expect(result.envelope.evidence.first?.quote == "Rechnung 4711")

    let invented = testEnvelope(context: context, quote: "Rechnung 9999")
    #expect(throws: KnowledgeValidationError.self) {
        try validator.validate(invented, context: context)
    }
}

@Test
func knowledgeValidationRejectsMissingEvidenceWrongPageAndElevatedClaimType() throws {
    let context = testKnowledgeContext()
    let validator = KnowledgeExtractionValidator()
    let missing = KnowledgeExtractionEnvelope(
        entities: [
            KnowledgeEntityCandidate(
                candidateID: "entity-1",
                type: .invoice,
                canonicalName: "Rechnung 4711",
                confidence: 0.95,
                evidenceIDs: []
            )
        ]
    )
    #expect(throws: KnowledgeValidationError.self) {
        try validator.validate(missing, context: context)
    }

    let wrongPage = testEnvelope(context: context, pageID: 999)
    #expect(throws: KnowledgeValidationError.self) {
        try validator.validate(wrongPage, context: context)
    }

    let elevated = testEnvelope(context: context, claimType: .userConfirmed)
    #expect(throws: KnowledgeValidationError.self) {
        try validator.validate(elevated, context: context)
    }
}

@Test
func knowledgeValueNormalizationIsDeterministic() {
    let normalizer = KnowledgeValueNormalizer()
    #expect(normalizer.normalize("1.234,50", type: .money) == "1234.5")
    #expect(normalizer.normalize(" 2026-07-30 ", type: .date) == "2026-07-30")
    #expect(normalizer.normalize("ja", type: .boolean) == "true")
    #expect(normalizer.normalize("nicht wahr", type: .boolean) == nil)
}

@Test
func knowledgeJobsAreIdempotentAndRespectDependencies() async throws {
    let fixture = try await makeKnowledgeDatabaseFixture(name: "Jobs")
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    var statistics = try await fixture.database.knowledgeStatistics()
    #expect(statistics.pendingJobs == 11)

    _ = try await fixture.database.indexDocument(
        file: fixture.file,
        hash: fixture.hash,
        pages: fixture.pages,
        chunks: fixture.chunks,
        embeddings: [[0.1, 0.2]],
        embeddingModelID: "test-embedding",
        embeddingModelVersion: "1",
        ocrPerformed: false
    )
    statistics = try await fixture.database.knowledgeStatistics()
    #expect(statistics.pendingJobs == 11)

    let first = try #require(try await fixture.database.nextKnowledgeJob())
    #expect(first.kind == .classifyDocument)
    #expect(first.state == .running)
    #expect(try await fixture.database.nextKnowledgeJob() == nil)

    try await fixture.database.completeKnowledgeJob(id: first.id, succeeded: true)
    let second = try #require(try await fixture.database.nextKnowledgeJob())
    #expect(second.kind == .extractEntities)
}

@Test
func validatedKnowledgePersistsEvidenceFactsRelationsAndGraph() async throws {
    let fixture = try await makeKnowledgeDatabaseFixture(name: "Persistence")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let context = try #require(
        try await fixture.database.knowledgeExtractionContext(
            documentID: fixture.documentID,
            modelID: "qwen-test",
            modelVersion: "1"
        )
    )
    let secondEntity = KnowledgeEntityCandidate(
        candidateID: "entity-2",
        type: .company,
        canonicalName: "Solar Nord GmbH",
        confidence: 0.94,
        evidenceIDs: ["ev-1"]
    )
    let relation = KnowledgeRelationCandidate(
        candidateID: "relation-1",
        subjectEntityID: "entity-1",
        predicate: "issued_by",
        objectEntityID: "entity-2",
        claimType: .explicitFact,
        confidence: 0.92,
        evidenceIDs: ["ev-1"]
    )
    let base = testEnvelope(context: context)
    let envelope = KnowledgeExtractionEnvelope(
        schemaVersion: 1,
        documentType: "invoice",
        documentTypeConfidence: 0.96,
        entities: base.entities + [secondEntity],
        facts: base.facts,
        relations: [relation],
        evidence: base.evidence
    )
    let validated = try KnowledgeExtractionValidator().validate(
        envelope,
        context: context
    )

    try await fixture.database.storeValidatedKnowledge(validated)
    let statistics = try await fixture.database.knowledgeStatistics()
    #expect(statistics.entities == 2)
    #expect(statistics.facts == 1)
    #expect(statistics.relations == 1)

    let invoiceID = try #require(
        try await fixture.database.knowledgeEntityID(
            type: .invoice,
            canonicalName: "Rechnung 4711"
        )
    )
    let graph = try await fixture.database.knowledgeGraph(startingAt: invoiceID)
    #expect(graph.count == 1)
    #expect(graph.first?.predicate == "issued_by")
    #expect(graph.first?.depth == 1)

    let search = HybridSearchService(
        database: fixture.database,
        embedder: TokenHashEmbedding(dimensions: 2),
        semanticEnabled: false
    )
    let outcome = try await search.search(
        "Rechnung 4711",
        plan: RuleBasedSearchPlanner().plan(query: "Rechnung 4711")
    )
    #expect(!outcome.directMatches.isEmpty)
    #expect(outcome.directMatches.first?.matchKinds.contains(.relation) == true)
    #expect(outcome.directMatches.first?.excerpt.contains("Rechnung 4711") == true)
}

@Test
func knowledgeResetPreservesClassicDocumentIndex() async throws {
    let fixture = try await makeKnowledgeDatabaseFixture(name: "Reset")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let context = try #require(
        try await fixture.database.knowledgeExtractionContext(
            documentID: fixture.documentID,
            modelID: "qwen-test",
            modelVersion: "1"
        )
    )
    let validated = try KnowledgeExtractionValidator().validate(
        testEnvelope(context: context),
        context: context
    )
    try await fixture.database.storeValidatedKnowledge(validated)

    await #expect(throws: Error.self) {
        try await fixture.database.resetKnowledgeDatabase(confirmation: "RESET")
    }
    try await fixture.database.resetKnowledgeDatabase(
        confirmation: "RESET KNOWLEDGE"
    )
    let knowledge = try await fixture.database.knowledgeStatistics()
    let documents = try await fixture.database.statistics()
    let preservedContext = try await fixture.database.knowledgeExtractionContext(
        documentID: fixture.documentID,
        modelID: "qwen-test",
        modelVersion: "1"
    )
    #expect(knowledge.entities == 0)
    #expect(knowledge.facts == 0)
    #expect(documents.totalChunks == 1)
    #expect(preservedContext?.pages.count == 1)
}

@Test
func entityResolutionNeverOverridesNegativeRule() {
    let resolver = DeterministicEntityResolver()
    let automatic = resolver.decide(
        leftName: "Schleswig-Holstein Netz AG",
        rightName: "Schleswig Holstein Netz",
        matchingIdentifiers: 1,
        matchingAddresses: 1,
        sharedContextSignals: 3,
        negativeRuleExists: false
    )
    #expect(automatic.level == .automatic)

    let rejected = resolver.decide(
        leftName: "SH Netz",
        rightName: "SH-Netz",
        matchingIdentifiers: 2,
        matchingAddresses: 2,
        sharedContextSignals: 5,
        negativeRuleExists: true
    )
    #expect(rejected.level == .rejectedByRule)
    #expect(rejected.confidence == 1)
}

@Test
func projectDetectionDoesNotLinkOnCommonNameAlone() {
    let evaluator = ProjectSignalEvaluator()
    let weak = evaluator.assess(
        matchingIdentifiers: 0,
        matchingAddresses: 0,
        sharedEntities: 1,
        timeProximity: 0.8,
        semanticSimilarity: 0.9,
        onlyCommonPersonName: true
    )
    #expect(!weak.automaticallyLink)
    #expect(weak.counterReasons == ["common_name_only"])

    let strong = evaluator.assess(
        matchingIdentifiers: 1,
        matchingAddresses: 1,
        sharedEntities: 3,
        timeProximity: 0.9,
        semanticSimilarity: 0.8,
        onlyCommonPersonName: false
    )
    #expect(strong.automaticallyLink)
}

@Test
func modelRouterSelectsQwenPhiAndDemandDrivenGemma() throws {
    let models = try ModelCatalog.bundled().models
    let profile = HardwareProfile(
        isAppleSilicon: true,
        chipName: "Synthetic M-series",
        physicalMemoryBytes: 17_179_869_184,
        availableStorageBytes: 50_000_000_000
    )
    let installed = Set(models.map(\.id))
    let router = ModelRouter()

    let extraction = router.route(
        task: .structuredExtraction,
        catalog: models,
        installedModelIDs: installed,
        profile: profile,
        pressure: .normal
    )
    #expect(extraction.descriptor?.id.contains("Qwen3.5-4B") == true)

    let validation = router.route(
        task: .knowledgeValidation,
        catalog: models,
        installedModelIDs: installed,
        profile: profile,
        pressure: .normal
    )
    #expect(validation.descriptor?.id.contains("Phi-4-mini") == true)

    let hiddenVision = router.route(
        task: .visionDocumentAnalysis,
        catalog: models,
        installedModelIDs: installed,
        profile: profile,
        pressure: .normal
    )
    #expect(hiddenVision.descriptor?.id.contains("gemma-4") != true)
    let gemmaID = try #require(
        models.first { $0.id.contains("gemma-4-e2b") }?.id
    )
    let enabledVision = router.route(
        task: .visionDocumentAnalysis,
        catalog: models,
        installedModelIDs: installed,
        profile: profile,
        pressure: .normal,
        preferences: .init(
            preferredVisionModelID: gemmaID,
            allowExperimentalModels: true
        )
    )
    #expect(enabledVision.descriptor?.id == gemmaID)
}

@Test
func modelMemoryBudgetCapsEightGigabyteContextAndStopsAtCriticalPressure() async throws {
    let qwen = try #require(
        try ModelCatalog.bundled().models.first { $0.id.contains("Qwen3.5-4B") }
    )
    let budget = ModelMemoryBudget(
        physicalMemoryBytes: 8_589_934_592,
        pressure: .normal
    )
    let reservation = try await budget.reserve(
        for: qwen,
        requestedContextLength: 32_768
    )
    #expect(reservation.contextLength == 2_048)
    await budget.release(reservation)
    await budget.updatePressure(.critical)
    await #expect(throws: Error.self) {
        try await budget.reserve(for: qwen, requestedContextLength: 2_048)
    }
}

@Test
func criticalMemoryPressureMakesRoutingFailClosed() throws {
    let models = try ModelCatalog.bundled().models
    let decision = ModelRouter().route(
        task: .structuredExtraction,
        catalog: models,
        installedModelIDs: Set(models.map(\.id)),
        profile: .init(
            isAppleSilicon: true,
            chipName: "Synthetic",
            physicalMemoryBytes: 8_589_934_592,
            availableStorageBytes: 50_000_000_000
        ),
        pressure: .critical
    )
    #expect(decision.descriptor == nil)
    #expect(!decision.requiresDownloadConsent)
}

@Test
func generativeTaskGateSerializesRuntimesAndRunsCleanup() async {
    let gate = LocalGenerativeTaskGate()
    let probe = GenerativeGateProbe()
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<3 {
            group.addTask {
                try? await gate.withExclusiveAccess({
                    await probe.runOperation()
                }, cleanup: {
                    await probe.recordCleanup()
                })
            }
        }
    }
    #expect(await probe.maximumConcurrentOperations() == 1)
    #expect(await probe.cleanupCount() == 3)
}

@Test
func queryPlanningAlwaysRequiresOriginalEvidence() {
    let plan = KnowledgeQueryPlanner().plan(
        hasResolvedEntity: true,
        modelsAvailable: false,
        asksForTimeRange: true
    )
    #expect(plan.graphDepth == 3)
    #expect(plan.useFacts)
    #expect(plan.useFullText)
    #expect(!plan.useVectorSearch)
    #expect(plan.requireOriginalEvidence)
}

@Test
func answerClassificationFailsClosedWithoutCitationsAndDistinguishesProvenanceClass() {
    let classifier = KnowledgeAnswerClassifier()
    #expect(
        classifier.classify(
            question: "Was ist belegt?",
            answer: "Eine Antwort ohne Quellen-ID.",
            sources: []
        ) == .unknown
    )
    let source = SearchSource(
        id: "source",
        documentID: 1,
        chunkID: "chunk",
        fileName: "synthetic.pdf",
        absolutePath: "/synthetic.pdf",
        relativePath: "synthetic.pdf",
        pageNumber: 1,
        excerpt: "Beleg",
        score: 1
    )
    #expect(
        classifier.classify(
            question: "Berechne die Summe.",
            answer: "Die belegte Summe beträgt 42 [S-001].",
            sources: [source]
        ) == .calculated
    )
    #expect(
        classifier.classify(
            question: "Was ist belegt?",
            answer: "Die Unterlagen widersprechen sich [S-001].",
            sources: [source]
        ) == .conflict
    )
}

@Test
func searchSplitLayoutPersistsUsableMinimumsAndCompactFallback() {
    let layout = SearchSplitLayout()
    #expect(
        layout.dividerPosition(
            fraction: 0.01,
            availableLength: 800,
            dividerThickness: 1
        ) == 180
    )
    #expect(
        layout.dividerPosition(
            fraction: 0.99,
            availableLength: 800,
            dividerThickness: 1
        ) == 579
    )
    #expect(layout.usesCompactPresentation(width: 500, height: 700))
    #expect(layout.usesCompactPresentation(width: 800, height: 400))
    #expect(!layout.usesCompactPresentation(width: 800, height: 700))
    #expect(layout.defaultFraction == 0.43)
}

@Test
func disablingKnowledgePausesWorkAndPreventsNewAutomaticJobs() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "FindoraKnowledgeDisabled-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let database = SQLiteDatabase(url: root.appending(path: "test.sqlite3"))
    try await database.initialize()
    try await database.setKnowledgeProcessingEnabled(false)
    let url = root.appending(path: "disabled.pdf")
    try Data("synthetic".utf8).write(to: url)
    let file = DiscoveredPDF(
        url: url,
        relativePath: "disabled.pdf",
        fileName: "disabled.pdf",
        size: 9,
        modifiedAt: Date(),
        resourceIdentifier: nil,
        volumeIdentifier: nil
    )
    _ = try await database.indexDocument(
        file: file,
        hash: "disabled-hash",
        pages: [ExtractedPage(pageNumber: 1, text: "Lokaler belegbarer Text")],
        chunks: [
            TextChunk(
                id: "disabled-chunk",
                pageNumber: 1,
                ordinal: 0,
                text: "Lokaler belegbarer Text"
            )
        ],
        embeddings: [[0.1]],
        embeddingModelID: "test",
        embeddingModelVersion: "1",
        ocrPerformed: false
    )
    #expect(try await database.knowledgeStatistics().pendingJobs == 0)
}

@Test
func modelLeasesSwitchLargeModelsExclusively() async throws {
    let models = try ModelCatalog.bundled().models
    let qwen = try #require(models.first { $0.id.contains("Qwen3.5-4B") })
    let phi = try #require(models.first { $0.id.contains("Phi-4-mini") })
    let budget = ModelMemoryBudget(
        physicalMemoryBytes: 17_179_869_184,
        pressure: .normal
    )
    let manager = ModelLeaseManager(memoryBudget: budget)
    let qwenRuntime = ClosureModelRuntimeAdapter(
        modelID: qwen.id,
        load: { _ in },
        unload: {}
    )
    let phiRuntime = ClosureModelRuntimeAdapter(
        modelID: phi.id,
        load: { _ in },
        unload: {}
    )
    await manager.register(qwenRuntime)
    await manager.register(phiRuntime)
    let first = try await manager.acquire(
        descriptor: qwen,
        requestedContextLength: 2_048,
        priority: 50
    )
    #expect(await qwenRuntime.isLoaded())

    let waiting = Task {
        try await manager.acquire(
            descriptor: phi,
            requestedContextLength: 2_048,
            priority: 80
        )
    }
    try await Task.sleep(for: .milliseconds(20))
    #expect(!waiting.isCancelled)
    let phiLoadedWhileWaiting = await phiRuntime.isLoaded()
    #expect(!phiLoadedWhileWaiting)
    await first.release()
    let second = try await waiting.value
    let qwenLoadedAfterSwitch = await qwenRuntime.isLoaded()
    let phiLoadedAfterSwitch = await phiRuntime.isLoaded()
    #expect(!qwenLoadedAfterSwitch)
    #expect(phiLoadedAfterSwitch)
    await second.release()
}

@Test
func knowledgeAgentSystemConsumesTheProductiveJobGraphAndAuditsEveryStage() async throws {
    let fixture = try await makeKnowledgeDatabaseFixture(name: "AgentSystem")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let context = try #require(
        try await fixture.database.knowledgeExtractionContext(
            documentID: fixture.documentID,
            modelID: "qwen-agent-test",
            modelVersion: "1"
        )
    )
    let generator = TestStructuredKnowledgeGenerator(
        modelID: "qwen-agent-test",
        modelVersion: "1",
        output: try JSONEncoder().encode(testEnvelope(context: context))
    )
    let system = KnowledgeAgentSystem(
        database: fixture.database,
        policy: .init(automaticSecondReview: false)
    )
    await system.setModels(primary: generator, reviewer: nil)

    for _ in 0..<11 {
        #expect(await system.runNextJob())
    }
    #expect(!(await system.runNextJob()))
    let statistics = try await fixture.database.knowledgeStatistics()
    #expect(statistics.pendingJobs == 0)
    #expect(statistics.entities == 1)
    #expect(statistics.facts == 1)
    #expect(try await fixture.database.agentRunCount() == 11)
    #expect(try await fixture.database.auditEventCount() >= 22)
    #expect(await generator.unloadCount == 1)

    let api = FindoraLocalKnowledgeAPI(database: fixture.database)
    let status = try await api.status()
    #expect(status.knowledge.facts == 1)
    #expect(status.ontologyTypeCount >= KnowledgeEntityType.allCases.count)
    #expect(status.agentRunCount == 11)
}

@Test
func knowledgeAgentWaitsForAModelResumesAndAuditsExistingServiceAgents() async throws {
    let fixture = try await makeKnowledgeDatabaseFixture(name: "AgentResume")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let system = KnowledgeAgentSystem(
        database: fixture.database,
        policy: .init(automaticSecondReview: false)
    )

    #expect(await system.runNextJob())
    #expect(
        await system.currentSnapshots().first(where: { $0.role == .planner })?.state
            == .waitingForModel
    )

    let context = try #require(
        try await fixture.database.knowledgeExtractionContext(
            documentID: fixture.documentID,
            modelID: "qwen-resume-test",
            modelVersion: "1"
        )
    )
    let generator = TestStructuredKnowledgeGenerator(
        modelID: "qwen-resume-test",
        modelVersion: "1",
        output: try JSONEncoder().encode(testEnvelope(context: context))
    )
    await system.setModels(primary: generator, reviewer: nil)
    #expect(await system.runNextJob())

    await system.reportExternalActivity(
        role: .importAgent,
        state: .running,
        detail: "Synthetic import"
    )
    await system.reportExternalActivity(
        role: .importAgent,
        state: .succeeded,
        detail: "Synthetic import completed",
        processedItemCount: 1
    )
    #expect(try await fixture.database.agentRunCount() == 3)
    #expect(try await fixture.database.auditEventCount() >= 6)
}

@Test
func ontologyAcceptsRegisteredLocalTypesWithoutAnotherSchemaMigration() async throws {
    let fixture = try await makeKnowledgeDatabaseFixture(name: "Ontology")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let customType = KnowledgeEntityType(rawValue: "medical_case")
    try await fixture.database.registerOntologyType(
        key: customType,
        domain: "medicine",
        displayName: "Medizinischer Fall",
        description: "Lokal definierter Vorbereitungstyp"
    )
    let context = try #require(
        try await fixture.database.knowledgeExtractionContext(
            documentID: fixture.documentID,
            modelID: "qwen-test",
            modelVersion: "1"
        )
    )
    let base = testEnvelope(context: context)
    let entity = KnowledgeEntityCandidate(
        candidateID: "medical-1",
        type: customType,
        canonicalName: "Lokaler Testfall",
        confidence: 0.91,
        evidenceIDs: ["ev-1"]
    )
    let envelope = KnowledgeExtractionEnvelope(
        entities: [entity],
        evidence: base.evidence
    )
    let validated = try KnowledgeExtractionValidator().validate(
        envelope,
        context: context
    )
    try await fixture.database.storeValidatedKnowledge(validated)

    let ontology = try await fixture.database.ontologyTypes()
    #expect(ontology.contains { $0.key == customType && !$0.isBuiltIn })
    #expect(
        try await fixture.database.knowledgeEntityID(
            type: customType,
            canonicalName: "Lokaler Testfall"
        ) != nil
    )
}

private struct KnowledgeDatabaseFixture {
    let root: URL
    let database: SQLiteDatabase
    let documentID: Int64
    let file: DiscoveredPDF
    let hash: String
    let pages: [ExtractedPage]
    let chunks: [TextChunk]
}

private func makeKnowledgeDatabaseFixture(
    name: String
) async throws -> KnowledgeDatabaseFixture {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "FindoraKnowledgeTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let database = SQLiteDatabase(url: root.appending(path: "test.sqlite3"))
    try await database.initialize()
    let url = root.appending(path: "\(name).pdf")
    try Data("synthetic-local-test".utf8).write(to: url)
    let file = DiscoveredPDF(
        url: url,
        relativePath: url.lastPathComponent,
        fileName: url.lastPathComponent,
        size: Int64(try Data(contentsOf: url).count),
        modifiedAt: Date(timeIntervalSince1970: 1_800_000_000),
        resourceIdentifier: nil,
        volumeIdentifier: nil
    )
    let hash = SHA256Hasher().hash(data: Data("knowledge-test-\(name)".utf8))
    let text = "Rechnung 4711 wurde von Solar Nord GmbH am 30.07.2026 erstellt."
    let pages = [ExtractedPage(pageNumber: 1, text: text)]
    let chunks = [TextChunk(id: "\(hash)-1-0", pageNumber: 1, ordinal: 0, text: text)]
    let documentID = try await database.indexDocument(
        file: file,
        hash: hash,
        pages: pages,
        chunks: chunks,
        embeddings: [[0.1, 0.2]],
        embeddingModelID: "test-embedding",
        embeddingModelVersion: "1",
        ocrPerformed: false
    )
    return .init(
        root: root,
        database: database,
        documentID: documentID,
        file: file,
        hash: hash,
        pages: pages,
        chunks: chunks
    )
}

private func testKnowledgeContext() -> KnowledgeExtractionContext {
    KnowledgeExtractionContext(
        documentID: 1,
        documentHash: "hash",
        pages: [
            KnowledgeSourcePage(
                pageID: 10,
                pageNumber: 1,
                text: "Rechnung 4711 wurde von Solar Nord GmbH erstellt.",
                validChunkIDs: ["chunk-1"]
            )
        ],
        extractionModelID: "qwen-test",
        extractionModelVersion: "1",
        promptVersion: "test-v1"
    )
}

private func testEnvelope(
    context: KnowledgeExtractionContext,
    quote: String = "Rechnung 4711",
    pageID: Int64? = nil,
    claimType: KnowledgeClaimType = .explicitFact
) -> KnowledgeExtractionEnvelope {
    let page = context.pages[0]
    let evidence = KnowledgeEvidenceCandidate(
        id: "ev-1",
        pageID: pageID ?? page.pageID,
        pageNumber: page.pageNumber,
        chunkID: page.validChunkIDs.first,
        quote: quote,
        source: .nativePDF,
        confidence: 0.99
    )
    let entity = KnowledgeEntityCandidate(
        candidateID: "entity-1",
        type: .invoice,
        canonicalName: "Rechnung 4711",
        confidence: 0.96,
        evidenceIDs: ["ev-1"]
    )
    let fact = KnowledgeFactCandidate(
        candidateID: "fact-1",
        subjectEntityID: "entity-1",
        predicate: "invoice_number",
        literalValue: "4711",
        valueType: .string,
        claimType: claimType,
        confidence: 0.95,
        evidenceIDs: ["ev-1"]
    )
    return KnowledgeExtractionEnvelope(
        schemaVersion: 1,
        documentType: "invoice",
        documentTypeConfidence: 0.96,
        entities: [entity],
        facts: [fact],
        evidence: [evidence]
    )
}

private actor TestStructuredKnowledgeGenerator: StructuredKnowledgeGenerating {
    let modelID: String
    let modelVersion: String
    let output: Data
    private(set) var unloadCount = 0

    init(modelID: String, modelVersion: String, output: Data) {
        self.modelID = modelID
        self.modelVersion = modelVersion
        self.output = output
    }

    func generateStructuredJSON(
        instructions: String,
        prompt: String,
        maximumTokens: Int
    ) async throws -> Data {
        output
    }

    func unload() async {
        unloadCount += 1
    }
}

private actor GenerativeGateProbe {
    private var activeOperations = 0
    private var maximumOperations = 0
    private var cleanups = 0

    func runOperation() async {
        activeOperations += 1
        maximumOperations = max(maximumOperations, activeOperations)
        try? await Task.sleep(for: .milliseconds(20))
        activeOperations -= 1
    }

    func recordCleanup() {
        cleanups += 1
    }

    func maximumConcurrentOperations() -> Int {
        maximumOperations
    }

    func cleanupCount() -> Int {
        cleanups
    }
}
