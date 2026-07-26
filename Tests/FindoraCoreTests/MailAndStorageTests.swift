import AppKit
import CoreText
import Foundation
import PDFKit
@preconcurrency import SQLite3
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

@Test
func communicationGraphLinksIdenticalPDFAttachmentsInBothImportOrders() async throws {
    for mailFirst in [true, false] {
        let root = try syntheticTemporaryDirectory(
            mailFirst ? "graph-mail-first" : "graph-pdf-first"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appending(path: "Support")
        let paths = try AppPaths(
            applicationSupport: support,
            logs: root.appending(path: "Logs")
        )
        let sourcePDF = root.appending(path: "attachment-source.pdf")
        try writeSyntheticPDF(
            text: "PRJ-1001 Synthetischer Nordhafen Auftrag identischer Anhang",
            to: sourcePDF
        )
        let pdfData = try Data(contentsOf: sourcePDF)
        try FileManager.default.removeItem(at: sourcePDF)
        let importedPDF = root.appending(path: "PRJ-1001 Auftrag.pdf")
        let eml = root.appending(path: "projekt.eml")
        try syntheticGraphEML(
            messageID: mailFirst ? "mail-first@test.invalid" : "pdf-first@test.invalid",
            subject: "PRJ-1001 Nordhafen Auftrag",
            sender: "Anna Beispiel <anna@synthetic-acme.test>",
            recipients: "Bob Test <bob@synthetic-acme.test>",
            body: "Synthetischer Auftrag Nordhafen PRJ-1001",
            attachmentName: "PRJ-1001 Auftrag.pdf",
            attachmentData: pdfData
        ).write(to: eml)

        let database = SQLiteDatabase(url: paths.database)
        try await database.initialize()
        let scanner = RecursivePDFScanner(excludedRoots: [support])
        let processor = DocumentProcessor(
            database: database,
            stabilityChecker: FileStabilityChecker(delay: .zero),
            embedder: TokenHashEmbedding(dimensions: 64)
        )
        let mailService = MailImportService(
            database: database,
            embedder: TokenHashEmbedding(dimensions: 64),
            archiveRoot: paths.mailArchive
        )

        if mailFirst {
            let summary = try await mailService.importSources(
                urls: [eml],
                importMode: .referenced
            ) { _ in }
            #expect(summary.imported == 1)
            try pdfData.write(to: importedPDF)
            try await database.saveScan(
                files: try await scanner.scan(root: root),
                root: root
            )
            await processor.processPending(
                ocrConfiguration: OCRConfiguration(isEnabled: false)
            ) { _ in }
        } else {
            try pdfData.write(to: importedPDF)
            try await database.saveScan(
                files: try await scanner.scan(root: root),
                root: root
            )
            await processor.processPending(
                ocrConfiguration: OCRConfiguration(isEnabled: false)
            ) { _ in }
            let summary = try await mailService.importSources(
                urls: [eml],
                importMode: .referenced
            ) { _ in }
            #expect(summary.imported == 1)
        }

        let pdfSources = try await database.fileNameSearch(
            terms: ["PRJ-1001 Auftrag.pdf"],
            contentFilter: .documents
        )
        let pdfSource = try #require(pdfSources.first)
        let context = try await database.communicationGraphContext(
            documentID: pdfSource.documentID
        )
        #expect(context.linkedEmails.contains {
            $0.kind == .identicalAttachment
                && $0.status == .automatic
                && $0.confidence == 1
        })
        #expect(context.partners.contains { $0.primaryAddress == "anna@synthetic-acme.test" })
        #expect(context.projects.contains { $0.reference == "1001" })
        let emailSource = try #require(
            try await database.fileNameSearch(
                terms: ["PRJ-1001 Nordhafen Auftrag"],
                contentFilter: .emails
            ).first
        )
        let emailContext = try await database.communicationGraphContext(
            documentID: emailSource.documentID
        )
        #expect(emailContext.linkedDocuments.contains {
            $0.kind == .identicalAttachment && $0.status == .automatic
        })

        let projectMatches = try await HybridSearchService(
            database: database,
            embedder: TokenHashEmbedding(dimensions: 64),
            semanticEnabled: false
        ).search("PRJ-1001")
        #expect(Set(projectMatches.map(\.contentType)).contains(.email))
        #expect(projectMatches.contains { $0.matchKinds.contains(.relation) })
    }
}

