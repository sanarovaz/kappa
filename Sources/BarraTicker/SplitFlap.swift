import SwiftUI
import AppKit

// MARK: - Estilo "Cartelera" (split-flap)
//
// Muestra un ítem por vez en un tablero de letras que giran. Los textos largos se
// parten en páginas del ancho del tablero. Hover pausa; la rueda / el trackpad
// avanzan o retroceden de página.

struct FlapPage {
    let item: TickerItem
    let text: String
}

private let flapCharset: [Character] = Array(" ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.,:-·$%▲▼/&()'+")

/// Una sola línea: si no entra se corta con "…", pero la cola (`suffix`, p. ej. el plazo) siempre se conserva.
func flapLine(_ item: TickerItem, cols: Int) -> String {
    let text = item.text.replacingOccurrences(of: "🟢", with: "●").uppercased()
    if text.count <= cols { return text }
    let tail = item.suffix.uppercased()
    if !tail.isEmpty, text.hasSuffix(tail), cols - tail.count - 1 >= 3 {
        let head = String(text.dropLast(tail.count))
        return String(head.prefix(cols - tail.count - 1)).trimmingCharacters(in: .whitespaces) + "…" + tail
    }
    return String(text.prefix(max(1, cols - 1))) + "…"
}

func makePages(_ items: [TickerItem], cols: Int) -> [FlapPage] {
    if items.isEmpty {
        return [FlapPage(item: TickerItem(id: "empty", category: .noticias, text: "Cargando datos…", url: nil),
                         text: "CARGANDO DATOS…")]
    }
    return items.flatMap { item in
        [FlapPage(item: item, text: flapLine(item, cols: cols))]
    }
}

private func pad(_ s: String, to cols: Int) -> [Character] {
    var a = Array(s)
    if a.count > cols { a = Array(a.prefix(cols)) }
    while a.count < cols { a.append(" ") }
    return a
}

/// (carácter a mostrar, fracción del paso actual) para la celda `i`, `t` segundos después del cambio.
private func flapShown(prev: Character, target: Character, t: Double, i: Int) -> (Character, CGFloat) {
    let delay = Double(i) * 0.02
    let dur = 0.45
    let p = (t - delay) / dur
    if prev == target || p >= 1 { return (target, 1) }
    if p < 0 { return (prev, 1) }
    guard let to = flapCharset.firstIndex(of: target) else { return (target, 1) }
    let steps = 6
    let k = Int(p * Double(steps))
    let frac = CGFloat(p * Double(steps) - Double(k))
    let n = flapCharset.count
    let idx = (((to - (steps - k)) % n) + n) % n
    return (flapCharset[idx], frac)
}

private struct FlapCell: View {
    let ch: Character
    let frac: CGFloat
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2.5).fill(Color.primary.opacity(0.13))
            Text(String(ch))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
                .scaleEffect(x: 1, y: 0.3 + 0.7 * frac)
            Rectangle().fill(Color.black.opacity(0.35)).frame(height: 0.8)
        }
        .frame(width: width, height: height)
    }
}

/// Estado de la cartelera: qué página se ve y cuál se veía antes. Los avisos de mail
/// entran recién cuando termina la página actual (nunca la cortan).
final class FlapPlayer {
    var lastBase: Int?
    var cursor = 0
    var current: FlapPage?
    var previous: FlapPage?
    var pending: [FlapPage] = []

    @MainActor
    func sync(base: Int, pages: [FlapPage], store: TickerStore, cols: Int) {
        let n = pages.count
        guard let last = lastBase, let cur = current else {
            lastBase = base
            cursor = ((base % n) + n) % n
            current = pages[cursor]
            previous = current
            return
        }
        lastBase = base
        if base > last {
            for _ in 0..<min(base - last, 8) {
                previous = current
                if pending.isEmpty, let alert = store.takeFlapAlert() {
                    pending = [FlapPage(item: alert, text: flapLine(alert, cols: cols))]
                }
                if !pending.isEmpty {
                    current = pending.removeFirst()
                } else {
                    cursor = (cursor + 1) % n
                    current = pages[cursor]
                }
            }
        } else if base < last {
            for _ in 0..<min(last - base, 8) {
                previous = current
                pending.removeAll()
                cursor = (cursor - 1 + n) % n
                current = pages[cursor]
            }
        } else if cursor >= n || cur.item.id == "empty" {
            cursor = min(cursor, n - 1)
            current = pages[cursor]
        }
    }
}

struct SplitFlapView: View {
    @State private var player = FlapPlayer()
    @ObservedObject var store: TickerStore
    @ObservedObject var settings: Settings
    let clock: ScrollClock
    let registry: ItemRegistry
    let width: CGFloat
    let height: CGFloat

    private let cellW: CGFloat = 9

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            board(date: context.date)
        }
        .frame(width: width, height: height)
    }

    private func cells(before: [Character], now: [Character], local: Double, cols: Int, cellH: CGFloat) -> [AnyView] {
        var out: [AnyView] = []
        for i in 0..<cols {
            let shown = flapShown(prev: before[i], target: now[i], t: local, i: i)
            out.append(AnyView(FlapCell(ch: shown.0, frac: shown.1, width: cellW, height: cellH)))
        }
        return out
    }

    private func board(date: Date) -> AnyView {
        let cfg = settings.config
        let dwell = max(1.5, cfg.flapSeconds)
        let cols = max(8, Int((width - 40) / (cellW + 1)))
        let cellH = min(height - 4, 18)

        // El reloj cuenta segundos activos (pausa con el hover; la rueda lo adelanta o atrasa).
        let seconds = Double(clock.tickSeconds(to: date))
        let pages = makePages(store.baseItems, cols: cols)
        let base = Int(floor(seconds / dwell))
        let local = (seconds / dwell - floor(seconds / dwell)) * dwell
        player.sync(base: base, pages: pages, store: store, cols: cols)
        let page = player.current ?? pages[0]
        let before = player.previous ?? page
        registry.fixedID = page.item.id

        let row = cells(before: pad(before.text, to: cols),
                        now: pad(page.text, to: cols),
                        local: local, cols: cols, cellH: cellH)
        return AnyView(
            HStack(spacing: 6) {
                Text(page.item.category.emoji).font(.system(size: 12))
                HStack(spacing: 1) {
                    ForEach(0..<row.count, id: \.self) { row[$0] }
                }
            }
            .padding(.horizontal, 8)
            .frame(width: width, height: height, alignment: .leading)
        )
    }
}
