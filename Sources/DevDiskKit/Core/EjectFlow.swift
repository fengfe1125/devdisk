import Foundation

struct EjectPlan: Equatable {
    let target: EjectTarget
    let createdAt: Date
    let holders: [Holder]
    let images: [DiskImage]
    let issues: [String]
    var completedApps: Int = 0
    var completedDaemons: Int = 0
    var completedImages: Int = 0
    var manual: [Holder] { holders.filter { $0.kind == .manual } }
    var apps: [Holder] { holders.filter { $0.kind == .guiApp } }
    var daemons: [Holder] { holders.filter { $0.kind == .daemon } }
    var writableImages: [DiskImage] { images.filter { $0.writable || !$0.accessKnown } }
    var incomplete: Bool { !issues.isEmpty }
    var canPrepare: Bool { !incomplete && manual.isEmpty && writableImages.isEmpty && !target.multipleVolumes }
    var requiresConfirmation: Bool {
        incomplete || target.multipleVolumes || !manual.isEmpty || !images.isEmpty || !apps.isEmpty || !daemons.isEmpty
    }
    var canSystemOnly: Bool { incomplete || target.multipleVolumes }
    var processScope: Set<ProcessIdentity> { Set((apps + daemons + manual).compactMap(\.identity)) }
}

/// Read-only preparation and explicitly approved execution share one cancellation token.
// Configuration is frozen before dispatch; mutable execution state is owned by one queue.
final class EjectFlow: @unchecked Sendable {
    enum StepState: Equatable {
        case pending, running, done(String?), skipped(String), failed(String)
    }
    struct Step: Identifiable, Equatable {
        let id: String
        let title: String
        var state: StepState = .pending
        var detail: String? {
            switch state {
            case .done(let d): return d
            case .skipped(let d), .failed(let d): return d
            default: return nil
            }
        }
    }
    enum Outcome: Equatable {
        case ejected(TimeInterval, stoppedApps: Int, stoppedDaemons: Int)
        case aborted(String)
        case preview(EjectPlan)
    }

    let runner: CommandRunner
    let mountPoint: String
    let cancellation: CancellationToken
    var inspector: ProcessInspecting = SystemProcessInspector()
    var targets: TargetInspecting = SystemTargetInspector()
    var expectedVolume: TargetVolume?
    var quitTimeout: TimeInterval = 20
    var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    var now: () -> Date = Date.init
    private(set) var steps: [Step] = []
    var onUpdate: ([Step]) -> Void = { _ in }
    var onCommit: () -> Void = {}
    private var stoppedApps = 0
    private var stoppedDaemons = 0
    private var detachedImages = 0
    private var completedDetail: String {
        "已退出应用 \(stoppedApps) 个、停止服务进程 \(stoppedDaemons) 个、推出映像 \(detachedImages) 个；已发出的请求无法撤销。"
    }
    private var scoped: CommandRunner { ScopedCommandRunner(base: runner, cancellation: cancellation) }

    init(runner: CommandRunner = SystemCommandRunner(), mountPoint: String,
         cancellation: CancellationToken = CancellationToken()) {
        self.runner = runner
        self.mountPoint = mountPoint
        self.cancellation = cancellation
    }

    func prepare(indexingOn: Bool? = nil) throws -> EjectPlan {
        try cancellation.check()
        let target = try targets.target(at: mountPoint, runner: scoped)
        if let expectedVolume, target.volume.device != expectedVolume.device || target.volume.uuid != expectedVolume.uuid || target.volume.mount != expectedVolume.mount {
            throw ProbeFailure("所选卷身份已变化，请重新选择")
        }
        var occ = Occupancy(runner: scoped)
        occ.inspector = inspector
        let result = ProbeResult<OccupancyReport>.capture {
            try occ.fullScan(mountPoint: mountPoint, indexingOn: indexingOn)
        }
        let images = ProbeResult<[DiskImage]>.capture {
            try DiskImageProbe(runner: scoped).images(on: mountPoint)
        }
        try cancellation.check()
        // A scan may take 30s; identity/topology must still match after it finishes.
        guard try targets.target(at: mountPoint, runner: scoped) == target else {
            throw ProbeFailure("扫描期间目标盘或关联卷已变化，请重新检测")
        }
        return EjectPlan(target: target, createdAt: now(), holders: result.value?.holders ?? [],
                         images: images.value ?? [],
                         issues: result.issues + (result.value?.issues ?? []) + images.issues)
    }

