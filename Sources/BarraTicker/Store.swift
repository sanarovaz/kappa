import Foundation
import Combine

@MainActor
final class TickerStore: ObservableObject {
    /// Lo que muestra el scroll: ítems base + avisos de mail vigentes.
    @Published private(set) var items: [TickerItem] = []
    /// Solo los ítems base (la cartelera recibe los avisos aparte, en cola).
    @Published private(set) var baseItems: [TickerItem] = []

    private struct Alert { let item: TickerItem; let expires: Date }
    private var alerts: [Alert] = []
    private var flapQueue: [TickerItem] = []
    private let alertTTL: TimeInterval = 90

    private var mailTimer: Timer?
    private var alertTimer: Timer?
    private var lastSummary = Date()
    private var mailBusy = false
    private var seenIDs: [String] = UserDefaults.standard.stringArray(forKey: "BarraTicker.mailSeen") ?? []
    private var seenSet = Set<String>()

    private let settings = Settings.shared
    private let calendar = CalendarSource.shared
    private let fx = FXSource()

    private var parts: [String: [TickerItem]] = [:]
    private let order = ["calendar", "countdowns", "fx", "jevons", "feeds"]

    private var fullTimer: Timer?
    private var localTimer: Timer?
    private var cancellable: AnyCancellable?
    private var refreshTask: Task<Void, Never>?
    private var lastInterval = 0
    private var lastSignature = ""