@Test
func communicationGraphKeepsFilenameOnlyAndSemanticMatchesAsSuggestions() async throws {
    let root = try syntheticTemporaryDirectory("graph-suggestions")
    defer { try? FileManager.default.removeItem(at: root) }
    let support = root.appending(path: "Support")
    let paths = try AppPaths(
        applicationSupport: support,
        logs: root.appending(path: "Logs")
    )
    let diskPDF = root.appending(path: "Gleicher Name.pdf")
    try writeSyntheticPDF(
        text: "Nordhafen Sanierung Fenster Planung Kosten Mai",
        to: diskPDF
    )
    let differentPDF = root.appending(path: "different.pdf")
    try writeSyntheticPDF(
        text: "Vollständig anderer synthetischer Inhalt ohne Übereinstimmung",
        to: differentPDF
    )
    let differentData = try Data(contentsOf: differentPDF)
    try FileManager.default.removeItem(at: differentPDF)
    let eml = root.appending(path: "vorschlag.eml")
    try syntheticGraphEML(
        messageID: "suggestion@test.invalid",
        subject: "Nordhafen Sanierung",
        sender: "Carla Kontakt <carla@synthetic-acme.test>",
        recipients: "Dora Kontakt <dora@synthetic-beta.test>",
        body: "Nordhafen Sanierung Fenster Budget Termin April",
        attachmentName: "Gleicher Name.pdf",
        attachmentData: differentData
    ).write(to: eml)

    let database = SQLiteDatabase(url: paths.database)
    try await database.initialize()
    let scanner = RecursivePDFScanner(excludedRoots: [support])
    try await database.saveScan(
        files: try await scanner.scan(root: root),
        root: root
    )
    await DocumentProcessor(
        database: database,
        stabilityChecker: FileStabilityChecker(delay: .zero),
        embedder: TokenHashEmbedding(dimensions: 64)
    ).processPending(ocrConfiguration: OCRConfiguration(isEnabled: false)) { _ in }
    let summary = try await MailImportService(
        database: database,
        embedder: TokenHashEmbedding(dimensions: 64),
        archiveRoot: paths.mailArchive
    ).importSources(urls: [eml], importMode: .referenced) { _ in }
    #expect(summary.imported == 1)

    let source = try #require(
        try await database.fileNameSearch(
            terms: ["Gleicher Name.pdf"],
            contentFilter: .documents
        ).first
    )
    let context = try await database.communicationGraphContext(
        documentID: source.documentID
    )
    #expect(context.linkedEmails.contains {
        $0.kind == .fileNameSimilarity && $0.status == .suggested
    })
    #expect(!context.linkedEmails.contains {
        $0.kind == .identicalAttachment && $0.status == .automatic
    })
    #expect(context.linkedEmails.contains {
        $0.kind == .contentSimilarity && $0.status == .suggested
    })
    let partners = try await database.communicationPartners()
    #expect(partners.count == 2)
    let organizations = try await database.organizations()
    #expect(organizations.count == 2)
    #expect(try await database.communicationProjects().contains {
        $0.status == .suggested
    })
    let partnerMatches = try await HybridSearchService(
        database: database,
        embedder: TokenHashEmbedding(dimensions: 64),
        semanticEnabled: false
    ).search("Carla Kontakt")
    #expect(partnerMatches.contains { $0.contentType == .email })
    #expect(partnerMatches.contains { $0.contentType != .email })
}

