import Foundation

public enum KnowledgePipelineError: LocalizedError, Equatable, Sendable {
    case noSourcePages
    case repeatedInvalidOutput
    case independentReviewRejectedAllClaims

    public var errorDescription: String? {
        switch self {
        case .noSourcePages:
            "Für die Wissensextraktion liegt kein belegbarer Seitentext vor."
        case .repeatedInvalidOutput:
            "Die lokale Modellausgabe war auch nach einer Korrektur nicht schema- und quellenkonform."
        case .independentReviewRejectedAllClaims:
            "Die unabhängige Zweitprüfung hat keine belastbare Aussage bestätigt."
        }
    }
}

public struct KnowledgeExtractionPolicy: Equatable, Sendable {
    public let automaticSecondReview: Bool
    public let secondReviewConfidenceThreshold: Double
    public let maximumInputCharacters: Int
    public let maximumOutputTokens: Int

    public init(
        automaticSecondReview: Bool = true,
        secondReviewConfidenceThreshold: Double = 0.78,
        maximumInputCharacters: Int = 24_000,
        maximumOutputTokens: Int = 2_048
    ) {
        self.automaticSecondReview = automaticSecondReview
        self.secondReviewConfidenceThreshold = min(
            max(secondReviewConfidenceThreshold, 0),
            1
        )
        self.maximumInputCharacters = min(max(maximumInputCharacters, 2_000), 48_000)
        self.maximumOutputTokens = min(max(maximumOutputTokens, 256), 4_096)
    }
}

/// Executes local structured extraction and owns the only write path from a
/// generative model into the knowledge layer. Invalid output is never partially
/// stored. A second model receives the original evidence and a neutral schema,
/// not the first model's rationale.
public struct KnowledgeExtractionCoordinator: Sendable {
    private let database: SQLiteDatabase
    private let primary: any StructuredKnowledgeGenerating
    private let independentReviewer: (any StructuredKnowledgeGenerating)?
    private let validator: KnowledgeExtractionValidator
    private let policy: KnowledgeExtractionPolicy

    public init(
        database: SQLiteDatabase,
        primary: any StructuredKnowledgeGenerating,
        independentReviewer: (any StructuredKnowledgeGenerating)? = nil,
        validator: KnowledgeExtractionValidator = .init(),
        policy: KnowledgeExtractionPolicy = .init()
    ) {
        self.database = database
        self.primary = primary
        self.independentReviewer = independentReviewer
        self.validator = validator
        self.policy = policy
    }

    @discardableResult
    public func extractAndStore(
        context: KnowledgeExtractionContext
    ) async throws -> ValidatedKnowledgeExtraction {
        guard !context.pages.isEmpty else {
            throw KnowledgePipelineError.noSourcePages
        }
        let prompt = Self.prompt(context: context, limit: policy.maximumInputCharacters)
        let instructions = Self.instructions
        do {
            let primaryResult = try await generateValidated(
                with: primary,
                instructions: instructions,
                prompt: prompt,
                context: context
            )

            let result: ValidatedKnowledgeExtraction
            if policy.automaticSecondReview,
               let independentReviewer,
               Self.needsSecondReview(
                   primaryResult.envelope,
                   threshold: policy.secondReviewConfidenceThreshold
               ) {
                // The primary runtime is fully released before Phi is loaded.
                // This is the hard one-large-model-at-a-time boundary on 8-GB
                // systems, independent of the runtimes' idle timers.
                await primary.unload()
                let reviewContext = KnowledgeExtractionContext(
                    documentID: context.documentID,
                    documentHash: context.documentHash,
                    pages: context.pages,
                    extractionModelID: independentReviewer.modelID,
                    extractionModelVersion: independentReviewer.modelVersion,
                    promptVersion: "\(context.promptVersion)-independent-review",
                    schemaVersion: context.schemaVersion
                )
                let review = try await generateValidated(
                    with: independentReviewer,
                    instructions: Self.independentReviewInstructions,
                    prompt: prompt,
                    context: reviewContext
                )
                await independentReviewer.unload()
                result = try Self.consensus(
                    primary: primaryResult,
                    review: review,
                    originalContext: context
                )
            } else {
                await primary.unload()
                result = primaryResult
            }

            let durableResult = Self.removingUncertainClaims(from: result)
            try await database.storeValidatedKnowledge(durableResult)
            return durableResult
        } catch {
            await primary.unload()
            if let independentReviewer {
                await independentReviewer.unload()
            }
            throw error
        }
    }

