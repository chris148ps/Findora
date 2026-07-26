import AppKit
import CoreText
import Foundation
import PDFKit
import Testing
@testable import FindoraCore

@Test
func mimeParserDecodesUnicodeHTMLRecipientsAndAttachments() throws {
    let raw = """
    Message-ID: <synthetic-1@example.test>
    Subject: =?UTF-8?Q?Pr=C3=BCfung_der_Wallbox?=
    From: =?UTF-8?Q?Mara_M=C3=BCller?= <mara@example.test>
    To: Theo <theo@example.test>
    Cc: Team <team@example.test>
    Date: Sat, 26 Jul 2026 12:30:00 +0200
    Content-Type: multipart/mixed; boundary="findora-boundary"

    --findora-boundary
    Content-Type: text/html; charset=utf-8

    <html><body><h1>Lokale Prüfung</h1><script>secret()</script><p>Nur auf diesem Mac.</p><img width="1" height="1" src="track.gif"></body></html>
    --findora-boundary
    Content-Type: text/plain; name="Notiz.txt"
    Content-Disposition: attachment; filename="Notiz.txt"
    Content-Transfer-Encoding: base64

    U3ludGhldGlzY2hlciBBbmhhbmc=
    --findora-boundary--
    """.replacingOccurrences(of: "\n", with: "\r\n")

    let mail = try MIMEMessageParser().parse(
        data: Data(raw.utf8),
        sourceFormat: .eml,
        sourceMailbox: "Testpostfach"
    )

    #expect(mail.subject == "Prüfung der Wallbox")
    #expect(mail.sender == MailAddress(name: "Mara Müller", address: "mara@example.test"))
    #expect(mail.recipients[.to]?.first?.address == "theo@example.test")
    #expect(mail.recipients[.cc]?.first?.address == "team@example.test")
    #expect(mail.normalizedText.contains("Lokale Prüfung"))
    #expect(mail.normalizedText.contains("Nur auf diesem Mac."))
    #expect(!mail.normalizedText.contains("secret()"))
    #expect(mail.attachments.count == 1)
    #expect(mail.attachments.first?.fileName == "Notiz.txt")
    #expect(String(data: mail.attachments[0].data, encoding: .utf8) == "Synthetischer Anhang")
}

@Test
func mboxStreamingReadsMultipleMessagesAndUnescapesFromLine() async throws {
    let root = try syntheticTemporaryDirectory("mbox")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "Postfach.mbox")
    let raw = """
    From sender@example.test Sat Jul 26 10:00:00 2026
    Message-ID: <one@example.test>
    Subject: Erste Mail
    From: sender@example.test
    Content-Type: text/plain; charset=utf-8

    Erste Nachricht
    >From bleibt Nachrichtentext
    From sender@example.test Sat Jul 26 11:00:00 2026
    Message-ID: <two@example.test>
    Subject: Zweite Mail
    From: sender@example.test
    Content-Type: text/plain; charset=utf-8

    Zweite Nachricht
    """
    try Data(raw.utf8).write(to: url)

    actor Collector {
        var mails: [ParsedMail] = []
        func append(_ mail: ParsedMail) { mails.append(mail) }
    }
    let collector = Collector()
    try await MailFileParser().forEachMessage(inMBOX: url) { mail in
        await collector.append(mail)
    }
    let mails = await collector.mails
    #expect(mails.map(\.subject) == ["Erste Mail", "Zweite Mail"])
    #expect(mails[0].normalizedText.contains("From bleibt Nachrichtentext"))
}

@Test
func syntheticUnicodeOutlookMSGIsParsedWithoutExternalDependency() throws {
    let data = syntheticMSG(
        subject: "Unicode – Grüße",
        body: "Lokaler Outlook-Inhalt",
        senderAddress: "outlook@example.test"
    )
    let mail = try OutlookMSGParser().parse(
        data: data,
        sourceMailbox: "Outlook-Test"
    )
    #expect(mail.sourceFormat == .outlookMSG)
    #expect(mail.subject == "Unicode – Grüße")
    #expect(mail.normalizedText == "Lokaler Outlook-Inhalt")
    #expect(mail.sender?.address == "outlook@example.test")
}

