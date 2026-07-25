import AppKit
import Observation
import PDFKit
import PrivateDocSearchCore
import PrivateDocSearchMLX
import ServiceManagement
import SwiftUI

@main
struct PrivateDocSearchApplication: App {
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup("PrivateDocSearch", id: "main") {
            ContentView()
                .environment(state)
                .frame(minWidth: 980, minHeight: 680)
        }
        .defaultSize(width: 1180, height: 780)

        MenuBarExtra("PrivateDocSearch", systemImage: state.isProcessing ? "doc.text.magnifyingglass" : "magnifyingglass") {
            MenuBarContent()
                .environment(state)
        }

        Settings {
            SettingsView()
                .environment(state)
                .frame(width: 620, height: 520)
        }
    }
}

enum AppSection: String, CaseIterable, Identifiable {
    case search = "Suche"
    case status = "Dokumentenstatus"
    case maintenance = "Dokumentenwartung"
    case ocr = "OCR"
    case models = "Modelle"
    case settings = "Einstellungen"
    case logs = "Protokoll"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .search: "magnifyingglass"
        case .status: "doc.text"
        case .maintenance: "wrench.and.screwdriver"
        case .ocr: "text.viewfinder"
        case .models: "cpu"
        case .settings: "gearshape"
        case .logs: "list.bullet.rectangle"
        }
    }
}

struct SearchSessionTurn: Identifiable {
    let id = UUID()
    let question: String
    let answer: String
    let sources: [SearchSource]
    let possibleSources: [SearchSource]
    let plan: SearchPlan
}

@MainActor
@Observable
final class AppState {
    var selectedSection: AppSection? = .search
    var documentFolderPath: String?
    var folderStatus = "Kein Ordner ausgewählt"
    var statistics = DocumentStatistics()
    var isProcessing = false
    var isPaused = false
    var question = ""
    var answer = ""
    var searchResults: [SearchSource] = []
    var possibleSearchResults: [SearchSource] = []
    var submittedQuestion = ""
    var currentSearchPlan: SearchPlan?
    var searchPlanningNotice: String?
    var searchSession: [SearchSessionTurn] = []
    var previewSource: SearchSource?
    var isSearching = false
    var lastError: String?
    var logEntries: [(Date, String, String, String?)] = []
    var ocrConfiguration = OCRConfiguration.default
    var ocrDependencies: OCRDependencies
    var ocrDependenciesChecked = false
    var scanIntervalMinutes = 5
    var showExperimentalModels = false
    var llmIdleMinutes = 10
    var launchAtLogin = false
    var memoryPressure = "Normal"
    var availableModels: [InstalledModel] = []
    var downloadingModelID: String?
    var pausedModelID: String?
    var modelDownloadProgress: ModelDownloadProgress?
    var activeEmbeddingModelID: String?
    var activeAnswerModelID: String?
    var modelMessage: String?
    var isInstallingOCRComponents = false
    var ocrInstallationMessage: String?
    var duplicateGroups: [DuplicateGroup] = []
    var emptyPageCandidates: [EmptyPageCandidate] = []
    var emptyPDFCandidates: [EmptyPDFCandidate] = []
    var isMaintainingDocuments = false
    var maintenanceMessage: String?
    let hardwareProfile: HardwareProfile

    var activeEmbeddingModelVersion: String? {
        guard let activeEmbeddingModelID else { return nil }
        return availableModels.first {
            $0.id == activeEmbeddingModelID
        }?.descriptor.modelVersion
    }

    var hasMixedEmbeddingIndex: Bool {
        statistics.e5EmbeddedChunks > 0 && statistics.fallbackEmbeddedChunks > 0
    }

    private let paths: AppPaths
    private let database: SQLiteDatabase
    private let fileLogger: AppFileLogger
    private let maintenanceService: DocumentMaintenanceService
    private let bookmarkStore = FolderBookmarkStore()
    private let scanner: RecursivePDFScanner
    private var processor: DocumentProcessor
    private var searchService: HybridSearchService
    private let modelManager: LocalModelManager
    private var answerGenerator: (any AnswerGenerating)?
    private var resolvedFolder: ResolvedFolder?
    private var scanLoop: Task<Void, Never>?
    private var eventScanTask: Task<Void, Never>?
    private var folderWatcher: FolderChangeWatcher?
    private var modelDownloadTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var searchPlanCache: [String: SearchPlan] = [:]
    private var searchContext = SearchSessionContext(limit: 6)
    private var memoryPressureMonitor: MemoryPressureMonitor?
    private var statusEventTask: Task<Void, Never>?
    private var statusRefreshTask: Task<Void, Never>?
    private var statusConsistencyTask: Task<Void, Never>?
    private var statusRefreshPending = false

    init() {
        do {
            let paths = try AppPaths()
            self.paths = paths
            self.database = SQLiteDatabase(url: paths.database)
            self.fileLogger = try AppFileLogger(logDirectory: paths.logs)
            self.maintenanceService = DocumentMaintenanceService(database: database)
            self.scanner = RecursivePDFScanner(excludedRoots: [paths.applicationSupport])
            let catalog = try ModelCatalog.bundled()
            self.modelManager = LocalModelManager(catalog: catalog, paths: paths)
            self.hardwareProfile = HardwareProfile.current(storageURL: paths.applicationSupport)
            let embedder = TokenHashEmbedding()
            self.ocrDependencies = .notChecked
            let ocrFactory: @Sendable () -> any OCRProcessing = {
                OCRProviderRouter(
                    visionProvider: VisionOCRProvider(),
                    tesseractProviderFactory: {
                        OCRmyPDFProcessor(
                            dependencies: OCRDependencyChecker().check(
                                runFunctionalSelfTest: false
                            )
                        )
                    }
                )
            }
            self.processor = DocumentProcessor(
                database: database,
                embedder: embedder,
                ocrProcessorFactory: ocrFactory,
                fileLogger: fileLogger
            )
            self.searchService = HybridSearchService(database: database, embedder: embedder)
        } catch {
            fatalError("PrivateDocSearch-Verzeichnisse konnten nicht angelegt werden: \(error)")
        }

        startMemoryPressureMonitoring()
        Task { await start() }
    }

    func start() async {
        do {
            try await fileLogger.log(
                .info,
                category: "App",
                message: "PrivateDocSearch wird gestartet."
            )
            try await database.initialize()
            await startDocumentStatusMonitoring()
            await runMemoryPressureDiagnosticIfRequested()
            await loadSettings()
            if ocrConfiguration.requiresTesseractComponents {
                await refreshOCRComponents()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            let documentAccessDisabled =
                ProcessInfo.processInfo.environment["PRIVATEDOCSEARCH_DISABLE_DOCUMENT_ACCESS"] == "1"
            if documentAccessDisabled {
                documentFolderPath = nil
                resolvedFolder = nil
                folderStatus = "Dokumentzugriff für Diagnose deaktiviert"
                try? await fileLogger.log(
                    .info,
                    category: "Diagnose",
                    message: "Dokumentzugriff und Scan wurden für diesen Diagnoselauf deaktiviert."
                )
            } else {
                documentFolderPath = await bookmarkStore.displayPath()
                resolvedFolder = try await bookmarkStore.resolve()
                if let folder = resolvedFolder {
                    documentFolderPath = folder.url.path
                    folderStatus = "Erreichbar"
                    _ = try OCRTemporaryFileCleaner().removeAbandonedFiles(below: folder.url)
                    configureFolderWatcher(for: folder.url)
                }
            }
            await restoreModelSelection()
            await refreshModels()
            await refreshDatabaseState()
            startScanLoop()
            if resolvedFolder != nil, !documentAccessDisabled {
                await scanNow()
            }
        } catch {
            report(error)
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Dokumentenordner auswählen"
        panel.prompt = "Ordner verwenden"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            do {
                resolvedFolder?.stopAccess()
                try await bookmarkStore.save(url: url)
                resolvedFolder = try await bookmarkStore.resolve()
                documentFolderPath = url.path
                folderStatus = "Erreichbar"
                configureFolderWatcher(for: url)
                await scanNow()
            } catch {
                report(error)
            }
        }
    }

    func scanNow() async {
        guard !isPaused else { return }
        guard let folder = resolvedFolder else {
            report(PrivateDocSearchError.noDocumentFolder)
            return
        }
        isProcessing = true
        folderStatus = "Scan läuft …"
        defer { isProcessing = false }

        do {
            let files = try await scanner.scan(root: folder.url)
            try await database.saveScan(files: files, root: folder.url)
            folderStatus = "Erreichbar"
            await processor.processPending(ocrConfiguration: ocrConfiguration) { _ in }
            await refreshDatabaseState()
        } catch {
            folderStatus = "Nicht erreichbar"
            report(error)
        }
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        let processor = processor
        let fileLogger = fileLogger
        Task {
            await processor.setPaused(paused)
            do {
                try await database.setProcessingPaused(paused)
                await refreshDocumentStatus()
            } catch {
                report(error)
            }
            try? await fileLogger.log(
                .info,
                category: "Verarbeitung",
                message: paused
                    ? "OCR und Indexierung wurden pausiert."
                    : "OCR und Indexierung wurden fortgesetzt."
            )
            if !paused {
                await scanNow()
            }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            report(error)
        }
    }

    func saveSettings() {
        Task {
            do {
                let data = try JSONEncoder().encode(ocrConfiguration)
                guard let ocrJSON = String(data: data, encoding: .utf8) else {
                    throw PrivateDocSearchError.processFailed("OCR-Einstellungen konnten nicht codiert werden.")
                }
                try await database.setSetting(key: "ocrConfiguration", value: ocrJSON)
                try await database.setSetting(key: "scanIntervalMinutes", value: String(scanIntervalMinutes))
                try await database.setSetting(key: "llmIdleMinutes", value: String(llmIdleMinutes))
                try await database.setSetting(key: "showExperimentalModels", value: showExperimentalModels ? "1" : "0")
                startScanLoop()
                modelMessage = "Einstellungen wurden lokal gespeichert."
            } catch {
                report(error)
            }
        }
    }

    func retryFailedJobs() {
        Task {
            do {
                try await database.retryFailedJobs()
                await scanNow()
            } catch {
                report(error)
            }
        }
    }

    func refreshOCRComponents() async {
        let dependencies = await Task.detached {
            OCRDependencyChecker().check()
        }.value
        ocrDependencies = dependencies
        ocrDependenciesChecked = true
        let paths = [
            dependencies.ocrMyPDF,
            dependencies.tesseract,
            dependencies.pdfText,
            dependencies.pdfInfo
        ].compactMap(\.?.path).joined(separator: ", ")
        let versions = dependencies.versions
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value.replacingOccurrences(of: "\n", with: " "))" }
            .joined(separator: "; ")
        try? await fileLogger.log(
            dependencies.isReady ? .info : .warning,
            category: "OCR-Komponenten",
            message: "PATH=\(dependencies.environmentPATH); Werkzeuge=\(paths); Versionen=\(versions); Selbsttest=\(dependencies.selfTestPassed)"
        )
    }

