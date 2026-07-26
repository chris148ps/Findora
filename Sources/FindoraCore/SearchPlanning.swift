import Foundation

public enum SearchIntent: String, Codable, CaseIterable, Sendable {
    case findDocuments = "find_documents"
    case answerQuestion = "answer_question"
    case summarize = "summarize"
    case compare = "compare"
}

public struct SearchPlan: Codable, Equatable, Sendable {
    public let intent: SearchIntent
    public let requiredEntities: [String]
    public let organizations: [String]
    public let locations: [String]
    public let timeRanges: [String]
    public let amounts: [String]
    public let documentTypes: [String]
    public let topics: [String]
    public let mustMatchAll: Bool
    public let optionalTerms: [String]

    public init(
        intent: SearchIntent = .findDocuments,
        requiredEntities: [String] = [],
        organizations: [String] = [],
        locations: [String] = [],
        timeRanges: [String] = [],
        amounts: [String] = [],
        documentTypes: [String] = [],
        topics: [String] = [],
        mustMatchAll: Bool = true,
        optionalTerms: [String] = []
    ) {
        self.intent = intent
        self.requiredEntities = Self.normalized(requiredEntities)
        self.organizations = Self.normalized(organizations)
        self.locations = Self.normalized(locations)
        self.timeRanges = Self.normalized(timeRanges)
        self.amounts = Self.normalized(amounts)
        self.documentTypes = Self.normalized(documentTypes)
        self.topics = Self.normalized(topics)
        self.mustMatchAll = mustMatchAll
        self.optionalTerms = Self.normalized(optionalTerms)
    }

    public var hardTerms: [String] {
        Self.normalized(
            requiredEntities + organizations + locations + timeRanges + amounts
        )
    }

    public var retrievalTerms: [String] {
        Self.normalized(hardTerms + documentTypes + topics + optionalTerms.prefix(8))
    }

    public func mergingContext(from previous: SearchPlan?) -> SearchPlan {
        guard let previous else { return self }
        return SearchPlan(
            intent: intent,
            requiredEntities: requiredEntities.isEmpty
                ? previous.requiredEntities
                : requiredEntities,
            organizations: organizations.isEmpty ? previous.organizations : organizations,
            locations: locations.isEmpty ? previous.locations : locations,
            timeRanges: timeRanges.isEmpty ? previous.timeRanges : timeRanges,
            amounts: amounts.isEmpty ? previous.amounts : amounts,
            documentTypes: documentTypes.isEmpty ? previous.documentTypes : documentTypes,
            topics: topics.isEmpty ? previous.topics : topics,
            mustMatchAll: true,
            optionalTerms: optionalTerms
        )
    }

    private static func normalized<S: Sequence>(_ values: S) -> [String]
    where S.Element == String {
        var seen: Set<String> = []
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...80).contains(trimmed.count) else { return nil }
            let key = trimmed.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "de_DE")
            )
            return seen.insert(key).inserted ? trimmed : nil
        }
    }
}

public enum SearchPlanValidationError: LocalizedError, Sendable {
    case invalidJSON
    case unknownFields
    case invalidSchema
    case unsafeContent

    public var errorDescription: String? {
        switch self {
        case .invalidJSON: "Der lokale Suchplan war kein gültiges JSON."
        case .unknownFields: "Der lokale Suchplan enthielt unbekannte Felder."
        case .invalidSchema: "Der lokale Suchplan entsprach nicht dem erwarteten Schema."
        case .unsafeContent: "Der lokale Suchplan enthielt unzulässige Befehle."
        }
    }
}

public struct SearchPlanValidator: Sendable {
    private static let allowedKeys: Set<String> = [
        "intent",
        "required_entities",
        "organizations",
        "locations",
        "time_ranges",
        "amounts",
        "document_types",
        "topics",
        "must_match_all",
        "optional_terms"
    ]

    public init() {}