@Test
func mailImportDeduplicatesMessageAndAttachmentAndSearchFiltersContentTypes() async throws {
    let root = try syntheticTemporaryDirectory("mail-import")
    defer { try? FileManager.default.removeItem(at: root) }
    let support = root.appending(path: "Support")
    let logs = root.appending(path: "Logs")
    let paths = try AppPaths(applicationSupport: support, logs: logs)
    let database = SQLiteDatabase(url: paths.database)
    try await database.initialize()

    let attachment = Data("Gemeinsamer synthetischer Anhang Wallboxprüfung".utf8)
        .base64EncodedString()
    let message = """
    Message-ID: <dedupe@example.test>
    Subject: =?UTF-8?Q?Synthetische_Wallboxpr=C3=BCfung?=
    From: sender@example.test
    To: receiver@example.test
    Content-Type: multipart/mixed; boundary="b"

    --b
    Content-Type: text/plain; charset=utf-8

    Lokale Prüfdaten für das Projekt Nord.
    --b
    Content-Type: text/plain; name="Pruefung.txt"
    Content-Disposition: attachment; filename="Pruefung.txt"
    Content-Transfer-Encoding: base64

    \(attachment)
    --b--
    """.replacingOccurrences(of: "\n", with: "\r\n")
    let first = root.appending(path: "erste.eml")
    let second = root.appending(path: "zweite.eml")
    try Data(message.utf8).write(to: first)
    try Data(message.utf8).write(to: second)

    let service = MailImportService(
        database: database,
        embedder: TokenHashEmbedding(dimensions: 64),
        archiveRoot: paths.mailArchive
    )
    let summary = try await service.importSources(
        urls: [first, second],
        importMode: .referenced
    ) { _ in }
    #expect(summary.imported == 1)
    #expect(summary.duplicates == 1)

    let search = HybridSearchService(
        database: database,
        embedder: TokenHashEmbedding(dimensions: 64),
        semanticEnabled: false
    )
    let emails = try await search.search(
        "Wallboxprüfung",
        contentFilter: .emails
    )
    let attachments = try await search.search(
        "Gemeinsamer",
        contentFilter: .attachments
    )
    let documents = try await search.search(
        "Wallboxprüfung",
        contentFilter: .documents
    )
    #expect(emails.count == 1)
    #expect(emails.allSatisfy { $0.contentType == .email })
    #expect(attachments.count == 1)
    #expect(attachments.allSatisfy { $0.contentType == .emailAttachment })
    #expect(documents.isEmpty)
    #expect(attachments.first?.parentEmailSubject == "Synthetische Wallboxprüfung")
    for source in try await database.mailSources() {
        try await database.removeMailSource(sourceID: source.id)
    }
    let indexOnlyEmails = try await search.search(
        "Wallboxprüfung",
        contentFilter: .emails
    )
    #expect(indexOnlyEmails.count == 1)
    #expect(indexOnlyEmails.first?.absolutePath.isEmpty == true)
    #expect(try await database.databaseQuickCheck() == "ok")
}

@Test
func storageMigrationCopiesValidatesSwitchesAndKeepsOldData() async throws {
    let root = try syntheticTemporaryDirectory("storage")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "Source")
    let destination = root.appending(path: "Destination")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let database = SQLiteDatabase(url: source.appending(path: "Findora.sqlite3"))
    try await database.initialize()
    try await database.setSetting(key: "synthetic", value: "keine Produktivdaten")
    try await database.checkpointAndClose()
    try Data("Vorschaudaten".utf8).write(to: source.appending(path: "preview.bin"))

    let suiteName = "FindoraTests.Storage.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = StorageConfigurationStore(defaults: defaults)
    let service = StorageMigrationService(configurationStore: store)
    let estimate = try await service.estimateMigration(
        sourceURL: source,
        destinationParent: destination
    )
    #expect(estimate.fileCount >= 2)
    #expect(estimate.assessment.isAllowed)

    let migrated = try await service.migrate(
        kind: .data,
        sourceURL: source,
        destinationParent: destination
    ) { _ in }
    #expect(FileManager.default.fileExists(atPath: source.path))
    #expect(FileManager.default.fileExists(atPath: migrated.appending(path: "preview.bin").path))
    let migratedDatabase = SQLiteDatabase(url: migrated.appending(path: "Findora.sqlite3"))
    try await migratedDatabase.initialize()
    #expect(try await migratedDatabase.setting(key: "synthetic") == "keine Produktivdaten")
    #expect(try await migratedDatabase.databaseQuickCheck() == "ok")
    try await migratedDatabase.checkpointAndClose()
    #expect(try store.lastMigration()?.phase == .completed)
}

