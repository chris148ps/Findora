import AppKit
import CoreImage
import Observation
import PDFKit
import FindoraCore
import FindoraMLX
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

@main
struct FindoraApplication: App {
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup("Findora", id: "main") {
            ContentView()
                .id(state.interfaceLocale.identifier)
                .environment(state)
                .environment(\.locale, state.interfaceLocale)
                .preferredColorScheme(state.preferredColorScheme)
                .frame(minWidth: 1_050, minHeight: 700)
        }
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(
                    state.interfaceLocale.language.languageCode?.identifier == "en"
                        ? "About Findora"
                        : "Über Findora"
                ) {
                    state.showsAbout = true
                }
            }
            CommandGroup(after: .newItem) {
                Divider()
                Button("E-Mail-Dateien importieren …") {
                    state.chooseMailFiles(format: .eml)
                }
                .disabled(state.isMailImporting || state.isStorageMigrationInProgress)
                Button("Apple-Mail-Postfach importieren …") {
                    state.chooseMailFiles(format: .mbox)
                }
                .disabled(state.isMailImporting || state.isStorageMigrationInProgress)
                Button("E-Mail-Importordner hinzufügen …") {
                    state.chooseMailImportFolder()
                }
                .disabled(state.isMailImporting || state.isStorageMigrationInProgress)
            }
        }

        MenuBarExtra("Findora", systemImage: state.isProcessing ? "doc.text.magnifyingglass" : "magnifyingglass") {
            MenuBarContent()
                .environment(state)
                .environment(\.locale, state.interfaceLocale)
                .preferredColorScheme(state.preferredColorScheme)
        }

        Settings {
            SettingsView()
                .environment(state)
                .environment(\.locale, state.interfaceLocale)
                .preferredColorScheme(state.preferredColorScheme)
                .frame(width: 620, height: 520)
        }
    }
}

enum InterfaceLanguage: String, CaseIterable, Identifiable {
    case system
    case german
    case english

    var id: Self { self }
    var displayName: LocalizedStringKey {
        switch self {
        case .system: "Systemsprache"
        case .german: "Deutsch"
        case .english: "English"
        }
    }
}

enum InterfaceAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }
    var displayName: LocalizedStringKey {
        switch self {
        case .system: "System"
        case .light: "Hell"
        case .dark: "Dunkel"
        }
    }
}

enum AppSection: String, CaseIterable, Identifiable {
    case search = "Suche"
    case mail = "E-Mail-Quellen"
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
        case .mail: "envelope"
        case .status: "doc.text"
        case .maintenance: "wrench.and.screwdriver"
        case .ocr: "text.viewfinder"
        case .models: "cpu"
        case .settings: "gearshape"
        case .logs: "list.bullet.rectangle"
        }
    }
}

struct PendingMailImport: Identifiable {
    let id = UUID()
    let urls: [URL]
    var estimate: MailImportEstimate
    var mode: MailImportMode = .referenced
    var watchFolders = false
}

struct PendingStorageChange: Identifiable {
    let id = UUID()
    let kind: StorageKind
    let sourceURL: URL
    let destinationParent: URL
    let estimate: StorageMigrationEstimate
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
    var searchContentFilter: SearchContentFilter = .all
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
    var ocrReviewCandidates: [OCRReviewCandidate] = []
    var missingFileCandidates: [MissingFileCandidate] = []
    var isMaintainingDocuments = false
    var maintenanceMessage: String?
    var statusDiagnosticMessage: String?
    var showsAbout = false
    var processingSession: ProcessingSessionSnapshot?
    var interfaceLanguage: InterfaceLanguage = .german
    var interfaceAppearance: InterfaceAppearance = .system
    var isAnswerModelLoaded = false
    var isEmbeddingModelLoaded = false
    var mailSources: [MailImportSource] = []
    var pendingMailImport: PendingMailImport?
    var mailImportProgress: MailImportProgress?
    var mailImportMessage: String?
    var isMailImporting = false
    var dataStoragePath = ""
    var modelStoragePath = ""
    var dataStorageAvailable = true
    var modelStorageAvailable = true
    var pendingStorageMigration: StorageMigrationRecord?
    var lastStorageMigration: StorageMigrationRecord?
    var pendingStorageChange: PendingStorageChange?
    var storageMigrationProgress: StorageMigrationProgress?
    var storageUsage: StorageUsageSnapshot?
    var storageMessage: String?
    var isStorageMigrationInProgress = false
    var removedDocumentPolicy: RemovedDocumentPolicy = .removeAfterSuccessfulScan
    var lastSynchronizationMessage: String?
    var hardwareProfile: HardwareProfile

    var interfaceLocale: Locale {
        switch interfaceLanguage {
        case .system:
            let language = Locale.current.language.languageCode?.identifier
            return Locale(identifier: language == "de" ? "de" : "en")
        case .german:
            return Locale(identifier: "de")
        case .english:
            return Locale(identifier: "en")
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch interfaceAppearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    func localizedSectionTitle(_ section: AppSection) -> String {
        guard interfaceLocale.language.languageCode?.identifier == "en" else {
            return section.rawValue
        }
        return switch section {
        case .search: "Search"
        case .mail: "Email sources"
        case .status: "Document status"
        case .maintenance: "Document maintenance"
        case .ocr: "OCR"
        case .models: "Models"
        case .settings: "Settings"
        case .logs: "Log"
        }
    }

    var semanticSearchEnabled: Bool {
        activeEmbeddingModelID != nil
    }

    var localAnswersEnabled: Bool {
        activeAnswerModelID != nil
    }

    var activeEmbeddingModelVersion: String? {
        guard let activeEmbeddingModelID else { return nil }
        return availableModels.first {
            $0.id == activeEmbeddingModelID
        }?.descriptor.modelVersion
    }

    var hasMixedEmbeddingIndex: Bool {
        statistics.e5EmbeddedChunks > 0 && statistics.fallbackEmbeddedChunks > 0
    }

    private var paths: AppPaths
    private var database: SQLiteDatabase
    private let fileLogger: AppFileLogger
    private var maintenanceService: DocumentMaintenanceService
    private let bookmarkStore = FolderBookmarkStore()
    private var scanner: RecursivePDFScanner
    private var processor: DocumentProcessor
    private var searchService: HybridSearchService
    private var modelManager: LocalModelManager
    private var mailImportService: MailImportService
    private let storageConfigurationStore: StorageConfigurationStore
    private let storageMigrationService: StorageMigrationService
    private var dataStorageAccess: ResolvedStorageLocation?
    private var modelStorageAccess: ResolvedStorageLocation?
    private var mailImportTask: Task<Void, Never>?
    private var mailWatchLoop: Task<Void, Never>?
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
            let storageStore = StorageConfigurationStore()
            let storageSelection = try storageStore.startupSelection()
            let paths = try AppPaths(
                applicationSupport: storageSelection.dataURL,
                modelStorage: storageSelection.modelURL,
                createDataDirectories: storageSelection.dataIsAvailable,
                createModelDirectory: storageSelection.modelsAreAvailable
            )
            self.paths = paths
            self.storageConfigurationStore = storageStore
            self.storageMigrationService = StorageMigrationService(
                configurationStore: storageStore
            )
            self.dataStorageAccess = storageSelection.dataAccess
            self.modelStorageAccess = storageSelection.modelAccess
            self.dataStoragePath = storageSelection.dataURL.path
            self.modelStoragePath = storageSelection.modelURL.path
            self.dataStorageAvailable = storageSelection.dataIsAvailable
            self.modelStorageAvailable = storageSelection.modelsAreAvailable
            self.pendingStorageMigration = try storageStore.pendingMigration()
            self.lastStorageMigration = try storageStore.lastMigration()
            let database = SQLiteDatabase(url: paths.database)
            let fileLogger = try AppFileLogger(logDirectory: paths.logs)
            self.database = database
            self.fileLogger = fileLogger
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
            self.searchService = HybridSearchService(
                database: database,
                embedder: embedder,
                semanticEnabled: false
            )
            self.mailImportService = MailImportService(
                database: database,
                embedder: embedder,
                archiveRoot: paths.mailArchive
            )
        } catch {
            fatalError("Findora-Verzeichnisse konnten nicht angelegt werden: \(error)")
        }

        startMemoryPressureMonitoring()
        Task { await start() }
    }

