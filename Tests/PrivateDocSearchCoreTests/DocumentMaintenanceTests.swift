import AppKit
import CoreText
import Foundation
import PDFKit
import Testing
@testable import PrivateDocSearchCore

@Test
func documentStatusHasExactlyFourPrimaryMetrics() {
    #expect(
        DocumentStatusPrimaryMetric.allCases
            == [.totalPDFs, .indexedPDFs, .pendingJobs, .duplicates]
    )
}

@Test
func pageContentAnalysisDistinguishesBlankVisualAndTextPages() throws {
    let root = maintenanceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let visualPDF = root.appending(path: "Seitenanalyse.pdf")
    try createMaintenancePDF(
        at: visualPDF,
        pages: [
            .blank,
            .separator,
            .signature,
            .stamp,
            .lowContrast,
            .smallMarginNote
        ]
    )
    let analyses = try PageContentAnalyzer().analyze(fileAt: visualPDF)
    #expect(analyses.count == 6)
    #expect(analyses[0].status == .fullyEmpty)
    #expect(analyses[1].status == .needsOCRReview)
    #expect(analyses[2].status == .needsOCRReview)
    #expect(analyses[3].status == .needsOCRReview)
    #expect(analyses[4].status == .needsOCRReview)
    #expect(analyses[5].status == .content)
    #expect(analyses[5].metrics.hasSmallText)
    #expect(analyses.dropFirst().allSatisfy { !$0.status.isEmptyCandidate })

    let imagePDF = root.appending(path: "Bild-ohne-Text.pdf")
    try createMaintenanceImagePDF(at: imagePDF)
    let image = try #require(
        PageContentAnalyzer().analyze(fileAt: imagePDF).first
    )
    #expect(image.status == .imageWithoutText)
    #expect(image.metrics.embeddedImageCount > 0)
}

@Test
func fullyEmptyPDFAndSingleEmptyPageArePersistedSeparately() async throws {
    let root = maintenanceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        applicationSupport: root.appending(path: "Support"),
        logs: root.appending(path: "Logs")
    )
    let blank = root.appending(path: "Komplett leer.pdf")
    try createMaintenancePDF(at: blank, pages: [.blank, .blank])
    let mixed = root.appending(path: "Gemischt.pdf")
    try createMaintenancePDF(
        at: mixed,
        pages: [.text("Erste Inhaltsseite"), .blank, .text("Letzte Inhaltsseite")]
    )
    let database = SQLiteDatabase(url: paths.database)
    try await database.initialize()
    let scanner = RecursivePDFScanner(excludedRoots: [paths.applicationSupport])
    try await database.saveScan(files: try await scanner.scan(root: root), root: root)
    await maintenanceProcessor(database: database).processPending(
        ocrConfiguration: OCRConfiguration(isEnabled: false)
    ) { _ in }

    let candidates = try await database.emptyPageCandidates()
    #expect(candidates.filter { $0.fileName == "Komplett leer.pdf" }.count == 2)
    #expect(
        candidates.contains {
            $0.fileName == "Gemischt.pdf"
                && $0.pageNumber == 2
                && $0.status == .fullyEmpty
        }
    )
    let emptyPDFs = try await database.emptyPDFCandidates()
    #expect(emptyPDFs.map(\.fileName) == ["Komplett leer.pdf"])
    #expect(emptyPDFs.first?.pageCount == 2)
}

