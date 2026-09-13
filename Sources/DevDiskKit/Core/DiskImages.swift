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

    var name: String { (path as NSString).lastPathComponent }
    var isMounted: Bool { !mountPoints.isEmpty }

    /// The whole-disk entry (`/dev/disk13`), which is what detach wants.
    var wholeDisk: String? {
        devEntries.first { $0.range(of: #"^/dev/disk\d+$"#, options: .regularExpression) != nil }
            ?? devEntries.first
    }
}

struct DiskImageProbe {
    let runner: CommandRunner

    init(runner: CommandRunner = SystemCommandRunner()) {
        self.runner = runner
    }

    /// Attached images whose backing file lives on `mountPoint`.
    func images(on mountPoint: String) throws -> [DiskImage] {
        let r = try runner.run(Tool.hdiutil, ["info", "-plist"],
                               timeout: Deadline.quick)
        try r.requireSuccess("hdiutil")
        guard let root = VolumeProbe.plist(r.stdout), root["images"] is [[String: Any]] else {
            throw ProbeFailure("hdiutil 输出无法解析")
        }
        return Self.parse(r.stdout, under: mountPoint)
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

    /// Detaches one image. Read-only images carry no user data, so the eject flow
    /// handles those itself; writable ones are left for the user to decide about.
    @discardableResult
    func detach(_ image: DiskImage) -> Bool {
        guard let dev = image.wholeDisk else { return false }
        let r = try? runner.run(Tool.hdiutil, ["detach", dev],
                                timeout: Deadline.eject)
        return r?.ok == true
    }
}
