import SwiftUI

/// Scrollable body only. The eject button lives in `ConnectedFooter`, pinned by
/// PanelView, so the primary action never scrolls out of reach.
///
/// Which sections appear is the user's choice, made in Settings — guessing at the
/// right density produced either a panel taller than the screen or one too sparse
/// to be worth opening.
struct ConnectedView: View {
    @ObservedObject private var language = LanguageStore.shared
    @EnvironmentObject var store: DiskStore

    @AppStorage(PanelSetting.capacity)       private var showCapacity = true
    @AppStorage(PanelSetting.hardware)       private var showHardware = true
    @AppStorage(PanelSetting.hardwareDetail) private var hardwareDetailRaw = HardwareDetail.standard.rawValue
    @AppStorage(PanelSetting.checks)         private var showChecks = true
    @AppStorage(PanelSetting.checksAllRows)  private var checksAllRows = false
    @AppStorage(PanelSetting.occupancy)      private var showOccupancy = true
    @AppStorage(PanelSetting.volume)         private var showVolume = false

    private var detail: HardwareDetail {
        HardwareDetail(rawValue: hardwareDetailRaw) ?? .standard
    }

    var body: some View {
        if let snap = store.snapshot {
            VStack(alignment: .leading, spacing: 0) {
                if let failure = store.ejectFailure {
                    EjectFailureBanner(message: failure) { store.dismissEjectFailure() }
                    Divider1()
                }
                let sections = visibleSections(snap)
                if sections.isEmpty {
                    allHidden
                } else {
                    ForEach(Array(sections.enumerated()), id: \.offset) { i, piece in
                        if i > 0 { Divider1() }
                        piece.view
                    }
                }
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(store.lastError?.text ?? L("connectedview.reading"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        }
    }

    private struct Piece { let view: AnyView }

    private func visibleSections(_ snap: DiskSnapshot) -> [Piece] {
        var out: [Piece] = []
        if showCapacity  { out.append(Piece(view: AnyView(capacity(snap)))) }
        if showHardware  { out.append(Piece(view: AnyView(hardware(snap)))) }
        if showVolume    { out.append(Piece(view: AnyView(volumeInfo(snap)))) }
        if showChecks    { out.append(Piece(view: AnyView(checks(snap)))) }
        if showOccupancy { out.append(Piece(view: AnyView(occupancy(snap)))) }
        return out
    }

    private var allHidden: some View {
        VStack(spacing: 6) {
            Text(L("connectedview.all.sections.are.hidden"))
                .font(.system(size: 12, weight: .medium))
            Text(L("connectedview.choose.what.to.show.in.settings"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }

    // MARK: - Capacity

    private func capacity(_ snap: DiskSnapshot) -> some View {
        PanelSection {
            CapacityBar(volume: snap.volume,
                        directories: store.directories,
                        loading: store.directoriesLoading)
            if let issue = store.directoryIssue { Text(L("connectedview.folder.usage.incomplete") + issue).font(.caption).foregroundStyle(.orange) }
        }
    }

    // MARK: - Hardware & health

    @ViewBuilder private func hardware(_ snap: DiskSnapshot) -> some View {
        PanelSection(title: L("connectedview.hardware.health"),
                aside: snap.hardware.firmware.map { L("connectedview.firmware", $0) }) {
            VStack(spacing: 6) {
                if let link = snap.hardware.linkDescription {
                    KeyValueRow(L("connectedview.interface"), link)
                }
                if let s = snap.hardware.smartStatus {
                    KeyValueRow("SMART") {
                        Pill(text: s, color: s == "Verified" ? .green : .red)
                    }
                }
                if let t = snap.hardware.trimSupported {
                    KeyValueRow("TRIM") {
                        Pill(text: t ? L("connectedview.enabled") : L("connectedview.disabled"), color: t ? .green : .orange)
                    }
                }

                if detail != .basic {
                    if let h = snap.health {
                        standardHealth(h)
                        if detail == .full { fullHealth(h) }
                    } else if let why = snap.healthUnavailableReason {
                        // Never show blanks — say why the detail is missing.
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "info.circle").font(.system(size: 10))
                            Text(why).fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                    }
                }
            }
        }
    }

    @ViewBuilder private func standardHealth(_ h: SmartHealth) -> some View {
        if let w = h.bytesWritten { KeyValueRow(L("connectedview.total.written"), Fmt.bytes(w)) }
        if let life = h.lifeRemaining {
            KeyValueRow(L("connectedview.life.left")) {
                HStack(spacing: 7) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary)
                            Capsule()
                                .fill(life > 20 ? Color.green : Color.orange)
                                .frame(width: geo.size.width * CGFloat(life) / 100)
                        }
                    }
                    .frame(width: 54, height: 5)
                    Text("\(life)%").font(.system(size: 11.5)).monospacedDigit()
                }
            }
        }
        if let hrs = h.powerOnHours { KeyValueRow(L("connectedview.power.on.time"), Fmt.hours(hrs)) }
        if let temp = h.temperatureC {
            KeyValueRow(L("connectedview.temperature")) {
                Text("\(temp) °C")
                    .font(.system(size: 11.5)).monospacedDigit()
                    .foregroundStyle(temp >= 70 ? Color.orange : Color.primary)
            }
        }
    }

    @ViewBuilder private func fullHealth(_ h: SmartHealth) -> some View {
        if let r = h.bytesRead { KeyValueRow(L("connectedview.total.read"), Fmt.bytes(r)) }
        if let spare = h.availableSpare { KeyValueRow(L("connectedview.available.spare"), "\(spare)%") }
        if let c = h.powerCycles { KeyValueRow(L("connectedview.power.cycles"), L("connectedview.", c)) }
        if let u = h.unsafeShutdowns {
            KeyValueRow(L("connectedview.unsafe.shutdowns")) {
                Text(L("connectedview.", u))
                    .font(.system(size: 11.5)).monospacedDigit()
                    .foregroundStyle(h.allShutdownsUnsafe ? Color.orange : Color.primary)
            }
        }
        if let e = h.mediaErrors {
            KeyValueRow(L("connectedview.media.errors")) {
                Text("\(e)")
                    .font(.system(size: 11.5)).monospacedDigit()
                    .foregroundStyle(e > 0 ? Color.red : Color.primary)
            }
        }
    }

    // MARK: - Volume

    private func volumeInfo(_ snap: DiskSnapshot) -> some View {
        let v = snap.volume
        return PanelSection(title: L("connectedview.volume.info"), aside: v.deviceIdentifier) {
            VStack(spacing: 6) {
                KeyValueRow(L("connectedview.mount.point"), v.mountPoint)
                KeyValueRow(L("connectedview.file.system"), v.filesystem)
                KeyValueRow(L("connectedview.type"), v.isExternal ? L("connectedview.external") : L("connectedview.internal"))
                if let p = v.physicalDisk { KeyValueRow(L("connectedview.physical.disk"), "/dev/" + p) }
                if let s = snap.hardware.serial { KeyValueRow(L("connectedview.serial.number"), s) }
                KeyValueRow(L("connectedview.volume.uuid")) {
                    Text(v.volumeUUID)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }

    // MARK: - Configuration checks

    @ViewBuilder private func checks(_ snap: DiskSnapshot) -> some View {
        let warnings = snap.warningCount
        PanelSection(title: L("connectedview.configuration"),
                aside: warnings > 0 ? L("connectedview.needs.attention.unknown", warnings) : L("connectedview.completed.checks.passed"),
                asideColor: warnings > 0 ? .orange : .green) {
            let problems = snap.checks.filter { $0.severity != .ok }
            let passing = snap.checks.filter { $0.severity == .ok }

            VStack(spacing: 0) {
                ForEach(problems) { check in
                    CheckRow(check: check,
                             onCopy: store.copy,
                             onOpen: store.openSettings)
                }

                if checksAllRows {
                    ForEach(passing) { check in
                        CheckRow(check: check,
                                 onCopy: store.copy,
                                 onOpen: store.openSettings)
                    }
                } else if !passing.isEmpty {
                    // Collapsed to one line by default; seven expanded rows were a
                    // big part of what made the panel taller than the screen.
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(.green)
                            .frame(width: 14)
                        Text(passing.map(\.title).joined(separator: M("list.separator")))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 5)
                }
            }
        }
    }

    // MARK: - Occupancy summary

    @ViewBuilder private func occupancy(_ snap: DiskSnapshot) -> some View {
        let report = store.occupancy
        let mine = report?.mine ?? []
        let system = report?.holders(.system) ?? []

        PanelSection(title: L("connectedview.what.s.using.the.drive"),
                aside: report?.scanDepth == .quick ? L("connectedview.possible.matches.unverified") : L("connectedview.your.processes.limited.system.visibility", mine.count)) {
            VStack(spacing: 1) {
                ForEach(mine) { h in
                    HStack(spacing: 8) {
                        Text(h.displayName).lineLimit(1)
                        Spacer(minLength: 6)
                        if let pid = h.pids.first {
                            Text(String(pid))
                                .font(.system(size: 10.5)).monospacedDigit()
                                .foregroundStyle(.tertiary)
                        }
                        Text(report?.scanDepth == .quick ? L("connectedview.possible.match") : h.kind == .guiApp ? L("connectedview.confirm.quit") : h.kind == .daemon ? L("connectedview.confirm.stop") : L("connectedview.handle.manually"))
                            .font(.system(size: 9.5, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(
                                (h.kind == .guiApp ? Color.orange : Color.secondary)
                                    .opacity(0.18),
                                in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(h.kind == .guiApp ? .orange : .secondary)
                    }
                    .font(.system(size: 11.5))
                    .padding(.vertical, 3)
                }

                if !system.isEmpty {
                    HStack(spacing: 8) {
                        Text(system.map(\.name).joined(separator: L("list.separator")))
                            .lineLimit(1).foregroundStyle(.secondary)
                        Spacer(minLength: 6)
                        Text(L("connectedview.system"))
                            .font(.system(size: 9.5, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(Color.secondary.opacity(0.15),
                                        in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11.5))
                    .padding(.vertical, 3)
                }

                if let report, !report.issues.isEmpty {
                    Text(report.issues.joined(separator: M("issue.separator"))).font(.caption).foregroundStyle(.orange)
                }
                if mine.isEmpty && system.isEmpty {
                    Text(report == nil || report?.state != .complete ? L("connectedview.open.file.status.unknown") : report?.scanDepth == .quick ? L("connectedview.no.candidates.found.a.full.preflight.will.run") : L("connectedview.no.open.files.found.for.the.current.user"))
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 3)
                }
            }

            LinkButton(title: L("connectedview.view.details.and.scan.again")) { store.screen = .scan }
        }
    }
}

/// Pinned action area for the connected screen.
struct ConnectedFooter: View {
    @ObservedObject private var language = LanguageStore.shared
    @EnvironmentObject var store: DiskStore

    var body: some View {
        VStack(spacing: 7) {
            PrimaryButton(title: L("connectedview.safely.eject"), symbol: "eject.fill") { store.eject() }
            Text(hint)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, UI.hPad)
        .padding(.top, 11)
        .padding(.bottom, 11)
    }

    private var hint: String {
        L("connectedview.read.only.preflight.first.confirm.before.handling.apps")
    }
}