@Test
func confirmedEmptyPageRemovalKeepsPDFValidAndQueuesTargetedReindex() async throws {
    let root = maintenanceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        applicationSupport: root.appending(path: "Support"),
        logs: root.appending(path: "Logs")
    )
    let pdf = root.appending(path: "Mit leerer Seite.pdf")
    try createMaintenancePDF(
        at: pdf,
        pages: [
            .text("INHALT EINS " + String(repeating: "Erste Seite. ", count: 8)),
            .blank,
            .text("INHALT ZWEI " + String(repeating: "Zweite Seite. ", count: 8))
        ]
    )
    let database = SQLiteDatabase(url: paths.database)
    try await database.initialize()
    let scanner = RecursivePDFScanner(excludedRoots: [paths.applicationSupport])
    try await database.saveScan(files: try await scanner.scan(root: root), root: root)
    await maintenanceProcessor(database: database).processPending(
        ocrConfiguration: OCRConfiguration(isEnabled: false)
    ) { _ in }
    try await database.setPageReviewDecision(
        path: pdf.path,
        pageNumber: 2,
        decision: .confirmedEmpty
    )
    let candidate = try #require(
        try await database.emptyPageCandidates().first {
            $0.absolutePath == pdf.path && $0.pageNumber == 2
        }
    )
    let trash = TestTrashManager(
        directory: root.appending(path: "Trash", directoryHint: .isDirectory)
    )
    try await DocumentMaintenanceService(
        database: database,
        trashManager: trash
    ).removePages(from: candidate, pageNumbers: [2])

    let result = try #require(PDFDocument(url: pdf))
    #expect(result.pageCount == 2)
    #expect(result.page(at: 0)?.string?.contains("INHALT EINS") == true)
    #expect(result.page(at: 1)?.string?.contains("INHALT ZWEI") == true)
    #expect(try await database.pendingFiles().map(\.url.path) == [pdf.path])
    #expect(trash.trashedItemCount == 1)
    let embedder = TokenHashEmbedding(dimensions: 64)
    await DocumentProcessor(
        database: database,
        stabilityChecker: FileStabilityChecker(delay: .zero),
        embedder: embedder
    ).processPending(ocrConfiguration: OCRConfiguration(isEnabled: false)) { _ in }
    let reindexed = try await HybridSearchService(
        database: database,
        embedder: embedder
    ).search("INHALT ZWEI")
    #expect(reindexed.first?.pageNumber == 2)
}

@Test
func emptyPDFTrashUpdatesDatabaseOnlyAfterRecoverableMove() async throws {
    let root = maintenanceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        applicationSupport: root.appending(path: "Support"),
        logs: root.appending(path: "Logs")
    )
    let pdf = root.appending(path: "Leer.pdf")
    try createMaintenancePDF(at: pdf, pages: [.blank])
    let database = SQLiteDatabase(url: paths.database)
    try await database.initialize()
    let scanner = RecursivePDFScanner(excludedRoots: [paths.applicationSupport])
    try await database.saveScan(files: try await scanner.scan(root: root), root: root)
    await maintenanceProcessor(database: database).processPending(
        ocrConfiguration: OCRConfiguration(isEnabled: false)
    ) { _ in }
    let candidate = try #require(try await database.emptyPDFCandidates().first)
    let trash = TestTrashManager(
        directory: root.appending(path: "Trash", directoryHint: .isDirectory)
    )
    let count = try await DocumentMaintenanceService(
        database: database,
        trashManager: trash
    ).trashEmptyPDFs([candidate])
    #expect(count == 1)
    #expect(!FileManager.default.fileExists(atPath: pdf.path))
    #expect(try await database.emptyPDFCandidates().isEmpty)
    #expect(try await database.statistics().totalPDFs == 0)
    #expect(trash.trashedItemCount == 1)
}

@Test
func duplicatesRequireIdenticalSHA256AcrossDifferentLocations() async throws {
    let root = maintenanceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        applicationSupport: root.appending(path: "Support"),
        logs: root.appending(path: "Logs")
    )
    let archive = root.appending(path: "Dokumentenarchiv", directoryHint: .isDirectory)
    let downloads = root.appending(path: "Downloads", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    let keeper = archive.appending(path: "Vertrag.pdf")
    let duplicate = downloads.appending(path: "Vertrag Kopie.pdf")
    let sameNameDifferentContent = downloads.appending(path: "Vertrag.pdf")
    try createMaintenancePDF(
        at: keeper,
        pages: [.text("IDENTISCHER SYNTHETISCHER INHALT")]
    )
    try FileManager.default.copyItem(at: keeper, to: duplicate)
    try createMaintenancePDF(
        at: sameNameDifferentContent,
        pages: [.text("ANDERER SYNTHETISCHER INHALT")]
    )

    let database = SQLiteDatabase(url: paths.database)
    try await database.initialize()
    let scanner = RecursivePDFScanner(excludedRoots: [paths.applicationSupport])
    try await database.saveScan(files: try await scanner.scan(root: root), root: root)
    await maintenanceProcessor(database: database).processPending(
        ocrConfiguration: OCRConfiguration(isEnabled: false)
    ) { _ in }

    let group = try #require(try await database.duplicateGroups().first)
    #expect(
        Set(group.locations.map(\.absolutePath))
            == Set([keeper.path, duplicate.path])
    )
    #expect(group.recommendedLocation?.absolutePath == keeper.path)
    #expect(
        !group.locations.contains {
            $0.absolutePath == sameNameDifferentContent.path
        }
    )
    #expect(try await database.statistics().duplicateLocations == 1)

    let trash = TestTrashManager(
        directory: root.appending(path: "Trash", directoryHint: .isDirectory)
    )
    let removed = try await DocumentMaintenanceService(
        database: database,
        trashManager: trash
    ).trashDuplicateLocations(
        expectedHashesByPath: [duplicate.path: group.contentHash]
    )
    #expect(removed == 1)
    #expect(FileManager.default.fileExists(atPath: keeper.path))
    #expect(!FileManager.default.fileExists(atPath: duplicate.path))
    #expect(FileManager.default.fileExists(atPath: sameNameDifferentContent.path))
    #expect(try await database.duplicateGroups().isEmpty)
    #expect(try await database.statistics().duplicateLocations == 0)
}

