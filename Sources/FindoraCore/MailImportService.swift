import Foundation

private struct MailImportDelta: Sendable {
    let result: MailDatabaseImportResult
    let attachmentCount: Int
    let subject: String
}

private actor MailImportProgressAccumulator {
    private var progress: MailImportProgress

    init(total: Int?) {
        var progress = MailImportProgress()
        progress.total = total
        self.progress = progress
    }

    func apply(_ delta: MailImportDelta) -> MailImportProgress {
        progress.processed += 1
        progress.currentSubject = delta.subject
        progress.attachments += delta.attachmentCount
        switch delta.result {
        case .imported:
            progress.imported += 1
        case .updated:
            progress.updated += 1
        case .duplicate:
            progress.skipped += 1
            progress.duplicates += 1
        }
        return progress
    }

    func recordFailure() -> MailImportProgress {
        progress.failed += 1
        progress.processed += 1
        return progress
    }

    func value() -> MailImportProgress {
        progress
    }
}

public actor MailImportService {
    private struct SourceFile: Sendable {
        let url: URL
        let format: MailSourceFormat
        let mailbox: String?
    }

    private let database: SQLiteDatabase
    private let embedder: any EmbeddingProviding
    private let chunker: PageChunker
    private let parser: MailFileParser
    private let archiveRoot: URL
    private let fileManager: FileManager
    private var paused = false

    public init(
        database: SQLiteDatabase,
        embedder: any EmbeddingProviding,
        archiveRoot: URL,
        chunker: PageChunker = PageChunker(),
        parser: MailFileParser = MailFileParser(),
        fileManager: FileManager = .default
    ) {
        self.database = database
        self.embedder = embedder
        self.archiveRoot = archiveRoot
        self.chunker = chunker
        self.parser = parser
        self.fileManager = fileManager
    }

    public func setPaused(_ paused: Bool) {
        self.paused = paused
    }

    public func estimate(
        urls: [URL],
        importMode: MailImportMode
    ) throws -> MailImportEstimate {
        var bytes: Int64 = 0
        var files = 0
        var containsMailbox = false
        for url in urls {
            let discovered = try discoverSourceFiles(below: url)
            files += discovered.count
            containsMailbox = containsMailbox || discovered.contains {
                $0.format == .mbox
            }
            for source in discovered {
                let values = try source.url.resourceValues(forKeys: [.fileSizeKey])
                bytes += Int64(values.fileSize ?? 0)
            }
        }
        let additional = importMode == .archived
            ? bytes + max(1_048_576, bytes / 8)
            : max(1_048_576, bytes / 8)
        return MailImportEstimate(
            sourceCount: urls.count,
            estimatedMessages: containsMailbox ? nil : files,
            estimatedAttachments: nil,
            sourceBytes: bytes,
            estimatedAdditionalBytes: additional
        )
    }

    public func importSources(
        urls: [URL],
        importMode: MailImportMode,
        watchFolders: Bool = false,
        onProgress: @Sendable (MailImportProgress) async -> Void
    ) async throws -> MailImportSummary {
        let discovered = try urls.flatMap(discoverSourceFiles)
        let accumulator = MailImportProgressAccumulator(
            total: discovered.contains { $0.format == .mbox }
                ? nil : discovered.count
        )
        await onProgress(await accumulator.value())

        for selectedURL in urls {
            try Task.checkCancellation()
            try await waitWhilePaused()
            let rootFormat = try sourceFormat(for: selectedURL)
            let bookmark = try? selectedURL.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: [.isDirectoryKey, .volumeIdentifierKey],
                relativeTo: nil
            )
            let sourceID = try await database.upsertMailSource(
                url: selectedURL,
                format: rootFormat,
                importMode: importMode,
                bookmarkData: bookmark,
                mailbox: selectedURL.deletingPathExtension().lastPathComponent,
                watchEnabled: watchFolders && rootFormat == .importFolder
            )
            if importMode == .archived {
                let archivedURL = try archiveSource(selectedURL)
                try await database.setMailSourceArchivedPath(
                    sourceID: sourceID,
                    archivedPath: archivedURL.path
                )
            }
            try await database.beginMailSourceSynchronization(sourceID: sourceID)

            let sourceFiles = try discoverSourceFiles(below: selectedURL)
            for sourceFile in sourceFiles {
                try Task.checkCancellation()
                try await waitWhilePaused()
                do {
                    if sourceFile.format == .mbox {
                        try await parser.forEachMessage(
                            inMBOX: sourceFile.url,
                            sourceMailbox: sourceFile.mailbox
                        ) { [self] mail in
                            try Task.checkCancellation()
                            try await waitWhilePaused()
                            let delta = try await importOne(
                                mail,
                                sourceID: sourceID,
                                importMode: importMode
                            )
                            await onProgress(await accumulator.apply(delta))
                        }
                    } else {
                        let mail = try parser.parse(
                            fileAt: sourceFile.url,
                            sourceMailbox: sourceFile.mailbox
                        )
                        let delta = try await importOne(
                            mail,
                            sourceID: sourceID,
                            importMode: importMode
                        )
                        await onProgress(await accumulator.apply(delta))
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try? await database.recordMailImportError(
                        sourceID: sourceID,
                        category: Self.safeErrorCategory(error)
                    )
                    await onProgress(await accumulator.recordFailure())
                }
            }
            try await database.finishMailSourceSynchronization(sourceID: sourceID)
        }
        return MailImportSummary(progress: await accumulator.value())
    }

    public func synchronizeSource(
        sourceID: Int64,
        onProgress: @Sendable (MailImportProgress) async -> Void
    ) async throws -> MailImportSummary {
        guard let source = try await database.mailSource(id: sourceID) else {
            throw FindoraError.database("Die E-Mail-Quelle wurde nicht gefunden.")
        }
        var original = URL(filePath: source.path)
        var securityScopeStarted = false
        if let bookmark = try await database.mailSourceBookmarkData(sourceID: sourceID) {
            var stale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                original = resolved
                securityScopeStarted = resolved.startAccessingSecurityScopedResource()
            }
        }
        defer {
            if securityScopeStarted {
                original.stopAccessingSecurityScopedResource()
            }
        }
        let fallback = source.archivedPath.map { URL(filePath: $0) }
        let selected: URL
        if fileManager.fileExists(atPath: original.path) {
            selected = original
        } else if let fallback, fileManager.fileExists(atPath: fallback.path) {
            selected = fallback
        } else {
            try await database.markMailSourceUnavailable(sourceID: sourceID)
            throw FindoraError.folderUnavailable(source.path)
        }
        let discovered = try discoverSourceFiles(below: selected)
        let accumulator = MailImportProgressAccumulator(
            total: discovered.contains { $0.format == .mbox }
                ? nil : discovered.count
        )
        await onProgress(await accumulator.value())
        try await database.beginMailSourceSynchronization(sourceID: sourceID)
        for sourceFile in discovered {
            try Task.checkCancellation()
            try await waitWhilePaused()
            do {
                if sourceFile.format == .mbox {
                    try await parser.forEachMessage(
                        inMBOX: sourceFile.url,
                        sourceMailbox: sourceFile.mailbox
                    ) { [self] mail in
                        try Task.checkCancellation()
                        try await waitWhilePaused()
                        let delta = try await importOne(
                            mail,
                            sourceID: sourceID,
                            importMode: source.importMode
                        )
                        await onProgress(await accumulator.apply(delta))
                    }
                } else {
                    let mail = try parser.parse(
                        fileAt: sourceFile.url,
                        sourceMailbox: sourceFile.mailbox
                    )
                    let delta = try await importOne(
                        mail,
                        sourceID: sourceID,
                        importMode: source.importMode
                    )
                    await onProgress(await accumulator.apply(delta))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try? await database.recordMailImportError(
                    sourceID: sourceID,
                    category: Self.safeErrorCategory(error)
                )
                await onProgress(await accumulator.recordFailure())
            }
        }
        try await database.finishMailSourceSynchronization(sourceID: sourceID)
        return MailImportSummary(progress: await accumulator.value())
    }

    private func importOne(
        _ mail: ParsedMail,
        sourceID: Int64,
        importMode: MailImportMode
    ) async throws -> MailImportDelta {
        let searchableText = Self.searchableText(mail)
        let documentHash = SHA256Hasher().hash(
            data: Data("email:\(mail.stableIdentity)".utf8)
        )
        let mailPages = [ExtractedPage(pageNumber: 1, text: searchableText)]
        let chunks = chunker.chunks(for: mailPages, documentHash: documentHash)
        let embeddings = try await embedder.embed(documents: chunks.map(\.text))

        var indexedAttachments: [IndexedMailAttachment] = []
        indexedAttachments.reserveCapacity(mail.attachments.count)
        for attachment in mail.attachments {
            try Task.checkCancellation()
            let indexed = try await indexAttachment(
                attachment,
                importMode: importMode
            )
            indexedAttachments.append(indexed)
        }

        let result = try await database.importMail(
            mail,
            sourceID: sourceID,
            sourceEntryKey: mail.stableIdentity,
            chunks: chunks,
            embeddings: embeddings,
            indexedAttachments: indexedAttachments,
            embeddingModelID: embedder.modelID,
            embeddingModelVersion: embedder.modelVersion
        )
        return MailImportDelta(
            result: result,
            attachmentCount: mail.attachments.count,
            subject: mail.subject
        )
    }

    private func indexAttachment(
        _ attachment: ParsedMailAttachment,
        importMode: MailImportMode
    ) async throws -> IndexedMailAttachment {
        let archivedPath = importMode == .archived
            ? try archiveAttachment(attachment).path
            : nil
        guard !attachment.isLikelyDecorativeInlineImage else {
            return IndexedMailAttachment(
                attachment: attachment,
                extractedText: "",
                pages: [],
                chunks: [],
                embeddings: [],
                archivedPath: archivedPath
            )
        }

        let pages = try await extractedPages(attachment)
        let normalizedText = pages.map(\.text)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let chunks = chunker.chunks(
            for: pages,
            documentHash: attachment.sha256
        )
        let embeddings = try await embedder.embed(documents: chunks.map(\.text))
        return IndexedMailAttachment(
            attachment: attachment,
            extractedText: normalizedText,
            pages: pages,
            chunks: chunks,
            embeddings: embeddings,
            archivedPath: archivedPath
        )
    }

    private func extractedPages(
        _ attachment: ParsedMailAttachment
    ) async throws -> [ExtractedPage] {
        switch attachment.mimeType {
        case "text/plain", "text/markdown":
            let text = Self.decodeAttachmentText(attachment.data)
            return text.isEmpty ? [] : [ExtractedPage(pageNumber: 1, text: text)]
        case "message/rfc822":
            let nested = try MIMEMessageParser().parse(
                data: attachment.data,
                sourceFormat: .eml
            )
            return nested.normalizedText.isEmpty
                ? []
                : [ExtractedPage(pageNumber: 1, text: Self.searchableText(nested))]
        case "application/vnd.ms-outlook":
            let nested = try OutlookMSGParser().parse(data: attachment.data)
            return nested.normalizedText.isEmpty
                ? []
                : [ExtractedPage(pageNumber: 1, text: Self.searchableText(nested))]
        case "application/pdf":
            return try await extractPDFPages(attachment)
        default:
            return []
        }
    }

    private func extractPDFPages(
        _ attachment: ParsedMailAttachment
    ) async throws -> [ExtractedPage] {
        let directory = fileManager.temporaryDirectory.appending(
            path: "Findora-mail-attachment-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        let url = directory.appending(path: "attachment.pdf")
        try attachment.data.write(to: url, options: .atomic)
        let extractor = PDFKitTextExtractor()
        let extracted = try extractor.extractPages(from: url)
        guard !extractor.hasUsableTextLayer(extracted) else { return extracted }

        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let file = DiscoveredPDF(
            url: url,
            relativePath: "attachment.pdf",
            fileName: "attachment.pdf",
            size: (attributes[.size] as? NSNumber)?.int64Value ?? Int64(attachment.data.count),
            modifiedAt: attributes[.modificationDate] as? Date ?? .now,
            resourceIdentifier: nil,
            volumeIdentifier: nil
        )
        var configuration = OCRConfiguration.default
        configuration.persistenceMode = .nonDestructive
        configuration.engineSelection = .appleVision
        let result = try await VisionOCRProvider().process(
            file,
            configuration: configuration
        )
        return result.pages
    }

    private func discoverSourceFiles(below selectedURL: URL) throws -> [SourceFile] {
        let values = try selectedURL.resourceValues(
            forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isSymbolicLink != true else { return [] }
        if values.isRegularFile == true {
            return [
                SourceFile(
                    url: selectedURL,
                    format: try sourceFormat(for: selectedURL),
                    mailbox: selectedURL.deletingPathExtension().lastPathComponent
                )
            ]
        }
        guard values.isDirectory == true else {
            throw MailParsingError.unsupportedFormat(selectedURL.lastPathComponent)
        }

        var result: [SourceFile] = []
        let rootComponents = selectedURL.standardizedFileURL.pathComponents.count
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isHiddenKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: selectedURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw FindoraError.folderUnavailable(selectedURL.path)
        }

        for case let url as URL in enumerator {
            let resource = try url.resourceValues(forKeys: Set(keys))
            if resource.isSymbolicLink == true || resource.isHidden == true {
                if resource.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            let depth = url.standardizedFileURL.pathComponents.count - rootComponents
            if depth > 12 {
                if resource.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if resource.isDirectory == true, url.pathExtension.lowercased() == "mbox" {
                let mboxFile = url.appending(path: "mbox")
                if fileManager.fileExists(atPath: mboxFile.path) {
                    result.append(
                        SourceFile(
                            url: mboxFile,
                            format: .mbox,
                            mailbox: url.deletingPathExtension().lastPathComponent
                        )
                    )
                }
                continue
            }
            guard resource.isRegularFile == true else { continue }
            let ext = url.pathExtension.lowercased()
            if ["eml", "msg", "mbox"].contains(ext) {
                result.append(
                    SourceFile(
                        url: url,
                        format: try sourceFormat(for: url),
                        mailbox: url.deletingLastPathComponent().lastPathComponent
                    )
                )
            } else if url.lastPathComponent == "mbox",
                      url.deletingLastPathComponent().pathExtension.lowercased() == "mbox" {
                result.append(
                    SourceFile(
                        url: url,
                        format: .mbox,
                        mailbox: url.deletingLastPathComponent()
                            .deletingPathExtension()
                            .lastPathComponent
                    )
                )
            }
        }
        return result.sorted { $0.url.path < $1.url.path }
    }

    private func sourceFormat(for url: URL) throws -> MailSourceFormat {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory == true {
            return url.pathExtension.lowercased() == "mbox" ? .mbox : .importFolder
        }
        switch url.pathExtension.lowercased() {
        case "mbox": return .mbox
        case "eml": return .eml
        case "msg": return .outlookMSG
        default:
            if url.lastPathComponent == "mbox" { return .mbox }
            throw MailParsingError.unsupportedFormat(url.lastPathComponent)
        }
    }

    private func archiveSource(_ source: URL) throws -> URL {
        let fingerprint = try sourceFingerprint(source)
        let sourcesRoot = archiveRoot.appending(path: "Sources", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: sourcesRoot, withIntermediateDirectories: true)
        let finalDirectory = sourcesRoot.appending(path: fingerprint, directoryHint: .isDirectory)
        let finalURL = finalDirectory.appending(path: source.lastPathComponent)
        if fileManager.fileExists(atPath: finalURL.path) {
            return finalURL
        }

        let staging = sourcesRoot.appending(
            path: ".staging-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer {
            if fileManager.fileExists(atPath: staging.path) {
                try? fileManager.removeItem(at: staging)
            }
        }
        let stagedURL = staging.appending(path: source.lastPathComponent)
        try fileManager.copyItem(at: source, to: stagedURL)
        guard try sourceFingerprint(stagedURL) == fingerprint else {
            throw FindoraError.processFailed(
                "Die archivierte Mailquelle stimmt nicht mit der Quelle überein."
            )
        }
        try fileManager.moveItem(at: staging, to: finalDirectory)
        return finalURL
    }

    private func archiveAttachment(_ attachment: ParsedMailAttachment) throws -> URL {
        let directory = archiveRoot
            .appending(path: "Attachments", directoryHint: .isDirectory)
            .appending(path: attachment.sha256, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeName = Self.safeFileName(attachment.fileName)
        let destination = directory.appending(path: safeName)
        if fileManager.fileExists(atPath: destination.path) {
            guard try SHA256Hasher().hash(fileAt: destination) == attachment.sha256 else {
                throw FindoraError.processFailed(
                    "Ein archivierter Anhang hat eine unerwartete Prüfsumme."
                )
            }
            return destination
        }
        let staging = directory.appending(path: ".partial-\(UUID().uuidString)")
        try attachment.data.write(to: staging, options: [.atomic])
        guard try SHA256Hasher().hash(fileAt: staging) == attachment.sha256 else {
            try? fileManager.removeItem(at: staging)
            throw FindoraError.processFailed(
                "Der Anhang konnte nicht verifiziert werden."
            )
        }
        try fileManager.moveItem(at: staging, to: destination)
        return destination
    }

    private func sourceFingerprint(_ url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory != true {
            return try SHA256Hasher().hash(fileAt: url)
        }
        var material = Data()
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw FindoraError.folderUnavailable(url.path)
        }
        for case let file as URL in enumerator {
            let resource = try file.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard resource.isRegularFile == true, resource.isSymbolicLink != true else {
                continue
            }
            let relative = String(file.path.dropFirst(url.path.count))
            material.append(Data(relative.utf8))
            material.append(Data(try SHA256Hasher().hash(fileAt: file).utf8))
        }
        return SHA256Hasher().hash(data: material)
    }

    private func waitWhilePaused() async throws {
        while paused {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    private static func searchableText(_ mail: ParsedMail) -> String {
        var sections = ["Betreff: \(mail.subject)"]
        if let sender = mail.sender {
            sections.append(
                "Von: \(sender.name.map { "\($0) " } ?? "")\(sender.address)"
            )
        }
        for role in [MailRecipientRole.to, .cc, .bcc] {
            let addresses = (mail.recipients[role] ?? []).map {
                "\($0.name.map { "\($0) " } ?? "")\($0.address)"
            }
            if !addresses.isEmpty {
                sections.append("\(role.rawValue.uppercased()): \(addresses.joined(separator: ", "))")
            }
        }
        if let date = mail.sentAt ?? mail.receivedAt {
            sections.append("Datum: \(date.formatted(.iso8601))")
        }
        if let mailbox = mail.sourceMailbox {
            sections.append("Postfach: \(mailbox)")
        }
        sections.append(mail.normalizedText)
        return sections.joined(separator: "\n")
    }

    private static func decodeAttachmentText(_ data: Data) -> String {
        (String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(decoding: data, as: UTF8.self))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func safeFileName(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\")
        let components = value.components(separatedBy: invalid)
        let safe = components.joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return safe.isEmpty ? "Anhang" : String(safe.prefix(180))
    }

    private static func safeErrorCategory(_ error: Error) -> String {
        switch error {
        case is MailParsingError:
            return "Parserfehler"
        case is CocoaError:
            return "Dateizugriffsfehler"
        default:
            return "Verarbeitungsfehler"
        }
    }
}