    /// No side effect until preflight either needs no preparation or receives confirmation.
    func run(indexingOn: Bool?) -> Outcome {
        do {
            let plan = try prepare(indexingOn: indexingOn)
            if plan.requiresConfirmation { return .preview(plan) }
            return execute(plan, systemOnly: false)
        } catch { return .aborted(error.localizedDescription) }
    }

    func execute(_ approved: EjectPlan, systemOnly: Bool) -> Outcome {
        let started = now()
        stoppedApps = approved.completedApps; stoppedDaemons = approved.completedDaemons; detachedImages = approved.completedImages
        steps = [Step(id: "validate", title: "确认目标及操作范围"),
                 Step(id: "apps", title: "请求应用退出"), Step(id: "daemons", title: "停止限定后台服务"),
                 Step(id: "images", title: "推出只读磁盘映像"), Step(id: "recheck", title: "复查占用"),
                 Step(id: "unmount", title: "系统弹出"), Step(id: "verify", title: "核验弹出结果")]
        emit()
        do {
            set("validate", .running)
            try cancellation.check()
            guard try targets.target(at: mountPoint, runner: scoped) == approved.target else {
                throw ProbeFailure("目标身份或关联卷已变化，请重新检测")
            }
            if now().timeIntervalSince(approved.createdAt) > 30 {
                return previewOutcome(try prepare())
            }
            if systemOnly {
                guard approved.canSystemOnly else { throw ProbeFailure("此预检不允许跳过准备步骤") }
                set("validate", .done("仅尝试普通系统弹出，不处理应用、服务或映像"))
                for id in ["apps", "daemons", "images", "recheck"] { set(id, .skipped("由用户选择仅尝试系统弹出")) }
            } else {
                let fresh = try prepare()
                guard fresh.target == approved.target else { throw ProbeFailure("目标盘已变化") }
                guard fresh.canPrepare, fresh.processScope.isSubset(of: approved.processScope),
                      fresh.images.allSatisfy({ approved.images.contains($0) }) else { return previewOutcome(fresh) }
                set("validate", .done("操作范围已核验"))
                for (id, list) in [("apps", fresh.apps), ("daemons", fresh.daemons)] {
                    set(id, .running)
                    if list.isEmpty { set(id, .skipped("没有需要处理的对象")); continue }
                    for holder in list {
                        try cancellation.check()
                        // Recheck both file evidence and identity immediately before each action.
                        let current = try prepare()
                        guard current.target == approved.target else { throw ProbeFailure("目标盘已变化") }
                        guard current.canPrepare, current.processScope.isSubset(of: approved.processScope),
                              current.images.allSatisfy({ approved.images.contains($0) }) else { return previewOutcome(current) }
                        guard let identity = holder.identity,
                              current.holders.contains(where: { $0.identity == identity && $0.kind == holder.kind }) else { continue }
                        guard let live = try inspector.identity(identity.pid) else { continue }
                        guard live == identity, live.uid == getuid() else { throw ProbeFailure("进程身份已变化，请重新检测") }
                        try cancellation.check()
                        if id == "apps" {
                            try inspector.requestQuit(identity)
                        } else {
                            let r = try scoped.run(Tool.kill, ["-TERM", String(identity.pid)])
                            try r.requireSuccess("停止服务")
                        }
                        set(id, .running)
                        try waitForExit(identity)
                        if id == "apps" { stoppedApps += 1 } else { stoppedDaemons += 1 }
                    }
                    set(id, .done(id == "apps" ? "确认退出 \(stoppedApps) 个应用" : "确认停止 \(stoppedDaemons) 个进程"))
                }
                set("images", .running)
                for image in fresh.images {
                    try cancellation.check()
                    let current = try prepare()
                    guard current.target == approved.target else { throw ProbeFailure("目标盘已变化") }
                    guard current.canPrepare, current.processScope.isSubset(of: approved.processScope),
                          current.images.allSatisfy({ approved.images.contains($0) }) else { return previewOutcome(current) }
                    guard current.images.contains(image) else { continue }
                    try cancellation.check()
                    guard DiskImageProbe(runner: scoped).detach(image) else { throw ProbeFailure("无法推出映像 \(image.name)") }
                    detachedImages += 1
                }
                set("images", fresh.images.isEmpty ? .skipped("没有需要推出的映像") : .done("已推出 \(detachedImages) 个映像"))
                set("recheck", .running)
                let final = try prepare()
                guard final.target == approved.target else { throw ProbeFailure("目标盘已变化") }
                if final.requiresConfirmation { return previewOutcome(final) }
                set("recheck", .done("未发现当前用户的占用；系统仍将检查是否允许弹出"))
            }
            try cancellation.check()
            guard try targets.target(at: mountPoint, runner: scoped) == approved.target else {
                throw ProbeFailure("弹出前目标身份或关联卷已变化")
            }
            guard cancellation.commit() else { throw ProbeFailure("操作已中止") }
            onCommit()
            set("unmount", .running)
            let r = try runner.run(Tool.diskutil, ["eject", approved.target.physicalDisk], timeout: Deadline.eject)
            set("verify", .running)
            let gone = try targets.isEjected(approved.target, runner: runner)
            if gone && (r.ok || r.timedOut) {
                set("unmount", .done(r.timedOut ? "系统命令超时，但已核验磁盘离线" : "系统已弹出"))
                set("verify", .done("物理盘已离线，关联卷已卸载"))
                return .ejected(now().timeIntervalSince(started), stoppedApps: stoppedApps, stoppedDaemons: stoppedDaemons)
            }
            if r.timedOut || r.ok {
                throw ProbeFailure("弹出结果未知：尚未核验磁盘离线，请勿拔线，刷新后检查")
            }
            throw ProbeFailure(Self.dissenterMessage(r.text + "\n" + r.stderr) ?? "系统拒绝弹出")
        } catch {
            let reason = cancellation.isCommitted ? "\(error.localizedDescription)；未确认可拔线。" : error.localizedDescription
            for step in steps where step.state == .running { set(step.id, .failed(reason)) }
            return .aborted(reason + "\n" + completedDetail)
        }
    }

