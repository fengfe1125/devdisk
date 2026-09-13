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
        case .unknown: return .orange
        case .notApplicable: return .secondary
        }
    }

    var symbol: String {
        switch self {
        case .ok:       return "checkmark.circle"
        case .warning:  return "exclamationmark.triangle"
        case .critical: return "exclamationmark.circle"
        case .unknown: return "questionmark.circle"
        case .notApplicable: return "minus.circle"
        }
    }
}

// MARK: - Section scaffolding

struct SectionHeader: View {
    @ObservedObject private var language = LanguageStore.shared
    let title: String
    var aside: String?
    var asideColor: Color = .secondary

    var body: some View {
        ViewThatFits(in: .horizontal) {
            header(horizontal: true).fixedSize(horizontal: true, vertical: false)
            header(horizontal: false)
        }
    }

    private func header(horizontal: Bool) -> some View {
        let layout = horizontal ? AnyLayout(HStackLayout(alignment: .firstTextBaseline))
                                : AnyLayout(VStackLayout(alignment: .leading, spacing: 3))
        return layout {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(.tertiary)
            if horizontal { Spacer(minLength: 8) }
            if let aside {
                Text(aside)
                    .font(.system(size: 10.5))
                    .foregroundStyle(asideColor)
            }
        }
    }
}

struct PanelSection<Content: View>: View {
    @ObservedObject private var language = LanguageStore.shared
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
    @ObservedObject private var language = LanguageStore.shared
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
    @ObservedObject private var language = LanguageStore.shared
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
    @ObservedObject private var language = LanguageStore.shared
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
                Text(L("components.free.total", Fmt.bytes(volume.totalBytes)))
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
                Text(L("components.used", Fmt.bytes(volume.usedBytes), pct))
                Spacer()
                Text(volume.filesystem)
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)

            if loading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L("components.calculating.folder.usage"))
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
                        Text(L("components.used.space.breakdown"))
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

    /// The palette has six colours, and a bar this narrow cannot show more than a
    /// handful of slices anyway — a camera card with 14 top-level folders produced
    /// repeated colours and a bar that overflowed its track.
    static let maxSegments = 6

    private var segments: [(name: String, bytes: Int64, color: Color)] {
        let sorted = directories.sorted { $0.bytes > $1.bytes }
        var s = sorted.prefix(Self.maxSegments).enumerated().map {
            ($0.element.name, $0.element.bytes, UI.segmentColor($0.offset))
        }
        let rest = sorted.dropFirst(Self.maxSegments).reduce(0) { $0 + $1.bytes } + other
        if rest > 0 { s.append((L("components.other"), rest, Color.secondary)) }
        return s
    }

    /// Segment widths that always add up to exactly `available`.
    ///
    /// The old version multiplied each share by the track width and then applied
    /// `max(1, …)` per segment, with 1pt of spacing between them. With one segment
    /// taking 99.6% and fourteen tiny ones, the minimums and gaps pushed the total
    /// past the track and `clipShape` silently cut the tail off — the bar looked
    /// truncated. Here the floor is only applied when every segment can have one,
    /// and any excess comes out of the largest slice.
    static func segmentWidths(bytes: [Int64], available: CGFloat,
                              minWidth: CGFloat = 2) -> [CGFloat] {
        guard !bytes.isEmpty else { return [] }
        guard available > 0 else { return Array(repeating: 0, count: bytes.count) }

        let total = CGFloat(max(1, bytes.reduce(0, +)))
        var w = bytes.map { available * CGFloat(max(0, $0)) / total }

        if minWidth * CGFloat(bytes.count) <= available {
            for i in w.indices where w[i] < minWidth { w[i] = minWidth }
            let overflow = w.reduce(0, +) - available
            if overflow > 0, let biggest = w.indices.max(by: { w[$0] < w[$1] }) {
                w[biggest] = max(minWidth, w[biggest] - overflow)
            }
        }

        // Absorb rounding drift so the bar fills its track exactly.
        let sum = w.reduce(0, +)
        if sum > 0 { w = w.map { $0 * available / sum } }
        return w
    }

    @ViewBuilder private var breakdown: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                // No inter-segment spacing: gaps were another source of overflow, and
                // adjacent colours read fine without them.
                let widths = Self.segmentWidths(bytes: segments.map(\.bytes),
                                                available: geo.size.width)
                HStack(spacing: 0) {
                    ForEach(Array(segments.indices), id: \.self) { i in
                        Rectangle()
                            .fill(segments[i].color)
                            .frame(width: widths[i])
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
    @ObservedObject private var language = LanguageStore.shared
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
                Button(copied ? L("components.copied") : L("components.copy.command")) {
                    onCopy(cmd)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .font(.system(size: 10))
                .foregroundStyle(copied ? Color.green : Color.secondary)
            } else if let url = check.settingsURL {
                Button(L("components.open")) { onOpen(url) }
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
    @ObservedObject private var language = LanguageStore.shared
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
    @ObservedObject private var language = LanguageStore.shared
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
    @ObservedObject private var language = LanguageStore.shared
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
    @ObservedObject private var language = LanguageStore.shared
    let message: Message
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(L("components.could.not.eject"))
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
    @ObservedObject private var language = LanguageStore.shared
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
    @ObservedObject private var language = LanguageStore.shared
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
                        Text(L("components.version.available", update.version.hasPrefix("v") ? String(update.version.dropFirst()) : update.version))
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
