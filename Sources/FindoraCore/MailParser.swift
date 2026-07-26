import Foundation

public enum MailParsingError: LocalizedError, Sendable {
    case unsupportedFormat(String)
    case malformedMessage(String)
    case malformedMailbox(String)
    case malformedMSG(String)
    case recursionLimit

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let value):
            "Das E-Mail-Format wird nicht unterstützt: \(value)"
        case .malformedMessage(let detail):
            "Die E-Mail ist beschädigt oder unvollständig: \(detail)"
        case .malformedMailbox(let detail):
            "Das MBOX-Archiv ist beschädigt oder unvollständig: \(detail)"
        case .malformedMSG(let detail):
            "Die Outlook-MSG-Datei ist beschädigt oder nicht unterstützt: \(detail)"
        case .recursionLimit:
            "Die maximale Rekursionstiefe für eingebettete Nachrichten wurde erreicht."
        }
    }
}

public struct MailFileParser: Sendable {
    public static let maximumEmbeddedDepth = 4

    private let mimeParser = MIMEMessageParser()
    private let msgParser = OutlookMSGParser()

    public init() {}

    public func parse(
        fileAt url: URL,
        sourceMailbox: String? = nil
    ) throws -> ParsedMail {
        let ext = url.pathExtension.lowercased()
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        switch ext {
        case "eml":
            return try mimeParser.parse(
                data: data,
                sourceFormat: .eml,
                sourceMailbox: sourceMailbox
            )
        case "msg":
            return try msgParser.parse(
                data: data,
                sourceMailbox: sourceMailbox
            )
        default:
            throw MailParsingError.unsupportedFormat(url.lastPathComponent)
        }
    }

    public func forEachMessage(
        inMBOX url: URL,
        sourceMailbox: String? = nil,
        handler: @Sendable (ParsedMail) async throws -> Void
    ) async throws {
        try await MBOXStreamReader().forEachMessage(in: url) { data in
            let parsed = try mimeParser.parse(
                data: data,
                sourceFormat: .mbox,
                sourceMailbox: sourceMailbox ?? url.deletingPathExtension().lastPathComponent
            )
            try await handler(parsed)
        }
    }
}

public struct MBOXStreamReader: Sendable {
    public let chunkSize: Int
    public let maximumMessageBytes: Int

    public init(
        chunkSize: Int = 64 * 1_024,
        maximumMessageBytes: Int = 256 * 1_024 * 1_024
    ) {
        self.chunkSize = chunkSize
        self.maximumMessageBytes = maximumMessageBytes
    }

    public func forEachMessage(
        in url: URL,
        handler: @Sendable (Data) async throws -> Void
    ) async throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var pending = Data()
        var message = Data()
        var sawEnvelope = false

        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                let lineRange = pending.startIndex...newline
                var line = Data(pending[lineRange])
                pending.removeSubrange(lineRange)

                let isEnvelope = line.starts(with: Data("From ".utf8))
                if isEnvelope {
                    if sawEnvelope, !message.isEmpty {
                        try await handler(Self.trimLeadingLineBreaks(message))
                        message.removeAll(keepingCapacity: true)
                    }
                    sawEnvelope = true
                    continue
                }

                if line.starts(with: Data(">From ".utf8)) {
                    line.removeFirst()
                }
                message.append(line)
                guard message.count <= maximumMessageBytes else {
                    throw MailParsingError.malformedMailbox(
                        "Eine einzelne Nachricht überschreitet \(maximumMessageBytes) Byte."
                    )
                }
            }
        }

        if !pending.isEmpty {
            message.append(pending)
        }
        if !message.isEmpty {
            try await handler(Self.trimLeadingLineBreaks(message))
        } else if !sawEnvelope {
            throw MailParsingError.malformedMailbox("Keine Nachricht gefunden.")
        }
    }

    private static func trimLeadingLineBreaks(_ data: Data) -> Data {
        var value = data
        while value.starts(with: [0x0A]) || value.starts(with: [0x0D, 0x0A]) {
            if value.starts(with: [0x0D, 0x0A]) {
                value.removeFirst(2)
            } else {
                value.removeFirst()
            }
        }
        return value
    }
}

