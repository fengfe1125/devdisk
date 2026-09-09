import Foundation

/// One mounted volume, as seen by discovery.
struct DiscoveredVolume: Identifiable, Equatable {
    var mountPoint: String
    var name: String
    var deviceIdentifier: String
    var filesystem: String
    var busProtocol: String
    var isExternal: Bool
    var isDiskImage: Bool
    var isBoot: Bool
    var totalBytes: Int64
    var freeBytes: Int64

    var id: String { mountPoint }

    /// What the drive picker should offer: a real external drive, not the boot
    /// volume and not a mounted installer image.
    var isSelectableDrive: Bool { isExternal && !isDiskImage && !isBoot }
}

/// Finds the external drives currently attached.
///
/// Enumeration is done with FileManager and classification with `diskutil info`,
/// deliberately **not** `diskutil list external`: a PCIe-tunneled NVMe enclosure
/// reports `RemovableMedia: No` and `Detachable: No`, so a filter built on those
/// would miss exactly the kind of drive this app exists for. The one key that is
/// true for such an enclosure is `RemovableMediaOrExternalDevice`.
struct VolumeDiscovery {
    let runner: CommandRunner

    init(runner: CommandRunner = SystemCommandRunner()) {
        self.runner = runner
    }

    /// Mount points of everything currently mounted, including "/".
    func mountedPaths(fm: FileManager = .default) -> [String] {
        let urls = fm.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: [.skipHiddenVolumes]) ?? []
        // Volume names can carry trailing spaces ("NIKON Z 6  " on an ExFAT camera
        // card), so paths are used exactly as reported — never trimmed.
        return urls.map(\.path)
    }

    func discover() -> [DiscoveredVolume] {
        mountedPaths().compactMap { path in
            guard let r = try? runner.run(Tool.diskutil, ["info", "-plist", path],
                                          timeout: Deadline.quick),
                  r.ok,
                  let d = VolumeProbe.plist(r.stdout)
            else { return nil }
            return Self.parse(d, fallbackMountPoint: path)
        }
    }

    /// External drives only, sorted for a stable list.
    func drives() -> [DiscoveredVolume] {
        discover().filter(\.isSelectableDrive)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func parse(_ d: [String: Any], fallbackMountPoint: String) -> DiscoveredVolume? {
        let mount = d["MountPoint"] as? String ?? fallbackMountPoint
        guard !mount.isEmpty else { return nil }

        let bus = d["BusProtocol"] as? String ?? ""
        let cap = VolumeProbe.capacity(of: mount)

        return DiscoveredVolume(
            mountPoint: mount,
            name: d["VolumeName"] as? String ?? (mount as NSString).lastPathComponent,
            deviceIdentifier: d["DeviceIdentifier"] as? String ?? "",
            filesystem: d["FilesystemName"] as? String ?? "—",
            busProtocol: bus,
            isExternal: d["RemovableMediaOrExternalDevice"] as? Bool ?? false,
            // A mounted .dmg reports itself as external too, so installer images
            // would otherwise show up in the drive list as if they were hardware.
            isDiskImage: bus == "Disk Image",
            isBoot: mount == "/",
            totalBytes: cap.total,
            freeBytes: cap.free
        )
    }

    /// Which volume the panel should show.
    ///
    /// The pinned volume wins whenever it is attached — plugging the dev drive back
    /// in returns to it. Otherwise a lone external drive is shown automatically, so
    /// the panel is never blank while something is actually plugged in.
    enum Choice: Equatable {
        case pinned(String)
        case only(String)
        case pick          // several attached, none pinned online
        case none          // nothing attached
    }

    static func choose(drives: [DiscoveredVolume], pinned: String) -> Choice {
        if drives.contains(where: { $0.mountPoint == pinned }) { return .pinned(pinned) }
        if drives.isEmpty { return .none }
        if drives.count == 1 { return .only(drives[0].mountPoint) }
        return .pick
    }
}
