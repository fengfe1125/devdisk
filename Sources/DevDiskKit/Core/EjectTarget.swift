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

enum EjectVerificationState: Equatable {
    /// The device disappeared from the disk registry and its volumes are unmounted.
    case offline
    /// Fixed external devices can remain enumerated after a successful software
    /// eject. Their volumes are gone from the kernel mount table.
    case unmounted
    case present, unavailable
}

/// One conservative observation of the post-eject state. A missing mount alone is
/// not success: both the physical disk registry and every related mount must agree.
struct EjectVerification: Equatable {
    let state: EjectVerificationState
    let physicalDiskPresent: Bool?
    let mountedVolumes: [TargetVolume]
    let relatedMountsKnown: Bool
    let issue: Message?

    var confirmedOffline: Bool { state == .offline }

    var detail: Message {
        let disk = physicalDiskPresent.map {
            $0 ? M("ejectverification.physical.disk.present") : M("ejectverification.physical.disk.absent")
        } ?? M("ejectverification.physical.disk.unknown")
        let mounts = !relatedMountsKnown
            ? M("ejectverification.related.volumes.unknown")
            : mountedVolumes.isEmpty
                ? M("ejectverification.related.volumes.unmounted")
                : M("ejectverification.related.volumes.still.mounted", mountedVolumes.map(\.mount).joined(separator: ", "))
        return issue.map { disk + "; " + mounts + "; " + $0 } ?? disk + "; " + mounts
    }
}

protocol TargetInspecting {
    func target(at mount: String, runner: CommandRunner) throws -> EjectTarget
    func validateUnmounted(_ target: EjectTarget, runner: CommandRunner) throws
    func ejectVerification(_ target: EjectTarget, runner: CommandRunner,
                           timeout: TimeInterval) -> EjectVerification
}

extension TargetInspecting {
    func isEjected(_ target: EjectTarget, runner: CommandRunner) throws -> Bool {
        let result = ejectVerification(target, runner: runner, timeout: Deadline.quick)
        if result.state == .unavailable {
            throw ProbeFailure(result.issue ?? M("ejecttarget.could.not.verify.the.system.disk.list"))
        }
        return result.confirmedOffline
    }
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

    /// After unmount, the old mount path is gone. Re-resolve the original UUIDs and
    /// physical-store mapping by device, and reject new mounted siblings/reused IDs.
    func validateUnmounted(_ target: EjectTarget, runner: CommandRunner) throws {
        guard !target.affected.isEmpty else { throw ProbeFailure(M("ejectforce.target.changed")) }
        for volume in target.affected {
            let d = try info(volume.device, runner: runner)
            guard !volume.uuid.isEmpty, d["VolumeUUID"] as? String == volume.uuid,
                  d["DeviceIdentifier"] as? String == volume.device,
                  d["RemovableMediaOrExternalDevice"] as? Bool == true,
                  try physical(d, runner: runner) == target.physicalDisk,
                  (d["MountPoint"] as? String).map({ $0.isEmpty || $0 == volume.mount }) ?? true else {
                throw ProbeFailure(M("ejectforce.target.changed"))
            }
        }
        let paths = try mountedPaths()
        for path in paths {
            let d = try info(path, runner: runner)
            if d["BusProtocol"] as? String == "Disk Image" { continue }
            if try physical(d, runner: runner) == target.physicalDisk {
                guard target.affected.contains(try volume(d)) else {
                    throw ProbeFailure(M("ejectforce.target.changed"))
                }
            }
        }
        guard Set(paths) == Set(try mountedPaths()) else { throw ProbeFailure(M("ejectforce.target.changed")) }
    }

    func ejectVerification(_ target: EjectTarget, runner: CommandRunner,
                           timeout: TimeInterval) -> EjectVerification {
        var diskPresent: Bool?
        var mounted: [TargetVolume] = []
        var mountsKnown = false
        var issues: [Message] = []
        do {
            let r = try runner.run(Tool.diskutil, ["list", "-plist"], timeout: max(0.05, timeout))
            try r.requireSuccess("diskutil list")
            guard let d = VolumeProbe.plist(r.stdout), let disks = d["AllDisks"] as? [String], !disks.isEmpty else {
                throw ProbeFailure(M("ejecttarget.could.not.verify.the.system.disk.list"))
            }
            diskPresent = disks.contains(target.physicalDisk)
        } catch {
            issues.append(error.displayMessage)
        }
        do {
            let paths = Set(try mountedPaths())
            mounted = target.affected.filter { paths.contains($0.mount) }
            // A volume can remount at a different path or a new sibling can appear.
            // Check every additional mount instead of treating missing old paths as proof.
            if diskPresent == true {
                for path in paths where !target.affected.contains(where: { $0.mount == path }) {
                    let d = try info(path, runner: runner)
                    if d["BusProtocol"] as? String == "Disk Image" { continue }
                    if try physical(d, runner: runner) == target.physicalDisk {
                        mounted.append(try volume(d))
                    }
                }
            }
            guard Set(try mountedPaths()) == paths else { throw ProbeFailure(M("ejectforce.target.changed")) }
            mountsKnown = true
        } catch {
            issues.append(error.displayMessage)
        }
        let issue = issues.isEmpty ? nil : issues.joined(separator: M("issue.separator"))
        let state: EjectVerificationState
        if diskPresent == false, mountsKnown, mounted.isEmpty, issue == nil { state = .offline }
        else if diskPresent == true, mountsKnown, mounted.isEmpty, issue == nil { state = .unmounted }
        else if diskPresent == true || !mounted.isEmpty { state = .present }
        else { state = .unavailable }
        return .init(state: state, physicalDiskPresent: diskPresent,
                     mountedVolumes: mounted, relatedMountsKnown: mountsKnown, issue: issue)
    }
}