@Test
func failedMultiFileTrashRestoresFilesAndLeavesDatabaseUnchanged() async throws {
    let root = maintenanceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        applicationSupport: root.appending(path: "Support"),
        logs: root.appending(path: "Logs")
    )
    let first = root.appending(path: "Original.pdf")
    let second = root.appending(path: "Kopie 1.pdf")
    let third = root.appending(path: "Kopie 2.pdf")
    try createMaintenancePDF(at: first, pages: [.text("ROLLBACK INHALT")])
    try FileManager.default.copyItem(at: first, to: second)
    try FileManager.default.copyItem(at: first, to: third)
    let database = SQLiteDatabase(url: paths.database)
    try await database.initialize()
    let scanner = RecursivePDFScanner(excludedRoots: [paths.applicationSupport])
    try await database.saveScan(files: try await scanner.scan(root: root), root: root)
    await maintenanceProcessor(database: database).processPending(
        ocrConfiguration: OCRConfiguration(isEnabled: false)
    ) { _ in }
    let group = try #require(try await database.duplicateGroups().first)
    let trash = FailingTrashManager(
        directory: root.appending(path: "Trash", directoryHint: .isDirectory),
        failureIndex: 2
    )
    var didFail = false
    do {
        _ = try await DocumentMaintenanceService(
            database: database,
            trashManager: trash
        ).trashDuplicateLocations(
            expectedHashesByPath: [
                second.path: group.contentHash,
                third.path: group.contentHash
            ]
        )
    } catch {
        didFail = true
    }
    #expect(didFail)
    #expect(FileManager.default.fileExists(atPath: first.path))
    #expect(FileManager.default.fileExists(atPath: second.path))
    #expect(FileManager.default.fileExists(atPath: third.path))
    #expect(try await database.duplicateGroups().first?.locations.count == 3)
    #expect(try await database.statistics().duplicateLocations == 2)
}

private enum MaintenancePage {
    case blank
    case separator
    case signature
    case stamp
    case lowContrast
    case smallMarginNote
    case text(String)
}

private func maintenanceTemporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "PrivateDocSearchMaintenanceTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func maintenanceProcessor(database: SQLiteDatabase) -> DocumentProcessor {
    DocumentProcessor(
        database: database,
        stabilityChecker: FileStabilityChecker(delay: .zero),
        embedder: TokenHashEmbedding(dimensions: 64)
    )
}

