import SwiftUI

/// Detection results, grouped by how certain we are about each holder. The system
/// group is inferred rather than scanned — an unprivileged lsof cannot see other
/// users' handles — and the footer says so plainly, because "nobody is using it"
/// followed by a failed eject is the worst outcome this screen could produce.
struct ScanView: View {
    @EnvironmentObject var store: DiskStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            subhead
            meta
            if let report = store.occupancy, !report.issues.isEmpty {
                Text("检测不完整：" + report.issues.joined(separator: "；"))
                    .font(.caption).foregroundStyle(.orange).padding(.horizontal, UI.hPad).padding(.bottom, 10)
            }
            Divider1()

            group(kind: .guiApp,
                  title: "需要你决定", color: .orange,
                  note: "弹出时会发送退出请求，由应用自己弹保存对话框。绝不强杀。")

            group(kind: .daemon,
                  title: "确认后可停止", color: .secondary,
                  note: "限定后台服务可能仍在工作；确认前不会发送停止请求。")

            group(kind: .manual, title: "需手动处理", color: .orange,
                  note: "模拟器、前台构建及无法确认身份的进程不会被自动停止。")

            group(kind: .system,
                  title: "系统进程", color: .secondary,
                  note: "不由本程序处理。diskutil eject 会让它们自行释放。")

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
                    Text("返回")
                }
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text("谁在使用")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)

            Spacer(minLength: 4)

            Button {
                store.fullScan()
            } label: {
                if store.occupancyScanning {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("检测中…")
                    }
                } else {
                    Text("重新检测")
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
                         ? "未发现你的进程持有文件，用时 \(String(format: "%.1f", r.duration)) 秒"
                         : "找到 \(Fmt.count(n)) 个打开的文件，用时 \(String(format: "%.1f", r.duration)) 秒")
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
        if s < 60 { return "\(max(0, s)) 秒前" }
        if s < 3600 { return "\(s / 60) 分钟前" }
        return "\(s / 3600) 小时前"
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
                    Text("\(holders.count) 个")
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
                Text("普通权限只能看到你自己的进程。")
                    .font(.system(size: 10.5, weight: .semibold))
                Text("上面的系统进程是按「卷已挂载 + Spotlight 索引开启」推断的，不是扫出来的——lsof 看不见其他用户的文件句柄。")
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
    @EnvironmentObject var store: DiskStore

    var body: some View {
        PrimaryButton(title: "预检并弹出", symbol: "eject.fill") { store.eject() }
            .padding(.horizontal, UI.hPad)
            .padding(.vertical, 11)
    }
}

// MARK: - One holder

struct HolderRow: View {
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
                    Text(holder.name)
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
                        Text("…另有 \(Fmt.count(n - holder.sampleFiles.count)) 个")
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
        if let n = holder.openFileCount { return "\(Fmt.count(n)) 个文件" }
        return holder.kind == .system ? "推断" : "可能相关"
    }
}