    func installMissingOCRComponents() {
        guard !isInstallingOCRComponents else { return }
        guard ocrConfiguration.requiresTesseractComponents else {
            ocrInstallationMessage = "Für Apple Vision werden keine externen OCR-Komponenten benötigt."
            return
        }
        isInstallingOCRComponents = true
        ocrInstallationMessage = "OCR-Komponenten werden installiert …"
        let dependencies = ocrDependencies
        Task {
            defer { isInstallingOCRComponents = false }
            do {
                let result = try await OCRComponentInstaller().installMissing(from: dependencies)
                ocrDependencies = result.dependencies
                ocrInstallationMessage = "Installation und Werkzeug-Selbsttest erfolgreich."
                try? await fileLogger.log(
                    .info,
                    category: "OCR-Komponenten",
                    message: "OCR-Komponenten wurden installiert und erneut geprüft."
                )
            } catch {
                ocrInstallationMessage = error.localizedDescription
                report(error)
                await refreshOCRComponents()
            }
        }
    }

    func rebuildSearchIndex() {
        guard !isProcessing else { return }
        isProcessing = true
        Task {
            defer { isProcessing = false }
            do {
                try await processor.rebuildSearchIndex { _ in }
                modelMessage = "Der Suchindex wurde aus dem gespeicherten Text neu aufgebaut."
                await refreshDatabaseState()
            } catch {
                report(error)
            }
        }
    }

    func resetOCRData() {
        guard !isProcessing else { return }
        Task {
            do {
                try await database.resetOCRData()
                try? await fileLogger.log(
                    .warning,
                    category: "Indexwartung",
                    message: "OCR-Text, OCR-Qualität und davon abhängige Indexdaten wurden zurückgesetzt."
                )
                await scanNow()
            } catch {
                report(error)
            }
        }
    }

    func deleteDocumentIndex() {
        guard !isProcessing else { return }
        setPaused(true)
        Task {
            do {
                try await database.deleteDocumentIndex()
                try? await fileLogger.log(
                    .warning,
                    category: "Indexwartung",
                    message: "Der vollständige Dokumentindex wurde gelöscht; PDFs, Modelle und Einstellungen blieben erhalten."
                )
                modelMessage = "Dokumentindex gelöscht. Verarbeitung bleibt bis zum manuellen Fortsetzen pausiert."
                await refreshDatabaseState()
            } catch {
                report(error)
            }
        }
    }

    func repairIndex() {
        guard !isProcessing else { return }
        Task {
            do {
                let result = try await database.repairIndex()
                modelMessage = result
                try? await fileLogger.log(
                    .info,
                    category: "Indexwartung",
                    message: result
                )
                await refreshDatabaseState()
            } catch {
                report(error)
            }
        }
    }

    func refreshMaintenance() async {
        do {
            async let duplicates = database.duplicateGroups()
            async let emptyPages = database.emptyPageCandidates()
            async let emptyPDFs = database.emptyPDFCandidates()
            let snapshot = try await (duplicates, emptyPages, emptyPDFs)
            duplicateGroups = snapshot.0
            emptyPageCandidates = snapshot.1
            emptyPDFCandidates = snapshot.2
        } catch {
            report(error)
        }
    }

    func analyzeMissingPages() {
        guard !isMaintainingDocuments, !isProcessing else { return }
        isMaintainingDocuments = true
        maintenanceMessage = "Fehlende Seitenanalysen werden ergänzt …"
        Task {
            defer { isMaintainingDocuments = false }
            do {
                let count = try await maintenanceService.analyzeMissingPages()
                maintenanceMessage = count == 0
                    ? "Alle indexierten PDFs besitzen bereits eine Seitenanalyse."
                    : "\(count) PDF(s) wurden ohne erneute OCR visuell analysiert."
                try? await fileLogger.log(
                    .info,
                    category: "Dokumentenwartung",
                    message: "Fehlende Seitenanalysen ergänzt: \(count)."
                )
                await refreshMaintenance()
                await refreshDocumentStatus()
            } catch {
                report(error)
            }
        }
    }

    func setPageDecision(
        _ candidate: EmptyPageCandidate,
        decision: PageReviewDecision
    ) {
        Task {
            do {
                try await database.setPageReviewDecision(
                    path: candidate.absolutePath,
                    pageNumber: candidate.pageNumber,
                    decision: decision
                )
                await refreshMaintenance()
            } catch {
                report(error)
            }
        }
    }

    func removeConfirmedEmptyPages(_ candidates: [EmptyPageCandidate]) {
        guard !candidates.isEmpty,
              !isMaintainingDocuments,
              !isProcessing else { return }
        isMaintainingDocuments = true
        maintenanceMessage = "Bestätigte leere Seiten werden sicher entfernt …"
        Task {
            defer { isMaintainingDocuments = false }
            do {
                for group in Dictionary(grouping: candidates, by: \.absolutePath).values {
                    guard let representative = group.first else { continue }
                    try await maintenanceService.removePages(
                        from: representative,
                        pageNumbers: Set(group.map(\.pageNumber))
                    )
                }
                await processor.processPending(
                    ocrConfiguration: ocrConfiguration
                ) { _ in }
                maintenanceMessage =
                    "\(candidates.count) bestätigte Seite(n) entfernt; Originalfassungen liegen im Papierkorb und der Suchindex wurde gezielt aktualisiert."
                try? await fileLogger.log(
                    .warning,
                    category: "Dokumentenwartung",
                    message: "Bestätigte leere Seiten entfernt und betroffene PDFs neu indexiert: \(candidates.count)."
                )
                await refreshMaintenance()
                await refreshDatabaseState()
            } catch {
                report(error)
            }
        }
    }

    func trashEmptyPDFs(_ candidates: [EmptyPDFCandidate]) {
        guard !candidates.isEmpty,
              !isMaintainingDocuments,
              !isProcessing else { return }
        isMaintainingDocuments = true
        maintenanceMessage = "Bestätigte leere PDFs werden in den Papierkorb verschoben …"
        Task {
            defer { isMaintainingDocuments = false }
            do {
                let count = try await maintenanceService.trashEmptyPDFs(candidates)
                maintenanceMessage =
                    "\(count) vollständig leere PDF(s) wurden in den macOS-Papierkorb verschoben."
                try? await fileLogger.log(
                    .warning,
                    category: "Dokumentenwartung",
                    message: "Vollständig leere PDFs in den Papierkorb verschoben: \(count)."
                )
                await refreshMaintenance()
                await refreshDatabaseState()
            } catch {
                report(error)
            }
        }
    }

    func trashDuplicateLocations(_ locations: [DuplicateLocation]) {
        guard !locations.isEmpty,
              !isMaintainingDocuments,
              !isProcessing else { return }
        let hashesByPath = Dictionary(uniqueKeysWithValues: locations.compactMap {
            location -> (String, String)? in
            guard let hash = duplicateGroups.first(where: {
                $0.locations.contains(location)
            })?.contentHash else { return nil }
            return (location.absolutePath, hash)
        })
        guard hashesByPath.count == locations.count else {
            report(
                PrivateDocSearchError.processFailed(
                    "Die Duplikatauswahl ist nicht mehr aktuell."
                )
            )
            return
        }
        isMaintainingDocuments = true
        maintenanceMessage = "Ausgewählte Duplikate werden in den Papierkorb verschoben …"
        Task {
            defer { isMaintainingDocuments = false }
            do {
                let count = try await maintenanceService.trashDuplicateLocations(
                    expectedHashesByPath: hashesByPath
                )
                maintenanceMessage =
                    "\(count) bestätigte SHA-256-Duplikat(e) wurden in den macOS-Papierkorb verschoben."
                try? await fileLogger.log(
                    .warning,
                    category: "Dokumentenwartung",
                    message: "SHA-256-Duplikate in den Papierkorb verschoben: \(count)."
                )
                await refreshMaintenance()
                await refreshDatabaseState()
            } catch {
                report(error)
            }
        }
    }

    func previewMaintenanceFile(
        path: String,
        fileName: String,
        relativePath: String,
        pageNumber: Int = 1
    ) {
        previewSource = SearchSource(
            id: "\(path)#\(pageNumber)",
            documentID: 0,
            chunkID: "maintenance",
            fileName: fileName,
            absolutePath: path,
            relativePath: relativePath,
            pageNumber: pageNumber,
            excerpt: "",
            score: 0
        )
    }

    func submitQuestion() {
        let value = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !isSearching else { return }
        guard !isProcessing else {
            answer = "OCR oder Indexierung läuft gerade. Pausiere die Verarbeitung oder warte bis zum Abschluss, bevor das lokale Sprachmodell geladen wird."
            return
        }
        isSearching = true
        answer = ""
        searchResults = []
        possibleSearchResults = []
        submittedQuestion = value
        searchPlanningNotice = nil
        question = ""

        searchTask = Task {
            defer {
                isSearching = false
                searchTask = nil
            }
            do {
                let rulePlanner = RuleBasedSearchPlanner()
                let isFollowUp = rulePlanner.isFollowUp(value)
                let rulePlan = rulePlanner.plan(
                    query: value,
                    previousPlan: isFollowUp ? searchContext.latestPlan : nil
                )
                let contextKey = isFollowUp
                    ? searchContext.latestPlan?.retrievalTerms.joined(separator: "|") ?? ""
                    : ""
                let cacheKey = "\(value.lowercased())|\(contextKey)"
                let plan: SearchPlan
                if let cached = searchPlanCache[cacheKey] {
                    plan = cached
                } else if rulePlanner.needsModelPlanning(value),
                          let planner = answerGenerator as? any SearchPlanning {
                    do {
                        plan = try await planner.planSearch(
                            query: value,
                            ruleBasedPlan: rulePlan
                        )
                    } catch {
                        plan = rulePlan
                        searchPlanningNotice = "Der lokale KI-Suchplan war ungültig; die sichere regelbasierte Analyse wurde verwendet."
                    }
                    searchPlanCache[cacheKey] = plan
                } else {
                    plan = rulePlan
                    searchPlanCache[cacheKey] = plan
                }
                if searchPlanCache.count > 12,
                   let firstKey = searchPlanCache.keys.first {
                    searchPlanCache.removeValue(forKey: firstKey)
                }
                currentSearchPlan = plan
                searchContext.record(plan)

                let outcome = try await searchService.search(value, plan: plan)
                let sources = outcome.directMatches
                searchResults = sources
                possibleSearchResults = outcome.possibleMatches
                if sources.isEmpty {
                    answer = "Keine ausreichend passenden Dokumente gefunden."
                } else if let answerGenerator {
                    answer = try await answerGenerator.answer(
                        question: value,
                        sources: sources
                    )
                } else {
                    answer = """
                    Es wurden passende lokale Textstellen gefunden. Installiere und aktiviere im Bereich „Modelle“ \
                    ein kompatibles Antwortmodell, um daraus eine belegte natürlichsprachliche Antwort erzeugen zu lassen.
                    """
                }
                searchSession.append(
                    SearchSessionTurn(
                        question: value,
                        answer: answer,
                        sources: sources,
                        possibleSources: outcome.possibleMatches,
                        plan: plan
                    )
                )
                if searchSession.count > 6 {
                    searchSession.removeFirst(searchSession.count - 6)
                }
            } catch is CancellationError {
                answer = "Antwort wurde abgebrochen."
            } catch {
                report(error)
            }
        }
    }