    private func generateValidated(
        with generator: any StructuredKnowledgeGenerating,
        instructions: String,
        prompt: String,
        context: KnowledgeExtractionContext
    ) async throws -> ValidatedKnowledgeExtraction {
        var lastValidationError: Error?
        for attempt in 0..<2 {
            let correction = attempt == 0
                ? ""
                : """

                Der vorige Versuch wurde von der deterministischen Prüfung abgelehnt.
                Erzeuge das Objekt vollständig neu. Nutze ausschließlich wörtliche
                Belege aus den angegebenen Seiten und alle Pflichtfelder des Schemas.
                """
            let data = try await generator.generateStructuredJSON(
                instructions: instructions,
                prompt: prompt + correction,
                maximumTokens: policy.maximumOutputTokens
            )
            do {
                return try validator.decodeAndValidate(data, context: context)
            } catch {
                lastValidationError = error
            }
        }
        if let lastValidationError {
            throw lastValidationError
        }
        throw KnowledgePipelineError.repeatedInvalidOutput
    }

    private static func needsSecondReview(
        _ envelope: KnowledgeExtractionEnvelope,
        threshold: Double
    ) -> Bool {
        !envelope.uncertainties.isEmpty
            || envelope.facts.contains { $0.confidence < threshold }
            || envelope.relations.contains { $0.confidence < threshold }
            || envelope.projectSignals.contains { $0.weight < threshold }
    }

    private static func consensus(
        primary: ValidatedKnowledgeExtraction,
        review: ValidatedKnowledgeExtraction,
        originalContext: KnowledgeExtractionContext
    ) throws -> ValidatedKnowledgeExtraction {
        let reviewedFacts = Set(
            review.envelope.facts.map {
                factSignature($0, envelope: review.envelope)
            }
        )
        let reviewedRelations = Set(
            review.envelope.relations.map {
                relationSignature($0, envelope: review.envelope)
            }
        )
        let reviewedProjectSignals = Set(
            review.envelope.projectSignals.map(projectSignalSignature)
        )
        let facts = primary.envelope.facts.filter {
            reviewedFacts.contains(factSignature($0, envelope: primary.envelope))
        }
        let relations = primary.envelope.relations.filter {
            reviewedRelations.contains(
                relationSignature($0, envelope: primary.envelope)
            )
        }
        let projectSignals = primary.envelope.projectSignals.filter {
            reviewedProjectSignals.contains(projectSignalSignature($0))
        }
        if (
            !primary.envelope.facts.isEmpty
                || !primary.envelope.relations.isEmpty
                || !primary.envelope.projectSignals.isEmpty
        ),
           facts.isEmpty,
           relations.isEmpty,
           projectSignals.isEmpty {
            throw KnowledgePipelineError.independentReviewRejectedAllClaims
        }
        let requiredEntityIDs = Set(
            facts.flatMap { [$0.subjectEntityID, $0.objectEntityID].compactMap(\.self) }
                + relations.flatMap { [$0.subjectEntityID, $0.objectEntityID] }
        )
        let entities = primary.envelope.entities.filter {
            requiredEntityIDs.contains($0.candidateID)
                || projectSignals.isEmpty == false
        }
        let requiredEvidenceIDs = Set(
            entities.flatMap(\.evidenceIDs)
                + facts.flatMap(\.evidenceIDs)
                + relations.flatMap(\.evidenceIDs)
                + projectSignals.flatMap(\.evidenceIDs)
        )
        let evidence = primary.envelope.evidence.filter {
            requiredEvidenceIDs.contains($0.id)
        }
        let envelope = KnowledgeExtractionEnvelope(
            schemaVersion: primary.envelope.schemaVersion,
            documentType: primary.envelope.documentType,
            documentTypeConfidence: primary.envelope.documentTypeConfidence,
            entities: entities,
            facts: facts,
            relations: relations,
            evidence: evidence,
            projectSignals: projectSignals,
            uncertainties: primary.envelope.uncertainties
                + [KnowledgeUncertainty(
                    kind: "independent_review",
                    description: "Unsichere Aussagen wurden nur bei unabhängiger Übereinstimmung übernommen.",
                    relatedCandidateIDs: []
                )]
        )
        return ValidatedKnowledgeExtraction(envelope: envelope, context: originalContext)
    }

