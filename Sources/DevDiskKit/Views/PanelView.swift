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
            switch presentation {
            case .popover:
                // A ScrollView has no intrinsic content height, so `maxHeight` alone
                // gives MenuBarExtra nothing to size against and the whole body
                // collapses — leaving just the header and the eject button. The
                // Window scene hid this because defaultSize forced a height.
                // Measure the content and pin the frame to it, capped.
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) { screen }
                        .background(GeometryReader { g in
                            Color.clear.preference(key: ContentHeightKey.self,
                                                   value: g.size.height)
                        })
                }
                .frame(height: min(max(contentHeight, 60), UI.maxScrollHeight))
                .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
                .scrollBounceBehavior(.basedOnSize)
            case .window:
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) { screen }
                }
                .frame(maxHeight: .infinity)
            case .snapshot:
                VStack(alignment: .leading, spacing: 0) { screen }
            }

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
        .frame(width: presentation == .window ? nil : UI.width)
        .frame(minWidth: presentation == .window ? UI.width : nil,
               maxWidth: presentation == .window ? .infinity : nil,
               maxHeight: presentation == .window ? .infinity : nil)
    }

    @ViewBuilder private var screen: some View {
        switch store.screen {
        case .connected:            ConnectedView()
        case .scan:                 ScanView()
        case .settings:             SettingsPanel()
        case .ejecting:             EjectingView()
        case .ejected(_, let a, let d): EjectedView(apps: a, daemons: d)
        case .disconnected:         DisconnectedView()
        }
    }

    @ViewBuilder private var actionFooter: some View {
        switch store.screen {
        case .connected:    ConnectedFooter()
        case .scan:         ScanFooter()
        case .settings:     SettingsFooter()
        case .ejecting:     EjectingFooter()
        case .ejected:      EjectedFooter()
        case .disconnected: DisconnectedFooter()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            glyph
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Circle().fill(dotColor).frame(width: 7, height: 7)
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 4)

            // .plain rather than .borderless/.link: those styles bridge to AppKit
            // controls, which ImageRenderer cannot rasterize for the snapshot check.
            // Appearance is identical.
            if store.screen == .connected || store.screen == .scan {
                IconButton(symbol: "arrow.clockwise", help: "刷新") { store.refresh() }
            }
            IconButton(symbol: "gearshape", help: "设置") {
                store.screen = store.screen == .settings
                    ? (store.isMounted ? .connected : .disconnected)
                    : .settings
            }

            if presentation == .popover {
                IconButton(symbol: "macwindow", help: "在窗口中打开") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: DiskStore.mainWindowID)
                }
            }
            IconButton(symbol: "power", help: "退出 DevDisk") { store.quit() }
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
        switch store.screen {
        case .disconnected, .ejected: return false
        default: return true
        }
    }

    private var title: String {
        store.snapshot?.volume.name
            ?? URL(fileURLWithPath: store.mountPoint).lastPathComponent
    }

    private var dotColor: Color {
        switch store.screen {
        case .ejecting:               return .orange
        case .disconnected, .ejected: return .secondary
        default:                      return .green
        }
    }

    private var subtitle: String {
        if let e = store.lastError, store.screen == .connected { return e }
        switch store.screen {
        case .ejecting:     return "正在卸载…"
        case .ejected:      return "已卸载 · 可安全拔线"
        case .disconnected: return "未连接"
        case .settings:
            return "设置"
        case .scan:
            let n = store.occupancy?.holders.count ?? 0
            return "\(n) 个进程正在使用"
        case .connected:
            guard let s = store.snapshot else { return store.mountPoint }
            return [s.hardware.model, s.volume.filesystem]
                .compactMap { $0 }.joined(separator: " · ")
        }
    }
}

// MARK: - Blank states

struct BlankState: View {
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
    @EnvironmentObject var store: DiskStore

    var body: some View {
        VStack(spacing: 0) {
            BlankState(
                symbol: "externaldrive.badge.xmark",
                title: "\(name) 未连接",
                message: AnyView(
                    VStack(spacing: 3) {
                        Text("插上后自动恢复。")
                        // The dangling ~/Library/Android/sdk symlink is the real trap:
                        // Studio may decide the SDK is missing and re-download it onto
                        // the internal disk.
                        Text("此时请勿打开 Android Studio——它可能在内置盘重建 SDK。")
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
    @EnvironmentObject var store: DiskStore

    var body: some View {
        HStack {
            Spacer()
            Text(store.lastEjectSummary.map { "上次弹出：\($0)" } ?? store.mountPoint)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.vertical, 10)
    }
}

struct EjectedView: View {
    @EnvironmentObject var store: DiskStore
    let apps: Int
    let daemons: Int

    var body: some View {
        VStack(spacing: 0) {
            BlankState(
                symbol: "checkmark.circle",
                symbolColor: .green,
                symbolBackground: .green,
                title: "可以安全拔线",
                message: AnyView(
                    VStack(spacing: 3) {
                        Text("卷已卸载，无残留挂载点。")
                        if let s = store.lastEjectSummary { Text(s) }
                    }
                )
            )
        }
    }
}

/// Pinned action area after a successful eject.
struct EjectedFooter: View {
    @EnvironmentObject var store: DiskStore

    var body: some View {
        PrimaryButton(title: "好") { store.refresh() }
            .padding(.horizontal, UI.hPad)
            .padding(.vertical, 11)
    }
}
