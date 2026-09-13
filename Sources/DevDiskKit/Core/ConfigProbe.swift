import Foundation

/// Builds the configuration-check list. Every fix needs sudo, so none of them run
/// here — each check carries a copyable command or a Settings pane to open.
struct ConfigProbe {
    let runner: CommandRunner

    init(runner: CommandRunner = SystemCommandRunner()) {
        self.runner = runner
    }

    // MARK: - Individual probes

    func spotlightIndexing(mountPoint: String) throws -> Bool? {
        let r = try runner.run(Tool.mdutil, ["-s", mountPoint])
        try r.requireSuccess("mdutil")
        return Self.parseSpotlight(r.text)
    }

    /// mdutil echoes the firmlink-resolved path
    /// (/System/Volumes/Data/Volumes/Developer), not the argument, so matching on the
    /// requested path fails. Only the status phrase is reliable.
    static func parseSpotlight(_ text: String) -> Bool? {
        if text.contains("Indexing enabled") { return true }
        if text.contains("Indexing disabled") { return false }
        return nil
    }

    func timeMachineExcluded(path: String) throws -> Bool? {
        let r = try runner.run(Tool.tmutil, ["isexcluded", path])
        try r.requireSuccess("tmutil")
        return Self.parseExcluded(r.text)
    }

    /// "[Excluded]  /Volumes/Developer" / "[Included]  /Users/example"
    static func parseExcluded(_ text: String) -> Bool? {
        if text.contains("[Excluded]") { return true }
        if text.contains("[Included]") { return false }
        return nil
    }

    func diskSleepMinutes() throws -> Int? {
        let r = try runner.run(Tool.pmset, ["-g"])
        try r.requireSuccess("pmset")
        return Self.parseDiskSleep(r.text)
    }

    /// " disksleep            10"
    static func parseDiskSleep(_ text: String) -> Int? {
        for line in text.split(separator: "\n") where line.contains("disksleep") {
            if let last = line.split(whereSeparator: \.isWhitespace).last {
                return Int(last)
            }
        }
        return nil
    }

    /// A leftover mount point directory makes the next mount land on "Developer 1",
    /// silently breaking every hardcoded path.
    static func staleMountPoints(for name: String, fm: FileManager = .default) throws -> [String] {
        let entries = try fm.contentsOfDirectory(atPath: "/Volumes")
        let mounted = Set(try MountTable.paths())
        return entries
            .filter { $0 != name && $0.hasPrefix(name + " ") && !mounted.contains("/Volumes/" + $0) }
            .map { "/Volumes/" + $0 }
            .sorted()
    }

    // MARK: - Assembled checks

