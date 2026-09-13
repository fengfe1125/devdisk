import Foundation

enum MountTable {
    /// The kernel mount table includes hidden APFS volumes and excludes residual
    /// directories. Only local block-device mounts can share an eject target.
    static func paths() throws -> [String] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { throw ProbeFailure(M("ejecttarget.could.not.read.the.system.mount.table")) }
        defer { free(buffer) }
        return (0..<Int(count)).compactMap { index in
            let entry = buffer[index]
            let source = withUnsafeBytes(of: entry.f_mntfromname) {
                String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            guard source.hasPrefix("/dev/disk") else { return nil }
            return withUnsafeBytes(of: entry.f_mntonname) {
                String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
        }
    }
}

struct EjectTarget: Equatable {
    let volume: TargetVolume
    let physicalDisk: String
    let affected: [TargetVolume]
    var multipleVolumes: Bool { affected.count != 1 }
}

struct TargetVolume: Equatable, Hashable {
    let name: String
    let mount: String
    let device: String
    let uuid: String
}

protocol TargetInspecting {
    func target(at mount: String, runner: CommandRunner) throws -> EjectTarget
    func isEjected(_ target: EjectTarget, runner: CommandRunner) throws -> Bool
}

struct SystemTargetInspector: TargetInspecting {
    var mountedPaths: () throws -> [String] = MountTable.paths

    private func info(_ path: String, runner: CommandRunner) throws -> [String: Any] {
        let r = try runner.run(Tool.diskutil, ["info", "-plist", path])
        try r.requireSuccess("diskutil info")
        guard let d = VolumeProbe.plist(r.stdout) else { throw ProbeFailure(M("ejecttarget.could.not.parse.disk.information")) }
        return d
    }

    private func physical(_ d: [String: Any], runner: CommandRunner) throws -> String {
        if let container = d["APFSContainerReference"] as? String {
            guard let disk = try VolumeProbe(runner: runner).physicalDisk(container: container) else {
                throw ProbeFailure(M("ejecttarget.could.not.identify.a.single.apfs.physical.disk"))
            }
            return disk
        }
        guard let disk = (d["ParentWholeDisk"] as? String)
                ?? (d["Whole"] as? Bool == true ? d["DeviceIdentifier"] as? String : nil),
              disk.range(of: #"^disk\d+$"#, options: .regularExpression) != nil else {
            throw ProbeFailure(M("ejecttarget.could.not.verify.physical.disk.topology.handle.it"))
        }
        return disk
    }

    private func volume(_ d: [String: Any]) throws -> TargetVolume {
        guard let mount = d["MountPoint"] as? String, !mount.isEmpty,
              let device = d["DeviceIdentifier"] as? String, !device.isEmpty else { throw ProbeFailure(M("ejecttarget.the.target.is.not.a.currently.mounted.volume")) }
        return .init(name: d["VolumeName"] as? String ?? mount, mount: mount,
                     device: device, uuid: d["VolumeUUID"] as? String ?? "")
    }

    func target(at mount: String, runner: CommandRunner) throws -> EjectTarget {
        let paths = try mountedPaths()
        guard paths.contains(mount), mount != "/" else { throw ProbeFailure(M("ejecttarget.the.target.is.disconnected.or.is.not.an")) }
        let d = try info(mount, runner: runner)
        guard d["RemovableMediaOrExternalDevice"] as? Bool == true,
              d["BusProtocol"] as? String != "Disk Image" else {
            throw ProbeFailure(M("ejecttarget.could.not.verify.that.the.target.is.an"))
        }
        let selected = try volume(d)
        guard selected.mount == mount else { throw ProbeFailure(M("ejecttarget.the.mount.point.changed.select.it.again")) }
        let disk = try physical(d, runner: runner)
        var affected = [selected]
        for path in paths where path != mount {
            let other = try info(path, runner: runner)
            // Only mounted block-device volumes can share the physical target.
            guard other["BusProtocol"] as? String != "Disk Image",
                  let dev = other["DeviceIdentifier"] as? String,
                  dev.hasPrefix("disk") else { continue }
            let parent = try physical(other, runner: runner)
            if parent == disk {
                guard path != "/", other["RemovableMediaOrExternalDevice"] as? Bool == true else {
                    throw ProbeFailure(M("ejecttarget.the.target.shares.a.physical.disk.with.the"))
                }
                affected.append(try volume(other))
            }
        }
        guard Set(try mountedPaths()) == Set(paths) else { throw ProbeFailure(M("ejecttarget.the.mount.table.changed.scan.again")) }
        return .init(volume: selected, physicalDisk: disk,
                     affected: affected.sorted { $0.mount < $1.mount })
    }

    func isEjected(_ target: EjectTarget, runner: CommandRunner) throws -> Bool {
        let r = try runner.run(Tool.diskutil, ["list", "-plist"])
        try r.requireSuccess("diskutil list")
        guard let d = VolumeProbe.plist(r.stdout), let disks = d["AllDisks"] as? [String], !disks.isEmpty else {
            throw ProbeFailure(M("ejecttarget.could.not.verify.the.system.disk.list"))
        }
        let paths = Set(try mountedPaths())
        return !disks.contains(target.physicalDisk)
            && target.affected.allSatisfy { !paths.contains($0.mount) }
    }
}
