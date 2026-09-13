import SwiftUI

/// Lists the external drives currently attached.
///
/// Reached by clicking the volume name in the header. Mounted `.dmg` images and the
/// boot volume are filtered out by `VolumeDiscovery` — a disk image reports itself
/// as external, so without that filter every installer sitting in Downloads would
/// show up here as if it were hardware.
struct DrivePickerView: View {
    @ObservedObject private var language = LanguageStore.shared
    @EnvironmentObject var store: DiskStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelSection(title: L("drivepickerview.connected.external.drives"),
                         aside: store.drives.isEmpty ? nil : L("drivepickerview.", store.drives.count)) {
                if store.drives.isEmpty {
                    empty
                } else {
                    VStack(spacing: 5) {
                        ForEach(store.drives) { drive in
                            row(drive)
                        }
                    }
                }
            }

            Divider1()

            PanelSection(title: L("drivepickerview.default.drive")) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.pinnedMountPoint)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1).truncationMode(.middle)
                    Text(L("drivepickerview.automatically.switches.back.when.the.default.drive.connects"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("drivepickerview.no.external.drives.found"))
                .font(.system(size: 12, weight: .medium))
            Text(L("drivepickerview.mounted.disk.images.and.the.startup.disk.are"))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private func row(_ drive: DiscoveredVolume) -> some View {
        let isCurrent = drive.mountPoint == store.mountPoint
        let isPinned = drive.mountPoint == store.pinnedMountPoint

        return Button {
            store.select(drive)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: isCurrent ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        // Name shown verbatim: an ExFAT camera card really is called
                        // "NIKON Z 6  ", trailing spaces and all.
                        Text(drive.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1).truncationMode(.middle)
                        if isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Text(subtitle(drive))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if !isPinned {
                    Button(L("drivepickerview.set.as.default")) { store.pin(drive) }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .font(.system(size: 10))
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isCurrent ? Color.accentColor.opacity(0.10) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(isCurrent ? Color.accentColor.opacity(0.35) : Color(nsColor: .separatorColor))
        }
    }

    private func subtitle(_ d: DiscoveredVolume) -> String {
        [Fmt.bytes(d.freeBytes) + L("drivepickerview.free"),
         d.filesystem,
         d.busProtocol,
         d.deviceIdentifier]
            .filter { !$0.isEmpty && $0 != "—" }
            .joined(separator: " · ")
    }
}

/// Pinned action area for the drive picker.
struct DrivePickerFooter: View {
    @ObservedObject private var language = LanguageStore.shared
    @EnvironmentObject var store: DiskStore

    var body: some View {
        Button(L("drivepickerview.refresh.list")) { store.refresh() }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, UI.hPad)
            .padding(.vertical, 11)
    }
}