    func cancelSearch() {
        searchTask?.cancel()
    }

    func copyAnswer() {
        guard !answer.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(answer, forType: .string)
    }

    func clearSearchSession() {
        searchSession = []
        searchContext.reset()
        searchPlanCache = [:]
        submittedQuestion = ""
        answer = ""
        searchResults = []
        possibleSearchResults = []
        currentSearchPlan = nil
    }

    func open(_ source: SearchSource) {
        NSWorkspace.shared.open(URL(filePath: source.absolutePath))
    }

    func reveal(_ source: SearchSource) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: source.absolutePath)])
    }

    func showPage(_ source: SearchSource) {
        previewSource = source
    }

    func refreshDatabaseState() async {
        do {
            await refreshDocumentStatus()
            logEntries = try await database.recentErrors()
        } catch {
            report(error)
        }
    }

    private func refreshDocumentStatus() async {
        do {
            let snapshot = try await database.statistics()
            statistics = snapshot
            isPaused = snapshot.isPaused
            if selectedSection == .maintenance {
                await refreshMaintenance()
            }
        } catch {
            report(error)
        }
    }

    private func startDocumentStatusMonitoring() async {
        statusEventTask?.cancel()
        statusConsistencyTask?.cancel()
        let changes = await database.statusChanges()
        statusEventTask = Task { [weak self] in
            for await _ in changes {
                guard !Task.isCancelled, let self else { return }
                self.scheduleDocumentStatusRefresh()
            }
        }
        statusConsistencyTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self else { return }
                await self.refreshDocumentStatus()
            }
        }
    }

    private func scheduleDocumentStatusRefresh() {
        guard statusRefreshTask == nil else {
            statusRefreshPending = true
            return
        }
        statusRefreshPending = false
        statusRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            await self.refreshDocumentStatus()
            self.statusRefreshTask = nil
            if self.statusRefreshPending {
                self.scheduleDocumentStatusRefresh()
            }
        }
    }

    func refreshModels() async {
        availableModels = await modelManager.models(profile: hardwareProfile)
    }

    func installModel(_ model: InstalledModel, activateAfterInstall: Bool = false) {
        guard modelDownloadTask == nil else { return }
        downloadingModelID = model.id
        pausedModelID = nil
        modelMessage = nil
        modelDownloadTask = Task {
            defer {
                downloadingModelID = nil
                modelDownloadProgress = nil
                modelDownloadTask = nil
            }
            do {
                _ = try await modelManager.install(
                    modelID: model.id,
                    profile: hardwareProfile,
                    validation: { directory, descriptor in
                        switch descriptor.kind {
                        case .embedding:
                            let provider = MLXEmbeddingProvider(
                                modelID: descriptor.id,
                                modelVersion: descriptor.modelVersion,
                                directory: directory,
                                dimensions: 384
                            )
                            try await provider.test()
                            await provider.unload()
                        case .answer:
                            let generator = MLXAnswerGenerator(
                                directory: directory,
                                contextLength: descriptor.defaultContextLength
                            )
                            try await generator.test()
                        }
                    }
                ) { [weak self] progress in
                    await MainActor.run {
                        self?.modelDownloadProgress = progress
                    }
                }
                modelMessage = "\(model.descriptor.displayName) wurde sicher installiert."
                await refreshModels()
                if activateAfterInstall {
                    activateModel(model)
                }
            } catch is ModelDownloadPausedError {
                pausedModelID = model.id
                modelMessage = "Modelldownload pausiert. Er kann fortgesetzt oder verworfen werden."
            } catch is CancellationError {
                modelMessage = "Modelldownload wurde abgebrochen."
            } catch {
                report(error)
            }
        }
    }

    func cancelModelDownload() {
        Task { await modelManager.cancelDownload() }
        modelDownloadTask?.cancel()
    }

    func pauseModelDownload() {
        Task { await modelManager.pauseDownload() }
    }

    func discardPausedDownload() {
        Task {
            await modelManager.discardPausedDownload()
            pausedModelID = nil
            modelMessage = "Pausierter Download wurde verworfen."
        }
    }

    func activateModel(_ model: InstalledModel) {
        Task {
            do {
                guard let directory = await modelManager.installedDirectory(modelID: model.id) else {
                    throw PrivateDocSearchError.processFailed("Das Modell ist nicht installiert.")
                }
                switch model.descriptor.kind {
                case .embedding:
                    let provider = MLXEmbeddingProvider(
                        modelID: model.id,
                        modelVersion: model.descriptor.modelVersion,
                        directory: directory
                    )
                    try await provider.test()
                    let previousProcessor = processor
                    do {
                        processor = makeProcessor(embedder: provider)
                        try await processor.rebuildSearchIndex { _ in }
                        modelMessage = "Der neue Embedding-Index wird aufgebaut; die bisherige Suche bleibt aktiv."
                        let coverage = try await database.embeddingCoverage(
                            modelID: model.id,
                            modelVersion: model.descriptor.modelVersion
                        )
                        guard coverage.embeddedChunks == coverage.totalChunks else {
                            throw PrivateDocSearchError.processFailed(
                                "Neuindexierung unvollständig (\(coverage.embeddedChunks) von \(coverage.totalChunks) Chunks)."
                            )
                        }
                        try await modelManager.activate(modelID: model.id)
                        activeEmbeddingModelID = model.id
                        searchService = HybridSearchService(database: database, embedder: provider)
                        try await database.setSetting(key: "activeEmbeddingModelID", value: model.id)
                        modelMessage = "Embedding-Modell und vollständig aufgebauter Index wurden aktiviert."
                    } catch {
                        processor = previousProcessor
                        await provider.unload()
                        throw error
                    }
                case .answer:
                    let generator = MLXAnswerGenerator(
                        directory: directory,
                        contextLength: model.descriptor.defaultContextLength,
                        idleTimeout: .seconds(llmIdleMinutes * 60)
                    )
                    try await generator.test()
                    try await modelManager.activate(modelID: model.id)
                    await unloadAnswerModel(reason: "Modellwechsel")
                    answerGenerator = generator
                    activeAnswerModelID = model.id
                    try await database.setSetting(key: "activeAnswerModelID", value: model.id)
                    modelMessage = "Antwortmodell wurde getestet und aktiviert."
                }
                await refreshModels()
            } catch {
                report(error)
            }
        }
    }

    func testModel(_ model: InstalledModel) {
        Task {
            do {
                guard let directory = await modelManager.installedDirectory(modelID: model.id) else {
                    throw PrivateDocSearchError.processFailed("Das Modell ist nicht installiert.")
                }
                if model.descriptor.kind == .embedding {
                    let provider = MLXEmbeddingProvider(
                        modelID: model.id,
                        modelVersion: model.descriptor.modelVersion,
                        directory: directory
                    )
                    try await provider.test()
                    await provider.unload()
                } else {
                    let generator = MLXAnswerGenerator(
                        directory: directory,
                        contextLength: model.descriptor.defaultContextLength
                    )
                    try await generator.test()
                }
                modelMessage = "Modelltest erfolgreich: \(model.descriptor.displayName)"
            } catch {
                report(error)
            }
        }
    }

    func removeModel(_ model: InstalledModel) {
        Task {
            do {
                if model.descriptor.kind == .answer, activeAnswerModelID == model.id {
                    await unloadAnswerModel(reason: "Modellentfernung")
                    answerGenerator = nil
                    activeAnswerModelID = nil
                }
                if model.descriptor.kind == .embedding, activeEmbeddingModelID == model.id {
                    let fallback = TokenHashEmbedding()
                    processor = makeProcessor(embedder: fallback)
                    searchService = HybridSearchService(database: database, embedder: fallback)
                    activeEmbeddingModelID = nil
                }
                try await modelManager.remove(modelID: model.id)
                modelMessage = "Das Modell wurde in den Papierkorb verschoben."
                await refreshModels()
            } catch {
                report(error)
            }
        }
    }

    func exportLog() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "PrivateDocSearch-Protokoll.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = logEntries.map { date, category, message, path in
            "\(date.formatted()) [\(category)] \(message)\(path.map { " — \($0)" } ?? "")"
        }.joined(separator: "\n")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            report(error)
        }
    }

    private func startScanLoop() {
        scanLoop?.cancel()
        scanLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let seconds = max(1, self.scanIntervalMinutes) * 60
                try? await Task.sleep(for: .seconds(seconds))
                if Task.isCancelled { return }
                await self.scanNow()
            }
        }
    }

    private func configureFolderWatcher(for url: URL) {
        folderWatcher?.stop()
        let watcher = FolderChangeWatcher(url: url) { [weak self] in
            Task { @MainActor in
                self?.scheduleEventScan()
            }
        }
        do {
            try watcher.start()
            folderWatcher = watcher
        } catch {
            report(error)
        }
    }

    private func scheduleEventScan() {
        eventScanTask?.cancel()
        eventScanTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, !self.isProcessing else { return }
            await self.scanNow()
        }
    }

    private func restoreModelSelection() async {
        do {
            if let embeddingID = try await database.setting(key: "activeEmbeddingModelID"),
               let descriptor = await modelManager.descriptor(id: embeddingID),
               let directory = await modelManager.installedDirectory(modelID: embeddingID) {
                let provider = MLXEmbeddingProvider(
                    modelID: embeddingID,
                    modelVersion: descriptor.modelVersion,
                    directory: directory
                )
                try await modelManager.activate(modelID: embeddingID)
                processor = makeProcessor(embedder: provider)
                searchService = HybridSearchService(database: database, embedder: provider)
                activeEmbeddingModelID = embeddingID
            }
            if let answerID = try await database.setting(key: "activeAnswerModelID"),
               let descriptor = await modelManager.descriptor(id: answerID),
               let directory = await modelManager.installedDirectory(modelID: answerID) {
                answerGenerator = MLXAnswerGenerator(
                    directory: directory,
                    contextLength: descriptor.defaultContextLength,
                    idleTimeout: .seconds(llmIdleMinutes * 60)
                )
                try await modelManager.activate(modelID: answerID)
                activeAnswerModelID = answerID
            }
        } catch {
            report(error)
        }
    }

    private func loadSettings() async {
        do {
            if let value = try await database.setting(key: "ocrConfiguration"),
               let data = value.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(OCRConfiguration.self, from: data) {
                ocrConfiguration = decoded
            }
            if let value = try await database.setting(key: "scanIntervalMinutes"),
               let decoded = Int(value) {
                scanIntervalMinutes = min(max(decoded, 1), 1_440)
            }
            if let value = try await database.setting(key: "llmIdleMinutes"),
               let decoded = Int(value) {
                llmIdleMinutes = min(max(decoded, 1), 120)
            }
            showExperimentalModels = try await database.setting(key: "showExperimentalModels") == "1"
            isPaused = try await database.setting(key: "processingPaused") == "1"
            await processor.setPaused(isPaused)
        } catch {
            report(error)
        }
    }

    private func makeProcessor(embedder: any EmbeddingProviding) -> DocumentProcessor {
        return DocumentProcessor(
            database: database,
            embedder: embedder,
            ocrProcessorFactory: {
                OCRProviderRouter(
                    visionProvider: VisionOCRProvider(),
                    tesseractProviderFactory: {
                        OCRmyPDFProcessor(
                            dependencies: OCRDependencyChecker().check(
                                runFunctionalSelfTest: false
                            )
                        )
                    }
                )
            },
            fileLogger: fileLogger
        )
    }

    func ocrRequirementsChanged() {
        ocrInstallationMessage = nil
        guard ocrConfiguration.requiresTesseractComponents else {
            ocrDependencies = .notChecked
            ocrDependenciesChecked = false
            return
        }
        Task {
            await refreshOCRComponents()
        }
    }

    private func startMemoryPressureMonitoring() {
        guard memoryPressureMonitor == nil else { return }

        let monitor = MemoryPressureMonitor { [weak self] level in
            guard let self else { return }
            await self.handleMemoryPressure(level)
        }
        guard monitor.start() else { return }
        memoryPressureMonitor = monitor

        Task {
            try? await fileLogger.log(
                .info,
                category: "Speicherdruck",
                message: "Memory-Pressure-Monitor wurde gestartet."
            )
        }
    }

    private func handleMemoryPressure(_ level: MemoryPressureLevel) async {
        let displayValue: String
        switch level {
        case .critical:
            displayValue = "Kritisch"
        case .warning:
            displayValue = "Erhöht"
        case .normal:
            displayValue = "Normal"
        }
        memoryPressure = displayValue

        try? await fileLogger.log(
            level == .critical ? .warning : .info,
            category: "Speicherdruck",
            message: "Memory-Pressure-Ereignis: \(displayValue)."
        )

        if level == .critical {
            await unloadAnswerModel(reason: "kritischer Speicherdruck")
        }
    }

    private func runMemoryPressureDiagnosticIfRequested() async {
        guard let value = ProcessInfo.processInfo.environment[
            "PRIVATEDOCSEARCH_SIMULATE_MEMORY_PRESSURE"
        ]?.lowercased(),
        let level = MemoryPressureLevel(rawValue: value),
        let memoryPressureMonitor else {
            return
        }

        let ranAwayFromMainThread = await memoryPressureMonitor.simulateForDiagnostics(level)
        try? await fileLogger.log(
            .info,
            category: "Speicherdruck",
            message: "Diagnoseereignis \(level.rawValue) wurde von einer Hintergrund-Queue weitergeleitet: \(ranAwayFromMainThread)."
        )
    }

    private func unloadAnswerModel(reason: String) async {
        guard let answerGenerator else { return }
        try? await fileLogger.log(
            .warning,
            category: "Modelle",
            message: "Antwortmodell wird entladen. Grund: \(reason)."
        )
        await answerGenerator.unload()
        try? await fileLogger.log(
            .info,
            category: "Modelle",
            message: "Antwortmodell wurde entladen. Grund: \(reason)."
        )
    }

    private func report(_ error: Error) {
        let message = error.localizedDescription
        lastError = message
        Task {
            try? await fileLogger.log(
                .error,
                category: "Fehler",
                message: message
            )
            try? await database.recordError(category: "Allgemein", message: message)
            await refreshDatabaseState()
        }
    }
}

