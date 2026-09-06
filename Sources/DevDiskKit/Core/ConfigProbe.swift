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
    static func staleMountPoints(for name: String, fm: FileManager = .default) -> [String] {
        let entries = (try? fm.contentsOfDirectory(atPath: "/Volumes")) ?? []
        return entries
            .filter { $0 != name && $0.hasPrefix(name + " ") }
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

        if let excluded = try? timeMachineExcluded(path: mount), excluded == true {
            out.append(ConfigCheck(
                id: "timemachine", severity: .warning,
                title: "Time Machine 已排除整卷",
                detail: "源码与今后的签名 keystore 都不在备份内。",
                fixCommand: "sudo tmutil removeexclusion \(shellQuote(mount))",
                settingsURL: nil))
        } else {
            out.append(ConfigCheck(
                id: "timemachine", severity: .ok,
                title: "Time Machine 包含此卷",
                detail: "卷内容会被备份。", fixCommand: nil, settingsURL: nil))
        }

        if let indexing = try? spotlightIndexing(mountPoint: mount), indexing == true {
            out.append(ConfigCheck(
                id: "spotlight", severity: .warning,
                title: "Spotlight 正在索引",
                detail: "构建缓存被反复索引，白耗构建时的 IO。",
                fixCommand: "sudo mdutil -i off \(shellQuote(mount))",
                settingsURL: nil))
        } else {
            out.append(ConfigCheck(
                id: "spotlight", severity: .ok,
                title: "Spotlight 未索引此卷",
                detail: "构建缓存不会被反复索引。", fixCommand: nil, settingsURL: nil))
        }

        if let m = try? diskSleepMinutes(), m > 0 {
            out.append(ConfigCheck(
                id: "disksleep", severity: .warning,
                title: "磁盘休眠 \(m) 分钟",
                detail: "外置 NVMe 掉出总线会让正在跑的构建中断。",
                fixCommand: "sudo pmset -a disksleep 0", settingsURL: nil))
        } else {
            out.append(ConfigCheck(
                id: "disksleep", severity: .ok,
                title: "磁盘休眠已关闭",
                detail: "盘不会在空闲时掉出总线。", fixCommand: nil, settingsURL: nil))
        }

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

        let stale = Self.staleMountPoints(for: volume.name)
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

        // Surfaced only when the counter says every power-off so far was unclean.
        if let h = health, h.allShutdownsUnsafe,
           let u = h.unsafeShutdowns, let c = h.powerCycles {
            out.append(ConfigCheck(
                id: "unsafe", severity: .warning,
                title: "\(c) 次断电全部非正常",
                detail: "非正常断电 \(u) 次。部分硬盘盒卸载时直接切电也会记这一笔。",
                fixCommand: nil, settingsURL: nil))
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
