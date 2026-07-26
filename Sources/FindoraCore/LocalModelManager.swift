import Foundation

public struct ModelDownloadProgress: Equatable, Sendable {
    public let modelID: String
    public let currentFile: String
    public let downloadedBytes: Int64
    public let totalBytes: Int64

    public var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(downloadedBytes) / Double(totalBytes))
    }

    public init(
        modelID: String,
        currentFile: String,
        downloadedBytes: Int64,
        totalBytes: Int64
    ) {
        self.modelID = modelID
        self.currentFile = currentFile
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
    }
}

public actor LocalModelManager {
    private struct PendingDownload {
        let modelID: String
        let fileIndex: Int
        let completedBytes: Int64
        let resumeData: Data?
        let staging: URL
    }

    private let catalog: ModelCatalog
    private let modelsDirectory: URL
    private let downloadsDirectory: URL
    private let fileManager: FileManager
    private let hasher = SHA256Hasher()
    private var activeModelIDs: [ModelKind: String] = [:]
    private var currentDownload: ResumableDownloadOperation?
    private var pendingDownload: PendingDownload?

    public init(
        catalog: ModelCatalog,
        paths: AppPaths,
        fileManager: FileManager = .default
    ) {
        self.catalog = catalog
        self.modelsDirectory = paths.models
        self.downloadsDirectory = paths.downloads
        self.fileManager = fileManager
    }

    public func models(profile: HardwareProfile) -> [InstalledModel] {
        catalog.models.map { descriptor in
            let directory = installedDirectory(for: descriptor)
            let currentInstalled = validateInstalledFiles(descriptor, directory: directory)
            let installedVersion = currentInstalled
                ? descriptor.modelVersion
                : olderInstalledVersion(for: descriptor)
            return InstalledModel(
                descriptor: descriptor,
                directory: directory,
                isInstalled: currentInstalled,
                isActive: activeModelIDs[descriptor.kind] == descriptor.id,
                compatibility: profile.compatibility(for: descriptor),
                installedVersion: installedVersion,
                updateAvailable: installedVersion != nil && !currentInstalled
            )
        }
    }

    public func descriptor(id: String) -> LocalModelDescriptor? {
        catalog.models.first { $0.id == id }
    }

    public func installedDirectory(modelID: String) -> URL? {
        guard let descriptor = descriptor(id: modelID) else { return nil }
        let directory = installedDirectory(for: descriptor)
        return validateInstalledFiles(
            descriptor,
            directory: directory,
            checkHashes: true
        ) ? directory : nil
    }

    public func install(
        modelID: String,
        profile: HardwareProfile,
        validation: @Sendable @escaping (URL, LocalModelDescriptor) async throws -> Void = { _, _ in },
        progress: @Sendable @escaping (ModelDownloadProgress) async -> Void
    ) async throws -> URL {
        guard let descriptor = descriptor(id: modelID) else {
            throw FindoraError.processFailed("Unbekanntes Modell: \(modelID)")
        }
        guard profile.compatibility(for: descriptor) != .incompatible else {
            throw FindoraError.processFailed("Das Modell ist mit diesem Mac nicht kompatibel.")
        }
        guard profile.availableStorageBytes >= descriptor.downloadSizeBytes * 2 else {
            throw FindoraError.processFailed("Nicht genügend freier Speicher für sicheren Download und Installation.")
        }

        let defaultStaging = downloadsDirectory
            .appending(path: descriptor.id.replacingOccurrences(of: "/", with: "_"))
            .appending(path: descriptor.modelVersion)
        let resume = pendingDownload?.modelID == modelID ? pendingDownload : nil
        let staging = resume?.staging ?? defaultStaging
        if resume == nil {
            if fileManager.fileExists(atPath: staging.path) {
                try fileManager.removeItem(at: staging)
            }
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        }

        var completedBytes = resume?.completedBytes ?? 0
        let startIndex = resume?.fileIndex ?? 0
        do {
            for index in startIndex..<descriptor.files.count {
                let file = descriptor.files[index]
                try Task.checkCancellation()
                guard file.downloadURL.scheme == "https",
                      file.downloadURL.host.map(Self.isAllowedHost) == true else {
                    throw FindoraError.processFailed("Nicht freigegebene Modellquelle.")
                }

                await progress(
                    ModelDownloadProgress(
                        modelID: descriptor.id,
                        currentFile: file.relativePath,
                        downloadedBytes: completedBytes,
                        totalBytes: descriptor.downloadSizeBytes
                    )
                )

                let incoming = staging.appending(path: ".incoming-\(index)")
                let completedBeforeFile = completedBytes
                let operation = ResumableDownloadOperation(
                    request: URLRequest(url: file.downloadURL),
                    resumeData: index == startIndex ? resume?.resumeData : nil,
                    destination: incoming,
                    redirectValidator: { url in
                        url.scheme == "https" && url.host.map(Self.isAllowedHost) == true
                    }
                ) { written, _ in
                    Task {
                        await progress(
                            ModelDownloadProgress(
                                modelID: descriptor.id,
                                currentFile: file.relativePath,
                                downloadedBytes: completedBeforeFile + written,
                                totalBytes: descriptor.downloadSizeBytes
                            )
                        )
                    }
                }
                currentDownload = operation
                let result: ResumableDownloadOperation.Result
                do {
                    result = try await operation.run()
                } catch DownloadOperationError.paused(let resumeData) {
                    currentDownload = nil
                    pendingDownload = PendingDownload(
                        modelID: modelID,
                        fileIndex: index,
                        completedBytes: completedBytes,
                        resumeData: resumeData.isEmpty ? nil : resumeData,
                        staging: staging
                    )
                    throw ModelDownloadPausedError()
                }
                currentDownload = nil

                let http = result.response
                guard (200...299).contains(http.statusCode),
                      http.url?.host.map(Self.isAllowedHost) == true else {
                    throw FindoraError.processFailed("Modelldownload wurde von einer nicht freigegebenen Quelle beantwortet.")
                }

                let size = (try fileManager.attributesOfItem(atPath: result.file.path)[.size] as? NSNumber)?.int64Value ?? -1
                guard size == file.sizeBytes else {
                    throw FindoraError.processFailed("Unerwartete Dateigröße für \(file.relativePath).")
                }
                guard try hasher.hash(fileAt: result.file) == file.checksumSHA256.lowercased() else {
                    throw FindoraError.processFailed("Prüfsumme ist falsch: \(file.relativePath)")
                }

                let destination = staging.appending(path: file.relativePath)
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: result.file, to: destination)
                completedBytes += file.sizeBytes
                pendingDownload = PendingDownload(
                    modelID: modelID,
                    fileIndex: index + 1,
                    completedBytes: completedBytes,
                    resumeData: nil,
                    staging: staging
                )
            }

            pendingDownload = nil
            try validateModelDirectory(staging, descriptor: descriptor)
            try await validation(staging, descriptor)
            let destination = installedDirectory(for: descriptor)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: destination.path) {
                let old = destination.deletingLastPathComponent()
                    .appending(path: ".previous-\(UUID().uuidString)")
                try fileManager.moveItem(at: destination, to: old)
                do {
                    try fileManager.moveItem(at: staging, to: destination)
                    try? fileManager.removeItem(at: old)
                } catch {
                    try? fileManager.moveItem(at: old, to: destination)
                    throw error
                }
            } else {
                try fileManager.moveItem(at: staging, to: destination)
            }
            await progress(
                ModelDownloadProgress(
                    modelID: descriptor.id,
                    currentFile: "",
                    downloadedBytes: descriptor.downloadSizeBytes,
                    totalBytes: descriptor.downloadSizeBytes
                )
            )
            return destination
        } catch is ModelDownloadPausedError {
            throw ModelDownloadPausedError()
        } catch {
            currentDownload = nil
            pendingDownload = nil
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    public func pauseDownload() {
        currentDownload?.pause()
    }

    public func cancelDownload() {
        currentDownload?.cancel()
    }

    public func discardPausedDownload() {
        if let pendingDownload {
            try? fileManager.removeItem(at: pendingDownload.staging)
        }
        pendingDownload = nil
    }

    public func activate(modelID: String) throws {
        guard let descriptor = descriptor(id: modelID),
              installedDirectory(modelID: modelID) != nil else {
            throw FindoraError.processFailed("Das Modell ist nicht vollständig installiert.")
        }
        activeModelIDs[descriptor.kind] = descriptor.id
    }

    public func deactivate(kind: ModelKind) {
        activeModelIDs[kind] = nil
    }

    public func activeModel(kind: ModelKind) -> LocalModelDescriptor? {
        activeModelIDs[kind].flatMap(descriptor)
    }

    public func remove(modelID: String) throws {
        guard let descriptor = descriptor(id: modelID) else { return }
        if activeModelIDs[descriptor.kind] == modelID {
            activeModelIDs[descriptor.kind] = nil
        }
        let target = installedDirectory(for: descriptor)
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.trashItem(at: target, resultingItemURL: nil)
        }
    }

    private func installedDirectory(for descriptor: LocalModelDescriptor) -> URL {
        modelsDirectory
            .appending(path: descriptor.id.replacingOccurrences(of: "/", with: "_"))
            .appending(path: descriptor.modelVersion)
    }

    private func olderInstalledVersion(for descriptor: LocalModelDescriptor) -> String? {
        let root = modelsDirectory.appending(
            path: descriptor.id.replacingOccurrences(of: "/", with: "_"),
            directoryHint: .isDirectory
        )
        guard let children = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return children
            .filter {
                $0.lastPathComponent != descriptor.modelVersion
                    && ((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
            }
            .map(\.lastPathComponent)
            .sorted()
            .last
    }

    private func validateInstalledFiles(
        _ descriptor: LocalModelDescriptor,
        directory: URL,
        checkHashes: Bool = false
    ) -> Bool {
        descriptor.files.allSatisfy {
            let url = directory.appending(path: $0.relativePath)
            guard let size = try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
                return false
            }
            guard size.int64Value == $0.sizeBytes else { return false }
            return !checkHashes || (try? hasher.hash(fileAt: url)) == $0.checksumSHA256
        }
    }

    private func validateModelDirectory(
        _ directory: URL,
        descriptor: LocalModelDescriptor
    ) throws {
        guard validateInstalledFiles(descriptor, directory: directory) else {
            throw FindoraError.processFailed("Modellinstallation ist unvollständig.")
        }
        let config = directory.appending(path: "config.json")
        let data = try Data(contentsOf: config)
        _ = try JSONSerialization.jsonObject(with: data)
        let weightFiles = descriptor.files.filter { $0.relativePath.hasSuffix(".safetensors") }
        guard !weightFiles.isEmpty else {
            throw FindoraError.processFailed("Modell enthält keine SafeTensors-Gewichte.")
        }
    }

    private static func isAllowedHost(_ host: String) -> Bool {
        host == "huggingface.co"
            || host.hasSuffix(".huggingface.co")
            || host.hasSuffix(".hf.co")
            || host.hasSuffix(".xethub.hf.co")
    }
}
