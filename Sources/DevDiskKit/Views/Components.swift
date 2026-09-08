import AppKit
import SwiftUI

// MARK: - Design tokens

enum UI {
    static let width: CGFloat = 380

    /// Upper bound on the scrolling middle, derived from the display so the popover
    /// stays a card on a 13" laptop as well as a 32" monitor. The 180pt reserve
    /// covers the header, the action area and the version line.
    @MainActor static var maxScrollHeight: CGFloat {
        let available = NSScreen.main?.visibleFrame.height ?? 800
        return min(520, max(320, available - 180))
    }

    /// The window may grow taller than the popover, but still has to fit on screen.
    @MainActor static var maxWindowBodyHeight: CGFloat {
        let available = NSScreen.main?.visibleFrame.height ?? 900
        return max(320, available - 220)
    }
    static let hPad: CGFloat = 14
    static let vPad: CGFloat = 12

    /// macOS system colours, legible in both appearances.
    static let segmentPalette: [Color] = [
        Color(red: 0.04, green: 0.52, blue: 1.00),   // blue
        Color(red: 0.75, green: 0.35, blue: 0.95),   // purple
        Color(red: 1.00, green: 0.62, blue: 0.04),   // orange
        Color(red: 0.19, green: 0.82, blue: 0.35),   // green
        Color(red: 1.00, green: 0.22, blue: 0.37),   // pink
        Color(red: 0.00, green: 0.78, blue: 0.75),   // teal
    ]

    static func segmentColor(_ i: Int) -> Color {
        segmentPalette[i % segmentPalette.count]
    }
}

extension CheckSeverity {
    var color: Color {
        switch self {
        case .ok:       return .green
        case .warning:  return .orange
        case .critical: return .red
        }
    }

    var symbol: String {
        switch self {
        case .ok:       return "checkmark.circle"
        case .warning:  return "exclamationmark.triangle"
        case .critical: return "exclamationmark.circle"
        }
    }
}

// MARK: - Section scaffolding

struct SectionHeader: View {
    let title: String
    var aside: String?
    var asideColor: Color = .secondary

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(.tertiary)
            Spacer()
            if let aside {
                Text(aside)
                    .font(.system(size: 10.5))
                    .foregroundStyle(asideColor)
            }
        }
    }
}

struct PanelSection<Content: View>: View {
    var title: String?
    var aside: String?
    var asideColor: Color = .secondary
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let title {
                SectionHeader(title: title, aside: aside, asideColor: asideColor)
            }
            content
        }
        .padding(.horizontal, UI.hPad)
        .padding(.vertical, UI.vPad)
    }
}

// MARK: - Key/value grid

/// Generic over its trailing content so a row can hold a pill or a gauge; a plain
/// string value gets the convenience initializer below.
struct KeyValueRow<Trailing: View>: View {
    let key: String
    let trailing: Trailing

    init(_ key: String, @ViewBuilder trailing: () -> Trailing) {
        self.key = key
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(key)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            trailing
        }
    }
}

extension KeyValueRow where Trailing == Text {
    init(_ key: String, _ value: String?) {
        self.init(key) {
            Text(value ?? "—")
                .font(.system(size: 11.5))
                .monospacedDigit()
        }
    }
}

struct Pill: View {
    let text: String
    var color: Color = .green

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - Capacity

/// Two tiers: a true-scale bar for overall capacity, and a normalised breakdown of
/// the used portion. On a 97%-empty disk a single total-scale bar would compress
/// every directory into an unreadable sliver.
struct CapacityBar: View {
    let volume: VolumeInfo
    let directories: [DirectoryUsage]
    let loading: Bool

    // Shared with Settings: toggling here is remembered, and the settings window
    // and the panel stay in sync because both read the same UserDefaults key.
    @AppStorage(PanelSetting.breakdownOpen) private var expanded = false

    private var accounted: Int64 { directories.reduce(0) { $0 + $1.bytes } }
    private var other: Int64 { max(0, volume.usedBytes - accounted) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Fmt.bytes(volume.freeBytes))
                    .font(.system(size: 23, weight: .semibold))
                    .monospacedDigit()
                Text("可用 · 共 \(Fmt.bytes(volume.totalBytes))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 9)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(Color.accentColor)
                        .frame(width: max(2, geo.size.width * volume.usedFraction))
                }
            }
            .frame(height: 5)
            .padding(.bottom, 4)