    func checks(volume: VolumeInfo, health: SmartHealth?) -> [ConfigCheck] {
        var out: [ConfigCheck] = []
        let mount = volume.mountPoint

        out.append(volume.isEncrypted
            ? ConfigCheck(id: "encryption", severity: .ok,
                          title: M("configprobe.encrypted"),
                          detail: M("configprobe.contents.cannot.be.read.if.the.drive.is"),
                          fixCommand: nil, settingsURL: nil)
            : ConfigCheck(id: "encryption", severity: .critical,
                          title: M("configprobe.not.encrypted"),
                          detail: M("configprobe.this.portable.drive.contains.source.code.and.signing"),
                          fixCommand: nil,
                          settingsURL: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"))

        func unknown(_ id: String, _ title: Message, _ issues: [Message]) -> ConfigCheck {
            ConfigCheck(id: id, severity: .unknown, title: title + M("configprobe.unknown"),
                        detail: issues.joined(separator: M("issue.separator")), fixCommand: nil, settingsURL: nil)
        }
        let backup = ProbeResult<Bool>.capture { try timeMachineExcluded(path: mount) }
        if let excluded = backup.value {
            out.append(ConfigCheck(id: "timemachine", severity: excluded ? .warning : .ok,
                title: excluded ? M("configprobe.excluded.from.time.machine") : M("configprobe.not.excluded.as.a.whole.volume"),
                detail: excluded ? M("configprobe.time.machine.does.not.back.up.this.volume") : M("configprobe.checks.only.whole.volume.exclusion.not.backup.success"),
                fixCommand: excluded ? "sudo tmutil removeexclusion \(shellQuote(mount))" : nil, settingsURL: nil))
        } else { out.append(unknown("timemachine", "Time Machine", backup.issues)) }

        let spotlight = ProbeResult<Bool>.capture { try spotlightIndexing(mountPoint: mount) }
        if let enabled = spotlight.value {
            out.append(ConfigCheck(id: "spotlight", severity: enabled ? .warning : .ok,
                title: enabled ? M("configprobe.spotlight.indexing.enabled") : M("configprobe.spotlight.indexing.disabled"),
                detail: enabled ? M("configprobe.build.caches.may.add.indexing.i.o.this") : M("configprobe.spotlight.indexing.is.disabled.for.this.volume"),
                fixCommand: enabled ? "sudo mdutil -i off \(shellQuote(mount))" : nil, settingsURL: nil))
        } else { out.append(unknown("spotlight", "Spotlight", spotlight.issues)) }

        let sleep = ProbeResult<Int>.capture { try diskSleepMinutes() }
        if let minutes = sleep.value {
            out.append(ConfigCheck(id: "disksleep", severity: minutes > 0 ? .warning : .ok,
                title: minutes > 0 ? M("configprobe.disk.sleep.after.min", minutes) : M("configprobe.disk.sleep.disabled"),
                detail: M("configprobe.system.wide.setting.actual.behavior.depends.on.the"),
                fixCommand: minutes > 0 ? "sudo pmset -a disksleep 0" : nil, settingsURL: nil))
        } else { out.append(unknown("disksleep", M("configprobe.disk.sleep"), sleep.issues)) }

        out.append(volume.ownersEnabled
            ? ConfigCheck(id: "owners", severity: .ok,
                          title: M("configprobe.ownership.enabled"),
                          detail: M("configprobe.file.permissions.and.executable.bits.are.preserved"),
                          fixCommand: nil, settingsURL: nil)
            : ConfigCheck(id: "owners", severity: .critical,
                          title: M("configprobe.ownership.ignored"),
                          detail: M("configprobe.permissions.and.executable.bits.may.not.be.preserved"),
                          fixCommand: "sudo diskutil enableOwnership \(shellQuote(mount))",
                          settingsURL: nil))

        let staleResult = ProbeResult<[String]>.capture { try Self.staleMountPoints(for: volume.name) }
        let stale = staleResult.value ?? []
        out.append(stale.isEmpty
            ? ConfigCheck(id: "mountpoint", severity: .ok,
                          title: M("configprobe.mount.point.ok"),
                          detail: M("configprobe.no.leftover.directories", mount),
                          fixCommand: nil, settingsURL: nil)
            : ConfigCheck(id: "mountpoint", severity: .warning,
                          title: M("configprobe.leftover.mount.points"),
                          detail: M("configprobe.may.cause.a.different.mount.name.next.time", stale.map(Message.raw).joined(separator: M("list.separator"))),
                          fixCommand: stale.map { "sudo rmdir \(shellQuote($0))" }
                                           .joined(separator: "; "),
                          settingsURL: nil))

        if !staleResult.isComplete, let index = out.firstIndex(where: { $0.id == "mountpoint" }) {
            out[index] = unknown("mountpoint", M("configprobe.leftover.mount.points.a66a"), staleResult.issues)
        }

        // Surfaced only when the counter says every power-off so far was unclean.
        if let h = health, h.allShutdownsUnsafe,
           let u = h.unsafeShutdowns, let c = h.powerCycles {
            out.append(ConfigCheck(
                id: "unsafe", severity: .warning,
                title: M("configprobe.all.shutdowns.were.unsafe", c),
                detail: M("configprobe.unsafe.shutdowns.some.enclosures.also.record.this.when", u),
                fixCommand: nil, settingsURL: nil))
        }

        if !volume.encryptionKnown, let i = out.firstIndex(where: { $0.id == "encryption" }) {
            out[i] = unknown("encryption", M("configprobe.encryption"), [M("configprobe.the.device.did.not.report.a.recognized.encryption")])
        }
        if let i = out.firstIndex(where: { $0.id == "owners" }) {
            if volume.filesystem.localizedCaseInsensitiveContains("exfat") || volume.filesystem.localizedCaseInsensitiveContains("fat32") {
                out[i] = ConfigCheck(id: "owners", severity: .notApplicable, title: M("configprobe.volume.ownership.not.applicable"),
                                     detail: M("configprobe.this.file.system.does.not.support.this.ownership"), fixCommand: nil, settingsURL: nil)
            } else if !volume.ownershipKnown {
                out[i] = unknown("owners", M("configprobe.volume.ownership"), [M("configprobe.the.device.did.not.report.its.ownership.setting")])
            }
        }
        return out
    }

    func shellQuote(_ s: String) -> String { Self.shellQuote(s) }

    static func shellQuote(_ s: String) -> String {
        s.allSatisfy { $0.isLetter || $0.isNumber || "/._-".contains($0) }
            ? s
            : "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
