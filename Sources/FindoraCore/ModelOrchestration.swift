import Foundation

public enum ModelTask: String, Codable, CaseIterable, Sendable {
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

    public var requiredCapability: ModelCapability {
        ModelCapability(rawValue: rawValue)!
    }

    public var priority: Int {
        switch self {
        case .questionAnswering: 100
        case .visionDocumentAnalysis, .ocrValidation: 80
        case .structuredExtraction, .knowledgeValidation: 70
        case .entityResolution, .relationExtraction, .contradictionDetection: 60
        case .summarization: 40
        case .textGeneration: 50
        }
    }
}

public struct ModelRoutingPreferences: Equatable, Sendable {
    public let preferredPrimaryModelID: String?
    public let preferredValidationModelID: String?
    public let preferredVisionModelID: String?
    public let automaticSelection: Bool
    public let allowExperimentalModels: Bool

    public init(
        preferredPrimaryModelID: String? = nil,
        preferredValidationModelID: String? = nil,
        preferredVisionModelID: String? = nil,
        automaticSelection: Bool = true,
        allowExperimentalModels: Bool = false
    ) {
        self.preferredPrimaryModelID = preferredPrimaryModelID
        self.preferredValidationModelID = preferredValidationModelID
        self.preferredVisionModelID = preferredVisionModelID
        self.automaticSelection = automaticSelection
        self.allowExperimentalModels = allowExperimentalModels
    }
}

public struct ModelRoutingDecision: Equatable, Sendable {
    public let task: ModelTask
    public let descriptor: LocalModelDescriptor?
    public let requiresDownloadConsent: Bool
    public let reason: String

    public init(
        task: ModelTask,
        descriptor: LocalModelDescriptor?,
        requiresDownloadConsent: Bool,
        reason: String
    ) {
        self.task = task
        self.descriptor = descriptor
        self.requiresDownloadConsent = requiresDownloadConsent
        self.reason = reason
    }
}

public struct ModelRouter: Sendable {
    public init() {}

    public func route(
        task: ModelTask,
        catalog: [LocalModelDescriptor],
        installedModelIDs: Set<String>,
        failedModelIDs: Set<String> = [],
        profile: HardwareProfile,
        pressure: MemoryPressureLevel,
        preferences: ModelRoutingPreferences = .init()
    ) -> ModelRoutingDecision {
        guard pressure != .critical else {
            return ModelRoutingDecision(
                task: task,
                descriptor: nil,
                requiresDownloadConsent: false,
                reason: "Kritischer Speicherdruck pausiert neue Modellaufgaben."
            )
        }

        let preferredID: String?
        switch task {
        case .knowledgeValidation, .contradictionDetection:
            preferredID = preferences.preferredValidationModelID
        case .visionDocumentAnalysis, .ocrValidation:
            preferredID = preferences.preferredVisionModelID
        default:
            preferredID = preferences.preferredPrimaryModelID
        }

        let candidates = catalog.filter {
            $0.capabilities.contains(task.requiredCapability)
                && $0.availability != .unavailable
                && (preferences.allowExperimentalModels || !$0.experimental)
                && !failedModelIDs.contains($0.id)
                && profile.compatibility(for: $0) != .incompatible
        }
        let sorted = candidates.sorted { lhs, rhs in
            if lhs.id == preferredID { return true }
            if rhs.id == preferredID { return false }
            let lhsInstalled = installedModelIDs.contains(lhs.id)
            let rhsInstalled = installedModelIDs.contains(rhs.id)
            if lhsInstalled != rhsInstalled { return lhsInstalled }
            let lhsIsPrimaryQwen = lhs.id.localizedCaseInsensitiveContains("Qwen3.5-4B")
            let rhsIsPrimaryQwen = rhs.id.localizedCaseInsensitiveContains("Qwen3.5-4B")
            if lhsIsPrimaryQwen != rhsIsPrimaryQwen,
               ![ModelTask.knowledgeValidation, .contradictionDetection].contains(task) {
                return lhsIsPrimaryQwen
            }
            if lhs.experimental != rhs.experimental { return !lhs.experimental }
            if lhs.estimatedRuntimeRAMBytes != rhs.estimatedRuntimeRAMBytes {
                return lhs.estimatedRuntimeRAMBytes < rhs.estimatedRuntimeRAMBytes
            }
            return lhs.id < rhs.id
        }
        guard let selected = sorted.first else {
            return ModelRoutingDecision(
                task: task,
                descriptor: nil,
                requiresDownloadConsent: false,
                reason: "Kein installiertes oder kompatibles Modell besitzt die benötigte Fähigkeit."
            )
        }
        let installed = installedModelIDs.contains(selected.id)
        return ModelRoutingDecision(
            task: task,
            descriptor: selected,
            requiresDownloadConsent: !installed,
            reason: installed
                ? "Lokales Modell capability- und speicherbasiert ausgewählt."
                : "Das empfohlene lokale Modell benötigt vor der Aufgabe eine Downloadzustimmung."
        )
    }
}