public struct MIMEMessageParser: Sendable {
    private struct MIMEPart {
        let headers: [String: String]
        let body: Data
    }

    private struct ParsedBody {
        var plainTexts: [String] = []
        var htmlTexts: [String] = []
        var characterSets: [String] = []
        var attachments: [ParsedMailAttachment] = []
    }

    public init() {}

    public func parse(
        data: Data,
        sourceFormat: MailSourceFormat,
        sourceMailbox: String? = nil
    ) throws -> ParsedMail {
        let root = try splitPart(data)
        var body = ParsedBody()
        try collect(part: root, depth: 0, into: &body)

        let plain = body.plainTexts
            .map(Self.normalizePlainText)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let html = body.htmlTexts.isEmpty ? nil : body.htmlTexts.joined(separator: "\n")
        let normalizedHTML = html.map(HTMLMailNormalizer().normalize) ?? ""
        let normalized = plain.isEmpty ? normalizedHTML : plain
        let original = plain.isEmpty ? (html ?? normalizedHTML) : plain

        let sender = Self.parseAddresses(root.headers["from"] ?? root.headers["sender"]).first
        var recipients: [MailRecipientRole: [MailAddress]] = [:]
        recipients[.to] = Self.parseAddresses(root.headers["to"])
        recipients[.cc] = Self.parseAddresses(root.headers["cc"])
        recipients[.bcc] = Self.parseAddresses(root.headers["bcc"])

        return ParsedMail(
            sourceFormat: sourceFormat,
            messageID: root.headers["message-id"],
            conversationID: root.headers["thread-index"]
                ?? root.headers["x-conversation-id"],
            subject: Self.decodeHeader(root.headers["subject"] ?? ""),
            sender: sender,
            recipients: recipients,
            sentAt: Self.parseDate(root.headers["date"]),
            receivedAt: Self.receivedDate(root.headers["received"]),
            priority: Self.priority(root.headers),
            inReplyTo: root.headers["in-reply-to"],
            references: Self.messageIDs(root.headers["references"]),
            originalText: original,
            normalizedText: normalized,
            html: html,
            characterSet: body.characterSets.first,
            attachments: body.attachments,
            sourceMailbox: sourceMailbox,
            rawData: data
        )
    }

    private func collect(
        part: MIMEPart,
        depth: Int,
        into result: inout ParsedBody
    ) throws {
        guard depth <= MailFileParser.maximumEmbeddedDepth else {
            throw MailParsingError.recursionLimit
        }

        let contentType = Self.parameterizedHeader(
            part.headers["content-type"] ?? "text/plain; charset=utf-8"
        )
        let disposition = Self.parameterizedHeader(
            part.headers["content-disposition"] ?? ""
        )
        let mediaType = contentType.value.lowercased()

        if mediaType.hasPrefix("multipart/"),
           let boundary = contentType.parameters["boundary"],
           !boundary.isEmpty {
            for childData in Self.multipartBodies(part.body, boundary: boundary) {
                try collect(part: splitPart(childData), depth: depth + 1, into: &result)
            }
            return
        }

        let decoded = Self.decodeTransfer(
            part.body,
            encoding: part.headers["content-transfer-encoding"]
        )
        let fileName = disposition.parameters["filename"]
            ?? contentType.parameters["name"]
        let isAttachment = disposition.value.lowercased() == "attachment"
            || fileName != nil
        let isInline = disposition.value.lowercased() == "inline"

        if mediaType == "message/rfc822" {
            let nestedName = fileName ?? "Eingebettete Nachricht.eml"
            result.attachments.append(
                ParsedMailAttachment(
                    fileName: nestedName,
                    mimeType: mediaType,
                    contentID: part.headers["content-id"],
                    isInline: isInline,
                    data: decoded
                )
            )
            return
        }

        if isAttachment || (!mediaType.hasPrefix("text/") && mediaType != "application/xhtml+xml") {
            result.attachments.append(
                ParsedMailAttachment(
                    fileName: Self.decodeHeader(fileName ?? Self.defaultFileName(for: mediaType)),
                    mimeType: mediaType,
                    contentID: part.headers["content-id"]?.trimmingCharacters(
                        in: CharacterSet(charactersIn: "<>")
                    ),
                    isInline: isInline,
                    data: decoded
                )
            )
            return
        }

        let charset = contentType.parameters["charset"]?.lowercased() ?? "utf-8"
        let text = Self.decodeText(decoded, charset: charset)
        result.characterSets.append(charset)
        if mediaType == "text/html" || mediaType == "application/xhtml+xml" {
            result.htmlTexts.append(text)
        } else {
            result.plainTexts.append(text)
        }
    }

