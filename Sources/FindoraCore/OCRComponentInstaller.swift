import Foundation

public struct OCRInstallationResult: Equatable, Sendable {
    public let output: String
    public let dependencies: OCRDependencies

    public init(output: String, dependencies: OCRDependencies) {
        self.output = output
        self.dependencies = dependencies
    }
}

public actor OCRComponentInstaller {
    public static let packageArguments = [
        "install", "ocrmypdf", "tesseract-lang", "poppler"
    ]

    public init() {}

    public func installMissing(from dependencies: OCRDependencies) throws -> OCRInstallationResult {
        guard let brew = dependencies.homebrew else {
            throw FindoraError.dependencyMissing(
                "Homebrew fehlt. Installiere Homebrew zuerst über die offizielle Anleitung."
            )
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = brew
        // Fixed executable and arguments only. User-controlled values never reach this process.
        process.arguments = Self.packageArguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = dependencies.environmentPATH
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let diagnostics = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw FindoraError.processFailed(String(diagnostics.suffix(4_000)))
        }

        let refreshed = OCRDependencyChecker().check()
        guard refreshed.isReady else {
            throw FindoraError.dependencyMissing(
                refreshed.messages.joined(separator: " ")
            )
        }
        return OCRInstallationResult(
            output: String(diagnostics.suffix(4_000)),
            dependencies: refreshed
        )
    }
}