    func start() async {
        do {
            try await fileLogger.log(
                .info,
                category: "App",
                message: "Findora wird gestartet."
            )
            guard dataStorageAvailable else {
                folderStatus = "Datenspeicher nicht erreichbar"
                lastError = """
                Der konfigurierte Findora-Datenspeicher ist nicht erreichbar. \
                Es wurde keine neue Datenbank angelegt.

                Erwarteter Speicherort:
                \(dataStoragePath)
                """
                return
            }
            try await database.initialize()
            await startDocumentStatusMonitoring()
            await runMemoryPressureDiagnosticIfRequested()
            await loadSettings()
            processingSession = try await database.latestProcessingSession()
            if let finishedAt = processingSession?.finishedAt,
               Date().timeIntervalSince(finishedAt) > 8 {
                processingSession = nil
            }
            if var restored = processingSession, restored.phase.isActive {
                restored.phase = isPaused ? .paused : .scanning
                restored.isPaused = isPaused
                restored.currentFile = isPaused
                    ? restored.currentFile
                    : "Nächstes Dokument wird vorbereitet"
                processingSession = restored
                try? await database.saveProcessingSession(restored)
            }
            if ocrConfiguration.requiresTesseractComponents {
                await refreshOCRComponents()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            let documentAccessDisabled =
                ProcessInfo.processInfo.environment["FINDORA_DISABLE_DOCUMENT_ACCESS"] == "1"
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
            if modelStorageAvailable {
                await refreshModels()
                await restoreModelSelection()
                await refreshModels()
            } else {
                modelMessage =
                    "Der konfigurierte KI-Modellspeicher ist nicht erreichbar. Die Volltextsuche bleibt verfügbar."
            }
            await refreshMailSources()
            startMailWatchLoop()
            await refreshDatabaseState()
            await refreshStorageUsage()
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

    func chooseMailFiles(format: MailSourceFormat) {
        guard !isMailImporting, !isStorageMigrationInProgress else { return }
        let panel = NSOpenPanel()
        panel.title = switch format {
        case .mbox: "Apple-Mail-Postfach auswählen"
        case .eml: "E-Mail-Dateien auswählen"
        case .outlookMSG: "Outlook-Nachrichten auswählen"
        case .importFolder: "E-Mail-Quelle auswählen"
        }
        panel.prompt = "Auswählen"
        panel.canChooseDirectories = format == .mbox
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = format == .eml || format == .outlookMSG
        panel.resolvesAliases = true
        panel.treatsFilePackagesAsDirectories = false
        let fileExtension = format == .outlookMSG ? "msg" : format.rawValue
        if let type = UTType(filenameExtension: fileExtension) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        prepareMailImport(urls: panel.urls)
    }

    func chooseMailImportFolder() {
        guard !isMailImporting, !isStorageMigrationInProgress else { return }
        let panel = NSOpenPanel()
        panel.title = "E-Mail-Importordner auswählen"
        panel.prompt = "Ordner auswählen"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        prepareMailImport(urls: [url])
    }

    private func prepareMailImport(urls: [URL]) {
        Task {
            do {
                let estimate = try await mailImportService.estimate(
                    urls: urls,
                    importMode: .referenced
                )
                pendingMailImport = PendingMailImport(
                    urls: urls,
                    estimate: estimate
                )
            } catch {
                report(error, taskType: "E-Mail-Import vorbereiten")
            }
        }
    }

    func updatePendingMailImportMode(_ mode: MailImportMode) {
        guard let pending = pendingMailImport else { return }
        Task {
            do {
                let estimate = try await mailImportService.estimate(
                    urls: pending.urls,
                    importMode: mode
                )
                var updated = pending
                updated.mode = mode
                updated.estimate = estimate
                pendingMailImport = updated
            } catch {
                report(error, taskType: "E-Mail-Speicherbedarf schätzen")
            }
        }
    }

    func setPendingMailWatch(_ enabled: Bool) {
        pendingMailImport?.watchFolders = enabled
    }

    func confirmMailImport() {
        guard let pending = pendingMailImport,
              !isMailImporting,
              !isStorageMigrationInProgress else { return }
        pendingMailImport = nil
        isMailImporting = true
        mailImportMessage = nil
        mailImportTask = Task {
            defer {
                isMailImporting = false
                mailImportTask = nil
            }
            do {
                let summary = try await mailImportService.importSources(
                    urls: pending.urls,
                    importMode: pending.mode,
                    watchFolders: pending.watchFolders
                ) { [weak self] progress in
                    await MainActor.run {
                        self?.mailImportProgress = progress
                    }
                }
                mailImportMessage =
                    "\(summary.imported) E-Mail(s) importiert, \(summary.updated) aktualisiert, "
                    + "\(summary.duplicates) Dublette(n) übersprungen, \(summary.attachments) Anhang/Anhänge erkannt."
                await refreshMailSources()
                await refreshDatabaseState()
            } catch is CancellationError {
                mailImportMessage = "E-Mail-Import wurde abgebrochen und kann erneut gestartet werden."
            } catch {
                report(error, taskType: "E-Mail-Import")
            }
        }
    }

    func cancelMailImport() {
        mailImportTask?.cancel()
    }

    func setMailImportPaused(_ paused: Bool) {
        Task { await mailImportService.setPaused(paused) }
    }

    func refreshMailSources() async {
        do {
            mailSources = try await database.mailSources()
        } catch {
            report(error, taskType: "E-Mail-Quellen laden")
        }
    }

    func synchronizeMailSource(_ source: MailImportSource) {
        guard !isMailImporting, !isStorageMigrationInProgress else { return }
        isMailImporting = true
        mailImportTask = Task {
            defer {
                isMailImporting = false
                mailImportTask = nil
            }
            do {
                let summary = try await mailImportService.synchronizeSource(
                    sourceID: source.id
                ) { [weak self] progress in
                    await MainActor.run {
                        self?.mailImportProgress = progress
                    }
                }
                mailImportMessage =
                    "Abgleich abgeschlossen: \(summary.imported) neu, \(summary.updated) aktualisiert, \(summary.duplicates) Dublette(n)."
                await refreshMailSources()
                await refreshDatabaseState()
            } catch {
                report(error, taskType: "E-Mail-Quelle erneut einlesen")
            }
        }
    }

    func setMailSourceWatch(_ source: MailImportSource, enabled: Bool) {
        Task {
            do {
                try await database.setMailSourceWatchEnabled(
                    sourceID: source.id,
                    enabled: enabled
                )
                await refreshMailSources()
                startMailWatchLoop()
            } catch {
                report(error, taskType: "E-Mail-Ordnerüberwachung ändern")
            }
        }
    }

    func revealMailSource(_ source: MailImportSource) {
        let path = FileManager.default.fileExists(atPath: source.path)
            ? source.path
            : source.archivedPath ?? source.path
        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
    }

    func reassignMailSource(_ source: MailImportSource) {
        let panel = NSOpenPanel()
        panel.title = "E-Mail-Quelle neu zuordnen"
        panel.prompt = "Neu zuordnen"
        panel.canChooseDirectories = source.format == .mbox || source.format == .importFolder
        panel.canChooseFiles = source.format != .importFolder
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        if source.format != .importFolder,
           let type = UTType(
               filenameExtension: source.format == .outlookMSG
                   ? "msg" : source.format.rawValue
           ) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let bookmark = try url.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                try await database.reassignMailSource(
                    sourceID: source.id,
                    url: url,
                    bookmarkData: bookmark
                )
                await refreshMailSources()
                if let updated = mailSources.first(where: { $0.id == source.id }) {
                    synchronizeMailSource(updated)
                }
            } catch {
                report(error, taskType: "E-Mail-Quelle neu zuordnen")
            }
        }
    }

    func removeMailSource(_ source: MailImportSource) {
        Task {
            do {
                try await database.removeMailSource(sourceID: source.id)
                mailImportMessage =
                    "Die Quellenzuordnung wurde entfernt. Indexierte E-Mails und archivierte Originale wurden nicht gelöscht."
                await refreshMailSources()
                await refreshDatabaseState()
            } catch {
                report(error, taskType: "E-Mail-Quelle entfernen")
            }
        }
    }

    func chooseStorageLocation(kind: StorageKind) {
        guard !isStorageMigrationInProgress, !isProcessing, !isMailImporting else {
            storageMessage =
                "Bitte laufende OCR-, Indexierungs- oder Importvorgänge zuerst beenden oder pausieren."
            return
        }
        let panel = NSOpenPanel()
        panel.title = "\(kind.displayName) – Zielordner auswählen"
        panel.prompt = "Zielordner prüfen"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let source = kind == .data ? paths.applicationSupport : paths.models
        let exclusions = kind == .data ? [paths.models] : []
        Task {
            do {
                let estimate = try await storageMigrationService.estimateMigration(
                    sourceURL: source,
                    destinationParent: destination,
                    excludedRoots: exclusions
                )
                pendingStorageChange = PendingStorageChange(
                    kind: kind,
                    sourceURL: source,
                    destinationParent: destination,
                    estimate: estimate
                )
            } catch {
                report(error, taskType: "Speicherziel prüfen")
            }
        }
    }

    func reconnectConfiguredStorage(kind: StorageKind) {
        let panel = NSOpenPanel()
        panel.title = "\(kind.displayName) zuordnen"
        panel.prompt = "Speicher zuordnen"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if kind == .data,
           !FileManager.default.fileExists(
               atPath: url.appending(path: "Findora.sqlite3").path
           ) {
            lastError =
                "Der gewählte Ordner enthält keine Findora.sqlite3-Datenbank und wurde nicht aktiviert."
            return
        }
        Task {
            do {
                try storageConfigurationStore.saveLocation(kind: kind, url: url)
                try await reloadStorageState()
                lastError = nil
                if kind == .data {
                    await start()
                }
            } catch {
                report(error, taskType: "Konfigurierten Speicher neu zuordnen")
            }
        }
    }

    func retryConfiguredDataStorage() {
        Task {
            do {
                let selection = try storageConfigurationStore.startupSelection()
                guard selection.dataIsAvailable else {
                    lastError =
                        "Der konfigurierte Datenspeicher ist weiterhin nicht erreichbar: \(dataStoragePath)"
                    return
                }
                dataStorageAvailable = true
                try await reloadStorageState()
                lastError = nil
                await start()
            } catch {
                dataStorageAvailable = false
                report(error, taskType: "Datenspeicher erneut prüfen")
            }
        }
    }

    func confirmStorageMigration() {
        guard let change = pendingStorageChange,
              change.estimate.assessment.isAllowed,
              !isStorageMigrationInProgress else { return }
        pendingStorageChange = nil
        isStorageMigrationInProgress = true
        storageMessage = nil
        Task {
            let wasPaused = isPaused
            do {
                searchTask?.cancel()
                mailImportTask?.cancel()
                mailWatchLoop?.cancel()
                modelDownloadTask?.cancel()
                scanLoop?.cancel()
                eventScanTask?.cancel()
                folderWatcher?.stop()
                await processor.setPaused(true)
                await mailImportService.setPaused(true)
                if change.kind == .data {
                    try await database.checkpointAndClose()
                } else {
                    await unloadAnswerModel(reason: "Modellspeicher wird übertragen")
                    answerGenerator = nil
                    activeAnswerModelID = nil
                    activeEmbeddingModelID = nil
                    isAnswerModelLoaded = false
                    isEmbeddingModelLoaded = false
                }

                let exclusions = change.kind == .data ? [paths.models] : []
                _ = try await storageMigrationService.migrate(
                    kind: change.kind,
                    sourceURL: change.sourceURL,
                    destinationParent: change.destinationParent,
                    excludedRoots: exclusions
                ) { [weak self] progress in
                    await MainActor.run {
                        self?.storageMigrationProgress = progress
                    }
                }
                try await reloadStorageState()
                isPaused = wasPaused
                await processor.setPaused(wasPaused)
                await mailImportService.setPaused(false)
                if !wasPaused {
                    startScanLoop()
                    startMailWatchLoop()
                    if let folder = resolvedFolder {
                        configureFolderWatcher(for: folder.url)
                    }
                }
                storageMessage =
                    "\(change.kind.displayName) wurde kopiert, vollständig validiert und auf den neuen Ort umgeschaltet. Der alte Bestand bleibt erhalten."
            } catch {
                if change.kind == .data {
                    try? await database.initialize()
                    await startDocumentStatusMonitoring()
                }
                await processor.setPaused(wasPaused)
                await mailImportService.setPaused(false)
                isPaused = wasPaused
                if !wasPaused {
                    startScanLoop()
                    startMailWatchLoop()
                    if let folder = resolvedFolder {
                        configureFolderWatcher(for: folder.url)
                    }
                }
                report(error, taskType: "Speicher sicher übertragen")
            }
            isStorageMigrationInProgress = false
        }
    }

    func movePreviousStorageToTrash() {
        guard let migration = lastStorageMigration,
              migration.phase == .completed else { return }
        let oldURL = URL(filePath: migration.sourcePath)
        let activeURL = migration.kind == .data
            ? paths.applicationSupport
            : paths.models
        Task {
            do {
                try await storageMigrationService.moveOldStorageToTrash(
                    oldURL: oldURL,
                    activeURL: activeURL
                )
                storageMessage =
                    "Der bestätigte Altbestand wurde in den macOS-Papierkorb verschoben."
                lastStorageMigration = nil
            } catch {
                report(error, taskType: "Alten Speicher in Papierkorb verschieben")
            }
        }
    }

    func refreshStorageUsage() async {
        guard dataStorageAvailable else { return }
        do {
            let logical = try await database.logicalStorageUsage()
            storageUsage = try await storageMigrationService.storageUsage(
                paths: paths,
                databaseTextBytes: logical.textBytes,
                embeddingBytes: logical.embeddingBytes
            )
        } catch {
            report(error, taskType: "Speicherbelegung ermitteln")
        }
    }

    func checkStorageIntegrity() {
        Task {
            do {
                let result = try await database.databaseQuickCheck()
                storageMessage = result.lowercased() == "ok"
                    ? "SQLite-Integritätsprüfung erfolgreich."
                    : "SQLite-Integritätsprüfung meldet: \(result)"
            } catch {
                report(error, taskType: "Speicherintegrität prüfen")
            }
        }
    }

    func revealStorage(kind: StorageKind) {
        let url = kind == .data ? paths.applicationSupport : paths.models
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func cleanTemporaryStorage() {
        Task {
            do {
                try await storageMigrationService.cleanTemporaryData(paths: paths)
                storageMessage =
                    "Temporäre Modelldownloads wurden in den macOS-Papierkorb verschoben."
                await refreshStorageUsage()
            } catch {
                report(error, taskType: "Temporäre Daten bereinigen")
            }
        }
    }

    func continuePendingStorageMigration() {
        guard let record = pendingStorageMigration else { return }
        Task {
            do {
                if record.phase == .failed {
                    try await storageMigrationService.discardFailedStaging(for: record)
                }
                let source = URL(filePath: record.sourcePath)
                let parent = URL(filePath: record.destinationPath)
                    .deletingLastPathComponent()
                let exclusions = record.kind == .data ? [paths.models] : []
                let estimate = try await storageMigrationService.estimateMigration(
                    sourceURL: source,
                    destinationParent: parent,
                    excludedRoots: exclusions
                )
                pendingStorageChange = PendingStorageChange(
                    kind: record.kind,
                    sourceURL: source,
                    destinationParent: parent,
                    estimate: estimate
                )
            } catch {
                report(error, taskType: "Speichermigration fortsetzen")
            }
        }
    }

    func discardPendingStorageMigration() {
        guard let record = pendingStorageMigration else { return }
        Task {
            do {
                try await storageMigrationService.discardFailedStaging(for: record)
                storageConfigurationStore.clearMigrationRecord()
                pendingStorageMigration = nil
                storageMessage =
                    "Der unvollständige Staging-Bestand wurde in den Papierkorb verschoben. Der bisherige aktive Speicher bleibt unverändert."
            } catch {
                report(error, taskType: "Unvollständige Migration verwerfen")
            }
        }
    }

    func returnToPreviousStorage() {
        guard let record = pendingStorageMigration else { return }
        do {
            let oldURL = URL(filePath: record.sourcePath)
            try storageConfigurationStore.saveLocation(kind: record.kind, url: oldURL)
            storageConfigurationStore.clearMigrationRecord()
            pendingStorageMigration = nil
            storageMessage =
                "Der bisherige Speicher ist wieder als aktiv hinterlegt. Es wurden keine Daten gelöscht."
        } catch {
            report(error, taskType: "Zum bisherigen Speicher zurückkehren")
        }
    }

    private func reloadStorageState() async throws {
        let selection = try storageConfigurationStore.startupSelection()
        let newPaths = try AppPaths(
            applicationSupport: selection.dataURL,
            modelStorage: selection.modelURL,
            createDataDirectories: selection.dataIsAvailable,
            createModelDirectory: selection.modelsAreAvailable
        )
        let catalog = try ModelCatalog.bundled()

        if database.url != newPaths.database {
            let newDatabase = SQLiteDatabase(url: newPaths.database)
            try await newDatabase.initialize()
            database = newDatabase
            maintenanceService = DocumentMaintenanceService(database: newDatabase)
            scanner = RecursivePDFScanner(excludedRoots: [newPaths.applicationSupport])
            processor = makeProcessor(embedder: TokenHashEmbedding())
            searchService = HybridSearchService(
                database: newDatabase,
                embedder: TokenHashEmbedding(),
                semanticEnabled: false
            )
            mailImportService = MailImportService(
                database: newDatabase,
                embedder: TokenHashEmbedding(),
                archiveRoot: newPaths.mailArchive
            )
            await startDocumentStatusMonitoring()
            await loadSettings()
        }

        paths = newPaths
        modelManager = LocalModelManager(catalog: catalog, paths: newPaths)
        hardwareProfile = HardwareProfile.current(storageURL: newPaths.applicationSupport)
        dataStorageAccess?.stopAccess()
        modelStorageAccess?.stopAccess()
        dataStorageAccess = selection.dataAccess
        modelStorageAccess = selection.modelAccess
        dataStoragePath = selection.dataURL.path
        modelStoragePath = selection.modelURL.path
        dataStorageAvailable = selection.dataIsAvailable
        modelStorageAvailable = selection.modelsAreAvailable
        pendingStorageMigration = try storageConfigurationStore.pendingMigration()
        lastStorageMigration = try storageConfigurationStore.lastMigration()

        if modelStorageAvailable {
            await refreshModels()
            await restoreModelSelection()
            await refreshModels()
        }
        await refreshMailSources()
        await refreshDatabaseState()
        await refreshStorageUsage()
    }

    private func startMailWatchLoop() {
        mailWatchLoop?.cancel()
        guard mailSources.contains(where: \.watchEnabled) else {
            mailWatchLoop = nil
            return
        }
        mailWatchLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self else { return }
                let watched = self.mailSources.filter(\.watchEnabled)
                for source in watched {
                    guard !Task.isCancelled,
                          !self.isStorageMigrationInProgress,
                          !self.isMailImporting else { break }
                    self.isMailImporting = true
                    do {
                        _ = try await self.mailImportService.synchronizeSource(
                            sourceID: source.id
                        ) { [weak self] progress in
                            await MainActor.run {
                                self?.mailImportProgress = progress
                            }
                        }
                        await self.refreshMailSources()
                        await self.refreshDatabaseState()
                    } catch {
                        try? await self.database.markMailSourceUnavailable(
                            sourceID: source.id
                        )
                        await self.refreshMailSources()
                    }
                    self.isMailImporting = false
                }
            }
        }
    }

