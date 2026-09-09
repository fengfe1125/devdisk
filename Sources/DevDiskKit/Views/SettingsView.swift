import SwiftUI

/// Standard macOS settings window (⌘,). Controls what the menu bar panel shows, so
/// the density is the user's call rather than a guess baked into the layout.
struct SettingsView: View {
    var body: some View {
        TabView {
            PanelSettingsTab()
                .tabItem { Label("显示", systemImage: "list.bullet") }
            GeneralSettingsTab()
                .tabItem { Label("通用", systemImage: "gearshape") }
        }
        .frame(width: 460)
        .padding(.top, 8)
    }
}

// MARK: - Display

private struct PanelSettingsTab: View {
    @AppStorage(PanelSetting.capacity)       private var capacity = true
    @AppStorage(PanelSetting.breakdownOpen)  private var breakdownOpen = false
    @AppStorage(PanelSetting.hardware)       private var hardware = true
    @AppStorage(PanelSetting.hardwareDetail) private var hardwareDetail = HardwareDetail.standard.rawValue
    @AppStorage(PanelSetting.checks)         private var checks = true
    @AppStorage(PanelSetting.checksAllRows)  private var checksAllRows = false
    @AppStorage(PanelSetting.occupancy)      private var occupancy = true
    @AppStorage(PanelSetting.volume)         private var volume = false
    @AppStorage(PanelSetting.version)        private var version = true

    private var detail: Binding<HardwareDetail> {
        Binding(get: { HardwareDetail(rawValue: hardwareDetail) ?? .standard },
                set: { hardwareDetail = $0.rawValue })
    }

    var body: some View {
        Form {
            Section {
                Toggle("容量", isOn: $capacity)
                Toggle("展开「已用空间构成」", isOn: $breakdownOpen)
                    .disabled(!capacity)
                    .padding(.leading, 18)
            } footer: {
                Text("目录占用需要遍历整卷，首次打开会有短暂加载。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("硬件与健康", isOn: $hardware)
                Picker("详细程度", selection: detail) {
                    ForEach(HardwareDetail.allCases) { d in
                        Text(d.label).tag(d)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!hardware)
                Text(detail.wrappedValue.caption)
                    .font(.caption).foregroundStyle(.secondary)
            } footer: {
                Text("写入量以外的项目需要 smartmontools。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("配置检查", isOn: $checks)
                Toggle("同时展开已通过的项", isOn: $checksAllRows)
                    .disabled(!checks)
                    .padding(.leading, 18)
                Toggle("谁在使用", isOn: $occupancy)
                Toggle("卷信息", isOn: $volume)
                Toggle("底部版本行", isOn: $version)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @AppStorage("targetMountPoint") private var mountPoint = "/Volumes/Developer"
    @AppStorage("updateCheckEnabled") private var updateCheck = true
    @EnvironmentObject private var store: DiskStore
    @EnvironmentObject private var updates: UpdateChecker

    @State private var draft = ""

    var body: some View {
        Form {
            Section {
                TextField("监视的卷", text: $draft)
                    .onSubmit { commit() }
                HStack {
                    Button("应用") { commit() }
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty
                                  || draft == mountPoint)
                    if !draft.isEmpty && !FileManager.default.fileExists(atPath: draft) {
                        Text("该路径当前不存在")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Spacer()
                    Text(store.isMounted ? "已连接" : "未连接")
                        .font(.caption)
                        .foregroundStyle(store.isMounted ? .green : .secondary)
                }
            } header: {
                Text("卷")
            } footer: {
                Text("填写挂载点路径，例如 /Volumes/Developer。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("检查更新", isOn: $updateCheck)
                HStack {
                    Text("当前版本 \(updates.currentVersion)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("立即检查") { updates.checkNow() }
                        .disabled(updates.checking)
                }
                if let r = updates.available {
                    Link("有新版本 \(r.version)", destination: r.url)
                }
            } header: {
                Text("更新")
            } footer: {
                Text("每天最多检查一次。应用只提示，不会自动替换自己。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { draft = store.pinnedMountPoint }
    }

    private func commit() {
        // Stored verbatim: volume names really do carry trailing spaces (an ExFAT
        // camera card mounts at "/Volumes/NIKON Z 6  "), and trimming makes the path
        // stop matching the volume it names. Only a blank entry is rejected.
        guard !draft.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        mountPoint = draft
        store.pinnedMountPoint = draft
        store.refresh()
    }
}
