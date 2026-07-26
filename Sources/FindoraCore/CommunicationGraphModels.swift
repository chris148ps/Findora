import Foundation

public enum GraphRelationStatus: String, Codable, CaseIterable, Sendable {
    case automatic
    case suggested
    case confirmed
    case rejected

    public var displayName: String {
        switch self {
        case .automatic: "Automatisch verknüpft"
        case .suggested: "Vorschlag"
        case .confirmed: "Bestätigt"
        case .rejected: "Abgelehnt"
        }
    }
}

public enum GraphRelationKind: String, Codable, CaseIterable, Sendable {
    case identicalAttachment
    case sameConversation
    case contentSimilarity
    case fileNameSimilarity
    case sharedProjectReference
    case localSemantic

    public var displayName: String {
        switch self {
        case .identicalAttachment: "Identischer Anhang (SHA-256)"
        case .sameConversation: "Gleiche Unterhaltung"
        case .contentSimilarity: "Ähnlicher Inhalt"
        case .fileNameSimilarity: "Gleicher Dateiname"
        case .sharedProjectReference: "Gemeinsame Projektreferenz"
        case .localSemantic: "Lokale semantische Ähnlichkeit"
        }
    }
}

public struct Organization: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let name: String
    public let domain: String?
    public let partnerCount: Int
}

public struct CommunicationPartner: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let displayName: String
    public let primaryAddress: String
    public let aliasAddresses: [String]
    public let organizationName: String?
    public let emailCount: Int
    public let pdfCount: Int
    public let offerCount: Int
    public let invoiceCount: Int
    public let imageCount: Int
    public let lastActivity: Date?
}

public struct CommunicationProject: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let name: String
    public let reference: String
    public let status: GraphRelationStatus
    public let confidence: Double
    public let emailCount: Int
    public let documentCount: Int
    public let partnerNames: [String]
    public let lastActivity: Date?
}

public struct GraphLink: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let documentID: Int64?
    public let kind: GraphRelationKind
    public let status: GraphRelationStatus
    public let confidence: Double
}

public struct CommunicationGraphContext: Hashable, Sendable {
    public let partners: [CommunicationPartner]
    public let projects: [CommunicationProject]
    public let linkedEmails: [GraphLink]
    public let linkedDocuments: [GraphLink]

    public init(
        partners: [CommunicationPartner] = [],
        projects: [CommunicationProject] = [],
        linkedEmails: [GraphLink] = [],
        linkedDocuments: [GraphLink] = []
    ) {
        self.partners = partners
        self.projects = projects
        self.linkedEmails = linkedEmails
        self.linkedDocuments = linkedDocuments
    }
}

public struct CommunicationGraphStatistics: Equatable, Sendable {
    public let partners: Int
    public let organizations: Int
    public let projects: Int
    public let automaticLinks: Int
    public let suggestions: Int

    public init(
        partners: Int,
        organizations: Int,
        projects: Int,
        automaticLinks: Int,
        suggestions: Int
    ) {
        self.partners = partners
        self.organizations = organizations
        self.projects = projects
        self.automaticLinks = automaticLinks
        self.suggestions = suggestions
    }
}
