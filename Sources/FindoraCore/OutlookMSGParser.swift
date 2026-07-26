import Foundation

public struct OutlookMSGParser: Sendable {
    public init() {}

    public func parse(
        data: Data,
        sourceMailbox: String? = nil
    ) throws -> ParsedMail {
        let compound = try CompoundFile(data: data)
        return try parseMessage(
            compound: compound,
            storageID: compound.rootID,
            sourceMailbox: sourceMailbox,
            rawData: data,
            depth: 0
        )
    }

    private func parseMessage(
        compound: CompoundFile,
        storageID: Int,
        sourceMailbox: String?,
        rawData: Data,
        depth: Int
    ) throws -> ParsedMail {
        guard depth <= MailFileParser.maximumEmbeddedDepth else {
            throw MailParsingError.recursionLimit
        }
        let properties = try compound.properties(in: storageID)
        let transportHeaders = properties.string(0x007D) ?? ""
        let fallbackHeaders = Self.headerFields(transportHeaders)
        let html = properties.html(0x1013)
        let plain = properties.string(0x1000) ?? ""
        let normalized = plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? HTMLMailNormalizer().normalize(html ?? "")
            : Self.normalizePlainText(plain)

        let senderName = properties.string(0x0C1A)
            ?? properties.string(0x0042)
        let senderAddress = properties.string(0x0C1F)
            ?? properties.string(0x0065)
            ?? fallbackHeaders["from"].flatMap(Self.firstEmailAddress)
        let sender = senderAddress.map {
            MailAddress(name: senderName, address: $0)
        }

        var recipients: [MailRecipientRole: [MailAddress]] = [:]
        for child in compound.childEntries(of: storageID)
        where child.name.hasPrefix("__recip_version1.0_") {
            let values = try compound.properties(in: child.id)
            let role: MailRecipientRole = switch values.int32(0x0C15) {
            case 2: .cc
            case 3: .bcc
            default: .to
            }
            let address = values.string(0x39FE)
                ?? values.string(0x3003)
                ?? values.string(0x0C1F)
            if let address, address.contains("@") {
                recipients[role, default: []].append(
                    MailAddress(name: values.string(0x3001), address: address)
                )
            }
        }
        if recipients[.to, default: []].isEmpty {
            recipients[.to] = Self.parseAddressHeader(fallbackHeaders["to"])
        }
        if recipients[.cc, default: []].isEmpty {
            recipients[.cc] = Self.parseAddressHeader(fallbackHeaders["cc"])
        }
        if recipients[.bcc, default: []].isEmpty {
            recipients[.bcc] = Self.parseAddressHeader(fallbackHeaders["bcc"])
        }

        var attachments: [ParsedMailAttachment] = []
        for child in compound.childEntries(of: storageID)
        where child.name.hasPrefix("__attach_version1.0_") {
            let values = try compound.properties(in: child.id)
            let fileName = values.string(0x3707)
                ?? values.string(0x3704)
                ?? "Outlook-Anhang"
            let mimeType = values.string(0x370E)
                ?? Self.mimeType(for: fileName)
            let method = values.int32(0x3705) ?? 1
            if method == 5,
               let embedded = compound.childEntries(of: child.id).first(
                   where: { $0.name.hasPrefix("__substg1.0_3701000D") }
               ) {
                let embeddedRaw = try compound.concatenatedStreamData(in: embedded.id)
                let parsed = try parseMessage(
                    compound: compound,
                    storageID: embedded.id,
                    sourceMailbox: sourceMailbox,
                    rawData: embeddedRaw,
                    depth: depth + 1
                )
                let eml = Self.syntheticEML(parsed)
                attachments.append(
                    ParsedMailAttachment(
                        fileName: fileName.hasSuffix(".msg") ? fileName : fileName + ".eml",
                        mimeType: "message/rfc822",
                        data: eml
                    )
                )
            } else if let attachmentData = values.data(0x3701) {
                let flags = values.int32(0x3714) ?? 0
                attachments.append(
                    ParsedMailAttachment(
                        fileName: fileName,
                        mimeType: mimeType,
                        contentID: values.string(0x3712),
                        isInline: flags & 0x00000004 != 0,
                        data: attachmentData
                    )
                )
            }
        }

        let sentAt = properties.fileTime(0x0039)
            ?? Self.parseDate(fallbackHeaders["date"])
        let receivedAt = properties.fileTime(0x0E06)
        let priority: MailPriority = switch properties.int32(0x0017) {
        case 2: .high
        case 0: .low
        default: .normal
        }
        let references = Self.messageIDs(
            properties.string(0x1039) ?? fallbackHeaders["references"]
        )

        return ParsedMail(
            sourceFormat: .outlookMSG,
            messageID: properties.string(0x1035) ?? fallbackHeaders["message-id"],
            conversationID: properties.data(0x0071)?.base64EncodedString()
                ?? properties.string(0x0070),
            subject: properties.string(0x0037)
                ?? fallbackHeaders["subject"]
                ?? "(Ohne Betreff)",
            sender: sender,
            recipients: recipients,
            sentAt: sentAt,
            receivedAt: receivedAt,
            priority: priority,
            inReplyTo: properties.string(0x1042) ?? fallbackHeaders["in-reply-to"],
            references: references,
            originalText: plain.isEmpty ? (html ?? normalized) : plain,
            normalizedText: normalized,
            html: html,
            characterSet: properties.string(0x3FFD),
            attachments: attachments,
            sourceMailbox: sourceMailbox,
            rawData: rawData
        )
    }

