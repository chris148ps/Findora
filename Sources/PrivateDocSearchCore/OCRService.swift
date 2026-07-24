import Foundation

public enum OCRCPUMode: String, Codable, CaseIterable, Sendable {
    case economical
    case normal
    case fast

    public var displayName: String {
        switch self {
        case .economical: "Sparsam"
        case .normal: "Normal"
        case .fast: "Schnell"
        }
    }
}

public struct OCRConfiguration: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var languages: [String]
    public var rotatePages: Bool
    public var deskew: Bool
    public var clean: Bool
    public var optimizeLevel: Int
    public var createPDFA: Bool
    public var maximumParallelFiles: Int
    public var cpuMode: OCRCPUMode

    public init(
        isEnabled: Bool = true,
        languages: [String] = ["deu", "eng"],
        rotatePages: Bool = true,
        deskew: Bool = true,
        clean: Bool = false,
        optimizeLevel: Int = 0,
        createPDFA: Bool = false,
        maximumParallelFiles: Int = 1,
        cpuMode: OCRCPUMode = .normal
    ) {
        self.isEnabled = isEnabled
        self.languages = languages
        self.rotatePages = rotatePages
        self.deskew = deskew
        self.clean = clean
        self.optimizeLevel = min(max(optimizeLevel, 0), 3)
        self.createPDFA = createPDFA
        self.maximumParallelFiles = max(1, maximumParallelFiles)
        self.cpuMode = cpuMode
    }

    public static let `default` = OCRConfiguration()
}

public struct OCRDependencies: Equatable, Sendable {
    public let ocrMyPDF: URL?
    public let tesseract: URL?
    public let pdfText: URL?
    public let pdfInfo: URL?
    public let installedLanguages: [String]
    public let messages: [String]

    public var isReady: Bool {
        ocrMyPDF != nil
            && tesseract != nil
            && pdfText != nil
            && pdfInfo != nil
            && installedLanguages.contains("deu")
            && installedLanguages.contains("eng")
    }
}

public struct OCRDependencyChecker: Sendable {
    public let approvedDirectories: [URL]

    public init(approvedDirectories: [URL] = [
            URL(filePath: "/opt/homebrew/bin", directoryHint: .isDirectory),
            URL(filePath: "/usr/local/bin", directoryHint: .isDirectory)
        ]) {
        self.approvedDirectories = approvedDirectories
    }

    public func check(customOCRMyPDF: URL? = nil) -> OCRDependencies {
        let ocr = executable(named: "ocrmypdf", custom: customOCRMyPDF)
        let tesseract = executable(named: "tesseract")
        let pdfText = executable(named: "pdftotext")
        let pdfInfo = executable(named: "pdfinfo")
        let languages = tesseract.map(installedLanguages) ?? []
        var messages: [String] = []

        if ocr == nil { messages.append("OCRmyPDF fehlt. Installation: brew install ocrmypdf") }
        if tesseract == nil { messages.append("Tesseract fehlt. Installation: brew install tesseract tesseract-lang") }
        if pdfText == nil || pdfInfo == nil { messages.append("Poppler fehlt. Installation: brew install poppler") }
        if !languages.contains("deu") { messages.append("Tesseract-Sprachdaten Deutsch (deu) fehlen.") }
        if !languages.contains("eng") { messages.append("Tesseract-Sprachdaten Englisch (eng) fehlen.") }

        return OCRDependencies(
            ocrMyPDF: ocr,
            tesseract: tesseract,
            pdfText: pdfText,
            pdfInfo: pdfInfo,
            installedLanguages: languages,
            messages: messages
        )
    }

    private func executable(named name: String, custom: URL? = nil) -> URL? {
        let candidates = [custom].compactMap { $0 }
            + approvedDirectories.map { $0.appending(path: name) }
        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    private func installedLanguages(tesseract: URL) -> [String] {
        let process = Process()
        let output = Pipe()
        process.executableURL = tesseract
        process.arguments = ["--list-langs"]
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return String(decoding: data, as: UTF8.self)
                .components(separatedBy: .newlines)
                .dropFirst()
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } catch {
            return []
        }
    }
}

public struct OCRResult: Equatable, Sendable {
    public let inputHash: String
    public let outputHash: String
    public let pageCount: Int
    public let completedAt: Date

    public init(inputHash: String, outputHash: String, pageCount: Int, completedAt: Date) {
        self.inputHash = inputHash
        self.outputHash = outputHash
        self.pageCount = pageCount
        self.completedAt = completedAt
    }
}

public struct OCRTemporaryFileCleaner: Sendable {
    public init() {}

    @discardableResult
    public func removeAbandonedFiles(
        below root: URL,
        olderThan age: TimeInterval = 24 * 60 * 60,
        now: Date = Date()
    ) throws -> [URL] {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            throw PrivateDocSearchError.permissionDenied(root.path)
        }

        var removed: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values?.isRegularFile == true,
                  url.lastPathComponent.hasPrefix(".privatedocsearch-ocr-"),
                  url.pathExtension.lowercased() == "pdf",
                  let modified = values?.contentModificationDate,
                  now.timeIntervalSince(modified) >= age else {
                continue
            }
            try FileManager.default.removeItem(at: url)
            removed.append(url)
        }
        return removed
    }
}

