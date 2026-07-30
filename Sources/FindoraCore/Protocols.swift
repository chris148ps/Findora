import Foundation

public protocol DocumentScanning: Sendable {
    func scan(root: URL) async throws -> [DiscoveredPDF]
}

public protocol FileStabilityChecking: Sendable {
    func waitUntilStable(_ file: DiscoveredPDF) async throws -> DiscoveredPDF
}

public protocol PDFTextExtracting: Sendable {
    func extractPages(from url: URL) throws -> [ExtractedPage]
    func pageCount(of url: URL) throws -> Int
}

public protocol Chunking: Sendable {
    func chunks(for pages: [ExtractedPage], documentHash: String) -> [TextChunk]
}

public protocol EmbeddingProviding: Sendable {
    var modelID: String { get }
    var modelVersion: String { get }
    var dimensions: Int { get }
    func embed(documents: [String]) async throws -> [[Float]]
    func embed(query: String) async throws -> [Float]
}

public protocol OCRProcessing: Sendable {
    func process(_ file: DiscoveredPDF, configuration: OCRConfiguration) async throws -> OCRResult
    func process(
        _ file: DiscoveredPDF,
        configuration: OCRConfiguration,
        onEngineChange: @Sendable (OCREngine) async -> Void
    ) async throws -> OCRResult
}

public extension OCRProcessing {
    func process(
        _ file: DiscoveredPDF,
        configuration: OCRConfiguration,
        onEngineChange: @Sendable (OCREngine) async -> Void
    ) async throws -> OCRResult {
        let result = try await process(file, configuration: configuration)
        await onEngineChange(result.engine)
        return result
    }
}

public protocol OCRProvider: OCRProcessing {
    var engine: OCREngine { get }
}

public protocol OpticalDocumentAnalyzing: Sendable {
    var modelID: String { get }
    var modelVersion: String { get }

    func analyzePage(
        fileURL: URL,
        pageNumber: Int,
        timeout: Duration
    ) async throws -> OpticalPageAnalysis

    func unload() async
}

public protocol AnswerGenerating: Sendable {
    func answer(question: String, sources: [SearchSource]) async throws -> String
    func unload() async
}

/// Local model boundary for versioned, schema-constrained knowledge tasks.
/// Implementations return bytes only. They never receive database access and
/// therefore cannot persist unchecked model output.
public protocol StructuredKnowledgeGenerating: Sendable {
    var modelID: String { get }
    var modelVersion: String { get }

    func generateStructuredJSON(
        instructions: String,
        prompt: String,
        maximumTokens: Int
    ) async throws -> Data

    func unload() async
}
