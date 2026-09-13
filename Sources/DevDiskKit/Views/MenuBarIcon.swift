import AppKit
import SwiftUI

/// Loads the menu bar glyphs drawn in Figma. They ship as vector PDFs so one file
/// covers every scale factor.
///
/// `isTemplate = true` is the whole point: macOS then recolours the artwork itself
/// for light/dark menu bars and for the highlighted state. Without it the icon
/// renders as flat black artwork and turns into an unreadable blob on a dark menu
/// bar. The PDFs are pure black on transparent for exactly this reason.
///
/// Deliberately does **not** use `Bundle.module`. SwiftPM's generated accessor looks
/// only in `Bundle.main.bundleURL/<name>.bundle` — the .app's *root*, not
/// `Contents/Resources` — and otherwise at an absolute build path from whatever
/// machine compiled it. Inside a packaged app both miss, and the accessor calls
/// `fatalError`, so the app dies on launch instead of degrading. These lookups
/// cover both layouts and never trap.
enum MenuBarIcon {

    /// The icon reports the state of the *volume*, not which screen happens to be
    /// open. Deriving it from the screen alone made the icon claim "connected" the
    /// moment you opened settings on a disconnected drive.
    static func name(for screen: DiskStore.Screen,
                     mounted: Bool,
                     hasWarnings: Bool) -> String {
        switch screen {
        case .ejecting: return "ejecting"
        case .ejected:  return "ejected"
        default:
            guard mounted else { return "disconnected" }
            return hasWarnings ? "warning" : "connected"
        }
    }

    static let allNames = ["connected", "warning", "ejecting", "ejected", "disconnected"]

    /// SF Symbols equivalents, used if the bundled artwork cannot be loaded so the
    /// menu bar never ends up with a blank slot.
    static func fallbackSymbol(for screen: DiskStore.Screen,
                               mounted: Bool,
                               hasWarnings: Bool) -> String {
        switch screen {
        case .ejecting: return "externaldrive.badge.minus"
        case .ejected:  return "externaldrive.badge.checkmark"
        default:
            guard mounted else { return "externaldrive" }
            return hasWarnings ? "externaldrive.badge.exclamationmark" : "externaldrive.fill"
        }
    }

    /// Where the artwork can legitimately live, in preference order.
    static func url(for name: String) -> URL? {
        // 1. Packaged app: Contents/Resources/MenuBarIcons/<name>.pdf
        if let u = Bundle.main.url(
            forResource: name, withExtension: "pdf", subdirectory: "MenuBarIcons") {
            return u
        }

        let fm = FileManager.default
        // 2. `swift build` / `swift run`: the SwiftPM resource bundle sits next to
        //    the executable.
        let spm = Bundle.main.bundleURL
            .appendingPathComponent("DevDisk_DevDiskKit.bundle")
            .appendingPathComponent("MenuBarIcons")
            .appendingPathComponent(name + ".pdf")
        if fm.fileExists(atPath: spm.path) { return spm }

        // 3. Same bundle reached through this type's own framework, for good measure.
        let own = Bundle(for: BundleToken.self).bundleURL
            .appendingPathComponent("MenuBarIcons")
            .appendingPathComponent(name + ".pdf")
        if fm.fileExists(atPath: own.path) { return own }

        return nil
    }

    private final class BundleToken {}

    private static var cache: [String: NSImage] = [:]

    static func image(named name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        guard let url = url(for: name), let image = NSImage(contentsOf: url)
        else { return nil }

        image.isTemplate = true
        image.size = NSSize(width: 16, height: 16)
        cache[name] = image
        return image
    }

    /// Names that could not be resolved. Empty means the artwork is wired up
    /// correctly; used by `--selftest` so a broken package fails in CI rather than
    /// on a user's menu bar.
    static var missing: [String] {
        allNames.filter { image(named: $0) == nil }
    }
}

/// Menu bar label that prefers the bundled artwork and degrades to SF Symbols.
struct MenuBarLabel: View {
    @ObservedObject private var language = LanguageStore.shared
    let screen: DiskStore.Screen
    let mounted: Bool
    let hasWarnings: Bool

    var body: some View {
        if let image = MenuBarIcon.image(named: MenuBarIcon.name(
            for: screen, mounted: mounted, hasWarnings: hasWarnings)) {
            Image(nsImage: image)
        } else {
            Image(systemName: MenuBarIcon.fallbackSymbol(
                for: screen, mounted: mounted, hasWarnings: hasWarnings))
        }
    }
}
