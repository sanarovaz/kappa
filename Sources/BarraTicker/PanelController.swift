import AppKit
import SwiftUI
import Combine
import ApplicationServices

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    var isBuiltIn: Bool {
        guard let id = displayID else { return false }
        return CGDisplayIsBuiltin(id) != 0
    }
}

final class TickerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// macOS empuja por defecto las ventanas fuera del área de la barra de menús
    /// (las deja debajo, tapando las apps). Devolvemos el frame tal cual para que
    /// el panel quede DENTRO de la barra.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override func sendEvent(_ event: NSEvent) {
        DebugLog.bump("panel.event.\(event.type.rawValue)")
        super.sendEvent(event)
    }
}

/// Panel flotante sobre la barra de menús.
///
/// Regla de pantallas:
///  - Si hay un monitor externo conectado: solo se muestra en el/los monitores externos, centrado.
///  - Si no: se muestra a la derecha del notch con un ancho fijo (por defecto 220 pt).
///
/// Interacción (por monitores de mouse, porque el sistema no le entrega los eventos
/// de esa franja a la ventana):
///  - Clic izquierdo en un ítem: abre un popup chico con detalle.
///  - Clic en el popup, o de nuevo en el mismo ítem: abre la app/link correspondiente.
///  - Clic derecho: menú contextual.
@MainActor
final class PanelController: NSObject {
    private final class Entry {
        let panel: TickerPanel
        let clock: ScrollClock
        let registry: ItemRegistry
        init(panel: TickerPanel, clock: ScrollClock, registry: ItemRegistry) {
            self.panel = panel
            self.clock = clock
            self.registry = registry
        }
    }

    private let store: TickerStore
    private let settings = Settings.shared
    private var panels: [CGDirectDisplayID: Entry] = [:]
    private var popup: DetailPopup?
    private var lastTheme: PillTheme?
    private var currentTheme: PillTheme { lastTheme ?? settings.config.theme }
    private var mouseMonitors: [Any] = []
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []

    var menuProvider: (() -> NSMenu)?

    private let margin: CGFloat = 14
    private let minWidth: CGFloat = 120

    init(store: TickerStore) {
        self.store = store
        super.init()
    }

