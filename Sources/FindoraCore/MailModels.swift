import Foundation

public enum FindoraContentType: String, Codable, CaseIterable, Hashable, Sendable {
    case pdf
    case email
    case emailAttachment

    public var displayName: String {
        switch self {
        case .pdf: "PDF"
        case .email: "E-Mail"
        case .emailAttachment: "E-Mail-Anhang"
        }
    }
}

public enum SearchContentFilter: String, Codable, CaseIterable, Identifiable, Sendable {
    case all
    case documents
    case emails
    case attachments

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .all: "Alle"
        case .documents: "Dokumente"
        case .emails: "E-Mails"
        case .attachments: "Anhänge"
        }
    }
}

public enum MailSourceFormat: String, Codable, CaseIterable, Hashable, Sendable {
    case mbox
    case eml
    case outlookMSG = "msg"
    case importFolder

    public var displayName: String {
        switch self {
        case .mbox: "Apple Mail MBOX"
        case .eml: "EML"
        case .outlookMSG: "Outlook MSG"
        case .importFolder: "Importordner"
        }
    }
}

public enum MailImportMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case referenced
    case archived

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .referenced: "Quellen nur referenzieren"
        case .archived: "Quellen in Findora archivieren"
        }
    }
}

public enum MailSourceStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case available
    case unavailable
    case removedFromSource
    case archivedCopyAvailable
    case indexOnly

    public var displayName: String {
        switch self {
        case .available: "Quelle vorhanden"
        case .unavailable: "Quelle nicht mehr vorhanden"
        case .removedFromSource: "Aus Quelle entfernt"
        case .archivedCopyAvailable: "Archivierte Kopie vorhanden"
        case .indexOnly: "Nur Indexdaten vorhanden"
        }
    }
}

public enum MailImportState: String, Codable, CaseIterable, Hashable, Sendable {
    case pending
    case importing
    case indexed
    case failed
    case skipped
}

public enum MailRecipientRole: String, Codable, CaseIterable, Hashable, Sendable {
    case from
    case to
    case cc
    case bcc
}

public enum MailPriority: String, Codable, CaseIterable, Hashable, Sendable {
    case low
    case normal
    case high
}

public struct MailAddress: Codable, Equatable, Hashable, Sendable {
    public let name: String?
    public let address: String

    public init(name: String? = nil, address: String) {
        self.name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.address = address
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

public struct ParsedMailAttachment: Equatable, Sendable {
    public let fileName: String
    public let mimeType: String
    public let contentID: String?
    public let isInline: Bool
    public let data: Data
    public let sha256: String

    public init(
        fileName: String,
        mimeType: String,
        contentID: String? = nil,
        isInline: Bool = false,
        data: Data
    ) {
        self.fileName = fileName.isEmpty ? "Anhang" : fileName
        self.mimeType = mimeType.isEmpty ? "application/octet-stream" : mimeType.lowercased()
        self.contentID = contentID
        self.isInline = isInline
        self.data = data
        self.sha256 = SHA256Hasher().hash(data: data)
    }

    public var isLikelyDecorativeInlineImage: Bool {
        isInline
            && mimeType.hasPrefix("image/")
            && data.count <= 64 * 1_024
            && (fileName.localizedCaseInsensitiveContains("logo")
                || fileName.localizedCaseInsensitiveContains("signature")
                || fileName.localizedCaseInsensitiveContains("spacer"))
    }
}

public struct ParsedMail: Equatable, Sendable {
    public let sourceFormat: MailSourceFormat
    public let messageID: String?
    public let conversationID: String?
    public let subject: String
    public let sender: MailAddress?
    public let recipients: [MailRecipientRole: [MailAddress]]
    public let sentAt: Date?
    public let receivedAt: Date?
    public let priority: MailPriority
    public let inReplyTo: String?
    public let references: [String]
    public let originalText: String
    public let normalizedText: String
    public let html: String?
    public let characterSet: String?
    public let attachments: [ParsedMailAttachment]
    public let sourceMailbox: String?
    public let rawSHA256: String
    public let contentSHA256: String
    public let stableIdentity: String

    public init(
        sourceFormat: MailSourceFormat,
        messageID: String?,
        conversationID: String? = nil,
        subject: String,
        sender: MailAddress?,
        recipients: [MailRecipientRole: [MailAddress]],
        sentAt: Date?,
        receivedAt: Date? = nil,
        priority: MailPriority = .normal,
        inReplyTo: String? = nil,
        references: [String] = [],
        originalText: String,
        normalizedText: String,
        html: String? = nil,
        characterSet: String? = nil,
        attachments: [ParsedMailAttachment] = [],
        sourceMailbox: String? = nil,
        rawData: Data
    ) {
        let normalizedMessageID = Self.normalizedMessageID(messageID)
        let normalizedSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBody = normalizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let contentHash = SHA256Hasher().hash(
            data: Data(normalizedBody.utf8)
        )
        let verification = [
            sender?.address ?? "",
            sentAt.map { String(Int64($0.timeIntervalSince1970)) } ?? "",
            normalizedSubject.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current),
            contentHash
        ].joined(separator: "\u{1F}")
        let identityMaterial = normalizedMessageID.map {
            "message-id:\($0)\u{1F}\(verification)"
        } ?? "fallback:\(verification)"

        self.sourceFormat = sourceFormat
        self.messageID = normalizedMessageID
        self.conversationID = conversationID
        self.subject = normalizedSubject.isEmpty ? "(Ohne Betreff)" : normalizedSubject
        self.sender = sender
        self.recipients = recipients
        self.sentAt = sentAt
        self.receivedAt = receivedAt
        self.priority = priority
        self.inReplyTo = Self.normalizedMessageID(inReplyTo)
        self.references = references.compactMap(Self.normalizedMessageID)
        self.originalText = originalText
        self.normalizedText = normalizedBody
        self.html = html
        self.characterSet = characterSet
        self.attachments = attachments
        self.sourceMailbox = sourceMailbox
        self.rawSHA256 = SHA256Hasher().hash(data: rawData)
        self.contentSHA256 = contentHash
        self.stableIdentity = SHA256Hasher().hash(data: Data(identityMaterial.utf8))
    }

    private static func normalizedMessageID(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            .lowercased()
        guard normalized.contains("@"), !normalized.contains(" ") else { return nil }
        return normalized
    }
}

public struct MailImportSource: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let displayName: String
    public let format: MailSourceFormat
    public let path: String
    public let archivedPath: String?
    public let importMode: MailImportMode
    public let status: MailSourceStatus
    public let mailbox: String?
    public let watchEnabled: Bool
    public let lastImportedAt: Date?
    public let lastSynchronizedAt: Date?
    public let messageCount: Int
    public let attachmentCount: Int
    public let errorCount: Int
    public let storageBytes: Int64

