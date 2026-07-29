import Foundation

public struct OCRRetryPolicy: Equatable, Sendable {
    public let maximumAttempts: Int
    public let minimumAttempts: Int
    public let maximumDuration: Duration
    public let automaticAcceptanceScore: Double

    public init(
        maximumAttempts: Int = 8,
        minimumAttempts: Int = 3,
        maximumDuration: Duration = .seconds(120),
        automaticAcceptanceScore: Double = 0.50
    ) {
        self.maximumAttempts = min(8, max(1, maximumAttempts))
        self.minimumAttempts = min(
            self.maximumAttempts,
            max(1, minimumAttempts)
        )
        self.maximumDuration = maximumDuration
        self.automaticAcceptanceScore = min(1, max(0, automaticAcceptanceScore))
    }

    public static let `default` = OCRRetryPolicy()
}

public struct OCRRetryStrategy: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let preprocessing: String
    public let renderDPI: Int
    public let enhanceContrast: Bool
    public let binarize: Bool
    public let adaptiveBinarize: Bool
    public let backgroundLightening: Bool
    public let reduceShadows: Bool
    public let denoise: Bool
    public let sharpen: Bool
    public let cropBorders: Bool
    public let rotatePages: Bool
    public let deskew: Bool
    public let languages: [String]
    public let engineSelection: OCREngineSelection?

    public init(
        id: String,
        displayName: String,
        preprocessing: String,
        renderDPI: Int,
        enhanceContrast: Bool = false,
        binarize: Bool = false,
        adaptiveBinarize: Bool = false,
        backgroundLightening: Bool = false,
        reduceShadows: Bool = false,
        denoise: Bool = false,
        sharpen: Bool = false,
        cropBorders: Bool = false,
        rotatePages: Bool = true,
        deskew: Bool = true,
        languages: [String] = ["deu", "eng"],
        engineSelection: OCREngineSelection? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.preprocessing = preprocessing
        self.renderDPI = renderDPI
        self.enhanceContrast = enhanceContrast
        self.binarize = binarize
        self.adaptiveBinarize = adaptiveBinarize
        self.backgroundLightening = backgroundLightening
        self.reduceShadows = reduceShadows
        self.denoise = denoise
        self.sharpen = sharpen
        self.cropBorders = cropBorders
        self.rotatePages = rotatePages
        self.deskew = deskew
        self.languages = languages
        self.engineSelection = engineSelection
    }

    public static func defaults(
        baseLanguages: [String],
        baseEngine: OCREngineSelection
    ) -> [OCRRetryStrategy] {
        var strategies = [
            OCRRetryStrategy(
                id: "standard",
                displayName: "Standard",
                preprocessing: "Standardrendering + automatische Drehung",
                renderDPI: 144,
                languages: baseLanguages,
                engineSelection: baseEngine
            ),
            OCRRetryStrategy(
                id: "high-resolution-300",
                displayName: "300 dpi",
                preprocessing: "Höhere Renderauflösung",
                renderDPI: 300,
                languages: baseLanguages,
                engineSelection: baseEngine
            ),
            OCRRetryStrategy(
                id: "contrast-300",
                displayName: "Kontrastanhebung + 300 dpi",
                preprocessing: "Graustufen, Kontrast erhöhen, Hintergrund aufhellen",
                renderDPI: 300,
                enhanceContrast: true,
                backgroundLightening: true,
                reduceShadows: true,
                languages: baseLanguages,
                engineSelection: baseEngine
            ),
            OCRRetryStrategy(
                id: "binarize-300",
                displayName: "Binarisierung + 300 dpi",
                preprocessing: "Schwarz-Weiß-Binarisierung und Rauschreduktion",
                renderDPI: 300,
                enhanceContrast: true,
                binarize: true,
                adaptiveBinarize: true,
                denoise: true,
                languages: baseLanguages,
                engineSelection: baseEngine
            ),
            OCRRetryStrategy(
                id: "deskew-crop",
                displayName: "Begradigung und Randbereinigung",
                preprocessing: "Begradigen, automatische Drehung und Randbereinigung",
                renderDPI: 300,
                enhanceContrast: true,
                backgroundLightening: true,
                reduceShadows: true,
                cropBorders: true,
                languages: baseLanguages,
                engineSelection: baseEngine
            ),
            OCRRetryStrategy(
                id: "german-english",
                displayName: "Deutsch + Englisch",
                preprocessing: "Alternative Sprachkombination",
                renderDPI: 300,
                enhanceContrast: true,
                languages: ["deu", "eng"],
                engineSelection: baseEngine
            ),
            OCRRetryStrategy(
                id: "high-resolution-400",
                displayName: "400 dpi + Kontrastanhebung",
                preprocessing: "Einzelverarbeitung mit hoher Auflösung",
                renderDPI: 400,
                enhanceContrast: true,
                backgroundLightening: true,
                languages: baseLanguages,
                engineSelection: baseEngine
            )
        ]
        if baseEngine != .appleVision {
            strategies.insert(
                OCRRetryStrategy(
                    id: "alternative-engine",
                    displayName: "Alternative OCR-Engine",
                    preprocessing: "Alternative lokale OCR-Engine + 300 dpi",
                    renderDPI: 300,
                    enhanceContrast: true,
                    languages: baseLanguages,
                    engineSelection: baseEngine == .tesseractOCRmyPDF
                        ? .appleVision
                        : .tesseractOCRmyPDF
                ),
                at: strategies.count - 1
            )
        }
        return strategies
    }

    public func configuration(from base: OCRConfiguration) -> OCRConfiguration {
        var configuration = base
        configuration.persistenceMode = .nonDestructive
        configuration.maximumParallelFiles = 1
        configuration.languages = languages
        configuration.rotatePages = rotatePages
        configuration.deskew = deskew
        configuration.clean = binarize || backgroundLightening
        configuration.renderDPI = renderDPI
        configuration.enhanceContrast = enhanceContrast
        configuration.binarize = binarize
        configuration.adaptiveBinarize = adaptiveBinarize
        configuration.backgroundLightening = backgroundLightening
        configuration.reduceShadows = reduceShadows
        configuration.denoise = denoise
        configuration.sharpen = sharpen
        configuration.cropBorders = cropBorders
        configuration.engineSelection = engineSelection ?? base.engineSelection
        configuration.retryStrategyID = id
        return configuration
    }
}

