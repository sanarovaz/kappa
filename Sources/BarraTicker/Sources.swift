import Foundation
import AppKit
import SwiftUI
import EventKit

// MARK: - Modelo

struct TickerItem: Identifiable, Equatable {
    let id: String
    let category: TickerCategory
    var text: String            // lo que se ve en el ticker
    var suffix: String = ""     // cola de `text` que nunca se corta (p. ej. " · en 2 h")
    var url: URL?
    var title: String = ""      // encabezado del detalle (si está vacío, se usa `text`)
    var detail: String = ""     // líneas del detalle
    var wrapTitle: Bool = false // el título del detalle puede ocupar varias líneas (titulares)
}

// MARK: - Formato de cuentas regresivas

/// > 24 h: "mañana" o "en N días". > 4 h: "en N h". ≤ 4 h: "en N h M m" / "en M m".
func remainingText(until target: Date, now: Date = Date()) -> String {
    let secs = target.timeIntervalSince(now)
    if secs <= 0 { return "ahora" }

    if secs > 24 * 3600 {
        let cal = Calendar.current
        let days = cal.dateComponents([.day],
                                      from: cal.startOfDay(for: now),
                                      to: cal.startOfDay(for: target)).day ?? 2
        return days <= 1 ? "mañana" : "en \(days) días"
    }

    let totalMinutes = Int(secs / 60)
    let h = totalMinutes / 60
    let m = totalMinutes % 60
    if secs > 4 * 3600 { return "en \(h) h" }
    if h == 0 { return "en \(max(m, 1)) m" }
    return "en \(h) h \(m) m"
}

/// Para eventos de todo el día: "hoy", "mañana", "en N días".
func allDayText(start: Date, now: Date = Date()) -> String {
    let cal = Calendar.current
    let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: start)).day ?? 0
    if days <= 0 { return "hoy" }
    return days == 1 ? "mañana" : "en \(days) días"
}

private func spanishFormatter(_ template: String) -> DateFormatter {
    let f = DateFormatter()
    f.locale = Locale(identifier: "es_AR")
    f.setLocalizedDateFormatFromTemplate(template)
    return f
}

// MARK: - Calendario (EventKit)

private let weekdayShort = ["Do", "Lu", "Ma", "Mi", "Ju", "Vi", "Sá"]

/// Hoy: cuenta regresiva ("en 2 h 15 m"). Otro día: "Lu 15.45" (o "Lu 30 15.45" si pasa de una semana).
private func eventWhen(_ e: EKEvent, now: Date) -> String {
    let cal = Calendar.current
    let start = e.startDate ?? now
    let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: start)).day ?? 0

    if e.isAllDay {
        if days <= 0 { return "hoy" }
        return weekdayLabel(start, days: days)
    }
    if start <= now { return "ahora" }
    if cal.isDateInToday(start) { return remainingText(until: start, now: now) }

    let c = cal.dateComponents([.hour, .minute], from: start)
    let time = "\(c.hour ?? 0).\(String(format: "%02d", c.minute ?? 0))"
    return weekdayLabel(start, days: days) + " " + time
}

private func weekdayLabel(_ date: Date, days: Int) -> String {
    let cal = Calendar.current
    let wd = weekdayShort[(cal.component(.weekday, from: date) - 1) % 7]
    return days >= 7 ? "\(wd) \(cal.component(.day, from: date))" : wd
}

/// Link asociado al evento: su URL, o el primer http(s) que aparezca en ubicación o notas
/// (Meet, Zoom, Teams…). Nunca devuelve un link al Calendario.
private func eventLink(_ e: EKEvent) -> URL? {
    func web(_ u: URL?) -> URL? {
        guard let u, let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return u
    }
    if let u = web(e.url) { return u }
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
    for text in [e.location, e.notes] {
        guard let text, !text.isEmpty else { continue }
        let range = NSRange(text.startIndex..., in: text)
        for m in detector.matches(in: text, options: [], range: range) {
            if let u = web(m.url) { return u }
        }
    }
    return nil
}

struct CalendarInfo: Identifiable, Equatable {
    let id: String
    let title: String
    let account: String
    let color: Color
}

final class CalendarSource {
    static let shared = CalendarSource()
    private let store = EKEventStore()

    /// Todos los calendarios de eventos, con su cuenta de origen.
    func catalog() async -> [CalendarInfo] {
        guard await ensureAccess() else { return [] }
        return store.calendars(for: .event)
            .map { cal in
                CalendarInfo(id: cal.calendarIdentifier,
                             title: cal.title,
                             account: cal.source.title,
                             color: Color(nsColor: NSColor(cgColor: cal.cgColor) ?? .gray))
            }
            .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
    }

