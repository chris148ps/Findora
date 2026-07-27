import Foundation

public struct MaintenanceActionFailure: Identifiable, Hashable, Sendable {
    public let id: String
    public let objectName: String
    public let reason: String

    public init(id: String, objectName: String, reason: String) {
        self.id = id
        self.objectName = objectName
        self.reason = reason
    }
}

public struct MaintenanceBatchResult: Hashable, Sendable {
    public let succeeded: [String]
    public let skipped: [String]
    public let failures: [MaintenanceActionFailure]

    public init(
        succeeded: [String] = [],
        skipped: [String] = [],
        failures: [MaintenanceActionFailure] = []
    ) {
        self.succeeded = succeeded
        self.skipped = skipped
        self.failures = failures
    }

    public var summary: String {
        "\(succeeded.count) erfolgreich, \(skipped.count) übersprungen, \(failures.count) fehlgeschlagen."
    }
}

public struct MailDuplicateExemplar: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let emailID: Int64
    public let sourceID: Int64
    public let sourceName: String
    public let sourceFormat: MailSourceFormat
    public let sourcePath: String
    public let sourceFilePath: String?
    public let sourceFileSize: Int64?
    public let sourceFileHash: String?
    public let messageHash: String
    public let isIndividualFile: Bool
    public let isReference: Bool
    public let isPresent: Bool
}

public struct MailDuplicateGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let subject: String
    public let sender: String
    public let recipients: [String]
    public let date: Date?
    public let recognitionBasis: String
    public let exemplars: [MailDuplicateExemplar]

    public var selectedRemovableCount: Int {
        max(0, exemplars.count - 1)
    }
}
