import Foundation

public struct AppPaths: Sendable {
    public let applicationSupport: URL
    public let models: URL
    public let downloads: URL
    public let mailArchive: URL
    public let database: URL
    public let logs: URL

    public init(
        applicationSupport: URL? = nil,
        modelStorage: URL? = nil,
        logs: URL? = nil,
        createDataDirectories: Bool = true,
        createModelDirectory: Bool = true,
        fileManager: FileManager = .default
    ) throws {
        let supportRoot = applicationSupport ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appending(path: "Findora", directoryHint: .isDirectory)

        let logRoot = logs ?? fileManager.urls(
            for: .libraryDirectory,
            in: .userDomainMask
        ).first!
            .appending(path: "Logs", directoryHint: .isDirectory)
            .appending(path: "Findora", directoryHint: .isDirectory)

        self.applicationSupport = supportRoot
        self.models = modelStorage
            ?? supportRoot.appending(path: "Models", directoryHint: .isDirectory)
        self.downloads = self.models.appending(path: ".downloads", directoryHint: .isDirectory)
        self.mailArchive = supportRoot.appending(path: "MailArchive", directoryHint: .isDirectory)
        self.database = supportRoot.appending(path: "Findora.sqlite3")
        self.logs = logRoot

        if createDataDirectories {
            for directory in [supportRoot, self.mailArchive] {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
            }
        }
        if createModelDirectory {
            for directory in [self.models, self.downloads] {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
            }
        }
        try fileManager.createDirectory(
            at: logRoot,
            withIntermediateDirectories: true
        )
    }
}
