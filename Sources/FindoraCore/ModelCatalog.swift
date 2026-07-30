import Foundation

public enum ModelKind: String, Codable, Sendable {
    case embedding
    case answer
    case validator
    case documentVision
}

public enum ModelCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case embeddingGeneration
    case textGeneration
    case structuredExtraction
    case knowledgeValidation
    case entityResolution
    case summarization
    case questionAnswering
    case visionDocumentAnalysis
    case ocrValidation
    case relationExtraction
    case contradictionDetection
}

public enum ModelRuntime: String, Codable, CaseIterable, Sendable {
    case mlxText = "mlx_text"
    case mlxVision = "mlx_vision"
}

public enum ModelAvailability: String, Codable, CaseIterable, Sendable {
    case available
    case experimental
    case unavailable
}

public enum ModelOperationalState: String, Codable, CaseIterable, Sendable {
    case available
    case notInstalled
    case downloading
    case installed
    case enabled
    case loading
    case loaded
    case unloading
    case disabled
    case damaged
    case incompatible
}

public enum ModelCompatibility: String, Codable, Comparable, Sendable {
    case recommended
    case compatible
    case experimental
    case incompatible

    public static func < (lhs: Self, rhs: Self) -> Bool {
        let order: [Self] = [.recommended, .compatible, .experimental, .incompatible]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

public struct ModelFile: Codable, Hashable, Sendable {
    public let relativePath: String
    public let downloadURL: URL
    public let sizeBytes: Int64
    public let checksumSHA256: String

    public init(
        relativePath: String,
        downloadURL: URL,
        sizeBytes: Int64,
        checksumSHA256: String
    ) {
        self.relativePath = relativePath
        self.downloadURL = downloadURL
        self.sizeBytes = sizeBytes
        self.checksumSHA256 = checksumSHA256
    }
}

public struct LocalModelDescriptor: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let kind: ModelKind
    public let displayName: String
    public let family: String
    public let capabilities: Set<ModelCapability>
    public let runtime: ModelRuntime
    public let parameters: String
    public let quantization: String
    public let backend: String
    public let downloadSizeBytes: Int64
    public let estimatedRuntimeRAMBytes: Int64
    public let minimumSystemRAMBytes: Int64
    public let recommendedSystemRAMBytes: Int64
    public let defaultContextLength: Int
    public let maximumContextLength: Int
    public let downloadURL: URL
    public let checksumSHA256: String
    public let licenseName: String
    public let licenseURL: URL
    public let modelVersion: String
    public let repositoryID: String
    public let experimental: Bool
    public let availability: ModelAvailability
    public let files: [ModelFile]

    public init(
        id: String,
        kind: ModelKind,
        displayName: String,
        family: String,
        capabilities: Set<ModelCapability> = [],
        runtime: ModelRuntime = .mlxText,
        parameters: String,
        quantization: String,
        backend: String,
        downloadSizeBytes: Int64,
        estimatedRuntimeRAMBytes: Int64,
        minimumSystemRAMBytes: Int64,
        recommendedSystemRAMBytes: Int64,
        defaultContextLength: Int,
        maximumContextLength: Int,
        downloadURL: URL,
        checksumSHA256: String,
        licenseName: String,
        licenseURL: URL,
        modelVersion: String,
        repositoryID: String,
        experimental: Bool = false,
        availability: ModelAvailability = .available,
        files: [ModelFile]
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.family = family
        self.capabilities = capabilities
        self.runtime = runtime
        self.parameters = parameters
        self.quantization = quantization
        self.backend = backend
        self.downloadSizeBytes = downloadSizeBytes
        self.estimatedRuntimeRAMBytes = estimatedRuntimeRAMBytes
        self.minimumSystemRAMBytes = minimumSystemRAMBytes
        self.recommendedSystemRAMBytes = recommendedSystemRAMBytes
        self.defaultContextLength = defaultContextLength
        self.maximumContextLength = maximumContextLength
        self.downloadURL = downloadURL
        self.checksumSHA256 = checksumSHA256
        self.licenseName = licenseName
        self.licenseURL = licenseURL
        self.modelVersion = modelVersion
        self.repositoryID = repositoryID
        self.experimental = experimental
        self.availability = availability
        self.files = files
    }
}

public struct ModelCatalog: Codable, Sendable {
    public let schemaVersion: Int
    public let models: [LocalModelDescriptor]

    public init(schemaVersion: Int, models: [LocalModelDescriptor]) {
        self.schemaVersion = schemaVersion
        self.models = models
    }

