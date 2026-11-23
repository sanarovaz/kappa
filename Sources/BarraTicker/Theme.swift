import AppKit
import SwiftUI

/// Fondos de la píldora y del popup de detalle según el diseño elegido.
enum ThemeBackground {
    static func make(_ theme: PillTheme, radius: CGFloat) -> NSView {
        switch theme {
        case .glassDark:
            return glass(.hudWindow, radius: radius)
        case .glassLight:
            return glass(.popover, radius: radius)
        case .black:
            return solid(NSColor.black, radius: radius)
        case .white:
            return solid(NSColor.white, radius: radius)
        }
    }

    static func appearance(_ theme: PillTheme) -> NSAppearance? {
        NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
    }

    private static func glass(_ material: NSVisualEffectView.Material, radius: CGFloat) -> NSView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = radius
        v.layer?.masksToBounds = true
        return v
    }

    private static func solid(_ color: NSColor, radius: CGFloat) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = color.cgColor
        v.layer?.cornerRadius = radius
        v.layer?.masksToBounds = true
        return v
    }
}
