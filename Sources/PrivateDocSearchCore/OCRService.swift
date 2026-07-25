import Foundation
import CoreGraphics
import CoreText

public enum OCRPersistenceMode: String, Codable, CaseIterable, Sendable {
    case nonDestructive
    case persistent

    public var displayName: String {
        switch self {
        case .nonDestructive: "Nicht-destruktiv (empfohlen)"
        case .persistent: "PDF dauerhaft mit OCR versehen"
        }
    }
}

public enum OCREngineSelection: String, Codable, CaseIterable, Sendable {
    case automatic
    case appleVision
    case tesseractOCRmyPDF

    public var displayName: String {
        switch self {
        case .automatic: "Automatisch (empfohlen)"
        case .appleVision: "Apple Vision"
        case .tesseractOCRmyPDF: "Tesseract + OCRmyPDF"
        }
    }
}

public enum OCREngine: String, Codable, CaseIterable, Sendable {
    case appleVision
    case tesseract

    public var displayName: String {
        switch self {
        case .appleVision: "Apple Vision"
        case .tesseract: "Tesseract"
        }
    }
}

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
    public var persistenceMode: OCRPersistenceMode
    public var engineSelection: OCREngineSelection
    public var renderDPI: Int
    public var enhanceContrast: Bool
    public var binarize: Bool
    public var adaptiveBinarize: Bool
    public var backgroundLightening: Bool
    public var reduceShadows: Bool
    public var denoise: Bool
    public var sharpen: Bool
    public var cropBorders: Bool
    public var manualRotationDegrees: Int
    public var retryStrategyID: String?

    public init(
        isEnabled: Bool = true,
        languages: [String] = ["deu", "eng"],
        rotatePages: Bool = true,
        deskew: Bool = true,
        clean: Bool = false,
        optimizeLevel: Int = 0,
        createPDFA: Bool = false,
        maximumParallelFiles: Int = 1,
        cpuMode: OCRCPUMode = .normal,
        persistenceMode: OCRPersistenceMode = .nonDestructive,
        engineSelection: OCREngineSelection = .automatic,
        renderDPI: Int = 144,
        enhanceContrast: Bool = false,
        binarize: Bool = false,
        adaptiveBinarize: Bool = false,
        backgroundLightening: Bool = false,
        reduceShadows: Bool = false,
        denoise: Bool = false,
        sharpen: Bool = false,
        cropBorders: Bool = false,
        manualRotationDegrees: Int = 0,
        retryStrategyID: String? = nil
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
        self.persistenceMode = persistenceMode
        self.engineSelection = engineSelection
        self.renderDPI = min(600, max(72, renderDPI))
        self.enhanceContrast = enhanceContrast
        self.binarize = binarize
        self.adaptiveBinarize = adaptiveBinarize
        self.backgroundLightening = backgroundLightening
        self.reduceShadows = reduceShadows
        self.denoise = denoise
        self.sharpen = sharpen
        self.cropBorders = cropBorders
        self.manualRotationDegrees = [0, 90, 180, 270].contains(manualRotationDegrees)
            ? manualRotationDegrees
            : 0
        self.retryStrategyID = retryStrategyID
    }

    public static let `default` = OCRConfiguration()

    private enum CodingKeys: String, CodingKey {
        case isEnabled, languages, rotatePages, deskew, clean, optimizeLevel
        case createPDFA, maximumParallelFiles, cpuMode, persistenceMode, engineSelection
        case renderDPI, enhanceContrast, binarize, adaptiveBinarize
        case backgroundLightening, reduceShadows, denoise, sharpen, cropBorders
        case manualRotationDegrees, retryStrategyID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isEnabled: try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true,
            languages: try values.decodeIfPresent([String].self, forKey: .languages) ?? ["deu", "eng"],
            rotatePages: try values.decodeIfPresent(Bool.self, forKey: .rotatePages) ?? true,
            deskew: try values.decodeIfPresent(Bool.self, forKey: .deskew) ?? true,
            clean: try values.decodeIfPresent(Bool.self, forKey: .clean) ?? false,
            optimizeLevel: try values.decodeIfPresent(Int.self, forKey: .optimizeLevel) ?? 0,
            createPDFA: try values.decodeIfPresent(Bool.self, forKey: .createPDFA) ?? false,
            maximumParallelFiles: try values.decodeIfPresent(Int.self, forKey: .maximumParallelFiles) ?? 1,
            cpuMode: try values.decodeIfPresent(OCRCPUMode.self, forKey: .cpuMode) ?? .normal,
            persistenceMode: try values.decodeIfPresent(OCRPersistenceMode.self, forKey: .persistenceMode) ?? .nonDestructive,
            engineSelection: try values.decodeIfPresent(OCREngineSelection.self, forKey: .engineSelection) ?? .automatic,
            renderDPI: try values.decodeIfPresent(Int.self, forKey: .renderDPI) ?? 144,
            enhanceContrast: try values.decodeIfPresent(Bool.self, forKey: .enhanceContrast) ?? false,
            binarize: try values.decodeIfPresent(Bool.self, forKey: .binarize) ?? false,
            adaptiveBinarize: try values.decodeIfPresent(
                Bool.self,
                forKey: .adaptiveBinarize
            ) ?? false,
            backgroundLightening: try values.decodeIfPresent(Bool.self, forKey: .backgroundLightening) ?? false,
            reduceShadows: try values.decodeIfPresent(Bool.self, forKey: .reduceShadows) ?? false,
            denoise: try values.decodeIfPresent(Bool.self, forKey: .denoise) ?? false,
            sharpen: try values.decodeIfPresent(Bool.self, forKey: .sharpen) ?? false,
            cropBorders: try values.decodeIfPresent(Bool.self, forKey: .cropBorders) ?? false,
            manualRotationDegrees: try values.decodeIfPresent(Int.self, forKey: .manualRotationDegrees) ?? 0,
            retryStrategyID: try values.decodeIfPresent(String.self, forKey: .retryStrategyID)
        )
    }

    public var initiallyReportedEngine: OCREngine {
        if persistenceMode == .persistent {
            return .tesseract
        }
        switch engineSelection {
        case .automatic, .appleVision:
            #if os(macOS)
            return .appleVision
            #else
            return .tesseract
            #endif
        case .tesseractOCRmyPDF:
            return .tesseract
        }
    }

    public var requiresTesseractComponents: Bool {
        persistenceMode == .persistent || engineSelection == .tesseractOCRmyPDF
    }
}