    func install() {
        settings.$config
            .sink { [weak self] cfg in self?.relayout(cfg) }
            .store(in: &cancellables)

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.relayout()
                self?.updateHover()
                self?.snapshotIfNeeded()
            }
        }

        // Hover y clic por monitores de mouse: no dependen de que la ventana reciba
        // los eventos (en la zona de la barra de menús el sistema no se los entrega).
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let type = event.type
            DebugLog.bump("monitor.global.\(type.rawValue)")
            let dx: CGFloat = type == .scrollWheel ? event.scrollingDeltaX : 0
            let dy: CGFloat = type == .scrollWheel ? event.scrollingDeltaY : 0
            MainActor.assumeIsolated { self?.handleMouse(type, dx: dx, dy: dy) }
        }) { mouseMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let type = event.type
            DebugLog.bump("monitor.local.\(type.rawValue)")
            let dx: CGFloat = type == .scrollWheel ? event.scrollingDeltaX : 0
            let dy: CGFloat = type == .scrollWheel ? event.scrollingDeltaY : 0
            MainActor.assumeIsolated { self?.handleMouse(type, dx: dx, dy: dy) }
            return event
        }) { mouseMonitors.append(l) }

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayout() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayout() }
        })
    }

    static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Layout

    private func relayout(_ config: Config? = nil) {
        let c = config ?? settings.config
        guard c.displayMode == .centered, let primary = NSScreen.screens.first else {
            removeAll()
            return
        }

        // Cambió el diseño: se reconstruyen los paneles.
        if lastTheme != c.theme {
            removeAll()
            lastTheme = c.theme
        }

        let reserveRight = statusReserve(primary: primary)
        let menuEdge: CGFloat? = c.avoidMenus ? menuRightEdge() : nil

        // Regla: con monitor externo, solo ahí. Sin monitor externo, la pantalla integrada.
        let externals = NSScreen.screens.filter { !$0.isBuiltIn }
        let targets = externals.isEmpty ? NSScreen.screens : externals

        var seen = Set<CGDirectDisplayID>()
        for screen in targets {
            guard let id = screen.displayID else { continue }
            guard let frame = computeFrame(screen: screen, primary: primary,
                                           centeredWidth: CGFloat(c.width),
                                           notchWidth: CGFloat(c.notchWidth),
                                           reserveRight: reserveRight, menuEdge: menuEdge) else { continue }
            seen.insert(id)
            let panel = (panels[id] ?? makePanel(id, theme: c.theme)).panel
            if panel.frame != frame { panel.setFrame(frame, display: true) }

            // Seguro: si el sistema lo dejó fuera de la barra (más abajo de lo pedido),
            // se oculta en vez de tapar las apps.
            if abs(panel.frame.maxY - frame.maxY) > 1 || abs(panel.frame.minY - frame.minY) > 1 {
                panel.orderOut(nil)
                continue
            }
            if !panel.isVisible { panel.orderFrontRegardless() }
        }

        for (id, entry) in panels where !seen.contains(id) {
            entry.panel.orderOut(nil)
            entry.panel.close()
            panels[id] = nil
        }
    }

    private func removeAll() {
        closePopup()
        for (_, entry) in panels {
            entry.panel.orderOut(nil)
            entry.panel.close()
        }
        panels.removeAll()
    }

    private func menuBarHeight(_ screen: NSScreen) -> CGFloat {
        if screen.safeAreaInsets.top > 0 { return screen.safeAreaInsets.top }
        let d = screen.frame.maxY - screen.visibleFrame.maxY
        return d > 10 ? d : NSStatusBar.system.thickness
    }

    private func computeFrame(screen: NSScreen, primary: NSScreen,
                              centeredWidth: CGFloat, notchWidth: CGFloat,
                              reserveRight: CGFloat, menuEdge: CGFloat?) -> NSRect? {
        let f = screen.frame
        let barH = menuBarHeight(screen)
        let inset: CGFloat = 3
        let y = f.maxY - barH + inset
        let h = barH - inset * 2

        var lo = f.minX + margin
        let hi = f.maxX - reserveRight - margin

        // Pantalla con notch: pegado a la derecha del notch, ancho fijo.
        if screen.safeAreaInsets.top > 0, let right = screen.auxiliaryTopRightArea {
            // Puede venir en coordenadas globales o relativas a la pantalla.
            let rx = (right.minX >= f.minX && right.minX <= f.maxX) ? right.minX : f.minX + right.minX
            lo = rx + margin
            let w = min(notchWidth, hi - lo)
            guard w >= minWidth else { return nil }
            return NSRect(x: lo.rounded(), y: y, width: w.rounded(), height: h)
        }

        // Sin notch: centrado en la pantalla, corriéndose si los menús de la app lo tocan.
        if let edge = menuEdge {
            let rel = edge - primary.frame.minX
            if rel > 0 && rel < f.width { lo = max(lo, f.minX + rel + margin) }
        }
        let avail = hi - lo
        guard avail >= minWidth else { return nil }

        let w = min(centeredWidth, avail)
        var x = f.midX - w / 2
        x = min(max(x, lo), hi - w)                      // nunca fuera de la banda libre
        return NSRect(x: x.rounded(), y: y, width: w.rounded(), height: h)
    }

    // MARK: - Diagnóstico

    private func snapshotIfNeeded() {
        DebugLog.snapshots += 1
        guard DebugLog.snapshots % 2 == 0, DebugLog.snapshots <= 300 else { return }

        let c = settings.config
        var lines: [String] = []
        lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString) | mode=\(c.displayMode.rawValue) theme=\(c.theme.rawValue) hideOthers=\(c.hideOthers) axTrusted=\(AXIsProcessTrusted()) avoidMenus=\(c.avoidMenus)")
        for sc in NSScreen.screens {
            lines.append("screen frame=\(sc.frame) builtIn=\(sc.isBuiltIn) safeTop=\(sc.safeAreaInsets.top)")
        }
        for (id, e) in panels {
            lines.append("panel \(id) frame=\(e.panel.frame) visible=\(e.panel.isVisible) paused=\(e.clock.paused)")
        }
        if let primary = NSScreen.screens.first {
            let reserve = statusReserve(primary: primary)
            let edge = menuRightEdge()
            lines.append("reserveRight=\(Int(reserve)) menuEdge=\(edge.map { String(Int($0)) } ?? "nil")")
            for sc in NSScreen.screens {
                let frame = computeFrame(screen: sc, primary: primary,
                                         centeredWidth: CGFloat(c.width), notchWidth: CGFloat(c.notchWidth),
                                         reserveRight: reserve, menuEdge: edge)
                lines.append("layout screen=\(sc.frame.origin) -> \(frame.map { String(describing: $0) } ?? "nil")")
            }
        }
        lines.append("items=\(store.items.count) first=\(store.items.first?.text ?? "-")")
        lines.append("mouse=\(NSEvent.mouseLocation) counters=\(DebugLog.counters.sorted { $0.key < $1.key })")
        for provider in DebugLog.providers {
            let extra = provider()
            if !extra.isEmpty { lines.append(extra) }
        }
        DebugLog.write(lines.joined(separator: "\n   "))
    }

    // MARK: - Mouse

    private func updateHover() {
        let loc = NSEvent.mouseLocation
        for entry in panels.values {
            entry.clock.paused = entry.panel.isVisible && entry.panel.frame.contains(loc)
        }
    }

    private func closePopup() {
        popup?.close()
        popup = nil
    }

    private func showPopup(item: TickerItem, entry: Entry, clickX: CGFloat) {
        closePopup()
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(entry.panel.frame) }) else { return }
        popup = DetailPopup(item: item,
                            color: settings.color(for: item.category),
                            theme: currentTheme,
                            anchor: entry.panel.frame,
                            clickX: clickX,
                            screen: screen)
    }

    private func handleMouse(_ type: NSEvent.EventType, dx: CGFloat = 0, dy: CGFloat = 0) {
        updateHover()
        if type == .scrollWheel {
            // Rueda (normal o con shift) o trackpad horizontal: mueve el ticker.
            let delta = abs(dx) >= abs(dy) ? dx : dy
            guard delta != 0 else { return }
            let loc = NSEvent.mouseLocation
            for entry in panels.values where entry.panel.isVisible && entry.panel.frame.contains(loc) {
                if settings.config.style == .splitFlap {
                    // ~60 pt de scroll = una página
                    entry.clock.nudge(-delta * CGFloat(max(1.5, settings.config.flapSeconds)) / 60)
                } else {
                    entry.clock.nudge(-delta)
                }
            }
            return
        }
        guard type == .leftMouseDown || type == .rightMouseDown else { return }
        let loc = NSEvent.mouseLocation
        let frames = panels.values.map { "\($0.panel.frame) vis=\($0.panel.isVisible)" }.joined(separator: " | ")
        DebugLog.write("mouseDown type=\(type.rawValue) loc=\(loc) panels=[\(frames)] popup=\(popup != nil)")

        // Clic derecho: menú contextual sobre el panel; en cualquier caso cierra el popup.
        if type == .rightMouseDown {
            closePopup()
            for entry in panels.values where entry.panel.isVisible && entry.panel.frame.contains(loc) {
                DebugLog.write("right click en panel -> menú")
                menuProvider?().popUp(positioning: nil, at: loc, in: nil)
                break
            }
            return
        }

        // Clic izquierdo sobre el popup: abrir la app/link y cerrar.
        if let popup, popup.panel.frame.contains(loc) {
            DebugLog.write("click en popup -> abrir \(popup.url?.absoluteString ?? "nil")")
            if let url = popup.url { NSWorkspace.shared.open(url) }
            closePopup()
            return
        }

        // Clic izquierdo sobre el panel.
        for entry in panels.values where entry.panel.isVisible && entry.panel.frame.contains(loc) {
            let localX = loc.x - entry.panel.frame.minX
            let id = entry.registry.itemID(atLocalX: localX, offset: entry.clock.offset)
            let item = id.flatMap { store.item(withID: $0) }
            DebugLog.write("click en panel localX=\(Int(localX)) offset=\(Int(entry.clock.offset)) cycle=\(Int(entry.registry.cycle)) frames=\(entry.registry.frames.count) items=\(store.items.count) id=\(id ?? "nil") url=\(item?.url?.absoluteString ?? "nil")")

            guard let item else { closePopup(); return }
            if popup?.itemID == item.id {
                // Segundo clic sobre el mismo ítem: abrir.
                if let url = item.url { NSWorkspace.shared.open(url) }
                closePopup()
            } else {
                showPopup(item: item, entry: entry, clickX: loc.x)
            }
            return
        }

        // Clic en cualquier otro lado: cerrar el popup.
        closePopup()
    }

    // MARK: - Medición de obstáculos

    /// Ancho que ocupan, desde el borde derecho, los ítems de barra de otras apps y del sistema.
    /// (En macOS 27 estas ventanas no aparecen en CGWindowList: devuelve 0.)
    private func statusReserve(primary: NSScreen) -> CGFloat {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return 0 }
        let me = Int(ProcessInfo.processInfo.processIdentifier)
        let pf = primary.frame
        var minX = CGFloat.greatestFiniteMagnitude

        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 25,
                  (w[kCGWindowOwnerPID as String] as? Int) != me,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: dict as CFDictionary) else { continue }
            if r.minY < 40, r.height < 60, r.minX >= pf.minX, r.maxX <= pf.maxX + 1 {
                minX = min(minX, r.minX)
            }
        }
        return minX == CGFloat.greatestFiniteMagnitude ? 0 : max(0, pf.maxX - minX)
    }

    /// Borde derecho (coordenada x global) del último menú de la app activa. Requiere Accesibilidad.
    private func menuRightEdge() -> CGFloat? {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)

        var barRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXMenuBarAttribute as CFString, &barRef) == .success,
              let barRef, CFGetTypeID(barRef) == AXUIElementGetTypeID() else { return nil }
        let bar = barRef as! AXUIElement

        var kidsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &kidsRef) == .success,
              let kids = kidsRef as? [AXUIElement] else { return nil }

        var maxX: CGFloat = 0
        for kid in kids {
            var posRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(kid, kAXPositionAttribute as CFString, &posRef) == .success,
                  AXUIElementCopyAttributeValue(kid, kAXSizeAttribute as CFString, &sizeRef) == .success,
                  let posRef, let sizeRef,
                  CFGetTypeID(posRef) == AXValueGetTypeID(),
                  CFGetTypeID(sizeRef) == AXValueGetTypeID() else { continue }
            var p = CGPoint.zero
            var s = CGSize.zero
            AXValueGetValue(posRef as! AXValue, .cgPoint, &p)
            AXValueGetValue(sizeRef as! AXValue, .cgSize, &s)
            maxX = max(maxX, p.x + s.width)
        }
        return maxX > 0 ? maxX : nil
    }

    // MARK: - Creación del panel

    private func makePanel(_ id: CGDirectDisplayID, theme: PillTheme) -> Entry {
        let panel = TickerPanel(contentRect: .zero,
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered,
                                defer: false)
        // Por encima de la barra de menús y de los ítems de estado.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.appearance = ThemeBackground.appearance(theme)

        let background = ThemeBackground.make(theme, radius: 9)

        let clock = ScrollClock()
        let registry = ItemRegistry()
        let host = TickerHostingView(rootView: TickerView(store: store, settings: settings,
                                                          clock: clock, registry: registry,
                                                          useContainerWidth: true))
        host.clock = clock
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            host.topAnchor.constraint(equalTo: background.topAnchor),
            host.bottomAnchor.constraint(equalTo: background.bottomAnchor)
        ])

        panel.contentView = background
        let entry = Entry(panel: panel, clock: clock, registry: registry)
        panels[id] = entry
        return entry
    }
}
