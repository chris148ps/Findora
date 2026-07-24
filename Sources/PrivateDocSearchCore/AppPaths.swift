import Foundation

public struct AppPaths: Sendable {
    public let applicationSupport: URL
    public let models: URL
    public let downloads: URL
    public let database: URL
    public let logs: URL

    public init(
        applicationSupport: URL? = nil,
        logs: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        let supportRoot = applicationSupport ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appending(path: "PrivateDocSearch", directoryHint: .isDirectory)

        let logRoot = logs ?? fileManager.urls(
            for: .libraryDirectory,
            in: .userDomainMask
        ).first!
            .appending(path: "Logs", directoryHint: .isDirectory)
            .appending(path: "PrivateDocSearch", directoryHint: .isDirectory)

        self.applicationSupport = supportRoot
        self.models = supportRoot.appending(path: "Models", directoryHint: .isDirectory)
        self.downloads = supportRoot.appending(path: ".downloads", directoryHint: .isDirectory)
        self.database = supportRoot.appending(path: "PrivateDocSearch.sqlite3")
        self.logs = logRoot

        for directory in [supportRoot, self.models, self.downloads, logRoot] {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
    }
}

