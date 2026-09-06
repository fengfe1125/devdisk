import AppKit
import SwiftUI

/// Loads the menu bar glyphs drawn in Figma. They ship as vector PDFs so one file
/// covers every scale factor.
///
/// `isTemplate = true` is the whole point: macOS then recolours the artwork itself
/// for light/dark menu bars and for the highlighted state. Without it the icon
/// renders as flat black artwork and turns into an unreadable blob on a dark menu
/// bar. The PDFs are pure black on transparent for exactly this reason.
enum MenuBarIcon {

    static func name(for screen: DiskStore.Screen, hasWarnings: Bool) -> String {
        switch screen {
        case .ejecting:     return "ejecting"
        case .ejected:      return "ejected"
        case .disconnected: return "disconnected"
        case .connected, .scan:
            return hasWarnings ? "warning" : "connected"
        }
    }

    /// SF Symbols equivalents, used if the bundled artwork cannot be loaded so the
    /// menu bar never ends up with a blank slot.
    static func fallbackSymbol(for screen: DiskStore.Screen, hasWarnings: Bool) -> String {
        switch screen {
        case .ejecting:     return "externaldrive.badge.minus"
        case .ejected:      return "externaldrive.badge.checkmark"
        case .disconnected: return "externaldrive"
        case .connected, .scan:
            return hasWarnings ? "externaldrive.badge.exclamationmark" : "externaldrive.fill"
        }
    }

    private static var cache: [String: NSImage] = [:]

    static func image(named name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        guard let url = Bundle.module.url(
                forResource: name, withExtension: "pdf", subdirectory: "MenuBarIcons"),
              let image = NSImage(contentsOf: url)
        else { return nil }

        image.isTemplate = true
        image.size = NSSize(width: 16, height: 16)
        cache[name] = image
        return image
    }
}

/// Menu bar label that prefers the bundled artwork and degrades to SF Symbols.
struct MenuBarLabel: View {
    let screen: DiskStore.Screen
    let hasWarnings: Bool

    var body: some View {
        if let image = MenuBarIcon.image(
            named: MenuBarIcon.name(for: screen, hasWarnings: hasWarnings)) {
            Image(nsImage: image)
        } else {
            Image(systemName: MenuBarIcon.fallbackSymbol(
                for: screen, hasWarnings: hasWarnings))
        }
    }
}