public struct OCRDependencies: Equatable, Sendable {
    public let homebrew: URL?
    public let ocrMyPDF: URL?
    public let tesseract: URL?
    public let pdfText: URL?
    public let pdfInfo: URL?
    public let pdfToPPM: URL?
    public let environmentPATH: String
    public let installedLanguages: [String]
    public let versions: [String: String]
    public let selfTestPassed: Bool
    public let messages: [String]

    public init(
        homebrew: URL?,
        ocrMyPDF: URL?,
        tesseract: URL?,
        pdfText: URL?,
        pdfInfo: URL?,
        pdfToPPM: URL?,
        environmentPATH: String,
        installedLanguages: [String],
        versions: [String: String],
        selfTestPassed: Bool,
        messages: [String]
    ) {
        self.homebrew = homebrew
        self.ocrMyPDF = ocrMyPDF
        self.tesseract = tesseract
        self.pdfText = pdfText
        self.pdfInfo = pdfInfo
        self.pdfToPPM = pdfToPPM
        self.environmentPATH = environmentPATH
        self.installedLanguages = installedLanguages
        self.versions = versions
        self.selfTestPassed = selfTestPassed
        self.messages = messages
    }

    public var componentsInstalled: Bool {
        ocrMyPDF != nil
            && tesseract != nil
            && pdfText != nil
            && pdfInfo != nil
            && installedLanguages.contains("deu")
            && installedLanguages.contains("eng")
    }