struct ContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        NavigationSplitView {
            List(AppSection.allCases, selection: $state.selectedSection) { section in
                Label(section.rawValue, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationTitle("PrivateDocSearch")
            .frame(minWidth: 210)
        } detail: {
            Group {
                switch state.selectedSection ?? .search {
                case .search: SearchView()
                case .status: StatusView()
                case .maintenance: MaintenanceView()
                case .ocr: OCRView()
                case .models: ModelsView()
                case .settings: SettingsView()
                case .logs: LogView()
                }
            }
            .environment(state)
        }
        .alert(
            "PrivateDocSearch",
            isPresented: Binding(
                get: { state.lastError != nil },
                set: { if !$0 { state.lastError = nil } }
            )
        ) {
            Button("OK") { state.lastError = nil }
        } message: {
            Text(state.lastError ?? "")
        }
        .sheet(item: $state.previewSource) { source in
            PDFSourcePreview(source: source)
        }
    }
}

struct SearchView: View {
    @Environment(AppState.self) private var state
    @State private var showPossibleMatches = false
    @State private var showSessionHistory = false

    var body: some View {
        @Bindable var state = state
        VStack(spacing: 0) {
            if !historicalTurns.isEmpty {
                DisclosureGroup(
                    "Sitzungsverlauf (\(historicalTurns.count))",
                    isExpanded: $showSessionHistory
                ) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(historicalTurns) { turn in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("Sie:").font(.caption.bold())
                                    Text(turn.question).lineLimit(2)
                                    Text("PrivateDocSearch:").font(.caption.bold())
                                    Text(plainMarkdown(turn.answer))
                                        .lineLimit(4)
                                        .foregroundStyle(.secondary)
                                    HStack(spacing: 6) {
                                        ForEach(Array(turn.sources.prefix(3).enumerated()), id: \.element.id) {
                                            index, source in
                                            Button("[\(index + 1)] \(source.fileName)") {
                                                state.showPage(source)
                                            }
                                            .buttonStyle(.borderless)
                                            .lineLimit(1)
                                        }
                                    }
                                    .font(.caption2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                    Button("Sitzungsverlauf löschen") {
                        state.clearSearchSession()
                    }
                }
                .padding(.horizontal)
                .padding(.top, 10)
            }

            if state.isProcessing {
                Label(
                    "Lokale Antwortgenerierung wartet, bis OCR und Indexierung beendet oder pausiert sind.",
                    systemImage: "memorychip"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

            if state.submittedQuestion.isEmpty
                && state.answer.isEmpty
                && state.searchResults.isEmpty {
                ContentUnavailableView(
                    "Unterlagen lokal durchsuchen",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(
                        "Stelle eine natürliche Frage. Eindeutige Namen und Nummern werden als Pflichtbedingungen behandelt."
                    )
                )
            } else {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top) {
                            Text("Sie")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            Text(state.submittedQuestion)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .padding(12)
                        .background(.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))

                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Label("PrivateDocSearch", systemImage: "sparkles")
                                    .font(.headline)
                                Spacer()
                                if !state.answer.isEmpty {
                                    Button("Antwort kopieren", systemImage: "doc.on.doc") {
                                        state.copyAnswer()
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                            if state.isSearching && state.answer.isEmpty {
                                HStack(spacing: 10) {
                                    ProgressView()
                                    Text("Antwort wird erstellt …")
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Abbrechen", role: .destructive) {
                                        state.cancelSearch()
                                    }
                                }
                            } else {
                                ScrollView {
                                    Text(markdown(state.answer))
                                        .font(.body)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                }
                                .frame(minHeight: 80, maxHeight: 240)
                                .environment(
                                    \.openURL,
                                    OpenURLAction { url in
                                        guard url.scheme == "privatedocsearch",
                                              url.host == "source",
                                              let number = Int(url.lastPathComponent),
                                              state.searchResults.indices.contains(number - 1) else {
                                            return .systemAction
                                        }
                                        state.showPage(state.searchResults[number - 1])
                                        return .handled
                                    }
                                )
                            }
                            if let notice = state.searchPlanningNotice {
                                Label(notice, systemImage: "shield.checkered")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            if !state.searchResults.isEmpty {
                                HStack(spacing: 8) {
                                    ForEach(Array(state.searchResults.prefix(5).enumerated()), id: \.element.id) {
                                        index, source in
                                        Button("[\(index + 1)] \(source.fileName)") {
                                            state.showPage(source)
                                        }
                                        .buttonStyle(.borderless)
                                        .lineLimit(1)
                                    }
                                }
                                .font(.caption)
                            }
                        }
                        .padding(16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(.blue.opacity(0.25), lineWidth: 1)
                        }
                    }
                    .padding()

                    Divider()

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            if !state.searchResults.isEmpty {
                                HStack {
                                    Text("Direkt passende Dokumente")
                                        .font(.title2.bold())
                                    Text(state.searchResults.count.formatted())
                                        .foregroundStyle(.secondary)
                                }
                                ForEach(
                                    Array(state.searchResults.enumerated()),
                                    id: \.element.id
                                ) { index, source in
                                    SourceCard(number: index + 1, source: source)
                                }
                            } else if !state.isSearching {
                                ContentUnavailableView(
                                    "Keine ausreichend passenden Dokumente gefunden",
                                    systemImage: "doc.text.magnifyingglass"
                                )
                            }

                            if !state.possibleSearchResults.isEmpty {
                                DisclosureGroup(
                                    "Möglicherweise passende Dokumente (\(state.possibleSearchResults.count))",
                                    isExpanded: $showPossibleMatches
                                ) {
                                    LazyVStack(spacing: 12) {
                                        ForEach(state.possibleSearchResults) { source in
                                            SourceCard(number: nil, source: source)
                                        }
                                    }
                                    .padding(.top, 10)
                                }
                            }
                        }
                        .padding()
                    }
                }
            }

            Divider()

            HStack(alignment: .bottom, spacing: 10) {
                TextField(
                    state.searchSession.isEmpty
                        ? "Frage zu deinen Unterlagen …"
                        : "Folgefrage stellen …",
                    text: $state.question,
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .onSubmit { state.submitQuestion() }

                Button {
                    if state.isSearching {
                        state.cancelSearch()
                    } else {
                        state.submitQuestion()
                    }
                } label: {
                    if state.isSearching {
                        Label("Abbrechen", systemImage: "stop.fill")
                    } else {
                        Label("Senden", systemImage: "paperplane.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(state.isSearching ? .red : .accentColor)
                .disabled(
                    (state.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && !state.isSearching)
                        || (state.isProcessing && !state.isSearching)
                )
            }
            .padding()
        }
        .navigationTitle("Suche")
    }

    private func markdown(_ value: String) -> AttributedString {
        var linked = value
        for index in state.searchResults.indices.reversed() {
            linked = linked.replacingOccurrences(
                of: "[\(index + 1)]",
                with: "[\(index + 1)](privatedocsearch://source/\(index + 1))"
            )
        }
        return (try? AttributedString(
            markdown: linked,
            options: .init(interpretedSyntax: .full)
        )) ?? AttributedString(value)
    }

    private func plainMarkdown(_ value: String) -> AttributedString {
        (try? AttributedString(
            markdown: value,
            options: .init(interpretedSyntax: .full)
        )) ?? AttributedString(value)
    }

    private var historicalTurns: [SearchSessionTurn] {
        if state.isSearching {
            return state.searchSession
        }
        if state.searchSession.last?.question == state.submittedQuestion {
            return Array(state.searchSession.dropLast())
        }
        return state.searchSession
    }
}

struct SourceCard: View {
    @Environment(AppState.self) private var state
    let number: Int?
    let source: SearchSource

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(number.map { "\($0). \(source.fileName)" } ?? source.fileName)
                        .font(.headline)
                    Spacer()
                    Text(source.relevance.displayName)
                        .font(.caption.bold())
                        .foregroundStyle(
                            source.relevance == .veryRelevant ? .green : .blue
                        )
                }
                HStack {
                    Text(source.relativePath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Label("Seite \(source.pageNumber)", systemImage: "doc.text")
                        .font(.caption)
                }
                badgeRow
                Text(highlightedExcerpt)
                    .textSelection(.enabled)
                if !source.reason.isEmpty {
                    Label(source.reason, systemImage: "checkmark.seal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Seite anzeigen") { state.showPage(source) }
                    Button("PDF öffnen") { state.open(source) }
                    Button("Im Finder anzeigen") { state.reveal(source) }
                    Spacer()
                    Text(source.absolutePath)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .help(source.absolutePath)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var badgeRow: some View {
        HStack(spacing: 7) {
            if let entity = source.matchedEntities.first {
                SearchBadge(text: "Person: \(entity)", color: .green)
            }
            if let topic = source.matchedTopics.first {
                SearchBadge(text: "Thema: \(topic)", color: .blue)
            }
            SearchBadge(
                text: source.textSource == "ocr" ? "OCR-Text" : "Digitale Textschicht",
                color: .secondary
            )
            if let quality = source.ocrQuality {
                SearchBadge(text: qualityLabel(quality), color: .orange)
            }
            if let kind = source.matchKinds.first {
                SearchBadge(text: kind.displayName, color: .purple)
            }
        }
    }

    private var highlightedExcerpt: AttributedString {
        let attributed = NSMutableAttributedString(string: source.excerpt)
        let terms = source.matchedEntities + source.matchedTopics
        for term in terms {
            guard let expression = try? NSRegularExpression(
                pattern: NSRegularExpression.escapedPattern(for: term),
                options: [.caseInsensitive]
            ) else { continue }
            let range = NSRange(location: 0, length: attributed.length)
            for match in expression.matches(in: source.excerpt, range: range) {
                attributed.addAttributes(
                    [
                        .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize),
                        .backgroundColor: NSColor.systemYellow.withAlphaComponent(0.22)
                    ],
                    range: match.range
                )
            }
        }
        return AttributedString(attributed)
    }

    private func qualityLabel(_ value: String) -> String {
        switch OCRQualityStatus(rawValue: value) {
        case .good: "OCR gut"
        case .review: "OCR prüfen"
        case .likelyFailed: "OCR schwach"
        case nil: "OCR"
        }
    }
}

struct SearchBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.10), in: Capsule())
    }
}

