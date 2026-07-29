import Foundation

public actor HybridSearchService {
    private struct Candidate: Sendable {
        var source: SearchSource
        var lexicalRank: Int?
        var semanticScore: Double?
        var combinedScore: Double
    }

    private let database: SQLiteDatabase
    private let embedder: any EmbeddingProviding
    private let semanticEnabled: Bool
    private let rulePlanner = RuleBasedSearchPlanner()

    public init(
        database: SQLiteDatabase,
        embedder: any EmbeddingProviding,
        semanticEnabled: Bool = true
    ) {
        self.database = database
        self.embedder = embedder
        self.semanticEnabled = semanticEnabled
    }

    public func search(
        _ query: String,
        contentFilter: SearchContentFilter = .all,
        limit: Int = 12
    ) async throws -> [SearchSource] {
        let plan = rulePlanner.plan(query: query)
        return try await search(
            query,
            plan: plan,
            contentFilter: contentFilter,
            limit: limit
        ).directMatches
    }

    public func search(
        _ query: String,
        plan: SearchPlan,
        contentFilter: SearchContentFilter = .all,
        limit: Int = 12
    ) async throws -> SearchOutcome {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return SearchOutcome(plan: plan, directMatches: [], possibleMatches: [])
        }

        let lexicalQuery = plan.retrievalTerms.isEmpty
            ? trimmed
            : plan.retrievalTerms.joined(separator: " ")
        async let lexical = database.lexicalSearch(
            query: lexicalQuery,
            contentFilter: contentFilter,
            limit: 80
        )
        async let fileNames = database.fileNameSearch(
            terms: plan.hardTerms + plan.documentTypes + [trimmed],
            contentFilter: contentFilter,
            limit: 40
        )
        let (lexicalResults, fileNameResults) =
            try await (lexical, fileNames)
        var semantic: [(SearchSource, Double)] = []
        if semanticEnabled {
            let vector = try await embedder.embed(
                query: semanticQuery(query: trimmed, plan: plan)
            )
            let stored = try await database.vectorRows(
                modelID: embedder.modelID,
                modelVersion: embedder.modelVersion,
                contentFilter: contentFilter
            )
            semantic = Array(
                stored
                    .map { source, candidate in
                        (source, Self.cosine(vector, candidate))
                    }
                    .filter { $0.1 >= 0.05 }
                    .sorted { $0.1 > $1.1 }
                    .prefix(80)
            )
        }

        var candidates: [String: Candidate] = [:]
        for (rank, source) in lexicalResults.enumerated() {
            candidates[source.id] = Candidate(
                source: source,
                lexicalRank: rank,
                semanticScore: nil,
                combinedScore: 0.55 / Double(61 + rank)
            )
        }
        for (rank, source) in fileNameResults.enumerated() {
            let contribution = 0.58 / Double(61 + rank)
            if var existing = candidates[source.id] {
                existing.lexicalRank = min(existing.lexicalRank ?? rank, rank)
                existing.combinedScore += contribution
                candidates[source.id] = existing
            } else {
                candidates[source.id] = Candidate(
                    source: source,
                    lexicalRank: rank,
                    semanticScore: nil,
                    combinedScore: contribution
                )
            }
        }
        for (rank, item) in semantic.enumerated() {
            let (source, semanticScore) = item
            let contribution = 0.45 / Double(61 + rank)
            if var existing = candidates[source.id] {
                existing.semanticScore = semanticScore
                existing.combinedScore += contribution
                candidates[source.id] = existing
            } else {
                candidates[source.id] = Candidate(
                    source: source,
                    lexicalRank: nil,
                    semanticScore: semanticScore,
                    combinedScore: contribution
                )
            }
        }

        let viable = candidates.values.filter {
            $0.combinedScore >= 0.0065
                && (
                    $0.lexicalRank != nil
                    || ($0.semanticScore ?? -1) >= 0.10
                )
        }
        let evidence = try await database.searchEvidence(
            documentIDs: Set(viable.map(\.source.documentID))
        )
        let queryTerms = Self.searchTerms(
            query: trimmed,
            plan: plan
        )
        let ranked = viable.compactMap { candidate in
            Self.rerank(
                candidate,
                plan: plan,
                query: trimmed,
                queryTerms: queryTerms,
                evidence: evidence[candidate.source.documentID]
            )
        }.sorted {
            if $0.relevance != $1.relevance {
                return Self.relevanceOrder($0.relevance) < Self.relevanceOrder($1.relevance)
            }
            return $0.score > $1.score
        }

        var direct: [SearchSource] = []
        var possible: [SearchSource] = []
        var directPages: Set<String> = []
        var possiblePages: Set<String> = []
        var pagesPerDocument: [Int64: Int] = [:]
        for source in ranked {
            let pageKey = "\(source.documentID)#\(source.pageNumber)"
            switch source.relevance {
            case .veryRelevant, .relevant:
                guard direct.count < limit,
                      directPages.insert(pageKey).inserted,
                      pagesPerDocument[source.documentID, default: 0] < 4 else {
                    continue
                }
                direct.append(source)
                pagesPerDocument[source.documentID, default: 0] += 1
            case .possiblyRelevant:
                guard possible.count < min(6, limit),
                      possiblePages.insert(pageKey).inserted else { continue }
                possible.append(source)
            }
        }
        return SearchOutcome(
            plan: plan,
            directMatches: direct,
            possibleMatches: possible
        )
    }

    private func semanticQuery(query: String, plan: SearchPlan) -> String {
        let concepts = (plan.topics + plan.documentTypes + plan.optionalTerms.prefix(8))
            .joined(separator: " ")
        return concepts.isEmpty ? query : "\(query) \(concepts)"
    }

    private static func rerank(
        _ candidate: Candidate,
        plan: SearchPlan,
        query: String,
        queryTerms: [String],
        evidence: DocumentSearchEvidence?
    ) -> SearchSource? {
        guard let evidence, !evidence.chunks.isEmpty else { return nil }
        let fileName = candidate.source.fileName
        let allDocumentText = evidence.chunks.map(\.text).joined(separator: "\n")
        let hardTerms = plan.hardTerms
        let matchedEntities = plan.requiredEntities.filter {
            contains($0, in: allDocumentText) || contains($0, in: fileName)
        }
        let matchedHardTerms = hardTerms.filter {
            contains($0, in: allDocumentText) || contains($0, in: fileName)
        }
        guard hardTerms.isEmpty || (
            plan.mustMatchAll
                ? matchedHardTerms.count == hardTerms.count
                : !matchedHardTerms.isEmpty
        ) else {
            return nil
        }

        let matchedTopics = plan.topics.filter { topic in
            contains(topic, in: allDocumentText)
                || plan.optionalTerms.contains(where: { contains($0, in: allDocumentText) })
        }
        let topicsSatisfied = plan.topics.isEmpty
            || (plan.mustMatchAll
                ? matchedTopics.count == plan.topics.count
                : !matchedTopics.isEmpty)

        let scoringTerms = queryTerms + hardTerms + plan.topics + plan.optionalTerms
        let pageChunks = evidence.chunks.filter {
            $0.pageNumber == candidate.source.pageNumber
        }
        let bestChunk = (pageChunks.isEmpty ? evidence.chunks : pageChunks).max { lhs, rhs in
            matchCount(scoringTerms, in: lhs.text) < matchCount(scoringTerms, in: rhs.text)
        } ?? evidence.chunks[0]
        let hardInBestChunk = hardTerms.filter {
            contains($0, in: bestChunk.text)
        }
        let topicsInBestChunk = plan.topics.filter { topic in
            contains(topic, in: bestChunk.text)
                || plan.optionalTerms.contains(where: { contains($0, in: bestChunk.text) })
        }
        let sameChunk = (hardTerms.isEmpty || hardInBestChunk.count == hardTerms.count)
            && (plan.topics.isEmpty || topicsInBestChunk.count == plan.topics.count)

        let phraseInText = containsPhrase(query, in: bestChunk.text)
        let phraseInFileName = containsPhrase(query, in: fileName)
        let matchedQueryTerms = queryTerms.filter {
            contains($0, in: bestChunk.text) || contains($0, in: fileName)
        }
        let hasExactEvidence = candidate.lexicalRank != nil
            || phraseInText
            || phraseInFileName
        let semanticScore = candidate.semanticScore ?? -1
        let relevance: SearchRelevance
        if topicsSatisfied {
            if sameChunk && (!hardTerms.isEmpty || !plan.topics.isEmpty) {
                relevance = .veryRelevant
            } else if !hardTerms.isEmpty || !plan.topics.isEmpty {
                relevance = .relevant
            } else if hasExactEvidence || semanticScore >= 0.18 {
                relevance = .relevant
            } else {
                return nil
            }
        } else if !hardTerms.isEmpty, semanticScore >= 0.16 {
            relevance = .possiblyRelevant
        } else {
            return nil
        }

        var kinds: [SearchMatchKind] = []
        if hasExactEvidence { kinds.append(.exact) }
        if semanticScore >= 0.10 { kinds.append(.semantic) }
        if hardTerms.contains(where: { contains($0, in: fileName) }) {
            kinds.append(.fileName)
        }
        kinds.append(sameChunk ? .sameChunk : .sameDocument)

        let reason = reason(
            matchedEntities: matchedEntities,
            matchedTopics: matchedTopics,
            fileNameMatched: kinds.contains(.fileName),
            sameChunk: sameChunk,
            pageNumber: bestChunk.pageNumber
        )
        let excerpt = bestChunk.text.count > 560
            ? String(bestChunk.text.prefix(557)) + "…"
            : bestChunk.text
        var score = candidate.combinedScore
        if sameChunk { score += 0.02 }
        score += Double(matchedHardTerms.count + matchedTopics.count) * 0.005
        if phraseInText { score += 0.16 }
        if phraseInFileName { score += 0.20 }
        if matchedQueryTerms.count == queryTerms.count, !queryTerms.isEmpty {
            score += 0.08
        }
        if queryTerms.contains(where: isIdentifierLike),
           matchedQueryTerms.contains(where: isIdentifierLike) {
            score += 0.18
        }
        if bestChunk.ocrQuality == OCRQualityStatus.likelyFailed.rawValue {
            score -= 0.01
        }
        return SearchSource(
            id: "\(bestChunk.chunkID)|\(candidate.source.absolutePath)",
            documentID: candidate.source.documentID,
            chunkID: bestChunk.chunkID,
            fileName: candidate.source.fileName,
            absolutePath: candidate.source.absolutePath,
            relativePath: candidate.source.relativePath,
            pageNumber: bestChunk.pageNumber,
            excerpt: excerpt,
            score: score,
            relevance: relevance,
            matchedEntities: matchedEntities,
            matchedTopics: matchedTopics,
            matchedTerms: matchedQueryTerms,
            reason: reason,
            ocrQuality: bestChunk.ocrQuality,
            textSource: bestChunk.textSource,
            matchKinds: kinds,
            contentType: candidate.source.contentType,
            mailSubject: candidate.source.mailSubject,
            mailSender: candidate.source.mailSender,
            mailDate: candidate.source.mailDate,
            mailbox: candidate.source.mailbox,
            parentEmailSubject: candidate.source.parentEmailSubject,
            parentEmailSender: candidate.source.parentEmailSender,
            parentEmailDate: candidate.source.parentEmailDate
        )
    }

    private static func reason(
        matchedEntities: [String],
        matchedTopics: [String],
        fileNameMatched: Bool,
        sameChunk: Bool,
        pageNumber: Int
    ) -> String {
        var evidence: [String] = []
        if !matchedEntities.isEmpty {
            evidence.append("„\(matchedEntities.joined(separator: "“, „"))“")
        }
        if !matchedTopics.isEmpty {
            evidence.append("Thema \(matchedTopics.joined(separator: ", "))")
        }
        if evidence.isEmpty {
            evidence.append("die Suchbegriffe")
        }
        let location = fileNameMatched
            ? "im Dateinamen und im belegten Dokumentkontext"
            : sameChunk
                ? "gemeinsam im Textabschnitt"
                : "im selben Dokument"
        return "Gefunden, weil \(evidence.joined(separator: " und ")) \(location) auf Seite \(pageNumber) nachgewiesen wurden."
    }

    private static func matchCount(_ terms: [String], in text: String) -> Int {
        terms.filter { contains($0, in: text) }.count
    }

    private static func contains(_ term: String, in text: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: term)
        let pattern = #"(?<![\p{L}\p{N}])"# + escaped + #"(?:s)?(?![\p{L}\p{N}])"#
        return text.range(
            of: pattern,
            options: [.regularExpression, .caseInsensitive, .diacriticInsensitive]
        ) != nil
    }

    private static func containsPhrase(_ phrase: String, in text: String) -> Bool {
        let normalizedPhrase = phrase
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedText = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return !normalizedPhrase.isEmpty && normalizedText.contains(normalizedPhrase)
    }

    private static func searchTerms(
        query: String,
        plan: SearchPlan
    ) -> [String] {
        var seen: Set<String> = []
        return (plan.hardTerms + plan.topics + plan.retrievalTerms + [
            query.trimmingCharacters(in: .whitespacesAndNewlines)
        ]).filter {
            !$0.isEmpty
                && seen.insert($0.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                )).inserted
        }
    }

    private static func isIdentifierLike(_ value: String) -> Bool {
        value.range(
            of: #"(?=.*\d)[\p{L}\p{N}][\p{L}\p{N}./:+_-]{3,}"#,
            options: .regularExpression
        ) != nil
    }

    private static func relevanceOrder(_ relevance: SearchRelevance) -> Int {
        switch relevance {
        case .veryRelevant: 0
        case .relevant: 1
        case .possiblyRelevant: 2
        }
    }

    private static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return -1 }
        return Double(zip(lhs, rhs).reduce(Float.zero) { $0 + $1.0 * $1.1 })
    }
}
