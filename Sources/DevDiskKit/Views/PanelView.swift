import AppKit
import SwiftUI

/// Carries the measured height of the scrolling content up to the popover frame.
private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct PanelView: View {
    @ObservedObject private var language = LanguageStore.shared
    @EnvironmentObject var store: DiskStore
    @EnvironmentObject var updates: UpdateChecker

    /// Where this panel is being shown. The popover is a fixed-width card with a
    /// bounded body; the window is resizable and lets the body fill it; snapshot
    /// renders unwrapped because ImageRenderer cannot rasterize ScrollView contents
    /// (they come out blank).
    enum Presentation { case popover, window, snapshot }
    var presentation: Presentation = .popover

    @Environment(\.openWindow) private var openWindow
    @AppStorage(PanelSetting.version) private var showVersion = true

    /// Natural height of the scrolling content, measured so the popover can be sized
    /// to fit it.
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider1()

            // A menu bar popover is a card, not a page. Without a bound the connected
            // screen renders ~900pt tall and runs from the menu bar to the bottom of
            // the display. Only the middle scrolls; the header and the primary action
            // stay put so eject is always one click away.
            // Scroll only when the content actually needs it. Wrapping short
            // content in a fixed-height ScrollView left the popover window sized for
            // the tallest screen it had shown: the ejected card needed 308pt but the
            // window stayed 633pt, and SwiftUI centred the card in it — a transparent
            // band above and below, and the card sitting far below the menu bar.
            body(cap: presentation == .window ? UI.maxWindowBodyHeight
                                              : UI.maxScrollHeight)

            Divider1()
            actionFooter
            if showVersion || updates.available != nil {
                Divider1()
                VersionFooter(version: updates.currentVersion,
                              update: updates.available) { url in
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .frame(width: UI.width)
        // The content height is stateful because long screens switch to a bounded
        // ScrollView. Reset it before measuring a new screen; otherwise a short
        // ejected/disconnected screen can spend one layout pass inside the old
        // long-screen height and leave the popover host window oversized.
        .environment(\.locale, language.resolved.locale)
        .onChange(of: language.resolved) { _, _ in contentHeight = 0 }
        .onChange(of: store.activeScreen) { _, _ in
            contentHeight = 0
        }
    }

    /// Measures the content, and only introduces a scroll view once it exceeds the
    /// cap — so a short screen reports its true height and the window shrinks to it.
    @ViewBuilder private func body(cap: CGFloat) -> some View {
        let measured = VStack(alignment: .leading, spacing: 0) { screen }
            .background(GeometryReader { g in
                Color.clear.preference(key: ContentHeightKey.self, value: g.size.height)
            })

        Group {
            if presentation == .snapshot {
                // ImageRenderer cannot rasterize ScrollView contents.
                VStack(alignment: .leading, spacing: 0) { screen }
            } else if contentHeight > cap {
                ScrollView(.vertical) { measured }
                    .frame(height: cap)
                    .scrollBounceBehavior(.basedOnSize)
            } else {
                measured
            }
        }
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
    }

    @ViewBuilder private var screen: some View {
        switch store.activeScreen {
        case .connected:            ConnectedView()
        case .scan:                 ScanView()
        case .preview:              EjectPreviewView()
        case .settings:             SettingsPanel()
        case .drives:               DrivePickerView()
        case .ejecting:             EjectingView()
        case .ejected(_, let a, let d): EjectedView(apps: a, daemons: d)
        case .disconnected:         DisconnectedView()
        }
    }

    @ViewBuilder private var actionFooter: some View {
        switch store.activeScreen {
        case .connected:    ConnectedFooter()
        case .scan:         ScanFooter()
        case .preview:      EjectPreviewFooter()
        case .settings:     SettingsFooter()
        case .drives:       DrivePickerFooter()
        case .ejecting:     EjectingFooter()
        case .ejected:      EjectedFooter()
        case .disconnected: DisconnectedFooter()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            glyph
            Button {
                store.screen = store.screen == .drives
                    ? (store.isMounted ? .connected : .disconnected)
                    : .drives
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Circle().fill(dotColor).frame(width: 7, height: 7)
                        Text(title)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1).truncationMode(.middle)
                        // Only hint at switching when there is something to switch to.
                        if store.drives.count > 1 || store.screen == .drives {
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(store.operation.locksTarget)
            Spacer(minLength: 4)

            // .plain rather than .borderless/.link: those styles bridge to AppKit
            // controls, which ImageRenderer cannot rasterize for the snapshot check.
            // Appearance is identical.
            if store.screen == .connected || store.screen == .scan {
                IconButton(symbol: "arrow.clockwise", help: L("panelview.refresh")) { store.refresh(force: true) }
            }
            IconButton(symbol: "gearshape", help: L("panelview.settings")) {
                store.screen = store.screen == .settings
                    ? (store.isMounted ? .connected : .disconnected)
                    : .settings
            }

            .disabled(store.operation.locksTarget)

            if presentation == .popover {
                IconButton(symbol: "macwindow", help: L("panelview.open.in.window")) {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: DiskStore.mainWindowID)
                }
            }
            IconButton(symbol: "power", help: L("panelview.quit.devdisk")) { store.quit() }
                .disabled(store.operation.locksTarget)
        }
        .padding(.horizontal, UI.hPad)
        .padding(.top, 13)
        .padding(.bottom, 12)
    }

    private var glyph: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(active ? AnyShapeStyle(Color.accentColor.gradient)
                         : AnyShapeStyle(.quaternary))
            .frame(width: 34, height: 34)
            .overlay {
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(active ? Color.white : Color.secondary)
            }
    }

    private var active: Bool {
        switch store.activeScreen {
        case .disconnected, .ejected: return false
        default: return true
        }
    }

    private var title: String {
        store.snapshot?.volume.displayName
            ?? URL(fileURLWithPath: store.mountPoint).lastPathComponent
    }

    private var dotColor: Color {
        switch store.activeScreen {
        case .ejecting:               return .orange
        case .disconnected, .ejected: return .secondary
        default:                      return .green
        }
    }

    private var subtitle: String {
        if let e = store.lastError, store.screen == .connected { return e.text }
        switch store.activeScreen {
        case .ejecting:     return store.waitingForSystem ? L("ejectingview.waiting.for.macos.do.not.unplug") : L("panelview.preparing.to.eject")
        case .preview:      return L("panelview.review.the.eject.scope")
        case .ejected:      return L("panelview.unmounted.safe.to.unplug")
        case .disconnected: return L("panelview.disconnected")
        case .settings:
            return L("panelview.settings")
        case .drives:
            return store.drives.isEmpty ? L("panelview.no.external.drives") : L("panelview.choose.a.drive")
        case .scan:
            let n = store.occupancy?.holders.count ?? 0
            return L("panelview.scan.entries", n)
        case .connected:
            guard let s = store.snapshot else { return store.mountPoint }
            return [s.hardware.model, s.volume.filesystem]
                .compactMap { $0 }.joined(separator: " · ")
        }
    }
}

