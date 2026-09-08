import Foundation

/// Works out who is holding the volume, in three tiers of decreasing certainty.
///
/// Measured on this machine: as a normal user, `lsof +D /Volumes/Developer`,
/// `lsof -w /Volumes/Developer` and `lsof /dev/disk7s1` all return nothing — yet
/// fseventsd (root) and mds_stores (_mds_stores) genuinely hold the volume. An
/// unprivileged lsof cannot see other users' file handles. Reporting "nobody is
/// using it" and then failing to eject is the worst possible outcome, so system
/// daemons are *inferred* from volume state and labelled as such in the UI.
struct Occupancy {
    let runner: CommandRunner

    init(runner: CommandRunner = SystemCommandRunner()) {
        self.runner = runner
    }

    // MARK: - Known processes

    struct Pattern {
        let match: String       // substring of the full command line
        let display: String
        let kind: HolderKind
        let bundleID: String?
    }

    static let known: [Pattern] = [
        .init(match: "Android Studio.app", display: "Android Studio",
              kind: .guiApp, bundleID: "com.google.android.studio"),
        .init(match: "Xcode.app/Contents/MacOS/Xcode", display: "Xcode",
              kind: .guiApp, bundleID: "com.apple.dt.Xcode"),
        .init(match: "IntelliJ IDEA.app", display: "IntelliJ IDEA",
              kind: .guiApp, bundleID: "com.jetbrains.intellij"),

        .init(match: "GradleDaemon", display: "GradleDaemon", kind: .daemon, bundleID: nil),
        .init(match: "GradleWrapperMain", display: "Gradle", kind: .daemon, bundleID: nil),
        .init(match: "KotlinCompileDaemon", display: "KotlinCompileDaemon",
              kind: .daemon, bundleID: nil),
        .init(match: "qemu-system", display: "Android 模拟器", kind: .daemon, bundleID: nil),
        .init(match: "platform-tools/adb", display: "adb", kind: .daemon, bundleID: nil),
    ]

    // MARK: - Process table

    struct ProcInfo {
        var pid: Int32
        var user: String
        var args: String      // full command line
    }

    func processes() throws -> [ProcInfo] {
        let r = try runner.run(Tool.ps, ["-axo", "pid=,user=,args="])
        return Self.parsePs(r.text)
    }

    /// Parses `ps -axo pid=,user=,args=`. Only pid and user are split off by
    /// whitespace — both are guaranteed space-free — and everything after them is the
    /// command line verbatim, which may contain spaces (".../Android Studio.app/...").
    static func parsePs(_ text: String) -> [ProcInfo] {
        text.split(separator: "\n").compactMap { raw in
            var rest = Substring(raw).drop { $0 == " " }
            let pidTok = rest.prefix { $0 != " " }
            guard let pid = Int32(pidTok) else { return nil }
            rest = rest.dropFirst(pidTok.count).drop { $0 == " " }
            let user = rest.prefix { $0 != " " }
            guard !user.isEmpty else { return nil }
            let args = rest.dropFirst(user.count).drop { $0 == " " }
            guard !args.isEmpty else { return nil }

            // No command-name field: an executable path may itself contain spaces
            // ("/Applications/Android Studio.app/..."), so any attempt to split one
            // out of args is wrong. Classification matches against args instead, and
            // display names come from the pattern list or from lsof's own `c` field.
            return ProcInfo(pid: pid, user: String(user), args: String(args))
        }
    }

    static func classify(_ p: ProcInfo) -> Pattern? {
        known.first { p.args.contains($0.match) }
    }

    // MARK: - Quick scan

    /// Matches the known list against the process table. Instant, catches the cases
    /// that actually block an eject, and runs no filesystem walk.
    func quickScan(mountPoint: String, indexingOn: Bool?) throws -> OccupancyReport {
        let start = Date()
        let procs = try processes()
        var holders = Self.groupKnown(procs, mountPoint: mountPoint)
        holders += Self.inferredSystemHolders(indexingOn: indexingOn)

        return OccupancyReport(
            holders: holders, scanDepth: .quick, scannedAt: start,
            duration: Date().timeIntervalSince(start), openFilesFound: nil
        )
    }