    func start() {
        seenSet = Set(seenIDs)
        mailTimer = Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.pollMail() }
        }
        alertTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pruneAlerts() }
        }
        Task { await pollMail() }
        lastInterval = settings.config.refreshMinutes
        lastSignature = networkSignature(settings.config)
        reschedule()

        cancellable = settings.$config
            .dropFirst()
            .debounce(for: .seconds(0.8), scheduler: RunLoop.main)
            .sink { [weak self] cfg in
                Task { @MainActor in self?.configChanged(cfg) }
            }

        refreshAll()
    }

    /// Refresca todo (local + red).
    func refreshAll() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.loadLocal()
            await self.loadNetwork()
        }
    }

    // MARK: - Timers

    private func reschedule() {
        fullTimer?.invalidate()
        localTimer?.invalidate()

        let minutes = max(1, settings.config.refreshMinutes)
        fullTimer = Timer.scheduledTimer(withTimeInterval: Double(minutes) * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
        // Las cuentas regresivas se recalculan cada minuto (sin red).
        localTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.loadLocal()
            }
        }
    }

    private func configChanged(_ c: Config) {
        if c.refreshMinutes != lastInterval {
            lastInterval = c.refreshMinutes
            reschedule()
        }
        let sig = networkSignature(c)
        let needNetwork = sig != lastSignature
        lastSignature = sig

        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.loadLocal()
            if needNetwork { await self.loadNetwork() }
        }
    }

    private func networkSignature(_ c: Config) -> String {
        let feeds = c.feeds.map { "\($0.name)|\($0.url)|\($0.maxItems)" }.joined(separator: ";")
        return "\(c.showFX)|\(c.fxKinds)|\(c.showFeeds)|\(feeds)|\(c.showMail)|\(c.mailExcludedAccounts)|\(c.gmailAccounts)|\(c.googleClientID)|\(c.mailUseMailApp)"
    }

    // MARK: - Carga

    private func loadLocal() async {
        let c = settings.config
        parts["calendar"] = c.showCalendar
            ? await calendar.items(days: c.calendarDays, excluded: c.excludedCalendarIDs)
            : []
        parts["countdowns"] = c.showCountdowns ? CountdownSource.items(c.countdowns) : []
        parts["jevons"] = c.showJevons ? JevonsSource.items(path: c.jevonsPath) : []
        publish()
    }

    private func loadNetwork() async {
        let c = settings.config

        if c.showFX {
            if let r = await fx.items(kinds: c.fxKinds) { parts["fx"] = r }
        } else {
            parts["fx"] = []
        }
        if Task.isCancelled { return }

        if c.showFeeds {
            var all: [TickerItem] = []
            var anyOK = false
            for f in c.feeds where !f.url.isEmpty {
                if let r = await RSSSource.items(feed: f) {
                    all += r
                    anyOK = true
                }
            }
            if anyOK || c.feeds.isEmpty { parts["feeds"] = all }
        } else {
            parts["feeds"] = []
        }
        if Task.isCancelled { return }

        publish()
        await pollMail()
    }

    // MARK: - Avisos de mail

    /// Busca mails nuevos (aviso único por mail) y emite el resumen periódico.
    private func pollMail() async {
        let c = settings.config
        guard c.showMail, !mailBusy else { return }
        mailBusy = true
        defer { mailBusy = false }
        // Fuentes: Mail.app (si está abierto y habilitado) y cuentas Gmail por IMAP.
        var batches: [(key: String, msgs: [MailMessage])] = []
        if c.mailUseMailApp, let a = await MailMonitor.unreadToday(excluded: c.mailExcludedAccounts, launchIfNeeded: c.mailLaunchHidden) {
            batches.append(("mailapp", a))
        }
        for email in c.gmailAccounts {
            guard !c.googleClientID.isEmpty else { break }
            do {
                batches.append((email, try await GmailAPI.unreadToday(email: email, clientID: c.googleClientID)))
            } catch {
                DebugLog.write("gmail \(email): \(error.localizedDescription)")
            }
        }
        guard !batches.isEmpty else { return }

        // Cada fuente se "inicializa" la primera vez: lo que ya estaba sin leer no avisa.
        let primedKey = "BarraTicker.mailPrimedSources"
        var primed = Set(UserDefaults.standard.stringArray(forKey: primedKey) ?? [])
        if UserDefaults.standard.bool(forKey: "BarraTicker.mailPrimed") { primed.insert("mailapp") }

        var byID: [String: MailMessage] = [:]
        for b in batches {
            if !primed.contains(b.key) {
                for m in b.msgs { markSeen(m.id) }
                primed.insert(b.key)
                lastSummary = Date()
            }
            for m in b.msgs { byID[m.id] = m }       // Gmail pisa a Mail.app: su link anda sin Mail
        }
        UserDefaults.standard.set(Array(primed), forKey: primedKey)
        let unread = byID.values.sorted { $0.date < $1.date }

        for m in unread where !seenSet.contains(m.id) {
            markSeen(m.id)
            let item = TickerItem(id: "mailnew-" + m.id,
                                  category: .mail,
                                  text: "🟢 " + m.senderName,
                                  url: m.link ?? URL(string: "message://%3C\(m.id)%3E"),
                                  title: m.senderName,
                                  detail: "\(m.subject)\nCuenta: \(m.account)")
            push(item)
        }

        let minutes = max(1, c.mailSummaryMinutes)
        if Date().timeIntervalSince(lastSummary) >= Double(minutes) * 60 {
            lastSummary = Date()
            if !unread.isEmpty {
                var names: [String] = []
                for m in unread.reversed() where !names.contains(m.senderName) {
                    names.append(m.senderName)
                    if names.count == 2 { break }
                }
                let n = unread.count
                let text = "\(n) sin leer hoy (\(names.joined(separator: ", ")))"
                push(TickerItem(id: "mailsum-\(Int(Date().timeIntervalSince1970))",
                                category: .mail,
                                text: text,
                                url: URL(string: "message://"),
                                title: "\(n) mails sin leer hoy",
                                detail: unread.reversed().prefix(5)
                                    .map { "\($0.senderName): \($0.subject)" }.joined(separator: "\n")))
            }
        }
    }

    private func markSeen(_ id: String) {
        guard seenSet.insert(id).inserted else { return }
        seenIDs.append(id)
        if seenIDs.count > 500 {
            let drop = seenIDs.prefix(seenIDs.count - 500)
            for d in drop { seenSet.remove(d) }
            seenIDs.removeFirst(seenIDs.count - 500)
        }
        UserDefaults.standard.set(seenIDs, forKey: "BarraTicker.mailSeen")
    }

    private func push(_ item: TickerItem) {
        alerts.append(Alert(item: item, expires: Date().addingTimeInterval(alertTTL)))
        if settings.config.style == .splitFlap { flapQueue.append(item) }
        publish()
    }

    private func pruneAlerts() {
        let before = alerts.count
        alerts.removeAll { $0.expires < Date() }
        if alerts.count != before { publish() }
    }

    /// La cartelera pide el próximo aviso cuando termina de mostrar una página.
    func takeFlapAlert() -> TickerItem? {
        flapQueue.isEmpty ? nil : flapQueue.removeFirst()
    }

    /// Para resolver clics: busca entre ítems base, avisos y lo que haya mostrado la cartelera.
    func item(withID id: String) -> TickerItem? {
        baseItems.first { $0.id == id } ?? alerts.first { $0.item.id == id }?.item
    }

    private func publish() {
        let base = order.flatMap { parts[$0] ?? [] }
        let scrollAlerts = settings.config.style == .scroll ? alerts.map(\.item) : []
        let merged = base + scrollAlerts
        if base != baseItems { baseItems = base }
        if merged != items { items = merged }
    }
}
