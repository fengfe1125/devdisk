import SwiftUI

/// Detection results, grouped by how certain we are about each holder. The system
/// group is inferred rather than scanned — an unprivileged lsof cannot see other
/// users' handles — and the footer says so plainly, because "nobody is using it"
/// followed by a failed eject is the worst outcome this screen could produce.
struct ScanView: View {
    @ObservedObject private var language = LanguageStore.shared
    @EnvironmentObject var store: DiskStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            subhead
            meta
            if let report = store.occupancy, !report.issues.isEmpty {
                Text(L("scanview.scan.incomplete") + report.issues.joined(separator: M("issue.separator")))
                    .font(.caption).foregroundStyle(.orange).padding(.horizontal, UI.hPad).padding(.bottom, 10)
            }
            Divider1()

            group(kind: .guiApp,
                  title: L("scanview.your.decision.needed"), color: .orange,
                  note: L("scanview.eject.sends.a.quit.request.each.app.shows"))

            group(kind: .daemon,
                  title: L("scanview.can.stop.after.confirmation"), color: .secondary,
                  note: L("scanview.approved.background.services.may.still.be.working.no"))

            group(kind: .manual, title: L("ejectpreviewview.handle.manually"), color: .orange,
                  note: L("scanview.emulators.foreground.builds.and.processes.with.unverified.identities"))

            group(kind: .system,
                  title: L("scanview.system.processes"), color: .secondary,
                  note: L("scanview.devdisk.does.not.handle.these.diskutil.eject.asks"))

            permissionNote
        }
    }

    // MARK: - Header

    private var subhead: some View {
        HStack(spacing: 8) {
            Button {
                store.screen = .connected
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                    Text(L("scanview.back"))
                }
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(L("connectedview.what.s.using.the.drive"))
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)

            Spacer(minLength: 4)

            Button {
                store.fullScan()
            } label: {
                if store.occupancyScanning {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text(L("scanview.scanning"))
                    }
                } else {
                    Text(L("ejectpreviewview.scan.again"))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .font(.system(size: 10.5))
            .disabled(store.occupancyScanning)
        }
        .padding(.horizontal, UI.hPad)
        .padding(.top, 11)
        .padding(.bottom, 10)
    }

    @ViewBuilder private var meta: some View {
        if let r = store.occupancy {
            HStack(spacing: 6) {
                Text(r.scanDepth.label)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("·")
                Text(Self.relative(r.scannedAt))
                if r.state == .complete, let n = r.openFilesFound {
                    Text("·")
                    Text(n == 0
                         ? L("scanview.no.open.files.found.for.your.processes.s", Message.number(r.duration, decimals: 1))
                         : L("scanview.open.files.found.s", n, Message.number(r.duration, decimals: 1)))
                }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, UI.hPad)
            .padding(.bottom, 10)
        }
    }

    static func relative(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return L("scanview.s.ago", max(0, s)) }
        if s < 3600 { return L("scanview.min.ago", s / 60) }
        return L("scanview.hr.ago", s / 3600)
    }

    // MARK: - Groups

    @ViewBuilder
    private func group(kind: HolderKind, title: String, color: Color, note: String) -> some View {
        let holders = store.occupancy?.holders(kind) ?? []
        if !holders.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.system(size: 10.5, weight: .semibold))
                        .kerning(0.4)
                        .foregroundStyle(color)
                    Spacer()
                    Text(L("scanview.", holders.count))
                        .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
                .padding(.bottom, 5)

                Text(note)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)

                ForEach(holders) { HolderRow(holder: $0) }
            }
            .padding(.horizontal, UI.hPad)
            .padding(.top, 10)
            .padding(.bottom, 12)

            Divider1()
        }
    }

    // MARK: - Permission note

    private var permissionNote: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(L("scanview.standard.permissions.show.only.your.own.processes"))
                    .font(.system(size: 10.5, weight: .semibold))
                Text(L("scanview.system.processes.above.are.inferred.from.the.mounted"))
                    .font(.system(size: 10.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.orange.opacity(0.28))
        }
        .padding(.horizontal, UI.hPad)
        .padding(.vertical, 12)
    }
}

/// Pinned action area for the detection screen.
struct ScanFooter: View {
    @ObservedObject private var language = LanguageStore.shared
    @EnvironmentObject var store: DiskStore

    var body: some View {
        PrimaryButton(title: L("scanview.preflight.and.eject"), symbol: "eject.fill") { store.eject() }
            .padding(.horizontal, UI.hPad)
            .padding(.vertical, 11)
    }
}

// MARK: - One holder

struct HolderRow: View {
    @ObservedObject private var language = LanguageStore.shared
    let holder: Holder
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(holder.displayName)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if !holder.pids.isEmpty || !holder.user.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Text(trailing)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.system(size: 11.5))
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(holder.sampleFiles, id: \.self) { f in
                        Text(f)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let n = holder.openFileCount, n > holder.sampleFiles.count {
                        Text(L("scanview.more", Fmt.count(n - holder.sampleFiles.count)))
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    if let reason = holder.inferenceReason {
                        Text(reason)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.top, 7).padding(.bottom, 8)
                .overlay(alignment: .top) { Divider1() }
            }
        }
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7).strokeBorder(.separator)
        }
        .padding(.bottom, 5)
    }

    private var subtitle: String {
        let pids = holder.pids.map(String.init).joined(separator: ", ")
        return [pids.isEmpty ? nil : pids, holder.user.isEmpty ? nil : holder.user]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var trailing: String {
        if let n = holder.openFileCount { return L("scanview.files", n) }
        return holder.kind == .system ? L("scanview.inferred") : L("connectedview.possible.match")
    }
}