public struct OCRAttemptRecord: Equatable, Sendable {
    public let pageNumber: Int
    public let strategy: OCRRetryStrategy
    public let engine: OCREngine
    public let text: String
    public let quality: OCRPageQuality
    public let qualityScore: Double
    public let duration: Duration
    public let completedAt: Date
    public let textBoxes: [OCRTextBox]

    public init(
        pageNumber: Int,
        strategy: OCRRetryStrategy,
        engine: OCREngine,
        text: String,
        quality: OCRPageQuality,
        qualityScore: Double,
        duration: Duration,
        completedAt: Date,
        textBoxes: [OCRTextBox] = []
    ) {
        self.pageNumber = pageNumber
        self.strategy = strategy
        self.engine = engine
        self.text = text
        self.quality = quality
        self.qualityScore = qualityScore
        self.duration = duration
        self.completedAt = completedAt
        self.textBoxes = textBoxes
    }
}

public struct OCRRetryOutcome: Sendable {
    public let result: OCRResult?
    public let attempts: [OCRAttemptRecord]
    public let acceptedPageNumbers: Set<Int>
    public let bestStrategyByPage: [Int: OCRRetryStrategy]
    public let completedAttemptCount: Int
    public let stoppedByLimit: Bool
    public let failedAttemptDescriptions: [String]

    public init(
        result: OCRResult?,
        attempts: [OCRAttemptRecord],
        acceptedPageNumbers: Set<Int>,
        bestStrategyByPage: [Int: OCRRetryStrategy],
        completedAttemptCount: Int,
        stoppedByLimit: Bool,
        failedAttemptDescriptions: [String]
    ) {
        self.result = result
        self.attempts = attempts
        self.acceptedPageNumbers = acceptedPageNumbers
        self.bestStrategyByPage = bestStrategyByPage
        self.completedAttemptCount = completedAttemptCount
        self.stoppedByLimit = stoppedByLimit
        self.failedAttemptDescriptions = failedAttemptDescriptions
    }
}

public struct OCRQualityScorer: Sendable {
    public init() {}

