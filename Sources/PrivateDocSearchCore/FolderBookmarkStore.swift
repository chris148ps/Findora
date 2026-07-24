import Foundation

public actor FolderBookmarkStore {
    private let defaults: UserDefaults
    private let bookmarkKey = "documentFolderSecurityScopedBookmark"
    private let displayPathKey = "documentFolderDisplayPath"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func save(url: URL) throws {
        let data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: [.isDirectoryKey, .volumeIdentifierKey],
            relativeTo: nil
        )
        defaults.set(data, forKey: bookmarkKey)
        defaults.set(url.path, forKey: displayPathKey)
    }

    public func resolve() throws -> ResolvedFolder? {
        guard let data = defaults.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )

        if stale {
            try save(url: url)
        }

        guard url.startAccessingSecurityScopedResource() else {
            throw PrivateDocSearchError.permissionDenied(url.path)
        }

        return ResolvedFolder(url: url)
    }

    public func displayPath() -> String? {
        defaults.string(forKey: displayPathKey)
    }

    public func clear() {
        defaults.removeObject(forKey: bookmarkKey)
        defaults.removeObject(forKey: displayPathKey)
    }
}

public final class ResolvedFolder: @unchecked Sendable {
    public let url: URL
    private var isActive = true

    init(url: URL) {
        self.url = url
    }

    deinit {
        stopAccess()
    }

    public func stopAccess() {
        if isActive {
            url.stopAccessingSecurityScopedResource()
            isActive = false
        }
    }
}

