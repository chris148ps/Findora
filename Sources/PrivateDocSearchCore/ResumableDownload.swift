import Foundation

public struct ModelDownloadPausedError: LocalizedError, Sendable {
    public init() {}

    public var errorDescription: String? {
        "Der Modelldownload wurde pausiert."
    }
}

enum DownloadOperationError: Error {
    case paused(Data)
}

final class ResumableDownloadOperation: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct Result: Sendable {
        let file: URL
        let response: HTTPURLResponse
    }

    private let request: URLRequest
    private let resumeData: Data?
    private let destination: URL
    private let redirectValidator: @Sendable (URL) -> Bool
    private let progress: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result, Error>?
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var pauseRequested = false
    private var cancelRequested = false
    private var isFinished = false

    init(
        request: URLRequest,
        resumeData: Data?,
        destination: URL,
        redirectValidator: @Sendable @escaping (URL) -> Bool,
        progress: @Sendable @escaping (Int64, Int64) -> Void
    ) {
        self.request = request
        self.resumeData = resumeData
        self.destination = destination
        self.redirectValidator = redirectValidator
        self.progress = progress
    }

    func run() async throws -> Result {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.waitsForConnectivity = true
                configuration.timeoutIntervalForResource = 60 * 60 * 24
                let session = URLSession(
                    configuration: configuration,
                    delegate: self,
                    delegateQueue: nil
                )
                lock.lock()
                self.continuation = continuation
                self.session = session
                let task = resumeData.map(session.downloadTask(withResumeData:))
                    ?? session.downloadTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func pause() {
        lock.lock()
        guard !isFinished, !pauseRequested, !cancelRequested, let task else {
            lock.unlock()
            return
        }
        pauseRequested = true
        lock.unlock()

        task.cancel(byProducingResumeData: { [weak self] resumeData in
            guard let self else { return }
            self.finish(.failure(DownloadOperationError.paused(resumeData ?? Data())))
        })
    }

    func cancel() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        cancelRequested = true
        let task = task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, redirectValidator(url) else {
            completionHandler(nil)
            finish(.failure(PrivateDocSearchError.processFailed(
                "Modelldownload wurde auf eine nicht freigegebene Quelle umgeleitet."
            )))
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let response = downloadTask.response as? HTTPURLResponse else {
            finish(.failure(PrivateDocSearchError.processFailed("Ungültige Download-Antwort.")))
            return
        }
        do {
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: location, to: destination)
            finish(.success(Result(file: destination, response: response)))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let error else { return }
        lock.lock()
        let isPause = pauseRequested
        let isCancel = cancelRequested
        lock.unlock()
        if isPause {
            if let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                finish(.failure(DownloadOperationError.paused(resumeData)))
            }
            return
        }
        finish(.failure(isCancel ? CancellationError() : error))
    }

    private func finish(_ result: Swift.Result<Result, Error>) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = continuation
        self.continuation = nil
        let session = session
        self.session = nil
        task = nil
        lock.unlock()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }
}