            HStack {
                Text("已用 \(Fmt.bytes(volume.usedBytes))（\(pct)）")
                Spacer()
                Text(volume.filesystem)
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)

            if loading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在统计各目录占用…")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(.top, 12)
            } else if !directories.isEmpty {
                // Collapsed by default: the headline is how much room is left, and an
                // always-open six-row legend was a big part of what made the panel
                // taller than the screen.
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        Text("已用空间构成")
                        Spacer()
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 12)

                if expanded { breakdown }
            }
        }
    }

    private var pct: String {
        String(format: "%.1f%%", volume.usedFraction * 100)
    }

    private var segments: [(name: String, bytes: Int64, color: Color)] {
        var s = directories.enumerated().map {
            ($0.element.name, $0.element.bytes, UI.segmentColor($0.offset))
        }
        if other > 0 { s.append(("其他", other, Color.secondary)) }
        return s
    }

    @ViewBuilder private var breakdown: some View {
        let total = max(1, segments.reduce(0) { $0 + $1.bytes })

        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(segments, id: \.name) { seg in
                        Rectangle().fill(seg.color)
                            .frame(width: max(1, geo.size.width
                                   * CGFloat(seg.bytes) / CGFloat(total)))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 9)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14),
                                GridItem(.flexible())],
                      alignment: .leading, spacing: 4) {
                ForEach(segments, id: \.name) { seg in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(seg.color).frame(width: 8, height: 8)
                        Text(seg.name).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 4)
                        Text(Fmt.bytes(seg.bytes))
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(.system(size: 11.5))
                }
            }
        }
        .padding(.top, 10)
    }
}

// MARK: - Configuration check row

struct CheckRow: View {
    let check: ConfigCheck
    let onCopy: (String) -> Void
    let onOpen: (String) -> Void

    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: check.severity.symbol)
                .font(.system(size: 12))
                .foregroundStyle(check.severity.color)
                .frame(width: 14)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(check.title).font(.system(size: 12, weight: .medium))
                Text(check.detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 6)

            // Fixes all need sudo, so the app hands over the command instead of
            // running it. A menu-bar agent holding root is not worth the convenience.
            if let cmd = check.fixCommand {
                Button(copied ? "已复制" : "复制命令") {
                    onCopy(cmd)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .font(.system(size: 10))
                .foregroundStyle(copied ? Color.green : Color.secondary)
            } else if let url = check.settingsURL {
                Button("前往") { onOpen(url) }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .font(.system(size: 10))
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Primary button

struct PrimaryButton: View {
    let title: String
    var symbol: String?
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol) }
                Text(title).fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(role == .destructive ? .red : .accentColor)
    }
}

/// Small icon button. Uses .plain so it renders identically everywhere, including
/// under ImageRenderer.
struct IconButton: View {
    let symbol: String
    var help: String = ""
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(hovering ? AnyShapeStyle(.quaternary)
                                     : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Text button that looks like a link but does not bridge to an AppKit control.
struct LinkButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Shown when an eject stopped, until the user dismisses it or ejects again.
/// Without this the panel simply returned to normal and the click looked ignored.
struct EjectFailureBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text("未能弹出")
                    .font(.system(size: 11.5, weight: .semibold))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 4)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, UI.hPad)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.12))
    }
}

struct Divider1: View {
    var body: some View {
        Rectangle().fill(.separator).frame(height: 1)
    }
}

// MARK: - Version / update footer

/// Always-visible footer carrying the running version, and the update notice when
/// one is available. Clicking opens the release page — the app never replaces
/// itself, because an ad-hoc signed build swapped in behind the user's back would
/// just get blocked by Gatekeeper with no explanation.
struct VersionFooter: View {
    let version: String
    let update: Release?
    let onOpen: (URL) -> Void

    var body: some View {
        HStack(spacing: 5) {
            Spacer()
            Text("DevDisk \(version)")
                .foregroundStyle(.tertiary)

            if let update {
                Text("·").foregroundStyle(.tertiary)
                Button {
                    onOpen(update.url)
                } label: {
                    HStack(spacing: 3) {
                        Text("有新版本 \(update.version.hasPrefix("v") ? String(update.version.dropFirst()) : update.version)")
                        Image(systemName: "arrow.down.circle")
                    }
                    .foregroundStyle(Color.accentColor)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .font(.system(size: 10.5))
        .padding(.vertical, 7)
    }
}