    private static func headerFields(_ raw: String) -> [String: String] {
        var fields: [String: String] = [:]
        var currentKey: String?
        for rawLine in raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if (line.hasPrefix(" ") || line.hasPrefix("\t")), let currentKey {
                fields[currentKey, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            fields[key] = value
            currentKey = key
        }
        return fields
    }

    private static func parseAddressHeader(_ value: String?) -> [MailAddress] {
        guard let value else { return [] }
        return value.split(separator: ",").compactMap { component in
            let string = MIMEMessageParser.decodeHeader(String(component))
            guard let address = firstEmailAddress(string) else { return nil }
            let name = string.replacingOccurrences(of: address, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: " <>\"'"))
            return MailAddress(name: name.isEmpty ? nil : name, address: address)
        }
    }

    private static func firstEmailAddress(_ value: String) -> String? {
        let pattern = #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ), let match = regex.firstMatch(
            in: value,
            range: NSRange(value.startIndex..., in: value)
        ), let range = Range(match.range, in: value) else {
            return nil
        }
        return String(value[range])
    }

    private static func messageIDs(_ value: String?) -> [String] {
        guard let value else { return [] }
        let pattern = #"<([^>]+)>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(
            in: value,
            range: NSRange(value.startIndex..., in: value)
        ).compactMap { match in
            guard let range = Range(match.range(at: 1), in: value) else { return nil }
            return String(value[range])
        }
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        for format in [
            "EEE, d MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "d MMM yyyy HH:mm:ss Z"
        ] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    private static func normalizePlainText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func mimeType(for fileName: String) -> String {
        switch URL(filePath: fileName).pathExtension.lowercased() {
        case "pdf": "application/pdf"
        case "txt": "text/plain"
        case "md": "text/markdown"
        case "eml": "message/rfc822"
        case "msg": "application/vnd.ms-outlook"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "tif", "tiff": "image/tiff"
        default: "application/octet-stream"
        }
    }

    private static func syntheticEML(_ mail: ParsedMail) -> Data {
        var lines: [String] = []
        if let messageID = mail.messageID {
            lines.append("Message-ID: <\(messageID)>")
        }
        lines.append("Subject: \(mail.subject)")
        if let sender = mail.sender {
            lines.append("From: \(sender.name.map { "\($0) " } ?? "")<\(sender.address)>")
        }
        if let sentAt = mail.sentAt {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
            lines.append("Date: \(formatter.string(from: sentAt))")
        }
        lines.append("Content-Type: text/plain; charset=utf-8")
        lines.append("Content-Transfer-Encoding: 8bit")
        lines.append("")
        lines.append(mail.normalizedText)
        return Data(lines.joined(separator: "\r\n").utf8)
    }
}

