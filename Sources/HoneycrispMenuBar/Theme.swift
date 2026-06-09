import SwiftUI

/// The System direction: stock materials and SF Pro everywhere, with the
/// brand showing up only as the accent and the app icons. Values come from
/// the brand tokens.
enum Theme {
    static let red = Color(red: 0xC5 / 255, green: 0x45 / 255, blue: 0x3A / 255)
    static let gold = Color(red: 0xB6 / 255, green: 0x84 / 255, blue: 0x1F / 255)
    static let green = Color(red: 0x34 / 255, green: 0xC7 / 255, blue: 0x59 / 255)
    static let greenText = Color(red: 0x2A / 255, green: 0x8C / 255, blue: 0x46 / 255)

    /// Fallback SF Symbols and tints for the four apps when the brand SVGs
    /// are not bundled (bare swift run).
    static func fallbackIcon(for app: AppID) -> (symbol: String, tint: Color) {
        switch app {
        case .mail: return ("envelope.fill", Color(red: 0.10, green: 0.46, blue: 0.95))
        case .reminders: return ("checklist", Color(red: 0.95, green: 0.40, blue: 0.30))
        case .messages: return ("message.fill", Color(red: 0.22, green: 0.78, blue: 0.35))
        case .contacts: return ("person.crop.square.fill", Color(white: 0.55))
        }
    }
}

import HoneycrispCore

/// One of the four app icons: the hand-built brand SVG when bundled, an SF
/// Symbol stand-in otherwise.
struct AppIconView: View {
    let app: AppID
    var size: CGFloat = 24

    var body: some View {
        if let image = BundledArt.appIcon(app) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
        } else {
            let fallback = Theme.fallbackIcon(for: app)
            Image(systemName: fallback.symbol)
                .resizable()
                .scaledToFit()
                .foregroundStyle(fallback.tint)
                .frame(width: size * 0.78, height: size * 0.78)
                .frame(width: size, height: size)
        }
    }
}

/// Loads bundled brand art from Contents/Resources (Bundle.main, never
/// Bundle.module; see the AGENTS.md findings).
enum BundledArt {
    static func appIcon(_ app: AppID) -> NSImage? {
        image(named: "\(app.rawValue).svg")
    }

    static func panelIcon() -> NSImage? {
        image(named: "icon.svg")
    }

    static func menuBarGlyph() -> NSImage? {
        guard let image = image(named: "glyph-black.svg") else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    private static func image(named name: String) -> NSImage? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent(name),
            let image = NSImage(contentsOf: url)
        else { return nil }
        return image
    }
}