@Test
func communicationGraphSeparatesMultipleContactsAndProjects() async throws {
    let root = try syntheticTemporaryDirectory("graph-multiple")
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        applicationSupport: root.appending(path: "Support"),
        logs: root.appending(path: "Logs")
    )
    let first = root.appending(path: "first.eml")
    let second = root.appending(path: "second.eml")
    try syntheticGraphEML(
        messageID: "first-project@test.invalid",
        subject: "PRJ-2001 Synthetisches Projekt Alpha",
        sender: "Erika Alpha <erika@synthetic-acme.test>",
        recipients: "Findora Test <findora@example.invalid>",
        body: "Projekt PRJ-2001 nur synthetische Daten"
    ).write(to: first)
    try syntheticGraphEML(
        messageID: "second-project@test.invalid",
        subject: "PRJ-2002 Synthetisches Projekt Beta",
        sender: "Felix Beta <felix@synthetic-acme.test>",
        recipients: "Findora Test <findora@example.invalid>",
        body: "Projekt PRJ-2002 nur synthetische Daten"
    ).write(to: second)
    let database = SQLiteDatabase(url: paths.database)
    try await database.initialize()
    let summary = try await MailImportService(
        database: database,
        embedder: TokenHashEmbedding(dimensions: 64),
        archiveRoot: paths.mailArchive
    ).importSources(urls: [first, second], importMode: .referenced) { _ in }
    #expect(summary.imported == 2)
    let partners = try await database.communicationPartners()
    #expect(partners.contains { $0.primaryAddress == "erika@synthetic-acme.test" })
    #expect(partners.contains { $0.primaryAddress == "felix@synthetic-acme.test" })
    let organizations = try await database.organizations()
    #expect(organizations.contains {
        $0.domain == "synthetic-acme.test" && $0.partnerCount == 2
    })
    let projects = try await database.communicationProjects()
    #expect(projects.contains { $0.reference == "2001" })
    #expect(projects.contains { $0.reference == "2002" })
}

@Test
func databaseMigrationsPreserveDocumentsOCRMailAndEmbeddingsAcrossVersions() async throws {
    for legacyVersion in [10, 11] {
        let root = try syntheticTemporaryDirectory("migration-v\(legacyVersion)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try AppPaths(
            applicationSupport: root.appending(path: "Support"),
            logs: root.appending(path: "Logs")
        )
        let databaseURL = paths.database
        var database: SQLiteDatabase? = SQLiteDatabase(url: databaseURL)
        try await database?.initialize()

        let pdf = root.appending(path: "PRJ-3001 Erhalten.pdf")
        try writeSyntheticPDF(text: "Erhaltener synthetischer OCR Text PRJ-3001", to: pdf)
        let data = try Data(contentsOf: pdf)
        let hash = SHA256Hasher().hash(data: data)
        let page = ExtractedPage(
            pageNumber: 1,
            text: "Erhaltener synthetischer OCR Text PRJ-3001"
        )
        let chunks = PageChunker().chunks(for: [page], documentHash: hash)
        let embedder = TokenHashEmbedding(dimensions: 64)
        let embeddings = try await embedder.embed(documents: chunks.map(\.text))
        let attributes = try pdf.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey]
        )
        _ = try await database?.indexDocument(
            file: DiscoveredPDF(
                url: pdf,
                relativePath: pdf.lastPathComponent,
                fileName: pdf.lastPathComponent,
                size: Int64(attributes.fileSize ?? data.count),
                modifiedAt: attributes.contentModificationDate ?? .now,
                resourceIdentifier: nil,
                volumeIdentifier: nil
            ),
            hash: hash,
            pages: [page],
            chunks: chunks,
            embeddings: embeddings,
            embeddingModelID: embedder.modelID,
            embeddingModelVersion: embedder.modelVersion,
            ocrPerformed: true,
            ocrPageNumbers: [1]
        )
        let eml = root.appending(path: "preserved.eml")
        try syntheticGraphEML(
            messageID: "preserved-v\(legacyVersion)@test.invalid",
            subject: "PRJ-3001 Erhaltene Mail",
            sender: "Migration Test <migration@synthetic-acme.test>",
            recipients: "Findora Test <findora@example.invalid>",
            body: "Erhaltene synthetische Maildaten PRJ-3001"
        ).write(to: eml)
        let mailSummary = try await MailImportService(
            database: try #require(database),
            embedder: embedder,
            archiveRoot: paths.mailArchive
        ).importSources(urls: [eml], importMode: .referenced) { _ in }
        #expect(mailSummary.imported == 1)

        let vectorsBefore = try await database?.vectorRows(
            modelID: embedder.modelID,
            modelVersion: embedder.modelVersion
        ).count
        try await database?.checkpointAndClose()
        database = nil
        try downgradeSyntheticDatabase(at: databaseURL, to: legacyVersion)

        let migrated = SQLiteDatabase(url: databaseURL)
        try await migrated.initialize()
        let version = try await migrated.databaseVersionSnapshot(
            embeddingModelID: embedder.modelID,
            embeddingModelVersion: embedder.modelVersion
        )
        #expect(version.schemaVersion == FindoraAnalysisVersions.schema)
        #expect(version.expectedSchemaVersion == FindoraAnalysisVersions.schema)
        let preservedOCR = try await migrated.lexicalSearch(
            query: "synthetischer OCR Text",
            contentFilter: .documents
        )
        let preservedMail = try await migrated.lexicalSearch(
            query: "synthetische Maildaten",
            contentFilter: .emails
        )
        let vectorsAfter = try await migrated.vectorRows(
            modelID: embedder.modelID,
            modelVersion: embedder.modelVersion
        ).count
        #expect(!preservedOCR.isEmpty)
        #expect(!preservedMail.isEmpty)
        #expect(vectorsAfter == vectorsBefore)
        #expect(try await migrated.databaseQuickCheck() == "ok")
        #expect(try await migrated.databaseIntegrityCheck() == "ok")
        try await migrated.checkpointAndClose()
    }
}