private func createMaintenancePDF(
    at url: URL,
    pages: [MaintenancePage]
) throws {
    var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
    guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
        throw PrivateDocSearchError.invalidPDF(
            "Synthetischer PDF-Kontext konnte nicht angelegt werden."
        )
    }
    for page in pages {
        context.beginPDFPage(nil)
        switch page {
        case .blank:
            break
        case .separator:
            context.setStrokeColor(gray: 0, alpha: 1)
            context.setLineWidth(3)
            context.move(to: CGPoint(x: 40, y: 421))
            context.addLine(to: CGPoint(x: 555, y: 421))
            context.strokePath()
        case .signature:
            context.setStrokeColor(gray: 0.05, alpha: 1)
            context.setLineWidth(2)
            context.move(to: CGPoint(x: 90, y: 120))
            context.addCurve(
                to: CGPoint(x: 330, y: 125),
                control1: CGPoint(x: 150, y: 190),
                control2: CGPoint(x: 230, y: 60)
            )
            context.strokePath()
        case .stamp:
            context.setStrokeColor(gray: 0.1, alpha: 1)
            context.setLineWidth(5)
            context.strokeEllipse(in: CGRect(x: 190, y: 330, width: 210, height: 120))
            context.move(to: CGPoint(x: 220, y: 390))
            context.addLine(to: CGPoint(x: 370, y: 390))
            context.strokePath()
        case .lowContrast:
            context.setStrokeColor(gray: 0.93, alpha: 1)
            context.setLineWidth(8)
            for offset in stride(from: 100, through: 700, by: 28) {
                context.move(to: CGPoint(x: 80, y: offset))
                context.addLine(to: CGPoint(x: 515, y: offset))
            }
            context.strokePath()
        case .smallMarginNote:
            drawMaintenanceText(
                "kleine Randnotiz",
                size: 5,
                at: CGPoint(x: 8, y: 18),
                in: context
            )
        case .text(let value):
            drawMaintenanceText(
                value,
                size: 24,
                at: CGPoint(x: 72, y: 760),
                in: context
            )
        }
        context.endPDFPage()
    }
    context.closePDF()
}

private func drawMaintenanceText(
    _ text: String,
    size: CGFloat,
    at point: CGPoint,
    in context: CGContext
) {
    let attributed = NSAttributedString(
        string: text,
        attributes: [
            .font: NSFont.systemFont(ofSize: size),
            .foregroundColor: NSColor.black
        ]
    )
    let line = CTLineCreateWithAttributedString(attributed)
    context.textPosition = point
    CTLineDraw(line, context)
}

private func createMaintenanceImagePDF(at url: URL) throws {
    let image = NSImage(size: NSSize(width: 1_000, height: 1_400))
    image.lockFocus()
    NSColor.white.setFill()
    NSRect(origin: .zero, size: image.size).fill()
    NSColor.black.setFill()
    NSBezierPath(
        roundedRect: NSRect(x: 120, y: 500, width: 760, height: 380),
        xRadius: 30,
        yRadius: 30
    ).fill()
    image.unlockFocus()
    guard let page = PDFPage(image: image) else {
        throw PrivateDocSearchError.invalidPDF("Bildseite konnte nicht erstellt werden.")
    }
    let document = PDFDocument()
    document.insert(page, at: 0)
    guard document.write(to: url) else {
        throw PrivateDocSearchError.invalidPDF("Bild-PDF konnte nicht geschrieben werden.")
    }
}

private final class TestTrashManager: TrashManaging, @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private var count = 0

    init(directory: URL) {
        self.directory = directory
    }

    var trashedItemCount: Int {
        lock.withLock { count }
    }

    func trashItem(at url: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let target = directory.appending(
            path: "\(UUID().uuidString)-\(url.lastPathComponent)"
        )
        try FileManager.default.moveItem(at: url, to: target)
        lock.withLock { count += 1 }
        return target
    }

    func restoreItem(from trashedURL: URL, to originalURL: URL) throws {
        try FileManager.default.moveItem(at: trashedURL, to: originalURL)
        lock.withLock { count -= 1 }
    }
}

private final class FailingTrashManager: TrashManaging, @unchecked Sendable {
    private let directory: URL
    private let failureIndex: Int
    private let lock = NSLock()
    private var attempts = 0

    init(directory: URL, failureIndex: Int) {
        self.directory = directory
        self.failureIndex = failureIndex
    }

    func trashItem(at url: URL) throws -> URL {
        let shouldFail = lock.withLock { () -> Bool in
            attempts += 1
            return attempts == failureIndex
        }
        if shouldFail {
            throw PrivateDocSearchError.processFailed(
                "Synthetischer Papierkorbfehler"
            )
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let target = directory.appending(
            path: "\(UUID().uuidString)-\(url.lastPathComponent)"
        )
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    func restoreItem(from trashedURL: URL, to originalURL: URL) throws {
        try FileManager.default.moveItem(at: trashedURL, to: originalURL)
    }
}
