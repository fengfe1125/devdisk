import SwiftUI

/// Settings rendered inside the panel itself.
///
/// The popover cannot rely on the Settings scene: `SettingsLink` does nothing from
/// a MenuBarExtra, and `NSApp.sendAction(showSettingsWindow:)` silently returns
/// without creating a window while the popover is key. An in-panel screen works
/// identically in the popover and the window, with no AppKit indirection to fail.
/// It reads the same `@AppStorage` keys as the Settings window, so the two stay in
/// sync automatically.
struct SettingsPanel: View {
    @EnvironmentObject var store: DiskStore
    @EnvironmentObject var updates: UpdateChecker

    @AppStorage(PanelSetting.capacity)       private var capacity = true
    @AppStorage(PanelSetting.breakdownOpen)  private var breakdownOpen = false
    @AppStorage(PanelSetting.hardware)       private var hardware = true
    @AppStorage(PanelSetting.hardwareDetail) private var hardwareDetail = HardwareDetail.standard.rawValue
    @AppStorage(PanelSetting.checks)         private var checks = true
    @AppStorage(PanelSetting.checksAllRows)  private var checksAllRows = false
    @AppStorage(PanelSetting.occupancy)      private var occupancy = true
    @AppStorage(PanelSetting.volume)         private var volume = false
    @AppStorage(PanelSetting.version)        private var version = true
    @AppStorage("updateCheckEnabled")        private var updateCheck = true

    private var detail: Binding<HardwareDetail> {
        Binding(get: { HardwareDetail(rawValue: hardwareDetail) ?? .standard },
                set: { hardwareDetail = $0.rawValue })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelSection(title: "显示的区块") {
                VStack(alignment: .leading, spacing: 2) {
                    row("容量", $capacity)
                    subRow("展开「已用空间构成」", $breakdownOpen, enabled: capacity)
                    row("硬件与健康", $hardware)
                    row("配置检查", $checks)
                    subRow("同时展开已通过的项", $checksAllRows, enabled: checks)
                    row("谁在使用", $occupancy)
                    row("卷信息", $volume)
                    row("底部版本行", $version)
                }
            }

            Divider1()

            PanelSection(title: "硬件与健康详细程度") {
                VStack(alignment: .leading, spacing: 7) {
                    Picker("", selection: detail) {
                        ForEach(HardwareDetail.allCases) { d in
                            Text(d.label).tag(d)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(!hardware)

                    Text(detail.wrappedValue.caption)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider1()

            PanelSection(title: "监视的卷") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(store.pinnedMountPoint)
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                    Text("在设置窗口（⌘,）里可以修改。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }

            Divider1()

            PanelSection(title: "更新") {
                VStack(alignment: .leading, spacing: 6) {
                    row("检查更新", $updateCheck)
                    HStack(spacing: 6) {
                        Text("当前 \(updates.currentVersion)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if updates.checking {
                            ProgressView().controlSize(.mini)
                        } else {
                            LinkButton(title: "立即检查") { updates.checkNow() }
                        }
                    }
                    if let r = updates.available {
                        LinkButton(title: "有新版本 \(r.version)，前往下载") {
                            NSWorkspace.shared.open(r.url)
                        }
                    }
                }
            }
        }
    }

    private func row(_ title: String, _ binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            Text(title).font(.system(size: 12))
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .padding(.vertical, 2)
    }

    private func subRow(_ title: String, _ binding: Binding<Bool>,
                        enabled: Bool) -> some View {
        Toggle(isOn: binding) {
            Text(title).font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .disabled(!enabled)
        .padding(.leading, 16)
        .padding(.vertical, 2)
    }
}

/// Pinned action area for the settings screen.
struct SettingsFooter: View {
    @EnvironmentObject var store: DiskStore

    var body: some View {
        Button("完成") { store.screen = store.isMounted ? .connected : .disconnected }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, UI.hPad)
            .padding(.vertical, 11)
    }
}