public struct ModelMemoryReservation: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let modelID: String
    public let bytes: Int64
    public let contextLength: Int
}

public actor ModelMemoryBudget {
    public let physicalMemoryBytes: UInt64
    public let systemReserveBytes: UInt64
    private var pressure: MemoryPressureLevel
    private var reservations: [UUID: ModelMemoryReservation] = [:]

    public init(
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        systemReserveBytes: UInt64 = 2_684_354_560,
        pressure: MemoryPressureLevel = .normal
    ) {
        self.physicalMemoryBytes = physicalMemoryBytes
        self.systemReserveBytes = systemReserveBytes
        self.pressure = pressure
    }

    public func updatePressure(_ level: MemoryPressureLevel) {
        pressure = level
    }

    public func currentPressure() -> MemoryPressureLevel {
        pressure
    }

    public func reserve(
        for descriptor: LocalModelDescriptor,
        requestedContextLength: Int
    ) throws -> ModelMemoryReservation {
        guard pressure != .critical else {
            throw FindoraError.processFailed(
                "Kritischer Speicherdruck verhindert das Laden eines Modells."
            )
        }
        let usable = physicalMemoryBytes > systemReserveBytes
            ? physicalMemoryBytes - systemReserveBytes
            : 0
        let alreadyReserved = reservations.values.reduce(Int64(0)) { $0 + $1.bytes }
        guard descriptor.estimatedRuntimeRAMBytes + alreadyReserved <= Int64(usable) else {
            throw FindoraError.processFailed(
                "Das sichere lokale Modellspeicherbudget ist ausgeschöpft."
            )
        }
        let pressureCap = pressure == .warning ? 1_024 : descriptor.defaultContextLength
        let eightGigabyteCap = physicalMemoryBytes <= 8_589_934_592 ? 2_048 : Int.max
        let contextLength = max(
            256,
            min(
                requestedContextLength,
                descriptor.maximumContextLength,
                pressureCap,
                eightGigabyteCap
            )
        )
        let reservation = ModelMemoryReservation(
            id: UUID(),
            modelID: descriptor.id,
            bytes: descriptor.estimatedRuntimeRAMBytes,
            contextLength: contextLength
        )
        reservations[reservation.id] = reservation
        return reservation
    }

    public func release(_ reservation: ModelMemoryReservation) {
        reservations[reservation.id] = nil
    }

    public func reservedBytes() -> Int64 {
        reservations.values.reduce(Int64(0)) { $0 + $1.bytes }
    }
}

public protocol ModelRuntimeControlling: Sendable {
    var modelID: String { get }
    func load(contextLength: Int) async throws
    func unload() async
    func isLoaded() async -> Bool
}

public actor ClosureModelRuntimeAdapter: ModelRuntimeControlling {
    public nonisolated let modelID: String
    private let loadAction: @Sendable (Int) async throws -> Void
    private let unloadAction: @Sendable () async -> Void
    private var loaded = false

    public init(
        modelID: String,
        load: @Sendable @escaping (Int) async throws -> Void,
        unload: @Sendable @escaping () async -> Void
    ) {
        self.modelID = modelID
        loadAction = load
        unloadAction = unload
    }

    public func load(contextLength: Int) async throws {
        guard !loaded else { return }
        try await loadAction(contextLength)
        loaded = true
    }

    public func unload() async {
        guard loaded else { return }
        await unloadAction()
        loaded = false
    }

    public func isLoaded() -> Bool {
        loaded
    }
}

public final class ModelLease: @unchecked Sendable {
    private actor ReleaseGate {
        private var released = false

        func claim() -> Bool {
            guard !released else { return false }
            released = true
            return true
        }
    }

    public let token: UUID
    public let modelID: String
    public let contextLength: Int
    private let manager: ModelLeaseManager
    private let releaseGate = ReleaseGate()

    fileprivate init(
        token: UUID,
        modelID: String,
        contextLength: Int,
        manager: ModelLeaseManager
    ) {
        self.token = token
        self.modelID = modelID
        self.contextLength = contextLength
        self.manager = manager
    }

    public func release() async {
        if await releaseGate.claim() {
            await manager.release(token: token)
        }
    }
}