    public init(
        id: Int64,
        displayName: String,
        format: MailSourceFormat,
        path: String,
        archivedPath: String? = nil,
        importMode: MailImportMode,
        status: MailSourceStatus,
        mailbox: String? = nil,
        watchEnabled: Bool = false,
        lastImportedAt: Date? = nil,
        lastSynchronizedAt: Date? = nil,
        messageCount: Int = 0,
        attachmentCount: Int = 0,
        errorCount: Int = 0,
        storageBytes: Int64 = 0
    ) {
        self.id = id
        self.displayName = displayName
        self.format = format
        self.path = path
        self.archivedPath = archivedPath
        self.importMode = importMode
        self.status = status
        self.mailbox = mailbox
        self.watchEnabled = watchEnabled
        self.lastImportedAt = lastImportedAt
        self.lastSynchronizedAt = lastSynchronizedAt
        self.messageCount = messageCount
        self.attachmentCount = attachmentCount
        self.errorCount = errorCount
        self.storageBytes = storageBytes
    }
}

public struct MailImportProgress: Equatable, Sendable {
    public var processed = 0
    public var total: Int?
    public var imported = 0
    public var updated = 0
    public var skipped = 0
    public var failed = 0
    public var attachments = 0
    public var duplicates = 0
    public var currentSubject: String?

    public init() {}
}

public struct MailImportSummary: Equatable, Sendable {
    public let imported: Int
    public let updated: Int
    public let skipped: Int
    public let failed: Int
    public let attachments: Int
    public let duplicates: Int

    public init(progress: MailImportProgress) {
        self.imported = progress.imported
        self.updated = progress.updated
        self.skipped = progress.skipped
        self.failed = progress.failed
        self.attachments = progress.attachments
        self.duplicates = progress.duplicates
    }
}

public struct MailImportEstimate: Equatable, Sendable {
    public let sourceCount: Int
    public let estimatedMessages: Int?
    public let estimatedAttachments: Int?
    public let sourceBytes: Int64
    public let estimatedAdditionalBytes: Int64

    public init(
        sourceCount: Int,
        estimatedMessages: Int?,
        estimatedAttachments: Int?,
        sourceBytes: Int64,
        estimatedAdditionalBytes: Int64
    ) {
        self.sourceCount = sourceCount
        self.estimatedMessages = estimatedMessages
        self.estimatedAttachments = estimatedAttachments
        self.sourceBytes = sourceBytes
        self.estimatedAdditionalBytes = estimatedAdditionalBytes
    }
}

public struct IndexedMailAttachment: Sendable {
    public let attachment: ParsedMailAttachment
    public let extractedText: String
    public let pages: [ExtractedPage]
    public let chunks: [TextChunk]
    public let embeddings: [[Float]]
    public let archivedPath: String?

    public init(
        attachment: ParsedMailAttachment,
        extractedText: String,
        pages: [ExtractedPage],
        chunks: [TextChunk],
        embeddings: [[Float]],
        archivedPath: String? = nil
    ) {
        self.attachment = attachment
        self.extractedText = extractedText
        self.pages = pages
        self.chunks = chunks
        self.embeddings = embeddings
        self.archivedPath = archivedPath
    }
}

public enum MailDatabaseImportResult: Sendable {
    case imported
    case updated
    case duplicate
}
