import Foundation

public enum MemoryPressureLevel: String, Equatable, Sendable {
    case normal
    case warning
    case critical
}

public final class MemoryPressureMonitor: @unchecked Sendable {
    public typealias Handler = @MainActor @Sendable (MemoryPressureLevel) async -> Void

    private let queue: DispatchQueue
    private let handler: Handler
    private let lock = NSLock()
    private var source: DispatchSourceMemoryPressure?

    public init(
        queue: DispatchQueue = .global(qos: .utility),
        handler: @escaping Handler
    ) {
        self.queue = queue
        self.handler = handler
    }

    deinit {
        stop()
    }

    @discardableResult
    public func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard source == nil else { return false }

        let newSource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: queue
        )
        newSource.setEventHandler { [weak self, weak newSource] in
            guard let self,
                  let eventSource = newSource,
                  self.isCurrent(eventSource) else {
                return
            }
            self.forward(Self.level(for: eventSource.data))
        }
        source = newSource
        newSource.resume()
        return true
    }

    public func stop() {
        lock.lock()
        let activeSource = source
        source = nil
        lock.unlock()
        activeSource?.cancel()
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return source != nil
    }

    public func simulateForDiagnostics(
        _ level: MemoryPressureLevel,
        from callbackQueue: DispatchQueue? = nil
    ) async -> Bool {
        let callbackQueue = callbackQueue ?? queue
        let handler = handler
        return await withCheckedContinuation { continuation in
            callbackQueue.async {
                let ranAwayFromMainThread = !Thread.isMainThread
                Task { @MainActor in
                    await handler(level)
                    continuation.resume(returning: ranAwayFromMainThread)
                }
            }
        }
    }

    private func forward(_ level: MemoryPressureLevel) {
        let handler = handler
        Task { @MainActor in
            await handler(level)
        }
    }

    private func isCurrent(_ candidate: DispatchSourceMemoryPressure) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let source else { return false }
        return source === candidate
    }

    private static func level(
        for event: DispatchSource.MemoryPressureEvent
    ) -> MemoryPressureLevel {
        if event.contains(.critical) {
            return .critical
        }
        if event.contains(.warning) {
            return .warning
        }
        return .normal
    }
}
