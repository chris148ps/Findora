import Foundation
import Testing
@testable import FindoraCore

@Test
func runtimeTestRootIsTemporaryIsolatedAndStableAcrossRestarts() {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "FindoraRuntimeTests-\(UUID().uuidString)")
    let environment = [
        FindoraRuntimeEnvironment.testRootVariable: root.path
    ]

    #expect(
        FindoraRuntimeEnvironment.applicationSupportRoot(
            environment: environment
        ).path == root.appending(path: "ApplicationSupport").path
    )
    #expect(
        FindoraRuntimeEnvironment.logRoot(environment: environment).path
            == root.appending(path: "Logs").path
    )

    let firstDefaults = FindoraRuntimeEnvironment.userDefaults(
        environment: environment
    )
    firstDefaults.set("isoliert", forKey: "runtime-test")
    let restartedDefaults = FindoraRuntimeEnvironment.userDefaults(
        environment: environment
    )
    #expect(restartedDefaults.string(forKey: "runtime-test") == "isoliert")
    restartedDefaults.removeObject(forKey: "runtime-test")

    #expect(
        FindoraRuntimeEnvironment.testRoot(
            environment: [
                FindoraRuntimeEnvironment.testRootVariable:
                    NSHomeDirectory() + "/FindoraRuntimeTests"
            ]
        ) == nil
    )
}

@Test
func crashReportIsOptInSanitizedAndRetriedUntilDelivered() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "FindoraCrashReportTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let reportDirectory = root.appending(path: "CrashReports")
    let diagnostics = root.appending(path: "DiagnosticReports")
    try FileManager.default.createDirectory(
        at: diagnostics,
        withIntermediateDirectories: true
    )
    let log = root.appending(path: "Findora.log")
    try Data(
        """
        2026-07-27T10:00:00Z [ERROR] [Test] Kontrollierter Fehler \
        path=\(NSHomeDirectory())/Private/vertrag.pdf
        Kontakt secret@example.com unter /Volumes/Privat/scan.pdf
        """.utf8
    ).write(to: log)

    let first = try CrashReportCoordinator.beginSession(
        directory: reportDirectory,
        logFile: log,
        diagnosticsDirectory: diagnostics,
        appVersion: "0.1.0",
        buildVersion: "1",
        now: Date(timeIntervalSince1970: 100)
    )
    #expect(!CrashReportCoordinator.hasPendingReport(session: first))

    let diagnostic = diagnostics.appending(path: "Findora-2026-07-27.ips")
    try Data(
        """
        {"exception":"synthetic","path":"\(NSHomeDirectory())/Private/file.pdf",\
        "contact":"diagnostic@example.com"}
        """.utf8
    ).write(to: diagnostic)
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 110)],
        ofItemAtPath: diagnostic.path
    )

    let second = try CrashReportCoordinator.beginSession(
        directory: reportDirectory,
        logFile: log,
        diagnosticsDirectory: diagnostics,
        appVersion: "0.1.0",
        buildVersion: "1",
        now: Date(timeIntervalSince1970: 120)
    )
    #expect(CrashReportCoordinator.hasPendingReport(session: second))
    let sanitized = try String(
        contentsOf: second.pendingReportURL,
        encoding: .utf8
    )
    #expect(!sanitized.contains(NSHomeDirectory()))
    #expect(!sanitized.contains("/Private/"))
    #expect(!sanitized.contains("secret@example.com"))
    #expect(!sanitized.contains("diagnostic@example.com"))
    #expect(!sanitized.contains("/Volumes/Privat"))
    #expect(sanitized.contains("<redacted-email>"))
    #expect(sanitized.contains("path=<redacted>"))

    let sender = CrashReportTestSender()
    #expect(
        await CrashReportCoordinator.deliverPendingReport(
            session: second,
            configuration: CrashReportConfiguration(
                isEnabled: false,
                recipient: "owner@example.com"
            ),
            sender: sender
        ) == .disabled
    )
    #expect(await sender.sentCount == 0)
    #expect(CrashReportCoordinator.hasPendingReport(session: second))
    #expect(
        await CrashReportCoordinator.deliverPendingReport(
            session: second,
            configuration: CrashReportConfiguration(
                isEnabled: true,
                recipient: "ungültig"
            ),
            sender: sender
        ) == .invalidRecipient
    )
    #expect(CrashReportCoordinator.hasPendingReport(session: second))
    #expect(
        await CrashReportCoordinator.deliverPendingReport(
            session: second,
            configuration: CrashReportConfiguration(
                isEnabled: true,
                recipient: "owner@example.com"
            ),
            sender: sender
        ) == .sent
    )
    #expect(await sender.sentCount == 1)
    #expect(await sender.lastRecipient == "owner@example.com")
    #expect(!(await sender.lastReport).contains("secret@example.com"))
    #expect(!CrashReportCoordinator.hasPendingReport(session: second))
}

@Test
func gracefulTerminationDoesNotCreateCrashReport() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "FindoraGracefulCrashTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try CrashReportCoordinator.beginSession(
        directory: root,
        appVersion: "0.1.0",
        buildVersion: "1"
    )
    #expect(FileManager.default.fileExists(atPath: first.markerURL.path))
    CrashReportCoordinator.endCurrentSession(directory: root)
    #expect(!FileManager.default.fileExists(atPath: first.markerURL.path))
    let second = try CrashReportCoordinator.beginSession(
        directory: root,
        appVersion: "0.1.0",
        buildVersion: "1"
    )
    #expect(!CrashReportCoordinator.hasPendingReport(session: second))
}

@Test
func failedCrashReportDeliveryKeepsPendingReport() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "FindoraFailedCrashTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try CrashReportCoordinator.beginSession(
        directory: root,
        appVersion: "0.1.0",
        buildVersion: "1"
    )
    let session = try CrashReportCoordinator.beginSession(
        directory: root,
        appVersion: "0.1.0",
        buildVersion: "1"
    )
    let result = await CrashReportCoordinator.deliverPendingReport(
        session: session,
        configuration: CrashReportConfiguration(
            isEnabled: true,
            recipient: "owner@example.com"
        ),
        sender: CrashReportTestSender(shouldFail: true)
    )
    guard case .failed = result else {
        Issue.record("Ein simuliertes Apple-Mail-Problem muss als Fehler erscheinen.")
        return
    }
    #expect(CrashReportCoordinator.hasPendingReport(session: session))
}

private actor CrashReportTestSender: CrashReportSending {
    private let shouldFail: Bool
    private(set) var recipients: [String] = []
    private(set) var reports: [String] = []

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    var sentCount: Int { recipients.count }
    var lastRecipient: String? { recipients.last }
    var lastReport: String { reports.last ?? "" }

    func sendCrashReport(
        recipient: String,
        subject: String,
        reportFile: URL
    ) async throws {
        if shouldFail {
            throw FindoraError.processFailed(
                "Synthetischer Apple-Mail-Fehler"
            )
        }
        recipients.append(recipient)
        reports.append(
            try String(contentsOf: reportFile, encoding: .utf8)
        )
    }
}