    private func ensureAccess() async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .fullAccess { return true }
        if status == .notDetermined {
            return (try? await store.requestFullAccessToEvents()) ?? false
        }
        return false
    }

    func items(days: Int, excluded: [String]) async -> [TickerItem] {
        guard await ensureAccess() else { return [] }
        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: max(1, days), to: now)
            ?? now.addingTimeInterval(Double(days) * 86_400)
        let calendars = store.calendars(for: .event).filter { !excluded.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: calendars)
        let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }

        let dayFmt = spanishFormatter("EEEdMMM")
        let timeFmt = spanishFormatter("HHmm")

        return events.prefix(8).map { e in
            let title = e.title ?? "Evento"
            let when = eventWhen(e, now: now)
            let link = eventLink(e)

            var lines: [String] = []
            if e.isAllDay {
                lines.append("\(dayFmt.string(from: e.startDate)) · todo el día")
            } else {
                var l = "\(dayFmt.string(from: e.startDate)), \(timeFmt.string(from: e.startDate))"
                if Calendar.current.isDate(e.startDate, inSameDayAs: e.endDate) {
                    l += "–\(timeFmt.string(from: e.endDate))"
                }
                lines.append(l)
            }
            if let loc = e.location, !loc.isEmpty { lines.append("📍 \(loc)") }
            if let host = link?.host { lines.append("🔗 \(host)") }
            lines.append("Calendario: \(e.calendar.title)")

            let id = "cal-" + (e.eventIdentifier ?? UUID().uuidString)
            return TickerItem(id: id,
                              category: .calendario,
                              text: "\(title) · \(when)",
                              suffix: " · \(when)",
                              url: link,
                              title: title,
                              detail: lines.joined(separator: "\n"))
        }
    }
}

// MARK: - Cuentas regresivas manuales

enum CountdownSource {
    static func items(_ list: [Countdown]) -> [TickerItem] {
        let now = Date()
        let fmt = spanishFormatter("EEEdMMMyHHmm")
        return list
            .filter { $0.date > now }
            .sorted { $0.date < $1.date }
            .map { c in
                TickerItem(id: "cd-" + c.id.uuidString,
                           category: .plazo,
                           text: "\(c.title) · \(remainingText(until: c.date, now: now))",
                           suffix: " · \(remainingText(until: c.date, now: now))",
                           url: c.url.isEmpty ? nil : URL(string: c.url),
                           title: c.title,
                           detail: "Vence: \(fmt.string(from: c.date))")
            }
    }
}

// MARK: - Tipo de cambio (DolarApi)

private struct DolarQuote: Decodable {
    let casa: String
    let nombre: String?
    let compra: Double?
    let venta: Double?
}

final class FXSource {
    private var last: [String: Double] = [:]
    private var arrows: [String: String] = [:]

    private static let names: [String: String] = [
        "oficial": "Oficial", "blue": "Blue", "bolsa": "MEP",
        "contadoconliqui": "CCL", "mayorista": "Mayorista",
        "cripto": "Cripto", "tarjeta": "Tarjeta"
    ]

    /// nil = falló la red (se conservan los datos anteriores).
    func items(kinds: [String]) async -> [TickerItem]? {
        guard let url = URL(string: "https://dolarapi.com/v1/dolares") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let quotes = try JSONDecoder().decode([DolarQuote].self, from: data)

            let nf = NumberFormatter()
            nf.locale = Locale(identifier: "es_AR")
            nf.numberStyle = .decimal
            nf.maximumFractionDigits = 0
            func money(_ v: Double?) -> String {
                guard let v else { return "–" }
                return "$" + (nf.string(from: NSNumber(value: v)) ?? "\(v)")
            }

            var parts: [String] = []
            var lines: [String] = []
            for k in kinds {
                guard let q = quotes.first(where: { $0.casa == k }), let v = q.venta else { continue }
                if let prev = last[k], prev != v { arrows[k] = v > prev ? " ▲" : " ▼" }
                last[k] = v
                let name = Self.names[k] ?? (q.nombre ?? k)
                parts.append("\(name) \(money(v))\(arrows[k] ?? "")")
                lines.append("\(name): compra \(money(q.compra)) · venta \(money(v))")
            }
            guard !parts.isEmpty else { return [] }
            return [TickerItem(id: "fx",
                               category: .cambio,
                               text: parts.joined(separator: "  ·  "),
                               url: URL(string: "https://dolarhoy.com"),
                               title: "Tipo de cambio",
                               detail: lines.joined(separator: "\n"))]
        } catch {
            return nil
        }
    }
}