private struct CompoundFile: Sendable {
    struct Entry: Sendable {
        let id: Int
        let name: String
        let type: UInt8
        let leftID: UInt32
        let rightID: UInt32
        let childID: UInt32
        let startSector: UInt32
        let streamSize: UInt64
    }

    let data: Data
    let sectorSize: Int
    let miniSectorSize: Int
    let miniStreamCutoff: Int
    let fat: [UInt32]
    let miniFAT: [UInt32]
    let entries: [Entry]
    let rootID: Int
    let rootMiniStream: Data

    init(data: Data) throws {
        guard data.count >= 512,
              data.prefix(8) == Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) else {
            throw MailParsingError.malformedMSG("Ungültige Compound-File-Signatur.")
        }
        guard data.u16(at: 28) == 0xFFFE else {
            throw MailParsingError.malformedMSG("Nicht unterstützte Byte-Reihenfolge.")
        }
        let sectorShift = Int(data.u16(at: 30))
        let miniShift = Int(data.u16(at: 32))
        guard (sectorShift == 9 || sectorShift == 12), miniShift == 6 else {
            throw MailParsingError.malformedMSG("Nicht unterstützte Sektorgröße.")
        }
        self.data = data
        self.sectorSize = 1 << sectorShift
        self.miniSectorSize = 1 << miniShift
        self.miniStreamCutoff = Int(data.u32(at: 56))

        let fatSectorCount = Int(data.u32(at: 44))
        var fatSectorIDs: [UInt32] = []
        for index in 0..<109 {
            let value = data.u32(at: 76 + index * 4)
            if Self.isRegularSector(value) { fatSectorIDs.append(value) }
        }
        var difatSector = data.u32(at: 68)
        let difatCount = Int(data.u32(at: 72))
        var visitedDIFAT: Set<UInt32> = []
        for _ in 0..<difatCount where Self.isRegularSector(difatSector) {
            guard visitedDIFAT.insert(difatSector).inserted else {
                throw MailParsingError.malformedMSG("Zyklische DIFAT-Kette.")
            }
            let bytes = try Self.sector(data, id: difatSector, sectorSize: sectorSize)
            let entriesPerSector = sectorSize / 4 - 1
            for index in 0..<entriesPerSector {
                let value = bytes.u32(at: index * 4)
                if Self.isRegularSector(value) { fatSectorIDs.append(value) }
            }
            difatSector = bytes.u32(at: entriesPerSector * 4)
        }
        guard fatSectorIDs.count >= fatSectorCount else {
            throw MailParsingError.malformedMSG("FAT-Sektoren fehlen.")
        }

        var fat: [UInt32] = []
        for sectorID in fatSectorIDs.prefix(fatSectorCount) {
            let bytes = try Self.sector(data, id: sectorID, sectorSize: sectorSize)
            for offset in stride(from: 0, to: bytes.count, by: 4) {
                fat.append(bytes.u32(at: offset))
            }
        }
        self.fat = fat

        let directorySector = data.u32(at: 48)
        let directoryData = try Self.chainData(
            data: data,
            start: directorySector,
            allocation: fat,
            sectorSize: sectorSize
        )
        var entries: [Entry] = []
        for offset in stride(from: 0, through: max(0, directoryData.count - 128), by: 128) {
            let raw = directoryData.subdata(in: offset..<(offset + 128))
            let nameByteCount = max(0, min(64, Int(raw.u16(at: 64))) - 2)
            let nameData = raw.subdata(in: 0..<nameByteCount)
            let name = String(data: nameData, encoding: .utf16LittleEndian) ?? ""
            entries.append(
                Entry(
                    id: entries.count,
                    name: name,
                    type: raw[66],
                    leftID: raw.u32(at: 68),
                    rightID: raw.u32(at: 72),
                    childID: raw.u32(at: 76),
                    startSector: raw.u32(at: 116),
                    streamSize: raw.u64(at: 120)
                )
            )
        }
        guard let root = entries.first(where: { $0.type == 5 }) else {
            throw MailParsingError.malformedMSG("Root-Storage fehlt.")
        }
        self.entries = entries
        self.rootID = root.id

