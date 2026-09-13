import SwiftUI

struct EjectPreviewView: View {
    @EnvironmentObject var store: DiskStore
    var body: some View {
        if let plan = store.ejectPlan {
            VStack(alignment: .leading, spacing: 0) {
                PanelSection(title: "弹出影响预览", aside: plan.incomplete ? "检测不完整" : "只读预检已完成") {
                    Text(plan.target.volume.name).font(.headline)
                    Text(plan.target.volume.mount).font(.caption).textSelection(.enabled)
                    Text("检测于 \(plan.createdAt.formatted(date: .omitted, time: .standard)) · 超过 30 秒须重新核验")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("普通权限仅能检查可见句柄；系统将在弹出时再次判断。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if plan.completedApps + plan.completedDaemons + plan.completedImages > 0 {
                    Text("本次已退出应用 \(plan.completedApps) 个、停止服务 \(plan.completedDaemons) 个、推出映像 \(plan.completedImages) 个。以下为更新后的预览。")
                        .font(.caption).foregroundStyle(.secondary).padding(UI.hPad)
                }
                if plan.target.multipleVolumes {
                    PanelSection(title: "整盘弹出会影响以下卷") {
                        ForEach(plan.target.affected, id: \.device) { volume in
                            Text("\(volume.name) · \(volume.mount)").font(.caption)
                        }
                        Text("本版不对多卷盘自动处理进程，只能明确选择普通系统弹出。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                if !plan.issues.isEmpty {
                    PanelSection(title: "检测不完整") {
                        ForEach(Array(plan.issues.enumerated()), id: \.offset) { _, issue in
                            Text(issue).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                group("将请求退出的应用", plan.apps, note: "退出会影响整个应用，由应用处理未保存内容。")
                group("将停止的限定后台服务", plan.daemons, note: "服务可能仍在工作；确认后仅发送 TERM 并等待退出。")
                group("需手动处理", plan.manual, note: "请先保存并停止这些任务，再重新检测。")
                if !plan.images.isEmpty {
                    PanelSection(title: "关联磁盘映像") {
                        ForEach(Array(plan.images.enumerated()), id: \.offset) { _, image in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(image.name).font(.system(size: 12, weight: .medium))
                                Text(image.path).font(.caption).textSelection(.enabled)
                                Text(image.writable || !image.accessKnown ? "可写或属性未知：需手动推出" : "只读：确认后普通推出")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !plan.writableImages.isEmpty {
                    Text("请先手动推出可写或属性未知的映像。")
                        .font(.caption).foregroundStyle(.orange).padding(UI.hPad)
                }
            }
        }
    }
    @ViewBuilder private func group(_ title: String, _ holders: [Holder], note: String) -> some View {
        if !holders.isEmpty {
            PanelSection(title: title) {
                Text(note).font(.caption).foregroundStyle(.secondary)
                ForEach(holders) { HolderRow(holder: $0) }
            }
        }
    }
}

struct EjectPreviewFooter: View {
    @EnvironmentObject var store: DiskStore
    var body: some View {
        VStack(spacing: 8) {
            if let plan = store.ejectPlan {
                if plan.canPrepare {
                    PrimaryButton(title: "确认处理并弹出", symbol: "eject.fill") { store.confirmEject() }
                }
                if plan.canSystemOnly {
                    PrimaryButton(title: "仅尝试系统弹出", symbol: "eject") { store.confirmEject(systemOnly: true) }
                    Text("不会退出应用、停止服务、主动推出映像或强制卸载")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                HStack {
                    Button("重新检测") { store.retryPreflight() }
                    Spacer()
                    Button("取消") { store.cancelEject() }
                }.buttonStyle(.bordered)
            }
        }.padding(.horizontal, UI.hPad).padding(.vertical, 11)
    }
}