@Test
func missingConfiguredStorageIsReportedWithoutCreatingReplacementDatabase() throws {
    let root = try syntheticTemporaryDirectory("missing-storage")
    defer { try? FileManager.default.removeItem(at: root) }
    let external = root.appending(path: "ExternalFindora")
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
    let suiteName = "FindoraTests.MissingStorage.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = StorageConfigurationStore(defaults: defaults)
    try store.saveLocation(kind: .data, url: external)
    try FileManager.default.removeItem(at: external)

    let selection = try store.startupSelection()
    #expect(selection.dataIsCustom)
    #expect(!selection.dataIsAvailable)
    #expect(selection.dataURL == external)
    #expect(!FileManager.default.fileExists(atPath: external.path))
    #expect(
        !FileManager.default.fileExists(
            atPath: external.appending(path: "Findora.sqlite3").path
        )
    )
}

@Test
func removedDocumentPoliciesEitherKeepIndexOrOnlyMarkLocationMissing() async throws {
    let root = try syntheticTemporaryDirectory("document-policy")
    defer { try? FileManager.default.removeItem(at: root) }
    let support = root.appending(path: "Support")
    let paths = try AppPaths(
        applicationSupport: support,
        logs: root.appending(path: "Logs")
    )
    let pdf = root.appending(path: "Fuehrende Quelle.pdf")
    try writeSyntheticPDF(text: "Synthetischer Synchronisationstext", to: pdf)
    let database = SQLiteDatabase(url: paths.database)
    try await database.initialize()
    let scanner = RecursivePDFScanner(excludedRoots: [support])
    let processor = DocumentProcessor(
        database: database,
        stabilityChecker: FileStabilityChecker(delay: .zero),
        embedder: TokenHashEmbedding(dimensions: 64)
    )
    try await database.saveScan(files: try await scanner.scan(root: root), root: root)
    await processor.processPending(ocrConfiguration: OCRConfiguration(isEnabled: false)) { _ in }
    try FileManager.default.removeItem(at: pdf)

    try await database.saveScan(
        files: try await scanner.scan(root: root),
        root: root,
        removedDocumentPolicy: .keepIndexed
    )
    await processor.processPending(
        ocrConfiguration: OCRConfiguration(isEnabled: false),
        removeMissingDocuments: false
    ) { _ in }
    #expect(
        !(try await database.lexicalSearch(
            query: "Synchronisationstext",
            contentFilter: .documents
        )).isEmpty
    )

    try await database.saveScan(
        files: [],
        root: root,
        removedDocumentPolicy: .markMissing
    )
    await processor.processPending(
        ocrConfiguration: OCRConfiguration(isEnabled: false),
        removeMissingDocuments: false
    ) { _ in }
    #expect(
        (try await database.lexicalSearch(
            query: "Synchronisationstext",
            contentFilter: .documents
        )).isEmpty
    )
    let coverage = try await database.embeddingCoverage(
        modelID: "builtin-token-hash",
        modelVersion: "1"
    )
    #expect(coverage.totalChunks > 0)
}

private func syntheticTemporaryDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "Findora-\(name)-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeSyntheticPDF(text: String, to url: URL) throws {
    var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
    guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
        throw FindoraError.invalidPDF("Synthetischer PDF-Kontext konnte nicht angelegt werden.")
    }
    context.beginPDFPage(nil)
    let attributed = NSAttributedString(
        string: text,
        attributes: [.font: NSFont.systemFont(ofSize: 18)]
    )
    let line = CTLineCreateWithAttributedString(attributed)
    context.textPosition = CGPoint(x: 50, y: 700)
    CTLineDraw(line, context)
    context.endPDFPage()
    context.closePDF()
}

