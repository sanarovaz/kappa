import Foundation
import AppKit

struct MailMessage: Equatable {
    let id: String
    let account: String
    let sender: String      // "Nombre <mail>" tal cual
    let subject: String
    let date: Date
    var link: URL? = nil

    /// Solo el nombre (sin la dirección).
    var senderName: String {
        var s = sender
        if let r = s.range(of: "<") { s = String(s[..<r.lowerBound]) }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        return s.isEmpty ? sender : s
    }
}

/// Consulta Mail.app por AppleScript (fuera del hilo principal). Mail tiene que estar abierto.
enum MailMonitor {
    static var isMailRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").isEmpty
    }

    /// Si Mail está cerrado y se permite, lo abre en segundo plano (sin ventana ni foco).
    static func ensureRunning(launch: Bool) async -> Bool {
        if isMailRunning { return true }
        guard launch, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.mail") else { return false }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        cfg.hides = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: cfg)
        for _ in 0..<10 {
            if isMailRunning { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        try? await Task.sleep(nanoseconds: 3_000_000_000)   // que cargue las cuentas
        return isMailRunning
    }

    /// Nombres de las cuentas configuradas en Mail.
    static func accounts() async -> [String] {
        guard isMailRunning else { return [] }
        let script = """
        tell application "Mail" to set n to name of every account
        set AppleScript's text item delimiters to linefeed
        return n as text
        """
        let out = await Task.detached { run(script) }.value
        return (out ?? "").components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    /// Mails sin leer recibidos hoy en la bandeja de entrada de cada cuenta no excluida.
    /// nil = Mail cerrado o falló la consulta.
    static func unreadToday(excluded: [String], launchIfNeeded: Bool = false) async -> [MailMessage]? {
        guard await ensureRunning(launch: launchIfNeeded) else { return nil }
        let list = excluded
            .map { "\"" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
            .joined(separator: ", ")
        let script = """
        set excluded to {\(list)}
        set startOfToday to current date
        set time of startOfToday to 0
        set out to {}
        tell application "Mail"
            repeat with acc in accounts
                set accName to name of acc
                if accName is not in excluded then
                    try
                        set msgs to (messages of mailbox "INBOX" of acc whose read status is false and date received is greater than or equal to startOfToday)
                        repeat with m in msgs
                            set d to date received of m
                            set mo to (month of d) as integer
                            set ts to (year of d as string) & "-" & text -2 thru -1 of ("0" & mo) & "-" & text -2 thru -1 of ("0" & (day of d)) & " " & text -2 thru -1 of ("0" & (hours of d)) & ":" & text -2 thru -1 of ("0" & (minutes of d)) & ":" & text -2 thru -1 of ("0" & (seconds of d))
                            set end of out to accName & "||" & (message id of m) & "||" & (sender of m) & "||" & (subject of m) & "||" & ts
                        end repeat
                    end try
                end if
            end repeat
        end tell
        set AppleScript's text item delimiters to linefeed
        return out as text
        """
        guard let output = await Task.detached(operation: { run(script) }).value else { return nil }

        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var result: [MailMessage] = []
        for line in output.components(separatedBy: "\n") where !line.isEmpty {
            let p = line.components(separatedBy: "||")
            guard p.count >= 5, let date = fmt.date(from: p[4]) else { continue }
            result.append(MailMessage(id: p[1], account: p[0], sender: p[2], subject: p[3], date: date))
        }
        return result.sorted { $0.date < $1.date }
    }

    private static func run(_ script: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }

        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 25, execute: killer)

        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()

        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