        let miniFATStart = data.u32(at: 60)
        let miniFATCount = Int(data.u32(at: 64))
        if miniFATCount > 0, Self.isRegularSector(miniFATStart) {
            let bytes = try Self.chainData(
                data: data,
                start: miniFATStart,
                allocation: fat,
                sectorSize: sectorSize,
                maximumSectors: miniFATCount
            )
            var mini: [UInt32] = []
            for offset in stride(from: 0, to: bytes.count, by: 4) {
                mini.append(bytes.u32(at: offset))
            }
            self.miniFAT = mini
        } else {
            self.miniFAT = []
        }
        if root.streamSize > 0, Self.isRegularSector(root.startSector) {
            let bytes = try Self.chainData(
                data: data,
                start: root.startSector,
                allocation: fat,
                sectorSize: sectorSize
            )
            self.rootMiniStream = Data(bytes.prefix(Int(root.streamSize)))
        } else {
            self.rootMiniStream = Data()
        }
    }

    func childEntries(of storageID: Int) -> [Entry] {
        guard entries.indices.contains(storageID) else { return [] }
        var result: [Entry] = []
        var visited: Set<UInt32> = []
        walkSiblingTree(entries[storageID].childID, visited: &visited, output: &result)
        return result
    }

    func properties(in storageID: Int) throws -> MSGProperties {
        var values: [UInt16: [UInt16: Data]] = [:]
        for child in childEntries(of: storageID) where child.type == 2 {
            guard let property = Self.propertyName(child.name) else { continue }
            values[property.id, default: [:]][property.type] = try streamData(child)
        }
        return MSGProperties(values: values)
    }

    func concatenatedStreamData(in storageID: Int) throws -> Data {
        var result = Data()
        for child in childEntries(of: storageID).sorted(by: { $0.name < $1.name }) {
            if child.type == 2 {
                result.append(try streamData(child))
            } else if child.type == 1 {
                result.append(try concatenatedStreamData(in: child.id))
            }
        }
        return result
    }

    private func walkSiblingTree(
        _ rawID: UInt32,
        visited: inout Set<UInt32>,
        output: inout [Entry]
    ) {
        guard rawID != Self.noStream,
              rawID < UInt32(entries.count),
              visited.insert(rawID).inserted else { return }
        let entry = entries[Int(rawID)]
        walkSiblingTree(entry.leftID, visited: &visited, output: &output)
        output.append(entry)
        walkSiblingTree(entry.rightID, visited: &visited, output: &output)
    }

    private func streamData(_ entry: Entry) throws -> Data {
        let size = Int(min(entry.streamSize, UInt64(Int.max)))
        guard size > 0 else { return Data() }
        if size < miniStreamCutoff,
           !miniFAT.isEmpty,
           Self.isRegularSector(entry.startSector) {
            var result = Data()
            var sector = entry.startSector
            var visited: Set<UInt32> = []
            while Self.isRegularSector(sector), result.count < size {
                guard visited.insert(sector).inserted,
                      Int(sector) < miniFAT.count else {
                    throw MailParsingError.malformedMSG("Ungültige MiniFAT-Kette.")
                }
                let offset = Int(sector) * miniSectorSize
                guard offset + miniSectorSize <= rootMiniStream.count else {
                    throw MailParsingError.malformedMSG("Mini-Stream liegt außerhalb des Containers.")
                }
                result.append(rootMiniStream.subdata(in: offset..<(offset + miniSectorSize)))
                sector = miniFAT[Int(sector)]
            }
            return Data(result.prefix(size))
        }
        let bytes = try Self.chainData(
            data: data,
            start: entry.startSector,
            allocation: fat,
            sectorSize: sectorSize
        )
        return Data(bytes.prefix(size))
    }

    private static func propertyName(_ name: String) -> (id: UInt16, type: UInt16)? {
        guard name.hasPrefix("__substg1.0_") else { return nil }
        let suffix = name.dropFirst("__substg1.0_".count)
        guard suffix.count >= 8 else { return nil }
        let idText = suffix.prefix(4)
        let typeText = suffix.dropFirst(4).prefix(4)
        guard let id = UInt16(idText, radix: 16),
              let type = UInt16(typeText, radix: 16) else { return nil }
        return (id, type)
    }

    private static func chainData(
        data: Data,
        start: UInt32,
        allocation: [UInt32],
        sectorSize: Int,
        maximumSectors: Int? = nil
    ) throws -> Data {
        guard isRegularSector(start) else { return Data() }
        var result = Data()
        var sector = start
        var visited: Set<UInt32> = []
        let maximum = maximumSectors ?? max(1, allocation.count)
        while isRegularSector(sector), result.count / sectorSize < maximum {
            guard visited.insert(sector).inserted,
                  Int(sector) < allocation.count else {
                throw MailParsingError.malformedMSG("Ungültige oder zyklische FAT-Kette.")
            }
            result.append(try self.sector(data, id: sector, sectorSize: sectorSize))
            sector = allocation[Int(sector)]
        }
        return result
    }

    private static func sector(
        _ data: Data,
        id: UInt32,
        sectorSize: Int
    ) throws -> Data {
        let offset = (Int(id) + 1) * sectorSize
        guard offset >= 0, offset + sectorSize <= data.count else {
            throw MailParsingError.malformedMSG("Sektor liegt außerhalb des Containers.")
        }
        return data.subdata(in: offset..<(offset + sectorSize))
    }

    private static func isRegularSector(_ value: UInt32) -> Bool {
        value < 0xFFFFFFFA
    }

    private static let noStream: UInt32 = 0xFFFFFFFF
}

