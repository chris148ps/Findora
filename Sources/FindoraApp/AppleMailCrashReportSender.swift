import AppKit
import Foundation
import FindoraCore

struct AppleMailCrashReportSender: CrashReportSending {
    func sendCrashReport(
        recipient: String,
        subject: String,
        reportFile: URL
    ) async throws {
        try await MainActor.run {
            let script = """
            tell application id "com.apple.mail"
                set crashMessage to make new outgoing message with properties {visible:false, subject:"\(escape(subject))", content:"Automatisch erzeugter, lokal bereinigter Findora-Crashbericht."}
                tell crashMessage
                    make new to recipient at end of to recipients with properties {address:"\(escape(recipient))"}
                    make new attachment with properties {file name:(POSIX file "\(escape(reportFile.path))")} at after the last paragraph
                    send
                end tell
            end tell
            """
            var errorInfo: NSDictionary?
            guard let appleScript = NSAppleScript(source: script) else {
                throw FindoraError.processFailed(
                    "Apple-Mail-Automation konnte nicht vorbereitet werden."
                )
            }
            _ = appleScript.executeAndReturnError(&errorInfo)
            if let errorInfo {
                let message = errorInfo["NSAppleScriptErrorMessage"] as? String
                    ?? "Apple Mail konnte den Crashbericht nicht senden."
                throw FindoraError.processFailed(message)
            }
        }
    }

    private func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