    func scanNow() async {
        guard !isPaused else { return }
        guard !isStorageMigrationInProgress else { return }
        guard !isProcessing else { return }
        guard let folder = resolvedFolder else {
            report(FindoraError.noDocumentFolder)
            return
        }
        isProcessing = true
        await beginProcessingSession(phase: .scanning)
        folderStatus = "Scan läuft …"
        defer { isProcessing = false }

        do {
            let files = try await scanner.scan(root: folder.url)
            await updateProcessingSession(
                phase: .scanning,
                total: files.count,
                currentFile: nil
            )
            try await database.saveScan(
                files: files,
                root: folder.url,
                removedDocumentPolicy: removedDocumentPolicy
            )
            folderStatus = "Erreichbar"
            await updateProcessingSession(phase: .indexing)
            await processor.processPending(
                ocrConfiguration: ocrConfiguration,
                removeMissingDocuments:
                    removedDocumentPolicy == .removeAfterSuccessfulScan
            ) {
                [weak self] progress in
                await self?.updateProcessingSession(
                    phase: .indexing,
                    total: progress.total,
                    completed: progress.completed,
                    currentFile: progress.currentFile
                )
            }
            await refreshDatabaseState()
            lastSynchronizationMessage =
                "Synchronisation abgeschlossen: \(files.count) PDF-Datei(en) im führenden Dokumentenordner abgeglichen."
            await updateProcessingSession(failed: statistics.failedJobs)
            await finishProcessingSession(phase: .completed)
        } catch is CancellationError {
            await finishProcessingSession(phase: .completed)
            reportCancellation(
                taskType: "Dokumentenscan",
                trigger: "Task ersetzt oder App-Lifecycle",
                userInitiated: false
            )
        } catch {
            folderStatus = "Nicht erreichbar"
            await finishProcessingSession(phase: .failed)
            report(error, taskType: "Dokumentenscan")
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
                if var session = processingSession {
                    session.isPaused = paused
                    session.phase = paused ? .paused : .scanning
                    processingSession = session
                    try await database.saveProcessingSession(session)
                }
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
                    throw FindoraError.processFailed("OCR-Einstellungen konnten nicht codiert werden.")
                }
                try await database.setSetting(key: "ocrConfiguration", value: ocrJSON)
                try await database.setSetting(key: "scanIntervalMinutes", value: String(scanIntervalMinutes))
                try await database.setSetting(key: "llmIdleMinutes", value: String(llmIdleMinutes))
                try await database.setSetting(key: "showExperimentalModels", value: showExperimentalModels ? "1" : "0")
                try await database.setSetting(key: "interfaceLanguage", value: interfaceLanguage.rawValue)
                try await database.setSetting(key: "interfaceAppearance", value: interfaceAppearance.rawValue)
                try await database.setSetting(
                    key: "removedDocumentPolicy",
                    value: removedDocumentPolicy.rawValue
                )
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
                await beginProcessingSession(phase: .rebuildingSearch)
                try await processor.rebuildSearchIndex { [weak self] progress in
                    await self?.updateProcessingSession(
                        phase: .rebuildingSearch,
                        total: progress.total,
                        completed: progress.completed,
                        currentFile: progress.currentFile
                    )
                }
                modelMessage = "Der Suchindex wurde aus dem gespeicherten Text neu aufgebaut."
                await refreshDatabaseState()
                await finishProcessingSession(phase: .completed)
            } catch is CancellationError {
                await finishProcessingSession(phase: .completed)
                reportCancellation(
                    taskType: "Suchindex-Neuaufbau",
                    trigger: "Reset oder Benutzerabbruch",
                    userInitiated: false
                )
            } catch {
                await finishProcessingSession(phase: .failed)
                report(error, taskType: "Suchindex-Neuaufbau")
            }
        }
    }

    func resetOCRData() {
        guard !isProcessing else { return }
        isProcessing = true
        Task {
            defer { isProcessing = false }
            do {
                await beginProcessingSession(phase: .resettingAnalysis)
                try await database.resetAutomaticOCRAndAnalysis()
                try? await fileLogger.log(
                    .warning,
                    category: "Indexwartung",
                    message: "Automatische OCR-, Retry- und Leerseitenanalysen wurden zurückgesetzt; manuelle Bewertungen und Texte blieben erhalten."
                )
                await refreshDatabaseState()
                isProcessing = false
                await scanNow()
            } catch is CancellationError {
                await finishProcessingSession(phase: .completed)
                reportCancellation(
                    taskType: "OCR-Analyse-Reset",
                    trigger: "Reset abgebrochen",
                    userInitiated: false
                )
            } catch {
                await finishProcessingSession(phase: .failed)
                report(error, taskType: "OCR-Analyse-Reset")
            }
        }
    }

    func deleteDocumentIndex() {
        guard !isProcessing else { return }
        setPaused(true)
        Task {
            do {
                await beginProcessingSession(phase: .cancelling)
                try await database.deleteDocumentIndex()
                try? await fileLogger.log(
                    .warning,
                    category: "Indexwartung",
                    message: "Der vollständige Dokumentindex wurde gelöscht; PDFs, Modelle und Einstellungen blieben erhalten."
                )
                modelMessage = "Dokumentindex gelöscht. Verarbeitung bleibt bis zum manuellen Fortsetzen pausiert."
                await refreshDatabaseState()
                processingSession = nil
            } catch {
                await finishProcessingSession(phase: .failed)
                report(error, taskType: "Vollständiger Index-Reset")
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
            async let ocrReview = database.ocrReviewCandidates()
            async let missingFiles = database.missingFileCandidates()
            let snapshot = try await (
                duplicates, emptyPages, emptyPDFs, ocrReview, missingFiles
            )
            duplicateGroups = snapshot.0
            emptyPageCandidates = snapshot.1
            emptyPDFCandidates = snapshot.2
            ocrReviewCandidates = snapshot.3
            missingFileCandidates = snapshot.4
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
                if decision == .notEmpty {
                    await retryOCRPage(
                        path: candidate.absolutePath,
                        pageNumber: candidate.pageNumber
                    )
                }
            } catch {
                report(error)
            }
        }
    }

    func reanalyzeEmptyPage(_ candidate: EmptyPageCandidate) {
        guard !isMaintainingDocuments, !isProcessing else { return }
        isMaintainingDocuments = true
        maintenanceMessage =
            "Leerseitenanalyse für Seite \(candidate.pageNumber) wird neu ausgeführt …"
        Task {
            defer { isMaintainingDocuments = false }
            do {
                let result = try await maintenanceService.reanalyzePage(
                    path: candidate.absolutePath,
                    expectedHash: candidate.originalHash,
                    pageNumber: candidate.pageNumber
                )
                maintenanceMessage =
                    "Seite \(candidate.pageNumber) wurde neu geprüft: \(result.status.displayName)."
                try? await fileLogger.log(
                    .info,
                    category: "Leerseitenanalyse",
                    message:
                        "Einzelseite gezielt neu geprüft; Seite=\(candidate.pageNumber); "
                        + "Status=\(result.status.rawValue).",
                    path: candidate.absolutePath
                )
                await refreshMaintenance()
                await refreshDocumentStatus()
            } catch is CancellationError {
                reportCancellation(
                    taskType: "Einzelne Leerseitenanalyse",
                    trigger: "Task ersetzt oder App-Lifecycle",
                    userInitiated: false,
                    pageNumber: candidate.pageNumber
                )
            } catch {
                report(error, taskType: "Einzelne Leerseitenanalyse")
            }
        }
    }

    func retryOCR(
        _ candidate: OCRReviewCandidate,
        configuration: OCRConfiguration? = nil
    ) {
        Task {
            await retryOCRPage(
                path: candidate.absolutePath,
                pageNumber: candidate.pageNumber,
                configuration: configuration
            )
        }
    }

    func retryOCR(_ candidates: [OCRReviewCandidate]) {
        guard !candidates.isEmpty else { return }
        Task {
            for candidate in candidates {
                guard !Task.isCancelled else { return }
                await retryOCRPage(
                    path: candidate.absolutePath,
                    pageNumber: candidate.pageNumber,
                    configuration: nil
                )
            }
        }
    }

    func retryOCR(
        _ candidates: [OCRReviewCandidate],
        configuration: OCRConfiguration
    ) {
        guard !candidates.isEmpty else { return }
        Task {
            for candidate in candidates {
                guard !Task.isCancelled else { return }
                await retryOCRPage(
                    path: candidate.absolutePath,
                    pageNumber: candidate.pageNumber,
                    configuration: configuration
                )
            }
        }
    }

    func confirmNotEmpty(_ candidates: [OCRReviewCandidate]) {
        guard !candidates.isEmpty else { return }
        Task {
            for candidate in candidates {
                try? await database.setPageReviewDecision(
                    path: candidate.absolutePath,
                    pageNumber: candidate.pageNumber,
                    decision: .notEmpty
                )
            }
            await refreshMaintenance()
            retryOCR(candidates)
        }
    }

    func savePageText(
        _ candidate: OCRReviewCandidate,
        text: String,
        kind: PageTextKind
    ) {
        guard !isMaintainingDocuments else { return }
        isMaintainingDocuments = true
        Task {
            defer { isMaintainingDocuments = false }
            do {
                try await processor.updatePageText(
                    path: candidate.absolutePath,
                    pageNumber: candidate.pageNumber,
                    text: text,
                    kind: kind
                )
                maintenanceMessage =
                    "\(kind.displayName) wurde lokal gespeichert und der Seitenindex gezielt aktualisiert."
                try? await fileLogger.log(
                    .info,
                    category: "OCR-Nachbearbeitung",
                    message: "Benutzergeprüfter Seitentext gespeichert und gezielt indexiert.",
                    path: candidate.absolutePath
                )
                await refreshMaintenance()
                await refreshDocumentStatus()
            } catch {
                report(error)
            }
        }
    }

    func resetManualPageText(_ candidate: OCRReviewCandidate) {
        guard let original = candidate.originalOCRText else { return }
        savePageText(candidate, text: original, kind: .automatic)
    }

    func resetPageReview(_ candidate: OCRReviewCandidate) {
        Task {
            do {
                try await database.resetPageReviewDecision(
                    path: candidate.absolutePath,
                    pageNumber: candidate.pageNumber
                )
                await refreshMaintenance()
            } catch {
                report(error)
            }
        }
    }

    private func retryOCRPage(
        path: String,
        pageNumber: Int,
        configuration: OCRConfiguration? = nil
    ) async {
        guard !isMaintainingDocuments, !isProcessing else { return }
        isMaintainingDocuments = true
        maintenanceMessage = "OCR wird automatisch nachbearbeitet …"
        defer { isMaintainingDocuments = false }
        do {
            let outcome = try await processor.retryOCRPage(
                path: path,
                pageNumber: pageNumber,
                configuration: configuration ?? ocrConfiguration
            ) { [weak self] attempt, total, strategy in
                await MainActor.run {
                    self?.maintenanceMessage =
                        "OCR wird verbessert · Versuch \(attempt) von \(total) · \(strategy.displayName)"
                }
            }
            let isPreview = configuration?.retryStrategyID != nil
            if let strategy = outcome.bestStrategyByPage[pageNumber] {
                if isPreview {
                    maintenanceMessage =
                        "OCR-Vorschau berechnet · \(strategy.displayName) · noch nicht übernommen"
                } else {
                    maintenanceMessage =
                        outcome.acceptedPageNumbers.contains(pageNumber)
                            ? "OCR verbessert · Beste Strategie: \(strategy.displayName)"
                            : "Automatische OCR-Nachbearbeitung ohne ausreichendes Ergebnis."
                }
            } else {
                maintenanceMessage =
                    "Automatische OCR-Nachbearbeitung ohne ausreichendes Ergebnis."
            }
            try? await fileLogger.log(
                outcome.acceptedPageNumbers.contains(pageNumber) ? .info : .warning,
                category: "OCR-Nachbearbeitung",
                message: isPreview
                    ? "Manuelle OCR-Vorschau ohne Übernahme berechnet."
                    : outcome.acceptedPageNumbers.contains(pageNumber)
                        ? "Automatische OCR-Nachbearbeitung erfolgreich abgeschlossen."
                        : "Automatische OCR-Nachbearbeitung ohne ausreichendes Ergebnis.",
                path: path
            )
            await refreshMaintenance()
            await refreshDocumentStatus()
        } catch {
            report(error)
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
                    "\(count) bestätigte leere PDF(s) wurden in den macOS-Papierkorb verschoben."
                try? await fileLogger.log(
                    .warning,
                    category: "Dokumentenwartung",
                    message: "Bestätigte leere PDFs in den Papierkorb verschoben: \(count)."
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
                FindoraError.processFailed(
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
        guard !isStorageMigrationInProgress else {
            answer = "Die Suche ist während der sicheren Speicherübertragung pausiert."
            return
        }
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

                let outcome = try await searchService.search(
                    value,
                    plan: plan,
                    contentFilter: searchContentFilter
                )
                let sources = outcome.directMatches
                searchResults = sources
                possibleSearchResults = outcome.possibleMatches
                if sources.isEmpty {
                    answer = "Keine ausreichend passenden Dokumente gefunden."
                } else if let answerGenerator {
                    isAnswerModelLoaded = true
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
        guard !source.absolutePath.isEmpty else { return }
        NSWorkspace.shared.open(URL(filePath: source.absolutePath))
    }

    func reveal(_ source: SearchSource) {
        guard !source.absolutePath.isEmpty else { return }
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

    func checkStatusValues() async {
        do {
            let report = try await database.checkStatusConsistency()
            statistics = report.statistics
            statusDiagnosticMessage = report.summary
            try await fileLogger.log(
                report.isConsistent ? .info : .warning,
                category: "Statusdiagnose",
                message: report.summary
            )
            if !report.isConsistent {
                try await database.recordError(
                    category: "Statusdiagnose",
                    message: report.summary
                )
            }
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
        let models = await modelManager.models(profile: hardwareProfile)
        for model in models where model.isInstalled {
            try? await database.registerInstalledModel(
                modelID: model.id,
                modelVersion: model.descriptor.modelVersion,
                kind: model.descriptor.kind,
                installedPath: model.directory.path,
                integrityCheckedAt: .now
            )
        }
        availableModels = models
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
                    throw FindoraError.processFailed("Das Modell ist nicht installiert.")
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
                        var coverage = try await database.embeddingCoverage(
                            modelID: model.id,
                            modelVersion: model.descriptor.modelVersion
                        )
                        if coverage.totalChunks > 0,
                           coverage.embeddedChunks == coverage.totalChunks {
                            modelMessage =
                                "Der vorhandene, passende Embedding-Index wird wiederverwendet."
                        } else {
                            modelMessage =
                                "Der neue Embedding-Index wird aufgebaut; die bisherige Suche bleibt bis zum Abschluss erhalten."
                            try await processor.rebuildSearchIndex { _ in }
                            coverage = try await database.embeddingCoverage(
                                modelID: model.id,
                                modelVersion: model.descriptor.modelVersion
                            )
                        }
                        guard coverage.embeddedChunks == coverage.totalChunks else {
                            throw FindoraError.processFailed(
                                "Neuindexierung unvollständig (\(coverage.embeddedChunks) von \(coverage.totalChunks) Chunks)."
                            )
                        }
                        try await modelManager.activate(modelID: model.id)
                        activeEmbeddingModelID = model.id
                        isEmbeddingModelLoaded = true
                        searchService = HybridSearchService(
                            database: database,
                            embedder: provider,
                            semanticEnabled: true
                        )
                        try await database.setModelEnabled(
                            modelID: model.id,
                            modelVersion: model.descriptor.modelVersion,
                            kind: .embedding
                        )
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
                    isAnswerModelLoaded = true
                    try await database.setModelEnabled(
                        modelID: model.id,
                        modelVersion: model.descriptor.modelVersion,
                        kind: .answer
                    )
                    try await database.setSetting(key: "activeAnswerModelID", value: model.id)
                    modelMessage = "Antwortmodell wurde getestet und aktiviert."
                }
                await refreshModels()
            } catch {
                report(error)
            }
        }
    }

    func deactivateModel(_ model: InstalledModel) {
        Task {
            do {
                switch model.descriptor.kind {
                case .answer:
                    guard activeAnswerModelID == model.id else { return }
                    await unloadAnswerModel(reason: "Vom Benutzer deaktiviert")
                    answerGenerator = nil
                    activeAnswerModelID = nil
                    await modelManager.deactivate(kind: .answer)
                    try await database.setModelEnabled(
                        modelID: nil,
                        modelVersion: nil,
                        kind: .answer
                    )
                    try await database.setSetting(
                        key: "activeAnswerModelID",
                        value: ""
                    )
                    modelMessage =
                        "Antwortmodell deaktiviert. Suche und regelbasierte Suchplanung bleiben verfügbar."
                case .embedding:
                    guard activeEmbeddingModelID == model.id else { return }
                    let fallback = TokenHashEmbedding()
                    processor = makeProcessor(embedder: fallback)
                    searchService = HybridSearchService(
                        database: database,
                        embedder: fallback,
                        semanticEnabled: false
                    )
                    activeEmbeddingModelID = nil
                    isEmbeddingModelLoaded = false
                    await modelManager.deactivate(kind: .embedding)
                    try await database.setModelEnabled(
                        modelID: nil,
                        modelVersion: nil,
                        kind: .embedding
                    )
                    try await database.setSetting(
                        key: "activeEmbeddingModelID",
                        value: ""
                    )
                    modelMessage =
                        "Embedding-Modell deaktiviert. Die Volltextsuche bleibt aktiv; vorhandene Embeddings wurden nicht gelöscht."
                }
                await refreshModels()
            } catch {
                report(error, taskType: "Modell deaktivieren")
            }
        }
    }

    func testModel(_ model: InstalledModel) {
        Task {
            do {
                guard let directory = await modelManager.installedDirectory(modelID: model.id) else {
                    throw FindoraError.processFailed("Das Modell ist nicht installiert.")
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
                    isAnswerModelLoaded = false
                    try await database.setModelEnabled(
                        modelID: nil,
                        modelVersion: nil,
                        kind: .answer
                    )
                    try await database.setSetting(key: "activeAnswerModelID", value: "")
                }
                if model.descriptor.kind == .embedding, activeEmbeddingModelID == model.id {
                    let fallback = TokenHashEmbedding()
                    processor = makeProcessor(embedder: fallback)
                    searchService = HybridSearchService(
                        database: database,
                        embedder: fallback,
                        semanticEnabled: false
                    )
                    activeEmbeddingModelID = nil
                    isEmbeddingModelLoaded = false
                    try await database.setModelEnabled(
                        modelID: nil,
                        modelVersion: nil,
                        kind: .embedding
                    )
                    try await database.setSetting(key: "activeEmbeddingModelID", value: "")
                }
                try await modelManager.remove(modelID: model.id)
                try await database.removeModelState(
                    modelID: model.id,
                    modelVersion: model.descriptor.modelVersion
                )
                modelMessage = "Das Modell wurde in den Papierkorb verschoben."
                await refreshModels()
            } catch {
                report(error)
            }
        }
    }

    func exportLog() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Findora-Protokoll.txt"
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
            let storedStates = try await database.modelStates()
            let storedEmbeddingID = storedStates.first {
                $0.kind == .embedding && $0.enabled
            }?.modelID
            let storedAnswerID = storedStates.first {
                $0.kind == .answer && $0.enabled
            }?.modelID
            let legacyEmbeddingID = try await database.setting(
                key: "activeEmbeddingModelID"
            )
            let embeddingID = storedEmbeddingID ?? legacyEmbeddingID
            if let embeddingID, !embeddingID.isEmpty,
               let descriptor = await modelManager.descriptor(id: embeddingID),
               let directory = await modelManager.installedDirectory(modelID: embeddingID) {
                let provider = MLXEmbeddingProvider(
                    modelID: embeddingID,
                    modelVersion: descriptor.modelVersion,
                    directory: directory
                )
                try await modelManager.activate(modelID: embeddingID)
                processor = makeProcessor(embedder: provider)
                searchService = HybridSearchService(
                    database: database,
                    embedder: provider,
                    semanticEnabled: true
                )
                activeEmbeddingModelID = embeddingID
                isEmbeddingModelLoaded = true
                try await database.setModelEnabled(
                    modelID: embeddingID,
                    modelVersion: descriptor.modelVersion,
                    kind: .embedding
                )
            }
            let legacyAnswerID = try await database.setting(
                key: "activeAnswerModelID"
            )
            let answerID = storedAnswerID ?? legacyAnswerID
            if let answerID, !answerID.isEmpty,
               let descriptor = await modelManager.descriptor(id: answerID),
               let directory = await modelManager.installedDirectory(modelID: answerID) {
                answerGenerator = MLXAnswerGenerator(
                    directory: directory,
                    contextLength: descriptor.defaultContextLength,
                    idleTimeout: .seconds(llmIdleMinutes * 60)
                )
                try await modelManager.activate(modelID: answerID)
                activeAnswerModelID = answerID
                isAnswerModelLoaded = false
                try await database.setModelEnabled(
                    modelID: answerID,
                    modelVersion: descriptor.modelVersion,
                    kind: .answer
                )
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
            if let value = try await database.setting(key: "interfaceLanguage"),
               let language = InterfaceLanguage(rawValue: value) {
                interfaceLanguage = language
            }
            if let value = try await database.setting(key: "interfaceAppearance"),
               let appearance = InterfaceAppearance(rawValue: value) {
                interfaceAppearance = appearance
            }
            if let value = try await database.setting(key: "removedDocumentPolicy"),
               let policy = RemovedDocumentPolicy(rawValue: value) {
                removedDocumentPolicy = policy
            }
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
            "FINDORA_SIMULATE_MEMORY_PRESSURE"
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
        isAnswerModelLoaded = false
    }

    private func beginProcessingSession(
        phase: ProcessingSessionPhase,
        total: Int = 0
    ) async {
        let session = ProcessingSessionSnapshot(
            phase: phase,
            total: total,
            isPaused: false
        )
        processingSession = session
        try? await database.saveProcessingSession(session)
    }

    private func updateProcessingSession(
        phase: ProcessingSessionPhase? = nil,
        total: Int? = nil,
        completed: Int? = nil,
        failed: Int? = nil,
        currentFile: String? = nil
    ) async {
        guard var session = processingSession else { return }
        if let phase { session.phase = phase }
        if let total { session.total = max(session.total, total) }
        if let completed { session.completed = max(session.completed, completed) }
        if let failed { session.failed = max(session.failed, failed) }
        session.currentFile = currentFile
        processingSession = session
        try? await database.saveProcessingSession(session)
    }

    private func finishProcessingSession(
        phase: ProcessingSessionPhase
    ) async {
        guard var session = processingSession else { return }
        session.phase = phase
        session.currentFile = nil
        session.isPaused = false
        session.finishedAt = .now
        if phase == .completed, session.total > 0 {
            session.completed = max(
                session.completed,
                max(0, session.total - session.failed)
            )
        }
        processingSession = session
        try? await database.saveProcessingSession(session)
        let sessionID = session.id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self,
                  self.processingSession?.id == sessionID,
                  self.processingSession?.phase.isActive == false else {
                return
            }
            self.processingSession = nil
        }
    }

    private func reportCancellation(
        taskType: String,
        trigger: String,
        userInitiated: Bool,
        documentID: String? = nil,
        pageNumber: Int? = nil,
        strategy: String? = nil
    ) {
        if userInitiated {
            maintenanceMessage = "Vorgang abgebrochen"
        }
        Task {
            try? await fileLogger.log(
                .info,
                category: "Abbruch",
                message:
                    "Task=\(taskType); Dokument-ID=\(documentID ?? "—"); "
                    + "Seite=\(pageNumber.map(String.init) ?? "—"); "
                    + "Strategie=\(strategy ?? "—"); Auslöser=\(trigger); "
                    + "erwartet=true; Benutzeraktion=\(userInitiated); "
                    + "Reset=\(trigger.localizedCaseInsensitiveContains("reset")); "
                    + "Retry-Wechsel=\(trigger.localizedCaseInsensitiveContains("retry")); "
                    + "App-Lifecycle=\(trigger.localizedCaseInsensitiveContains("lifecycle"))."
            )
        }
    }

    private func report(
        _ error: Error,
        taskType: String = #function,
        userInitiatedCancellation: Bool = false
    ) {
        let classification = AppErrorClassifier.classify(
            error,
            userInitiatedCancellation: userInitiatedCancellation
        )
        if classification.category == .cancelled
            || classification.category == .userCancelled {
            reportCancellation(
                taskType: taskType,
                trigger: userInitiatedCancellation
                    ? "Benutzerabbruch"
                    : "interner Task-Abbruch",
                userInitiated: userInitiatedCancellation
            )
            return
        }
        if classification.category == .requiresAttention
            || classification.category == .fatal {
            lastError = classification.userMessage
        } else {
            maintenanceMessage = classification.userMessage
        }
        Task {
            try? await fileLogger.log(
                classification.category == .recoverable ? .warning : .error,
                category: "Fehlerklassifikation",
                message:
                    "Task=\(taskType); Kategorie=\(classification.category.rawValue); "
                    + classification.technicalMessage
            )
            try? await database.recordError(
                category: classification.category.rawValue,
                message: classification.technicalMessage
            )
            await refreshDatabaseState()
        }
    }
}

struct ContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        Group {
            if state.dataStorageAvailable {
                NavigationSplitView {
                    FindoraSidebar(selection: $state.selectedSection)
                } detail: {
                    Group {
                        switch state.selectedSection ?? .search {
                        case .search: SearchView()
                        case .mail: MailSourcesView()
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
            } else {
                MissingDataStorageView()
                    .environment(state)
            }
        }
        .alert(
            "Findora",
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
            SourcePreview(source: source)
        }
        .sheet(item: $state.pendingMailImport) { pending in
            MailImportConfirmationView(importRequest: pending)
        }
        .sheet(item: $state.pendingStorageChange) { change in
            StorageMigrationConfirmationView(change: change)
        }
        .sheet(isPresented: $state.showsAbout) {
            FindoraAboutView(
                isEnglish: state.interfaceLocale.language.languageCode?
                    .identifier == "en"
            )
        }
    }
}

struct MissingDataStorageView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ContentUnavailableView {
            Label("Findora-Datenspeicher nicht erreichbar", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            VStack(spacing: 8) {
                Text("Es wurde keine neue leere Datenbank angelegt.")
                Text("Erwarteter Speicherort:")
                Text(state.dataStoragePath)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        } actions: {
            Button("Datenträger erneut prüfen") {
                state.retryConfiguredDataStorage()
            }
            .buttonStyle(.borderedProminent)
            Button("Anderen Speicherort zuordnen …") {
                state.reconnectConfiguredStorage(kind: .data)
            }
        }
    }
}

private struct FindoraSidebar: View {
    @Binding var selection: AppSection?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Findora")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Divider()

            List(selection: $selection) {
                sidebarSection([.search, .mail])
                sidebarSection([.status, .maintenance])
                sidebarSection([.ocr, .models])
                sidebarSection([.settings, .logs])
            }
            .listStyle(.sidebar)
        }
        .navigationSplitViewColumnWidth(min: 245, ideal: 255, max: 280)
        .accessibilityLabel("Findora-Navigation")
    }

    @ViewBuilder
    private func sidebarSection(_ sections: [AppSection]) -> some View {
        Section {
            ForEach(sections) { section in
                Label(
                    LocalizedStringKey(section.rawValue),
                    systemImage: section.symbol
                )
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                .contentShape(Rectangle())
                .tag(section)
                .listRowInsets(
                    EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12)
                )
                .accessibilityLabel(LocalizedStringKey(section.rawValue))
            }
        }
    }
}

