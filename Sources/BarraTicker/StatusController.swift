import AppKit
import SwiftUI
import Combine

/// Divisor para ocultar íconos de otras apps, ítem de barra opcional (modo "derecha")
/// y menú contextual compartido con el panel centrado.
@MainActor
final class StatusController: NSObject {
    private let store: TickerStore
    private let settings = Settings.shared
    private let appState = AppState.shared
    private let setupKey = "BarraTicker.dividerSetupDone"

    private var tickerItem: NSStatusItem?
    private var dividerItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    var onOpenSettings: (() -> Void)?

    init(store: TickerStore) {
        self.store = store
        super.init()
    }

    func install() {
        DebugLog.providers.append { [weak self] in
            guard let self else { return "" }
            let d = self.dividerItem
            let frame = d?.button?.window.map { String(describing: $0.frame) } ?? "nil"
            return "divider: exists=\(d != nil) length=\(d?.length ?? -1) windowFrame=\(frame) visible=\(d?.isVisible ?? false) organizing=\(self.appState.organizing)"
        }

        // Organizar íconos: el estado vive en AppState para poder manejarlo desde Ajustes.
        appState.$organizing
            .dropFirst()
            .sink { [weak self] organizing in
                guard let self else { return }
                if !organizing && self.dividerItem != nil {
                    UserDefaults.standard.set(true, forKey: self.setupKey)
                }
                self.updateDividerAppearance()
            }
            .store(in: &cancellables)

        settings.$config
            .map(\.displayMode)
            .removeDuplicates()
            .sink { [weak self] mode in self?.applyMode(mode) }
            .store(in: &cancellables)

        settings.$config
            .map(\.width)
            .removeDuplicates()
            .sink { [weak self] w in self?.tickerItem?.length = CGFloat(w) }
            .store(in: &cancellables)

        settings.$config
            .map(\.hideOthers)
            .removeDuplicates()
            .sink { [weak self] hide in self?.applyDivider(hide: hide) }
            .store(in: &cancellables)
    }

    // MARK: - Modo ítem de barra

    private func applyMode(_ mode: DisplayMode) {
        if mode == .statusItem {
            if tickerItem == nil { createTickerItem() }
        } else if let item = tickerItem {
            NSStatusBar.system.removeStatusItem(item)
            tickerItem = nil
        }
    }

    private func createTickerItem() {
        let item = NSStatusBar.system.statusItem(withLength: CGFloat(settings.config.width))
        item.autosaveName = "BarraTicker.ticker"
        tickerItem = item

        guard let button = item.button else { return }
        let clock = ScrollClock()
        let registry = ItemRegistry()
        let host = TickerHostingView(rootView: TickerView(store: store, settings: settings,
                                                          clock: clock, registry: registry))
        host.clock = clock
        host.onClick = { [weak self] x in
            guard let self,
                  let id = registry.itemID(atLocalX: x, offset: clock.offset),
                  let url = self.store.item(withID: id)?.url else { return }
            NSWorkspace.shared.open(url)
        }
        host.contextMenuProvider = { [weak self] in self?.makeMenu() ?? NSMenu() }
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            host.topAnchor.constraint(equalTo: button.topAnchor),
            host.bottomAnchor.constraint(equalTo: button.bottomAnchor)
        ])
    }

    // MARK: - Divisor

    private func applyDivider(hide: Bool) {
        if hide {
            if dividerItem == nil {
                let d = NSStatusBar.system.statusItem(withLength: 16)
                d.autosaveName = "BarraTicker.divider"
                dividerItem = d
                // Primera vez: arranca en modo organizar. Después arranca ya oculto.
                appState.organizing = !UserDefaults.standard.bool(forKey: setupKey)
            }
            updateDividerAppearance()
        } else if let d = dividerItem {
            NSStatusBar.system.removeStatusItem(d)
            dividerItem = nil
            appState.organizing = false
        }
    }

    private func updateDividerAppearance() {
        guard let d = dividerItem else { return }
        if appState.organizing {
            d.length = 16
            d.button?.title = "┃"
            d.button?.alphaValue = 0.7
        } else {
            d.length = 10_000
            d.button?.title = ""
        }
    }

    // MARK: - Menú contextual (clic derecho sobre el ticker)

    func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let refresh = NSMenuItem(title: "Actualizar ahora", action: #selector(refreshNow), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)

        let prefs = NSMenuItem(title: "Ajustes…", action: #selector(showSettings), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        if settings.config.hideOthers {
            let title = appState.organizing
                ? "Terminar de organizar íconos (ocultar)"
                : "Organizar íconos ocultos…"
            let organize = NSMenuItem(title: title, action: #selector(toggleOrganize), keyEquivalent: "")
            organize.target = self
            menu.addItem(organize)
        }

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Salir de Kappa", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    @objc private func refreshNow() { store.refreshAll() }
    @objc private func showSettings() { onOpenSettings?() }
    @objc private func toggleOrganize() { appState.organizing.toggle() }
    @objc private func quitApp() { NSApp.terminate(nil) }
}
