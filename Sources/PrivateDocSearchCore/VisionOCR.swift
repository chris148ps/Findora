import Foundation

/// Reserved boundary for a future local vision OCR implementation.
/// No vision model is downloaded, activated, or used by the current pipeline.
public protocol VisionOCRProviding: Sendable {
    var modelID: String { get }
    var modelVersion: String { get }
    func recognizePages(in pdf: URL, languages: [String]) async throws -> [ExtractedPage]
    func unload() async
}

public struct VisionOCRDescriptor: Codable, Equatable, Sendable {
    public let modelID: String
    public let modelVersion: String
    public let estimatedRuntimeRAMBytes: Int64
    public let isEnabled: Bool

    public init(
        modelID: String,
        modelVersion: String,
        estimatedRuntimeRAMBytes: Int64,
        isEnabled: Bool = false
    ) {
        self.modelID = modelID
        self.modelVersion = modelVersion
        self.estimatedRuntimeRAMBytes = estimatedRuntimeRAMBytes
        self.isEnabled = isEnabled
    }
}
