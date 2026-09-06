import Foundation

/// Runs the safe-eject sequence. GUI applications are asked to quit through
/// AppleScript so they can raise their own save dialogs — they are never killed. If
/// the user cancels such a dialog the whole flow stops and says so, rather than
/// escalating.
final class EjectFlow {
    enum StepState: Equatable {
        case pending
        case running
        case done(String?)       // optional detail
        case skipped(String)
        case failed(String)
    }

    struct Step: Identifiable, Equatable {
        let id: String
        let title: String
        var state: StepState = .pending
        var detail: String? {
            switch state {
            case .done(let d):     return d
            case .skipped(let d):  return d
            case .failed(let d):   return d
            default:               return nil
            }
        }
    }

    enum Outcome: Equatable {
        case ejected(TimeInterval, stoppedApps: Int, stoppedDaemons: Int)
        case aborted(String)
    }

    let runner: CommandRunner
    let mountPoint: String
    /// Seconds to wait for a GUI app to disappear after the quit request.
    var quitTimeout: TimeInterval = 20
    /// Injectable so tests do not actually sleep.
    var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    var now: () -> Date = Date.init

    private(set) var steps: [Step] = []
    var onUpdate: ([Step]) -> Void = { _ in }

    init(runner: CommandRunner = SystemCommandRunner(), mountPoint: String) {
        self.runner = runner
        self.mountPoint = mountPoint
    }

    // MARK: - Run

    func run(indexingOn: Bool?) -> Outcome {
        let started = now()
        let occ = Occupancy(runner: runner)

        steps = [
            Step(id: "scan",     title: "扫描占用者"),
            Step(id: "apps",     title: "请求应用退出"),
            Step(id: "daemons",  title: "停止守护进程"),
            Step(id: "recheck",  title: "复查占用"),
            Step(id: "unmount",  title: "卸载卷"),
        ]
        emit()

        // 1 — who is holding it
        set("scan", .running)
        let report: OccupancyReport
        do {
            report = try occ.quickScan(mountPoint: mountPoint, indexingOn: indexingOn)
        } catch {
            set("scan", .failed(error.localizedDescription))
            return .aborted("无法扫描占用进程：\(error.localizedDescription)")
        }
        let apps = report.holders(.guiApp)
        let daemons = report.holders(.daemon)
        set("scan", .done("发现 \(apps.count) 个应用、\(daemons.count) 个守护进程"))

        // 2 — ask GUI apps to quit
        set("apps", .running)
        if apps.isEmpty {
            set("apps", .skipped("没有需要退出的应用"))
        } else {
            for app in apps {
                if let refusal = quit(app) {
                    set("apps", .failed(refusal))
                    return .aborted(refusal)
                }
            }
            set("apps", .done(apps.map(\.name).joined(separator: "、") + " 已退出"))
        }

        // 3 — stop daemons (no unsaved state; they restart on demand)
        set("daemons", .running)
        if daemons.isEmpty {
            set("daemons", .skipped("没有运行中的守护进程"))
        } else {
            var stopped = 0
            for d in daemons where !d.pids.isEmpty {
                let r = try? runner.run(Tool.kill, ["-TERM"] + d.pids.map(String.init))
                if r?.ok == true { stopped += d.pids.count }
            }
            set("daemons", .done("\(stopped) 个进程已结束"))
        }

        // 4 — recheck. Deliberately the slow lsof path rather than the pattern-matching
        // quick scan: this is the last check before committing, and the quick scan only
        // knows about dev tooling. Measured against the real volume it costs ~1s, and
        // without it the step cheerfully reports "nothing of yours is holding it" one
        // line before the unmount fails on a process the pattern list never knew about.
        set("recheck", .running)
        let after = (try? occ.fullScan(mountPoint: mountPoint, indexingOn: indexingOn))?.mine ?? []
        if after.isEmpty {
            set("recheck", .done("已无你的进程占用"))
        } else {
            let names = after.map { h in
                h.openFileCount.map { "\(h.name) 持有 \($0) 个文件" } ?? h.name
            }
            set("recheck", .done("仍有 " + names.joined(separator: "、")))
        }

        // 5 — unmount. diskutil's dissenter PID is the authoritative answer when this
        // fails, and is the only place we can obtain it.
        set("unmount", .running)
        let r = try? runner.run(Tool.diskutil, ["eject", mountPoint])
        guard let r, r.ok else {
            let raw = [r?.text ?? "", r?.stderr ?? ""].joined(separator: "\n")
            let msg = Self.dissenterMessage(raw) ?? "卸载失败，卷仍在使用中"
            set("unmount", .failed(msg))
            return .aborted(msg)
        }
        set("unmount", .done(nil))

        return .ejected(now().timeIntervalSince(started),
                        stoppedApps: apps.count,
                        stoppedDaemons: daemons.count)
    }

    // MARK: - Quitting a GUI app

    /// Returns nil on success, or a message explaining why the app is still running.
    private func quit(_ app: Holder) -> String? {
        let target = app.bundleID.map { "application id \"\($0)\"" }
            ?? "application \"\(app.name)\""
        _ = try? runner.run(Tool.osascript, ["-e", "tell \(target) to quit"])

        let deadline = now().addingTimeInterval(quitTimeout)
        while now() < deadline {
            if !isRunning(app) { return nil }
            sleep(0.5)
        }
        return isRunning(app)
            ? "\(app.name) 仍在运行——保存对话框可能在等你，流程已中止"
            : nil
    }

    private func isRunning(_ app: Holder) -> Bool {
        guard let procs = try? Occupancy(runner: runner).processes() else { return false }
        if !app.pids.isEmpty {
            let live = Set(procs.map(\.pid))
            return app.pids.contains { live.contains($0) }
        }
        return procs.contains { Occupancy.classify($0)?.display == app.name }
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