    private func splitPart(_ data: Data) throws -> MIMEPart {
        let separators = [Data("\r\n\r\n".utf8), Data("\n\n".utf8)]
        guard let split = separators.compactMap({ separator -> (Range<Data.Index>, Int)? in
            data.range(of: separator).map { ($0, separator.count) }
        }).min(by: { $0.0.lowerBound < $1.0.lowerBound }) else {
            throw MailParsingError.malformedMessage("Kopfzeilen und Inhalt sind nicht getrennt.")
        }
        let headerData = data[..<split.0.lowerBound]
        let bodyStart = split.0.lowerBound + split.1
        let body = bodyStart <= data.endIndex ? Data(data[bodyStart...]) : Data()
        let headerText = String(data: headerData, encoding: .isoLatin1)
            ?? String(decoding: headerData, as: UTF8.self)
        return MIMEPart(headers: Self.parseHeaders(headerText), body: body)
    }

    private static func parseHeaders(_ value: String) -> [String: String] {
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var unfolded: [String] = []
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if (line.first == " " || line.first == "\t"), !unfolded.isEmpty {
                unfolded[unfolded.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
            } else {
                unfolded.append(String(line))
            }
        }
        var headers: [String: String] = [:]
        for line in unfolded {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let rawValue = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let existing = headers[name] {
                headers[name] = existing + "\n" + rawValue
            } else {
                headers[name] = rawValue
            }
        }
        return headers
    }

    private static func parameterizedHeader(
        _ rawValue: String
    ) -> (value: String, parameters: [String: String]) {
        let segments = splitHeaderParameters(rawValue)
        let value = segments.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var parameters: [String: String] = [:]
        for segment in segments.dropFirst() {
            guard let equals = segment.firstIndex(of: "=") else { continue }
            let key = segment[..<equals]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            var parameter = segment[segment.index(after: equals)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if parameter.hasPrefix("\""), parameter.hasSuffix("\""), parameter.count >= 2 {
                parameter.removeFirst()
                parameter.removeLast()
            }
            parameters[key] = decodeHeader(parameter)
        }
        return (value, parameters)
    }

    private static func splitHeaderParameters(_ value: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        for character in value {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" && quoted {
                escaped = true
            } else if character == "\"" {
                quoted.toggle()
                current.append(character)
            } else if character == ";" && !quoted {
                result.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        result.append(current)
        return result
    }

    private static func multipartBodies(_ body: Data, boundary: String) -> [Data] {
        let normalized = String(data: body, encoding: .isoLatin1)
            ?? String(decoding: body, as: UTF8.self)
        let marker = "--\(boundary)"
        return normalized
            .components(separatedBy: marker)
            .dropFirst()
            .compactMap { section -> Data? in
                var value = section
                if value.hasPrefix("--") { return nil }
                value = value.trimmingCharacters(in: .newlines)
                guard !value.isEmpty else { return nil }
                return value.data(using: .isoLatin1)
                    ?? value.data(using: .utf8)
            }
    }

    private static func decodeTransfer(_ data: Data, encoding: String?) -> Data {
        switch encoding?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "base64":
            let compact = data.filter {
                !CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar($0))
            }
            return Data(base64Encoded: Data(compact)) ?? data
        case "quoted-printable":
            return decodeQuotedPrintable(data)
        default:
            return data
        }
    }

