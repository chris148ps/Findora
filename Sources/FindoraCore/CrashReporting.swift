import Foundation

public struct CrashReportConfiguration: Equatable, Sendable {
    public let isEnabled: Bool
    public let recipient: String

    public init(isEnabled: Bool, recipient: String) {
        self.isEnabled = isEnabled
        self.recipient = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct CrashReportSession: Sendable {
    public let directory: URL
    public let markerURL: URL
    public let pendingReportURL: URL
}

public enum CrashReportDeliveryResult: Equatable, Sendable {
    case noPendingReport
    case disabled
    case invalidRecipient
    case sent
    case failed(String)
}

public protocol CrashReportSending: Sendable {
    func sendCrashReport(
        recipient: String,
        subject: String,
        reportFile: URL
    ) async throws
}

public enum CrashReportCoordinator {
    private struct RunMarker: Codable {
        let sessionID: UUID
        let startedAt: Date
        let appVersion: String
        let buildVersion: String
        let processID: Int32
    }

    public static func defaultDirectory(
        fileManager: FileManager = .default
    ) -> URL {
        FindoraRuntimeEnvironment.applicationSupportRoot(
            fileManager: fileManager
        )
            .appending(path: "CrashReports", directoryHint: .isDirectory)
    }

    public static func beginSession(
        directory: URL? = nil,
        logFile: URL? = nil,
        diagnosticsDirectory: URL? = nil,
        appVersion: String,
        buildVersion: String,
        now: Date = .now,
        processID: Int32 = ProcessInfo.processInfo.processIdentifier,
        fileManager: FileManager = .default
    ) throws -> CrashReportSession {
        let directory = directory ?? defaultDirectory(fileManager: fileManager)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let markerURL = directory.appending(path: "running-session.json")
        let pendingURL = directory.appending(path: "pending-crash-report.txt")

        if fileManager.fileExists(atPath: markerURL.path),
           !fileManager.fileExists(atPath: pendingURL.path) {
            let markerData = try? Data(contentsOf: markerURL)
            let previous = markerData.flatMap {
                try? JSONDecoder().decode(RunMarker.self, from: $0)
            }
            let report = buildReport(
                previous: previous,
                logFile: logFile,
                diagnosticsDirectory: diagnosticsDirectory,
                generatedAt: now,
                fileManager: fileManager
            )
            try Data(report.utf8).write(to: pendingURL, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: pendingURL.path
            )
        }

        let current = RunMarker(
            sessionID: UUID(),
            startedAt: now,
            appVersion: appVersion,
            buildVersion: buildVersion,
            processID: processID
        )
        let data = try JSONEncoder().encode(current)
        try data.write(to: markerURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: markerURL.path
        )
        return CrashReportSession(
            directory: directory,
            markerURL: markerURL,
            pendingReportURL: pendingURL
        )
    }

    public static func endCurrentSession(
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        let directory = directory ?? defaultDirectory(fileManager: fileManager)
        let marker = directory.appending(path: "running-session.json")
        try? fileManager.removeItem(at: marker)
    }

    public static func hasPendingReport(
        session: CrashReportSession,
        fileManager: FileManager = .default
    ) -> Bool {
        fileManager.fileExists(atPath: session.pendingReportURL.path)
    }

    public static func deliverPendingReport(
        session: CrashReportSession,
        configuration: CrashReportConfiguration,
        sender: any CrashReportSending,
        fileManager: FileManager = .default
    ) async -> CrashReportDeliveryResult {
        guard hasPendingReport(session: session, fileManager: fileManager) else {
            return .noPendingReport
        }
        guard configuration.isEnabled else {
            return .disabled
        }
        guard isValidEmailAddress(configuration.recipient) else {
            return .invalidRecipient
        }
        do {
            try await sender.sendCrashReport(
                recipient: configuration.recipient,
                subject: "Findora Crashbericht",
                reportFile: session.pendingReportURL
            )
            try fileManager.removeItem(at: session.pendingReportURL)
            return .sent
        } catch {
            return .failed(safeFailureDescription(error))
        }
    }

    public static func isValidEmailAddress(_ value: String) -> Bool {
        let address = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.count <= 254,
              !address.contains("\n"),
              !address.contains("\r") else { return false }
        return address.range(
            of: #"^[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,63}$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func buildReport(
        previous: RunMarker?,
        logFile: URL?,
        diagnosticsDirectory: URL?,
        generatedAt: Date,
        fileManager: FileManager
    ) -> String {
        var sections = [
            "Findora Crashbericht",
            "Erstellt: \(generatedAt.ISO8601Format())",
            "Vorherige Sitzung: \(previous?.sessionID.uuidString ?? "unbekannt")",
            "Start: \(previous?.startedAt.ISO8601Format() ?? "unbekannt")",
            "App-Version: \(previous?.appVersion ?? "unbekannt")",
            "Build: \(previous?.buildVersion ?? "unbekannt")",
            "Prozess-ID: \(previous.map { String($0.processID) } ?? "unbekannt")"
        ]

        if let diagnostic = newestDiagnosticReport(
            after: previous?.startedAt,
            diagnosticsDirectory: diagnosticsDirectory,
            fileManager: fileManager
        ),
        let data = try? Data(contentsOf: diagnostic),
        let text = String(data: data.prefix(200_000), encoding: .utf8) {
            sections.append("\n--- macOS-Diagnoseauszug ---\n")
            sections.append(sanitizedDiagnosticText(text))
        } else {
            sections.append(
                "\nKein passender macOS-Diagnosebericht gefunden; "
                + "die vorherige Sitzung wurde nicht regulär beendet."
            )
        }

        if let logFile,
           let log = try? String(contentsOf: logFile, encoding: .utf8) {
            let tail = log.split(separator: "\n", omittingEmptySubsequences: false)
                .suffix(200)
                .joined(separator: "\n")
            sections.append("\n--- Bereinigtes Findora-Protokoll ---\n")
            sections.append(sanitizedDiagnosticText(tail))
        }
        sections.append(
            "\nDokumentinhalte, Suchanfragen und vollständige private Pfade "
            + "werden nicht in diesen Bericht aufgenommen."
        )
        return sections.joined(separator: "\n")
    }

    private static func newestDiagnosticReport(
        after start: Date?,
        diagnosticsDirectory: URL?,
        fileManager: FileManager
    ) -> URL? {
        let directory = diagnosticsDirectory ?? fileManager.urls(
            for: .libraryDirectory,
            in: .userDomainMask
        ).first?
            .appending(path: "Logs", directoryHint: .isDirectory)
            .appending(path: "DiagnosticReports", directoryHint: .isDirectory)
        guard let directory,
              let files = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else { return nil }
        let threshold = start?.addingTimeInterval(-300)
        return files.compactMap { url -> (URL, Date)? in
            let name = url.lastPathComponent.lowercased()
            guard name.hasPrefix("findora-") || name.hasPrefix("findora_"),
                  ["ips", "crash"].contains(url.pathExtension.lowercased()),
                  let modified = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey]
                  ).contentModificationDate,
                  threshold.map({ modified >= $0 }) ?? true else { return nil }
            return (url, modified)
        }
        .max(by: { $0.1 < $1.1 })?
        .0
    }

    public static func sanitizedDiagnosticText(_ input: String) -> String {
        var value = input
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
        let replacements: [(String, String)] = [
            (#"(?im)\bpath=[^\r\n]*"#, "path=<redacted>"),
            (#"~/[^\s\"",}]+"#, "<redacted-path>"),
            (
                #"(?i)\b[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,63}\b"#,
                "<redacted-email>"
            ),
            (
                #"(?:/Users|/Volumes|/private|/tmp|/var/folders)/[^\s\"",}]+"#,
                "<redacted-path>"
            )
        ]
        for (pattern, replacement) in replacements {
            value = value.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }
        return value
    }

    private static func safeFailureDescription(_ error: Error) -> String {
        let message = error.localizedDescription
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        return String(message.prefix(500))
    }
}
