import CoreServices
import Foundation

public final class FolderChangeWatcher: @unchecked Sendable {
    private let url: URL
    private let handler: @Sendable () -> Void
    private let queue = DispatchQueue(
        label: "de.privatedocsearch.folder-watcher",
        qos: .utility
    )
    private var stream: FSEventStreamRef?
    private let lock = NSLock()

    public init(url: URL, handler: @Sendable @escaping () -> Void) {
        self.url = url
        self.handler = handler
    }

    deinit {
        stop()
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard stream == nil else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, clientInfo, _, _, _, _ in
            guard let clientInfo else { return }
            let watcher = Unmanaged<FolderChangeWatcher>
                .fromOpaque(clientInfo)
                .takeUnretainedValue()
            watcher.handler()
        }

        guard let newStream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            UInt32(kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagNoDefer)
        ) else {
            throw PrivateDocSearchError.processFailed(
                "Die rekursive Dateisystembeobachtung konnte nicht gestartet werden."
            )
        }
        FSEventStreamSetDispatchQueue(newStream, queue)
        guard FSEventStreamStart(newStream) else {
            FSEventStreamInvalidate(newStream)
            FSEventStreamRelease(newStream)
            throw PrivateDocSearchError.permissionDenied(url.path)
        }
        stream = newStream
    }

    public func stop() {
        lock.lock()
        let activeStream = stream
        stream = nil
        lock.unlock()

        guard let activeStream else { return }
        FSEventStreamStop(activeStream)
        FSEventStreamInvalidate(activeStream)
        FSEventStreamRelease(activeStream)
    }
}