public actor OCRmyPDFProcessor: OCRProcessing {
    private let dependencies: OCRDependencies
    private let extractor: PDFKitTextExtractor
    private let hasher: SHA256Hasher
    private let fileManager: FileManager
    private var currentProcess: Process?

    public init(
        dependencies: OCRDependencies,
        extractor: PDFKitTextExtractor = PDFKitTextExtractor(),
        hasher: SHA256Hasher = SHA256Hasher(),
        fileManager: FileManager = .default
    ) {
        self.dependencies = dependencies
        self.extractor = extractor
        self.hasher = hasher
        self.fileManager = fileManager
    }

    public func process(
        _ file: DiscoveredPDF,
        configuration: OCRConfiguration
    ) async throws -> OCRResult {
        try Task.checkCancellation()
        guard configuration.isEnabled else { throw PrivateDocSearchError.cancelled }
        guard dependencies.isReady, let executable = dependencies.ocrMyPDF else {
            throw PrivateDocSearchError.dependencyMissing(
                dependencies.messages.joined(separator: " ")
            )
        }
        let missingLanguages = configuration.languages.filter {
            !dependencies.installedLanguages.contains($0)
        }
        guard missingLanguages.isEmpty else {
            throw PrivateDocSearchError.dependencyMissing(
                "Tesseract-Sprachen fehlen: \(missingLanguages.joined(separator: ", "))"
            )
        }

        let inputHash = try hasher.hash(fileAt: file.url)
        let originalPageCount = try extractor.pageCount(of: file.url)
        let temporary = file.url.deletingLastPathComponent().appending(
            path: ".privatedocsearch-ocr-\(UUID().uuidString).pdf"
        )
        defer { try? fileManager.removeItem(at: temporary) }

        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments(
            configuration: configuration,
            input: file.url,
            output: temporary
        )
        process.standardOutput = output
        process.standardError = output
        process.qualityOfService = configuration.cpuMode == .economical ? .utility : .userInitiated
        currentProcess = process
        defer { currentProcess = nil }

        try process.run()
        let diagnosticData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let diagnostics = String(decoding: diagnosticData, as: UTF8.self)

        try Task.checkCancellation()
        guard process.terminationStatus == 0 else {
            throw PrivateDocSearchError.processFailed(
                Self.sanitizedDiagnostics(diagnostics, replacing: file.url.path)
            )
        }

        try validateOutput(temporary, expectedPages: originalPageCount)
        guard try hasher.hash(fileAt: file.url) == inputHash else {
            throw PrivateDocSearchError.unstableFile(file.url.path)
        }

        _ = try fileManager.replaceItemAt(
            file.url,
            withItemAt: temporary,
            backupItemName: nil,
            options: []
        )

        try validateOutput(file.url, expectedPages: originalPageCount)
        return OCRResult(
            inputHash: inputHash,
            outputHash: try hasher.hash(fileAt: file.url),
            pageCount: originalPageCount,
            completedAt: Date()
        )
    }

    public func cancelCurrent() {
        currentProcess?.terminate()
    }

    private func arguments(
        configuration: OCRConfiguration,
        input: URL,
        output: URL
    ) -> [String] {
        var arguments = [
            "--skip-text",
            "--output-type", configuration.createPDFA ? "pdfa" : "pdf",
            "--optimize", String(configuration.optimizeLevel),
            "--jobs", "1",
            "-l", configuration.languages.joined(separator: "+")
        ]
        if configuration.rotatePages { arguments.append("--rotate-pages") }
        if configuration.deskew { arguments.append("--deskew") }
        if configuration.clean { arguments.append("--clean") }
        arguments.append(contentsOf: [input.path, output.path])
        return arguments
    }

    private func validateOutput(_ url: URL, expectedPages: Int) throws {
        guard fileManager.fileExists(atPath: url.path),
              let handle = try? FileHandle(forReadingFrom: url) else {
            throw PrivateDocSearchError.invalidPDF("OCR-Ausgabedatei fehlt.")
        }
        defer { try? handle.close() }
        let signature = try handle.read(upToCount: 5)
        guard signature == Data("%PDF-".utf8) else {
            throw PrivateDocSearchError.invalidPDF("Ungültige PDF-Signatur.")
        }
        let pageCount = try extractor.pageCount(of: url)
        guard pageCount == expectedPages else {
            throw PrivateDocSearchError.invalidPDF(
                "Seitenzahl änderte sich von \(expectedPages) auf \(pageCount)."
            )
        }
        let pages = try extractor.extractPages(from: url)
        guard extractor.hasUsableTextLayer(pages) else {
            throw PrivateDocSearchError.invalidPDF("Keine brauchbare Textschicht nach OCR.")
        }
    }

    private static func sanitizedDiagnostics(_ diagnostics: String, replacing path: String) -> String {
        let sanitized = diagnostics.replacingOccurrences(of: path, with: "<Dokument>")
        return String(sanitized.suffix(2_000))
    }
}
