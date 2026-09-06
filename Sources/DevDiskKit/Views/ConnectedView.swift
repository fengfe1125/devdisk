import SwiftUI

/// Scrollable body only. The eject button lives in `ConnectedFooter`, pinned by
/// PanelView, so the primary action never scrolls out of reach.
struct ConnectedView: View {
    @EnvironmentObject var store: DiskStore

    var body: some View {
        if let snap = store.snapshot {
            VStack(alignment: .leading, spacing: 0) {
                Section {
                    CapacityBar(volume: snap.volume,
                                directories: store.directories,
                                loading: store.directoriesLoading)
                }
                Divider1()

                hardware(snap)
                Divider1()

                checks(snap)
                Divider1()

                occupancy(snap)
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

    // MARK: - Hardware & health

    @ViewBuilder private func hardware(_ snap: DiskSnapshot) -> some View {
        Section(title: "硬件与健康",
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

                if let h = snap.health {
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

    // MARK: - Configuration checks

    @ViewBuilder private func checks(_ snap: DiskSnapshot) -> some View {
        let warnings = snap.warningCount
        Section(title: "配置检查",
                aside: warnings > 0 ? "\(warnings) 项需注意" : "全部正常",
                asideColor: warnings > 0 ? .orange : .green) {
            // Only the items needing attention get a full two-line row. Everything
            // that passes collapses into one line — seven expanded rows made the
            // panel taller than the screen.
            let problems = snap.checks.filter { $0.severity != .ok }
            let passing = snap.checks.filter { $0.severity == .ok }

            VStack(spacing: 0) {
                ForEach(problems) { check in
                    CheckRow(check: check,
                             onCopy: store.copy,
                             onOpen: store.openSettings)
                }

                if !passing.isEmpty {
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

        Section(title: "谁在使用",
                aside: "\(mine.count) 个你的进程 · \(system.count) 个系统进程") {
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
                        Text(h.kind == .guiApp ? "请求退出" : "自动停止")
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

                if mine.isEmpty && system.isEmpty {
                    Text("没有检测到占用进程")
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
        let apps = store.occupancy?.holders(.guiApp) ?? []
        return apps.isEmpty
            ? "将停止守护进程后卸载卷"
            : "将先请求 \(apps.map(\.name).joined(separator: "、")) 退出，再停止守护进程"
    }
}