    private static func factSignature(
        _ fact: KnowledgeFactCandidate,
        envelope: KnowledgeExtractionEnvelope
    ) -> String {
        let names = Dictionary(
            uniqueKeysWithValues: envelope.entities.map {
                ($0.candidateID, normalizedSignatureValue($0.canonicalName))
            }
        )
        return [
            names[fact.subjectEntityID] ?? "",
            fact.predicate.lowercased(),
            fact.objectEntityID.flatMap { names[$0] } ?? "",
            fact.literalValue?.lowercased() ?? "",
            fact.valueType.rawValue,
            fact.unit?.lowercased() ?? ""
        ].joined(separator: "\u{1f}")
    }

    private static func relationSignature(
        _ relation: KnowledgeRelationCandidate,
        envelope: KnowledgeExtractionEnvelope
    ) -> String {
        let names = Dictionary(
            uniqueKeysWithValues: envelope.entities.map {
                ($0.candidateID, normalizedSignatureValue($0.canonicalName))
            }
        )
        return [
            names[relation.subjectEntityID] ?? "",
            relation.predicate.lowercased(),
            names[relation.objectEntityID] ?? "",
            relation.validFrom ?? "",
            relation.validUntil ?? ""
        ].joined(separator: "\u{1f}")
    }

    private static func projectSignalSignature(
        _ signal: KnowledgeProjectSignal
    ) -> String {
        [
            normalizedSignatureValue(signal.kind),
            normalizedSignatureValue(signal.value)
        ].joined(separator: "\u{1f}")
    }

