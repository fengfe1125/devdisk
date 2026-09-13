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
                          title: "已加密",
                          detail: "丢失或失窃时盘上内容不可读。",
                          fixCommand: nil, settingsURL: nil)
            : ConfigCheck(id: "encryption", severity: .critical,
                          title: "未加密",
                          detail: "随身携带的盘，含源码与签名凭据。丢失即全部泄露。",
                          fixCommand: nil,
                          settingsURL: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"))

        func unknown(_ id: String, _ title: String, _ issues: [String]) -> ConfigCheck {
            ConfigCheck(id: id, severity: .unknown, title: title + " · 未知",
                        detail: issues.joined(separator: "；"), fixCommand: nil, settingsURL: nil)
        }
        let backup = ProbeResult<Bool>.capture { try timeMachineExcluded(path: mount) }
        if let excluded = backup.value {
            out.append(ConfigCheck(id: "timemachine", severity: excluded ? .warning : .ok,
                title: excluded ? "Time Machine 已排除整卷" : "此卷未被整卷排除",
                detail: excluded ? "本卷不在 Time Machine 的备份范围内。" : "这里只检查整卷排除设置，未验证备份是否成功或子目录是否另行排除。",
                fixCommand: excluded ? "sudo tmutil removeexclusion \(shellQuote(mount))" : nil, settingsURL: nil))
        } else { out.append(unknown("timemachine", "Time Machine", backup.issues)) }

        let spotlight = ProbeResult<Bool>.capture { try spotlightIndexing(mountPoint: mount) }
        if let enabled = spotlight.value {
            out.append(ConfigCheck(id: "spotlight", severity: enabled ? .warning : .ok,
                title: enabled ? "Spotlight 索引已启用" : "Spotlight 索引已关闭",
                detail: enabled ? "构建缓存可能产生额外索引 IO；这不表示此刻正在索引。" : "此卷已关闭 Spotlight 索引。",
                fixCommand: enabled ? "sudo mdutil -i off \(shellQuote(mount))" : nil, settingsURL: nil))
        } else { out.append(unknown("spotlight", "Spotlight", spotlight.issues)) }

        let sleep = ProbeResult<Int>.capture { try diskSleepMinutes() }
        if let minutes = sleep.value {
            out.append(ConfigCheck(id: "disksleep", severity: minutes > 0 ? .warning : .ok,
                title: minutes > 0 ? "磁盘休眠 \(minutes) 分钟" : "磁盘休眠已关闭",
                detail: "系统级休眠设置，实际行为取决于磁盘及硬盘盒。",
                fixCommand: minutes > 0 ? "sudo pmset -a disksleep 0" : nil, settingsURL: nil))
        } else { out.append(unknown("disksleep", "磁盘休眠", sleep.issues)) }

        out.append(volume.ownersEnabled
            ? ConfigCheck(id: "owners", severity: .ok,
                          title: "所有权已启用",
                          detail: "文件权限与可执行位保持正确。",
                          fixCommand: nil, settingsURL: nil)
            : ConfigCheck(id: "owners", severity: .critical,
                          title: "所有权被忽略",
                          detail: "权限与可执行位会被抹平，构建产物可能无法执行。",
                          fixCommand: "sudo diskutil enableOwnership \(shellQuote(mount))",
                          settingsURL: nil))

        let staleResult = ProbeResult<[String]>.capture { try Self.staleMountPoints(for: volume.name) }
        let stale = staleResult.value ?? []
        out.append(stale.isEmpty
            ? ConfigCheck(id: "mountpoint", severity: .ok,
                          title: "挂载点正常",
                          detail: "\(mount)，无残留目录。",
                          fixCommand: nil, settingsURL: nil)
            : ConfigCheck(id: "mountpoint", severity: .warning,
                          title: "存在残留挂载点",
                          detail: "\(stale.joined(separator: "、")) 会让下次挂载改名。",
                          fixCommand: stale.map { "sudo rmdir \(shellQuote($0))" }
                                           .joined(separator: "; "),
                          settingsURL: nil))

        if !staleResult.isComplete, let index = out.firstIndex(where: { $0.id == "mountpoint" }) {
            out[index] = unknown("mountpoint", "残留挂载点", staleResult.issues)
        }

        // Surfaced only when the counter says every power-off so far was unclean.
        if let h = health, h.allShutdownsUnsafe,
           let u = h.unsafeShutdowns, let c = h.powerCycles {
            out.append(ConfigCheck(
                id: "unsafe", severity: .warning,
                title: "\(c) 次断电全部非正常",
                detail: "非正常断电 \(u) 次。部分硬盘盒卸载时直接切电也会记这一笔。",
                fixCommand: nil, settingsURL: nil))
        }

        if !volume.encryptionKnown, let i = out.firstIndex(where: { $0.id == "encryption" }) {
            out[i] = unknown("encryption", "加密状态", ["设备未报告可识别的加密状态"])
        }
        if let i = out.firstIndex(where: { $0.id == "owners" }) {
            if volume.filesystem.localizedCaseInsensitiveContains("exfat") || volume.filesystem.localizedCaseInsensitiveContains("fat32") {
                out[i] = ConfigCheck(id: "owners", severity: .notApplicable, title: "卷所有权 · 不适用",
                                     detail: "此文件系统不提供这项所有权设置。", fixCommand: nil, settingsURL: nil)
            } else if !volume.ownershipKnown {
                out[i] = unknown("owners", "卷所有权", ["设备未报告所有权设置"])
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