struct PDFSourcePreview: View {
    @Environment(\.dismiss) private var dismiss
    let source: SearchSource

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text(source.fileName).font(.headline)
                    Text("Seite \(source.pageNumber) · \(source.absolutePath)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Schließen") { dismiss() }
            }
            .padding()
            Divider()
            PDFKitView(url: URL(filePath: source.absolutePath), pageNumber: source.pageNumber)
        }
        .frame(minWidth: 760, minHeight: 700)
    }
}

struct PDFKitView: NSViewRepresentable {
    let url: URL
    let pageNumber: Int

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        configure(view)
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: PDFView) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
        if let page = view.document?.page(at: max(0, pageNumber - 1)) {
            view.go(to: page)
        }
    }
}

struct StatusView: View {
    @Environment(AppState.self) private var state
    @State private var showsTechnicalDetails = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Dokumentenordner").font(.headline)
                        Text(state.documentFolderPath ?? "Nicht ausgewählt")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Label(state.folderStatus, systemImage: state.folderStatus == "Erreichbar" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(state.folderStatus == "Erreichbar" ? .green : .orange)
                    }
                    Spacer()
                    Button("Ordner auswählen …") { state.chooseFolder() }
                }
                .padding()
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], spacing: 12) {
                    ForEach(DocumentStatusPrimaryMetric.allCases) { metric in
                        MetricCard(
                            title: metric.displayName,
                            value: metric.value(in: state.statistics)
                        )
                    }
                }

                if state.isProcessing
                    || state.statistics.processingJobs > 0
                    || state.statistics.isPaused {
                    GroupBox(
                        state.statistics.isPaused
                            ? "Verarbeitung pausiert"
                            : state.statistics.processingJobs > 0
                                ? "Verarbeitung läuft"
                                : "Dokumentenverarbeitung"
                    ) {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: state.statistics.progressFraction)
                            HStack {
                                Text(
                                    "\(state.statistics.processedJobs) von \(state.statistics.totalJobs) PDFs verarbeitet"
                                )
                                Spacer()
                                Text(
                                    state.statistics.progressFraction,
                                    format: .percent.precision(.fractionLength(0))
                                )
                                .monospacedDigit()
                            }
                            Text("Aktuell:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(state.statistics.currentFile ?? "Ordner wird gescannt …")
                                .font(.headline)
                        }
                    }
                }

                DisclosureGroup(
                    "Technische Details",
                    isExpanded: $showsTechnicalDetails
                ) {
                    VStack(alignment: .leading, spacing: 14) {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 170))],
                            spacing: 10
                        ) {
                            MetricCard(title: "Mit Textschicht", value: state.statistics.searchablePDFs)
                            MetricCard(title: "Ohne Textschicht", value: state.statistics.withoutTextLayerPDFs)
                            MetricCard(title: "OCR erforderlich", value: state.statistics.ocrRequiredPDFs)
                            MetricCard(title: "OCR erfolgreich", value: state.statistics.ocrProcessedPDFs)
                            MetricCard(title: "OCR fehlgeschlagen", value: state.statistics.ocrFailedPDFs)
                            MetricCard(title: "In Bearbeitung", value: state.statistics.processingJobs)
                            MetricCard(title: "Pausiert", value: state.statistics.pausedJobs)
                            MetricCard(title: "Übersprungen", value: state.statistics.skippedJobs)
                            MetricCard(title: "Technische Fehler", value: state.statistics.failedJobs)
                            MetricCard(title: "Chunks", value: state.statistics.totalChunks)
                            MetricCard(title: "Embeddings", value: state.statistics.embeddedChunks)
                            MetricCard(title: "Fallback-Embeddings", value: state.statistics.fallbackEmbeddedChunks)
                            MetricCard(title: "E5-Embeddings", value: state.statistics.e5EmbeddedChunks)
                            MetricCard(title: "Fehlende Dateien", value: state.statistics.missingOrMovedFiles)
                            MetricCard(title: "OCR-Seiten gut", value: state.statistics.ocrQualityGoodPages)
                            MetricCard(title: "OCR überprüfen", value: state.statistics.ocrQualityReviewPages)
                            MetricCard(title: "Zu prüfende Seiten", value: state.statistics.emptyPageCandidates)
                            MetricCard(title: "Vollständig leere PDFs", value: state.statistics.fullyEmptyPDFs)
                        }
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                            GridRow {
                                Text("OCR-Engine").foregroundStyle(.secondary)
                                Text(state.statistics.currentOCREngine ?? "—")
                            }
                            GridRow {
                                Text("Embedding-Modell").foregroundStyle(.secondary)
                                Text(state.activeEmbeddingModelID ?? "Fallback (nicht neuronal)")
                            }
                            GridRow {
                                Text("Embedding-Version").foregroundStyle(.secondary)
                                Text(state.activeEmbeddingModelVersion ?? "Integriert")
                            }
                            GridRow {
                                Text("Indexzustand").foregroundStyle(.secondary)
                                Text(state.hasMixedEmbeddingIndex ? "Gemischte Embeddings" : "Konsistent")
                                    .foregroundStyle(state.hasMixedEmbeddingIndex ? .orange : .primary)
                            }
                            GridRow {
                                Text("Letzter Erfolg").foregroundStyle(.secondary)
                                Text(state.statistics.lastSuccessfulStep ?? "—")
                            }
                            GridRow {
                                Text("Letzter Fehler").foregroundStyle(.secondary)
                                Text(state.statistics.lastProcessingError ?? "—")
                                    .lineLimit(3)
                            }
                        }
                        if state.hasMixedEmbeddingIndex {
                            Label(
                                "E5- und Fallback-Vektoren sind gleichzeitig vorhanden. Die Suche verwendet nur das aktive Modell.",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .foregroundStyle(.orange)
                            Button("Embeddings neu erzeugen") {
                                state.rebuildSearchIndex()
                            }
                            .disabled(state.isProcessing)
                        }
                    }
                    .padding(.top, 10)
                }
                .padding()
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))

                HStack {
                    Button("Jetzt scannen") { Task { await state.scanNow() } }
                        .disabled(state.documentFolderPath == nil || state.isProcessing)
                    Button(state.isPaused ? "Fortsetzen" : "Pausieren") {
                        state.setPaused(!state.isPaused)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Dokumentenstatus")
    }
}

struct MetricCard: View {
    let title: String
    let value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).foregroundStyle(.secondary)
            Text(value.formatted()).font(.title.bold())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

private enum MaintenanceSection: String, CaseIterable, Identifiable {
    case duplicates = "Duplikate"
    case emptyPages = "Leere Seiten"
    case emptyPDFs = "Leere PDFs"
    case missingFiles = "Fehlende Dateien"
    case index = "Index und Embeddings"

    var id: Self { self }
}

private enum MaintenanceSort: String, CaseIterable, Identifiable {
    case fileName = "Dateiname"
    case path = "Pfad"
    case confidence = "Sicherheit"

    var id: Self { self }
}

