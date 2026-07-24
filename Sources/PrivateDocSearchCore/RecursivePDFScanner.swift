import Foundation

public struct RecursivePDFScanner: DocumentScanning {
    private let excludedRoots: [URL]

    public init(excludedRoots: [URL] = []) {
        self.excludedRoots = excludedRoots.map(\.standardizedFileURL)
    }

    public func scan(root: URL) async throws -> [DiscoveredPDF] {
        try Task.checkCancellation()

        var isDirectory: ObjCBool = false
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw PrivateDocSearchError.folderUnavailable(root.path)
        }

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .isHiddenKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey,
            .volumeIdentifierKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ]

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            throw PrivateDocSearchError.permissionDenied(root.path)
        }

        var found: [DiscoveredPDF] = []
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let standardized = url.standardizedFileURL

            if excludedRoots.contains(where: { standardized.path == $0.path || standardized.path.hasPrefix($0.path + "/") }) {
                enumerator.skipDescendants()
                continue
            }

            let values: URLResourceValues
            do {
                values = try standardized.resourceValues(forKeys: keys)
            } catch {
                continue
            }

            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true,
                  standardized.pathExtension.lowercased() == "pdf",
                  !Self.isTemporary(name: standardized.lastPathComponent) else {
                continue
            }

            let rootPath = root.standardizedFileURL.path
            let absolutePath = standardized.path
            let relativePath = absolutePath.hasPrefix(rootPath + "/")
                ? String(absolutePath.dropFirst(rootPath.count + 1))
                : standardized.lastPathComponent

            found.append(
                DiscoveredPDF(
                    url: standardized,
                    relativePath: relativePath,
                    fileName: standardized.lastPathComponent,
                    size: Int64(values.fileSize ?? 0),
                    modifiedAt: values.contentModificationDate ?? .distantPast,
                    resourceIdentifier: Self.identifierString(values.fileResourceIdentifier),
                    volumeIdentifier: Self.identifierString(values.volumeIdentifier),
                    isLocallyAvailable: values.isUbiquitousItem != true
                        || values.ubiquitousItemDownloadingStatus == .current,
                    availabilityError: values.isUbiquitousItem == true
                        && values.ubiquitousItemDownloadingStatus != .current
                        ? "Die Cloud-Datei ist derzeit nur als Platzhalter vorhanden."
                        : nil
                )
            )
        }

        return found.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    public static func isTemporary(name: String) -> Bool {
        let lowered = name.lowercased()
        if name.hasPrefix(".") || name.hasPrefix("~$") || name.hasPrefix(".privatedocsearch-ocr-") {
            return true
        }
        return [".part", ".partial", ".download", ".tmp", ".temp", ".crdownload"]
            .contains { lowered.hasSuffix($0) }
    }

    private static func identifierString(_ value: (any NSCopying & NSSecureCoding & NSObjectProtocol)?) -> String? {
        value.map { String(describing: $0) }
    }
}
