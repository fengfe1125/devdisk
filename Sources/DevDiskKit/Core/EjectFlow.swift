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
            Step(id: "images",   title: "推出磁盘映像"),
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
        set("scan", .done("发现 \(apps.count) 个应用、\(daemons.count) 个守护进程 · "
                          + Self.secs(now().timeIntervalSince(started))))

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

        // 3.5 — attached disk images backed by files on this volume.
        //
        // diskimages-helper holds the .dmg open, so the volume cannot unmount, and
        // diskutil names that helper as the dissenter — a launchd-owned system
        // process the user can neither kill nor act on. An image can also be
        // attached without being mounted, in which case it has no Finder presence
        // at all and there is literally nothing for the user to eject. Read-only
        // images carry no user data, so they are detached here; writable ones might,
        // so those stop the flow and are named.
        set("images", .running)
        let imageProbe = DiskImageProbe(runner: runner)
        let images = (try? imageProbe.images(on: mountPoint)) ?? []

        if images.isEmpty {
            set("images", .skipped("盘上没有已挂载的磁盘映像"))
        } else {
            let writable = images.filter(\.writable)
            if !writable.isEmpty {
                let names = Set(writable.map(\.name)).sorted().joined(separator: "、")
                let msg = "盘上有可写的磁盘映像正挂载着：\(names)。先手动推出它，以免丢失其中的改动。"
                set("images", .failed(msg))
                return .aborted(msg)
            }
            var detached = 0
            for image in images where imageProbe.detach(image) { detached += 1 }
            let names = Set(images.map(\.name)).sorted().joined(separator: "、")
            if detached == images.count {
                set("images", .done("已推出 \(names)"))
            } else {
                let msg = "无法推出磁盘映像 \(names)，卷会因此拒绝卸载"
                set("images", .failed(msg))
                return .aborted(msg)
            }
        }

        // 4 — recheck. Deliberately the slow lsof path rather than the pattern-matching
        // quick scan: this is the last check before committing, and the quick scan only
        // knows about dev tooling. Measured against the real volume it costs ~1s, and
        // without it the step cheerfully reports "nothing of yours is holding it" one
        // line before the unmount fails on a process the pattern list never knew about.
        set("recheck", .running)
        let recheckStart = now()
        let after = (try? occ.fullScan(mountPoint: mountPoint, indexingOn: indexingOn))?.mine ?? []
        let recheckTook = Self.secs(now().timeIntervalSince(recheckStart))
        let leftovers = after.map(\.name)
        if after.isEmpty {
            set("recheck", .done("已无你的进程占用 · " + recheckTook))
        } else {
            let names = after.map { h in
                h.openFileCount.map { "\(h.name) 持有 \($0) 个文件" } ?? h.name
            }
            set("recheck", .done("仍有 " + names.joined(separator: "、") + " · " + recheckTook))
        }

        // 5 — unmount. diskutil's dissenter PID is the authoritative answer when this
        // fails, and is the only place we can obtain it.
        set("unmount", .running)
        let unmountStart = now()
        let r = try? runner.run(Tool.diskutil, ["eject", mountPoint],
                                timeout: Deadline.eject)
        let unmountTook = now().timeIntervalSince(unmountStart)

        // A timeout is not the same as a refusal, and saying so matters: diskutil
        // can wedge waiting on diskarbitrationd, and "卸载失败，卷仍在使用中"
        // would send the user hunting for a process that does not exist.
        if r?.timedOut == true {
            let msg = "卸载超时（\(Int(Deadline.eject)) 秒），diskutil 无响应"
            set("unmount", .failed(msg))
            return .aborted(msg)
        }
        guard let r, r.ok else {
            let raw = [r?.text ?? "", r?.stderr ?? ""].joined(separator: "\n")
            var msg = Self.dissenterMessage(raw) ?? "卸载失败，卷仍在使用中"
            // diskutil names whichever process it happened to ask — often a parent
            // shell rather than the one actually writing. The recheck saw the whole
            // set, so name the others too instead of sending the user after a shell.
            let others = leftovers.filter { !msg.contains($0) }
            if !others.isEmpty {
                msg += "；还有 " + others.joined(separator: "、") + " 在持有它"
            }
            set("unmount", .failed(msg))
            return .aborted(msg)
        }
        set("unmount", .done(Self.secs(unmountTook)))

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

    /// Step durations are shown in the UI so a slow step is visibly slow rather than
    /// indistinguishable from a wedged one.
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
