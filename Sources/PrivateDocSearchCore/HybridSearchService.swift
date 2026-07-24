import Foundation

public actor HybridSearchService {
    private let database: SQLiteDatabase
    private let embedder: any EmbeddingProviding

    public init(database: SQLiteDatabase, embedder: any EmbeddingProviding) {
        self.database = database
        self.embedder = embedder
    }

    public func search(_ query: String, limit: Int = 12) async throws -> [SearchSource] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        async let lexical = database.lexicalSearch(query: trimmed, limit: 40)
        async let queryVector = embedder.embed(query: trimmed)
        let (lexicalResults, vector) = try await (lexical, queryVector)
        let stored = try await database.vectorRows(
            modelID: embedder.modelID,
            modelVersion: embedder.modelVersion
        )

        let semantic = stored
            .map { source, candidate -> SearchSource in
                var scored = source
                let score = Self.cosine(vector, candidate)
                scored = SearchSource(
                    id: source.id,
                    documentID: source.documentID,
                    chunkID: source.chunkID,
                    fileName: source.fileName,
                    absolutePath: source.absolutePath,
                    relativePath: source.relativePath,
                    pageNumber: source.pageNumber,
                    excerpt: source.excerpt,
                    score: score
                )
                return scored
            }
            .filter { $0.score > 0.05 }
            .sorted { $0.score > $1.score }
            .prefix(40)

        var fused: [String: (SearchSource, Double)] = [:]
        for (rank, source) in lexicalResults.enumerated() {
            fused[source.id] = (source, 0.55 / Double(60 + rank + 1))
        }
        for (rank, source) in semantic.enumerated() {
            let semanticScore = 0.45 / Double(60 + rank + 1)
            if let existing = fused[source.id] {
                fused[source.id] = (existing.0, existing.1 + semanticScore)
            } else {
                fused[source.id] = (source, semanticScore)
            }
        }

        var perDocument: [Int64: Int] = [:]
        return fused.values
            .sorted { $0.1 > $1.1 }
            .compactMap { source, score in
                let count = perDocument[source.documentID, default: 0]
                guard count < 3 else { return nil }
                perDocument[source.documentID] = count + 1
                return SearchSource(
                    id: source.id,
                    documentID: source.documentID,
                    chunkID: source.chunkID,
                    fileName: source.fileName,
                    absolutePath: source.absolutePath,
                    relativePath: source.relativePath,
                    pageNumber: source.pageNumber,
                    excerpt: source.excerpt,
                    score: score
                )
            }
            .prefix(limit)
            .map { $0 }
    }

    private static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return -1 }
        return Double(zip(lhs, rhs).reduce(Float.zero) { $0 + $1.0 * $1.1 })
    }
}