struct MaintenanceView: View {
    @Environment(AppState.self) private var state
    @State private var section: MaintenanceSection = .duplicates
    @State private var filter = ""
    @State private var sort: MaintenanceSort = .fileName
    @State private var selectedDuplicatePaths: Set<String> = []
    @State private var selectedPageIDs: Set<String> = []
    @State private var selectedEmptyPDFPaths: Set<String> = []
    @State private var confirmsDuplicateTrash = false
    @State private var confirmsPageRemoval = false
    @State private var confirmsEmptyPDFTrash = false
    @State private var confirmsIndexReset = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Wartungsbereich", selection: $section) {
                    ForEach(MaintenanceSection.allCases) {
                        Text($0.rawValue).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                TextField("Liste durchsuchen", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                Picker("Sortierung", selection: $sort) {
                    ForEach(MaintenanceSort.allCases) {
                        Text($0.rawValue).tag($0)
                    }
                }
                .frame(width: 150)
                Button("Aktualisieren") {
                    Task { await state.refreshMaintenance() }
                }
            }
            .padding()

            Divider()

            if state.isMaintainingDocuments {
                ProgressView(state.maintenanceMessage ?? "Dokumentenwartung läuft …")
                    .padding()
            } else if let message = state.maintenanceMessage {
                Label(message, systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }

            Group {
                switch section {
                case .duplicates:
                    duplicateList
                case .emptyPages:
                    emptyPageList
                case .emptyPDFs:
                    emptyPDFList
                case .missingFiles:
                    missingFilesView
                case .index:
                    indexView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Dokumentenwartung")
        .task { await state.refreshMaintenance() }
        .confirmationDialog(
            "Ausgewählte Duplikate in den Papierkorb verschieben?",
            isPresented: $confirmsDuplicateTrash
        ) {
            Button("In den Papierkorb", role: .destructive) {
                state.trashDuplicateLocations(selectedDuplicateLocations)
                selectedDuplicatePaths.removeAll()
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text(
                "Nur byteidentische SHA-256-Duplikate werden verschoben. Je Gruppe muss mindestens eine Datei erhalten bleiben."
            )
        }
        .confirmationDialog(
            "Bestätigte leere Seiten entfernen?",
            isPresented: $confirmsPageRemoval
        ) {
            Button("Neue PDF erzeugen und austauschen", role: .destructive) {
                state.removeConfirmedEmptyPages(selectedEmptyPages)
                selectedPageIDs.removeAll()
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text(
                "Die PDF wird neu erzeugt und vollständig validiert. Die ursprüngliche Fassung wird nach dem atomaren Austausch in den Papierkorb verschoben."
            )
        }
        .confirmationDialog(
            "Vollständig leere PDFs in den Papierkorb verschieben?",
            isPresented: $confirmsEmptyPDFTrash
        ) {
            Button("In den Papierkorb", role: .destructive) {
                state.trashEmptyPDFs(selectedEmptyPDFs)
                selectedEmptyPDFPaths.removeAll()
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Die Dateien werden niemals endgültig gelöscht.")
        }
        .confirmationDialog(
            "Dokumentindex zurücksetzen?",
            isPresented: $confirmsIndexReset
        ) {
            Button("Index zurücksetzen", role: .destructive) {
                state.deleteDocumentIndex()
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("PDF-Dateien und Modelle bleiben unverändert.")
        }
    }

    private var duplicateList: some View {
        VStack(spacing: 0) {
            List {
                if filteredDuplicateGroups.isEmpty {
                    ContentUnavailableView(
                        "Keine SHA-256-Duplikate",
                        systemImage: "doc.on.doc"
                    )
                }
                ForEach(filteredDuplicateGroups) { group in
                    Section {
                        ForEach(sorted(group.locations)) { location in
                            HStack(alignment: .top, spacing: 12) {
                                Toggle(
                                    "Entfernen",
                                    isOn: selectionBinding(
                                        location.absolutePath,
                                        in: $selectedDuplicatePaths
                                    )
                                )
                                .labelsHidden()
                                MaintenanceThumbnail(
                                    path: location.absolutePath,
                                    pageNumber: 1
                                )
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(location.fileName).font(.headline)
                                        if group.recommendedLocation == location {
                                            Text("Empfohlen behalten")
                                                .font(.caption2.bold())
                                                .foregroundStyle(.green)
                                        }
                                    }
                                    Text(location.relativePath)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(location.absolutePath)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                    Text(
                                        "\(ByteCountFormatter.string(fromByteCount: location.fileSize, countStyle: .file)) · \(location.modifiedAt.formatted())"
                                    )
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    HStack {
                                        Button("Vorschau") {
                                            state.previewMaintenanceFile(
                                                path: location.absolutePath,
                                                fileName: location.fileName,
                                                relativePath: location.relativePath
                                            )
                                        }
                                        Button("Diese Datei behalten") {
                                            selectedDuplicatePaths.remove(
                                                location.absolutePath
                                            )
                                        }
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(group.locations.count) identische Dateien")
                            Text("SHA-256 \(group.contentHash)")
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            maintenanceActionBar(
                selectionCount: selectedDuplicatePaths.count,
                title: "Ausgewählte Duplikate in den Papierkorb",
                enabled: duplicateSelectionIsSafe
            ) {
                confirmsDuplicateTrash = true
            } reset: {
                selectedDuplicatePaths.removeAll()
            }
        }
    }

    private var emptyPageList: some View {
        VStack(spacing: 0) {
            List {
                if filteredEmptyPages.isEmpty {
                    ContentUnavailableView(
                        "Keine zu prüfenden Seiten",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text(
                            "Neue PDFs werden während der normalen Verarbeitung analysiert."
                        )
                    )
                }
                ForEach(filteredEmptyPages) { candidate in
                    HStack(alignment: .top, spacing: 12) {
                        Toggle(
                            "Auswählen",
                            isOn: selectionBinding(
                                candidate.id,
                                in: $selectedPageIDs
                            )
                        )
                        .labelsHidden()
                        .disabled(
                            candidate.decision != .confirmedEmpty
                                || !candidate.status.isEmptyCandidate
                        )
                        MaintenanceThumbnail(
                            path: candidate.absolutePath,
                            pageNumber: candidate.pageNumber
                        )
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(candidate.fileName).font(.headline)
                                Text("Seite \(candidate.pageNumber)")
                                Spacer()
                                Text(candidate.status.displayName)
                                    .font(.caption.bold())
                                    .foregroundStyle(
                                        candidate.status.isEmptyCandidate
                                            ? .orange
                                            : .blue
                                    )
                            }
                            Text(candidate.relativePath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(candidate.absolutePath)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Text(
                                "\(candidate.confidence, format: .percent.precision(.fractionLength(1))) Sicherheit · \(candidate.metrics.whiteRatio, format: .percent.precision(.fractionLength(2))) Weißfläche"
                            )
                            .font(.caption)
                            Text(candidate.reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(
                                "Dunkle Pixel \(candidate.metrics.darkPixelRatio, format: .percent.precision(.fractionLength(3))) · Kanten \(candidate.metrics.edgeRatio, format: .percent.precision(.fractionLength(3))) · Varianz \(candidate.metrics.variance.formatted(.number.precision(.fractionLength(5)))) · Bilder \(candidate.metrics.embeddedImageCount) · Annotationen \(candidate.metrics.annotationCount)"
                            )
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            HStack {
                                Button("Vorschau") {
                                    preview(candidate)
                                }
                                Button("In PDF öffnen") {
                                    preview(candidate)
                                }
                                Button("Als leer bestätigen") {
                                    state.setPageDecision(
                                        candidate,
                                        decision: .confirmedEmpty
                                    )
                                }
                                .disabled(!candidate.status.isEmptyCandidate)
                                Button("Nicht leer") {
                                    selectedPageIDs.remove(candidate.id)
                                    state.setPageDecision(
                                        candidate,
                                        decision: .notEmpty
                                    )
                                }
                                Button("Ausschließen") {
                                    selectedPageIDs.remove(candidate.id)
                                    state.setPageDecision(
                                        candidate,
                                        decision: .excluded
                                    )
                                }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .padding(.vertical, 5)
                }
            }
            maintenanceActionBar(
                selectionCount: selectedPageIDs.count,
                title: "Ausgewählte Seiten entfernen",
                enabled: !selectedEmptyPages.isEmpty
            ) {
                confirmsPageRemoval = true
            } reset: {
                selectedPageIDs.removeAll()
            }
        }
    }

    private var emptyPDFList: some View {
        VStack(spacing: 0) {
            List {
                if filteredEmptyPDFs.isEmpty {
                    ContentUnavailableView(
                        "Keine vollständig leeren PDFs",
                        systemImage: "doc"
                    )
                }
                ForEach(filteredEmptyPDFs) { candidate in
                    HStack(spacing: 12) {
                        Toggle(
                            "Auswählen",
                            isOn: selectionBinding(
                                candidate.absolutePath,
                                in: $selectedEmptyPDFPaths
                            )
                        )
                        .labelsHidden()
                        MaintenanceThumbnail(
                            path: candidate.absolutePath,
                            pageNumber: 1
                        )
                        VStack(alignment: .leading, spacing: 4) {
                            Text(candidate.fileName).font(.headline)
                            Text(candidate.relativePath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(candidate.absolutePath)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Text(
                                "\(candidate.pageCount) vollständig analysierte leere Seite(n) · \(candidate.confidence, format: .percent.precision(.fractionLength(1))) Sicherheit"
                            )
                            .font(.caption)
                            Button("Vorschau") {
                                state.previewMaintenanceFile(
                                    path: candidate.absolutePath,
                                    fileName: candidate.fileName,
                                    relativePath: candidate.relativePath
                                )
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
            maintenanceActionBar(
                selectionCount: selectedEmptyPDFPaths.count,
                title: "Ausgewählte PDFs in den Papierkorb",
                enabled: !selectedEmptyPDFs.isEmpty
            ) {
                confirmsEmptyPDFTrash = true
            } reset: {
                selectedEmptyPDFPaths.removeAll()
            }
        }
    }

    private var missingFilesView: some View {
        ContentUnavailableView {
            Label("Fehlende Dateien", systemImage: "questionmark.folder")
        } description: {
            Text(
                "\(state.statistics.missingOrMovedFiles) Datei(en) fehlen oder wurden verschoben. Ein Scan gleicht Pfade und Suchindex gezielt ab."
            )
        } actions: {
            Button("Jetzt prüfen") {
                Task { await state.scanNow() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(state.documentFolderPath == nil || state.isProcessing)
        }
    }

    private var indexView: some View {
        Form {
            Section("Leerseitenanalyse") {
                Button("Fehlende Analysen ergänzen") {
                    state.analyzeMissingPages()
                }
                Text(
                    "Analysiert nur bisher nicht geprüfte PDFs und startet keine zusätzliche OCR."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Section("Embeddings") {
                Button("Embeddings neu erzeugen") {
                    state.rebuildSearchIndex()
                }
                Text(
                    "Erzeugt Chunks und Embeddings ausschließlich aus dem bereits gespeicherten Text neu."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Section("Index zurücksetzen") {
                Button("Dokumentindex zurücksetzen …", role: .destructive) {
                    confirmsIndexReset = true
                }
                Text("PDF-Dateien werden weder verändert noch verschoben.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func maintenanceActionBar(
        selectionCount: Int,
        title: String,
        enabled: Bool,
        action: @escaping () -> Void,
        reset: @escaping () -> Void
    ) -> some View {
        HStack {
            Text("\(selectionCount) ausgewählt")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Auswahl zurücksetzen", action: reset)
                .disabled(selectionCount == 0)
            Button(title, role: .destructive, action: action)
                .disabled(
                    !enabled
                        || state.isMaintainingDocuments
                        || state.isProcessing
                )
        }
        .padding()
        .background(.bar)
    }

    private var filteredDuplicateGroups: [DuplicateGroup] {
        let query = normalizedFilter
        let values = query.isEmpty ? state.duplicateGroups : state.duplicateGroups.filter {
            $0.contentHash.localizedCaseInsensitiveContains(query)
                || $0.locations.contains {
                    $0.fileName.localizedCaseInsensitiveContains(query)
                        || $0.relativePath.localizedCaseInsensitiveContains(query)
                }
        }
        return values.sorted {
            ($0.recommendedLocation?.fileName ?? $0.contentHash)
                .localizedStandardCompare(
                    $1.recommendedLocation?.fileName ?? $1.contentHash
                ) == .orderedAscending
        }
    }

    private var filteredEmptyPages: [EmptyPageCandidate] {
        let values = state.emptyPageCandidates.filter(matchesFilter)
        switch sort {
        case .fileName:
            return values.sorted {
                $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
            }
        case .path:
            return values.sorted {
                $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            }
        case .confidence:
            return values.sorted { $0.confidence > $1.confidence }
        }
    }

    private var filteredEmptyPDFs: [EmptyPDFCandidate] {
        let values = state.emptyPDFCandidates.filter {
            normalizedFilter.isEmpty
                || $0.fileName.localizedCaseInsensitiveContains(normalizedFilter)
                || $0.relativePath.localizedCaseInsensitiveContains(normalizedFilter)
        }
        switch sort {
        case .fileName:
            return values.sorted {
                $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
            }
        case .path:
            return values.sorted {
                $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            }
        case .confidence:
            return values.sorted { $0.confidence > $1.confidence }
        }
    }

    private var selectedDuplicateLocations: [DuplicateLocation] {
        state.duplicateGroups.flatMap(\.locations).filter {
            selectedDuplicatePaths.contains($0.absolutePath)
        }
    }

    private var duplicateSelectionIsSafe: Bool {
        guard !selectedDuplicatePaths.isEmpty else { return false }
        return state.duplicateGroups.allSatisfy { group in
            let selected = group.locations.filter {
                selectedDuplicatePaths.contains($0.absolutePath)
            }.count
            return selected < group.locations.count
        }
    }

    private var selectedEmptyPages: [EmptyPageCandidate] {
        state.emptyPageCandidates.filter {
            selectedPageIDs.contains($0.id)
                && $0.decision == .confirmedEmpty
                && $0.status.isEmptyCandidate
        }
    }

    private var selectedEmptyPDFs: [EmptyPDFCandidate] {
        state.emptyPDFCandidates.filter {
            selectedEmptyPDFPaths.contains($0.absolutePath)
        }
    }

    private var normalizedFilter: String {
        filter.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func matchesFilter(_ candidate: EmptyPageCandidate) -> Bool {
        normalizedFilter.isEmpty
            || candidate.fileName.localizedCaseInsensitiveContains(normalizedFilter)
            || candidate.relativePath.localizedCaseInsensitiveContains(normalizedFilter)
            || candidate.status.displayName.localizedCaseInsensitiveContains(normalizedFilter)
    }

    private func sorted(_ locations: [DuplicateLocation]) -> [DuplicateLocation] {
        switch sort {
        case .fileName:
            locations.sorted {
                $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
            }
        case .path:
            locations.sorted {
                $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            }
        case .confidence:
            locations.sorted { $0.modifiedAt < $1.modifiedAt }
        }
    }

    private func preview(_ candidate: EmptyPageCandidate) {
        state.previewMaintenanceFile(
            path: candidate.absolutePath,
            fileName: candidate.fileName,
            relativePath: candidate.relativePath,
            pageNumber: candidate.pageNumber
        )
    }

    private func selectionBinding(
        _ id: String,
        in selection: Binding<Set<String>>
    ) -> Binding<Bool> {
        Binding(
            get: { selection.wrappedValue.contains(id) },
            set: { enabled in
                if enabled {
                    selection.wrappedValue.insert(id)
                } else {
                    selection.wrappedValue.remove(id)
                }
            }
        )
    }
}

private struct MaintenanceThumbnail: View {
    let path: String
    let pageNumber: Int
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "doc")
                    .font(.title)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 58, height: 78)
        .background(.white, in: RoundedRectangle(cornerRadius: 4))
        .overlay {
            RoundedRectangle(cornerRadius: 4).stroke(.quaternary)
        }
        .task(id: "\(path)#\(pageNumber)") {
            guard let document = PDFDocument(url: URL(filePath: path)),
                  let page = document.page(at: max(0, pageNumber - 1)) else {
                image = nil
                return
            }
            image = page.thumbnail(
                of: NSSize(width: 116, height: 156),
                for: .mediaBox
            )
        }
    }
}

struct OCRView: View {
    @Environment(AppState.self) private var state
    @State private var confirmsInstallation = false

    var body: some View {
        @Bindable var state = state
        Form {
            Section("OCR-Engine") {
                Picker("OCR-Engine", selection: $state.ocrConfiguration.engineSelection) {
                    ForEach(OCREngineSelection.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                .pickerStyle(.radioGroup)
                LabeledContent(
                    "Apple Vision",
                    value: VisionOCRProvider.isAvailable ? "Verfügbar" : "Nicht verfügbar"
                )
                Text(
                    state.ocrConfiguration.engineSelection == .automatic
                        ? "Apple Vision wird auf macOS bevorzugt. Nur wenn Vision fehlschlägt, versucht die App automatisch Tesseract."
                        : state.ocrConfiguration.engineSelection == .appleVision
                            ? "Apple Vision arbeitet vollständig lokal und benötigt weder Homebrew noch externe OCR-Komponenten."
                            : "OCRmyPDF und Tesseract werden über zentral aufgelöste lokale Werkzeuge ausgeführt."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if state.ocrConfiguration.requiresTesseractComponents {
                Section("Tesseract-Komponenten") {
                    componentRow("OCRmyPDF", available: state.ocrDependencies.ocrMyPDF != nil)
                    componentRow("Tesseract", available: state.ocrDependencies.tesseract != nil)
                    componentRow(
                        "Deutsche Sprachdaten",
                        available: state.ocrDependencies.installedLanguages.contains("deu")
                    )
                    componentRow(
                        "Poppler",
                        available: state.ocrDependencies.pdfInfo != nil
                            && state.ocrDependencies.pdfText != nil
                    )
                    LabeledContent(
                        "Verfügbarkeit",
                        value: state.ocrDependenciesChecked
                            ? state.ocrDependencies.isReady ? "Bereit" : "Unvollständig"
                            : "Noch nicht geprüft"
                    )
                    ForEach(state.ocrDependencies.messages, id: \.self) {
                        Text($0).foregroundStyle(.orange)
                    }
                    if state.ocrDependenciesChecked,
                       state.ocrDependencies.homebrew != nil,
                       !state.ocrDependencies.isReady {
                        Button("Fehlende Komponenten installieren") {
                            confirmsInstallation = true
                        }
                        .disabled(state.isInstallingOCRComponents)
                    } else if state.ocrDependenciesChecked,
                              state.ocrDependencies.homebrew == nil {
                        Text("Homebrew fehlt. Installiere es zuerst nach der offiziellen Anleitung von brew.sh.")
                            .foregroundStyle(.secondary)
                        Button("Offiziellen Installationsbefehl kopieren") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"",
                                forType: .string
                            )
                        }
                    }
                    if let message = state.ocrInstallationMessage {
                        Text(message).foregroundStyle(.secondary)
                    }
                    Button("Erneut prüfen") {
                        Task { await state.refreshOCRComponents() }
                    }
                }
            }
            Section("Verarbeitung") {
                Toggle("OCR aktiviert", isOn: $state.ocrConfiguration.isEnabled)
                Picker("Speichermodus", selection: $state.ocrConfiguration.persistenceMode) {
                    ForEach(OCRPersistenceMode.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                Text(
                    state.ocrConfiguration.persistenceMode == .nonDestructive
                        ? "Das Original bleibt unverändert. OCR-Text, Seiten- und Qualitätsdaten werden lokal in SQLite gespeichert."
                        : "Die validierte OCR-Ausgabe ersetzt die PDF atomar. Bei einem Fehler bleibt das Original unverändert."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if state.ocrConfiguration.persistenceMode == .persistent,
                   state.ocrConfiguration.engineSelection != .tesseractOCRmyPDF {
                    Text("Für dauerhaft durchsuchbare PDFs wird automatisch OCRmyPDF verwendet.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    if !state.ocrDependencies.isReady {
                        Button("Jetzt installieren") {
                            confirmsInstallation = true
                        }
                        .disabled(state.isInstallingOCRComponents)
                    }
                }
                Toggle("Seiten automatisch drehen", isOn: $state.ocrConfiguration.rotatePages)
                Toggle("Seiten begradigen", isOn: $state.ocrConfiguration.deskew)
                Toggle("Bild vor OCR bereinigen", isOn: $state.ocrConfiguration.clean)
                Toggle("PDF/A erzeugen", isOn: $state.ocrConfiguration.createPDFA)
                Picker("CPU-Modus", selection: $state.ocrConfiguration.cpuMode) {
                    ForEach(OCRCPUMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Text("Sparsam verarbeitet jeweils eine Datei. Normal nutzt die gewählte Parallelität. Schnell nutzt höchstens die Hälfte der CPU-Kerne und benötigt mehr Arbeitsspeicher.")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper("Optimierung: \(state.ocrConfiguration.optimizeLevel)", value: $state.ocrConfiguration.optimizeLevel, in: 0...3)
                Text("0 bewahrt die Bilddaten weitgehend. Höhere Stufen verkleinern die Ausgabedatei, benötigen aber mehr CPU und können Bilder neu komprimieren; die Texterkennung wird dadurch nicht besser.")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper(
                    "Maximale Parallelität: \(state.ocrConfiguration.maximumParallelFiles)",
                    value: $state.ocrConfiguration.maximumParallelFiles,
                    in: 1...4
                )
                Text("Auf Macs mit 8 GB ist 1 empfohlen. Mehr parallele Dateien erhöhen Tempo und Speicherbedarf, nicht die OCR-Qualität.")
                    .font(.caption).foregroundStyle(.secondary)
                Menu("Sprachen: \(state.ocrConfiguration.languages.joined(separator: " + "))") {
                    ForEach(availableLanguages, id: \.self) { language in
                        Button {
                            toggleLanguage(language)
                        } label: {
                            if state.ocrConfiguration.languages.contains(language) {
                                Label(language, systemImage: "checkmark")
                            } else {
                                Text(language)
                            }
                        }
                    }
                }
                Button("Fehler erneut versuchen") {
                    state.retryFailedJobs()
                }
                Button("OCR-Einstellungen speichern") {
                    state.saveSettings()
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("OCR")
        .onChange(of: state.ocrConfiguration.engineSelection) {
            state.ocrRequirementsChanged()
        }
        .onChange(of: state.ocrConfiguration.persistenceMode) {
            state.ocrRequirementsChanged()
        }
        .confirmationDialog(
            "OCR-Komponenten mit Homebrew installieren?",
            isPresented: $confirmsInstallation
        ) {
            Button("ocrmypdf, tesseract-lang und poppler installieren") {
                state.installMissingOCRComponents()
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Homebrew wird ohne sudo und ausschließlich mit festen Paketnamen aufgerufen.")
        }
    }

    @ViewBuilder
    private func componentRow(_ name: String, available: Bool) -> some View {
        Label(name, systemImage: available ? "checkmark.circle.fill" : "xmark.circle.fill")
            .foregroundStyle(available ? .green : .red)
    }

    private func toggleLanguage(_ language: String) {
        if let index = state.ocrConfiguration.languages.firstIndex(of: language) {
            guard state.ocrConfiguration.languages.count > 1 else { return }
            state.ocrConfiguration.languages.remove(at: index)
        } else {
            state.ocrConfiguration.languages.append(language)
            state.ocrConfiguration.languages.sort()
        }
    }

    private var availableLanguages: [String] {
        Array(Set(["deu", "eng"] + state.ocrDependencies.installedLanguages)).sorted()
    }
}

struct ModelsView: View {
    @Environment(AppState.self) private var state
    @State private var pendingEmbeddingActivation: InstalledModel?
    @State private var pendingEmbeddingUpdate: InstalledModel?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Dieser Mac") {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                        GridRow {
                            Text("Chip").foregroundStyle(.secondary)
                            Text(state.hardwareProfile.chipName)
                        }
                        GridRow {
                            Text("Unified Memory").foregroundStyle(.secondary)
                            Text(ByteCountFormatter.string(
                                fromByteCount: Int64(state.hardwareProfile.physicalMemoryBytes),
                                countStyle: .memory
                            ))
                        }
                        GridRow {
                            Text("Freier Speicher").foregroundStyle(.secondary)
                            Text(ByteCountFormatter.string(
                                fromByteCount: state.hardwareProfile.availableStorageBytes,
                                countStyle: .file
                            ))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let message = state.modelMessage {
                    Label(message, systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                }

                if let progress = state.modelDownloadProgress {
                    GroupBox("Modelldownload") {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: progress.fraction)
                            Text(progress.currentFile)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack {
                                Text(
                                    "\(ByteCountFormatter.string(fromByteCount: progress.downloadedBytes, countStyle: .file)) von \(ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file))"
                                )
                                Spacer()
                                Button("Pausieren") {
                                    state.pauseModelDownload()
                                }
                                Button("Abbrechen", role: .destructive) {
                                    state.cancelModelDownload()
                                }
                            }
                        }
                    }
                }

                Text("Embedding-Modell")
                    .font(.title2.bold())
                ForEach(visibleModels(kind: .embedding)) { model in
                    modelCard(model)
                }

                Text("Antwortmodelle")
                    .font(.title2.bold())
                ForEach(visibleModels(kind: .answer)) { model in
                    modelCard(model)
                }
            }
            .padding()
        }
        .navigationTitle("Modelle")
        .alert(
            "Index neu aufbauen?",
            isPresented: Binding(
                get: { pendingEmbeddingActivation != nil },
                set: { if !$0 { pendingEmbeddingActivation = nil } }
            ),
            presenting: pendingEmbeddingActivation
        ) { model in
            Button("Aktivieren und neu aufbauen") {
                state.activateModel(model)
                pendingEmbeddingActivation = nil
            }
            Button("Abbrechen", role: .cancel) {
                pendingEmbeddingActivation = nil
            }
        } message: { model in
            Text(
                "Beim Wechsel zu \(model.descriptor.displayName) müssen alle Dokument-Chunks neu eingebettet werden. Der bisherige Index bleibt bis zum erfolgreichen Aufbau erhalten."
            )
        }
        .confirmationDialog(
            "Embedding-Modell aktualisieren?",
            isPresented: Binding(
                get: { pendingEmbeddingUpdate != nil },
                set: { if !$0 { pendingEmbeddingUpdate = nil } }
            ),
            presenting: pendingEmbeddingUpdate
        ) { model in
            Button("Aktualisieren und Index neu aufbauen") {
                state.installModel(model, activateAfterInstall: true)
                pendingEmbeddingUpdate = nil
            }
            Button("Abbrechen", role: .cancel) { pendingEmbeddingUpdate = nil }
        } message: { model in
            Text("Die neue Version wird vollständig geladen und geprüft. Erst danach wird der Index aus gespeichertem Text neu aufgebaut; bei Fehler bleibt die alte Version erhalten.")
        }
    }

    private func visibleModels(kind: ModelKind) -> [InstalledModel] {
        state.availableModels.filter {
            $0.descriptor.kind == kind
                && ($0.compatibility != .experimental || state.showExperimentalModels)
        }
    }

    @ViewBuilder
    private func modelCard(_ model: InstalledModel) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.descriptor.displayName).font(.headline)
                        Text("\(model.descriptor.family) · \(model.descriptor.parameters) · \(model.descriptor.quantization)")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    compatibilityBadge(model.compatibility)
                    if model.isActive {
                        Text("Aktiv")
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.green.opacity(0.18), in: Capsule())
                    }
                }

                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 4) {
                    GridRow {
                        Text("Download").foregroundStyle(.secondary)
                        Text(ByteCountFormatter.string(
                            fromByteCount: model.descriptor.downloadSizeBytes,
                            countStyle: .file
                        ))
                        Text("RAM geschätzt").foregroundStyle(.secondary)
                        Text(ByteCountFormatter.string(
                            fromByteCount: model.descriptor.estimatedRuntimeRAMBytes,
                            countStyle: .memory
                        ))
                    }
                    GridRow {
                        Text("Kontext").foregroundStyle(.secondary)
                        Text(model.descriptor.defaultContextLength.formatted())
                        Text("Version").foregroundStyle(.secondary)
                        Text(String(model.descriptor.modelVersion.prefix(10)))
                            .monospaced()
                    }
                    if let installedVersion = model.installedVersion {
                        GridRow {
                            Text("Installiert").foregroundStyle(.secondary)
                            Text(String(installedVersion.prefix(10))).monospaced()
                            Text("SHA-256").foregroundStyle(.secondary)
                            Text(String(model.descriptor.checksumSHA256.prefix(12))).monospaced()
                        }
                    }
                }

                HStack {
                    Link("Lizenz: \(model.descriptor.licenseName)", destination: model.descriptor.licenseURL)
                    Spacer()
                    if model.updateAvailable {
                        Button("Modell aktualisieren") {
                            if model.descriptor.kind == .embedding {
                                pendingEmbeddingUpdate = model
                            } else {
                                state.installModel(model, activateAfterInstall: true)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            state.downloadingModelID != nil
                                || model.compatibility == .incompatible
                        )
                    } else if model.isInstalled {
                        Button("Testen") { state.testModel(model) }
                        Button(model.isActive ? "Aktiv" : "Aktivieren") {
                            if model.descriptor.kind == .embedding {
                                pendingEmbeddingActivation = model
                            } else {
                                state.activateModel(model)
                            }
                        }
                        .disabled(model.isActive)
                        .buttonStyle(.borderedProminent)
                        Button("Entfernen", role: .destructive) {
                            state.removeModel(model)
                        }
                    } else {
                        if state.pausedModelID == model.id {
                            Button("Fortsetzen") { state.installModel(model) }
                                .buttonStyle(.borderedProminent)
                            Button("Verwerfen", role: .destructive) {
                                state.discardPausedDownload()
                            }
                        } else {
                            Button("Herunterladen") { state.installModel(model) }
                            .buttonStyle(.borderedProminent)
                            .disabled(
                                state.downloadingModelID != nil
                                    || model.compatibility == .incompatible
                            )
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func compatibilityBadge(_ compatibility: ModelCompatibility) -> some View {
        let (title, color): (String, Color) = switch compatibility {
        case .recommended: ("Empfohlen", .green)
        case .compatible: ("Kompatibel", .blue)
        case .experimental: ("Experimentell", .orange)
        case .incompatible: ("Nicht kompatibel", .red)
        }
        Text(title)
            .font(.caption.bold())
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }
}

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @State private var confirmsRebuild = false
    @State private var confirmsOCRReset = false
    @State private var confirmsIndexDeletion = false

    var body: some View {
        @Bindable var state = state
        Form {
            Section("Dokumente") {
                LabeledContent("Ordner", value: state.documentFolderPath ?? "Nicht ausgewählt")
                Button("Dokumentenordner auswählen …") { state.chooseFolder() }
                Stepper("Scanintervall: \(state.scanIntervalMinutes) Minuten", value: $state.scanIntervalMinutes, in: 1...1440)
            }
            Section("Lokales Sprachmodell") {
                Stepper("Nach \(state.llmIdleMinutes) Minuten entladen", value: $state.llmIdleMinutes, in: 1...120)
                Toggle("Experimentelle Modelle anzeigen", isOn: $state.showExperimentalModels)
            }
            Section("Start und Hintergrund") {
                Toggle(
                    "Beim Anmelden starten",
                    isOn: Binding(
                        get: { state.launchAtLogin },
                        set: { state.setLaunchAtLogin($0) }
                    )
                )
                LabeledContent("Speicherdruck", value: state.memoryPressure)
            }
            Section("Datenschutz") {
                Text("Dokumente, Suchanfragen, Embeddings und Antworten bleiben lokal. Telemetrie ist deaktiviert.")
                    .foregroundStyle(.secondary)
            }
            Section("Indexwartung") {
                Button("Suchindex neu aufbauen …") { confirmsRebuild = true }
                Text("Löscht Chunks, Volltextindex und Embeddings und baut sie ausschließlich aus dem bereits gespeicherten Seitentext neu auf.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("OCR zurücksetzen …") { confirmsOCRReset = true }
                Text("Löscht OCR-Text, Qualitätswerte und davon abhängige Indexdaten. Original-PDFs bleiben erhalten und OCR wird erneut eingeplant.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Inkonsistenzen reparieren") { state.repairIndex() }
                Text("Prüft SQLite und Fremdschlüssel, gleicht Jobzustände ab und baut den Volltextindex aus vorhandenen Chunks neu auf.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Vollständigen Dokumentindex löschen …", role: .destructive) {
                    confirmsIndexDeletion = true
                }
                Text("Löscht Dokumente, Seiten, OCR-Daten, Chunks, Embeddings und Suchverlauf. PDFs, Modelle und Einstellungen bleiben erhalten.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Einstellungen speichern") {
                    state.saveSettings()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Einstellungen")
        .confirmationDialog("Suchindex neu aufbauen?", isPresented: $confirmsRebuild) {
            Button("Neu aufbauen") { state.rebuildSearchIndex() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Gespeicherter Seiten- und OCR-Text bleibt erhalten.")
        }
        .confirmationDialog("OCR-Daten wirklich zurücksetzen?", isPresented: $confirmsOCRReset) {
            Button("OCR zurücksetzen", role: .destructive) { state.resetOCRData() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Original-PDFs werden nicht gelöscht oder verschoben.")
        }
        .confirmationDialog("Dokumentindex vollständig löschen?", isPresented: $confirmsIndexDeletion) {
            Button("Dokumentindex löschen", role: .destructive) { state.deleteDocumentIndex() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Die Verarbeitung wird danach pausiert. PDFs, Modelle und Einstellungen bleiben erhalten.")
        }
    }
}

struct LogView: View {
    @Environment(AppState.self) private var state
    @State private var filter = ""

    var body: some View {
        VStack {
            HStack {
                Button("Aktualisieren") { Task { await state.refreshDatabaseState() } }
                Button("Log exportieren …") { state.exportLog() }
                TextField("Protokoll filtern", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                Spacer()
            }
            .padding([.horizontal, .top])
            List {
                ForEach(Array(filteredEntries.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.1).font(.headline)
                            Spacer()
                            Text(entry.0.formatted()).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(entry.2)
                        if let path = entry.3 {
                            Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Protokoll")
    }

    private var filteredEntries: [(Date, String, String, String?)] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return state.logEntries }
        return state.logEntries.filter { entry in
            entry.1.localizedCaseInsensitiveContains(query)
                || entry.2.localizedCaseInsensitiveContains(query)
                || (entry.3?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }
}

struct MenuBarContent: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(state.isProcessing ? "Verarbeitung läuft" : state.isPaused ? "Verarbeitung pausiert" : "Dienst aktiv")
        if let file = state.statistics.currentFile { Text(file).font(.caption) }
        Divider()
        Button("Hauptfenster öffnen") {
            NSApplication.shared.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
        Button("Jetzt scannen") { Task { await state.scanNow() } }
            .disabled(state.documentFolderPath == nil || state.isProcessing)
        Button(state.isPaused ? "Fortsetzen" : "Verarbeitung pausieren") {
            state.setPaused(!state.isPaused)
        }
        Divider()
        Button("App beenden") { NSApplication.shared.terminate(nil) }
    }
}
