import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = TickerStore()
    private var status: StatusController?
    private var panels: PanelController?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installEditMenu()
        DebugLog.reset()
        DebugLog.write("launch pid=\(ProcessInfo.processInfo.processIdentifier) bundle=\(Bundle.main.bundleURL.path)")

        let controller = StatusController(store: store)
        controller.onOpenSettings = { [weak self] in self?.showSettings() }
        controller.install()
        status = controller

        let panelController = PanelController(store: store)
        panelController.menuProvider = { [weak controller] in controller?.makeMenu() ?? NSMenu() }
        panelController.install()
        panels = panelController

        store.start()

        // Primera ejecución: abrir los ajustes.
        let key = "BarraTicker.didLaunchBefore"
        if !UserDefaults.standard.bool(forKey: key) {
            UserDefaults.standard.set(true, forKey: key)
            showSettings()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Volver a abrir la app (Finder / Spotlight) abre los Ajustes: sirve de salvavidas
    /// si el panel está oculto por falta de espacio.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    /// Las apps accesorias no tienen barra de menús, y sin menú Edición los atajos
    /// ⌘V / ⌘C / ⌘X / ⌘A / ⌘Z no funcionan en los campos de texto.
    private func installEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Cerrar ventana", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edición")
        edit.addItem(withTitle: "Deshacer", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Rehacer", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cortar", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Pegar", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Seleccionar todo", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        NSApp.mainMenu = main
    }

    func showSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(settings: Settings.shared, store: store))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Kappa"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 780, height: 560))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        // App accesoria: sin esto la ventana queda visible pero inactiva y los campos de texto no reciben teclas.
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
    }
}
