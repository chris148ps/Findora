import Foundation

public enum StorageKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case data
    case models

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .data: "Findora-Datenspeicher"
        case .models: "KI-Modellspeicher"
        }
    }

    fileprivate var directoryName: String {
        switch self {
        case .data: "FindoraData"
        case .models: "FindoraModels"
        }
    }
}

public enum StorageMigrationPhase: String, Codable, CaseIterable, Sendable {
    case preparation
    case copying
    case validating
    case switching
    case completed
    case failed
    case rollbackRequired

    public var displayName: String {
        switch self {
        case .preparation: "Vorbereitung"
        case .copying: "Kopieren"
        case .validating: "Validieren"
        case .switching: "Umschalten"
        case .completed: "Abgeschlossen"
        case .failed: "Fehlgeschlagen"
        case .rollbackRequired: "Rückfall erforderlich"
        }
    }
}

public struct StorageMigrationRecord: Codable, Equatable, Sendable {
    public let id: String
    public let kind: StorageKind
    public let sourcePath: String
    public let destinationPath: String
    public var phase: StorageMigrationPhase
    public var copiedFiles: Int
    public var totalFiles: Int
    public var copiedBytes: Int64
    public var totalBytes: Int64
    public var lastErrorCategory: String?
    public let createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?
}

public struct StorageMigrationProgress: Equatable, Sendable {
    public let phase: StorageMigrationPhase
    public let copiedFiles: Int
    public let totalFiles: Int
    public let copiedBytes: Int64
    public let totalBytes: Int64
}

public struct StorageMigrationEstimate: Equatable, Sendable {
    public let fileCount: Int
    public let totalBytes: Int64
    public let assessment: StorageTargetAssessment

    public init(
        fileCount: Int,
        totalBytes: Int64,
        assessment: StorageTargetAssessment
    ) {
        self.fileCount = fileCount
        self.totalBytes = totalBytes
        self.assessment = assessment
    }
}

public struct StorageUsageSnapshot: Equatable, Sendable {
    public let databaseAndIndexBytes: Int64
    public let textBytes: Int64
    public let embeddingBytes: Int64
    public let previewBytes: Int64
    public let archivedSourceBytes: Int64
    public let archivedAttachmentBytes: Int64
    public let modelBytes: Int64
    public let temporaryBytes: Int64
    public let logBytes: Int64
    public let totalBytes: Int64
    public let availableDataBytes: Int64?
    public let availableModelBytes: Int64?
    public let capacityLevel: StorageCapacityLevel
}

public enum StorageCapacityLevel: String, Codable, CaseIterable, Sendable {
    case sufficient
    case low
    case critical
}

public struct StorageTargetAssessment: Equatable, Sendable {
    public let target: URL
    public let fileSystemDescription: String
    public let isLocal: Bool
    public let isReadOnly: Bool
    public let availableBytes: Int64?
    public let capacityLevel: StorageCapacityLevel
    public let blockingReasons: [String]
    public let warnings: [String]

    public var isAllowed: Bool {
        blockingReasons.isEmpty
    }
}

public struct StorageStartupSelection: Sendable {
    public let dataURL: URL
    public let modelURL: URL
    public let dataIsCustom: Bool
    public let modelsAreCustom: Bool
    public let dataIsAvailable: Bool
    public let modelsAreAvailable: Bool
    public let dataAccess: ResolvedStorageLocation?
    public let modelAccess: ResolvedStorageLocation?
}

public final class ResolvedStorageLocation: @unchecked Sendable {
    public let url: URL
    private var accessingSecurityScope: Bool

    init(url: URL, accessingSecurityScope: Bool) {
        self.url = url
        self.accessingSecurityScope = accessingSecurityScope
    }

    deinit {
        stopAccess()
    }

    public func stopAccess() {
        if accessingSecurityScope {
            url.stopAccessingSecurityScopedResource()
            accessingSecurityScope = false
        }
    }
}