private func syntheticMSG(
    subject: String,
    body: String,
    senderAddress: String
) -> Data {
    let sectorSize = 512
    let endOfChain: UInt32 = 0xFFFFFFFE
    let fatSector: UInt32 = 0xFFFFFFFD
    let freeSector: UInt32 = 0xFFFFFFFF
    let streamValues = [subject, body, senderAddress].map {
        var data = $0.data(using: .utf16LittleEndian)!
        data.append(contentsOf: [0, 0])
        data.append(Data(repeating: 0, count: 4_096 - data.count))
        return data
    }
    let streamStarts: [UInt32] = [1, 9, 17]
    let fatID: UInt32 = 25
    var header = Data(repeating: 0, count: sectorSize)
    writeBytes([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1], at: 0, to: &header)
    writeUInt16(0x003E, at: 24, to: &header)
    writeUInt16(0x0003, at: 26, to: &header)
    writeUInt16(0xFFFE, at: 28, to: &header)
    writeUInt16(9, at: 30, to: &header)
    writeUInt16(6, at: 32, to: &header)
    writeUInt32(1, at: 44, to: &header)
    writeUInt32(0, at: 48, to: &header)
    writeUInt32(4_096, at: 56, to: &header)
    writeUInt32(endOfChain, at: 60, to: &header)
    writeUInt32(0, at: 64, to: &header)
    writeUInt32(endOfChain, at: 68, to: &header)
    writeUInt32(0, at: 72, to: &header)
    for index in 0..<109 {
        writeUInt32(index == 0 ? fatID : freeSector, at: 76 + index * 4, to: &header)
    }

    var directory = Data(repeating: 0, count: sectorSize)
    writeDirectoryEntry(
        name: "Root Entry",
        type: 5,
        right: freeSector,
        child: 1,
        start: endOfChain,
        size: 0,
        slot: 0,
        to: &directory
    )
    let names = [
        "__substg1.0_0037001F",
        "__substg1.0_1000001F",
        "__substg1.0_0C1F001F"
    ]
    for index in 0..<3 {
        writeDirectoryEntry(
            name: names[index],
            type: 2,
            right: index < 2 ? UInt32(index + 2) : freeSector,
            child: freeSector,
            start: streamStarts[index],
            size: 4_096,
            slot: index + 1,
            to: &directory
        )
    }

    var fat = Data(repeating: 0xFF, count: sectorSize)
    writeUInt32(endOfChain, at: 0, to: &fat)
    for start in streamStarts {
        for offset in 0..<8 {
            let id = start + UInt32(offset)
            writeUInt32(
                offset == 7 ? endOfChain : id + 1,
                at: Int(id) * 4,
                to: &fat
            )
        }
    }
    writeUInt32(fatSector, at: Int(fatID) * 4, to: &fat)

    var result = header
    result.append(directory)
    for value in streamValues { result.append(value) }
    result.append(fat)
    return result
}

private func writeDirectoryEntry(
    name: String,
    type: UInt8,
    right: UInt32,
    child: UInt32,
    start: UInt32,
    size: UInt64,
    slot: Int,
    to data: inout Data
) {
    let base = slot * 128
    var nameData = name.data(using: .utf16LittleEndian)!
    nameData.append(contentsOf: [0, 0])
    writeBytes(Array(nameData.prefix(64)), at: base, to: &data)
    writeUInt16(UInt16(min(nameData.count, 64)), at: base + 64, to: &data)
    data[base + 66] = type
    data[base + 67] = 1
    writeUInt32(0xFFFFFFFF, at: base + 68, to: &data)
    writeUInt32(right, at: base + 72, to: &data)
    writeUInt32(child, at: base + 76, to: &data)
    writeUInt32(start, at: base + 116, to: &data)
    writeUInt64(size, at: base + 120, to: &data)
}

private func writeBytes(_ bytes: [UInt8], at offset: Int, to data: inout Data) {
    data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
}

private func writeUInt16(_ value: UInt16, at offset: Int, to data: inout Data) {
    writeBytes([
        UInt8(truncatingIfNeeded: value),
        UInt8(truncatingIfNeeded: value >> 8)
    ], at: offset, to: &data)
}

private func writeUInt32(_ value: UInt32, at offset: Int, to data: inout Data) {
    writeBytes((0..<4).map { UInt8(truncatingIfNeeded: value >> UInt32($0 * 8)) }, at: offset, to: &data)
}

private func writeUInt64(_ value: UInt64, at offset: Int, to data: inout Data) {
    writeBytes((0..<8).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }, at: offset, to: &data)
}