// MARK: - Último paper leído en Jevons (archivo JSON)
//
// Contrato: Jevons escribe un JSON con esta forma en `jevonsPath`:
// { "title": "…", "authors": "…", "url": "jevons://… o https://… o file://…" }

private struct JevonsPaper: Decodable {
    let title: String
    let authors: String?
    let url: String?
}

enum JevonsSource {
    /// Acepta un arreglo de papers (el más reciente primero) o un solo objeto. Usa los dos primeros.
    static func items(path: String) -> [TickerItem] {
        let full = (path as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: full) else { return [] }
        let decoder = JSONDecoder()
        var papers: [JevonsPaper] = []
        if let list = try? decoder.decode([JevonsPaper].self, from: data) {
            papers = list
        } else if let one = try? decoder.decode(JevonsPaper.self, from: data) {
            papers = [one]
        }
        return papers.prefix(2).enumerated().map { index, paper in
            var lines: [String] = []
            if let a = paper.authors, !a.isEmpty { lines.append(a) }
            lines.append(index == 0 ? "Último paper abierto en Jevons" : "Anteúltimo paper abierto en Jevons")
            return TickerItem(id: "jevons-\(index)-\(paper.title.hashValue)",
                              category: .papers,
                              text: "Leer: \(paper.title)",
                              url: paper.url.flatMap { URL(string: $0) },
                              title: paper.title,
                              detail: lines.joined(separator: "\n"))
        }
    }
}

// MARK: - RSS / Atom

private final class RSSParser: NSObject, XMLParserDelegate {
    struct Entry { var title: String; var link: String }

    private var entries: [Entry] = []
    private var inItem = false
    private var current = ""
    private var title = ""
    private var link = ""

    func parse(_ data: Data) -> [Entry] {
        let p = XMLParser(data: data)
        p.delegate = self
        p.parse()
        return entries
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "item" || elementName == "entry" {
            inItem = true
            title = ""
            link = ""
        }
        current = ""
        if inItem, elementName == "link", let href = attributeDict["href"], link.isEmpty {
            link = href
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        current += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        current += String(data: CDATABlock, encoding: .utf8) ?? ""
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        guard inItem else { return }
        let text = current.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "title":
            if title.isEmpty { title = text }
        case "link":
            if link.isEmpty { link = text }
        case "item", "entry":
            if !title.isEmpty { entries.append(Entry(title: title, link: link)) }
            inItem = false
        default:
            break
        }
    }
}

enum RSSSource {
    /// nil = falló la red o el parseo.
    static func items(feed: Feed) async -> [TickerItem]? {
        guard let url = URL(string: feed.url) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let entries = RSSParser().parse(data)
            return entries.prefix(max(1, feed.maxItems)).map { e in
                TickerItem(id: "feed-\(feed.id.uuidString)-\(e.link)-\(e.title.hashValue)",
                           category: .noticias,
                           text: "\(feed.name): \(e.title)",
                           url: URL(string: e.link),
                           title: e.title,
                           detail: feed.name,
                           wrapTitle: true)
            }
        } catch {
            return nil
        }
    }
}

// MARK: - Mail.app (vía osascript, fuera del hilo principal)

final class MailSource {
    private static let script = """
    tell application "Mail"
        set n to unread count of inbox
        if n is 0 then return "0"
        set m to first message of inbox whose read status is false
        return (n as string) & "||" & (sender of m) & "||" & (subject of m) & "||" & (message id of m)
    end tell
    """

    func item(showDetail: Bool) async -> TickerItem? {
        // No lanzamos Mail si no está abierto.
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").isEmpty else {
            return nil
        }
        let output = await Task.detached { MailSource.run() }.value
        guard let out = output, out != "0", !out.isEmpty else { return nil }

        let parts = out.components(separatedBy: "||")
        let count = parts.first ?? "?"
        var text = count == "1" ? "1 mail sin leer" : "\(count) mails sin leer"
        var url: URL? = nil
        var detailLines: [String] = []

        var sender = parts.count >= 2 ? parts[1] : ""
        if let r = sender.range(of: "<") { sender = String(sender[..<r.lowerBound]) }
        sender = sender.trimmingCharacters(in: .whitespaces)

        if parts.count >= 3 {
            detailLines.append("Último: \(sender)")
            detailLines.append(parts[2])
            if showDetail { text += " · \(sender): \(parts[2])" }
        }
        if parts.count >= 4, !parts[3].isEmpty {
            url = URL(string: "message://%3C\(parts[3])%3E")
        }
        return TickerItem(id: "mail", category: .mail, text: text, url: url,
                          title: text, detail: detailLines.joined(separator: "\n"))
    }

    private static func run() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }

        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: killer)

        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()

        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
