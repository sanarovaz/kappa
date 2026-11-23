import SwiftUI
import AppKit

// MARK: - Reloj de scroll (acumula desplazamiento; se frena con el hover)

final class ScrollClock {
    var offset: CGFloat = 0
    var paused = false
    private var lastDate: Date?

    func advance(to now: Date, speed: Double, cycle: CGFloat) -> CGFloat {
        let previous = lastDate
        lastDate = now
        guard let previous else { return offset }
        let dt = min(max(now.timeIntervalSince(previous), 0), 0.1)
        if !paused && cycle > 0 {
            offset += CGFloat(speed * dt)
        }
        if cycle > 0 {
            offset = offset.truncatingRemainder(dividingBy: cycle)
            if offset < 0 { offset += cycle }
        }
        return offset
    }

    /// Reloj en segundos activos (cartelera): avanza 1 por segundo salvo en pausa.
    func tickSeconds(to now: Date) -> CGFloat {
        let previous = lastDate
        lastDate = now
        if let previous, !paused {
            offset += CGFloat(min(max(now.timeIntervalSince(previous), 0), 0.1))
        }
        return offset
    }

    /// Desplazamiento manual (rueda / trackpad). Positivo = el contenido se mueve hacia la izquierda.
    func nudge(_ delta: CGFloat) { offset += delta }
}

// MARK: - Registro de posiciones de ítems (para resolver clics desde AppKit)

struct ItemFrame: Equatable {
    let id: String
    let minX: CGFloat
    let maxX: CGFloat
}

final class ItemRegistry {
    var frames: [ItemFrame] = []
    var cycle: CGFloat = 0
    /// Estilo cartelera: el ítem visible (cualquier clic cae sobre él).
    var fixedID: String?

    /// `x` = posición del clic dentro del ticker; `offset` = desplazamiento actual del scroll.
    func itemID(atLocalX x: CGFloat, offset: CGFloat) -> String? {
        if let fixedID { return fixedID }
        guard cycle > 0 else { return nil }
        var cx = (x + offset).truncatingRemainder(dividingBy: cycle)
        if cx < 0 { cx += cycle }
        return frames.first { cx >= $0.minX && cx <= $0.maxX }?.id
    }
}

// MARK: - Mediciones

struct WidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct ItemFramesKey: PreferenceKey {
    static let defaultValue: [ItemFrame] = []
    static func reduce(value: inout [ItemFrame], nextValue: () -> [ItemFrame]) {
        value.append(contentsOf: nextValue())
    }
}

// MARK: - Vista del ticker

struct TickerView: View {
    @ObservedObject var store: TickerStore
    @ObservedObject var settings: Settings
    let clock: ScrollClock
    let registry: ItemRegistry
    /// true: ocupa el tamaño de su contenedor (panel). false: usa el ancho de Ajustes (ítem de barra).
    var useContainerWidth = false

    @State private var cycle: CGFloat = 0

    var body: some View {
        if useContainerWidth {
            GeometryReader { geo in
                content(width: geo.size.width, height: geo.size.height)
            }
        } else {
            content(width: CGFloat(settings.config.width), height: NSStatusBar.system.thickness)
        }
    }

    @ViewBuilder
    private func content(width: CGFloat, height: CGFloat) -> some View {
        if settings.config.style == .splitFlap {
            SplitFlapView(store: store, settings: settings, clock: clock, registry: registry,
                          width: width, height: height)
        } else {
            scrollContent(width: width, height: height)
                .onAppear { registry.fixedID = nil }
        }
    }

    private func scrollContent(width: CGFloat, height: CGFloat) -> some View {
        let cfg = settings.config
        return TimelineView(.animation(minimumInterval: 1.0 / Double(max(10, cfg.fps)))) { context in
            let phase = clock.advance(to: context.date, speed: cfg.speed, cycle: cycle)
            let copies = cycle > 1 ? max(2, Int(ceil(width / cycle)) + 1) : 2

            HStack(spacing: 0) {
                ForEach(0..<copies, id: \.self) { index in
                    strip(reportFrames: index == 0)
                }
            }
            .onPreferenceChange(WidthKey.self) { newWidth in
                guard newWidth > 0 else { return }
                // Si el contenido cambia de ancho, conservamos la posición relativa
                // para que el scroll no salte.
                if cycle > 0 { clock.offset = clock.offset * newWidth / cycle }
                cycle = newWidth
                registry.cycle = newWidth
            }
            .onPreferenceChange(ItemFramesKey.self) { frames in
                registry.frames = frames
            }
            .fixedSize(horizontal: true, vertical: false)
            .offset(x: -phase)
            .frame(width: width, height: height, alignment: .leading)
            .clipped()
        }
        .mask(fade)
        .frame(width: width, height: height)
    }

    private func strip(reportFrames: Bool) -> some View {
        HStack(spacing: 0) {
            if store.items.isEmpty {
                Text("Cargando datos…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .padding(.horizontal, 10)
                separator
            } else {
                ForEach(store.items) { item in
                    ItemView(item: item, color: settings.color(for: item.category))
                        .background(
                            GeometryReader { g in
                                let f = g.frame(in: .named("strip"))
                                Color.clear.preference(
                                    key: ItemFramesKey.self,
                                    value: reportFrames ? [ItemFrame(id: item.id, minX: f.minX, maxX: f.maxX)] : []
                                )
                            }
                        )
                    separator
                }
            }
        }
        .coordinateSpace(name: "strip")
        .background(
            GeometryReader { g in
                Color.clear.preference(key: WidthKey.self, value: g.size.width)
            }
        )
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.5))
            .frame(width: 1, height: 12)
    }

    private var fade: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.04),
                .init(color: .black, location: 0.96),
                .init(color: .clear, location: 1)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

struct ItemView: View {
    let item: TickerItem
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Text(item.category.emoji)
                .font(.system(size: 12))
            Text(item.text)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 10)
    }
}

// MARK: - Host AppKit: hover (pausa), primer clic y menú contextual

final class TickerHostingView: NSHostingView<TickerView> {
    var clock: ScrollClock?
    /// Solo en modo ítem de barra: recibe la x del clic dentro de la vista.
    var onClick: ((CGFloat) -> Void)?
    var contextMenuProvider: (() -> NSMenu)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        DebugLog.bump("host.entered")
        clock?.paused = true
    }
    override func mouseExited(with event: NSEvent) {
        DebugLog.bump("host.exited")
        clock?.paused = false
    }

    override func mouseDown(with event: NSEvent) {
        DebugLog.bump("host.mouseDown")
        if let onClick {
            onClick(convert(event.locationInWindow, from: nil).x)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = contextMenuProvider?() {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }
}
