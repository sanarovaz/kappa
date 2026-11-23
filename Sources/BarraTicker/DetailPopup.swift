import AppKit
import SwiftUI

/// Ícono (favicon) del sitio al que lleva el link, con caché.
@MainActor
final class FaviconModel: ObservableObject {
    @Published var image: NSImage?
    private static var cache: [String: NSImage] = [:]

    func load(for url: URL?) {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host else { return }
        if let hit = Self.cache[host] { image = hit; return }
        Task {
            let candidates = [
                "https://\(host)/favicon.ico",
                "https://www.google.com/s2/favicons?domain=\(host)&sz=64"
            ]
            for c in candidates {
                guard let u = URL(string: c) else { continue }
                var req = URLRequest(url: u)
                req.timeoutInterval = 6
                guard let (data, resp) = try? await URLSession.shared.data(for: req),
                      (resp as? HTTPURLResponse)?.statusCode == 200,
                      let img = NSImage(data: data), img.size.width > 1 else { continue }
                Self.cache[host] = img
                self.image = img
                return
            }
        }
    }
}

/// Contenido del popup de detalle (chico, debajo del ticker).
struct DetailView: View {
    let item: TickerItem
    let color: Color
    @ObservedObject var favicon: FaviconModel

    private var hasWebLink: Bool {
        guard let s = item.url?.scheme?.lowercased() else { return false }
        return s == "http" || s == "https"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 6) {
                Text(item.category.emoji)
                    .font(.system(size: 13))
                if hasWebLink {
                    // Lugar reservado: el tamaño del globo no cambia cuando llega el ícono.
                    Group {
                        if let img = favicon.image {
                            Image(nsImage: img).resizable().interpolation(.high).scaledToFit()
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: 16, height: 16)
                }
                Text(item.title.isEmpty ? item.text : item.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(item.wrapTitle ? 6 : 1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: item.wrapTitle)
            }
            ForEach(Array(item.detail.split(separator: "\n").enumerated()), id: \.offset) { pair in
                Text(String(pair.element))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if item.url != nil {
                Text("Clic para abrir el link")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .frame(width: 250, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Ventana chiquita con más detalle. Un clic sobre ella abre la app/link del ítem.
@MainActor
final class DetailPopup {
    let panel: TickerPanel
    let itemID: String
    let url: URL?

    init(item: TickerItem, color: Color, theme: PillTheme, anchor: NSRect, clickX: CGFloat, screen: NSScreen) {
        itemID = item.id
        url = item.url

        let favicon = FaviconModel()
        favicon.load(for: item.url)
        let host = NSHostingView(rootView: DetailView(item: item, color: color, favicon: favicon))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)

        let background = ThemeBackground.make(theme, radius: 10)
        background.frame = NSRect(origin: .zero, size: size)
        background.addSubview(host)

        let p = TickerPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.appearance = ThemeBackground.appearance(theme)
        p.contentView = background

        let f = screen.frame
        var x = clickX - size.width / 2
        x = min(max(x, f.minX + 8), f.maxX - size.width - 8)
        let y = anchor.minY - size.height - 6
        p.setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height), display: true)
        p.orderFrontRegardless()
        panel = p
    }

    func close() {
        panel.orderOut(nil)
        panel.close()
    }
}