@Test
func interruptedSchemaMigrationRollsBackAndCanResumeCleanly() async throws {
    let root = try syntheticTemporaryDirectory("migration-interrupted")
    defer { try? FileManager.default.removeItem(at: root) }
    let databaseURL = root.appending(path: "Findora.sqlite3")
    let current = SQLiteDatabase(url: databaseURL)
    try await current.initialize()
    try await current.checkpointAndClose()
    try downgradeSyntheticDatabase(at: databaseURL, to: 10)
    try executeSyntheticSQL(
        "CREATE TABLE projects (id INTEGER PRIMARY KEY, sentinel TEXT)",
        at: databaseURL
    )

    let interrupted = SQLiteDatabase(url: databaseURL)
    await #expect(throws: Error.self) {
        try await interrupted.initialize()
    }
    try? await interrupted.checkpointAndClose()
    let versionAfterFailure = try syntheticScalarInt(
        "SELECT COALESCE(MAX(version), 0) FROM schema_migrations",
        at: databaseURL
    )
    #expect(versionAfterFailure == 10)
    #expect(
        try syntheticScalarInt(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='organizations'",
            at: databaseURL
        ) == 0
    )

    try executeSyntheticSQL("DROP TABLE projects", at: databaseURL)
    let resumed = SQLiteDatabase(url: databaseURL)
    try await resumed.initialize()
    #expect(
        try await resumed.databaseVersionSnapshot().schemaVersion
            == FindoraAnalysisVersions.schema
    )
    #expect(try await resumed.databaseQuickCheck() == "ok")
    #expect(try await resumed.databaseIntegrityCheck() == "ok")
    try await resumed.checkpointAndClose()
}

@Test
func incrementalAnalysisUpgradeOnlyFillsMissingGraphVersionsAndCanPause() async throws {
    let root = try syntheticTemporaryDirectory("incremental-upgrade")
    defer { try? FileManager.default.removeItem(at: root) }
    let databaseURL = root.appending(path: "Findora.sqlite3")
    var database: SQLiteDatabase? = SQLiteDatabase(url: databaseURL)
    try await database?.initialize()
    let eml = root.appending(path: "upgrade.eml")
    try syntheticGraphEML(
        messageID: "upgrade@test.invalid",
        subject: "PRJ-4001 Upgrade",
        sender: "Upgrade Person <upgrade@synthetic-acme.test>",
        recipients: "Findora Test <findora@example.invalid>",
        body: "Nur fehlende lokale Analysen PRJ-4001"
    ).write(to: eml)
    _ = try await MailImportService(
        database: try #require(database),
        embedder: TokenHashEmbedding(dimensions: 64),
        archiveRoot: root.appending(path: "Mail")
    ).importSources(urls: [eml], importMode: .referenced) { _ in }
    try await database?.checkpointAndClose()
    database = nil
    try executeSyntheticSQL(
        """
        UPDATE document_analysis_versions
        SET people_analysis_version = NULL, project_analysis_version = NULL
        WHERE document_id = (SELECT MIN(document_id) FROM document_analysis_versions)
        """,
        at: databaseURL
    )

    let reopened = SQLiteDatabase(url: databaseURL)
    try await reopened.initialize()
    let queued = try await reopened.prepareIncrementalAnalysisUpgrades()
    #expect(queued == 2)
    try await reopened.setAnalysisUpgradePaused(true)
    #expect(try await reopened.runIncrementalAnalysisUpgradeBatch() == 0)
    try await reopened.setAnalysisUpgradePaused(false)
    #expect(try await reopened.runIncrementalAnalysisUpgradeBatch() == 2)
    let snapshot = try await reopened.databaseVersionSnapshot()
    #expect(snapshot.pendingUpgrades == 0)
    #expect(
        snapshot.versions.first(where: { $0.kind == .peopleAnalysis })?
            .missingDocuments == 0
    )
    #expect(
        snapshot.versions.first(where: { $0.kind == .projectAnalysis })?
            .missingDocuments == 0
    )
    #expect(try await reopened.databaseQuickCheck() == "ok")
    try await reopened.checkpointAndClose()
}