    public func decode(_ text: String) throws -> SearchPlan {
        let json = Self.extractJSONObject(from: text)
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            throw SearchPlanValidationError.invalidJSON
        }
        guard Set(dictionary.keys).isSubset(of: Self.allowedKeys) else {
            throw SearchPlanValidationError.unknownFields
        }
        guard let intentValue = dictionary["intent"] as? String,
              let intent = SearchIntent(rawValue: intentValue),
              let required = Self.strings(dictionary["required_entities"]),
              let organizations = Self.strings(dictionary["organizations"]),
              let locations = Self.strings(dictionary["locations"]),
              let timeRanges = Self.strings(dictionary["time_ranges"]),
              let amounts = Self.strings(dictionary["amounts"]),
              let documentTypes = Self.strings(dictionary["document_types"]),
              let topics = Self.strings(dictionary["topics"]),
              let mustMatchAll = dictionary["must_match_all"] as? Bool,
              let optionalTerms = Self.strings(dictionary["optional_terms"]) else {
            throw SearchPlanValidationError.invalidSchema
        }
        let allValues = required + organizations + locations + timeRanges
            + amounts + documentTypes + topics + optionalTerms
        guard allValues.count <= 64,
              allValues.allSatisfy({ (1...80).contains($0.count) }),
              !allValues.contains(where: Self.containsUnsafeContent) else {
            throw SearchPlanValidationError.unsafeContent
        }
        return SearchPlan(
            intent: intent,
            requiredEntities: required,
            organizations: organizations,
            locations: locations,
            timeRanges: timeRanges,
            amounts: amounts,
            documentTypes: documentTypes,
            topics: topics,
            mustMatchAll: mustMatchAll,
            optionalTerms: optionalTerms
        )
    }

    private static func strings(_ value: Any?) -> [String]? {
        guard let values = value as? [Any],
              values.allSatisfy({ $0 is String }) else { return nil }
        return values.compactMap { $0 as? String }
    }

    private static func extractJSONObject(from text: String) -> String {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start <= end else { return text }
        return String(text[start...end])
    }

    private static func containsUnsafeContent(_ value: String) -> Bool {
        value.range(
            of: #"\b(SELECT|INSERT|UPDATE|DELETE|DROP|ALTER|PRAGMA|ATTACH)\b|;|--"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }
}

public struct RuleBasedSearchPlanner: Sendable {
    private static let ignoredCapitalizedWords: Set<String> = [
        "Suche", "Such", "Finde", "Find", "Zeige", "Welche", "Welcher", "Welches",
        "Was", "Wie", "Wo", "Wann", "Bitte", "Dokumente", "Unterlagen", "Thema"
    ]
    private static let followUpMarkers = [
        "davon", "diese", "dieser", "diesen", "welche davon", "unter diesen",
        "die gefundenen", "vorherigen", "genannten"
    ]
    private static let topics: [(canonical: String, terms: [String])] = [
        (
            "Ausbildung",
            [
                "ausbildung", "ausbildungsstelle", "ausbildungsvertrag",
                "ausbildungsbetrieb", "berufsausbildung", "berufsschule",
                "probezeit", "lehrstelle", "bewerbung"
            ]
        ),
        ("Kündigung", ["kündigung", "gekündigt", "kuendigung"]),
        ("Miete", ["miete", "mietvertrag", "vermieter", "mieter"]),
        ("Versicherung", ["versicherung", "police", "schaden"]),
        ("Rechnung", ["rechnung", "zahlung", "fälligkeit", "faelligkeit"])
    ]
    private static let documentTypes = [
        "Ausbildungsvertrag", "Arbeitsvertrag", "Mietvertrag", "Kündigung",
        "Rechnung", "Bescheid", "Zeugnis", "Bewerbung", "Mahnung"
    ]

    public init() {}

    public func plan(
        query: String,
        previousPlan: SearchPlan? = nil
    ) -> SearchPlan {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let detectedTopics = Self.topics.compactMap { topic in
            topic.terms.contains(where: lower.contains) ? topic.canonical : nil
        }
        let optionalTerms = Self.topics
            .filter { detectedTopics.contains($0.canonical) }
            .flatMap(\.terms)
        var entities = uniqueIdentifiers(in: trimmed)
        entities.append(contentsOf: capitalizedEntities(in: trimmed))
        entities.removeAll { entity in
            let normalizedEntity = entity.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "de_DE")
            )
            return detectedTopics.contains {
                $0.compare(entity, options: [.caseInsensitive, .diacriticInsensitive])
                    == .orderedSame
            } || optionalTerms.contains {
                let normalizedTerm = $0.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: Locale(identifier: "de_DE")
                )
                return normalizedEntity.hasPrefix(normalizedTerm)
                    || normalizedTerm.hasPrefix(normalizedEntity)
            }
        }
        let types = Self.documentTypes.filter {
            lower.contains($0.lowercased())
        }
        let plan = SearchPlan(
            intent: lower.contains("vergle")
                ? .compare
                : lower.contains("zusammenfass")
                    ? .summarize
                    : lower.contains("?")
                        ? .answerQuestion
                        : .findDocuments,
            requiredEntities: entities,
            organizations: organizations(in: trimmed),
            locations: locations(in: trimmed),
            timeRanges: dates(in: trimmed),
            amounts: amounts(in: trimmed),
            documentTypes: types,
            topics: detectedTopics,
            mustMatchAll: !entities.isEmpty || !detectedTopics.isEmpty,
            optionalTerms: optionalTerms
        )
        return isFollowUp(trimmed) ? plan.mergingContext(from: previousPlan) : plan
    }

    public func needsModelPlanning(_ query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        return words.count >= 5
            || query.contains("?")
            || query.lowercased().contains("zu tun")
            || query.lowercased().contains("betreffen")
    }

    public func isFollowUp(_ query: String) -> Bool {
        let lower = query.lowercased()
        return Self.followUpMarkers.contains(where: lower.contains)
    }

    private func capitalizedEntities(in text: String) -> [String] {
        let tokens = matches(
            #"\b[A-ZÄÖÜ][A-Za-zÄÖÜäöüß'’\-]{2,}\b"#,
            in: text
        )
        return tokens.compactMap { token in
            guard !Self.ignoredCapitalizedWords.contains(token),
                  !Self.documentTypes.contains(where: {
                      $0.compare(token, options: .caseInsensitive) == .orderedSame
                  }) else { return nil }
            if token.hasSuffix("s"), token.count > 4 {
                return String(token.dropLast())
            }
            return token
        }
    }

    private func uniqueIdentifiers(in text: String) -> [String] {
        var values: [String] = []
        let patterns = [
            #"\b[A-Z]{2}\d{2}(?:[ ]?[A-Z0-9]){11,30}\b"#,
            #"\b[A-ZÄÖÜ]{1,5}[-/]\d{2,}(?:[-/]\d+)*\b"#,
            #"\b(?:Kunden|Vertrags|Akten|Vorgangs)(?:nummer|zeichen)?[: ]+[A-Z0-9][A-Z0-9./-]{3,}\b"#
        ]
        for pattern in patterns {
            values.append(contentsOf: matches(pattern, in: text))
        }
        return values
    }

    private func organizations(in text: String) -> [String] {
        matches(#"\b[\p{Lu}][\p{L}&.'’-]+(?:\s+[\p{Lu}][\p{L}&.'’-]+)*\s+(?:GmbH|AG|e\.V\.|KG|Behörde|Amt)\b"#, in: text)
    }

    private func locations(in text: String) -> [String] {
        let values = matches(
            #"\b(?:in|aus|bei|nach|von)\s+[\p{Lu}][\p{L}'’-]+(?:\s+[\p{Lu}][\p{L}'’-]+)?\b"#,
            in: text
        )
        return values.compactMap { value in
            value.firstIndex(of: " ").map {
                String(value[value.index(after: $0)...])
            }
        }
    }

    private func dates(in text: String) -> [String] {
        matches(#"\b(?:\d{1,2}[./-]\d{1,2}[./-]\d{2,4}|\d{4})\b"#, in: text)
    }

    private func amounts(in text: String) -> [String] {
        matches(#"\b\d{1,3}(?:[.\s]\d{3})*(?:,\d{2})?\s?(?:€|EUR)\b"#, in: text)
    }

    private func matches(_ pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }
}

public protocol SearchPlanning: Sendable {
    func planSearch(query: String, ruleBasedPlan: SearchPlan) async throws -> SearchPlan
}

public struct SearchSessionContext: Equatable, Sendable {
    public let limit: Int
    public private(set) var plans: [SearchPlan] = []

    public init(limit: Int = 6) {
        self.limit = max(1, limit)
    }

    public var latestPlan: SearchPlan? { plans.last }

    public mutating func record(_ plan: SearchPlan) {
        plans.append(plan)
        if plans.count > limit {
            plans.removeFirst(plans.count - limit)
        }
    }

    public mutating func reset() {
        plans.removeAll(keepingCapacity: false)
    }
}

public struct SourceCitationValidator: Sendable {
    public static let noEvidenceMessage =
        "In den indexierten Unterlagen wurde keine ausreichend belastbare Antwort gefunden."

    public init() {}

    public func validate(_ output: String, sourceCount: Int) -> String {
        guard sourceCount > 0 else { return Self.noEvidenceMessage }
        var cleaned = output.replacingOccurrences(
            of: #"<think>[\s\S]*?</think>"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let citedIdentifiers = Set(
            cleaned.matches(of: /S-\d{3}/).map { String($0.output) }
        )
        let validIdentifiers = Set(
            (1...sourceCount).map { String(format: "S-%03d", $0) }
        )
        guard !citedIdentifiers.isEmpty,
              citedIdentifiers.isSubset(of: validIdentifiers) else {
            return Self.noEvidenceMessage
        }
        var hasValidCitation = false
        for index in 1...sourceCount {
            let identifier = String(format: "S-%03d", index)
            if cleaned.contains(identifier) {
                hasValidCitation = true
                cleaned = cleaned.replacingOccurrences(
                    of: "[\(identifier)]",
                    with: "[\(index)]"
                )
                cleaned = cleaned.replacingOccurrences(
                    of: identifier,
                    with: "[\(index)]"
                )
            }
        }
        guard hasValidCitation, !cleaned.isEmpty else {
            return Self.noEvidenceMessage
        }
        return cleaned
    }
}
