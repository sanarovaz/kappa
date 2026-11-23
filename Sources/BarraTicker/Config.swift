import SwiftUI
import AppKit

// MARK: - Categorías

enum TickerCategory: String, Codable, CaseIterable, Identifiable {
    case calendario, cambio, papers, plazo, noticias, mail

    var id: String { rawValue }

    var emoji: String {
        switch self {
        case .calendario: return "📅"
        case .cambio: return "💵"
        case .papers: return "📚"
        case .plazo: return "⏳"
        case .noticias: return "📰"
        case .mail: return "✉️"
        }
    }

    var name: String {
        switch self {
        case .calendario: return "Agenda"
        case .cambio: return "Cambio"
        case .papers: return "Papers"
        case .plazo: return "Plazos"
        case .noticias: return "Noticias"
        case .mail: return "Mail"
        }
    }

    var defaultHex: String {
        switch self {
        case .calendario: return "#3B82F6"
        case .cambio: return "#10B981"
        case .papers: return "#8B5CF6"
        case .plazo: return "#EF4444"
        case .noticias: return "#F59E0B"
        case .mail: return "#06B6D4"
        }
    }
}

enum PillTheme: String, Codable, CaseIterable, Identifiable {
    case glassDark, glassLight, black, white

    var id: String { rawValue }

    var title: String {
        switch self {
        case .glassDark: return "Cristal oscuro"
        case .glassLight: return "Cristal claro"
        case .black: return "Negro"
        case .white: return "Blanco"
        }
    }

    var isDark: Bool { self == .glassDark || self == .black }
}

enum TickerStyle: String, Codable, CaseIterable, Identifiable {
    case scroll, splitFlap
    var id: String { rawValue }
    var title: String { self == .scroll ? "Scroll continuo" : "Cartelera" }
}

enum DisplayMode: String, Codable, CaseIterable {
    case centered      // panel flotante centrado
    case statusItem    // ítem de barra, a la derecha
}

// MARK: - Datos editables

struct Countdown: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String = "Nuevo plazo"
    var date: Date = Date().addingTimeInterval(7 * 86_400)
    var url: String = ""
}

struct Feed: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String = "Feed"
    var url: String = ""
    var maxItems: Int = 3
}

struct Config: Codable, Equatable {
    // General
    var speed: Double = 40            // puntos por segundo
    var refreshMinutes: Int = 10
    var width: Double = 360           // ancho deseado del ticker
    var fps: Int = 30
    var hideOthers = false
    var launchAtLogin = false

    // Ubicación
    var displayMode: DisplayMode = .centered
    var showOnExternal = true
    var showOnNotchScreens = true
    var avoidMenus = true             // medir los menús de la app (Accesibilidad)
    var theme: PillTheme = .glassDark
    var style: TickerStyle = .scroll
    var flapSeconds: Double = 4       // segundos por página en la cartelera
    var notchWidth: Double = 220      // ancho cuando no hay monitor externo (a la derecha del notch)

    // Fuentes
    var showCalendar = true
    var calendarDays = 7
    var excludedCalendarIDs: [String] = []
    var showFX = true
    var fxKinds: [String] = ["oficial", "blue", "bolsa"]
    var showJevons = true
    var jevonsPath = "~/Jevons/ultimo-paper.json"
    var showCountdowns = true
    var showFeeds = true
    var showMail = false
    var mailShowDetail = false
    var mailExcludedAccounts: [String] = []   // cuentas de Mail que NO generan notificaciones
    var gmailAccounts: [String] = []          // cuentas Gmail conectadas por IMAP (contraseña en el Llavero)
    var googleClientID = ""                  // ID de cliente OAuth (tipo "aplicación de escritorio")
    var mailLaunchHidden = true               // abrir Mail en segundo plano si está cerrado
    var mailUseMailApp = true                 // leer también de Mail.app si está abierto
    var mailSummaryMinutes = 30               // cada cuántos minutos el resumen de no leídos de hoy

    // Listas
    var countdowns: [Countdown] = []
    var feeds: [Feed] = []

    // Colores por categoría (hex)
    var colors: [String: String] = [:]

    enum CodingKeys: String, CodingKey {
        case speed, refreshMinutes, width, fps, hideOthers, launchAtLogin
        case displayMode, showOnExternal, showOnNotchScreens, avoidMenus, theme, notchWidth, style, flapSeconds
        case showCalendar, calendarDays, excludedCalendarIDs
        case showFX, fxKinds, showJevons, jevonsPath
        case showCountdowns, showFeeds, showMail, mailShowDetail, mailExcludedAccounts, mailSummaryMinutes, gmailAccounts, mailUseMailApp, googleClientID, mailLaunchHidden
        case countdowns, feeds, colors
    }
}

