import Foundation

struct VolumeProbe {
    let runner: CommandRunner

    init(runner: CommandRunner = SystemCommandRunner()) {
        self.runner = runner
    }

    // MARK: - Volume

    func volume(at mountPoint: String) throws -> VolumeInfo? {
        let r = try runner.run(Tool.diskutil, ["info", "-plist", mountPoint])
        guard r.ok, let d = Self.plist(r.stdout) else { return nil }
        return try Self.parseVolume(d, mountPoint: mountPoint, resolvePhysical: {
            try physicalDisk(container: $0)
        })
    }

    static func parseVolume(
        _ d: [String: Any],
        mountPoint: String,
        resolvePhysical: (String) throws -> String?
    ) rethrows -> VolumeInfo {
        let container = d["APFSContainerReference"] as? String
        // FreeSpace in diskutil's output is 0 for APFS volumes; capacity comes from statfs.
        let cap = capacity(of: (d["MountPoint"] as? String) ?? mountPoint)

        return VolumeInfo(
            name: d["VolumeName"] as? String ?? "",
            mountPoint: d["MountPoint"] as? String ?? mountPoint,
            filesystem: d["FilesystemName"] as? String ?? "—",
            isEncrypted: d["Encryption"] as? Bool ?? false,
            // Removable / RemovableMedia are both false for a PCIe-tunneled NVMe
            // enclosure; only this key distinguishes external from internal.
            isExternal: d["RemovableMediaOrExternalDevice"] as? Bool ?? false,
            ownersEnabled: d["GlobalPermissionsEnabled"] as? Bool ?? false,
            volumeUUID: d["VolumeUUID"] as? String ?? "",
            deviceIdentifier: d["DeviceIdentifier"] as? String ?? "",
            containerReference: container,
            physicalDisk: try container.flatMap { try resolvePhysical($0) }
                ?? (container == nil ? (d["ParentWholeDisk"] as? String) : nil),
            totalBytes: cap.total,
            freeBytes: cap.free,
            encryptionKnown: d["Encryption"] is Bool,
            ownershipKnown: d["GlobalPermissionsEnabled"] is Bool
        )
    }

    /// diskutil reports FreeSpace as 0 for APFS volumes, so capacity is read from the
    /// filesystem directly.
    static func capacity(of path: String) -> (total: Int64, free: Int64) {
        let url = URL(fileURLWithPath: path)
        if let v = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        ]), let total = v.volumeTotalCapacity, let free = v.volumeAvailableCapacity {
            return (Int64(total), Int64(free))
        }
        var s = statfs()
        guard statfs(path, &s) == 0 else { return (0, 0) }
        // Darwin's statfs uses f_bsize; there is no f_frsize.
        return (Int64(s.f_blocks) * Int64(s.f_bsize),
                Int64(s.f_bavail) * Int64(s.f_bsize))
    }

    // MARK: - Container → physical disk

    /// An APFS volume's ParentWholeDisk names the *synthesized* container (disk7), which
    /// never appears in system_profiler. The physical device (disk6) is reached through
    /// the container's physical store (disk6s2) with its partition suffix stripped.
    func physicalDisk(container: String) throws -> String? {
        let r = try runner.run(Tool.diskutil, ["info", "-plist", container])
        guard r.ok, let d = Self.plist(r.stdout) else { return nil }
        return Self.parsePhysicalDisk(d)
    }

    static func parsePhysicalDisk(_ d: [String: Any]) -> String? {
        guard let stores = d["APFSPhysicalStores"] as? [[String: Any]],
              stores.count == 1,
              let store = stores.first?["APFSPhysicalStore"] as? String
        else { return nil }
        return wholeDisk(from: store)
    }

    /// "disk6s2" → "disk6"; "disk6" is returned unchanged.
    static func wholeDisk(from identifier: String) -> String {
        guard let r = identifier.range(of: #"^disk\d+"#, options: .regularExpression)
        else { return identifier }
        return String(identifier[r])
    }

    // MARK: - Hardware

    func hardware(physicalDisk: String?) throws -> DriveHardware {
        guard let disk = physicalDisk else { return DriveHardware() }
        let r = try runner.run(Tool.systemProfiler, ["SPNVMeDataType", "-json"])
        guard r.ok else { return DriveHardware() }
        return Self.parseHardware(r.stdout, bsdName: disk)
    }

    static func parseHardware(_ data: Data, bsdName: String) -> DriveHardware {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let controllers = root["SPNVMeDataType"] as? [[String: Any]]
        else { return DriveHardware() }

        let items = controllers.flatMap { $0["_items"] as? [[String: Any]] ?? [] }
        guard let it = items.first(where: { $0["bsd_name"] as? String == bsdName })
        else { return DriveHardware() }

        return DriveHardware(
            model: it["device_model"] as? String ?? it["_name"] as? String,
            serial: it["device_serial"] as? String,
            firmware: it["device_revision"] as? String,
            trimSupported: (it["spnvme_trim_support"] as? String).flatMap {
                $0.lowercased() == "yes" ? true : $0.lowercased() == "no" ? false : nil
            },
            smartStatus: it["smart_status"] as? String,
            linkWidth: it["spnvme_linkwidth"] as? String,
            linkSpeed: it["spnvme_linkspeed"] as? String
        )
    }

    // MARK: - Directory usage

    /// `du -sk` per top-level entry. Walking the whole volume takes seconds, so callers
    /// run this off the main thread and cache the result.
    func directoryUsage(mountPoint: String) throws -> [DirectoryUsage] {
        let entries = try FileManager.default.contentsOfDirectory(atPath: mountPoint)
        let visible = entries.filter { !$0.hasPrefix(".") }.sorted()
        guard !visible.isEmpty else { return [] }

        let r = try runner.run(Tool.du, ["-sk"] + visible.map { mountPoint + "/" + $0 },
                               timeout: Deadline.walk)
        try r.requireSuccess("du")
        guard r.stderr.isEmpty else { throw ProbeFailure(M("volumeprobe.folder.usage.incomplete") + r.stderr) }
        return Self.parseDu(r.text).sorted { $0.bytes > $1.bytes }
    }

    static func parseDu(_ text: String) -> [DirectoryUsage] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, let kb = Int64(parts[0].trimmingCharacters(in: .whitespaces))
            else { return nil }
            let path = parts[1].trimmingCharacters(in: .whitespaces)
            return DirectoryUsage(
                name: (path as NSString).lastPathComponent,
                bytes: kb * 1024
            )
        }
    }

    // MARK: - Helpers

    static func plist(_ data: Data) -> [String: Any]? {
        try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any]
    }
}