    private static func decodeQuotedPrintable(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var decoded: [UInt8] = []
        decoded.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x3D {
                if index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                    index += 2
                    continue
                }
                if index + 2 < bytes.count,
                   bytes[index + 1] == 0x0D,
                   bytes[index + 2] == 0x0A {
                    index += 3
                    continue
                }
                if index + 2 < bytes.count,
                   let high = hex(bytes[index + 1]),
                   let low = hex(bytes[index + 2]) {
                    decoded.append((high << 4) | low)
                    index += 3
                    continue
                }
            }
            decoded.append(bytes[index])
            index += 1
        }
        return Data(decoded)
    }

    private static func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 55
        case 97...102: byte - 87
        default: nil
        }
    }

    private static func decodeText(_ data: Data, charset: String) -> String {
        let encoding: String.Encoding = switch charset.lowercased() {
        case "utf-8", "utf8", "us-ascii", "ascii": .utf8
        case "iso-8859-1", "latin1", "iso_8859-1": .isoLatin1
        case "windows-1252", "cp1252": .windowsCP1252
        case "macintosh", "macroman": .macOSRoman
        case "utf-16", "unicode": .unicode
        case "utf-16le": .utf16LittleEndian
        case "utf-16be": .utf16BigEndian
        default: .utf8
        }
        return String(data: data, encoding: encoding)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(decoding: data, as: UTF8.self)
    }

    static func decodeHeader(_ rawValue: String) -> String {
        let pattern = #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return rawValue
        }
        var result = rawValue
        let matches = expression.matches(
            in: result,
            range: NSRange(result.startIndex..., in: result)
        )
        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: result),
                  let charsetRange = Range(match.range(at: 1), in: result),
                  let encodingRange = Range(match.range(at: 2), in: result),
                  let dataRange = Range(match.range(at: 3), in: result) else { continue }
            let charset = String(result[charsetRange])
            let encoding = String(result[encodingRange]).lowercased()
            let payload = String(result[dataRange])
            let data: Data?
            if encoding == "b" {
                data = Data(base64Encoded: payload)
            } else {
                data = decodeQuotedPrintable(
                    Data(payload.replacingOccurrences(of: "_", with: " ").utf8)
                )
            }
            guard let data else { continue }
            result.replaceSubrange(fullRange, with: decodeText(data, charset: charset))
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseAddresses(_ rawValue: String?) -> [MailAddress] {
        guard let rawValue, !rawValue.isEmpty else { return [] }
        return splitAddresses(rawValue).compactMap { raw in
            let value = decodeHeader(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if let open = value.lastIndex(of: "<"),
               let close = value.lastIndex(of: ">"),
               open < close {
                let name = value[..<open]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                let address = value[value.index(after: open)..<close]
                guard address.contains("@") else { return nil }
                return MailAddress(name: name.isEmpty ? nil : name, address: String(address))
            }
            let address = value.trimmingCharacters(
                in: CharacterSet(charactersIn: "\"' <>")
            )
            guard address.contains("@") else { return nil }
            return MailAddress(address: address)
        }
    }

    private static func splitAddresses(_ value: String) -> [String] {
        var values: [String] = []
        var current = ""
        var quoted = false
        var angleDepth = 0
        for character in value {
            if character == "\"" { quoted.toggle() }
            if character == "<" && !quoted { angleDepth += 1 }
            if character == ">" && !quoted { angleDepth = max(0, angleDepth - 1) }
            if (character == "," || character == ";"), !quoted, angleDepth == 0 {
                values.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { values.append(current) }
        return values
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let candidate = value
            .replacingOccurrences(
                of: #"\s+\([^)]*\)\s*$"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let formats = [
            "EEE, d MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "d MMM yyyy HH:mm:ss Z",
            "dd MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm Z",
            "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: candidate) { return date }
        }
        return ISO8601DateFormatter().date(from: candidate)
    }

    private static func receivedDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let last = value.split(separator: "\n").last.map(String.init) ?? value
        let datePart = last.split(separator: ";").last.map(String.init)
        return parseDate(datePart)
    }

    private static func priority(_ headers: [String: String]) -> MailPriority {
        let value = [
            headers["x-priority"],
            headers["priority"],
            headers["importance"]
        ].compactMap { $0 }.joined(separator: " ").lowercased()
        if value.contains("high") || value.hasPrefix("1") || value.hasPrefix("2") {
            return .high
        }
        if value.contains("low") || value.hasPrefix("4") || value.hasPrefix("5") {
            return .low
        }
        return .normal
    }

    private static func messageIDs(_ value: String?) -> [String] {
        guard let value else { return [] }
        let pattern = #"<([^>]+)>"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(
            in: value,
            range: NSRange(value.startIndex..., in: value)
        ).compactMap { match in
            guard let range = Range(match.range(at: 1), in: value) else { return nil }
            return String(value[range])
        }
    }

    private static func normalizePlainText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func defaultFileName(for mediaType: String) -> String {
        switch mediaType {
        case "application/pdf":
            return "Anhang.pdf"
        case "message/rfc822":
            return "Eingebettete Nachricht.eml"
        default:
            let ext = mediaType.split(separator: "/").last.map(String.init) ?? "bin"
            return "Anhang.\(ext)"
        }
    }
}