// MARK: - Blank states

struct BlankState: View {
    @ObservedObject private var language = LanguageStore.shared
    let symbol: String
    var symbolColor: Color = .secondary
    var symbolBackground: Color = .clear
    let title: String
    let message: AnyView

    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 11)
                .fill(symbolBackground == .clear
                      ? AnyShapeStyle(.quaternary)
                      : AnyShapeStyle(symbolBackground.opacity(0.15)))
                .frame(width: 46, height: 46)
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: 20))
                        .foregroundStyle(symbolColor)
                }
                .padding(.bottom, 12)

            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .padding(.bottom, 5)

            message
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 26)
        .padding(.bottom, 24)
    }
}

struct DisconnectedView: View {
    @ObservedObject private var language = LanguageStore.shared
    @EnvironmentObject var store: DiskStore

    var body: some View {
        VStack(spacing: 0) {
            BlankState(
                symbol: "externaldrive.badge.xmark",
                title: L("panelview.is.disconnected", name),
                message: AnyView(
                    VStack(spacing: 3) {
                        Text(L("panelview.reconnect.it.to.resume.automatically"))
                        // The dangling ~/Library/Android/sdk symlink is the real trap:
                        // Studio may decide the SDK is missing and re-download it onto
                        // the internal disk.
                        Text(L("panelview.do.not.open.android.studio.now.it.may"))
                            .foregroundStyle(.orange)
                    }
                )
            )
        }
    }

    private var name: String {
        URL(fileURLWithPath: store.mountPoint).lastPathComponent
    }
}

/// Pinned footer for the disconnected screen — last eject result, or the path
/// being watched.
struct DisconnectedFooter: View {
    @ObservedObject private var language = LanguageStore.shared
    @EnvironmentObject var store: DiskStore

    var body: some View {
        HStack {
            Spacer()
            Text(store.lastEjectSummary.map { L("panelview.last.eject", $0) } ?? store.mountPoint)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.vertical, 10)
    }
}

struct EjectedView: View {
    @ObservedObject private var language = LanguageStore.shared
    @EnvironmentObject var store: DiskStore
    let apps: Int
    let daemons: Int

    var body: some View {
        VStack(spacing: 0) {
            BlankState(
                symbol: "checkmark.circle",
                symbolColor: .green,
                symbolBackground: .green,
                title: L("panelview.safe.to.unplug"),
                message: AnyView(
                    VStack(spacing: 3) {
                        Text(L("panelview.physical.disk.offline.related.volumes.unmounted"))
                        if let s = store.lastEjectSummary { Text(s) }
                    }
                )
            )
        }
    }
}

/// Pinned action area after a successful eject.
struct EjectedFooter: View {
    @ObservedObject private var language = LanguageStore.shared
    @EnvironmentObject var store: DiskStore

    var body: some View {
        PrimaryButton(title: L("panelview.ok")) { store.refresh(force: true) }
            .padding(.horizontal, UI.hPad)
            .padding(.vertical, 11)
    }
}