private struct FindoraAboutView: View {
    @Environment(\.dismiss) private var dismiss
    let isEnglish: Bool

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "—"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
            as? String ?? "—"
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Findora")
                .font(.largeTitle.bold())
            Text("Version \(version) · Build \(build)")
                .foregroundStyle(.secondary)
            Text(
                isEnglish
                    ? "Documents, OCR, search, and AI analysis are processed locally on this Mac."
                    : "Dokumente, OCR, Suche und KI-Auswertung werden lokal auf diesem Mac verarbeitet."
            )
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)
            Label(
                isEnglish ? "No telemetry" : "Keine Telemetrie",
                systemImage: "hand.raised.fill"
            )
                .foregroundStyle(.secondary)
            Button(isEnglish ? "Close" : "Schließen") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(32)
        .frame(minWidth: 440)
        .accessibilityElement(children: .contain)
    }
}

struct MailSourcesView: View {
    @Environment(AppState.self) private var state
    @State private var pendingRemoval: MailImportSource?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("E-Mail-Import").font(.title2.bold())
                        Text("Manuell ausgewählte Exporte werden ausschließlich lokal verarbeitet.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Aktualisieren") {
                        Task { await state.refreshMailSources() }
                    }
                }

                HStack {
                    Button("Apple-Mail-Postfach (.mbox) …") {
                        state.chooseMailFiles(format: .mbox)
                    }
                    Button("E-Mail-Dateien (.eml) …") {
                        state.chooseMailFiles(format: .eml)
                    }
                    Button("Outlook-Nachrichten (.msg) …") {
                        state.chooseMailFiles(format: .outlookMSG)
                    }
                    Button("Importordner …") {
                        state.chooseMailImportFolder()
                    }
                }
                .disabled(state.isMailImporting || state.isStorageMigrationInProgress)

                if let progress = state.mailImportProgress, state.isMailImporting {
                    GroupBox("Import läuft") {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(
                                value: Double(progress.processed),
                                total: Double(max(progress.total ?? progress.processed + 1, 1))
                            )
                            Text(
                                "\(progress.processed) von \(progress.total.map(String.init) ?? "…") · "
                                + "\(progress.imported) neu · \(progress.duplicates) Dubletten · \(progress.failed) Fehler"
                            )
                            .font(.caption)
                            if let subject = progress.currentSubject {
                                Text(subject).lineLimit(1).foregroundStyle(.secondary)
                            }
                            HStack {
                                Button("Pausieren") { state.setMailImportPaused(true) }
                                Button("Fortsetzen") { state.setMailImportPaused(false) }
                                Button("Abbrechen", role: .destructive) {
                                    state.cancelMailImport()
                                }
                            }
                        }
                    }
                }

                if let message = state.mailImportMessage {
                    Label(message, systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }

                if state.mailSources.isEmpty {
                    ContentUnavailableView(
                        "Keine E-Mail-Quelle eingerichtet",
                        systemImage: "envelope.badge",
                        description: Text(
                            "Sie können Apple-Mail-Postfächer, Outlook-Nachrichten oder einen Importordner manuell hinzufügen."
                        )
                    )
                    .frame(maxWidth: .infinity, minHeight: 280)
                } else {
                    ForEach(state.mailSources) { source in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(source.displayName).font(.headline)
                                    Spacer()
                                    SearchBadge(
                                        text: source.status.displayName,
                                        color: source.status == .available
                                            || source.status == .archivedCopyAvailable
                                            ? .green : .orange
                                    )
                                }
                                Text(source.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                Grid(alignment: .leading, horizontalSpacing: 20) {
                                    GridRow {
                                        Text("Typ").foregroundStyle(.secondary)
                                        Text(source.format.displayName)
                                        Text("Modus").foregroundStyle(.secondary)
                                        Text(source.importMode.displayName)
                                    }
                                    GridRow {
                                        Text("Nachrichten").foregroundStyle(.secondary)
                                        Text(source.messageCount.formatted())
                                        Text("Anhänge").foregroundStyle(.secondary)
                                        Text(source.attachmentCount.formatted())
                                    }
                                }
                                if source.format == .importFolder {
                                    Toggle(
                                        "Ordner auf neue E-Mail-Dateien überwachen",
                                        isOn: Binding(
                                            get: { source.watchEnabled },
                                            set: { state.setMailSourceWatch(source, enabled: $0) }
                                        )
                                    )
                                }
                                HStack {
                                    Button("Jetzt erneut einlesen") {
                                        state.synchronizeMailSource(source)
                                    }
                                    Button("Quelle im Finder anzeigen") {
                                        state.revealMailSource(source)
                                    }
                                    Button("Quelle neu zuordnen") {
                                        state.reassignMailSource(source)
                                    }
                                    Button("Quelle entfernen", role: .destructive) {
                                        pendingRemoval = source
                                    }
                                    Spacer()
                                    if let date = source.lastSynchronizedAt {
                                        Text("Letzter Abgleich: \(date.formatted())")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle(state.localizedSectionTitle(.mail))
        .confirmationDialog(
            "E-Mail-Quelle entfernen?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            )
        ) {
            Button("Quellenzuordnung entfernen", role: .destructive) {
                if let source = pendingRemoval {
                    state.removeMailSource(source)
                }
                pendingRemoval = nil
            }
            Button("Abbrechen", role: .cancel) {
                pendingRemoval = nil
            }
        } message: {
            Text(
                "Indexierte E-Mails und archivierte Originale bleiben erhalten. Quelldateien werden nicht verändert."
            )
        }
    }
}

struct MailImportConfirmationView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let importRequest: PendingMailImport
    @State private var mode: MailImportMode
    @State private var watchFolders: Bool

    init(importRequest: PendingMailImport) {
        self.importRequest = importRequest
        _mode = State(initialValue: importRequest.mode)
        _watchFolders = State(initialValue: importRequest.watchFolders)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("E-Mail-Import bestätigen").font(.title2.bold())
            Text("Vor dieser Bestätigung werden keine E-Mail-Inhalte verarbeitet.")
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("Ausgewählte Quellen")
                    Text(importRequest.estimate.sourceCount.formatted())
                }
                GridRow {
                    Text("Erkannte Dateien")
                    Text(importRequest.estimate.estimatedMessages?.formatted() ?? "Unbekannt")
                }
                GridRow {
                    Text("Quellgröße")
                    Text(bytes(importRequest.estimate.sourceBytes))
                }
                GridRow {
                    Text("Zusätzlicher Speicher (Schätzung)")
                    Text(bytes(importRequest.estimate.estimatedAdditionalBytes))
                }
            }
            Picker("Importmodus", selection: $mode) {
                ForEach(MailImportMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .onChange(of: mode) { _, value in
                state.updatePendingMailImportMode(value)
            }
            Toggle("Importordner nach neuen Dateien überwachen", isOn: $watchFolders)
                .onChange(of: watchFolders) { _, value in
                    state.setPendingMailWatch(value)
                }
            Text("Die Ordnerüberwachung ist standardmäßig aus. Quelldateien werden niemals automatisch gelöscht oder verschoben.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Abbrechen") {
                    state.pendingMailImport = nil
                    dismiss()
                }
                Button("Import starten") {
                    state.confirmMailImport()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

struct StorageMigrationConfirmationView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let change: PendingStorageChange

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(change.kind.displayName) sicher übertragen")
                .font(.title2.bold())
            Text(change.destinationParent.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow {
                    Text("Dateien")
                    Text(change.estimate.fileCount.formatted())
                }
                GridRow {
                    Text("Zu kopieren")
                    Text(bytes(change.estimate.totalBytes))
                }
                GridRow {
                    Text("Freier Speicher")
                    Text(
                        change.estimate.assessment.availableBytes.map(bytes)
                            ?? "Nicht zuverlässig ermittelbar"
                    )
                }
                GridRow {
                    Text("Dateisystem")
                    Text(change.estimate.assessment.fileSystemDescription)
                }
            }
            ForEach(change.estimate.assessment.blockingReasons, id: \.self) {
                Label($0, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            }
            ForEach(change.estimate.assessment.warnings, id: \.self) {
                Label($0, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Text(
                "Findora pausiert Verarbeitung und Suche, checkpointet SQLite, kopiert zunächst in einen Staging-Ordner, prüft Größen, SHA-256 und Datenbankintegrität und schaltet erst danach um. Der alte Bestand bleibt erhalten."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Abbrechen") {
                    state.pendingStorageChange = nil
                    dismiss()
                }
                Button("Daten sicher übertragen") {
                    state.confirmStorageMigration()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!change.estimate.assessment.isAllowed)
            }
        }
        .padding(24)
        .frame(width: 620)
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
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
                                    Text("Findora:").font(.caption.bold())
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
                                Label("Findora", systemImage: "sparkles")
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
                                        guard url.scheme == "findora",
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

            VStack(spacing: 8) {
                Picker("Inhalt", selection: $state.searchContentFilter) {
                    ForEach(SearchContentFilter.allCases) { filter in
                        Text(filter.displayName).tag(filter)
                    }
                }
                .pickerStyle(.segmented)

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
            }
            .padding()
        }
        .navigationTitle(state.localizedSectionTitle(.search))
    }

    private func markdown(_ value: String) -> AttributedString {
        var linked = value
        for index in state.searchResults.indices.reversed() {
            linked = linked.replacingOccurrences(
                of: "[\(index + 1)]",
                with: "[\(index + 1)](findora://source/\(index + 1))"
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
                    SearchBadge(text: source.contentType.displayName, color: .indigo)
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
                    if source.contentType == .pdf {
                        Label("Seite \(source.pageNumber)", systemImage: "doc.text")
                            .font(.caption)
                    } else if let date = source.mailDate {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                    }
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
                    Button(source.contentType == .pdf ? "Seite anzeigen" : "Quelle anzeigen") {
                        state.showPage(source)
                    }
                    if !source.absolutePath.isEmpty {
                        Button(source.contentType == .pdf ? "PDF öffnen" : "Original öffnen") {
                            state.open(source)
                        }
                        Button("Im Finder anzeigen") { state.reveal(source) }
                    }
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
            if source.contentType == .pdf {
                SearchBadge(
                    text: source.textSource == "ocr" ? "OCR-Text" : "Digitale Textschicht",
                    color: .secondary
                )
            }
            if let sender = source.mailSender, !sender.isEmpty {
                SearchBadge(text: "Von: \(sender)", color: .teal)
            }
            if let parent = source.parentEmailSubject, !parent.isEmpty {
                SearchBadge(text: "Mail: \(parent)", color: .cyan)
            }
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

struct SourcePreview: View {
    let source: SearchSource

    var body: some View {
        if source.contentType == .pdf {
            PDFSourcePreview(source: source)
        } else {
            MailSourcePreview(source: source)
        }
    }
}

struct MailSourcePreview: View {
    @Environment(\.dismiss) private var dismiss
    let source: SearchSource

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(source.contentType.displayName, systemImage: "envelope")
                    .font(.headline)
                Spacer()
                Button("Schließen") { dismiss() }
            }
            Text(source.mailSubject ?? source.fileName)
                .font(.title2.bold())
            if let sender = source.mailSender ?? source.parentEmailSender {
                LabeledContent("Absender", value: sender)
            }
            if let date = source.mailDate ?? source.parentEmailDate {
                LabeledContent("Datum", value: date.formatted())
            }
            if let mailbox = source.mailbox {
                LabeledContent("Mailbox / Quelle", value: mailbox)
            }
            if let parent = source.parentEmailSubject {
                LabeledContent("Zugehörige E-Mail", value: parent)
            }
            Divider()
            ScrollView {
                Text(source.excerpt)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            HStack {
                if !source.absolutePath.isEmpty {
                    Button("Original öffnen") {
                        NSWorkspace.shared.open(URL(filePath: source.absolutePath))
                    }
                    Button("Im Finder anzeigen") {
                        NSWorkspace.shared.activateFileViewerSelecting([
                            URL(filePath: source.absolutePath)
                        ])
                    }
                }
                Spacer()
            }
        }
        .padding(24)
        .frame(minWidth: 680, minHeight: 480)
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
                        if let documentFolderPath = state.documentFolderPath {
                            Text(documentFolderPath)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        } else {
                            Text("Nicht ausgewählt")
                                .foregroundStyle(.secondary)
                        }
                        Label(
                            LocalizedStringKey(state.folderStatus),
                            systemImage: state.folderStatus == "Erreichbar"
                                ? "checkmark.circle.fill"
                                : "exclamationmark.triangle.fill"
                        )
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

                if let session = state.processingSession, session.phase.isVisible {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: session.progressFraction)
                            HStack {
                                Text(
                                    "\(session.completed) von \(session.total) PDFs verarbeitet"
                                )
                                Spacer()
                                Text(
                                    session.progressFraction,
                                    format: .percent.precision(.fractionLength(0))
                                )
                                .monospacedDigit()
                            }
                            if session.failed > 0 {
                                Text("\(session.failed) fehlgeschlagen")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            Text("Aktuell:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let currentFile =
                                session.currentFile ?? state.statistics.currentFile {
                                Text(currentFile).font(.headline)
                            } else {
                                Text(processingFallback(for: session))
                                    .font(.headline)
                            }
                            if let step = state.statistics.currentStep {
                                Text(step)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } label: {
                        Text(processingTitle(for: session))
                    }
                }

                DisclosureGroup(
                    "Technische Details",
                    isExpanded: $showsTechnicalDetails
                ) {
                    VStack(alignment: .leading, spacing: 14) {
                        TechnicalMetricGroup(
                            title: "Dokumente",
                            metrics: documentMetrics
                        )
                        TechnicalMetricGroup(
                            title: "Texterkennung",
                            metrics: textRecognitionMetrics
                        )
                        TechnicalMetricGroup(
                            title: "Suche und Index",
                            metrics: searchIndexMetrics
                        )
                        TechnicalMetricGroup(
                            title: "Wartung",
                            metrics: maintenanceMetrics
                        )
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                            GridRow {
                                Text("OCR-Engine").foregroundStyle(.secondary)
                                Text(state.statistics.currentOCREngine ?? "—")
                            }
                            GridRow {
                                Text("Embedding-Modell").foregroundStyle(.secondary)
                                if let modelID = state.activeEmbeddingModelID {
                                    Text(modelID)
                                } else {
                                    Text("Fallback (nicht neuronal)")
                                }
                            }
                            GridRow {
                                Text("Embedding-Version").foregroundStyle(.secondary)
                                if let version = state.activeEmbeddingModelVersion {
                                    Text(version)
                                } else {
                                    Text("Integriert")
                                }
                            }
                            GridRow {
                                Text("Indexzustand").foregroundStyle(.secondary)
                                Text(
                                    state.hasMixedEmbeddingIndex
                                        ? LocalizedStringKey("Gemischte Embeddings")
                                        : LocalizedStringKey("Konsistent")
                                )
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
        .navigationTitle(state.localizedSectionTitle(.status))
    }

    private func processingTitle(
        for session: ProcessingSessionSnapshot
    ) -> LocalizedStringKey {
        if session.isPaused || session.phase == .paused {
            return "Verarbeitung pausiert"
        }
        return switch session.phase {
        case .scanning: "Dokumente werden gescannt"
        case .ocr: "OCR läuft"
        case .indexing: "Indexierung läuft"
        case .rebuildingSearch: "Suchindex wird neu aufgebaut"
        case .resettingAnalysis: "OCR und Analysen werden zurückgesetzt"
        case .cancelling: "Verarbeitung wird beendet"
        case .completed: "Verarbeitung abgeschlossen"
        case .failed: "Verarbeitung mit Fehler beendet"
        case .idle, .paused: "Dokumentenverarbeitung"
        }
    }

    private func processingFallback(
        for session: ProcessingSessionSnapshot
    ) -> LocalizedStringKey {
        switch session.phase {
        case .scanning: "Ordner wird gescannt …"
        case .completed: "Alle geplanten Arbeitsschritte sind abgeschlossen."
        case .failed: "Der letzte Arbeitsschritt konnte nicht abgeschlossen werden."
        default: "Nächstes Dokument wird vorbereitet …"
        }
    }

    private var documentMetrics: [TechnicalStatusMetric] {
        let statistics = state.statistics
        return [
            .init("PDFs insgesamt", statistics.totalPDFs, "PDFs",
                  "Aktuelle PDF-Pfade im letzten Scan, einschließlich derzeit nicht verfügbarer Dateien."),
            .init("Indexiert", statistics.indexedPDFs, "PDFs",
                  "Aktuelle PDF-Pfade mit erfolgreich abgeschlossenem Datenbankindex."),
            .init("In Warteschlange", statistics.pendingJobs, "Jobs",
                  "Aktuelle PDF-Jobs, die erkannt wurden, auf Stabilität warten oder auf OCR warten."),
            .init("In Bearbeitung", statistics.processingJobs, "Jobs",
                  "Aktuelle PDF-Jobs in Extraktion, OCR oder Indexierung."),
            .init("Pausiert", statistics.pausedJobs, "Jobs",
                  "Overlay: wartende oder laufende Jobs bei global pausierter Verarbeitung; nicht zur Zustandssumme addieren."),
            .init("Übersprungen", statistics.skippedJobs, "frühere Jobs",
                  "Nicht mehr im aktuellen Scan vorhandene, aus dem aktiven Bestand ausgeschlossene Jobs."),
            .init("Technische Fehler", statistics.failedJobs, "Jobs",
                  "Aktuelle PDF-Jobs, deren letzter Verarbeitungslauf fehlgeschlagen ist."),
            .init("Fehlende Dateien", statistics.missingOrMovedFiles, "Pfade",
                  "Nicht verfügbare aktuelle oder seit dem letzten Scan entfernte PDF-Pfade."),
            .init("Duplikate", statistics.duplicateLocations, "PDF-Pfade",
                  "Zusätzliche aktuelle PDF-Pfade mit demselben SHA-256-Inhalt.")
        ]
    }

    private var textRecognitionMetrics: [TechnicalStatusMetric] {
        let statistics = state.statistics
        return [
            .init("Bereits vollständig durchsuchbar", statistics.fullySearchablePDFs, "PDFs",
                  "Indexierte PDFs mit bereits vorhandenem verwertbarem PDF-Text und ohne verwendeten OCR-Text."),
            .init("Durch OCR ergänzt", statistics.ocrSupplementedPDFs, "PDFs",
                  "Indexierte PDFs, bei denen mindestens eine Seite verwertbaren OCR-Text liefert."),
            .init("Ohne verwertbaren Text", statistics.indexedWithoutUsableTextPDFs, "PDFs",
                  "Indexierte PDFs ohne nichtleeren PDF-, OCR- oder manuellen Seitentext."),
            .init("Weitere indexierte Sonderfälle", statistics.otherIndexedPDFs, "PDFs",
                  "Indexierte PDFs mit ausschließlich manuellem oder älterem nicht eindeutig zuordenbarem Text."),
            .init("OCR erforderlich – PDFs", statistics.ocrRequiredPDFs, "PDFs",
                  "Noch nicht abgeschlossene PDF-Jobs, die auf OCR warten oder gerade OCR ausführen."),
            .init("OCR fehlgeschlagen – PDFs", statistics.ocrFailedPDFs, "PDFs",
                  "Nicht indexierte PDF-Jobs, deren letzter fehlgeschlagener Schritt OCR war."),
            .init("Seiten mit PDF-Text", statistics.pagesWithPDFText, "Seiten",
                  "Seiten aktueller indexierter PDFs mit verwertbarem eingebettetem PDF-Text."),
            .init("Seiten mit OCR-Text", statistics.pagesWithOCRText, "Seiten",
                  "Seiten aktueller indexierter PDFs mit verwertbarem OCR-Text; Retry-Versuche zählen nicht."),
            .init("Seiten mit manuellem Text", statistics.pagesWithManualText, "Seiten",
                  "Seiten aktueller indexierter PDFs mit manuell korrigiertem oder erfasstem Text."),
            .init("Seiten ohne verwertbaren Text", statistics.pagesWithoutUsableText, "Seiten",
                  "Seiten aktueller indexierter PDFs ohne nichtleeren gespeicherten Text."),
            .init("OCR erfolgreich – Seiten", statistics.ocrQualityGoodPages, "Seiten",
                  "OCR-Seiten, deren gespeichertes Ergebnis die Qualitätsprüfung bestanden hat."),
            .init("OCR-Seiten zur Prüfung", statistics.ocrQualityReviewPages, "Seiten",
                  "OCR-Seiten mit gespeichertem Ergebnis, das die Qualitätsprüfung zur Kontrolle markiert hat."),
            .init("OCR wahrscheinlich fehlgeschlagen", statistics.ocrQualityFailedPages, "Seiten",
                  "OCR-Seiten, deren Qualitätsprüfung ein wahrscheinlich unbrauchbares Ergebnis meldet.")
        ]
    }

    private var searchIndexMetrics: [TechnicalStatusMetric] {
        let statistics = state.statistics
        return [
            .init("Chunks", statistics.totalChunks, "Textabschnitte",
                  "Aktuelle suchbare Textabschnitte eindeutiger Dokumentinhalte."),
            .init("Embeddings gesamt", statistics.embeddedChunks, "Vektoren",
                  "Persistierte Embedding-Vektoren für aktuelle Chunks; mehrere Modelltypen pro Chunk zählen getrennt."),
            .init("E5-Embeddings", statistics.e5EmbeddedChunks, "Vektoren",
                  "Persistierte Embedding-Vektoren eines E5-Modells."),
            .init("Fallback-Embeddings", statistics.fallbackEmbeddedChunks, "Vektoren",
                  "Persistierte deterministische Token-Hash-Fallback-Vektoren."),
            .init("Weitere Embeddings", statistics.otherEmbeddedChunks, "Vektoren",
                  "Persistierte Vektoren anderer, ausdrücklich separat klassifizierter Modelle.")
        ]
    }

    private var maintenanceMetrics: [TechnicalStatusMetric] {
        let statistics = state.statistics
        return [
            .init("Zu prüfende leere Seiten", statistics.emptyPageCandidates, "Seiten",
                  "Aktuelle Seiten mit automatischer Leer- oder Unsicherheitsklassifikation ohne abschließende Entscheidung."),
            .init("Bestätigte leere PDFs", statistics.fullyEmptyPDFs, "PDFs",
                  "PDFs, deren sämtliche Seiten aktuell als leer klassifiziert sind."),
            .init("Sicher leere Seiten", statistics.safelyEmptyPages, "Seiten",
                  "Aktuelle Seiten mit hoher automatischer Leer-Konfidenz."),
            .init("Vermutlich leere Seiten", statistics.probablyEmptyPages, "Seiten",
                  "Aktuelle Seiten mit unsicherer automatischer Leer-Klassifikation."),
            .init("OCR-Nachbearbeitung aktiv", statistics.ocrRetryingPages, "Jobs",
                  "Aktuelle OCR-Jobs mit mindestens einem dokumentierten Retry-Fortschritt."),
            .init("OCR-Prüffälle – Seiten", statistics.ocrReviewPages, "Seiten",
                  "Aktuelle Seiten mit fachlichem OCR-Prüfbedarf."),
            .init("Manuell als nicht leer bestätigt", statistics.manuallyNotEmptyPages, "Seiten",
                  "Aktuelle Seiten mit manueller Entscheidung, dass Inhalt vorhanden ist."),
            .init("OCR ohne Ergebnis – Seiten", statistics.ocrNoResultPages, "Seiten",
                  "Aktuelle Seiten, für die OCR keinen verwertbaren Text geliefert hat."),
            .init("Manuell korrigierte Seiten", statistics.manuallyCorrectedPages, "Seiten",
                  "Aktuelle Seiten mit manuell korrigiertem OCR-Text."),
            .init("Manuell erfasste Seiten", statistics.manuallyEnteredPages, "Seiten",
                  "Aktuelle Seiten mit vollständig manuell erfasstem Text.")
        ]
    }
}

struct MetricCard: View {
    let title: String
    let value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(title)).foregroundStyle(.secondary)
            Text(value.formatted()).font(.title.bold())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct TechnicalStatusMetric: Identifiable {
    let title: String
    let value: Int
    let unit: String
    let explanation: String

    var id: String { title }

    init(_ title: String, _ value: Int, _ unit: String, _ explanation: String) {
        self.title = title
        self.value = value
        self.unit = unit
        self.explanation = explanation
    }
}

private struct TechnicalMetricGroup: View {
    let title: String
    let metrics: [TechnicalStatusMetric]
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(
            isExpanded: $isExpanded
        ) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 205))],
                spacing: 10
            ) {
                ForEach(metrics) { metric in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(LocalizedStringKey(metric.title))
                            .foregroundStyle(.secondary)
                        Text(metric.value.formatted())
                            .font(.title2.bold())
                            .monospacedDigit()
                        Text(LocalizedStringKey(metric.unit))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(
                        .background.secondary,
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                    .help(Text(LocalizedStringKey(metric.explanation)))
                }
            }
            .padding(.top, 8)
        } label: {
            Text(LocalizedStringKey(title)).font(.headline)
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

private enum MaintenanceSection: String, CaseIterable, Identifiable {
    case duplicates = "Duplikate"
    case emptyPages = "Leere Seiten"
    case ocrReview = "OCR prüfen"
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

private enum MaintenanceStatusFilter: String, CaseIterable, Identifiable {
    case all = "Alle Zustände"
    case automatic = "Automatisch erkannt"
    case confirmed = "Manuell bestätigt"
    case review = "Prüfung erforderlich"
    case noResult = "Ohne OCR-Ergebnis"
    case manuallyEdited = "Manuell bearbeitet"
    case moved = "Verschoben"
    case deleted = "Gelöscht"
    case unavailable = "Nicht verfügbar"

    var id: Self { self }
}

struct MaintenanceView: View {
    @Environment(AppState.self) private var state
    @State private var section: MaintenanceSection = .duplicates
    @State private var filter = ""
    @State private var sort: MaintenanceSort = .fileName
    @State private var statusFilter: MaintenanceStatusFilter = .all
    @State private var selectedDuplicatePaths: Set<String> = []
    @State private var selectedPageIDs: Set<String> = []
    @State private var selectedOCRReviewIDs: Set<String> = []
    @State private var selectedEmptyPDFPaths: Set<String> = []
    @State private var selectedMissingPaths: Set<String> = []
    @State private var manualOCRCandidate: OCRReviewCandidate?
    @State private var confirmsDuplicateTrash = false
    @State private var confirmsPageRemoval = false
    @State private var confirmsEmptyPDFTrash = false
    @State private var confirmsIndexReset = false
    @State private var confirmsIndexResetFinally = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                maintenanceSectionPicker
                maintenanceFilterBar
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if section != .index {
                selectionControls
                Divider()
            }

            if state.isMaintainingDocuments {
                ProgressView {
                    Text(
                        LocalizedStringKey(
                            state.maintenanceMessage
                                ?? "Dokumentenwartung läuft …"
                        )
                    )
                }
                    .padding()
            } else if let message = state.maintenanceMessage {
                Label(
                    LocalizedStringKey(message),
                    systemImage: "checkmark.shield"
                )
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
                case .ocrReview:
                    ocrReviewList
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
        .navigationTitle(state.localizedSectionTitle(.maintenance))
        .task { await state.refreshMaintenance() }
        .onChange(of: section) {
            statusFilter = .all
            clearCurrentSelection()
        }
        .onChange(of: filter) {
            clearCurrentSelection()
        }
        .onChange(of: statusFilter) {
            clearCurrentSelection()
        }
        .sheet(item: $manualOCRCandidate) { candidate in
            ManualOCRReviewSheet(candidate: candidate)
                .environment(state)
        }
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
            "Bestätigte leere PDFs in den Papierkorb verschieben?",
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
            Button("Weiter …", role: .destructive) {
                confirmsIndexResetFinally = true
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Alle Dokument-, OCR-, Analyse-, Wartungs- und Suchdaten einschließlich manueller Entscheidungen werden entfernt. PDF-Dateien und Modelle bleiben unverändert.")
        }
        .confirmationDialog(
            "Letzte Bestätigung: Dokumentindex vollständig löschen?",
            isPresented: $confirmsIndexResetFinally
        ) {
            Button("Endgültig aus SQLite löschen", role: .destructive) {
                state.deleteDocumentIndex()
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Die Indexdaten können nur durch erneute Verarbeitung wiederhergestellt werden.")
        }
    }

    private var maintenanceSectionPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(MaintenanceSection.allCases) { item in
                    Button {
                        section = item
                    } label: {
                        Text(LocalizedStringKey(item.rawValue))
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 32)
                            .foregroundStyle(
                                section == item ? Color.white : Color.primary
                            )
                            .background(
                                section == item
                                    ? Color.accentColor
                                    : Color.secondary.opacity(0.10),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(LocalizedStringKey(item.rawValue))
                    .accessibilityValue(
                        section == item
                            ? LocalizedStringKey("Ausgewählt")
                            : LocalizedStringKey("Nicht ausgewählt")
                    )
                    .accessibilityHint(Text("Wartungsbereich anzeigen"))
                    .help(Text(LocalizedStringKey(item.rawValue)))
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityLabel(Text("Wartungsbereiche"))
    }

    private var maintenanceFilterBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                maintenanceSearchField
                    .frame(minWidth: 200, idealWidth: 260, maxWidth: .infinity)
                maintenanceSortPicker
                    .frame(width: 150)
                maintenanceStatusPicker
                    .frame(width: 180)
                maintenanceRefreshButton
            }

            VStack(alignment: .leading, spacing: 8) {
                maintenanceSearchField
                HStack(spacing: 10) {
                    maintenanceSortPicker
                        .frame(minWidth: 130, maxWidth: .infinity)
                    maintenanceStatusPicker
                        .frame(minWidth: 150, maxWidth: .infinity)
                    maintenanceRefreshButton
                }
            }
        }
    }

    private var maintenanceSearchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Liste durchsuchen", text: $filter)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 30)
        .background(.background, in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
        .accessibilityLabel(Text("Liste durchsuchen"))
        .help(Text("Wartungsliste nach Dateiname, Pfad oder Status filtern"))
    }

    private var maintenanceSortPicker: some View {
        Picker("Sortierung", selection: $sort) {
            ForEach(MaintenanceSort.allCases) {
                Text(LocalizedStringKey($0.rawValue)).tag($0)
            }
        }
        .labelsHidden()
        .accessibilityLabel(Text("Sortierung"))
        .help(Text("Sortierreihenfolge auswählen"))
    }

    private var maintenanceStatusPicker: some View {
        Picker("Status", selection: $statusFilter) {
            ForEach(availableStatusFilters) {
                Text(LocalizedStringKey($0.rawValue)).tag($0)
            }
        }
        .labelsHidden()
        .accessibilityLabel(Text("Statusfilter"))
        .help(Text("Angezeigte Zustände einschränken"))
    }

    private var maintenanceRefreshButton: some View {
        Button {
            Task { await state.refreshMaintenance() }
        } label: {
            Label("Aktualisieren", systemImage: "arrow.clockwise")
        }
        .help(Text("Wartungsdaten aus SQLite aktualisieren"))
        .accessibilityHint(Text("Lädt alle Wartungslisten neu"))
    }

    private var duplicateList: some View {
        VStack(spacing: 0) {
            List {
                if filteredDuplicateGroups.isEmpty {
                    maintenanceEmptyState(
                        "Keine Duplikate gefunden",
                        symbol: "doc.on.doc",
                        description: "Findora hat keine Dateien mit identischem SHA-256-Inhalt gefunden."
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
                selectionCount: selectedDuplicateLocations.count,
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
                    maintenanceEmptyState(
                        "Keine leeren Seiten gefunden",
                        symbol: "doc.text.magnifyingglass",
                        description: "Findora hat keine Seiten gefunden, die manuell geprüft werden müssen."
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
                                Button("Analyse neu starten") {
                                    state.reanalyzeEmptyPage(candidate)
                                }
                                .disabled(
                                    state.isMaintainingDocuments
                                        || state.isProcessing
                                )
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
                selectionCount: selectedEmptyPages.count,
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
                    maintenanceEmptyState(
                        "Keine leeren PDFs gefunden",
                        symbol: "doc",
                        description: "Es gibt keine vollständig analysierten und bestätigten leeren PDFs."
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
                                "\(candidate.pageCount) analysierte und manuell als leer bestätigte Seite(n) · \(candidate.confidence, format: .percent.precision(.fractionLength(1))) Sicherheit"
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
                selectionCount: selectedEmptyPDFs.count,
                title: "Ausgewählte PDFs in den Papierkorb",
                enabled: !selectedEmptyPDFs.isEmpty
            ) {
                confirmsEmptyPDFTrash = true
            } reset: {
                selectedEmptyPDFPaths.removeAll()
            }
        }
    }

    private var ocrReviewList: some View {
        VStack(spacing: 0) {
            List {
                if filteredOCRReviewCandidates.isEmpty {
                    maintenanceEmptyState(
                        "Keine OCR-Prüffälle",
                        symbol: "checkmark.circle",
                        description: "Alle aktuell erkannten OCR-Seiten sind bearbeitet."
                    )
                }
                ForEach(filteredOCRReviewCandidates) { candidate in
                    HStack(alignment: .top, spacing: 12) {
                        Toggle(
                            "Auswählen",
                            isOn: selectionBinding(
                                candidate.id,
                                in: $selectedOCRReviewIDs
                            )
                        )
                        .labelsHidden()
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
                                    .foregroundStyle(.orange)
                            }
                            Text(candidate.relativePath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(candidate.absolutePath)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            if let best = candidate.bestVariant {
                                Text(
                                    "Beste Variante: \(best.strategyName) · \(best.engine.displayName) · \(best.qualityScore, format: .percent.precision(.fractionLength(0)))"
                                )
                                .font(.caption)
                                Text(
                                    "\(best.characterCount) Zeichen · \(best.wordCount) Wörter · \(best.recognizedLanguage) · \(best.preprocessing)"
                                )
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                if !best.text.isEmpty {
                                    Text(best.text)
                                        .font(.caption)
                                        .lineLimit(3)
                                        .textSelection(.enabled)
                                }
                            } else {
                                Text("Noch keine verwertbare OCR-Variante gespeichert.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(
                                "\(candidate.variants.count) Variante(n) · \(candidate.textKind.displayName)"
                            )
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            HStack {
                                Button("Vorschau") {
                                    state.previewMaintenanceFile(
                                        path: candidate.absolutePath,
                                        fileName: candidate.fileName,
                                        relativePath: candidate.relativePath,
                                        pageNumber: candidate.pageNumber
                                    )
                                }
                                Button("Nicht leer") {
                                    state.confirmNotEmpty([candidate])
                                }
                                Button("Automatisch nachbearbeiten") {
                                    state.retryOCR(candidate)
                                }
                                Button("OCR manuell nachbearbeiten") {
                                    manualOCRCandidate = candidate
                                }
                                Button("Manuelle Bewertung zurücksetzen") {
                                    state.resetPageReview(candidate)
                                }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .padding(.vertical, 5)
                }
            }
            ocrReviewActionBar
        }
    }

    private var missingFilesView: some View {
        VStack(spacing: 0) {
            List {
                if filteredMissingFiles.isEmpty {
                    maintenanceEmptyState(
                        "Keine fehlenden Dateien",
                        symbol: "checkmark.circle",
                        description: "Der gespeicherte Dokumentbestand ist erreichbar."
                    )
                }
                ForEach(filteredMissingFiles) { candidate in
                    HStack(alignment: .top, spacing: 12) {
                        Toggle(
                            "Auswählen",
                            isOn: selectionBinding(
                                candidate.absolutePath,
                                in: $selectedMissingPaths
                            )
                        )
                        .labelsHidden()
                        Image(systemName: missingFileSymbol(candidate.reason))
                            .font(.title2)
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(candidate.fileName).font(.headline)
                            Text(candidate.relativePath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(candidate.absolutePath)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Text(missingFileReason(candidate.reason))
                                .font(.caption)
                            if let message = candidate.message, !message.isEmpty {
                                Text(message)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            missingFilesActionBar
        }
    }

    private var indexView: some View {
        Form {
            Section {
                if state.hasMixedEmbeddingIndex {
                    ContentUnavailableView {
                        Label(
                            "Gemischter Embedding-Index",
                            systemImage: "exclamationmark.triangle"
                        )
                    } description: {
                        Text("E5- und Fallback-Vektoren sind gleichzeitig vorhanden. Die Suche verwendet nur das aktive Modell.")
                    }
                } else {
                    ContentUnavailableView {
                        Label("Index konsistent", systemImage: "checkmark.circle")
                    } description: {
                        Text("Findora hat keinen gemischten Embedding-Index erkannt.")
                    }
                }
            }
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
        title: LocalizedStringKey,
        enabled: Bool,
        action: @escaping () -> Void,
        reset: @escaping () -> Void
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                selectionCountLabel(selectionCount)
                Spacer(minLength: 16)
                actionBarButtons(
                    title: title,
                    selectionCount: selectionCount,
                    enabled: enabled,
                    action: action,
                    reset: reset
                )
            }

            VStack(alignment: .leading, spacing: 10) {
                selectionCountLabel(selectionCount)
                actionBarButtons(
                    title: title,
                    selectionCount: selectionCount,
                    enabled: enabled,
                    action: action,
                    reset: reset
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 58)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private func maintenanceEmptyState(
        _ title: LocalizedStringKey,
        symbol: String,
        description: LocalizedStringKey
    ) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(description)
        } actions: {
            Button("Erneut prüfen") {
                Task { await state.refreshMaintenance() }
            }
        }
    }

    private var ocrReviewActionBar: some View {
        let candidates = selectedOCRReviewCandidates
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                ocrReviewSelectionDescription
                Spacer(minLength: 16)
                ocrReviewActionButtons(candidates)
            }

            VStack(alignment: .leading, spacing: 10) {
                ocrReviewSelectionDescription
                ocrReviewActionButtons(candidates)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var ocrReviewSelectionDescription: some View {
        VStack(alignment: .leading, spacing: 2) {
            selectionCountLabel(selectedOCRReviewCandidates.count)
            Text("Hohe Auflösungen werden einzeln verarbeitet. Gemeinsame Strategie: 300 dpi + Kontrast, bis ca. 45 MB Arbeitsspeicher je Seite.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func ocrReviewActionButtons(
        _ candidates: [OCRReviewCandidate]
    ) -> some View {
        HStack(spacing: 10) {
            Button("Auswahl zurücksetzen") {
                selectedOCRReviewIDs.removeAll()
            }
            .disabled(candidates.isEmpty)
            Menu("Auswahl bearbeiten") {
                Button("Als nicht leer markieren") {
                    state.confirmNotEmpty(candidates)
                }
                Button("Automatisch nachbearbeiten") {
                    state.retryOCR(candidates)
                }
                Button("Mit gleicher Strategie testen") {
                    state.retryOCR(
                        candidates,
                        configuration: sharedBulkOCRConfiguration
                    )
                }
            }
            .disabled(
                candidates.isEmpty
                    || state.isMaintainingDocuments
                    || state.isProcessing
            )
        }
    }

    private var missingFilesActionBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                selectionCountLabel(selectedMissingCount)
                Text("Ein Scan gleicht Pfade und Suchindex gezielt ab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 16)
                scanNowButton
            }

            VStack(alignment: .leading, spacing: 10) {
                selectionCountLabel(selectedMissingCount)
                Text("Ein Scan gleicht Pfade und Suchindex gezielt ab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                scanNowButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var scanNowButton: some View {
        Button("Jetzt prüfen") {
            Task { await state.scanNow() }
        }
        .buttonStyle(.borderedProminent)
        .disabled(state.documentFolderPath == nil || state.isProcessing)
    }

    private var selectionControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                selectionCountLabel(currentSelectionCount)
                Spacer(minLength: 12)
                selectionToolButtons
            }

            VStack(alignment: .leading, spacing: 8) {
                selectionCountLabel(currentSelectionCount)
                selectionToolButtons
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.background.secondary)
    }

    private var selectionToolButtons: some View {
        HStack(spacing: 8) {
            Button("Alle auswählen") { selectAllVisible() }
                .disabled(selectableVisibleCount == 0)
                .help(Text("Alle aktuell sichtbaren und zulässigen Einträge auswählen"))
            Button("Keine auswählen") { clearCurrentSelection() }
                .disabled(currentSelectionCount == 0)
                .help(Text("Aktuelle Auswahl aufheben"))
            Button("Auswahl umkehren") { invertVisibleSelection() }
                .disabled(selectableVisibleCount == 0)
                .help(Text("Auswahl der sichtbaren Einträge umkehren"))
        }
        .buttonStyle(.borderless)
    }

    private func selectionCountLabel(_ count: Int) -> some View {
        Label(
            "\(count) ausgewählt",
            systemImage: count == 0 ? "checklist.unchecked" : "checklist.checked"
        )
        .font(.callout.weight(.medium))
        .foregroundStyle(count == 0 ? .secondary : .primary)
        .accessibilityLabel(Text("\(count) ausgewählt"))
    }

    private func actionBarButtons(
        title: LocalizedStringKey,
        selectionCount: Int,
        enabled: Bool,
        action: @escaping () -> Void,
        reset: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Button("Auswahl zurücksetzen", action: reset)
                .disabled(selectionCount == 0)
            Button(title, role: .destructive, action: action)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(
                    !enabled
                        || state.isMaintainingDocuments
                        || state.isProcessing
                )
        }
    }

    private var availableStatusFilters: [MaintenanceStatusFilter] {
        switch section {
        case .duplicates, .emptyPDFs:
            [.all, .confirmed]
        case .emptyPages:
            [.all, .automatic, .confirmed]
        case .ocrReview:
            [.all, .review, .noResult, .manuallyEdited]
        case .missingFiles:
            [.all, .moved, .deleted, .unavailable]
        case .index:
            [.all]
        }
    }

    private func selectAllVisible() {
        switch section {
        case .duplicates:
            for group in filteredDuplicateGroups {
                let keeper = group.recommendedLocation ?? group.locations.first
                selectedDuplicatePaths.formUnion(
                    group.locations
                        .filter { $0 != keeper }
                        .map(\.absolutePath)
                )
            }
        case .emptyPages:
            selectedPageIDs.formUnion(
                filteredEmptyPages
                    .filter {
                        $0.decision == .confirmedEmpty
                            && $0.status.isEmptyCandidate
                    }
                    .map(\.id)
            )
        case .ocrReview:
            selectedOCRReviewIDs = VisibleSelection.selectAll(
                current: selectedOCRReviewIDs,
                visible: filteredOCRReviewCandidates.map(\.id)
            )
        case .emptyPDFs:
            selectedEmptyPDFPaths = VisibleSelection.selectAll(
                current: selectedEmptyPDFPaths,
                visible: filteredEmptyPDFs.map(\.absolutePath)
            )
        case .missingFiles:
            selectedMissingPaths = VisibleSelection.selectAll(
                current: selectedMissingPaths,
                visible: filteredMissingFiles.map(\.absolutePath)
            )
        case .index:
            break
        }
    }

    private func clearCurrentSelection() {
        switch section {
        case .duplicates: selectedDuplicatePaths.removeAll()
        case .emptyPages: selectedPageIDs.removeAll()
        case .ocrReview: selectedOCRReviewIDs.removeAll()
        case .emptyPDFs: selectedEmptyPDFPaths.removeAll()
        case .missingFiles: selectedMissingPaths.removeAll()
        case .index: break
        }
    }

    private func invertVisibleSelection() {
        switch section {
        case .duplicates:
            let visible = Set(
                filteredDuplicateGroups.flatMap {
                    $0.locations.map(\.absolutePath)
                }
            )
            selectedDuplicatePaths.formSymmetricDifference(visible)
            for group in filteredDuplicateGroups
            where group.locations.allSatisfy({
                selectedDuplicatePaths.contains($0.absolutePath)
            }) {
                if let keeper = group.recommendedLocation ?? group.locations.first {
                    selectedDuplicatePaths.remove(keeper.absolutePath)
                }
            }
        case .emptyPages:
            let visible = Set(
                filteredEmptyPages.filter {
                    $0.decision == .confirmedEmpty
                        && $0.status.isEmptyCandidate
                }.map(\.id)
            )
            selectedPageIDs.formSymmetricDifference(visible)
        case .ocrReview:
            selectedOCRReviewIDs = VisibleSelection.invert(
                current: selectedOCRReviewIDs,
                visible: filteredOCRReviewCandidates.map(\.id)
            )
        case .emptyPDFs:
            selectedEmptyPDFPaths = VisibleSelection.invert(
                current: selectedEmptyPDFPaths,
                visible: filteredEmptyPDFs.map(\.absolutePath)
            )
        case .missingFiles:
            selectedMissingPaths = VisibleSelection.invert(
                current: selectedMissingPaths,
                visible: filteredMissingFiles.map(\.absolutePath)
            )
        case .index:
            break
        }
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
        let values = state.emptyPageCandidates.filter {
            let matchesStatus: Bool = switch statusFilter {
            case .all: true
            case .automatic: $0.decision == PageReviewDecision.undecided
            case .confirmed:
                $0.decision == PageReviewDecision.confirmedEmpty
            default: true
            }
            return matchesFilter($0) && matchesStatus
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

    private var filteredEmptyPDFs: [EmptyPDFCandidate] {
        let values = state.emptyPDFCandidates.filter {
            (normalizedFilter.isEmpty
                || $0.fileName.localizedCaseInsensitiveContains(normalizedFilter)
                || $0.relativePath.localizedCaseInsensitiveContains(normalizedFilter))
                && (statusFilter == .all || statusFilter == .confirmed)
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

    private var filteredOCRReviewCandidates: [OCRReviewCandidate] {
        let values = state.ocrReviewCandidates.filter {
            let matchesText = normalizedFilter.isEmpty
                || $0.fileName.localizedCaseInsensitiveContains(normalizedFilter)
                || $0.relativePath.localizedCaseInsensitiveContains(normalizedFilter)
                || $0.status.displayName.localizedCaseInsensitiveContains(normalizedFilter)
            let matchesStatus: Bool = switch statusFilter {
            case .all: true
            case .review:
                $0.status == .needsOCRReview
                    || $0.status == .technicalReviewError
                    || $0.status == .imageWithoutRecognizedText
            case .noResult: $0.status == .ocrNoResult
            case .manuallyEdited: $0.textKind != .automatic
            default: true
            }
            return matchesText && matchesStatus
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
            return values.sorted {
                ($0.bestVariant?.qualityScore ?? 0)
                    > ($1.bestVariant?.qualityScore ?? 0)
            }
        }
    }

    private var filteredMissingFiles: [MissingFileCandidate] {
        state.missingFileCandidates.filter {
            let matchesText = normalizedFilter.isEmpty
                || $0.fileName.localizedCaseInsensitiveContains(normalizedFilter)
                || $0.relativePath.localizedCaseInsensitiveContains(normalizedFilter)
                || $0.absolutePath.localizedCaseInsensitiveContains(normalizedFilter)
            let matchesStatus: Bool = switch statusFilter {
            case .all: true
            case .moved: $0.reason == .moved
            case .deleted: $0.reason == .deleted
            case .unavailable:
                $0.reason == .cloudUnavailable || $0.reason == .accessDenied
            default: true
            }
            return matchesText && matchesStatus
        }.sorted {
            switch sort {
            case .fileName:
                $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
            case .path, .confidence:
                $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            }
        }
    }

    private func missingFileReason(_ reason: MissingFileReason) -> String {
        switch reason {
        case .moved: "Datei wurde vermutlich verschoben"
        case .deleted: "Datei ist nicht mehr vorhanden"
        case .cloudUnavailable: "Cloud-Datei ist derzeit nicht lokal verfügbar"
        case .accessDenied: "Zugriff auf die Datei wurde verweigert"
        }
    }

    private func missingFileSymbol(_ reason: MissingFileReason) -> String {
        switch reason {
        case .moved: "arrow.right.doc.on.clipboard"
        case .deleted: "trash"
        case .cloudUnavailable: "icloud.slash"
        case .accessDenied: "lock.trianglebadge.exclamationmark"
        }
    }

    private var selectedDuplicateLocations: [DuplicateLocation] {
        filteredDuplicateGroups.flatMap(\.locations).filter {
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
        filteredEmptyPages.filter {
            selectedPageIDs.contains($0.id)
                && $0.decision == .confirmedEmpty
                && $0.status.isEmptyCandidate
        }
    }

    private var selectedOCRReviewCandidates: [OCRReviewCandidate] {
        filteredOCRReviewCandidates.filter {
            selectedOCRReviewIDs.contains($0.id)
        }
    }

    private var selectedEmptyPDFs: [EmptyPDFCandidate] {
        filteredEmptyPDFs.filter {
            selectedEmptyPDFPaths.contains($0.absolutePath)
        }
    }

    private var selectedMissingCount: Int {
        filteredMissingFiles.filter {
            selectedMissingPaths.contains($0.absolutePath)
        }.count
    }

    private var currentSelectionCount: Int {
        switch section {
        case .duplicates:
            selectedDuplicateLocations.count
        case .emptyPages:
            selectedEmptyPages.count
        case .ocrReview:
            selectedOCRReviewCandidates.count
        case .emptyPDFs:
            selectedEmptyPDFs.count
        case .missingFiles:
            selectedMissingCount
        case .index:
            0
        }
    }

    private var selectableVisibleCount: Int {
        switch section {
        case .duplicates:
            filteredDuplicateGroups.reduce(0) { count, group in
                count + max(group.locations.count - 1, 0)
            }
        case .emptyPages:
            filteredEmptyPages.filter {
                $0.decision == .confirmedEmpty
                    && $0.status.isEmptyCandidate
            }.count
        case .ocrReview:
            filteredOCRReviewCandidates.count
        case .emptyPDFs:
            filteredEmptyPDFs.count
        case .missingFiles:
            filteredMissingFiles.count
        case .index:
            0
        }
    }

    private var sharedBulkOCRConfiguration: OCRConfiguration {
        var configuration = state.ocrConfiguration
        configuration.persistenceMode = .nonDestructive
        configuration.maximumParallelFiles = 1
        configuration.renderDPI = 300
        configuration.enhanceContrast = true
        configuration.backgroundLightening = true
        configuration.retryStrategyID = "shared-300-contrast"
        return configuration
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

private struct ManualOCRReviewSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let candidate: OCRReviewCandidate
    @State private var configuration: OCRConfiguration
    @State private var editedText: String

    init(candidate: OCRReviewCandidate) {
        self.candidate = candidate
        var configuration = OCRConfiguration.default
        configuration.persistenceMode = .nonDestructive
        configuration.maximumParallelFiles = 1
        configuration.rotatePages = true
        _configuration = State(initialValue: configuration)
        _editedText = State(
            initialValue: candidate.currentText.isEmpty
                ? candidate.bestVariant?.text ?? ""
                : candidate.currentText
        )
    }

    private var latestCandidate: OCRReviewCandidate {
        state.ocrReviewCandidates.first(where: { $0.id == candidate.id })
            ?? candidate
    }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Originalseite").font(.headline)
                PDFKitView(
                    url: URL(filePath: candidate.absolutePath),
                    pageNumber: candidate.pageNumber
                )
                Text("Vorschau der gewählten Bildaufbereitung").font(.headline)
                ProcessedOCRPreview(
                    path: candidate.absolutePath,
                    pageNumber: candidate.pageNumber,
                    configuration: configuration
                )
                .frame(height: 190)
            }
            .padding()
            .frame(minWidth: 520, minHeight: 680)

            Form {
                Section("OCR-Einstellungen") {
                    Picker("OCR-Engine", selection: $configuration.engineSelection) {
                        Text("Automatisch").tag(OCREngineSelection.automatic)
                        Text("Apple Vision").tag(OCREngineSelection.appleVision)
                        Text("Tesseract").tag(OCREngineSelection.tesseractOCRmyPDF)
                    }
                    Picker("Sprache", selection: languageBinding) {
                        Text("Deutsch").tag("deu")
                        Text("Englisch").tag("eng")
                        Text("Deutsch + Englisch").tag("deu+eng")
                    }
                    Picker("Drehung", selection: $configuration.manualRotationDegrees) {
                        Text("Automatisch / 0°").tag(0)
                        Text("90°").tag(90)
                        Text("180°").tag(180)
                        Text("270°").tag(270)
                    }
                    Picker("Auflösung", selection: $configuration.renderDPI) {
                        Text("Standard").tag(144)
                        Text("300 dpi").tag(300)
                        Text("400 dpi").tag(400)
                        Text("600 dpi").tag(600)
                    }
                    if configuration.renderDPI == 600 {
                        Label(
                            "600 dpi benötigt viel Speicher und wird nur für diese Seite einzeln ausgeführt.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }

                Section("Bildaufbereitung") {
                    Toggle("Kontrast erhöhen", isOn: $configuration.enhanceContrast)
                    Toggle("Schwarz-Weiß-Binarisierung", isOn: $configuration.binarize)
                    Toggle("Adaptive Binarisierung", isOn: $configuration.adaptiveBinarize)
                    Toggle("Hintergrund aufhellen", isOn: $configuration.backgroundLightening)
                    Toggle("Schatten reduzieren", isOn: $configuration.reduceShadows)
                    Toggle("Begradigen", isOn: $configuration.deskew)
                    Toggle("Rauschen entfernen", isOn: $configuration.denoise)
                    Toggle("Schärfen", isOn: $configuration.sharpen)
                    Toggle("Rand beschneiden", isOn: $configuration.cropBorders)
                    Text(
                        "Graustufen werden bei Kontrast- oder Binarisierungsverarbeitung automatisch verwendet. Nicht unterstützte Filter werden nicht vorgetäuscht."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section("OCR-Vorschau") {
                    if let best = latestCandidate.bestVariant {
                        LabeledContent("Beste Strategie", value: best.strategyName)
                        LabeledContent("Engine", value: best.engine.displayName)
                        LabeledContent(
                            "Qualität",
                            value: best.qualityScore.formatted(
                                .percent.precision(.fractionLength(0))
                            )
                        )
                        LabeledContent(
                            "Umfang",
                            value: "\(best.characterCount) Zeichen · \(best.wordCount) Wörter"
                        )
                        LabeledContent("Sprache", value: best.recognizedLanguage)
                        LabeledContent(
                            "Laufzeit",
                            value: "\(best.durationSeconds.formatted(.number.precision(.fractionLength(1)))) s"
                        )
                    } else {
                        Text("Noch keine OCR-Variante verfügbar.")
                            .foregroundStyle(.secondary)
                    }
                    Button("Andere Einstellungen testen") {
                        state.retryOCR(
                            candidate,
                            configuration: manualTestConfiguration
                        )
                    }
                    .disabled(state.isMaintainingDocuments || state.isProcessing)
                }

                Section("Aktuelle und alternative Fassungen") {
                    if !latestCandidate.currentText.isEmpty {
                        DisclosureGroup("Aktuell gespeicherte Fassung") {
                            Text(latestCandidate.currentText)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    ForEach(
                        latestCandidate.variants.sorted {
                            $0.qualityScore > $1.qualityScore
                        }
                    ) { variant in
                        DisclosureGroup(
                            "\(variant.isBest ? "Beste Variante · " : "")\(variant.strategyName) · \(variant.qualityScore, format: .percent.precision(.fractionLength(0)))"
                        ) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(
                                    "\(variant.engine.displayName) · \(variant.preprocessing)"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                Text(variant.text.isEmpty ? "Kein Text erkannt" : variant.text)
                                    .textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                Section("Text bearbeiten oder manuell erfassen") {
                    TextEditor(text: $editedText)
                        .font(.body.monospaced())
                        .frame(minHeight: 180)
                    HStack {
                        Button("Beste OCR-Fassung einsetzen") {
                            editedText = latestCandidate.bestVariant?.text ?? editedText
                        }
                        .disabled(latestCandidate.bestVariant == nil)
                        Button("Zur ursprünglichen OCR-Fassung zurücksetzen") {
                            editedText = latestCandidate.originalOCRText ?? ""
                        }
                        .disabled(latestCandidate.originalOCRText == nil)
                    }
                    Text(
                        "Der Text wird nur lokal in SQLite gespeichert. Die PDF bleibt unverändert; FTS, Chunks und Embeddings werden nur für diese Seite ersetzt."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 440)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Abbrechen") { dismiss() }
                Spacer()
                Button("Als vollständig manuell erfasst speichern") {
                    state.savePageText(
                        latestCandidate,
                        text: editedText,
                        kind: .manuallyEntered
                    )
                    dismiss()
                }
                .disabled(editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Korrigiertes Ergebnis übernehmen") {
                    state.savePageText(
                        latestCandidate,
                        text: editedText,
                        kind: .manuallyCorrected
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
            .background(.bar)
        }
        .frame(minWidth: 1_050, minHeight: 740)
    }

    private var languageBinding: Binding<String> {
        Binding(
            get: {
                configuration.languages == ["deu"] ? "deu"
                    : configuration.languages == ["eng"] ? "eng"
                    : "deu+eng"
            },
            set: { selection in
                configuration.languages = switch selection {
                case "deu": ["deu"]
                case "eng": ["eng"]
                default: ["deu", "eng"]
                }
            }
        )
    }

    private var manualTestConfiguration: OCRConfiguration {
        var tested = configuration
        tested.retryStrategyID = "manual-\(UUID().uuidString)"
        return tested
    }
}

private struct ProcessedOCRPreview: View {
    let path: String
    let pageNumber: Int
    let configuration: OCRConfiguration
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        .task(id: configuration) {
            image = render()
        }
    }

    private func render() -> NSImage? {
        guard let document = PDFDocument(url: URL(filePath: path)),
              let page = document.page(at: max(0, pageNumber - 1)) else {
            return nil
        }
        let thumbnail = page.thumbnail(
            of: NSSize(width: 900, height: 1_200),
            for: .mediaBox
        )
        guard let data = thumbnail.tiffRepresentation,
              var input = CIImage(data: data) else {
            return thumbnail
        }
        if configuration.cropBorders {
            let extent = input.extent
            input = input.cropped(
                to: extent.insetBy(
                    dx: extent.width * 0.01,
                    dy: extent.height * 0.01
                )
            )
        }
        if configuration.enhanceContrast
            || configuration.binarize
            || configuration.adaptiveBinarize {
            input = input.applyingFilter(
                "CIColorControls",
                parameters: [
                    kCIInputSaturationKey: 0,
                    kCIInputContrastKey: configuration.binarize
                        || configuration.adaptiveBinarize ? 4.0 : 1.6
                ]
            )
        }
        if configuration.backgroundLightening || configuration.reduceShadows {
            input = input.applyingFilter(
                "CIExposureAdjust",
                parameters: [kCIInputEVKey: 0.35]
            )
        }
        if configuration.denoise {
            input = input.applyingFilter(
                "CINoiseReduction",
                parameters: ["inputNoiseLevel": 0.02, "inputSharpness": 0.4]
            )
        }
        if configuration.sharpen {
            input = input.applyingFilter(
                "CISharpenLuminance",
                parameters: [kCIInputSharpnessKey: 0.7]
            )
        }
        let orientation: CGImagePropertyOrientation = switch
            configuration.manualRotationDegrees {
        case 90: .right
        case 180: .down
        case 270: .left
        default: .up
        }
        input = input.oriented(orientation)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(input, from: input.extent) else {
            return thumbnail
        }
        return NSImage(cgImage: cgImage, size: .zero)
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
                        Text(LocalizedStringKey(message))
                            .foregroundStyle(.secondary)
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
        .navigationTitle(state.localizedSectionTitle(.ocr))
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
    @State private var pendingRemoval: InstalledModel?

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
                    Label(
                        LocalizedStringKey(message),
                        systemImage: "checkmark.circle"
                    )
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
        .navigationTitle(state.localizedSectionTitle(.models))
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
        .confirmationDialog(
            "Modell wirklich entfernen?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            presenting: pendingRemoval
        ) { model in
            Button("Modell in den Papierkorb", role: .destructive) {
                state.removeModel(model)
                pendingRemoval = nil
            }
            Button("Abbrechen", role: .cancel) { pendingRemoval = nil }
        } message: { model in
            Text(
                model.descriptor.kind == .embedding
                    ? "Nur die Modelldateien werden verschoben. Gespeicherte Dokumenttexte und Embeddings bleiben erhalten; die Volltextsuche funktioniert weiter."
                    : "Nur die Modelldateien werden verschoben. Dokumentindex und Suche bleiben erhalten; KI-Antworten sind danach deaktiviert."
            )
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
                    if model.isInstalled {
                        Text(modelStatus(model))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                model.isActive
                                    ? Color.green.opacity(0.18)
                                    : Color.secondary.opacity(0.12),
                                in: Capsule()
                            )
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
                        if model.isActive {
                            Button("Deaktivieren") {
                                state.deactivateModel(model)
                            }
                        } else {
                            Button("Aktivieren") {
                                if model.descriptor.kind == .embedding {
                                    pendingEmbeddingActivation = model
                                } else {
                                    state.activateModel(model)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        Button("Entfernen", role: .destructive) {
                            pendingRemoval = model
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

    private func modelStatus(_ model: InstalledModel) -> String {
        guard model.isActive else { return "Installiert · deaktiviert" }
        switch model.descriptor.kind {
        case .embedding:
            return state.isEmbeddingModelLoaded
                ? "Aktiv · geladen"
                : "Aktiv"
        case .answer:
            return state.isAnswerModelLoaded
                ? "Aktiv · geladen"
                : "Aktiv · bei Bedarf laden"
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
    @State private var confirmsIndexDeletionFinally = false
    @State private var confirmsOldStorageRemoval = false
    @State private var confirmsTemporaryCleanup = false

    var body: some View {
        @Bindable var state = state
        Form {
            Section("Darstellung") {
                Picker("Sprache", selection: $state.interfaceLanguage) {
                    ForEach(InterfaceLanguage.allCases) {
                        Text($0.displayName).tag($0)
                    }
                }
                Picker("Erscheinungsbild", selection: $state.interfaceAppearance) {
                    ForEach(InterfaceAppearance.allCases) {
                        Text($0.displayName).tag($0)
                    }
                }
                Text("Sprache und Erscheinungsbild werden nach dem Speichern sofort auf alle Hauptansichten angewendet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Dokumente") {
                LabeledContent {
                    if let path = state.documentFolderPath {
                        Text(path)
                    } else {
                        Text("Nicht ausgewählt")
                    }
                } label: {
                    Text("Ordner")
                }
                Button("Dokumentenordner auswählen …") { state.chooseFolder() }
                Stepper(
                    value: $state.scanIntervalMinutes,
                    in: 1...1440
                ) {
                    Text("Scanintervall: \(state.scanIntervalMinutes) Minuten")
                }
                Picker(
                    "Verhalten bei entfernten Dokumenten",
                    selection: $state.removedDocumentPolicy
                ) {
                    ForEach(RemovedDocumentPolicy.allCases) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                Button("Jetzt synchronisieren") {
                    Task { await state.scanNow() }
                }
                if let message = state.lastSynchronizationMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("E-Mail-Quellen") {
                if state.mailSources.isEmpty {
                    Text("Keine E-Mail-Quelle eingerichtet")
                        .foregroundStyle(.secondary)
                } else {
                    Text(
                        "\(state.mailSources.count) Quelle(n), "
                        + "\(state.mailSources.reduce(0) { $0 + $1.messageCount }) E-Mail(s)"
                    )
                }
                Button("E-Mail-Quellen verwalten …") {
                    state.selectedSection = .mail
                }
            }
            Section("Speicher") {
                LabeledContent("Findora-Datenspeicher") {
                    VStack(alignment: .trailing) {
                        Text(state.dataStoragePath).lineLimit(1)
                        Text(state.dataStorageAvailable ? "Erreichbar" : "Nicht erreichbar")
                            .font(.caption)
                            .foregroundStyle(state.dataStorageAvailable ? .green : .red)
                    }
                }
                Button("Datenspeicher ändern …") {
                    state.chooseStorageLocation(kind: .data)
                }
                LabeledContent("KI-Modellspeicher") {
                    VStack(alignment: .trailing) {
                        Text(state.modelStoragePath).lineLimit(1)
                        Text(state.modelStorageAvailable ? "Erreichbar" : "Nicht erreichbar")
                            .font(.caption)
                            .foregroundStyle(state.modelStorageAvailable ? .green : .red)
                    }
                }
                Button("Modellspeicher ändern …") {
                    state.chooseStorageLocation(kind: .models)
                }
                HStack {
                    Button("Datenspeicher im Finder anzeigen") {
                        state.revealStorage(kind: .data)
                    }
                    Button("Modellspeicher im Finder anzeigen") {
                        state.revealStorage(kind: .models)
                    }
                }
                if let usage = state.storageUsage {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                        storageRow("Datenbank und Index", usage.databaseAndIndexBytes)
                        storageRow("OCR- und E-Mail-Texte", usage.textBytes)
                        storageRow("Embeddings", usage.embeddingBytes)
                        storageRow("Vorschaudaten", usage.previewBytes)
                        storageRow("Archivierte Mailquellen", usage.archivedSourceBytes)
                        storageRow("Archivierte Anhänge", usage.archivedAttachmentBytes)
                        storageRow("KI-Modelle", usage.modelBytes)
                        storageRow("Temporäre Daten", usage.temporaryBytes)
                        storageRow("Protokolle", usage.logBytes)
                        Divider()
                        storageRow("Gesamt", usage.totalBytes)
                        storageRow("Frei am Datenziel", usage.availableDataBytes ?? 0)
                        storageRow("Frei am Modellziel", usage.availableModelBytes ?? 0)
                    }
                    if usage.capacityLevel != .sufficient {
                        Label(
                            usage.capacityLevel == .critical
                                ? "Freier Speicher ist kritisch."
                                : "Freier Speicher ist knapp.",
                            systemImage: "externaldrive.badge.exclamationmark"
                        )
                        .foregroundStyle(usage.capacityLevel == .critical ? .red : .orange)
                    }
                }
                HStack {
                    Button("Integrität prüfen") {
                        state.checkStorageIntegrity()
                    }
                    Button("Temporäre Daten bereinigen") {
                        confirmsTemporaryCleanup = true
                    }
                    Button("Speicherbelegung aktualisieren") {
                        Task { await state.refreshStorageUsage() }
                    }
                }
                if state.isStorageMigrationInProgress,
                   let progress = state.storageMigrationProgress {
                    ProgressView(
                        value: Double(progress.copiedBytes),
                        total: Double(max(progress.totalBytes, 1))
                    )
                    Text(
                        "\(progress.phase.displayName): \(progress.copiedFiles) von \(progress.totalFiles) Dateien"
                    )
                    .font(.caption)
                }
                if let migration = state.pendingStorageMigration {
                    Label(
                        "Unvollständige Migration: \(migration.phase.displayName)",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                    HStack {
                        Button("Fortsetzen …") {
                            state.continuePendingStorageMigration()
                        }
                        Button("Zum alten Speicher zurückkehren") {
                            state.returnToPreviousStorage()
                        }
                        Button("Staging verwerfen", role: .destructive) {
                            state.discardPendingStorageMigration()
                        }
                    }
                }
                if let message = state.storageMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                if let migration = state.lastStorageMigration,
                   migration.phase == .completed,
                   FileManager.default.fileExists(atPath: migration.sourcePath) {
                    Button("Bestätigten Altbestand in Papierkorb verschieben …", role: .destructive) {
                        confirmsOldStorageRemoval = true
                    }
                    Text(migration.sourcePath)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(
                    "Datenbank und Modelle sind getrennt verschiebbar. Netzwerk-, Cloud- und ungeeignete Dateisystemziele werden vor dem Kopieren gesperrt."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Section("Lokales Sprachmodell") {
                Stepper(
                    value: $state.llmIdleMinutes,
                    in: 1...120
                ) {
                    Text("Nach \(state.llmIdleMinutes) Minuten entladen")
                }
                Toggle("Experimentelle Modelle anzeigen", isOn: $state.showExperimentalModels)
            }
            Section("Start und Hintergrund") {
                Toggle(
                    isOn: Binding(
                        get: { state.launchAtLogin },
                        set: { state.setLaunchAtLogin($0) }
                    )
                ) {
                    Text("Beim Anmelden starten")
                }
                LabeledContent {
                    Text(LocalizedStringKey(state.memoryPressure))
                } label: {
                    Text("Speicherdruck")
                }
            }
            Section("Datenschutz") {
                Text("Dokumente, Suchanfragen, Embeddings und Antworten bleiben lokal. Telemetrie ist deaktiviert.")
                    .foregroundStyle(.secondary)
            }
            Section("Indexwartung") {
                Button("Suchindex neu aufbauen …") { confirmsRebuild = true }
                Text("Löscht Chunks, Volltextindex und Embeddings und baut sie ausschließlich aus dem bereits gespeicherten Seitentext neu auf.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("OCR- und Analysewerte neu prüfen …") {
                    confirmsOCRReset = true
                }
                Text("Setzt automatische OCR- und Leerseitenbewertungen zurück und analysiert die Dokumente erneut. Manuelle Bewertungen und manuell bearbeiteter Text bleiben erhalten.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Inkonsistenzen reparieren") { state.repairIndex() }
                Text("Prüft SQLite und Fremdschlüssel, gleicht Jobzustände ab und baut den Volltextindex aus vorhandenen Chunks neu auf.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Kompletten Dokumentenindex löschen …", role: .destructive) {
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
        .navigationTitle(state.localizedSectionTitle(.settings))
        .task {
            await state.refreshStorageUsage()
        }
        .confirmationDialog("Suchindex neu aufbauen?", isPresented: $confirmsRebuild) {
            Button("Neu aufbauen") { state.rebuildSearchIndex() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Gespeicherter Seiten- und OCR-Text bleibt erhalten.")
        }
        .confirmationDialog("OCR- und Analysewerte neu prüfen?", isPresented: $confirmsOCRReset) {
            Button("Werte zurücksetzen und neu prüfen", role: .destructive) {
                state.resetOCRData()
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Original-PDFs werden nicht gelöscht oder verschoben.")
        }
        .confirmationDialog("Dokumentindex vollständig löschen?", isPresented: $confirmsIndexDeletion) {
            Button("Weiter …", role: .destructive) {
                confirmsIndexDeletionFinally = true
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Dies entfernt sämtliche Dokument-, OCR-, Analyse-, Wartungs- und Suchdaten einschließlich manueller Entscheidungen. PDFs, Modelle und Einstellungen bleiben erhalten.")
        }
        .confirmationDialog(
            "Letzte Bestätigung: vollständigen Dokumentindex löschen?",
            isPresented: $confirmsIndexDeletionFinally
        ) {
            Button("Endgültig aus SQLite löschen", role: .destructive) {
                state.deleteDocumentIndex()
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Die Indexdaten können nur durch einen erneuten Scan und erneute Verarbeitung wiederhergestellt werden.")
        }
        .confirmationDialog(
            "Alten Speicherbestand in den Papierkorb verschieben?",
            isPresented: $confirmsOldStorageRemoval
        ) {
            Button("In den Papierkorb verschieben", role: .destructive) {
                state.movePreviousStorageToTrash()
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Nur der nach erfolgreicher Migration zurückbehaltene Altbestand wird entfernt. Der aktive Speicher bleibt geschützt.")
        }
        .confirmationDialog(
            "Temporäre Daten bereinigen?",
            isPresented: $confirmsTemporaryCleanup
        ) {
            Button("Temporäre Daten in Papierkorb verschieben", role: .destructive) {
                state.cleanTemporaryStorage()
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Nur unvollständige Modelldownloads werden entfernt. Dokumente, E-Mails, Index und installierte Modelle bleiben erhalten.")
        }
    }

    private func storageRow(_ title: LocalizedStringKey, _ bytes: Int64) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                .monospacedDigit()
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
                Button("Statuswerte prüfen") {
                    Task { await state.checkStatusValues() }
                }
                Button("Log exportieren …") { state.exportLog() }
                TextField("Protokoll filtern", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                Spacer()
            }
            .padding([.horizontal, .top])
            if let message = state.statusDiagnosticMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .textSelection(.enabled)
            }
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
        .navigationTitle(state.localizedSectionTitle(.logs))
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