    public var isReady: Bool { componentsInstalled && selfTestPassed }

    public static let notChecked = OCRDependencies(
        homebrew: nil,
        ocrMyPDF: nil,
        tesseract: nil,
        pdfText: nil,
        pdfInfo: nil,
        pdfToPPM: nil,
        environmentPATH: "",
        installedLanguages: [],
        versions: [:],
        selfTestPassed: false,
        messages: []
    )
}

public struct OCRDependencyChecker: Sendable {
    public let approvedDirectories: [URL]

    public init(approvedDirectories: [URL] = [
            URL(filePath: "/opt/homebrew/bin", directoryHint: .isDirectory),
            URL(filePath: "/usr/local/bin", directoryHint: .isDirectory),
            URL(filePath: "/usr/bin", directoryHint: .isDirectory),
            URL(filePath: "/bin", directoryHint: .isDirectory)
        ]) {
        self.approvedDirectories = approvedDirectories
    }

    public func check(
        customOCRMyPDF: URL? = nil,
        runFunctionalSelfTest: Bool = true
    ) -> OCRDependencies {
        let searchDirectories = resolvedSearchDirectories()
        let homebrew = executable(named: "brew", directories: searchDirectories)
        let ocr = executable(named: "ocrmypdf", custom: customOCRMyPDF)
        let tesseract = executable(named: "tesseract")
        let pdfText = executable(named: "pdftotext")
        let pdfInfo = executable(named: "pdfinfo")
        let pdfToPPM = executable(named: "pdftoppm")
        let environmentPATH = searchDirectories.map(\.path).joined(separator: ":")
        let languages = tesseract.map {
            installedLanguages(tesseract: $0, environmentPATH: environmentPATH)
        } ?? []
        var versions: [String: String] = [:]
        for (name, executable, arguments) in [
            ("OCRmyPDF", ocr, ["--version"]),
            ("Tesseract", tesseract, ["--version"]),
            ("pdftotext", pdfText, ["-v"]),
            ("pdfinfo", pdfInfo, ["-v"])
        ] {
            if let executable,
               let version = commandOutput(
                   executable: executable,
                   arguments: arguments,
                   environmentPATH: environmentPATH
               ) {
                versions[name] = version
            }
        }
        var messages: [String] = []

        if homebrew == nil { messages.append("Homebrew fehlt.") }
        if ocr == nil { messages.append("OCRmyPDF fehlt. Installation: brew install ocrmypdf") }
        if tesseract == nil { messages.append("Tesseract fehlt. Installation: brew install tesseract tesseract-lang") }
        if pdfText == nil || pdfInfo == nil { messages.append("Poppler fehlt. Installation: brew install poppler") }
        if !languages.contains("deu") { messages.append("Tesseract-Sprachdaten Deutsch (deu) fehlen.") }
        if !languages.contains("eng") { messages.append("Tesseract-Sprachdaten Englisch (eng) fehlen.") }
        let commandsPassed = ocr != nil
            && tesseract != nil
            && pdfText != nil
            && pdfInfo != nil
            && versions.count == 4
            && languages.contains("deu")
            && languages.contains("eng")
        let selfTestPassed = commandsPassed
            && runFunctionalSelfTest
            && functionalSelfTest(
                ocrMyPDF: ocr!,
                pdfText: pdfText!,
                environmentPATH: environmentPATH
            )
        if runFunctionalSelfTest, !selfTestPassed, messages.isEmpty {
            messages.append("Der OCR-Werkzeug-Selbsttest ist fehlgeschlagen.")
        } else if !runFunctionalSelfTest, commandsPassed, messages.isEmpty {
            messages.append("Der OCR-Werkzeug-Selbsttest wird ausgeführt.")
        }

        return OCRDependencies(
            homebrew: homebrew,
            ocrMyPDF: ocr,
            tesseract: tesseract,
            pdfText: pdfText,
            pdfInfo: pdfInfo,
            pdfToPPM: pdfToPPM,
            environmentPATH: environmentPATH,
            installedLanguages: languages,
            versions: versions,
            selfTestPassed: selfTestPassed,
            messages: messages
        )
    }