public struct HTMLMailNormalizer: Sendable {
    public init() {}

    public func normalize(_ html: String) -> String {
        var value = html
        for tag in ["script", "style", "head", "noscript", "svg"] {
            value = value.replacingOccurrences(
                of: "(?is)<\(tag)\\b[^>]*>.*?</\(tag)>",
                with: " ",
                options: .regularExpression
            )
        }
        value = value.replacingOccurrences(
            of: #"(?is)<img\b[^>]*(?:width\s*=\s*["']?1["']?|height\s*=\s*["']?1["']?)[^>]*>"#,
            with: " ",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"(?i)<\s*(br|p|div|li|tr|h[1-6]|blockquote)\b[^>]*>"#,
            with: "\n",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"(?is)<[^>]+>"#,
            with: " ",
            options: .regularExpression
        )
        let entities = [
            "&nbsp;": " ",
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&#39;": "'",
            "&apos;": "'"
        ]
        for (entity, replacement) in entities {
            value = value.replacingOccurrences(
                of: entity,
                with: replacement,
                options: .caseInsensitive
            )
        }
        value = decodeNumericEntities(value)
        value = value.replacingOccurrences(
            of: #"[ \t]+"#,
            with: " ",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #" *\n *"#,
            with: "\n",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodeNumericEntities(_ input: String) -> String {
        let pattern = #"&#(x?[0-9A-Fa-f]+);"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return input
        }
        var result = input
        for match in expression.matches(
            in: result,
            range: NSRange(result.startIndex..., in: result)
        ).reversed() {
            guard let fullRange = Range(match.range(at: 0), in: result),
                  let valueRange = Range(match.range(at: 1), in: result) else { continue }
            let raw = String(result[valueRange])
            let number = raw.hasPrefix("x")
                ? UInt32(raw.dropFirst(), radix: 16)
                : UInt32(raw, radix: 10)
            guard let number, let scalar = UnicodeScalar(number) else { continue }
            result.replaceSubrange(fullRange, with: String(Character(scalar)))
        }
        return result
    }
}