private struct MSGProperties: Sendable {
    let values: [UInt16: [UInt16: Data]]

    func data(_ id: UInt16) -> Data? {
        values[id]?[0x0102]
            ?? values[id]?[0x000D]
    }

    func string(_ id: UInt16) -> String? {
        if let unicode = values[id]?[0x001F] {
            return String(data: unicode.removingTrailingNulls(unit: 2), encoding: .utf16LittleEndian)?
                .trimmingCharacters(in: .controlCharacters)
        }
        if let ansi = values[id]?[0x001E] {
            return String(data: ansi.removingTrailingNulls(unit: 1), encoding: .windowsCP1252)
                ?? String(data: ansi.removingTrailingNulls(unit: 1), encoding: .utf8)
        }
        return nil
    }

    func html(_ id: UInt16) -> String? {
        if let text = string(id) { return text }
        guard let data = data(id) else { return nil }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
    }

    func int32(_ id: UInt16) -> Int32? {
        guard let data = values[id]?[0x0003], data.count >= 4 else { return nil }
        return Int32(bitPattern: data.u32(at: 0))
    }

    func fileTime(_ id: UInt16) -> Date? {
        guard let data = values[id]?[0x0040], data.count >= 8 else { return nil }
        let ticks = data.u64(at: 0)
        guard ticks > 0 else { return nil }
        let seconds = Double(ticks) / 10_000_000.0 - 11_644_473_600.0
        return Date(timeIntervalSince1970: seconds)
    }
}

private extension Data {
    func u16(at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        let byte0 = UInt16(self[index(startIndex, offsetBy: offset)])
        let byte1 = UInt16(self[index(startIndex, offsetBy: offset + 1)])
        return byte0 | (byte1 << 8)
    }

    func u32(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        let byte0 = UInt32(self[index(startIndex, offsetBy: offset)])
        let byte1 = UInt32(self[index(startIndex, offsetBy: offset + 1)])
        let byte2 = UInt32(self[index(startIndex, offsetBy: offset + 2)])
        let byte3 = UInt32(self[index(startIndex, offsetBy: offset + 3)])
        return byte0 | (byte1 << 8) | (byte2 << 16) | (byte3 << 24)
    }

    func u64(at offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= count else { return 0 }
        return UInt64(u32(at: offset))
            | UInt64(u32(at: offset + 4)) << 32
    }

    func removingTrailingNulls(unit: Int) -> Data {
        var end = count
        while end >= unit {
            let range = (end - unit)..<end
            if self[range].allSatisfy({ $0 == 0 }) {
                end -= unit
            } else {
                break
            }
        }
        return subdata(in: 0..<end)
    }
}
