import Foundation

/// A disk image that is currently attached, described by `hdiutil info -plist`.
///
/// These matter because an image whose backing `.dmg` lives on the target volume
/// makes that volume impossible to unmount — `diskimages-helper` holds the file
/// open. Worse, an image can be *attached but not mounted*, in which case it has no
/// Finder presence at all: the user is told the drive is busy and has no way to see
/// or fix the cause. The only way out is `hdiutil detach`.
struct DiskImage: Equatable {
    var path: String
    var writable: Bool
    var accessKnown: Bool = true
    /// `/dev/diskN` entries, used to detach.
    var devEntries: [String]
    /// Mount points, empty when the image is attached but not mounted.
    var mountPoints: [String]

    var volumeUUIDs: [String: String] = [:]

    var name: String { (path as NSString).lastPathComponent }
    var isMounted: Bool { !mountPoints.isEmpty }

    /// The whole-disk entry (`/dev/disk13`), which is what detach wants.
    var wholeDisk: String? {
        devEntries.first { $0.range(of: #"^/dev/disk\d+$"#, options: .regularExpression) != nil }

    }
}

struct DiskImageProbe {
    let runner: CommandRunner

    init(runner: CommandRunner = SystemCommandRunner()) {
        self.runner = runner
    }

    /// Include dependencies on all affected volumes, then images backed by those images.
    /// The result is ordered children first so no backing volume is removed too early.
    func images(on mountPoint: String) throws -> [DiskImage] {
        try images(on: [mountPoint])
    }

    func images(on mounts: [String]) throws -> [DiskImage] {
        let r = try runner.run(Tool.hdiutil, ["info", "-plist"], timeout: Deadline.quick)
        try r.requireSuccess("hdiutil")
        guard let root = VolumeProbe.plist(r.stdout), let rows = root["images"] as? [[String: Any]],
              rows.allSatisfy({ $0["image-path"] is String && $0["system-entities"] is [[String: Any]] }) else {
            throw ProbeFailure(M("diskimages.could.not.parse.hdiutil.output"))
        }
        var remaining = Self.parse(r.stdout, under: "/")
        var roots = mounts
        var related: [DiskImage] = []
        while let index = remaining.firstIndex(where: { image in
            roots.contains { Self.contains(image.path, under: $0) }
        }) {
            var image = remaining.remove(at: index)
            guard image.wholeDisk != nil else { throw ProbeFailure(M("ejectforce.image.identity.unknown")) }
            // hdiutil can omit APFS mount points. Resolve every exported device, including
            // synthesized APFS volumes, rather than assuming the image has no mounts.
            for device in image.devEntries {
                guard device.range(of: #"^/dev/disk\d+(s\d+)*$"#, options: .regularExpression) != nil else {
                    throw ProbeFailure(M("ejectforce.image.identity.unknown"))
                }
                let info = try runner.run(Tool.diskutil, ["info", "-plist", device], timeout: Deadline.quick)
                try info.requireSuccess("diskutil info")
                guard let value = VolumeProbe.plist(info.stdout),
                      value["DeviceIdentifier"] as? String == String(device.dropFirst(5)) else {
                    throw ProbeFailure(M("ejectforce.image.identity.unknown"))
                }
                if let uuid = value["VolumeUUID"] as? String { image.volumeUUIDs[device] = uuid }
                if let mount = value["MountPoint"] as? String, !mount.isEmpty {
                    image.mountPoints.append(mount)
                }
            }
            image.mountPoints = Array(Set(image.mountPoints)).sorted()
            guard !image.mountPoints.contains("/") else { throw ProbeFailure(M("ejectforce.image.identity.unknown")) }
            roots += image.mountPoints
            related.append(image)
        }
        return related.reversed()
    }

    static func contains(_ path: String, under mount: String) -> Bool {
        let path = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        let mount = URL(fileURLWithPath: mount).resolvingSymlinksInPath().standardizedFileURL.path
        return path.hasPrefix(mount == "/" ? "/" : mount + "/")
    }

    static func parse(_ data: Data, under mountPoint: String) -> [DiskImage] {
        guard let root = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any],
              let images = root["images"] as? [[String: Any]]
        else { return [] }

        // Trailing slash so "/Volumes/Dev" cannot match "/Volumes/Developer".
        let prefix = mountPoint.hasSuffix("/") ? mountPoint : mountPoint + "/"

        return images.compactMap { img in
            guard let path = img["image-path"] as? String,
                  path.hasPrefix(prefix) else { return nil }

            let entities = img["system-entities"] as? [[String: Any]] ?? []
            return DiskImage(
                path: path,
                writable: img["writeable"] as? Bool ?? true,
                accessKnown: img["writeable"] is Bool,
                devEntries: entities.compactMap { $0["dev-entry"] as? String },
                mountPoints: entities.compactMap { $0["mount-point"] as? String }
                    .filter { !$0.isEmpty }
            )
        }
    }

    func areDetached(_ expected: [DiskImage], backingMounts: [String] = [], timeout: TimeInterval = Deadline.quick) throws -> Bool {
        let r = try runner.run(Tool.hdiutil, ["info", "-plist"], timeout: timeout)
        try r.requireSuccess("hdiutil")
        guard let root = VolumeProbe.plist(r.stdout), let rows = root["images"] as? [[String: Any]],
              rows.allSatisfy({ $0["image-path"] is String && $0["system-entities"] is [[String: Any]] }) else {
            throw ProbeFailure(M("diskimages.could.not.parse.hdiutil.output"))
        }
        let attached = Self.parse(r.stdout, under: "/")
        let roots = backingMounts + expected.flatMap(\.mountPoints)
        return !attached.contains { live in
            roots.contains { Self.contains(live.path, under: $0) } || expected.contains { $0.path == live.path || !Set($0.devEntries).isDisjoint(with: live.devEntries) }
        }
    }

    /// The caller retains command diagnostics and verifies the attachment disappeared.
    func detach(_ image: DiskImage, force: Bool = false) throws -> CommandResult {
        guard let dev = image.wholeDisk else { throw ProbeFailure(M("ejectforce.image.identity.unknown")) }
        return try runner.run(Tool.hdiutil, ["detach", dev] + (force ? ["-force"] : []), timeout: Deadline.eject)
    }
}