    static func groupKnown(_ procs: [ProcInfo], mountPoint: String) -> [Holder] {
        var byName: [String: (Pattern, [ProcInfo])] = [:]
        for p in procs {
            guard let pat = classify(p) else { continue }
            // A known binary that never references the volume is not holding it —
            // e.g. an Xcode session working entirely on the internal disk.
            guard p.args.contains(mountPoint) || pat.kind == .guiApp else { continue }
            byName[pat.display, default: (pat, [])].1.append(p)
        }
        return byName.values.map { pat, ps in
            Holder(name: pat.display,
                   pids: ps.map(\.pid).sorted(),
                   user: ps.first?.user ?? "",
                   kind: pat.kind,
                   evidence: .inferred(reason: "命令行匹配"),
                   bundleID: pat.bundleID)
        }
        .sorted { $0.name < $1.name }
    }

    // MARK: - Full scan

    /// `lsof +D` walks the whole tree, so this is the slow path and only ever runs
    /// when the user asks for it. Still limited to the current user's processes.
    func fullScan(mountPoint: String, indexingOn: Bool?) throws -> OccupancyReport {
        let start = Date()
        // -F emits one field per line (p pid, c command, L login, n name), which is
        // far safer to parse than lsof's aligned columns.
        let r = try runner.run(Tool.lsof, ["-w", "-F", "pcLn", "+D", mountPoint],
                               timeout: Deadline.scan)
        let sets = Self.parseLsof(r.text)
        let procs = try processes()
        let byPID = Dictionary(uniqueKeysWithValues: procs.map { ($0.pid, $0) })

        var holders: [Holder] = sets.map { set in
            let info = byPID[set.pid]
            let pat = info.flatMap(Self.classify)
            return Holder(
                name: pat?.display ?? set.command,
                pids: [set.pid],
                user: set.user.isEmpty ? (info?.user ?? "") : set.user,
                // An unrecognised process gets .guiApp so the flow asks rather than
                // kills — never guess that an unknown process is safe to terminate.
                kind: pat?.kind ?? .guiApp,
                evidence: .scanned(openFiles: set.files.count,
                                   sampleFiles: Array(set.files.prefix(3))),
                bundleID: pat?.bundleID
            )
        }
        .sorted { ($0.openFileCount ?? 0) > ($1.openFileCount ?? 0) }

        holders += Self.inferredSystemHolders(indexingOn: indexingOn)

        return OccupancyReport(
            holders: holders, scanDepth: .full, scannedAt: start,
            duration: Date().timeIntervalSince(start),
            openFilesFound: sets.reduce(0) { $0 + $1.files.count }
        )
    }

    struct LsofSet {
        var pid: Int32
        var command: String
        var user: String
        var files: [String]
    }

    static func parseLsof(_ text: String) -> [LsofSet] {
        var out: [LsofSet] = []
        var cur: LsofSet?
        for line in text.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p":
                if let c = cur { out.append(c) }
                cur = LsofSet(pid: Int32(value) ?? 0, command: "", user: "", files: [])
            case "c": cur?.command = value
            case "L": cur?.user = value
            case "n":
                // lsof also reports non-path entries (sockets, pipes); keep real paths.
                if value.hasPrefix("/") { cur?.files.append(value) }
            default: break
            }
        }
        if let c = cur { out.append(c) }
        return out.filter { !$0.files.isEmpty }
    }

    // MARK: - Inferred system holders

    /// Not scanned — derived from volume state, because an unprivileged lsof cannot
    /// see these processes' handles. The UI must present them as inference.
    static func inferredSystemHolders(indexingOn: Bool?) -> [Holder] {
        var out: [Holder] = []

        if indexingOn == true {
            out.append(Holder(
                name: "mds_stores", pids: [], user: "_mds_stores", kind: .system,
                evidence: .inferred(reason: "本卷 Spotlight 索引开启，正在写 .Spotlight-V100"),
                bundleID: nil))
        }
        out.append(Holder(
            name: "fseventsd", pids: [], user: "root", kind: .system,
            evidence: .inferred(reason: "任何已挂载的卷都会被它持有，写 .fseventsd"),
            bundleID: nil))

        return out
    }
}