public final class StorageConfigurationStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let fileManager: FileManager

    public init(
        defaults: UserDefaults? = nil,
        fileManager: FileManager = .default
    ) {
        self.defaults = defaults
            ?? FindoraRuntimeEnvironment.userDefaults(fileManager: fileManager)
        self.fileManager = fileManager
    }

    public func startupSelection() throws -> StorageStartupSelection {
        let defaultSupport = FindoraRuntimeEnvironment.applicationSupportRoot(
            fileManager: fileManager
        )
        let data = try resolve(kind: .data, defaultURL: defaultSupport)
        let defaultModels = defaultSupport.appending(path: "Models", directoryHint: .isDirectory)
        let models = try resolve(kind: .models, defaultURL: defaultModels)
        return StorageStartupSelection(
            dataURL: data.url,
            modelURL: models.url,
            dataIsCustom: data.isCustom,
            modelsAreCustom: models.isCustom,
            dataIsAvailable: data.isAvailable,
            modelsAreAvailable: models.isAvailable,
            dataAccess: data.access,
            modelAccess: models.access
        )
    }

    public func saveLocation(kind: StorageKind, url: URL) throws {
        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: [
                .isDirectoryKey,
                .volumeIdentifierKey,
                .volumeUUIDStringKey
            ],
            relativeTo: nil
        )
        defaults.set(bookmark, forKey: bookmarkKey(kind))
        defaults.set(url.path, forKey: pathKey(kind))
        defaults.set(true, forKey: customKey(kind))
    }

    public func clearCustomLocation(kind: StorageKind) {
        defaults.removeObject(forKey: bookmarkKey(kind))
        defaults.removeObject(forKey: pathKey(kind))
        defaults.removeObject(forKey: customKey(kind))
    }

    public func configuredPath(kind: StorageKind) -> String? {
        defaults.string(forKey: pathKey(kind))
    }

    public func saveMigration(_ record: StorageMigrationRecord) throws {
        defaults.set(
            try JSONEncoder().encode(record),
            forKey: migrationKey
        )
    }

    public func pendingMigration() throws -> StorageMigrationRecord? {
        guard let data = defaults.data(forKey: migrationKey) else { return nil }
        let record = try JSONDecoder().decode(StorageMigrationRecord.self, from: data)
        return record.phase == .completed ? nil : record
    }

    public func lastMigration() throws -> StorageMigrationRecord? {
        guard let data = defaults.data(forKey: migrationKey) else { return nil }
        return try JSONDecoder().decode(StorageMigrationRecord.self, from: data)
    }

    public func clearMigrationRecord() {
        defaults.removeObject(forKey: migrationKey)
    }

    private func resolve(
        kind: StorageKind,
        defaultURL: URL
    ) throws -> (
        url: URL,
        isCustom: Bool,
        isAvailable: Bool,
        access: ResolvedStorageLocation?
    ) {
        guard defaults.bool(forKey: customKey(kind)) else {
            return (
                defaultURL,
                false,
                fileManager.fileExists(atPath: defaultURL.path)
                    || kind == .models
                    || kind == .data,
                nil
            )
        }
        let displayPath = defaults.string(forKey: pathKey(kind))
        var resolvedURL = displayPath.map { URL(filePath: $0) }
        var stale = false
        if let bookmark = defaults.data(forKey: bookmarkKey(kind)),
           let bookmarked = try? URL(
               resolvingBookmarkData: bookmark,
               options: [.withSecurityScope],
               relativeTo: nil,
               bookmarkDataIsStale: &stale
           ) {
            resolvedURL = bookmarked
            if stale, fileManager.fileExists(atPath: bookmarked.path) {
                try saveLocation(kind: kind, url: bookmarked)
            }
        }
        guard let url = resolvedURL else {
            throw FindoraError.folderUnavailable(
                displayPath ?? "Unbekannter \(kind.displayName)"
            )
        }
        let exists = fileManager.fileExists(atPath: url.path)
        guard exists else {
            return (url, true, false, nil)
        }
        let accessing = url.startAccessingSecurityScopedResource()
        return (
            url,
            true,
            true,
            ResolvedStorageLocation(url: url, accessingSecurityScope: accessing)
        )
    }

    private func bookmarkKey(_ kind: StorageKind) -> String {
        "storage.\(kind.rawValue).bookmark"
    }

    private func pathKey(_ kind: StorageKind) -> String {
        "storage.\(kind.rawValue).path"
    }

    private func customKey(_ kind: StorageKind) -> String {
        "storage.\(kind.rawValue).custom"
    }

    private let migrationKey = "storage.migration.record"
}

