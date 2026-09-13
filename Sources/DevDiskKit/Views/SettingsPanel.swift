import SwiftUI

/// Settings rendered inside the panel itself.
///
/// The popover cannot rely on the Settings scene: an in-panel screen works
/// identically in the popover and the window, with no separate settings-window
/// action to fail while the popover is key.
/// It reads the same `@AppStorage` keys as the Settings window, so the two stay in
/// sync automatically.
struct SettingsPanel: View {
    @ObservedObject private var language = LanguageStore.shared
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
            PanelSection(title: L("language.title")) { LanguagePicker() }
            Divider1()
            PanelSection(title: L("settingspanel.visible.sections")) {
                VStack(alignment: .leading, spacing: 2) {
                    row(L("settingspanel.capacity"), $capacity)
                    subRow(L("settingspanel.expand.used.space.breakdown"), $breakdownOpen, enabled: capacity)
                    row(L("connectedview.hardware.health"), $hardware)
                    row(L("connectedview.configuration"), $checks)
                    subRow(L("settingspanel.expand.passed.checks"), $checksAllRows, enabled: checks)
                    row(L("connectedview.what.s.using.the.drive"), $occupancy)
                    row(L("connectedview.volume.info"), $volume)
                    row(L("settingspanel.version.footer"), $version)
                }
            }

            Divider1()

            PanelSection(title: L("settingspanel.hardware.health.detail")) {
                VStack(alignment: .leading, spacing: 7) {
                    Picker("", selection: detail) {
                        ForEach(HardwareDetail.allCases) { d in
                            Text(d.label).tag(d)
                        }
                    }
                    .pickerStyle(.segmented)
                .id(language.resolved)
                    .labelsHidden()
                    .disabled(!hardware)

                    Text(detail.wrappedValue.caption)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider1()

            PanelSection(title: L("settingspanel.monitored.volume")) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(store.pinnedMountPoint)
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                    Text(L("settingspanel.change.this.in.the.settings.window"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }

            Divider1()

            PanelSection(title: L("settingspanel.updates")) {
                VStack(alignment: .leading, spacing: 6) {
                    row(L("settingspanel.check.for.updates"), $updateCheck)
                    HStack(spacing: 6) {
                        Text(L("settingspanel.current", updates.currentVersion))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if updates.checking {
                            ProgressView().controlSize(.mini)
                        } else {
                            LinkButton(title: L("settingspanel.check.now")) { updates.checkNow() }
                        }
                    }
                    if let r = updates.available {
                        LinkButton(title: L("settingspanel.version.available.download", r.version)) {
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
    @ObservedObject private var language = LanguageStore.shared
    @EnvironmentObject var store: DiskStore

    var body: some View {
        Button(L("settingspanel.done")) { store.screen = store.isMounted ? .connected : .disconnected }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, UI.hPad)
            .padding(.vertical, 11)
    }
}