    private func resolvedSearchDirectories() -> [URL] {
        let inherited = ProcessInfo.processInfo.environment["PATH", default: ""]
            .split(separator: ":")
            .map { URL(filePath: String($0), directoryHint: .isDirectory) }
        var seen: Set<String> = []
        return (approvedDirectories + inherited).filter {
            seen.insert($0.standardizedFileURL.path).inserted
        }
    }

    private func executable(
        named name: String,
        custom: URL? = nil,
        directories: [URL]? = nil
    ) -> URL? {
        let candidates = [custom].compactMap { $0 }
            + (directories ?? resolvedSearchDirectories()).map { $0.appending(path: name) }
        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    private func installedLanguages(tesseract: URL, environmentPATH: String) -> [String] {
        guard let text = commandOutput(
            executable: tesseract,
            arguments: ["--list-langs"],
            environmentPATH: environmentPATH
        ) else { return [] }
        return text
            .components(separatedBy: .newlines)
            .dropFirst()
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func commandOutput(
        executable: URL,
        arguments: [String],
        environmentPATH: String
    ) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = environmentPATH
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    private func functionalSelfTest(
        ocrMyPDF: URL,
        pdfText: URL,
        environmentPATH: String
    ) -> Bool {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "PrivateDocSearch-selftest-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let input = directory.appending(path: "input.pdf")
        let output = directory.appending(path: "output.pdf")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            guard let bitmap = CGContext(
                data: nil,
                width: 1_200,
                height: 300,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
            bitmap.fill(CGRect(x: 0, y: 0, width: 1_200, height: 300))
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 64, nil)
            let attributes = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: CGColor(gray: 0, alpha: 1)
            ] as CFDictionary
            guard let attributed = CFAttributedStringCreate(
                nil,
                "PRIVATE DOC SEARCH OCR TEST 12345" as CFString,
                attributes
            ) else { return false }
            let line = CTLineCreateWithAttributedString(attributed)
            bitmap.textPosition = CGPoint(x: 35, y: 115)
            CTLineDraw(line, bitmap)
            guard let image = bitmap.makeImage() else { return false }

            var mediaBox = CGRect(x: 0, y: 0, width: 1_200, height: 300)
            guard let pdf = CGContext(input as CFURL, mediaBox: &mediaBox, nil) else {
                return false
            }
            pdf.beginPDFPage(nil)
            pdf.draw(image, in: mediaBox)
            pdf.endPDFPage()
            pdf.closePDF()

            guard commandOutput(
                executable: ocrMyPDF,
                arguments: [
                    "--force-ocr", "--output-type", "pdf", "--optimize", "0",
                    "--jobs", "1", "-l", "eng", input.path, output.path
                ],
                environmentPATH: environmentPATH
            ) != nil,
            let text = commandOutput(
                executable: pdfText,
                arguments: [output.path, "-"],
                environmentPATH: environmentPATH
            ) else {
                return false
            }
            return text.uppercased().contains("PRIVATE")
                && text.uppercased().contains("OCR")
        } catch {
            return false
        }
    }
}

public struct OCRResult: Equatable, Sendable {
    public let inputHash: String
    public let outputHash: String
    public let pageCount: Int
    public let pages: [ExtractedPage]
    public let persistedToOriginal: Bool
    public let pageQualities: [OCRPageQuality]
    public let engine: OCREngine
    public let duration: Duration
    public let messages: [String]
    public let completedAt: Date