// Decodificación tolerante: los ajustes guardados por versiones anteriores
// (sin las claves nuevas) se conservan en vez de resetearse.
extension Config {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? speed
        refreshMinutes = try c.decodeIfPresent(Int.self, forKey: .refreshMinutes) ?? refreshMinutes
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? width
        fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? fps
        hideOthers = try c.decodeIfPresent(Bool.self, forKey: .hideOthers) ?? hideOthers
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? launchAtLogin
        displayMode = try c.decodeIfPresent(DisplayMode.self, forKey: .displayMode) ?? displayMode
        showOnExternal = try c.decodeIfPresent(Bool.self, forKey: .showOnExternal) ?? showOnExternal
        showOnNotchScreens = try c.decodeIfPresent(Bool.self, forKey: .showOnNotchScreens) ?? showOnNotchScreens
        avoidMenus = try c.decodeIfPresent(Bool.self, forKey: .avoidMenus) ?? avoidMenus
        theme = try c.decodeIfPresent(PillTheme.self, forKey: .theme) ?? theme
        style = try c.decodeIfPresent(TickerStyle.self, forKey: .style) ?? style
        flapSeconds = try c.decodeIfPresent(Double.self, forKey: .flapSeconds) ?? flapSeconds
        notchWidth = try c.decodeIfPresent(Double.self, forKey: .notchWidth) ?? notchWidth
        showCalendar = try c.decodeIfPresent(Bool.self, forKey: .showCalendar) ?? showCalendar
        calendarDays = try c.decodeIfPresent(Int.self, forKey: .calendarDays) ?? calendarDays
        excludedCalendarIDs = try c.decodeIfPresent([String].self, forKey: .excludedCalendarIDs) ?? excludedCalendarIDs
        showFX = try c.decodeIfPresent(Bool.self, forKey: .showFX) ?? showFX
        fxKinds = try c.decodeIfPresent([String].self, forKey: .fxKinds) ?? fxKinds
        showJevons = try c.decodeIfPresent(Bool.self, forKey: .showJevons) ?? showJevons
        jevonsPath = try c.decodeIfPresent(String.self, forKey: .jevonsPath) ?? jevonsPath
        showCountdowns = try c.decodeIfPresent(Bool.self, forKey: .showCountdowns) ?? showCountdowns
        showFeeds = try c.decodeIfPresent(Bool.self, forKey: .showFeeds) ?? showFeeds
        showMail = try c.decodeIfPresent(Bool.self, forKey: .showMail) ?? showMail
        mailShowDetail = try c.decodeIfPresent(Bool.self, forKey: .mailShowDetail) ?? mailShowDetail
        mailExcludedAccounts = try c.decodeIfPresent([String].self, forKey: .mailExcludedAccounts) ?? mailExcludedAccounts
        mailSummaryMinutes = try c.decodeIfPresent(Int.self, forKey: .mailSummaryMinutes) ?? mailSummaryMinutes
        gmailAccounts = try c.decodeIfPresent([String].self, forKey: .gmailAccounts) ?? gmailAccounts
        mailUseMailApp = try c.decodeIfPresent(Bool.self, forKey: .mailUseMailApp) ?? mailUseMailApp
        googleClientID = try c.decodeIfPresent(String.self, forKey: .googleClientID) ?? googleClientID
        mailLaunchHidden = try c.decodeIfPresent(Bool.self, forKey: .mailLaunchHidden) ?? mailLaunchHidden
        countdowns = try c.decodeIfPresent([Countdown].self, forKey: .countdowns) ?? countdowns
        feeds = try c.decodeIfPresent([Feed].self, forKey: .feeds) ?? feeds
        colors = try c.decodeIfPresent([String: String].self, forKey: .colors) ?? colors
    }
}

// MARK: - Settings (persistencia en UserDefaults)

@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()
    private let key = "BarraTicker.config.v1"

    @Published var config: Config {
        didSet { save() }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: "BarraTicker.config.v1"),
           let decoded = try? JSONDecoder().decode(Config.self, from: data) {
            config = decoded
        } else {
            config = Config()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func color(for category: TickerCategory) -> Color {
        Color(hex: config.colors[category.rawValue] ?? category.defaultHex)
    }

    func setColor(_ color: Color, for category: TickerCategory) {
        config.colors[category.rawValue] = color.hexString
    }

    func resetColors() {
        config.colors = [:]
    }
}

/// Estado de UI compartido (no se persiste).
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    /// true mientras el divisor está visible para organizar íconos.
    @Published var organizing = false
}

// MARK: - Color <-> hex

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        if s.count != 6 { s = "888888" }
        let v = UInt64(s, radix: 16) ?? 0x888888
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255,
                  opacity: 1)
    }

    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor.gray
        return String(format: "#%02X%02X%02X",
                      Int((ns.redComponent * 255).rounded()),
                      Int((ns.greenComponent * 255).rounded()),
                      Int((ns.blueComponent * 255).rounded()))
    }
}
