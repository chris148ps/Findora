import Foundation

public enum AppLogLevel: String, Sendable {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

public actor AppFileLogger {
    public let fileURL: URL

    public init(
        logDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(
            at: logDirectory,
            withIntermediateDirectories: true
        )
        let fileURL = logDirectory.appending(path: "PrivateDocSearch.log")
        if !fileManager.fileExists(atPath: fileURL.path) {
            guard fileManager.createFile(
                atPath: fileURL.path,
                contents: Data(),
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw PrivateDocSearchError.processFailed(
                    "Die lokale Logdatei konnte nicht angelegt werden."
                )
            }
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
        self.fileURL = fileURL
    }

    public func log(
        _ level: AppLogLevel,
        category: String,
        message: String,
        path: String? = nil
    ) throws {
        let timestamp = Date().ISO8601Format()
        let safeCategory = Self.singleLine(category)
        let safeMessage = Self.singleLine(message)
        let safePath = path.map(Self.singleLine)
        let suffix = safePath.map { " path=\($0)" } ?? ""
        let line = "\(timestamp) [\(level.rawValue)] [\(safeCategory)] \(safeMessage)\(suffix)\n"

        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
        try handle.synchronize()
    }

    public func contents() throws -> String {
        try String(contentsOf: fileURL, encoding: .utf8)
    }

    private static func singleLine(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