    private static func normalizedSignatureValue(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "de_DE")
        )
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removingUncertainClaims(
        from extraction: ValidatedKnowledgeExtraction
    ) -> ValidatedKnowledgeExtraction {
        let inferredFacts = extraction.envelope.facts.filter {
            $0.claimType == .modelInference
        }
        let inferredRelations = extraction.envelope.relations.filter {
            $0.claimType == .modelInference
        }
        guard !inferredFacts.isEmpty || !inferredRelations.isEmpty else {
            return extraction
        }
        let discardedIDs = Set(
            inferredFacts.map(\.candidateID)
                + inferredRelations.map(\.candidateID)
        )
        let retainedUncertainties = extraction.envelope.uncertainties.map {
            KnowledgeUncertainty(
                kind: $0.kind,
                description: $0.description,
                relatedCandidateIDs: $0.relatedCandidateIDs.filter {
                    !discardedIDs.contains($0)
                }
            )
        }
        let envelope = KnowledgeExtractionEnvelope(
            schemaVersion: extraction.envelope.schemaVersion,
            documentType: extraction.envelope.documentType,
            documentTypeConfidence: extraction.envelope.documentTypeConfidence,
            entities: extraction.envelope.entities,
            facts: extraction.envelope.facts.filter {
                $0.claimType != .modelInference
            },
            relations: extraction.envelope.relations.filter {
                $0.claimType != .modelInference
            },
            evidence: extraction.envelope.evidence,
            projectSignals: extraction.envelope.projectSignals,
            uncertainties: retainedUncertainties + [
                KnowledgeUncertainty(
                    kind: "discarded_model_inference",
                    description:
                        "Nicht ausdrücklich belegte Modellableitungen wurden nicht als Fakten gespeichert.",
                    relatedCandidateIDs: []
                )
            ]
        )
        return ValidatedKnowledgeExtraction(
            envelope: envelope,
            context: extraction.context
        )
    }

    private static let instructions = """
    Du extrahierst ausschließlich lokal belegtes Wissen als genau ein JSON-Objekt.
    Kein Markdown, keine Erklärung und keine zusätzlichen Felder. Nutze schemaVersion 1
    und die Felder documentType, documentTypeConfidence, entities, facts, relations,
    evidence, projectSignals und uncertainties. Jede Entität, jeder Fakt, jede Relation
    und jedes Projektsignal benötigt evidenceIds. Jeder Beleg benötigt id, pageId,
    pageNumber, quote, characterStart, characterEnd, chunkId, boundingBox, source und
    confidence. quote muss wörtlich im angegebenen Seitentext vorkommen. Verwende nur
    explicit_fact, calculated_fact oder model_inference. Nutzerbestätigungen und externe
    Prüfungen darfst du nicht behaupten. Fehlende Information kommt in uncertainties,
    niemals als erfundener Fakt.
    """

    private static let independentReviewInstructions = """
    Prüfe die Originalseiten unabhängig und extrahiere nur Aussagen, die dort wörtlich
    belegt sind. Du kennst keine Begründung eines anderen Modells. Antworte als genau ein
    JSON-Objekt nach schemaVersion 1 mit documentType, documentTypeConfidence, entities,
    facts, relations, evidence, projectSignals und uncertainties. Kein Markdown und keine
    zusätzlichen Felder. Jeder Kandidat benötigt einen wörtlichen Beleg mit gültiger
    pageId, pageNumber und Zeichenposition.
    """

    private static func prompt(
        context: KnowledgeExtractionContext,
        limit: Int
    ) -> String {
        var remaining = limit
        var blocks: [String] = []
        for page in context.pages.sorted(by: { $0.pageNumber < $1.pageNumber }) {
            guard remaining > 0 else { break }
            let prefix = String(page.text.prefix(remaining))
            remaining -= prefix.count
            blocks.append(
                """
                [PAGE id=\(page.pageID) number=\(page.pageNumber)]
                \(prefix)
                [/PAGE]
                """
            )
        }
        return """
        /no_think
        Dokumenthash: \(context.documentHash)
        Zulässige Chunk-IDs je Seite:
        \(context.pages.map { "\($0.pageID):\($0.validChunkIDs.sorted())" }.joined(separator: "\n"))

        \(blocks.joined(separator: "\n\n"))
        """
    }
}

public enum EntityResolutionLevel: String, Equatable, Sendable {
    case automatic
    case suggestion
    case separate
    case rejectedByRule = "rejected_by_rule"
}

public struct EntityResolutionDecision: Equatable, Sendable {
    public let level: EntityResolutionLevel
    public let confidence: Double
    public let reasons: [String]
}

/// Deterministic first stage. Embeddings and model suggestions may add evidence
/// later, but can never override a stored negative rule.
public struct DeterministicEntityResolver: Sendable {
    public init() {}

    public func decide(
        leftName: String,
        rightName: String,
        matchingIdentifiers: Int,
        matchingAddresses: Int,
        sharedContextSignals: Int,
        negativeRuleExists: Bool
    ) -> EntityResolutionDecision {
        if negativeRuleExists {
            return .init(level: .rejectedByRule, confidence: 1, reasons: ["negative_rule"])
        }
        let left = normalize(leftName)
        let right = normalize(rightName)
        var score = 0.0
        var reasons: [String] = []
        if left == right {
            score += 0.72
            reasons.append("normalized_name")
        }
        if matchingIdentifiers > 0 {
            score += 0.35
            reasons.append("identifier")
        }
        if matchingAddresses > 0 {
            score += 0.18
            reasons.append("address")
        }
        if sharedContextSignals >= 2 {
            score += 0.08
            reasons.append("shared_context")
        }
        let confidence = min(score, 1)
        if confidence >= 0.90 {
            return .init(level: .automatic, confidence: confidence, reasons: reasons)
        }
        if confidence >= 0.65 {
            return .init(level: .suggestion, confidence: confidence, reasons: reasons)
        }
        return .init(level: .separate, confidence: confidence, reasons: reasons)
    }