public actor StorageMigrationService {
    private struct FileEntry: Sendable {
        let source: URL
        let relativePath: String
        let size: Int64
    }

    private let configurationStore: StorageConfigurationStore
    private let fileManager: FileManager

    public init(
        configurationStore: StorageConfigurationStore,
        fileManager: FileManager = .default
    ) {
        self.configurationStore = configurationStore
        self.fileManager = fileManager
    }

    public func assessTarget(
        parentURL: URL,
        requiredBytes: Int64
    ) throws -> StorageTargetAssessment {
        let standardized = parentURL.standardizedFileURL
        let values = try standardized.resourceValues(
            forKeys: [
                .volumeIsLocalKey,
                .volumeIsReadOnlyKey,
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeLocalizedFormatDescriptionKey
            ]
        )
        let format = values.volumeLocalizedFormatDescription ?? "Unbekannt"
        let isLocal = values.volumeIsLocal ?? false
        let isReadOnly = values.volumeIsReadOnly ?? true
        let available = values.volumeAvailableCapacityForImportantUsage
        let lowerPath = standardized.path.lowercased()
        let cloudMarkers = [
            "/library/mobile documents/",
            "/library/cloudstorage/",
            "onedrive",
            "dropbox",
            "icloud"
        ]
        let isCloudPath = cloudMarkers.contains { lowerPath.contains($0) }
        let lowerFormat = format.lowercased()
        let acceptedFormat = lowerFormat.contains("apfs")
            || lowerFormat.contains("mac os extended")
            || lowerFormat.contains("hfs")
        let knownUnsafeFormat = [
            "exfat", "fat", "ms-dos", "ntfs", "smb", "nfs", "webdav"
        ].contains { lowerFormat.contains($0) }

        var blocking: [String] = []
        var warnings: [String] = []
        if !isLocal {
            blocking.append("Netzwerk- und nicht lokale Volumes sind für SQLite-WAL nicht zulässig.")
        }
        if isReadOnly {
            blocking.append("Das Zielvolume ist schreibgeschützt.")
        }
        if isCloudPath {
            blocking.append("Aktiv synchronisierte Cloudordner sind als laufender Datenspeicher nicht zulässig.")
        }
        if knownUnsafeFormat {
            blocking.append("Das Dateisystem \(format) ist für diesen Speicher nicht zugelassen.")
        } else if !acceptedFormat {
            warnings.append(
                "macOS meldet das Dateisystem als „\(format)“. APFS wird empfohlen; die Erkennung ist nicht auf jedem Volume eindeutig."
            )
        }
        if let available, available < requiredBytes {
            blocking.append("Am Ziel ist nicht genügend freier Speicher verfügbar.")
        }
        let level: StorageCapacityLevel
        if let available {
            if available < max(requiredBytes, 1_073_741_824) {
                level = .critical
            } else if available < max(requiredBytes * 2, 5_368_709_120) {
                level = .low
            } else {
                level = .sufficient
            }
        } else {
            level = .low
            warnings.append("Der freie Speicher konnte nicht zuverlässig bestimmt werden.")
        }

        if blocking.isEmpty {
            let probe = standardized.appending(path: ".findora-write-test-\(UUID().uuidString)")
            do {
                try Data("Findora".utf8).write(to: probe, options: [.atomic])
                try fileManager.removeItem(at: probe)
            } catch {
                blocking.append("Das Ziel ist nicht zuverlässig beschreibbar.")
            }
        }
        return StorageTargetAssessment(
            target: standardized,
            fileSystemDescription: format,
            isLocal: isLocal,
            isReadOnly: isReadOnly,
            availableBytes: available,
            capacityLevel: level,
            blockingReasons: blocking,
            warnings: warnings
        )
    }

    public func estimateMigration(
        sourceURL: URL,
        destinationParent: URL,
        excludedRoots: [URL] = []
    ) throws -> StorageMigrationEstimate {
        let files = try inventory(
            sourceURL: sourceURL.standardizedFileURL,
            excludedRoots: excludedRoots.map(\.standardizedFileURL)
        )
        let totalBytes = files.reduce(Int64(0)) { $0 + $1.size }
        let assessment = try assessTarget(
            parentURL: destinationParent,
            requiredBytes: totalBytes + max(64 * 1_024 * 1_024, totalBytes / 20)
        )
        return StorageMigrationEstimate(
            fileCount: files.count,
            totalBytes: totalBytes,
            assessment: assessment
        )
    }

    public func storageUsage(
        paths: AppPaths,
        databaseTextBytes: Int64,
        embeddingBytes: Int64
    ) throws -> StorageUsageSnapshot {
        let databaseBytes = try fileSize(paths.database)
            + fileSizeIfPresent(URL(filePath: paths.database.path + "-wal"))
            + fileSizeIfPresent(URL(filePath: paths.database.path + "-shm"))
        let previewBytes = try directorySize(
            paths.applicationSupport.appending(path: "Previews")
        )
        let sourceBytes = try directorySize(
            paths.mailArchive.appending(path: "Sources")
        )
        let attachmentBytes = try directorySize(
            paths.mailArchive.appending(path: "Attachments")
        )
        let modelBytes = try directorySize(paths.models)
        let temporaryBytes = try directorySize(paths.downloads)
        let logBytes = try directorySize(paths.logs)
        let supportBytes = try directorySize(
            paths.applicationSupport,
            excludedRoots: [paths.models]
        )
        let total = supportBytes + modelBytes + logBytes
        let dataAvailable = try? paths.applicationSupport.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage
        let modelAvailable = try? paths.models.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage
        let lowest = [dataAvailable, modelAvailable].compactMap { $0 }.min()
        let level: StorageCapacityLevel
        if let lowest, lowest < 1_073_741_824 {
            level = .critical
        } else if let lowest, lowest < 5_368_709_120 {
            level = .low
        } else {
            level = .sufficient
        }
        return StorageUsageSnapshot(
            databaseAndIndexBytes: databaseBytes,
            textBytes: databaseTextBytes,
            embeddingBytes: embeddingBytes,
            previewBytes: previewBytes,
            archivedSourceBytes: sourceBytes,
            archivedAttachmentBytes: attachmentBytes,
            modelBytes: modelBytes,
            temporaryBytes: temporaryBytes,
            logBytes: logBytes,
            totalBytes: total,
            availableDataBytes: dataAvailable,
            availableModelBytes: modelAvailable,
            capacityLevel: level
        )
    }

    public func cleanTemporaryData(paths: AppPaths) throws {
        guard fileManager.fileExists(atPath: paths.downloads.path) else { return }
        let contents = try fileManager.contentsOfDirectory(
            at: paths.downloads,
            includingPropertiesForKeys: nil
        )
        for item in contents {
            try fileManager.trashItem(at: item, resultingItemURL: nil)
        }
    }

    public func migrate(
        kind: StorageKind,
        sourceURL: URL,
        destinationParent: URL,
        excludedRoots: [URL] = [],
        onProgress: @Sendable (StorageMigrationProgress) async -> Void
    ) async throws -> URL {
        let source = sourceURL.standardizedFileURL
        let parent = destinationParent.standardizedFileURL
        guard source.path != parent.path,
              !parent.path.hasPrefix(source.path + "/") else {
            throw FindoraError.processFailed(
                "Der neue Speicher darf nicht innerhalb des bisherigen Speichers liegen."
            )
        }
        let files = try inventory(
            sourceURL: source,
            excludedRoots: excludedRoots.map(\.standardizedFileURL)
        )
        let totalBytes = files.reduce(Int64(0)) { $0 + $1.size }
        let assessment = try assessTarget(
            parentURL: parent,
            requiredBytes: totalBytes + max(64 * 1_024 * 1_024, totalBytes / 20)
        )
        guard assessment.isAllowed else {
            throw FindoraError.processFailed(
                assessment.blockingReasons.joined(separator: " ")
            )
        }

        let finalURL = parent.appending(
            path: kind.directoryName,
            directoryHint: .isDirectory
        )
        guard !fileManager.fileExists(atPath: finalURL.path) else {
            throw FindoraError.processFailed(
                "Am Ziel existiert bereits \(kind.directoryName). Bitte wählen Sie einen anderen Ordner."
            )
        }
        let staging = parent.appending(
            path: ".findora-\(kind.rawValue)-staging-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        var record = StorageMigrationRecord(
            id: UUID().uuidString,
            kind: kind,
            sourcePath: source.path,
            destinationPath: finalURL.path,
            phase: .preparation,
            copiedFiles: 0,
            totalFiles: files.count,
            copiedBytes: 0,
            totalBytes: totalBytes,
            lastErrorCategory: nil,
            createdAt: .now,
            updatedAt: .now,
            completedAt: nil
        )
        try configurationStore.saveMigration(record)
        await onProgress(progress(record))

        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            record.phase = .copying
            record.updatedAt = .now
            try configurationStore.saveMigration(record)
            for file in files {
                try Task.checkCancellation()
                let destination = staging.appending(path: file.relativePath)
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.copyItem(at: file.source, to: destination)
                record.copiedFiles += 1
                record.copiedBytes += file.size
                record.updatedAt = .now
                try configurationStore.saveMigration(record)
                await onProgress(progress(record))
            }

            record.phase = .validating
            record.updatedAt = .now
            try configurationStore.saveMigration(record)
            await onProgress(progress(record))
            for file in files {
                try Task.checkCancellation()
                let destination = staging.appending(path: file.relativePath)
                let destinationSize = try destination.resourceValues(
                    forKeys: [.fileSizeKey]
                ).fileSize
                guard Int64(destinationSize ?? -1) == file.size,
                      try SHA256Hasher().hash(fileAt: destination)
                        == SHA256Hasher().hash(fileAt: file.source) else {
                    throw FindoraError.processFailed(
                        "Eine kopierte Datei stimmt nicht mit dem Ausgangsbestand überein."
                    )
                }
            }
            if kind == .data {
                let databaseURL = staging.appending(path: "Findora.sqlite3")
                guard fileManager.fileExists(atPath: databaseURL.path) else {
                    throw FindoraError.database(
                        "Die kopierte Findora-Datenbank fehlt."
                    )
                }
                let validationDatabase = SQLiteDatabase(url: databaseURL)
                try await validationDatabase.initialize()
                let result = try await validationDatabase.databaseQuickCheck()
                try await validationDatabase.checkpointAndClose()
                guard result.lowercased() == "ok" else {
                    throw FindoraError.database(
                        "SQLite quick_check am Ziel meldet: \(result)"
                    )
                }
            }

            record.phase = .switching
            record.updatedAt = .now
            try configurationStore.saveMigration(record)
            await onProgress(progress(record))
            try fileManager.moveItem(at: staging, to: finalURL)
            try configurationStore.saveLocation(kind: kind, url: finalURL)
            record.phase = .completed
            record.completedAt = .now
            record.updatedAt = .now
            try configurationStore.saveMigration(record)
            await onProgress(progress(record))
            return finalURL
        } catch {
            record.phase = fileManager.fileExists(atPath: staging.path)
                ? .failed
                : .rollbackRequired
            record.lastErrorCategory = Self.errorCategory(error)
            record.updatedAt = .now
            try? configurationStore.saveMigration(record)
            throw error
        }
    }

    public func discardFailedStaging(for record: StorageMigrationRecord) throws {
        guard record.phase == .failed else { return }
        let parent = URL(filePath: record.destinationPath).deletingLastPathComponent()
        guard let enumerator = fileManager.enumerator(
            at: parent,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsSubdirectoryDescendants]
        ) else { return }
        let prefix = ".findora-\(record.kind.rawValue)-staging-"
        for case let url as URL in enumerator where url.lastPathComponent.hasPrefix(prefix) {
            try fileManager.trashItem(at: url, resultingItemURL: nil)
        }
    }

    public func moveOldStorageToTrash(
        oldURL: URL,
        activeURL: URL
    ) throws {
        let old = oldURL.standardizedFileURL
        let active = activeURL.standardizedFileURL
        guard old.path != active.path,
              !active.path.hasPrefix(old.path + "/") else {
            throw FindoraError.processFailed(
                "Der aktive Speicher darf nicht als Altbestand entfernt werden."
            )
        }
        try fileManager.trashItem(at: old, resultingItemURL: nil)
    }

    private func inventory(
        sourceURL: URL,
        excludedRoots: [URL]
    ) throws -> [FileEntry] {
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw FindoraError.folderUnavailable(sourceURL.path)
        }
        var result: [FileEntry] = []
        guard let enumerator = fileManager.enumerator(
            at: sourceURL,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .fileSizeKey
            ],
            options: []
        ) else {
            throw FindoraError.folderUnavailable(sourceURL.path)
        }
        for case let url as URL in enumerator {
            let standardized = url.standardizedFileURL
            if excludedRoots.contains(where: {
                standardized.path == $0.path
                    || standardized.path.hasPrefix($0.path + "/")
            }) {
                if (try? standardized.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            let values = try standardized.resourceValues(
                forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true else { continue }
            let relative = String(
                standardized.path.dropFirst(sourceURL.path.count + 1)
            )
            result.append(
                FileEntry(
                    source: standardized,
                    relativePath: relative,
                    size: Int64(values.fileSize ?? 0)
                )
            )
        }
        return result.sorted { $0.relativePath < $1.relativePath }
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        guard fileManager.fileExists(atPath: url.path) else { return 0 }
        return Int64(
            try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        )
    }

    private func fileSizeIfPresent(_ url: URL) -> Int64 {
        (try? fileSize(url)) ?? 0
    }

    private func directorySize(
        _ root: URL,
        excludedRoots: [URL] = []
    ) throws -> Int64 {
        guard fileManager.fileExists(atPath: root.path) else { return 0 }
        let excluded = excludedRoots.map(\.standardizedFileURL)
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
            ],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let standardized = url.standardizedFileURL
            if excluded.contains(where: {
                standardized.path == $0.path
                    || standardized.path.hasPrefix($0.path + "/")
            }) {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            let values = try url.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }

    private func progress(
        _ record: StorageMigrationRecord
    ) -> StorageMigrationProgress {
        StorageMigrationProgress(
            phase: record.phase,
            copiedFiles: record.copiedFiles,
            totalFiles: record.totalFiles,
            copiedBytes: record.copiedBytes,
            totalBytes: record.totalBytes
        )
    }

    private static func errorCategory(_ error: Error) -> String {
        switch error {
        case is CancellationError: "Abgebrochen"
        case is CocoaError: "Dateisystem"
        default: "Validierung"
        }
    }
}