public actor ModelLeaseManager {
    private struct Waiter {
        let id: UUID
        let descriptor: LocalModelDescriptor
        let requestedContextLength: Int
        let priority: Int
        let continuation: CheckedContinuation<ModelLease, Error>
    }

    private let memoryBudget: ModelMemoryBudget
    private var runtimes: [String: any ModelRuntimeControlling] = [:]
    private var activeToken: UUID?
    private var activeReservation: ModelMemoryReservation?
    private var loadedModelID: String?
    private var waiters: [Waiter] = []
    private var cooldownUntil: [String: Date] = [:]
    private var states: [String: ModelOperationalState] = [:]

    public init(memoryBudget: ModelMemoryBudget) {
        self.memoryBudget = memoryBudget
    }

    public func register(_ runtime: any ModelRuntimeControlling) {
        runtimes[runtime.modelID] = runtime
        states[runtime.modelID] = .installed
    }

    public func state(modelID: String) -> ModelOperationalState {
        states[modelID] ?? .notInstalled
    }

    public func acquire(
        descriptor: LocalModelDescriptor,
        requestedContextLength: Int,
        priority: Int,
        timeout: Duration = .seconds(120)
    ) async throws -> ModelLease {
        if activeToken == nil {
            return try await grant(
                descriptor: descriptor,
                requestedContextLength: requestedContextLength
            )
        }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(
                    Waiter(
                        id: waiterID,
                        descriptor: descriptor,
                        requestedContextLength: requestedContextLength,
                        priority: priority,
                        continuation: continuation
                    )
                )
                waiters.sort {
                    if $0.priority != $1.priority { return $0.priority > $1.priority }
                    return $0.id.uuidString < $1.id.uuidString
                }
                Task {
                    try? await Task.sleep(for: timeout)
                    self.timeout(waiterID: waiterID)
                }
            }
        } onCancel: {
            Task { await self.cancel(waiterID: waiterID) }
        }
    }

    public func withLease<T: Sendable>(
        descriptor: LocalModelDescriptor,
        task: ModelTask,
        requestedContextLength: Int,
        timeout: Duration = .seconds(120),
        operation: @Sendable (ModelLease) async throws -> T
    ) async throws -> T {
        let lease = try await acquire(
            descriptor: descriptor,
            requestedContextLength: requestedContextLength,
            priority: task.priority,
            timeout: timeout
        )
        do {
            let value = try await operation(lease)
            await lease.release()
            return value
        } catch {
            await lease.release()
            throw error
        }
    }

    fileprivate func release(token: UUID) async {
        guard activeToken == token else { return }
        if let reservation = activeReservation {
            await memoryBudget.release(reservation)
        }
        activeReservation = nil
        activeToken = nil
        await fulfillNext()
    }

    public func unloadIdleModel() async {
        guard activeToken == nil, let loadedModelID,
              let runtime = runtimes[loadedModelID] else { return }
        states[loadedModelID] = .unloading
        await runtime.unload()
        states[loadedModelID] = .disabled
        self.loadedModelID = nil
    }

    public func handleMemoryPressure(_ level: MemoryPressureLevel) async {
        await memoryBudget.updatePressure(level)
        if level == .critical {
            for waiter in waiters {
                waiter.continuation.resume(
                    throwing: FindoraError.processFailed(
                        "Modellaufgabe wegen kritischen Speicherdrucks pausiert."
                    )
                )
            }
            waiters.removeAll()
            if activeToken == nil {
                await unloadIdleModel()
            }
        }
    }

    private func grant(
        descriptor: LocalModelDescriptor,
        requestedContextLength: Int
    ) async throws -> ModelLease {
        if let until = cooldownUntil[descriptor.id], until > Date() {
            throw FindoraError.processFailed(
                "Das Modell befindet sich nach einem Ladefehler im Cooldown."
            )
        }
        guard let runtime = runtimes[descriptor.id] else {
            states[descriptor.id] = .notInstalled
            throw FindoraError.processFailed("Für das Modell ist keine lokale Runtime registriert.")
        }
        let reservation = try await memoryBudget.reserve(
            for: descriptor,
            requestedContextLength: requestedContextLength
        )
        let token = UUID()
        activeToken = token
        activeReservation = reservation
        do {
            if let loadedModelID, loadedModelID != descriptor.id,
               let previousRuntime = runtimes[loadedModelID] {
                states[loadedModelID] = .unloading
                await previousRuntime.unload()
                states[loadedModelID] = .disabled
                self.loadedModelID = nil
            }
            states[descriptor.id] = .loading
            try await runtime.load(contextLength: reservation.contextLength)
            loadedModelID = descriptor.id
            states[descriptor.id] = .loaded
            return ModelLease(
                token: token,
                modelID: descriptor.id,
                contextLength: reservation.contextLength,
                manager: self
            )
        } catch {
            await memoryBudget.release(reservation)
            activeReservation = nil
            activeToken = nil
            states[descriptor.id] = .damaged
            cooldownUntil[descriptor.id] = Date().addingTimeInterval(60)
            await fulfillNext()
            throw error
        }
    }

    private func fulfillNext() async {
        guard activeToken == nil, !waiters.isEmpty else { return }
        let waiter = waiters.removeFirst()
        do {
            let lease = try await grant(
                descriptor: waiter.descriptor,
                requestedContextLength: waiter.requestedContextLength
            )
            waiter.continuation.resume(returning: lease)
        } catch {
            waiter.continuation.resume(throwing: error)
        }
    }

    private func timeout(waiterID: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(
            throwing: FindoraError.processFailed("Zeitlimit der Modellwarteschlange überschritten.")
        )
    }

    private func cancel(waiterID: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}