    public func normalize(_ value: String) -> String {
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "de_DE")
        )
        let parts = folded.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !["ag", "gmbh", "kg"].contains($0) }
        return parts.joined(separator: " ")
    }
}

public struct ProjectSignalAssessment: Equatable, Sendable {
    public let confidence: Double
    public let automaticallyLink: Bool
    public let reasons: [String]
    public let counterReasons: [String]
}

public struct ProjectSignalEvaluator: Sendable {
    public init() {}

    public func assess(
        matchingIdentifiers: Int,
        matchingAddresses: Int,
        sharedEntities: Int,
        timeProximity: Double,
        semanticSimilarity: Double,
        onlyCommonPersonName: Bool
    ) -> ProjectSignalAssessment {
        if onlyCommonPersonName && matchingIdentifiers == 0 && matchingAddresses == 0 {
            return .init(
                confidence: 0.15,
                automaticallyLink: false,
                reasons: [],
                counterReasons: ["common_name_only"]
            )
        }
        var score = min(Double(matchingIdentifiers) * 0.45, 0.70)
        score += min(Double(matchingAddresses) * 0.22, 0.30)
        score += min(Double(sharedEntities) * 0.07, 0.21)
        score += min(max(timeProximity, 0), 1) * 0.08
        score += min(max(semanticSimilarity, 0), 1) * 0.10
        score = min(score, 1)
        return .init(
            confidence: score,
            automaticallyLink: score >= 0.90
                && (matchingIdentifiers > 0 || matchingAddresses > 0),
            reasons: [
                matchingIdentifiers > 0 ? "identifier" : nil,
                matchingAddresses > 0 ? "address" : nil,
                sharedEntities > 0 ? "entities" : nil,
                timeProximity > 0.5 ? "time" : nil,
                semanticSimilarity > 0.6 ? "semantic" : nil
            ].compactMap(\.self),
            counterReasons: []
        )
    }
}

public struct KnowledgeQueryPlan: Equatable, Sendable {
    public let graphDepth: Int
    public let useFacts: Bool
    public let useSummaries: Bool
    public let useFullText: Bool
    public let useVectorSearch: Bool
    public let requireOriginalEvidence: Bool
}

public struct KnowledgeQueryPlanner: Sendable {
    public init() {}

    public func plan(
        hasResolvedEntity: Bool,
        modelsAvailable: Bool,
        asksForTimeRange: Bool
    ) -> KnowledgeQueryPlan {
        .init(
            graphDepth: hasResolvedEntity ? 3 : 1,
            useFacts: true,
            useSummaries: true,
            useFullText: true,
            useVectorSearch: modelsAvailable,
            requireOriginalEvidence: true
        )
    }
}

public struct KnowledgeAnswerClassifier: Sendable {
    public init() {}

    public func classify(
        question: String,
        answer: String,
        sources: [SearchSource]
    ) -> KnowledgeAnswerClass {
        guard !sources.isEmpty,
              answer != SourceCitationValidator.noEvidenceMessage,
              answer.range(
                of: #"\[S-\d{3}\]"#,
                options: .regularExpression
              ) != nil else {
            return .unknown
        }
        let normalizedQuestion = question.lowercased()
        let normalizedAnswer = answer.lowercased()
        if Self.containsAny(
            [
                "widerspruch",
                "widersprech",
                "konflikt",
                "abweichende angabe",
                "contradiction"
            ],
            in: normalizedAnswer
        ) {
            return .conflict
        }
        if Self.containsAny(
            ["berechne", "summe", "differenz", "durchschnitt", "calculate"],
            in: normalizedQuestion
        ) {
            return .calculated
        }
        if Self.containsAny(
            ["erfahrung", "muster", "trend", "typischerweise", "experience"],
            in: normalizedQuestion
        ) {
            return .experience
        }
        if Self.containsAny(
            ["wahrscheinlich", "möglicherweise", "unsicher", "probability"],
            in: normalizedAnswer
        ) {
            return .probability
        }
        return .secured
    }

    private static func containsAny(_ terms: [String], in text: String) -> Bool {
        terms.contains { text.contains($0) }
    }
}
