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
            throw PrivateDocSearchError.processFailed(
                "macOS hat keinen wiederherstellbaren Papierkorbpfad zurückgegeben."
            )
        }
        return result
    }

    public func restoreItem(from trashedURL: URL, to originalURL: URL) throws {
        guard !FileManager.default.fileExists(atPath: originalURL.path) else {
            throw PrivateDocSearchError.processFailed(
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
                throw PrivateDocSearchError.processFailed(
                    "Mindestens eine Datei jeder Duplikatgruppe muss erhalten bleiben."
                )
            }
            for path in selected {
                guard expectedHashesByPath[path] == group.contentHash else {
                    throw PrivateDocSearchError.processFailed(
                        "Die Duplikatauswahl passt nicht mehr zum geprüften SHA-256."
                    )
                }
            }
            coveredPaths.formUnion(selected)
        }
        guard coveredPaths == Set(expectedHashesByPath.keys) else {
            throw PrivateDocSearchError.processFailed(
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
            throw PrivateDocSearchError.processFailed(
                "Die Leerseitenanalyse hat sich geändert. Bitte die Auswahl erneut prüfen."
            )
        }
        return try await trashVerifiedFiles(expected)
    }

    public func removePages(
        from candidate: EmptyPageCandidate,
        pageNumbers: Set<Int>
    ) async throws {
        guard !pageNumbers.isEmpty,
              pageNumbers.allSatisfy({ (1...candidate.pageCount).contains($0) }),
              pageNumbers.count < candidate.pageCount else {
            throw PrivateDocSearchError.processFailed(
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
            throw PrivateDocSearchError.processFailed(
                "Alle ausgewählten Seiten müssen zuvor ausdrücklich als leer bestätigt werden."
            )
        }

        let originalURL = URL(filePath: candidate.absolutePath)
        try verifyHash(of: originalURL, expected: candidate.originalHash)
        guard let source = PDFDocument(url: originalURL),
              !source.isLocked,
              source.pageCount == candidate.pageCount else {
            throw PrivateDocSearchError.invalidPDF(
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
                throw PrivateDocSearchError.invalidPDF(
                    "Eine zu erhaltende Seite konnte nicht kopiert werden."
                )
            }
            output.insert(page, at: output.pageCount)
        }

        let temporaryURL = originalURL
            .deletingLastPathComponent()
            .appending(
                path: ".PrivateDocSearch-new-\(UUID().uuidString).pdf",
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
            throw PrivateDocSearchError.invalidPDF(
                "Die neu erzeugte PDF hat die Seitenzahl- oder Lesbarkeitsprüfung nicht bestanden."
            )
        }
        let outputFingerprints = try pageFingerprints(
            document: validation,
            indexes: Array(0..<validation.pageCount)
        )
        guard originalFingerprints == outputFingerprints else {
            throw PrivateDocSearchError.invalidPDF(
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
                throw PrivateDocSearchError.processFailed(
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
                throw PrivateDocSearchError.processFailed(
                    "Papierkorbvorgang und Wiederherstellung sind fehlgeschlagen: \(rollbackFailure.localizedDescription)"
                )
            }
            throw error
        }
    }

    private func verifyHash(of url: URL, expected: String) throws {
        guard FileManager.default.fileExists(atPath: url.path),
              try hasher.hash(fileAt: url) == expected else {
            throw PrivateDocSearchError.processFailed(
                "Die Datei wurde seit der Prüfung verändert; die Wartungsaktion wurde abgebrochen."
            )
        }
    }

    private func pageFingerprints(
        document: PDFDocument,
        indexes: [Int]
    ) throws -> [String] {
        try indexes.map { index in
            guard let page = document.page(at: index) else {
                throw PrivateDocSearchError.invalidPDF(
                    "Eine Seite konnte für die Integritätsprüfung nicht gelesen werden."
                )
            }
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width > 0, bounds.height > 0 else {
                throw PrivateDocSearchError.invalidPDF(
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
                throw PrivateDocSearchError.invalidPDF(
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
            throw PrivateDocSearchError.processFailed(
                "Der atomare PDF-Austausch ist fehlgeschlagen: \(String(cString: strerror(errno)))"
            )
        }
    }
}
