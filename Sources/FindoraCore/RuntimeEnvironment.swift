import Foundation

public enum FindoraRuntimeEnvironment {
    public static let testRootVariable = "FINDORA_TEST_ROOT"

    public static func testRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let rawPath = environment[testRootVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawPath.isEmpty else {
            return nil
        }

        let root = URL(fileURLWithPath: rawPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let temporaryRoot = fileManager.temporaryDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let temporaryPath = temporaryRoot.path
        let temporaryPrefix = temporaryPath.hasSuffix("/")
            ? temporaryPath
            : temporaryPath + "/"
        guard root.path.hasPrefix(temporaryPrefix),
              root.path != temporaryPath else {
            return nil
        }
        return root
    }

    public static func applicationSupportRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        if let root = testRoot(environment: environment, fileManager: fileManager) {
            return root.appending(path: "ApplicationSupport", directoryHint: .isDirectory)
        }
        return fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appending(path: "Findora", directoryHint: .isDirectory)
    }

    public static func logRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        if let root = testRoot(environment: environment, fileManager: fileManager) {
            return root.appending(path: "Logs", directoryHint: .isDirectory)
        }
        return fileManager.urls(
            for: .libraryDirectory,
            in: .userDomainMask
        ).first!
            .appending(path: "Logs", directoryHint: .isDirectory)
            .appending(path: "Findora", directoryHint: .isDirectory)
    }

    public static func temporaryRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        if let root = testRoot(environment: environment, fileManager: fileManager) {
            return root.appending(path: "Temporary", directoryHint: .isDirectory)
        }
        return fileManager.temporaryDirectory
    }

    public static func userDefaults(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> UserDefaults {
        guard let root = testRoot(
            environment: environment,
            fileManager: fileManager
        ) else {
            return .standard
        }
        let suite = "de.findora.app.test.\(stableIdentifier(for: root.path))"
        return UserDefaults(suiteName: suite) ?? .standard
    }

    private static func stableIdentifier(for value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