    public func score(_ quality: OCRPageQuality, text: String) -> Double {
        let characters = max(1, quality.characterCount)
        let words = max(1, quality.wordCount)
        let confidence = min(1, max(0, (quality.meanConfidence ?? 55) / 100))
        let characterScore = min(1, Double(quality.characterCount) / 120)
        let wordScore = min(1, Double(quality.wordCount) / 20)
        let unusualPenalty = min(
            0.35,
            Double(quality.unusualCharacterCount) / Double(characters)
        )
        let brokenPenalty = min(
            0.35,
            Double(quality.suspectedBrokenWordCount) / Double(words)
        )
        let repeatedArtifacts = text.range(
            of: #"(.)\1{5,}|(?:[|_~^]\s*){5,}"#,
            options: .regularExpression
        ) != nil ? 0.18 : 0
        let plausibleNumberBonus = text.range(
            of: #"\b(?:\d{1,2}[./-]\d{1,2}[./-]\d{2,4}|\d{4,})\b"#,
            options: .regularExpression
        ) != nil ? 0.03 : 0
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let plausibleTokens = tokens.count(where: Self.isPlausibleToken)
        let plausibleWordRatio = tokens.isEmpty
            ? 0
            : Double(plausibleTokens) / Double(tokens.count)
        let fragmentedRatio = tokens.isEmpty
            ? 0
            : Double(tokens.count(where: { $0.count == 1 })) / Double(tokens.count)
        let wordPlausibility = min(0.16, plausibleWordRatio * 0.16)
        let fragmentationPenalty = min(0.20, max(0, fragmentedRatio - 0.30))
        return min(
            1,
            max(
                0,
                confidence * 0.35
                    + characterScore * 0.30
                    + wordScore * 0.25
                    + (quality.status == .good ? 0.10 : 0)
                    + plausibleNumberBonus
                    + wordPlausibility
                    - unusualPenalty
                    - brokenPenalty
                    - repeatedArtifacts
                    - fragmentationPenalty
            )
        )
    }

    public func isAutomaticallyAcceptable(
        quality: OCRPageQuality,
        text: String,
        score: Double,
        threshold: Double
    ) -> Bool {
        score >= threshold
            && quality.characterCount >= 8
            && quality.wordCount >= 2
            && quality.status != .likelyFailed
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && Self.plausibleWordRatio(text) >= 0.42
    }

    private static func plausibleWordRatio(_ text: String) -> Double {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return 0 }
        return Double(tokens.count(where: isPlausibleToken)) / Double(tokens.count)
    }

    private static func isPlausibleToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .punctuationCharacters)
        guard !trimmed.isEmpty else { return false }
        let scalars = trimmed.unicodeScalars
        let alphanumeric = scalars.count {
            $0.properties.isAlphabetic || $0.properties.numericType != nil
        }
        guard alphanumeric >= max(2, trimmed.count * 2 / 3) else {
            return false
        }
        if trimmed.allSatisfy(\.isNumber) {
            return trimmed.count >= 2
        }
        if scalars.count(where: \.properties.isAlphabetic) >= 3 {
            let vowels = CharacterSet(
                charactersIn: "aeiouyäöüAEIOUYÄÖÜ"
            )
            return scalars.contains(where: vowels.contains)
                || scalars.contains(where: { $0.properties.numericType != nil })
        }
        return true
    }
}

public struct OCRRetryCoordinator: Sendable {
    private let provider: any OCRProcessing
    private let policy: OCRRetryPolicy
    private let strategies: [OCRRetryStrategy]
    private let scorer: OCRQualityScorer

    public init(
        provider: any OCRProcessing,
        baseConfiguration: OCRConfiguration,
        policy: OCRRetryPolicy = .default,
        strategies: [OCRRetryStrategy]? = nil,
        scorer: OCRQualityScorer = OCRQualityScorer()
    ) {
        self.provider = provider
        self.policy = policy
        self.strategies = strategies ?? OCRRetryStrategy.defaults(
            baseLanguages: baseConfiguration.languages,
            baseEngine: baseConfiguration.engineSelection
        )
        self.scorer = scorer
    }

