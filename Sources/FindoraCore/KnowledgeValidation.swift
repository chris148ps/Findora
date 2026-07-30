import Foundation

public enum KnowledgeValidationError: LocalizedError, Equatable, Sendable {
    case invalidJSON
    case unsupportedSchema(Int)
    case unknownField(String)
    case invalidConfidence(String)
    case duplicateIdentifier(String)
    case unknownEntity(String)
    case unknownEvidence(String)
    case missingEvidence(String)
    case invalidEvidence(String)
    case unsupportedValue(String)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON:
            "Die Modellantwort ist kein gültiges Wissens-JSON."
        case .unsupportedSchema(let version):
            "Nicht unterstützte Wissensschema-Version \(version)."
        case .unknownField(let field):
            "Das Wissens-JSON enthält das unbekannte Feld \(field)."
        case .invalidConfidence(let identifier):
            "Ungültiger Vertrauenswert für \(identifier)."
        case .duplicateIdentifier(let identifier):
            "Doppelte Kandidaten- oder Beleg-ID: \(identifier)."
        case .unknownEntity(let identifier):
            "Unbekannte Entitätsreferenz: \(identifier)."
        case .unknownEvidence(let identifier):
            "Unbekannte Belegreferenz: \(identifier)."
        case .missingEvidence(let identifier):
            "Der Wissenskandidat \(identifier) besitzt keinen Beleg."
        case .invalidEvidence(let identifier):
            "Der Beleg \(identifier) stimmt nicht mit der Eingabequelle überein."
        case .unsupportedValue(let identifier):
            "Der Wissenskandidat \(identifier) besitzt keinen gültigen Objektwert."
        }
    }
}

public struct KnowledgeExtractionValidator: Sendable {
    public static let schemaVersion = 1
    public static let maximumEvidenceQuoteLength = 1_500

    public init() {}

    public func decodeAndValidate(
        _ data: Data,
        context: KnowledgeExtractionContext
    ) throws -> ValidatedKnowledgeExtraction {
        try rejectUnknownTopLevelFields(data)
        let envelope: KnowledgeExtractionEnvelope
        do {
            envelope = try JSONDecoder().decode(KnowledgeExtractionEnvelope.self, from: data)
        } catch {
            throw KnowledgeValidationError.invalidJSON
        }
        return try validate(envelope, context: context)
    }

    public func validate(
        _ envelope: KnowledgeExtractionEnvelope,
        context: KnowledgeExtractionContext
    ) throws -> ValidatedKnowledgeExtraction {
        guard envelope.schemaVersion == Self.schemaVersion,
              context.schemaVersion == Self.schemaVersion else {
            throw KnowledgeValidationError.unsupportedSchema(envelope.schemaVersion)
        }
        if let confidence = envelope.documentTypeConfidence {
            try validateConfidence(confidence, identifier: "documentType")
        }

        let pageByID = Dictionary(uniqueKeysWithValues: context.pages.map { ($0.pageID, $0) })
        var allIDs = Set<String>()
        var evidenceByID: [String: KnowledgeEvidenceCandidate] = [:]
        for evidence in envelope.evidence {
            try insertUnique(evidence.id, into: &allIDs)
            try validateConfidence(evidence.confidence, identifier: evidence.id)
            guard let page = pageByID[evidence.pageID],
                  page.pageNumber == evidence.pageNumber,
                  evidence.quote.count <= Self.maximumEvidenceQuoteLength,
                  !evidence.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  evidence.chunkID.map(page.validChunkIDs.contains) ?? true,
                  evidence.boundingBox?.isValid ?? true,
                  quoteMatches(evidence, pageText: page.text) else {
                throw KnowledgeValidationError.invalidEvidence(evidence.id)
            }
            evidenceByID[evidence.id] = evidence
        }

        let entityIDs = Set(envelope.entities.map(\.candidateID))
        guard entityIDs.count == envelope.entities.count else {
            throw KnowledgeValidationError.duplicateIdentifier("entity")
        }
        for entity in envelope.entities {
            try insertUnique(entity.candidateID, into: &allIDs)
            try validateConfidence(entity.confidence, identifier: entity.candidateID)
            guard entity.type.isSyntacticallyValid,
                  !entity.canonicalName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw KnowledgeValidationError.unsupportedValue(entity.candidateID)
            }
            try validateEvidenceReferences(
                entity.evidenceIDs,
                identifier: entity.candidateID,
                evidenceByID: evidenceByID
            )
        }

        for fact in envelope.facts {
            try insertUnique(fact.candidateID, into: &allIDs)
            try validateConfidence(fact.confidence, identifier: fact.candidateID)
            guard entityIDs.contains(fact.subjectEntityID) else {
                throw KnowledgeValidationError.unknownEntity(fact.subjectEntityID)
            }
            if let objectEntityID = fact.objectEntityID,
               !entityIDs.contains(objectEntityID) {
                throw KnowledgeValidationError.unknownEntity(objectEntityID)
            }
            guard fact.objectEntityID != nil
                    || !(fact.literalValue ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw KnowledgeValidationError.unsupportedValue(fact.candidateID)
            }
            guard ![KnowledgeClaimType.userConfirmed, .externallyVerified]
                .contains(fact.claimType) else {
                throw KnowledgeValidationError.unsupportedValue(fact.candidateID)
            }
            if let literalValue = fact.literalValue,
               fact.valueType != .string,
               KnowledgeValueNormalizer().normalize(
                   literalValue,
                   type: fact.valueType
               ) == nil {
                throw KnowledgeValidationError.unsupportedValue(fact.candidateID)
            }
            try validateEvidenceReferences(
                fact.evidenceIDs,
                identifier: fact.candidateID,
                evidenceByID: evidenceByID
            )
        }