private func syntheticGraphEML(
    messageID: String,
    subject: String,
    sender: String,
    recipients: String,
    body: String,
    attachmentName: String? = nil,
    attachmentData: Data? = nil
) -> Data {
    var message = """
    Message-ID: <\(messageID)>
    Subject: \(subject)
    From: \(sender)
    To: \(recipients)
    Date: Sat, 26 Jul 2026 12:30:00 +0200
    """
    if let attachmentName, let attachmentData {
        message += """

        Content-Type: multipart/mixed; boundary="graph-boundary"

        --graph-boundary
        Content-Type: text/plain; charset=utf-8

        \(body)
        --graph-boundary
        Content-Type: application/pdf; name="\(attachmentName)"
        Content-Disposition: attachment; filename="\(attachmentName)"
        Content-Transfer-Encoding: base64

        \(attachmentData.base64EncodedString())
        --graph-boundary--
        """
    } else {
        message += """

        Content-Type: text/plain; charset=utf-8

        \(body)
        """
    }
    return Data(message.replacingOccurrences(of: "\n", with: "\r\n").utf8)
}

private func downgradeSyntheticDatabase(at url: URL, to version: Int) throws {
    precondition(version == 10 || version == 11)
    var statements = [
        "DROP TABLE IF EXISTS analysis_upgrade_jobs",
        "DROP TABLE IF EXISTS document_analysis_versions"
    ]
    if version == 10 {
        statements += [
            "DROP TABLE IF EXISTS document_relations",
            "DROP TABLE IF EXISTS mail_relations",
            "DROP TABLE IF EXISTS project_email_links",
            "DROP TABLE IF EXISTS project_document_links",
            "DROP TABLE IF EXISTS communication_partner_email_links",
            "DROP TABLE IF EXISTS communication_partner_aliases",
            "DROP TABLE IF EXISTS projects",
            "DROP TABLE IF EXISTS communication_partners",
            "DROP TABLE IF EXISTS organizations"
        ]
    }
    statements.append("DELETE FROM schema_migrations WHERE version > \(version)")
    try executeSyntheticSQL(statements.joined(separator: ";"), at: url)
}

private func executeSyntheticSQL(_ sql: String, at url: URL) throws {
    var connection: OpaquePointer?
    guard sqlite3_open(url.path, &connection) == SQLITE_OK, let connection else {
        throw FindoraError.database("Synthetische Testdatenbank konnte nicht geöffnet werden.")
    }
    defer { sqlite3_close(connection) }
    var errorMessage: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(connection, sql, nil, nil, &errorMessage)
    guard result == SQLITE_OK else {
        let message = errorMessage.map { String(cString: $0) } ?? "SQLite-Testfehler"
        sqlite3_free(errorMessage)
        throw FindoraError.database(message)
    }
}

private func syntheticScalarInt(_ sql: String, at url: URL) throws -> Int {
    var connection: OpaquePointer?
    guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          let connection else {
        throw FindoraError.database("Synthetische Testdatenbank konnte nicht gelesen werden.")
    }
    defer { sqlite3_close(connection) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
        throw FindoraError.database("Synthetische Testabfrage ist ungültig.")
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
        throw FindoraError.database("Synthetische Testabfrage lieferte keine Zeile.")
    }
    return Int(sqlite3_column_int64(statement, 0))
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
