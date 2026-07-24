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
}

public protocol AnswerGenerating: Sendable {
    func answer(question: String, sources: [SearchSource]) async throws -> String
    func unload() async
}