    public init(
        inputHash: String,
        outputHash: String,
        pageCount: Int,
        pages: [ExtractedPage] = [],
        persistedToOriginal: Bool = true,
        pageQualities: [OCRPageQuality] = [],
        engine: OCREngine = .tesseract,
        duration: Duration = .zero,
        messages: [String] = [],
        completedAt: Date
    ) {
        self.inputHash = inputHash
        self.outputHash = outputHash
        self.pageCount = pageCount
        self.pages = pages
        self.persistedToOriginal = persistedToOriginal
        self.pageQualities = pageQualities
        self.engine = engine
        self.duration = duration
        self.messages = messages
        self.completedAt = completedAt
    }
}

public enum OCRQualityStatus: String, Codable, CaseIterable, Sendable {
    case good
    case review
    case likelyFailed

    public var displayName: String {
        switch self {
        case .good: "Gut"
        case .review: "Prüfen"
        case .likelyFailed: "Wahrscheinlich fehlgeschlagen"
        }
    }
}

public struct OCRPageQuality: Codable, Equatable, Sendable {
    public let pageNumber: Int
    public let meanConfidence: Double?
    public let characterCount: Int
    public let wordCount: Int
    public let unusualCharacterCount: Int
    public let suspectedBrokenWordCount: Int
    public let recognizedLanguage: String
    public let isEmpty: Bool
    public let imageToTextRatio: Double
    public let status: OCRQualityStatus

    public init(
        pageNumber: Int,
        meanConfidence: Double?,
        characterCount: Int,
        wordCount: Int,
        unusualCharacterCount: Int,
        suspectedBrokenWordCount: Int,
        recognizedLanguage: String,
        isEmpty: Bool,
        imageToTextRatio: Double,
        status: OCRQualityStatus
    ) {
        self.pageNumber = pageNumber
        self.meanConfidence = meanConfidence
        self.characterCount = characterCount
        self.wordCount = wordCount
        self.unusualCharacterCount = unusualCharacterCount
        self.suspectedBrokenWordCount = suspectedBrokenWordCount
        self.recognizedLanguage = recognizedLanguage
        self.isEmpty = isEmpty
        self.imageToTextRatio = imageToTextRatio
        self.status = status
    }
}

public struct OCRQualityEvaluator: Sendable {
    public init() {}

    public func evaluate(
        pages: [ExtractedPage],
        configuredLanguages: [String],
        meanConfidences: [Int: Double] = [:]
    ) -> [OCRPageQuality] {
        pages.map { page in
            let words = page.text.split(whereSeparator: \.isWhitespace).map(String.init)
            let unusual = page.text.unicodeScalars.filter {
                !$0.properties.isAlphabetic
                    && $0.properties.numericType == nil
                    && !CharacterSet.whitespacesAndNewlines.contains($0)
                    && !CharacterSet.punctuationCharacters.contains($0)
            }.count
            let broken = words.filter {
                $0.count >= 4
                    && $0.unicodeScalars.filter(\.properties.isAlphabetic).count * 2 < $0.count
            }.count
            let confidence = meanConfidences[page.pageNumber]
            let characters = page.text.trimmingCharacters(in: .whitespacesAndNewlines).count
            let density = min(1, Double(characters) / 1_500)
            let status: OCRQualityStatus
            if characters < 8 || (confidence ?? 100) < 40 {
                status = .likelyFailed
            } else if (confidence ?? 100) < 70
                        || unusual > max(3, characters / 20)
                        || broken > max(2, words.count / 10) {
                status = .review
            } else {
                status = .good
            }
            return OCRPageQuality(
                pageNumber: page.pageNumber,
                meanConfidence: confidence,
                characterCount: characters,
                wordCount: words.count,
                unusualCharacterCount: unusual,
                suspectedBrokenWordCount: broken,
                recognizedLanguage: detectedLanguage(
                    in: page.text,
                    configuredLanguages: configuredLanguages
                ),
                isEmpty: characters == 0,
                imageToTextRatio: 1 - density,
                status: status
            )
        }
    }