    public static func load(from url: URL) throws -> ModelCatalog {
        let data = try Data(contentsOf: url)
        let catalog = try JSONDecoder().decode(ModelCatalog.self, from: data)
        guard catalog.schemaVersion == 2 else {
            throw FindoraError.processFailed("Nicht unterstützte Modellkatalog-Version.")
        }
        let allowedHosts = Set(["huggingface.co"])
        for model in catalog.models {
            let manifest = model.files
                .sorted { $0.relativePath < $1.relativePath }
                .map { "\($0.relativePath):\($0.checksumSHA256.lowercased())\n" }
                .joined()
            let manifestHash = SHA256Hasher().hash(data: Data(manifest.utf8))
            guard ["mlx", "mlx-vlm"].contains(model.backend),
                  !model.capabilities.isEmpty,
                  (model.runtime == .mlxVision) == (model.backend == "mlx-vlm"),
                  model.availability != .unavailable || model.experimental,
                  !model.files.isEmpty,
                  model.downloadURL.scheme == "https",
                  model.checksumSHA256.lowercased() == manifestHash,
                  model.files.allSatisfy({
                      $0.downloadURL.scheme == "https"
                          && $0.downloadURL.host.map(allowedHosts.contains) == true
                          && $0.checksumSHA256.count == 64
                          && !$0.relativePath.contains("..")
                          && !$0.relativePath.hasPrefix("/")
                  }) else {
                throw FindoraError.processFailed(
                    "Unsicherer oder unvollständiger Katalogeintrag: \(model.id)"
                )
            }
        }
        return catalog
    }

    public static func bundled() throws -> ModelCatalog {
        guard let url = Bundle.module.url(
            forResource: "model-catalog",
            withExtension: "json"
        ) else {
            throw FindoraError.processFailed("Der lokale Modellkatalog fehlt.")
        }
        return try load(from: url)
    }
}

public struct HardwareProfile: Equatable, Sendable {
    public let isAppleSilicon: Bool
    public let chipName: String
    public let physicalMemoryBytes: UInt64
    public let availableStorageBytes: Int64

    public init(
        isAppleSilicon: Bool,
        chipName: String,
        physicalMemoryBytes: UInt64,
        availableStorageBytes: Int64
    ) {
        self.isAppleSilicon = isAppleSilicon
        self.chipName = chipName
        self.physicalMemoryBytes = physicalMemoryBytes
        self.availableStorageBytes = availableStorageBytes
    }

    public static func current(storageURL: URL) -> HardwareProfile {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
        let values = try? storageURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return HardwareProfile(
            isAppleSilicon: machine == "arm64",
            chipName: Self.sysctlString("machdep.cpu.brand_string") ?? machine,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            availableStorageBytes: values?.volumeAvailableCapacityForImportantUsage ?? 0
        )
    }

    public func compatibility(
        for model: LocalModelDescriptor,
        systemReserveBytes: UInt64 = 2_684_354_560
    ) -> ModelCompatibility {
        guard isAppleSilicon,
              physicalMemoryBytes >= UInt64(max(0, model.minimumSystemRAMBytes)),
              availableStorageBytes >= model.downloadSizeBytes * 2 else {
            return .incompatible
        }
        let usable = physicalMemoryBytes > systemReserveBytes
            ? physicalMemoryBytes - systemReserveBytes
            : 0
        guard UInt64(max(0, model.estimatedRuntimeRAMBytes)) <= usable else {
            return model.estimatedRuntimeRAMBytes < Int64(physicalMemoryBytes)
                ? .experimental
                : .incompatible
        }
        return physicalMemoryBytes >= UInt64(max(0, model.recommendedSystemRAMBytes))
            ? .recommended
            : .compatible
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

public struct InstalledModel: Identifiable, Equatable, Sendable {
    public let id: String
    public let descriptor: LocalModelDescriptor
    public let directory: URL
    public let isInstalled: Bool
    public let isActive: Bool
    public let compatibility: ModelCompatibility
    public let installedVersion: String?
    public let updateAvailable: Bool
    public let integrityFailed: Bool

    public init(
        descriptor: LocalModelDescriptor,
        directory: URL,
        isInstalled: Bool,
        isActive: Bool,
        compatibility: ModelCompatibility,
        installedVersion: String? = nil,
        updateAvailable: Bool = false,
        integrityFailed: Bool = false
    ) {
        self.id = descriptor.id
        self.descriptor = descriptor
        self.directory = directory
        self.isInstalled = isInstalled
        self.isActive = isActive
        self.compatibility = compatibility
        self.installedVersion = installedVersion
        self.updateAvailable = updateAvailable
        self.integrityFailed = integrityFailed
    }
}
