import SwiftUI

/// Standard macOS settings window (⌘,). Controls what the menu bar panel shows, so
/// the density is the user's call rather than a guess baked into the layout.
struct SettingsView: View {
    @ObservedObject private var language = LanguageStore.shared
    var body: some View {
        TabView {
            PanelSettingsTab()
                .tabItem { Label(L("settingsview.display"), systemImage: "list.bullet") }
            GeneralSettingsTab()
                .tabItem { Label(L("settingsview.general"), systemImage: "gearshape") }
        }
        .environment(\.locale, language.resolved.locale)
        .frame(width: 460)
        .padding(.top, 8)
    }
}

// MARK: - Display

private struct PanelSettingsTab: View {
    @ObservedObject private var language = LanguageStore.shared
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
                Toggle(L("settingspanel.capacity"), isOn: $capacity)
                Toggle(L("settingspanel.expand.used.space.breakdown"), isOn: $breakdownOpen)
                    .disabled(!capacity)
                    .padding(.leading, 18)
            } footer: {
                Text(L("settingsview.folder.usage.scans.the.entire.volume.and.may"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle(L("connectedview.hardware.health"), isOn: $hardware)
                Picker(L("settingsview.detail.level"), selection: detail) {
                    ForEach(HardwareDetail.allCases) { d in
                        Text(d.label).tag(d)
                    }
                }
                .pickerStyle(.segmented)
                .id(language.resolved)
                .disabled(!hardware)
                Text(detail.wrappedValue.caption)
                    .font(.caption).foregroundStyle(.secondary)
            } footer: {
                Text(L("settingsview.items.other.than.writes.require.smartmontools"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle(L("connectedview.configuration"), isOn: $checks)
                Toggle(L("settingspanel.expand.passed.checks"), isOn: $checksAllRows)
                    .disabled(!checks)
                    .padding(.leading, 18)
                Toggle(L("connectedview.what.s.using.the.drive"), isOn: $occupancy)
                Toggle(L("connectedview.volume.info"), isOn: $volume)
                Toggle(L("settingspanel.version.footer"), isOn: $version)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @ObservedObject private var language = LanguageStore.shared
    @AppStorage("targetMountPoint") private var mountPoint = "/Volumes/Developer"
    @AppStorage("updateCheckEnabled") private var updateCheck = true
    @EnvironmentObject private var store: DiskStore
    @EnvironmentObject private var updates: UpdateChecker

    @State private var draft = ""

    var body: some View {
        Form {
            Section { LanguagePicker() }
            Group {
            Section {
                TextField(L("settingspanel.monitored.volume"), text: $draft)
                    .onSubmit { commit() }
                HStack {
                    Button(L("settingsview.apply")) { commit() }
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty
                                  || draft == mountPoint)
                    if !draft.isEmpty && !FileManager.default.fileExists(atPath: draft) {
                        Text(L("settingsview.this.path.does.not.currently.exist"))
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Spacer()
                    Text(store.isMounted ? L("settingsview.connected") : L("panelview.disconnected"))
                        .font(.caption)
                        .foregroundStyle(store.isMounted ? .green : .secondary)
                }
            } header: {
                Text(L("settingsview.volume"))
            } footer: {
                Text(L("settingsview.enter.a.mount.point.such.as.volumes.developer"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle(L("settingspanel.check.for.updates"), isOn: $updateCheck)
                HStack {
                    Text(L("settingsview.current.version", updates.currentVersion))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L("settingspanel.check.now")) { updates.checkNow() }
                        .disabled(updates.checking)
                }
                if let r = updates.available {
                    Link(L("components.version.available", r.version), destination: r.url)
                }
            } header: {
                Text(L("settingspanel.updates"))
            } footer: {
                Text(L("settingsview.checks.at.most.once.a.day.devdisk.only"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            }
            .disabled(store.operation.locksTarget)
        }
        .formStyle(.grouped)
        .onAppear { draft = store.pinnedMountPoint }
    }

    private func commit() {
        // Stored verbatim: volume names really do carry trailing spaces (an ExFAT
        // camera card mounts at "/Volumes/NIKON Z 6  "), and trimming makes the path
        // stop matching the volume it names. Only a blank entry is rejected.
        guard !draft.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        store.pinnedMountPoint = draft
        store.refresh(force: true)
    }
}