        for relation in envelope.relations {
            try insertUnique(relation.candidateID, into: &allIDs)
            try validateConfidence(relation.confidence, identifier: relation.candidateID)
            guard entityIDs.contains(relation.subjectEntityID) else {
                throw KnowledgeValidationError.unknownEntity(relation.subjectEntityID)
            }
            guard entityIDs.contains(relation.objectEntityID) else {
                throw KnowledgeValidationError.unknownEntity(relation.objectEntityID)
            }
            guard ![KnowledgeClaimType.userConfirmed, .externallyVerified]
                .contains(relation.claimType) else {
                throw KnowledgeValidationError.unsupportedValue(relation.candidateID)
            }
            try validateEvidenceReferences(
                relation.evidenceIDs,
                identifier: relation.candidateID,
                evidenceByID: evidenceByID
            )
        }

        for (index, signal) in envelope.projectSignals.enumerated() {
            try validateConfidence(signal.weight, identifier: "projectSignal-\(index)")
            try validateEvidenceReferences(
                signal.evidenceIDs,
                identifier: "projectSignal-\(index)",
                evidenceByID: evidenceByID
            )
        }

        return ValidatedKnowledgeExtraction(envelope: envelope, context: context)
    }

    private func rejectUnknownTopLevelFields(_ data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            throw KnowledgeValidationError.invalidJSON
        }
        let allowed = Set([
            "schemaVersion", "documentType", "documentTypeConfidence", "entities",
            "facts", "relations", "evidence", "projectSignals", "uncertainties"
        ])
        if let unknown = dictionary.keys.first(where: { !allowed.contains($0) }) {
            throw KnowledgeValidationError.unknownField(unknown)
        }
    }

    private func insertUnique(_ identifier: String, into values: inout Set<String>) throws {
        guard !identifier.isEmpty, values.insert(identifier).inserted else {
            throw KnowledgeValidationError.duplicateIdentifier(identifier)
        }
    }

    private func validateConfidence(_ value: Double, identifier: String) throws {
        guard value.isFinite, (0...1).contains(value) else {
            throw KnowledgeValidationError.invalidConfidence(identifier)
        }
    }

    private func validateEvidenceReferences(
        _ identifiers: [String],
        identifier: String,
        evidenceByID: [String: KnowledgeEvidenceCandidate]
    ) throws {
        guard !identifiers.isEmpty else {
            throw KnowledgeValidationError.missingEvidence(identifier)
        }
        for evidenceID in Set(identifiers) {
            guard evidenceByID[evidenceID] != nil else {
                throw KnowledgeValidationError.unknownEvidence(evidenceID)
            }
        }
    }

    private func quoteMatches(
        _ evidence: KnowledgeEvidenceCandidate,
        pageText: String
    ) -> Bool {
        let utf16 = Array(pageText.utf16)
        if let start = evidence.characterStart,
           let end = evidence.characterEnd {
            guard start >= 0, end > start, end <= utf16.count,
                  start < end else {
                return false
            }
            let exact = String(decoding: utf16[start..<end], as: UTF16.self)
            return normalized(exact) == normalized(evidence.quote)
        }
        guard evidence.characterStart == nil, evidence.characterEnd == nil else {
            return false
        }
        return normalized(pageText).contains(normalized(evidence.quote))
    }

    private func normalized(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct KnowledgeValueNormalizer: @unchecked Sendable {
    private let decimalFormatter: NumberFormatter

    public init(locale: Locale = Locale(identifier: "de_DE")) {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.generatesDecimalNumbers = true
        decimalFormatter = formatter
    }

    public func normalize(_ value: String, type: KnowledgeValueType) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch type {
        case .integer:
            return Int64(trimmed.filter { $0.isNumber || $0 == "-" }).map(String.init)
        case .decimal, .money, .measurement:
            return decimalFormatter.number(from: trimmed)?.decimalValue.description
        case .boolean:
            switch trimmed.lowercased() {
            case "true", "1", "ja", "yes": return "true"
            case "false", "0", "nein", "no": return "false"
            default: return nil
            }
        case .date:
            return normalizedDate(trimmed, includeTime: false)
        case .dateTime:
            return normalizedDate(trimmed, includeTime: true)
        case .string, .entityReference:
            return trimmed.precomposedStringWithCanonicalMapping
        }
    }

    private func normalizedDate(_ value: String, includeTime: Bool) -> String? {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: value) {
            if includeTime { return iso.string(from: date) }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: date)
        }
        let formats = ["dd.MM.yyyy", "d.M.yyyy", "yyyy-MM-dd"]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                formatter.dateFormat = "yyyy-MM-dd"
                return formatter.string(from: date)
            }
        }
        return nil
    }
}
