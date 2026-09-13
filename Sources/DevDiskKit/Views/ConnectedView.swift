import SwiftUI

/// Scrollable body only. The eject button lives in `ConnectedFooter`, pinned by
/// PanelView, so the primary action never scrolls out of reach.
///
/// Which sections appear is the user's choice, made in Settings — guessing at the
/// right density produced either a panel taller than the screen or one too sparse
/// to be worth opening.
struct ConnectedView: View {
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
                Text(store.lastError ?? "正在读取…")
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
            Text("所有区块都已隐藏")
                .font(.system(size: 12, weight: .medium))
            Text("在设置里选择要显示的内容（⌘,）")
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
            if let issue = store.directoryIssue { Text("目录统计未完成：" + issue).font(.caption).foregroundStyle(.orange) }
        }
    }

    // MARK: - Hardware & health

    @ViewBuilder private func hardware(_ snap: DiskSnapshot) -> some View {
        PanelSection(title: "硬件与健康",
                aside: snap.hardware.firmware.map { "固件 \($0)" }) {
            VStack(spacing: 6) {
                if let link = snap.hardware.linkDescription {
                    KeyValueRow("接口", link)
                }
                if let s = snap.hardware.smartStatus {
                    KeyValueRow("SMART") {
                        Pill(text: s, color: s == "Verified" ? .green : .red)
                    }
                }
                if let t = snap.hardware.trimSupported {
                    KeyValueRow("TRIM") {
                        Pill(text: t ? "已启用" : "未启用", color: t ? .green : .orange)
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
        if let w = h.bytesWritten { KeyValueRow("累计写入", Fmt.bytes(w)) }
        if let life = h.lifeRemaining {
            KeyValueRow("剩余寿命") {
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
        if let hrs = h.powerOnHours { KeyValueRow("通电时间", Fmt.hours(hrs)) }
        if let temp = h.temperatureC {
            KeyValueRow("温度") {
                Text("\(temp) °C")
                    .font(.system(size: 11.5)).monospacedDigit()
                    .foregroundStyle(temp >= 70 ? Color.orange : Color.primary)
            }
        }
    }

    @ViewBuilder private func fullHealth(_ h: SmartHealth) -> some View {
        if let r = h.bytesRead { KeyValueRow("累计读取", Fmt.bytes(r)) }
        if let spare = h.availableSpare { KeyValueRow("可用备用块", "\(spare)%") }
        if let c = h.powerCycles { KeyValueRow("通电次数", "\(c) 次") }
        if let u = h.unsafeShutdowns {
            KeyValueRow("非正常断电") {
                Text("\(u) 次")
                    .font(.system(size: 11.5)).monospacedDigit()
                    .foregroundStyle(h.allShutdownsUnsafe ? Color.orange : Color.primary)
            }
        }
        if let e = h.mediaErrors {
            KeyValueRow("介质错误") {
                Text("\(e)")
                    .font(.system(size: 11.5)).monospacedDigit()
                    .foregroundStyle(e > 0 ? Color.red : Color.primary)
            }
        }
    }

    // MARK: - Volume

    private func volumeInfo(_ snap: DiskSnapshot) -> some View {
        let v = snap.volume
        return PanelSection(title: "卷信息", aside: v.deviceIdentifier) {
            VStack(spacing: 6) {
                KeyValueRow("挂载点", v.mountPoint)
                KeyValueRow("文件系统", v.filesystem)
                KeyValueRow("类型", v.isExternal ? "外置" : "内置")
                if let p = v.physicalDisk { KeyValueRow("物理盘", "/dev/" + p) }
                if let s = snap.hardware.serial { KeyValueRow("序列号", s) }
                KeyValueRow("卷 UUID") {
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
        PanelSection(title: "配置检查",
                aside: warnings > 0 ? "\(warnings) 项需注意 / 未知" : "已完成检查正常",
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
                        Text(passing.map(\.title).joined(separator: "、"))
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

        PanelSection(title: "谁在使用",
                aside: report?.scanDepth == .quick ? "可能相关 · 尚未核验" : "\(mine.count) 个你的进程 · 系统可见性受限") {
            VStack(spacing: 1) {
                ForEach(mine) { h in
                    HStack(spacing: 8) {
                        Text(h.name).lineLimit(1)
                        Spacer(minLength: 6)
                        if let pid = h.pids.first {
                            Text(String(pid))
                                .font(.system(size: 10.5)).monospacedDigit()
                                .foregroundStyle(.tertiary)
                        }
                        Text(report?.scanDepth == .quick ? "可能相关" : h.kind == .guiApp ? "需确认退出" : h.kind == .daemon ? "需确认停止" : "手动处理")
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
                        Text(system.map(\.name).joined(separator: "、"))
                            .lineLimit(1).foregroundStyle(.secondary)
                        Spacer(minLength: 6)
                        Text("系统")
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
                    Text(report.issues.joined(separator: "；")).font(.caption).foregroundStyle(.orange)
                }
                if mine.isEmpty && system.isEmpty {
                    Text(report == nil || report?.state != .complete ? "占用状态未知" : report?.scanDepth == .quick ? "未发现候选进程，弹出前将完整预检" : "未发现当前用户的占用")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 3)
                }
            }

            LinkButton(title: "查看详情并重新检测…") { store.screen = .scan }
        }
    }
}

/// Pinned action area for the connected screen.
struct ConnectedFooter: View {
    @EnvironmentObject var store: DiskStore

    var body: some View {
        VStack(spacing: 7) {
            PrimaryButton(title: "安全弹出", symbol: "eject.fill") { store.eject() }
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
        "先只读预检；需要处理应用或服务时再确认"
    }
}