    private func detectedLanguage(
        in text: String,
        configuredLanguages: [String]
    ) -> String {
        let normalized = " \(text.lowercased()) "
        let germanMarkers = [" der ", " die ", " und ", " ist ", " nicht ", " ein ", " eine "]
        let englishMarkers = [" the ", " and ", " is ", " not ", " a ", " of ", " to "]
        let germanScore = germanMarkers.filter(normalized.contains).count
        let englishScore = englishMarkers.filter(normalized.contains).count
        if germanScore > englishScore, configuredLanguages.contains("deu") { return "deu" }
        if englishScore > germanScore, configuredLanguages.contains("eng") { return "eng" }
        return configuredLanguages.count == 1
            ? configuredLanguages[0]
            : "unbestimmt"
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

public actor OCRmyPDFProcessor: OCRProvider {
    public nonisolated let engine = OCREngine.tesseract
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
        let started = ContinuousClock.now
        try Task.checkCancellation()
        guard configuration.isEnabled else { throw PrivateDocSearchError.cancelled }
        guard dependencies.componentsInstalled, let executable = dependencies.ocrMyPDF else {
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
        var temporaryFiles = [temporary]
        defer {
            for url in temporaryFiles {
                try? fileManager.removeItem(at: url)
            }
        }

        try runOCR(
            executable: executable,
            configuration: configuration,
            input: file.url,
            output: temporary,
            recoveryAttempt: false
        )
        var bestURL = temporary
        var bestPages = try validateOutput(temporary, expectedPages: originalPageCount)
        var bestQualities = qualityResults(
            pdf: temporary,
            pages: bestPages,
            languages: configuration.languages
        )
        if bestQualities.contains(where: { $0.status == .likelyFailed }) {
            let retry = file.url.deletingLastPathComponent().appending(
                path: ".privatedocsearch-ocr-\(UUID().uuidString).pdf"
            )
            temporaryFiles.append(retry)
            do {
                try runOCR(
                    executable: executable,
                    configuration: configuration,
                    input: file.url,
                    output: retry,
                    recoveryAttempt: true
                )
                let retryPages = try validateOutput(retry, expectedPages: originalPageCount)
                let retryQualities = qualityResults(
                    pdf: retry,
                    pages: retryPages,
                    languages: configuration.languages
                )
                if qualityScore(retryQualities) > qualityScore(bestQualities) {
                    bestURL = retry
                    bestPages = retryPages
                    bestQualities = retryQualities
                }
            } catch {
                // The validated first attempt remains usable.
            }
        }
        guard try hasher.hash(fileAt: file.url) == inputHash else {
            throw PrivateDocSearchError.unstableFile(file.url.path)
        }

        let outputHash = try hasher.hash(fileAt: bestURL)
        if configuration.persistenceMode == .persistent {
            _ = try fileManager.replaceItemAt(
                file.url,
                withItemAt: bestURL,
                backupItemName: nil,
                options: []
            )
            _ = try validateOutput(file.url, expectedPages: originalPageCount)
        }
        return OCRResult(
            inputHash: inputHash,
            outputHash: outputHash,
            pageCount: originalPageCount,
            pages: bestPages,
            persistedToOriginal: configuration.persistenceMode == .persistent,
            pageQualities: bestQualities,
            engine: engine,
            duration: started.duration(to: .now),
            completedAt: Date()
        )
    }

    public func cancelCurrent() {
        currentProcess?.terminate()
    }

    private func arguments(
        configuration: OCRConfiguration,
        input: URL,
        output: URL,
        recoveryAttempt: Bool = false
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
        if configuration.clean || configuration.denoise {
            arguments.append("--clean")
        }
        if configuration.backgroundLightening || configuration.reduceShadows {
            arguments.append("--remove-background")
        }
        if configuration.renderDPI > 144 {
            arguments.append(contentsOf: [
                "--oversample", String(configuration.renderDPI)
            ])
        }
        if recoveryAttempt {
            if !configuration.rotatePages { arguments.append("--rotate-pages") }
            if !configuration.deskew { arguments.append("--deskew") }
            if configuration.renderDPI <= 144 {
                arguments.append(contentsOf: ["--oversample", "300"])
            }
        }
        arguments.append(contentsOf: [input.path, output.path])
        return arguments
    }

    private func runOCR(
        executable: URL,
        configuration: OCRConfiguration,
        input: URL,
        output: URL,
        recoveryAttempt: Bool
    ) throws {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments(
            configuration: configuration,
            input: input,
            output: output,
            recoveryAttempt: recoveryAttempt
        )
        process.standardOutput = pipe
        process.standardError = pipe
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = dependencies.environmentPATH
        process.environment = environment
        process.qualityOfService = configuration.cpuMode == .economical ? .utility : .userInitiated
        currentProcess = process
        defer { currentProcess = nil }
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else {
            throw PrivateDocSearchError.processFailed(
                Self.sanitizedDiagnostics(
                    String(decoding: data, as: UTF8.self),
                    replacing: input.path
                )
            )
        }
    }

    private func qualityScore(_ qualities: [OCRPageQuality]) -> Double {
        guard !qualities.isEmpty else { return -.infinity }
        return qualities.reduce(0) { result, quality in
            let statusBonus: Double = switch quality.status {
            case .good: 100
            case .review: 40
            case .likelyFailed: 0
            }
            return result + statusBonus + (quality.meanConfidence ?? 0)
                + min(Double(quality.characterCount), 2_000) / 100
        } / Double(qualities.count)
    }

    private func validateOutput(_ url: URL, expectedPages: Int) throws -> [ExtractedPage] {
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
        if let pdfInfo = dependencies.pdfInfo {
            let integrity = try run(executable: pdfInfo, arguments: [url.path])
            guard integrity.status == 0 else {
                throw PrivateDocSearchError.invalidPDF("pdfinfo meldet einen Strukturfehler.")
            }
        }
        return pages
    }

    private func qualityResults(
        pdf: URL,
        pages: [ExtractedPage],
        languages: [String]
    ) -> [OCRPageQuality] {
        var confidences: [Int: Double] = [:]
        for page in pages {
            if let confidence = tesseractConfidence(
                pdf: pdf,
                pageNumber: page.pageNumber,
                languages: languages
            ) {
                confidences[page.pageNumber] = confidence
            }
        }
        return OCRQualityEvaluator().evaluate(
            pages: pages,
            configuredLanguages: languages,
            meanConfidences: confidences
        )
    }

    private func tesseractConfidence(
        pdf: URL,
        pageNumber: Int,
        languages: [String]
    ) -> Double? {
        guard let renderer = dependencies.pdfToPPM,
              let tesseract = dependencies.tesseract else { return nil }
        let directory = fileManager.temporaryDirectory.appending(
            path: "PrivateDocSearch-quality-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: directory) }
            let prefix = directory.appending(path: "page")
            let render = try run(
                executable: renderer,
                arguments: [
                    "-f", String(pageNumber), "-l", String(pageNumber),
                    "-singlefile", "-r", "150", "-png", pdf.path, prefix.path
                ]
            )
            guard render.status == 0 else { return nil }
            let image = prefix.appendingPathExtension("png")
            let result = try run(
                executable: tesseract,
                arguments: [
                    image.path, "stdout", "-l", languages.joined(separator: "+"), "tsv"
                ]
            )
            guard result.status == 0 else { return nil }
            let confidences = result.output.components(separatedBy: .newlines).compactMap { line -> Double? in
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard fields.count >= 12,
                      fields[0] == "5",
                      !fields[11].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let value = Double(fields[10]),
                      value >= 0 else { return nil }
                return value
            }
            guard !confidences.isEmpty else { return nil }
            return confidences.reduce(0, +) / Double(confidences.count)
        } catch {
            return nil
        }
    }

    private func run(executable: URL, arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = dependencies.environmentPATH
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private static func sanitizedDiagnostics(_ diagnostics: String, replacing path: String) -> String {
        let sanitized = diagnostics.replacingOccurrences(of: path, with: "<Dokument>")
        return String(sanitized.suffix(2_000))
    }
}
