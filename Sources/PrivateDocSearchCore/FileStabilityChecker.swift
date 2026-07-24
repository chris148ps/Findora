import Foundation

public struct FileStabilityChecker: FileStabilityChecking {
    private let delay: Duration

    public init(delay: Duration = .seconds(5)) {
        self.delay = delay
    }

    public func waitUntilStable(_ file: DiscoveredPDF) async throws -> DiscoveredPDF {
        let first = try snapshot(file.url)
        try await Task.sleep(for: delay)
        try Task.checkCancellation()
        let second = try snapshot(file.url)

        guard first.size == second.size, first.modified == second.modified else {
            throw PrivateDocSearchError.unstableFile(file.url.path)
        }

        return DiscoveredPDF(
            url: file.url,
            relativePath: file.relativePath,
            fileName: file.fileName,
            size: second.size,
            modifiedAt: second.modified,
            resourceIdentifier: file.resourceIdentifier,
            volumeIdentifier: file.volumeIdentifier
        )
    }

    private func snapshot(_ url: URL) throws -> (size: Int64, modified: Date) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else {
            throw PrivateDocSearchError.unstableFile(url.path)
        }
        return (size.int64Value, modified)
    }
}