    private func previewOutcome(_ plan: EjectPlan) -> Outcome {
        var updated = plan
        updated.completedApps = stoppedApps
        updated.completedDaemons = stoppedDaemons
        updated.completedImages = detachedImages
        return .preview(updated)
    }

    private func waitForExit(_ expected: ProcessIdentity) throws {
        let end = now().addingTimeInterval(quitTimeout)
        while now() < end {
            try cancellation.check()
            guard let live = try inspector.identity(expected.pid) else { return }
            if live != expected { return } // the original instance ended; never signal its replacement
            sleep(0.1)
        }
        throw ProbeFailure("\(expected.appName ?? "PID \(expected.pid)") 仍在运行；请处理保存对话框或手动停止后重试")
    }

    static func secs(_ t: TimeInterval) -> String {
        t < 1 ? String(format: "%.0f 毫秒", t * 1000) : String(format: "%.1f 秒", t)
    }
    // MARK: - Parsing

    /// diskutil names the blocking process when an unmount is refused. Two formats
    /// occur, both verified against real output:
    ///
    ///     Unmount was dissented by PID 12167 (/usr/bin/tail)
    ///     Dissenter PID=1234 (ProcessName) status=0x0000c010 (kDAReturnBusy)
    ///
    /// Both patterns are anchored on their distinctive prefix so the follow-up
    /// "Dissenter parent PPID 12165 (/bin/zsh)" line cannot be mistaken for the
    /// culprit — reporting the parent shell instead of the real holder would send
    /// the user chasing the wrong process.
    static func dissenterMessage(_ text: String) -> String? {
        let patterns = [
            #"dissented by PID\s+(\d+)(?:\s*\(([^)]*)\))?"#,
            #"Dissenter PID=(\d+)(?:\s*\(([^)]*)\))?"#,
        ]
        for pattern in patterns {
            guard let re = try? NSRegularExpression(
                    pattern: pattern, options: [.caseInsensitive]),
                  let m = re.firstMatch(
                    in: text, range: NSRange(text.startIndex..., in: text))
            else { continue }

            func group(_ i: Int) -> String? {
                guard let r = Range(m.range(at: i), in: text) else { return nil }
                let v = String(text[r]).trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }
            guard let pid = group(1) else { continue }
            // The name often arrives as a full path (/usr/bin/tail).
            let name = group(2).map { ($0 as NSString).lastPathComponent }
            return name.map { "被 \($0)（PID \(pid)）阻塞" } ?? "被 PID \(pid) 阻塞"
        }

        let line = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return line.map { "卸载失败：\($0)" }
    }

    // MARK: - Step bookkeeping

    private func set(_ id: String, _ state: StepState) {
        guard let i = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[i].state = state
        emit()
    }

    private func emit() { onUpdate(steps) }
}
