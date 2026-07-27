import Darwin
import Foundation
import PDFKit

public protocol TrashManaging: Sendable {
    func trashItem(at url: URL) throws -> URL
    func restoreItem(from trashedURL: URL, to originalURL: URL) throws
}

public struct MacOSTrashManager: TrashManaging {
    public init() {}

    public func trashItem(at url: URL) throws -> URL {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(
            at: url,
            resultingItemURL: &resultingURL
        )
        guard let result = resultingURL as URL? else {
            throw FindoraError.processFailed(
                "macOS hat keinen wiederherstellbaren Papierkorbpfad zurückgegeben."
            )
        }
        return result
    }

    public func restoreItem(from trashedURL: URL, to originalURL: URL) throws {
        guard !FileManager.default.fileExists(atPath: originalURL.path) else {
            throw FindoraError.processFailed(
                "Die ursprüngliche Position ist beim Wiederherstellen bereits belegt."
            )
        }
        try FileManager.default.moveItem(at: trashedURL, to: originalURL)
    }
}

public actor DocumentMaintenanceService {
    private let database: SQLiteDatabase
    private let trashManager: any TrashManaging
    private let hasher: SHA256Hasher

    public init(
        database: SQLiteDatabase,
        trashManager: any TrashManaging = MacOSTrashManager(),
        hasher: SHA256Hasher = SHA256Hasher()
    ) {
        self.database = database
        self.trashManager = trashManager
        self.hasher = hasher
    }

    @discardableResult
    public func analyzeMissingPages() async throws -> Int {
        let files = try await database.filesMissingPageContentAnalysis()
        let analyzer = PageContentAnalyzer()
        var completed = 0
        for file in files {
            try Task.checkCancellation()
            let url = URL(filePath: file.path)
            try verifyHash(of: url, expected: file.hash)
            let analyses = try analyzer.analyze(fileAt: url)
            try await database.replacePageContentAnalyses(
                path: file.path,
                originalHash: file.hash,
                analyses: analyses
            )
            completed += 1
        }
        return completed
    }

    public func reanalyzePage(
        path: String,
        expectedHash: String,
        pageNumber: Int
    ) async throws -> PageContentAnalysis {
        try Task.checkCancellation()
        let url = URL(filePath: path)
        try verifyHash(of: url, expected: expectedHash)
        let analyses = try PageContentAnalyzer().analyze(fileAt: url)
        guard let requested = analyses.first(where: {
            $0.pageNumber == pageNumber
        }) else {
            throw FindoraError.invalidPDF(
                "Die ausgewählte Seite ist in der aktuellen PDF nicht mehr vorhanden."
            )
        }
        try await database.replacePageContentAnalyses(
            path: path,
            originalHash: expectedHash,
            analyses: analyses
        )
        return requested
    }

    @discardableResult
    public func trashDuplicateLocations(
        expectedHashesByPath: [String: String]
    ) async throws -> Int {
        guard !expectedHashesByPath.isEmpty else { return 0 }
        let groups = try await database.duplicateGroups()
        var coveredPaths: Set<String> = []
        for group in groups {
            let groupPaths = Set(group.locations.map(\.absolutePath))
            let selected = groupPaths.intersection(expectedHashesByPath.keys)
            guard selected.count < group.locations.count else {
                throw FindoraError.processFailed(
                    "Mindestens eine Datei jeder Duplikatgruppe muss erhalten bleiben."
                )
            }
            for path in selected {
                guard expectedHashesByPath[path] == group.contentHash else {
                    throw FindoraError.processFailed(
                        "Die Duplikatauswahl passt nicht mehr zum geprüften SHA-256."
                    )
                }
            }
            coveredPaths.formUnion(selected)
        }
        guard coveredPaths == Set(expectedHashesByPath.keys) else {
            throw FindoraError.processFailed(
                "Mindestens eine ausgewählte Datei ist kein aktuell bestätigtes SHA-256-Duplikat."
            )
        }
        return try await trashVerifiedFiles(expectedHashesByPath)
    }

    @discardableResult
    public func trashEmptyPDFs(_ candidates: [EmptyPDFCandidate]) async throws -> Int {
        let expected = Dictionary(
            uniqueKeysWithValues: candidates.map { ($0.absolutePath, $0.originalHash) }
        )
        guard !expected.isEmpty else { return 0 }
        let currentCandidates = Set(
            try await database.emptyPDFCandidates().map(\.absolutePath)
        )
        guard Set(expected.keys).isSubset(of: currentCandidates) else {
            throw FindoraError.processFailed(
                "Die Leerseitenanalyse hat sich geändert. Bitte die Auswahl erneut prüfen."
            )
        }
        return try await trashVerifiedFiles(expected)
    }

    public func trashEmptyPDFsIndividually(
        _ candidates: [EmptyPDFCandidate]
    ) async -> MaintenanceBatchResult {
        let current = (try? await database.emptyPDFCandidates()) ?? []
        let currentByPath = Dictionary(uniqueKeysWithValues: current.map {
            ($0.absolutePath, $0.originalHash)
        })
        var succeeded: [String] = []
        var skipped: [String] = []
        var failures: [MaintenanceActionFailure] = []
        for candidate in candidates {
            guard currentByPath[candidate.absolutePath] == candidate.originalHash else {
                skipped.append(candidate.fileName)
                continue
            }
            do {
                _ = try await trashVerifiedFiles([
                    candidate.absolutePath: candidate.originalHash
                ])
                succeeded.append(candidate.fileName)
            } catch {
                failures.append(
                    MaintenanceActionFailure(
                        id: candidate.absolutePath,
                        objectName: candidate.fileName,
                        reason: Self.safeActionReason(error)
                    )
                )
            }
        }
        return MaintenanceBatchResult(
            succeeded: succeeded,
            skipped: skipped,
            failures: failures
        )
    }

    public func removeEmptyPDFsFromIndex(
        _ candidates: [EmptyPDFCandidate]
    ) async -> MaintenanceBatchResult {
        let current = (try? await database.emptyPDFCandidates()) ?? []
        let currentByPath = Dictionary(uniqueKeysWithValues: current.map {
            ($0.absolutePath, $0.originalHash)
        })
        var succeeded: [String] = []
        var skipped: [String] = []
        var failures: [MaintenanceActionFailure] = []
        for candidate in candidates {
            guard currentByPath[candidate.absolutePath] == candidate.originalHash else {
                skipped.append(candidate.fileName)
                continue
            }
            do {
                try verifyHash(
                    of: URL(filePath: candidate.absolutePath),
                    expected: candidate.originalHash
                )
                try await database.markPathsRemoved([candidate.absolutePath])
                succeeded.append(candidate.fileName)
            } catch {
                failures.append(
                    MaintenanceActionFailure(
                        id: candidate.absolutePath,
                        objectName: candidate.fileName,
                        reason: Self.safeActionReason(error)
                    )
                )
            }
        }
        return MaintenanceBatchResult(
            succeeded: succeeded,
            skipped: skipped,
            failures: failures
        )
    }

    public func removeOCRReviewEntries(
        _ candidates: [OCRReviewCandidate]
    ) async -> MaintenanceBatchResult {
        var succeeded: [String] = []
        var failures: [MaintenanceActionFailure] = []
        for candidate in candidates {
            do {
                try await database.setPageReviewDecision(
                    path: candidate.absolutePath,
                    pageNumber: candidate.pageNumber,
                    decision: .excluded
                )
                succeeded.append("\(candidate.fileName), Seite \(candidate.pageNumber)")
            } catch {
                failures.append(
                    MaintenanceActionFailure(
                        id: candidate.id,
                        objectName: "\(candidate.fileName), Seite \(candidate.pageNumber)",
                        reason: Self.safeActionReason(error)
                    )
                )
            }
        }
        return MaintenanceBatchResult(succeeded: succeeded, failures: failures)
    }

    public func removeOCRReviewDocumentsFromIndex(
        _ candidates: [OCRReviewCandidate]
    ) async -> MaintenanceBatchResult {
        let currentIDs = Set(
            ((try? await database.ocrReviewCandidates()) ?? []).map(\.id)
        )
        let byPath = Dictionary(grouping: candidates, by: \.absolutePath)
        var succeeded: [String] = []
        var failures: [MaintenanceActionFailure] = []
        for (path, values) in byPath {
            guard let candidate = values.first else { continue }
            guard values.contains(where: { currentIDs.contains($0.id) }) else {
                failures.append(
                    MaintenanceActionFailure(
                        id: path,
                        objectName: candidate.fileName,
                        reason: "Der OCR-Prüfstatus hat sich geändert. Bitte die Auswahl aktualisieren."
                    )
                )
                continue
            }
            do {
                try verifyHash(
                    of: URL(filePath: path),
                    expected: candidate.originalHash
                )
                try await database.markPathsRemoved([path])
                succeeded.append(candidate.fileName)
            } catch {
                failures.append(
                    MaintenanceActionFailure(
                        id: path,
                        objectName: candidate.fileName,
                        reason: Self.safeActionReason(error)
                    )
                )
            }
        }
        return MaintenanceBatchResult(succeeded: succeeded, failures: failures)
    }

    public func trashOCRReviewDocuments(
        _ candidates: [OCRReviewCandidate]
    ) async -> MaintenanceBatchResult {
        let currentIDs = Set(
            ((try? await database.ocrReviewCandidates()) ?? []).map(\.id)
        )
        let byPath = Dictionary(grouping: candidates, by: \.absolutePath)
        var succeeded: [String] = []
        var failures: [MaintenanceActionFailure] = []
        for (path, values) in byPath {
            guard let candidate = values.first else { continue }
            guard values.contains(where: { currentIDs.contains($0.id) }) else {
                failures.append(
                    MaintenanceActionFailure(
                        id: path,
                        objectName: candidate.fileName,
                        reason: "Der OCR-Prüfstatus hat sich geändert. Bitte die Auswahl aktualisieren."
                    )
                )
                continue
            }
            do {
                _ = try await trashVerifiedFiles([path: candidate.originalHash])
                succeeded.append(candidate.fileName)
            } catch {
                failures.append(
                    MaintenanceActionFailure(
                        id: path,
                        objectName: candidate.fileName,
                        reason: Self.safeActionReason(error)
                    )
                )
            }
        }
        return MaintenanceBatchResult(succeeded: succeeded, failures: failures)
    }

    public func removeMailDuplicateExemplarsFromIndex(
        _ exemplars: [MailDuplicateExemplar]
    ) async -> MaintenanceBatchResult {
        let currentGroups = (try? await database.mailDuplicateGroups()) ?? []
        var succeeded: [String] = []
        var skipped: [String] = []
        var failures: [MaintenanceActionFailure] = []
        for exemplar in exemplars {
            guard !exemplar.isReference else {
                skipped.append(exemplar.sourceName)
                continue
            }
            do {
                try verifyCurrentMailDuplicate(
                    exemplar,
                    in: currentGroups
                )
                _ = try await database.removeMailDuplicateExemplars(
                    linkIDs: [exemplar.id]
                )
                succeeded.append(exemplar.sourceName)
            } catch {
                failures.append(
                    MaintenanceActionFailure(
                        id: String(exemplar.id),
                        objectName: exemplar.sourceName,
                        reason: Self.safeActionReason(error)
                    )
                )
            }
        }
        return MaintenanceBatchResult(
            succeeded: succeeded,
            skipped: skipped,
            failures: failures
        )
    }

    public func trashMailDuplicateExemplars(
        _ exemplars: [MailDuplicateExemplar]
    ) async -> MaintenanceBatchResult {
        let currentGroups = (try? await database.mailDuplicateGroups()) ?? []
        var succeeded: [String] = []
        var skipped: [String] = []
        var failures: [MaintenanceActionFailure] = []
        for exemplar in exemplars {
            guard !exemplar.isReference,
                  exemplar.isIndividualFile,
                  let path = exemplar.sourceFilePath,
                  let expectedHash = exemplar.sourceFileHash else {
                skipped.append(exemplar.sourceName)
                continue
            }
            let originalURL = URL(filePath: path)
            do {
                try verifyCurrentMailDuplicate(
                    exemplar,
                    in: currentGroups
                )
                try verifyHash(of: originalURL, expected: expectedHash)
                let trashedURL = try trashManager.trashItem(at: originalURL)
                do {
                    _ = try await database.removeMailDuplicateExemplars(
                        linkIDs: [exemplar.id]
                    )
                } catch {
                    try trashManager.restoreItem(from: trashedURL, to: originalURL)
                    throw error
                }
                succeeded.append(originalURL.lastPathComponent)
            } catch {
                failures.append(
                    MaintenanceActionFailure(
                        id: String(exemplar.id),
                        objectName: originalURL.lastPathComponent,
                        reason: Self.safeActionReason(error)
                    )
                )
            }
        }
        return MaintenanceBatchResult(
            succeeded: succeeded,
            skipped: skipped,
            failures: failures
        )
    }

    private func verifyCurrentMailDuplicate(
        _ exemplar: MailDuplicateExemplar,
        in groups: [MailDuplicateGroup]
    ) throws {
        guard let group = groups.first(where: {
            $0.exemplars.contains(where: { $0.id == exemplar.id })
        }),
        let current = group.exemplars.first(where: { $0.id == exemplar.id }),
        !current.isReference,
        current.sourceFilePath == exemplar.sourceFilePath,
        current.sourceFileHash == exemplar.sourceFileHash,
        let reference = group.exemplars.first(where: \.isReference) else {
            throw FindoraError.processFailed(
                "Die Mail-Dublettengruppe oder ihr Referenzexemplar ist nicht mehr aktuell."
            )
        }
        if reference.isIndividualFile {
            guard let path = reference.sourceFilePath,
                  let hash = reference.sourceFileHash else {
                throw FindoraError.processFailed(
                    "Das Referenzexemplar kann nicht sicher geprüft werden."
                )
            }
            try verifyHash(of: URL(filePath: path), expected: hash)
        } else {
            let referencePath = reference.sourceFilePath ?? reference.sourcePath
            guard FileManager.default.fileExists(atPath: referencePath) else {
                throw FindoraError.processFailed(
                    "Die Mailquelle des Referenzexemplars ist nicht mehr erreichbar."
                )
            }
        }
    }

    public func removePages(
        from candidate: EmptyPageCandidate,
        pageNumbers: Set<Int>
    ) async throws {
        guard !pageNumbers.isEmpty,
              pageNumbers.allSatisfy({ (1...candidate.pageCount).contains($0) }),
              pageNumbers.count < candidate.pageCount else {
            throw FindoraError.processFailed(
                "Einzelne Seiten dürfen nur entfernt werden, wenn mindestens eine Seite erhalten bleibt."
            )
        }
        let currentCandidates = try await database.emptyPageCandidates()
        let confirmed = currentCandidates.filter {
            $0.absolutePath == candidate.absolutePath
                && pageNumbers.contains($0.pageNumber)
                && $0.decision == .confirmedEmpty
                && $0.status.isEmptyCandidate
                && $0.originalHash == candidate.originalHash
        }
        guard confirmed.count == pageNumbers.count else {
            throw FindoraError.processFailed(
                "Alle ausgewählten Seiten müssen zuvor ausdrücklich als leer bestätigt werden."
            )
        }

        let originalURL = URL(filePath: candidate.absolutePath)
        try verifyHash(of: originalURL, expected: candidate.originalHash)
        guard let source = PDFDocument(url: originalURL),
              !source.isLocked,
              source.pageCount == candidate.pageCount else {
            throw FindoraError.invalidPDF(
                "Die Ausgangs-PDF ist nicht mehr in dem geprüften Zustand."
            )
        }
        let remainingIndexes = (0..<source.pageCount).filter {
            !pageNumbers.contains($0 + 1)
        }
        let originalFingerprints = try pageFingerprints(
            document: source,
            indexes: remainingIndexes
        )
        let output = PDFDocument()
        for index in remainingIndexes {
            guard let page = source.page(at: index)?.copy() as? PDFPage else {
                throw FindoraError.invalidPDF(
                    "Eine zu erhaltende Seite konnte nicht kopiert werden."
                )
            }
            output.insert(page, at: output.pageCount)
        }

        let temporaryURL = originalURL
            .deletingLastPathComponent()
            .appending(
                path: ".Findora-new-\(UUID().uuidString).pdf",
                directoryHint: .notDirectory
            )
        defer {
            if FileManager.default.fileExists(atPath: temporaryURL.path) {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }
        guard output.write(to: temporaryURL),
              let validation = PDFDocument(url: temporaryURL),
              !validation.isLocked,
              validation.pageCount == remainingIndexes.count else {
            throw FindoraError.invalidPDF(
                "Die neu erzeugte PDF hat die Seitenzahl- oder Lesbarkeitsprüfung nicht bestanden."
            )
        }
        let outputFingerprints = try pageFingerprints(
            document: validation,
            indexes: Array(0..<validation.pageCount)
        )
        guard originalFingerprints == outputFingerprints else {
            throw FindoraError.invalidPDF(
                "Reihenfolge oder Darstellung der zu erhaltenden Seiten stimmt nicht überein."
            )
        }
        try verifyHash(of: originalURL, expected: candidate.originalHash)

        try Self.atomicSwap(originalURL, temporaryURL)
        let trashedOriginal: URL
        do {
            trashedOriginal = try trashManager.trashItem(at: temporaryURL)
        } catch {
            try? Self.atomicSwap(originalURL, temporaryURL)
            throw error
        }

        do {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: originalURL.path
            )
            try await database.markPathForReindex(
                path: originalURL.path,
                size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                modifiedAt: attributes[.modificationDate] as? Date ?? .now
            )
        } catch {
            do {
                try trashManager.restoreItem(
                    from: trashedOriginal,
                    to: temporaryURL
                )
                try Self.atomicSwap(originalURL, temporaryURL)
            } catch let rollbackError {
                throw FindoraError.processFailed(
                    "Datenbankaktualisierung und Wiederherstellung sind fehlgeschlagen: \(rollbackError.localizedDescription)"
                )
            }
            throw error
        }
    }

    private func trashVerifiedFiles(
        _ expectedHashesByPath: [String: String]
    ) async throws -> Int {
        let orderedPaths = expectedHashesByPath.keys.sorted()
        for path in orderedPaths {
            guard let expected = expectedHashesByPath[path] else { continue }
            try verifyHash(of: URL(filePath: path), expected: expected)
        }

        var moved: [(original: URL, trashed: URL)] = []
        do {
            for path in orderedPaths {
                let original = URL(filePath: path)
                let trashed = try trashManager.trashItem(at: original)
                moved.append((original, trashed))
            }
            try await database.markPathsRemoved(orderedPaths)
            return moved.count
        } catch {
            var rollbackFailure: Error?
            for item in moved.reversed() {
                do {
                    try trashManager.restoreItem(
                        from: item.trashed,
                        to: item.original
                    )
                } catch {
                    rollbackFailure = error
                }
            }
            if let rollbackFailure {
                throw FindoraError.processFailed(
                    "Papierkorbvorgang und Wiederherstellung sind fehlgeschlagen: \(rollbackFailure.localizedDescription)"
                )
            }
            throw error
        }
    }

    private func verifyHash(of url: URL, expected: String) throws {
        guard FileManager.default.fileExists(atPath: url.path),
              try hasher.hash(fileAt: url) == expected else {
            throw FindoraError.processFailed(
                "Die Datei wurde seit der Prüfung verändert; die Wartungsaktion wurde abgebrochen."
            )
        }
    }

    private static func safeActionReason(_ error: Error) -> String {
        if let error = error as? FindoraError {
            return error.localizedDescription
        }
        return "Der Vorgang konnte für dieses Objekt nicht sicher abgeschlossen werden."
    }

    private func pageFingerprints(
        document: PDFDocument,
        indexes: [Int]
    ) throws -> [String] {
        try indexes.map { index in
            guard let page = document.page(at: index) else {
                throw FindoraError.invalidPDF(
                    "Eine Seite konnte für die Integritätsprüfung nicht gelesen werden."
                )
            }
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width > 0, bounds.height > 0 else {
                throw FindoraError.invalidPDF(
                    "Eine zu erhaltende Seite besitzt keine gültige Seitengröße."
                )
            }
            let width = 256
            let height = max(1, Int((CGFloat(width) * bounds.height / bounds.width).rounded()))
            var pixels = [UInt8](repeating: 255, count: width * height)
            let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
                guard let context = CGContext(
                    data: bytes.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                ) else { return false }
                context.setFillColor(gray: 1, alpha: 1)
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.scaleBy(
                    x: CGFloat(width) / bounds.width,
                    y: CGFloat(height) / bounds.height
                )
                context.translateBy(x: -bounds.minX, y: -bounds.minY)
                page.draw(with: .mediaBox, to: context)
                return true
            }
            guard rendered else {
                throw FindoraError.invalidPDF(
                    "Eine zu erhaltende Seite konnte nicht gerendert werden."
                )
            }
            let text = (page.string ?? "").data(using: .utf8) ?? Data()
            let metadata = Data(
                "\(bounds.width)x\(bounds.height)#\(page.annotations.count)#".utf8
            )
            return hasher.hash(data: Data(pixels) + text + metadata)
        }
    }

    private static func atomicSwap(_ first: URL, _ second: URL) throws {
        let result = first.path.withCString { firstPath in
            second.path.withCString { secondPath in
                renameatx_np(
                    AT_FDCWD,
                    firstPath,
                    AT_FDCWD,
                    secondPath,
                    UInt32(RENAME_SWAP)
                )
            }
        }
        guard result == 0 else {
            throw FindoraError.processFailed(
                "Der atomare PDF-Austausch ist fehlgeschlagen: \(String(cString: strerror(errno)))"
            )
        }
    }
}