    public func run(
        file: DiscoveredPDF,
        baseConfiguration: OCRConfiguration,
        pageAnalyses: [PageContentAnalysis],
        onProgress: @Sendable (Int, Int, OCRRetryStrategy) async -> Void
    ) async throws -> OCRRetryOutcome {
        var seenStrategyIDs: Set<String> = []
        let uniqueStrategies = strategies.filter { strategy in
            seenStrategyIDs.insert(strategy.id).inserted
        }
        let limited = Array(uniqueStrategies.prefix(policy.maximumAttempts))
        let started = ContinuousClock.now
        var attempts: [OCRAttemptRecord] = []
        var best: [Int: OCRAttemptRecord] = [:]
        var completedAttempts = 0
        var lastResult: OCRResult?
        var stoppedByLimit = false
        var failedAttemptDescriptions: [String] = []

        for (index, strategy) in limited.enumerated() {
            try Task.checkCancellation()
            if started.duration(to: .now) >= policy.maximumDuration {
                stoppedByLimit = true
                break
            }
            await onProgress(index + 1, limited.count, strategy)
            let highResolution = strategy.renderDPI >= 300
            if highResolution {
                await OCRHighResolutionGate.shared.acquire()
            }
            do {
                let attemptStarted = ContinuousClock.now
                let remaining = policy.maximumDuration - started.duration(to: .now)
                let result = try await process(
                    file,
                    configuration: strategy.configuration(from: baseConfiguration),
                    timeout: remaining
                )
                let duration = attemptStarted.duration(to: .now)
                lastResult = result
                completedAttempts += 1
                let texts = Dictionary(uniqueKeysWithValues: result.pages.map {
                    ($0.pageNumber, $0.text)
                })
                let boxes = Dictionary(grouping: result.textBoxes, by: \.pageNumber)
                for quality in result.pageQualities where
                    baseConfiguration.targetPageNumbers?.contains(
                        quality.pageNumber
                    ) ?? true {
                    let text = texts[quality.pageNumber] ?? ""
                    let score = scorer.score(quality, text: text)
                    let record = OCRAttemptRecord(
                        pageNumber: quality.pageNumber,
                        strategy: strategy,
                        engine: result.engine,
                        text: text,
                        quality: quality,
                        qualityScore: score,
                        duration: duration,
                        completedAt: result.completedAt,
                        textBoxes: boxes[quality.pageNumber] ?? []
                    )
                    attempts.append(record)
                    if best[quality.pageNumber].map({
                        score > $0.qualityScore
                    }) ?? true {
                        best[quality.pageNumber] = record
                    }
                }
            } catch is CancellationError {
                if highResolution { await OCRHighResolutionGate.shared.release() }
                throw CancellationError()
            } catch {
                completedAttempts += 1
                failedAttemptDescriptions.append(
                    "\(strategy.displayName): \(error.localizedDescription)"
                )
            }
            if highResolution {
                await OCRHighResolutionGate.shared.release()
            }

            let relevantPages = pageAnalyses.filter {
                $0.status != .safelyEmpty
            }.map(\.pageNumber)
            if completedAttempts >= policy.minimumAttempts,
               !relevantPages.isEmpty,
               relevantPages.allSatisfy({ page in
                   guard let record = best[page] else { return false }
                   return scorer.isAutomaticallyAcceptable(
                       quality: record.quality,
                       text: record.text,
                       score: record.qualityScore,
                       threshold: policy.automaticAcceptanceScore
                   )
               }) {
                break
            }
        }

        let accepted = Set(best.compactMap { page, record in
            scorer.isAutomaticallyAcceptable(
                quality: record.quality,
                text: record.text,
                score: record.qualityScore,
                threshold: policy.automaticAcceptanceScore
            ) ? page : nil
        })
        let pages = best.values.sorted(by: {
            $0.pageNumber < $1.pageNumber
        }).map {
            ExtractedPage(
                pageNumber: $0.pageNumber,
                text: $0.text,
                source: $0.strategy.id == "standard"
                    ? ($0.engine == .appleVision ? .visionOCR : .verifiedOCR)
                    : .postprocessedOCR,
                qualityScore: $0.qualityScore
            )
        }
        let qualities = best.values.sorted(by: {
            $0.pageNumber < $1.pageNumber
        }).map(\.quality)
        let dominantEngine = Dictionary(grouping: best.values, by: \.engine)
            .max { lhs, rhs in lhs.value.count < rhs.value.count }?
            .key
        let assembledResult = lastResult.map {
            OCRResult(
                inputHash: $0.inputHash,
                outputHash: $0.outputHash,
                pageCount: $0.pageCount,
                pages: pages,
                persistedToOriginal: false,
                pageQualities: qualities,
                engine: dominantEngine ?? $0.engine,
                duration: started.duration(to: .now),
                messages: $0.messages,
                textBoxes: best.values.flatMap(\.textBoxes),
                completedAt: .now
            )
        }
        return OCRRetryOutcome(
            result: assembledResult,
            attempts: attempts,
            acceptedPageNumbers: accepted,
            bestStrategyByPage: best.mapValues(\.strategy),
            completedAttemptCount: completedAttempts,
            stoppedByLimit: stoppedByLimit,
            failedAttemptDescriptions: failedAttemptDescriptions
        )
    }

    private func process(
        _ file: DiscoveredPDF,
        configuration: OCRConfiguration,
        timeout: Duration
    ) async throws -> OCRResult {
        try await withThrowingTaskGroup(of: OCRResult.self) { group in
            group.addTask {
                try await provider.process(file, configuration: configuration)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw FindoraError.processFailed(
                    "Zeitlimit der automatischen OCR-Nachbearbeitung erreicht."
                )
            }
            guard let first = try await group.next() else {
                throw FindoraError.processFailed(
                    "OCR-Nachbearbeitung lieferte kein Ergebnis."
                )
            }
            group.cancelAll()
            return first
        }
    }
}

private actor OCRHighResolutionGate {
    static let shared = OCRHighResolutionGate()
    private var isOccupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isOccupied {
            isOccupied = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            isOccupied = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
