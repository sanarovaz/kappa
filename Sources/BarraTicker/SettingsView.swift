import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - Páginas

private enum SettingsPage: String, CaseIterable, Identifiable {
    case general, appearance
    case agenda, deadlines, exchange, papers, news, mail
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Apariencia"
        case .agenda: return "Agenda"
        case .deadlines: return "Plazos"
        case .exchange: return "Cambio"
        case .papers: return "Papers"
        case .news: return "Noticias"
        case .mail: return "Mail"
        case .advanced: return "Avanzado"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .agenda: return "calendar"
        case .deadlines: return "hourglass"
        case .exchange: return "banknote"
        case .papers: return "books.vertical"
        case .news: return "newspaper"
        case .mail: return "envelope"
        case .advanced: return "wrench.and.screwdriver"
        }
    }
}

// MARK: - Ventana de Ajustes

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject private var appState = AppState.shared
    let store: TickerStore

    @State private var page: SettingsPage? = .general
    @State private var calendars: [CalendarInfo] = []
    @State private var mailAccounts: [String] = []
    @State private var googleSecret = ""
    @State private var gmailStatus = ""
    @State private var gmailBusy = false
    @State private var confirmReset = false

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                row(.general)
                row(.appearance)
                Section("Contenido") {
                    row(.agenda)
                    row(.deadlines)
                    row(.exchange)
                    row(.papers)
                    row(.news)
                    row(.mail)
                }
                Section("Sistema") {
                    row(.advanced)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(190)
        } detail: {
            detail(page ?? .general)
                .navigationTitle((page ?? .general).title)
        }
        .toolbar(removing: .sidebarToggle)
        .frame(width: 780, height: 560)
    }

    private func row(_ p: SettingsPage) -> some View {
        Label(p.title, systemImage: p.symbol).tag(p)
    }

    @ViewBuilder
    private func detail(_ p: SettingsPage) -> some View {
        switch p {
        case .general: generalPage
        case .appearance: appearancePage
        case .agenda: agendaPage
        case .deadlines: deadlinesPage
        case .exchange: exchangePage
        case .papers: papersPage
        case .news: newsPage
        case .mail: mailPage
        case .advanced: advancedPage
        }
    }

    // MARK: Piezas reutilizables

    /// Interruptor principal de cada fuente de contenido.
    private func sourceToggle(_ title: String, _ binding: Binding<Bool>, footer: String) -> some View {
        Section {
            Toggle(title, isOn: binding)
        } footer: {
            Text(footer)
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                           step: Double, unit: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: value, in: range, step: step).frame(width: 190)
                Text("\(Int(value.wrappedValue)) \(unit)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)
            }
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    // MARK: General

    private var generalPage: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Kappa").font(.title2.bold())
                        Text("Agenda, plazos, cambio, papers, noticias y mails en tu barra de menús.")
                            .foregroundStyle(.secondary)
                        Text("Versión \(appVersion)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                Picker("Ubicación", selection: $settings.config.displayMode) {
                    Text("Flotante sobre la barra").tag(DisplayMode.centered)
                    Text("Ítem de la barra, a la derecha").tag(DisplayMode.statusItem)
                }
                if settings.config.displayMode == .centered {
                    sliderRow("Ancho en monitor externo", value: $settings.config.width,
                              range: 200...900, step: 10, unit: "pt")
                    sliderRow("Ancho junto al notch", value: $settings.config.notchWidth,
                              range: 120...500, step: 10, unit: "pt")
                } else {
                    sliderRow("Ancho", value: $settings.config.width, range: 150...600, step: 10, unit: "pt")
                }
            } header: {
                Text("Pantalla")
            } footer: {
                if settings.config.displayMode == .centered {
                    Text("Con un monitor externo conectado, Kappa aparece solo ahí, centrado. "
                         + "Sin monitor, aparece a la derecha del notch.")
                }
            }

            Section("Actualización") {
                Stepper("Actualizar cada \(settings.config.refreshMinutes) min",
                        value: $settings.config.refreshMinutes, in: 1...120)
                LabeledContent("Ahora") {
                    Button("Actualizar") { store.refreshAll() }
                }
            }

            Section("Inicio") {
                Toggle("Abrir Kappa al iniciar sesión", isOn: $settings.config.launchAtLogin)
                    .onChange(of: settings.config.launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            NSLog("Kappa: no se pudo cambiar el inicio de sesión: \(error)")
                        }
                    }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Apariencia

    private var appearancePage: some View {
        Form {
            Section {
                Picker("Estilo", selection: $settings.config.style) {
                    ForEach(TickerStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                if settings.config.style == .scroll {
                    sliderRow("Velocidad", value: $settings.config.speed, range: 10...200, step: 5, unit: "pt/s")
                } else {
                    Stepper("Cada página dura \(Int(settings.config.flapSeconds)) s",
                            value: $settings.config.flapSeconds, in: 2...15)
                }
            } header: {
                Text("Estilo")
            } footer: {
                Text(settings.config.style == .scroll
                     ? "El texto se desplaza de forma continua, de derecha a izquierda."
                     : "Muestra un ítem por vez en un tablero de letras que giran, como en una estación de tren.")
            }

            Section("Fondo") {
                HStack(spacing: 14) {
                    ForEach(PillTheme.allCases) { theme in
                        Button { settings.config.theme = theme } label: {
                            ThemeSwatch(theme: theme, selected: settings.config.theme == theme)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }

            Section("Cómo se usa") {
                Label("Pasá el mouse por encima para pausar.", systemImage: "cursorarrow")
                Label("La rueda del mouse o el trackpad lo mueven.", systemImage: "arrow.left.and.right")
                Label("Un clic abre un globo con el detalle; otro clic abre el link.", systemImage: "hand.tap")
                Label("Clic derecho: actualizar, ajustes y salir.", systemImage: "contextualmenu.and.cursorarrow")
            }
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    // MARK: Agenda

    private var calendarGroups: [(key: String, value: [CalendarInfo])] {
        Dictionary(grouping: calendars, by: \.account).sorted { $0.key < $1.key }
    }

    private func calendarBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !settings.config.excludedCalendarIDs.contains(id) },
            set: { on in
                var excluded = settings.config.excludedCalendarIDs
                if on { excluded.removeAll { $0 == id } }
                else if !excluded.contains(id) { excluded.append(id) }
                settings.config.excludedCalendarIDs = excluded
            }
        )
    }

    private var agendaPage: some View {
        Form {
            sourceToggle("Mostrar próximos eventos", $settings.config.showCalendar,
                         footer: "Los eventos de hoy muestran cuánto falta; los de otros días, el día y la hora. "
                                 + "Si un evento tiene link (Meet, Zoom…), el segundo clic lo abre.")

            Section("Período") {
                Stepper("Mirar \(settings.config.calendarDays) días hacia adelante",
                        value: $settings.config.calendarDays, in: 1...60)
            }
            .disabled(!settings.config.showCalendar)

            if calendars.isEmpty {
                Section("Calendarios") {
                    Text("No hay calendarios disponibles. Dale permiso a Kappa en Ajustes del Sistema → "
                         + "Privacidad y seguridad → Calendarios.")
                        .foregroundStyle(.secondary)
                    Button("Abrir Ajustes del Sistema") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                    }
                    Button("Volver a buscar") { Task { calendars = await CalendarSource.shared.catalog() } }
                }
                .disabled(!settings.config.showCalendar)
            } else {
                ForEach(calendarGroups, id: \.key) { group in
                    Section(group.key) {
                        ForEach(group.value) { cal in
                            Toggle(isOn: calendarBinding(cal.id)) {
                                HStack(spacing: 8) {
                                    Circle().fill(cal.color).frame(width: 10, height: 10)
                                    Text(cal.title)
                                }
                            }
                        }
                    }
                    .disabled(!settings.config.showCalendar)
                }
            }
        }
        .formStyle(.grouped)
        .task { calendars = await CalendarSource.shared.catalog() }
    }

    // MARK: Plazos

    private var deadlinesPage: some View {
        Form {
            sourceToggle("Mostrar plazos", $settings.config.showCountdowns,
                         footer: "Fechas límite propias, con cuenta regresiva. Los plazos vencidos dejan de mostrarse.")

            Section("Tus plazos") {
                if settings.config.countdowns.isEmpty {
                    Text("Todavía no agregaste ninguno.").foregroundStyle(.secondary)
                }
                ForEach($settings.config.countdowns) { $c in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("Título", text: $c.title)
                            Button(role: .destructive) {
                                settings.config.countdowns.removeAll { $0.id == c.id }
                            } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .help("Eliminar")
                        }
                        HStack {
                            DatePicker("Vence", selection: $c.date, displayedComponents: [.date, .hourAndMinute])
                            TextField("Link (opcional)", text: $c.url)
                        }
                    }
                    .padding(.vertical, 2)
                }
                Button { settings.config.countdowns.append(Countdown()) } label: {
                    Label("Agregar plazo", systemImage: "plus")
                }
            }
            .disabled(!settings.config.showCountdowns)
        }
        .formStyle(.grouped)
    }

    // MARK: Cambio

    private var exchangePage: some View {
        Form {
            sourceToggle("Mostrar cotizaciones", $settings.config.showFX,
                         footer: "Cotización del dólar en Argentina (venta), con flecha cuando sube o baja. "
                                 + "Datos de DolarApi.")

            Section("Cotizaciones") {
                ForEach(fxOptions, id: \.0) { key, name in
                    Toggle(name, isOn: fxBinding(key))
                }
            }
            .disabled(!settings.config.showFX)
        }
        .formStyle(.grouped)
    }

    private var fxOptions: [(String, String)] {
        [("oficial", "Oficial"), ("blue", "Blue"), ("bolsa", "MEP"),
         ("contadoconliqui", "CCL"), ("mayorista", "Mayorista")]
    }

    private func fxBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { settings.config.fxKinds.contains(key) },
            set: { on in
                var kinds = settings.config.fxKinds
                if on, !kinds.contains(key) { kinds.append(key) }
                if !on { kinds.removeAll { $0 == key } }
                let order = fxOptions.map(\.0)
                kinds.sort { (order.firstIndex(of: $0) ?? 99) < (order.firstIndex(of: $1) ?? 99) }
                settings.config.fxKinds = kinds
            }
        )
    }

    // MARK: Papers

    private var papersPage: some View {
        Form {
            sourceToggle("Mostrar papers recientes", $settings.config.showJevons,
                         footer: "Muestra los dos últimos papers que abriste en Jevons, como “Leer: Título”. "
                                 + "El segundo clic abre el paper en Jevons.")

            Section("Archivo de Jevons") {
                LabeledContent("Ubicación") {
                    HStack {
                        Text(settings.config.jevonsPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Elegir…") { chooseJevonsFile() }
                    }
                }
            }
            .disabled(!settings.config.showJevons)
        }
        .formStyle(.grouped)
    }

    private func chooseJevonsFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: (settings.config.jevonsPath as NSString).deletingLastPathComponent
            .replacingOccurrences(of: "~", with: NSHomeDirectory()))
        if panel.runModal() == .OK, let url = panel.url {
            settings.config.jevonsPath = url.path
        }
    }

    // MARK: Noticias

    private var newsPage: some View {
        Form {
            sourceToggle("Mostrar noticias", $settings.config.showFeeds,
                         footer: "Titulares de los sitios que agregues (cualquier feed RSS o Atom). "
                                 + "Al hacer clic se ve el titular completo y el ícono del medio.")

            Section("Fuentes") {
                if settings.config.feeds.isEmpty {
                    Text("Todavía no agregaste ninguna. Pegá la dirección del feed RSS de un diario o blog.")
                        .foregroundStyle(.secondary)
                }
                ForEach($settings.config.feeds) { $f in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("Nombre", text: $f.name)
                            Button(role: .destructive) {
                                settings.config.feeds.removeAll { $0.id == f.id }
                            } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .help("Eliminar")
                        }
                        TextField("Dirección del feed (https://…)", text: $f.url)
                        Stepper("Titulares por vez: \(f.maxItems)", value: $f.maxItems, in: 1...10)
                    }
                    .padding(.vertical, 2)
                }
                Button { settings.config.feeds.append(Feed()) } label: {
                    Label("Agregar fuente", systemImage: "plus")
                }
            }
            .disabled(!settings.config.showFeeds)
        }
        .formStyle(.grouped)
    }

    // MARK: Mail

    private var mailPage: some View {
        Form {
            sourceToggle("Mostrar avisos de mail", $settings.config.showMail,
                         footer: "Cada mail nuevo se avisa una sola vez, con 🟢 y el remitente. "
                                 + "Cada tanto aparece un resumen de los no leídos de hoy. "
                                 + "Kappa lee tus mails a través de la app Mail.")

            Section {
                if mailAccounts.isEmpty {
                    Text("No encontré cuentas en Mail.").foregroundStyle(.secondary)
                }
                ForEach(mailAccounts, id: \.self) { name in
                    Toggle(name, isOn: Binding(
                        get: { !settings.config.mailExcludedAccounts.contains(name) },
                        set: { on in
                            var ex = settings.config.mailExcludedAccounts
                            ex.removeAll { $0 == name }
                            if !on { ex.append(name) }
                            settings.config.mailExcludedAccounts = ex
                        }
                    ))
                }
                HStack {
                    Button("Buscar cuentas") { Task { mailAccounts = await MailMonitor.accounts() } }
                    Button("Agregar una cuenta…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")!)
                    }
                }
            } header: {
                Text("Cuentas")
            } footer: {
                Text("Para agregar una cuenta (Gmail, la de tu universidad, etc.), sumala en Ajustes del Sistema → "
                     + "Cuentas de Internet con Mail activado. Después apretá “Buscar cuentas”.")
            }
            .disabled(!settings.config.showMail)

            Section {
                Stepper("Resumen cada \(settings.config.mailSummaryMinutes) min",
                        value: $settings.config.mailSummaryMinutes, in: 5...240, step: 5)
                Toggle("Abrir Mail en segundo plano si está cerrado", isOn: $settings.config.mailLaunchHidden)
            } header: {
                Text("Avisos")
            } footer: {
                Text("La primera vez, macOS te pide permiso para que Kappa controle Mail.")
            }
            .disabled(!settings.config.showMail)
        }
        .formStyle(.grouped)
        .task { mailAccounts = await MailMonitor.accounts() }
    }

    // MARK: Avanzado

    private var advancedPage: some View {
        Form {
            Section {
                Toggle("Ocultar íconos de otras apps", isOn: $settings.config.hideOthers)
                if settings.config.hideOthers {
                    LabeledContent(appState.organizing ? "Organizando" : "Divisor") {
                        Button(appState.organizing ? "Listo, ocultar" : "Organizar íconos") {
                            appState.organizing.toggle()
                        }
                    }
                }
            } header: {
                Text("Íconos de la barra de menús")
            } footer: {
                Text(appState.organizing && settings.config.hideOthers
                     ? "Arrastrá con ⌘ los íconos que querés ocultar a la izquierda del divisor “┃”, y dejá a su derecha los que querés ver."
                     : "Los íconos que queden a la izquierda del divisor “┃” se ocultan. También podés controlarlo en Ajustes del Sistema → Barra de menús.")
            }

            Section {
                Toggle("Evitar los menús de la app activa", isOn: $settings.config.avoidMenus)
                    .onChange(of: settings.config.avoidMenus) { _, on in
                        if on { PanelController.requestAccessibility() }
                    }
                Picker("Fluidez de la animación", selection: $settings.config.fps) {
                    Text("Normal").tag(30)
                    Text("Alta").tag(60)
                }
            } header: {
                Text("Pantalla")
            } footer: {
                Text("Evitar los menús necesita el permiso de Accesibilidad. Kappa se corre para no tapar los menús de la app que estés usando.")
            }

            Section {
                DisclosureGroup("Conexión directa con Google") {
                    googleSection
                }
            } header: {
                Text("Opcional")
            } footer: {
                Text("Solo si querés leer Gmail sin la app Mail. Hace falta crear credenciales en Google Cloud; "
                     + "para la mayoría de los casos alcanza con la página Mail.")
            }

            Section("Mantenimiento") {
                Button("Mostrar archivo de registro") {
                    NSWorkspace.shared.activateFileViewerSelecting([DebugLog.url])
                }
                Button("Restablecer todos los ajustes…", role: .destructive) { confirmReset = true }
            }
        }
        .formStyle(.grouped)
        .task { googleSecret = SecretStore.get(GoogleAuth.clientSecretKey) ?? "" }
        .confirmationDialog("¿Restablecer todos los ajustes?", isPresented: $confirmReset) {
            Button("Restablecer", role: .destructive) { settings.config = Config() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Vuelven los valores originales. Tus cuentas, calendarios y mails no se tocan.")
        }
    }

    @ViewBuilder
    private var googleSection: some View {
        ForEach(settings.config.gmailAccounts, id: \.self) { email in
            LabeledContent(email) {
                Button("Quitar") {
                    GoogleAuth.forget(email)
                    settings.config.gmailAccounts.removeAll { $0 == email }
                }
            }
        }
        TextField("Client ID", text: $settings.config.googleClientID)
        SecureField("Client secret", text: $googleSecret)
            .onChange(of: googleSecret) { _, v in
                SecretStore.set(v.trimmingCharacters(in: .whitespacesAndNewlines), for: GoogleAuth.clientSecretKey)
            }
        Button(gmailBusy ? "Esperando al navegador…" : "Agregar cuenta de Google") { connectGmail() }
            .disabled(gmailBusy || settings.config.googleClientID.isEmpty || googleSecret.isEmpty)
        if !gmailStatus.isEmpty {
            Text(gmailStatus).font(.caption)
        }
        Link("Abrir Google Cloud Console", destination: URL(string: "https://console.cloud.google.com/apis/credentials")!)
            .font(.caption)
    }

    private func connectGmail() {
        let clientID = settings.config.googleClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = googleSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        gmailBusy = true
        gmailStatus = "Se abrió el navegador: elegí la cuenta y aceptá el permiso de lectura."
        Task {
            do {
                let email = try await GoogleAuth.signIn(clientID: clientID, clientSecret: secret)
                if !settings.config.gmailAccounts.contains(email) { settings.config.gmailAccounts.append(email) }
                gmailStatus = "Conectado: \(email)"
                store.refreshAll()
            } catch {
                gmailStatus = "No se pudo conectar: \(error.localizedDescription)"
            }
            gmailBusy = false
        }
    }
}

// MARK: - Muestra de fondo

private struct ThemeSwatch: View {
    let theme: PillTheme
    let selected: Bool

    private var fill: AnyShapeStyle {
        switch theme {
        case .glassDark:
            return AnyShapeStyle(LinearGradient(colors: [Color(white: 0.30), Color(white: 0.14)],
                                                startPoint: .top, endPoint: .bottom))
        case .glassLight:
            return AnyShapeStyle(LinearGradient(colors: [Color(white: 0.97), Color(white: 0.84)],
                                                startPoint: .top, endPoint: .bottom))
        case .black: return AnyShapeStyle(Color.black)
        case .white: return AnyShapeStyle(Color.white)
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 9)
                .fill(fill)
                .frame(width: 118, height: 42)
                .overlay(
                    Text("📅  Reunión · en 2 h")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.isDark ? Color.white : Color.black)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.35),
                                lineWidth: selected ? 3 : 1)
                )
            Text(theme.title)
                .font(.caption)
                .foregroundStyle(selected ? Color.primary : Color.secondary)
        }
    }
}
