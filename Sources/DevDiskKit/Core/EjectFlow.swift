import Foundation

struct EjectPlan: Equatable {
    let target: EjectTarget
    let createdAt: Date
    let holders: [Holder]
    let images: [DiskImage]
    let issues: [Message]
    var completedApps: Int = 0
    var completedDaemons: Int = 0
    var completedImages: Int = 0
    var selectedTasks: Set<ProcessIdentity> = []
    var requested: [ProcessIdentity: HolderKind] = [:]
    var credited: Set<ProcessIdentity> = []
    var notice: Message? = nil
    var failure: EjectFailure? = nil
    var manual: [Holder] { holders.filter { $0.kind == .manual } }
    var apps: [Holder] { holders.filter { $0.kind == .guiApp } }
    var daemons: [Holder] { holders.filter { $0.kind == .daemon } }
    var writableImages: [DiskImage] { images.filter { $0.writable || !$0.accessKnown } }
    var incomplete: Bool { !issues.isEmpty }
    var canPrepare: Bool { canPrepare(approvedTasks: selectedTasks) }
    func canPrepare(approvedTasks: Set<ProcessIdentity>) -> Bool {
        !incomplete && writableImages.isEmpty && !target.multipleVolumes
            && manual.allSatisfy { $0.canTerminateTask && $0.identity.map(approvedTasks.contains) == true }
    }
    var needsContinuation: Bool { !requested.isEmpty }
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
        case pending, running, done(Message?), skipped(Message), failed(Message)
    }
    struct Step: Identifiable, Equatable {
        let id: String
        let title: Message
        var state: StepState = .pending
        var detail: Message? {
            switch state {
            case .done(let d): return d
            case .skipped(let d), .failed(let d): return d
            default: return nil
            }
        }
    }
    enum Outcome: Equatable {
        case ejected(TimeInterval, stoppedApps: Int, stoppedDaemons: Int)
        case aborted(Message)
        case preview(EjectPlan)
        case verificationPending(EjectFailure, Message)
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
    var monotonicNow: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var verificationTimeout: TimeInterval = 10
    var verificationInterval: TimeInterval = 0.25
    private(set) var steps: [Step] = []
    var onUpdate: ([Step]) -> Void = { _ in }
    var onCommit: () -> Void = {}
    var onSystemReturned: () -> Void = {}
    var onFailure: (EjectFailure) -> Void = { _ in }
    var onVerifiedEject: (Message) -> Void = { _ in }
    private(set) var lastFailure: EjectFailure?
    private var requested: [ProcessIdentity: HolderKind] = [:]
    private var credited: Set<ProcessIdentity> = []
    private var selectedTasks: Set<ProcessIdentity> = []
    private var lastCommandOutput = ""
    private var stoppedApps = 0
    private var stoppedDaemons = 0
    private var detachedImages = 0
    private var completedDetail: Message {
        M("ejectflow.apps.quit.service.processes.stopped.images.ejected.requests", stoppedApps, stoppedDaemons, detachedImages)
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
            throw ProbeFailure(M("ejectflow.the.selected.volume.s.identity.changed.select.it"))
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
            throw ProbeFailure(M("ejectflow.the.target.drive.or.related.volumes.changed.during"))
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
        } catch { return .aborted(error.displayMessage) }
    }

    func execute(_ approved: EjectPlan, systemOnly: Bool) -> Outcome {
        let started = now()
        stoppedApps = approved.completedApps; stoppedDaemons = approved.completedDaemons; detachedImages = approved.completedImages
        selectedTasks = approved.selectedTasks; requested = approved.requested; credited = approved.credited
        lastFailure = approved.failure; lastCommandOutput = ""
        steps = [Step(id: "validate", title: M("ejectflow.verify.target.and.scope")),
                 Step(id: "apps", title: M("ejectflow.request.apps.to.quit")), Step(id: "daemons", title: M("ejectflow.stop.approved.background.services")),
                 Step(id: "images", title: M("ejectflow.eject.read.only.disk.images")), Step(id: "recheck", title: M("ejectflow.recheck.open.files")),
                 Step(id: "unmount", title: M("ejectflow.ask.macos.to.eject")), Step(id: "verify", title: M("ejectflow.verify.eject.result"))]
        emit()
        do {
            set("validate", .running)
            try cancellation.check()
            guard try targets.target(at: mountPoint, runner: scoped) == approved.target else {
                throw ProbeFailure(M("ejectflow.the.target.s.identity.or.related.volumes.changed"))
            }
            if now().timeIntervalSince(approved.createdAt) > 30 {
                return previewOutcome(try prepare())
            }
            if systemOnly {
                guard approved.canSystemOnly else { throw ProbeFailure(M("ejectflow.this.preflight.does.not.allow.preparation.to.be")) }
                set("validate", .done(M("ejectflow.only.attempt.a.normal.system.eject.leave.apps")))
                for id in ["apps", "daemons", "images", "recheck"] { set(id, .skipped(M("ejectflow.user.chose.to.attempt.system.eject.only"))) }
            } else {
                // Account for requests completed while the user handled a save dialog.
                for identity in requested.keys where !credited.contains(identity) {
                    if try inspector.identity(identity.pid) != identity { creditExit(identity) }
                }
                let fresh = try prepare()
                guard fresh.target == approved.target else { throw ProbeFailure(M("ejectflow.the.target.drive.changed")) }
                guard fresh.canPrepare(approvedTasks: selectedTasks), fresh.processScope.isSubset(of: approved.processScope),
                      fresh.images.allSatisfy({ approved.images.contains($0) }) else { return previewOutcome(fresh) }
                set("validate", .done(M("ejectflow.operation.scope.verified")))
                for (id, list) in [("apps", fresh.apps), ("daemons", fresh.daemons + fresh.manual)] {
                    set(id, .running)
                    if list.isEmpty { set(id, .skipped(M("ejectflow.nothing.needs.to.be.handled"))); continue }
                    for holder in list {
                        try cancellation.check()
                        // Recheck both file evidence and identity immediately before each action.
                        let current = try prepare()
                        guard current.target == approved.target else { throw ProbeFailure(M("ejectflow.the.target.drive.changed")) }
                        guard current.canPrepare(approvedTasks: selectedTasks), current.processScope.isSubset(of: approved.processScope),
                              current.images.allSatisfy({ approved.images.contains($0) }) else { return previewOutcome(current) }
                        guard let identity = holder.identity,
                              current.holders.contains(where: { $0.identity == identity && $0.kind == holder.kind }) else { continue }
                        guard let live = try inspector.identity(identity.pid) else { continue }
                        guard live == identity, live.uid == getuid(), !live.isProtectedService else { throw ProbeFailure(M("ejectflow.process.identity.changed.scan.again")) }
                        try cancellation.check()
                        if requested[identity] == nil {
                            requested[identity] = holder.kind
                            if id == "apps" {
                                do { try inspector.requestQuit(identity) }
                                catch {
                                    recordFailure(approved.target, stage: id, message: error.displayMessage, blockingPID: identity.pid)
                                    return previewOutcome(current, notice: error.displayMessage)
                                }
                            } else {
                                guard holder.kind == .daemon || (holder.canTerminateTask && selectedTasks.contains(identity)) else {
                                    return previewOutcome(current)
                                }
                                let r = try scoped.run(Tool.kill, ["-TERM", String(identity.pid)])
                                lastCommandOutput = r.text + r.stderr
                                try r.requireSuccess(M("ejectflow.stop.service"))
                            }
                        }
                        set(id, .running)
                        switch try waitForRelease(identity) {
                        case .exited: creditExit(identity)
                        case .released: break
                        case .waiting:
                            let message = M("ejectflow.waiting.for.release", holder.displayName)
                            recordFailure(approved.target, stage: id, message: message, blockingPID: identity.pid)
                            return previewOutcome(try prepare(), notice: message)
                        }
                    }
                    set(id, .done(id == "apps" ? M("ejectflow.apps.confirmed.quit", stoppedApps) : M("ejectflow.processes.confirmed.stopped", stoppedDaemons)))
                }
                set("images", .running)
                for image in fresh.images {
                    try cancellation.check()
                    let current = try prepare()
                    guard current.target == approved.target else { throw ProbeFailure(M("ejectflow.the.target.drive.changed")) }
                    guard current.canPrepare(approvedTasks: selectedTasks), current.processScope.isSubset(of: approved.processScope),
                          current.images.allSatisfy({ approved.images.contains($0) }) else { return previewOutcome(current) }
                    guard current.images.contains(image) else { continue }
                    try cancellation.check()
                    guard DiskImageProbe(runner: scoped).detach(image) else { throw ProbeFailure(M("ejectflow.could.not.eject.image", image.name)) }
                    detachedImages += 1
                }
                set("images", fresh.images.isEmpty ? .skipped(M("ejectflow.no.images.to.eject")) : .done(M("ejectflow.images.ejected", detachedImages)))
                set("recheck", .running)
                let final = try prepare()
                guard final.target == approved.target else { throw ProbeFailure(M("ejectflow.the.target.drive.changed")) }
                if final.requiresConfirmation { return previewOutcome(final) }
                set("recheck", .done(M("ejectflow.no.open.files.found.for.the.current.user")))
            }
            return try ejectWithRecovery(approved, systemOnly: systemOnly, started: started)
        } catch {
            let reason = cancellation.isCommitted ? M("ejectflow.it.is.not.confirmed.safe.to.unplug", error.displayMessage) : error.displayMessage
            recordFailure(approved.target, stage: steps.first(where: { $0.state == .running })?.id ?? lastFailure?.stage ?? "validate", message: reason)
            for step in steps where step.state == .running { set(step.id, .failed(reason)) }
            return .aborted(reason + "\n" + completedDetail)
        }
    }

    /// Read-only refresh keeps completed actions and pending quit requests.
    func recheck(_ previous: EjectPlan) -> Outcome {
        stoppedApps = previous.completedApps; stoppedDaemons = previous.completedDaemons
        detachedImages = previous.completedImages; selectedTasks = previous.selectedTasks
        requested = previous.requested; credited = previous.credited; lastFailure = previous.failure
        do {
            let fresh = try prepare()
            guard fresh.target == previous.target else { throw ProbeFailure(M("ejectflow.the.target.drive.changed")) }
            return previewOutcome(fresh, notice: previous.notice)
        } catch { return .aborted(error.displayMessage) }
    }

    /// Rechecks only the post-eject state. It never sends another eject request or
    /// repeats process actions, so a late Disk Arbitration update can safely repair
    /// a previously pending result.
    func reverify(_ previous: EjectFailure) -> Outcome {
        stoppedApps = previous.completedApps
        stoppedDaemons = previous.completedProcesses
        detachedImages = previous.completedImages
        lastCommandOutput = previous.commandOutput
        steps = [Step(id: "verify", title: M("ejectflow.verify.eject.result"), state: .running)]
        onUpdate(steps)
        let started = now()
        let commandSucceeded = previous.commandExitCode == 0
            && !previous.commandTimedOut && !previous.commandCancelled
        let (verification, duration) = waitForEject(previous.target,
                                                    acceptUnmounted: commandSucceeded)
        if confirmsEject(verification, acceptUnmounted: commandSucceeded) {
            let detail = verification.state == .offline
                ? M("ejectflow.physical.disk.offline.related.volumes.unmounted")
                : M("ejectflow.system.eject.confirmed.related.volumes.unmounted")
            set("verify", .done(detail))
            onVerifiedEject(detail)
            return .ejected(now().timeIntervalSince(started), stoppedApps: stoppedApps, stoppedDaemons: stoppedDaemons)
        }
        let reason = M("ejectflow.eject.result.pending.verification")
        let updated = EjectFailure(target: previous.target, stage: "verify", message: reason,
                                   commandOutput: previous.commandOutput,
                                   blockingPID: previous.blockingPID,
                                   completedApps: stoppedApps, completedProcesses: stoppedDaemons,
                                   completedImages: detachedImages,
                                   commandExitCode: previous.commandExitCode,
                                   commandTimedOut: previous.commandTimedOut,
                                   commandCancelled: previous.commandCancelled,
                                   verificationDuration: duration, verification: verification)
        lastFailure = updated
        onFailure(updated)
        set("verify", .failed(reason))
        return .verificationPending(updated, reason + "\n" + completedDetail)
    }

    private func previewOutcome(_ plan: EjectPlan, notice: Message? = nil) -> Outcome {
        var updated = plan
        updated.completedApps = stoppedApps
        updated.completedDaemons = stoppedDaemons
        updated.completedImages = detachedImages
        updated.selectedTasks = selectedTasks.intersection(plan.processScope)
        updated.requested = requested
        updated.credited = credited
        updated.notice = notice
        updated.failure = lastFailure
        return .preview(updated)
    }

    private enum ReleaseState { case exited, released, waiting }

    private func waitForRelease(_ expected: ProcessIdentity) throws -> ReleaseState {
        let end = now().addingTimeInterval(quitTimeout)
        while now() < end {
            try cancellation.check()
            guard let live = try inspector.identity(expected.pid) else { return .exited }
            if live != expected { return .exited } // never signal its replacement
            var occupancy = Occupancy(runner: scoped); occupancy.inspector = inspector
            let report = try occupancy.fullScan(mountPoint: mountPoint, indexingOn: nil)
            guard report.state == .complete else {
                throw ProbeFailure(report.issues.first ?? M("occupancy.open.file.scan.incomplete"))
            }
            if !report.holders.contains(where: { $0.identity == expected }) { return .released }
            sleep(0.1)
        }
        return .waiting
    }

    private func creditExit(_ identity: ProcessIdentity) {
        guard let kind = requested[identity], credited.insert(identity).inserted else { return }
        if kind == .guiApp { stoppedApps += 1 } else { stoppedDaemons += 1 }
    }

    @discardableResult
    private func recordFailure(_ target: EjectTarget, stage: String, message: Message,
                               blockingPID: Int32? = nil, command: CommandResult? = nil,
                               verification: EjectVerification? = nil,
                               verificationDuration: TimeInterval? = nil) -> EjectFailure {
        let failure = EjectFailure(target: target, stage: stage, message: message,
                                   commandOutput: String(lastCommandOutput.prefix(16_384)),
                                   blockingPID: blockingPID ?? EjectFailure.blockingPID(in: lastCommandOutput),
                                   completedApps: stoppedApps, completedProcesses: stoppedDaemons,
                                   completedImages: detachedImages,
                                   commandExitCode: command?.exitCode,
                                   commandTimedOut: command?.timedOut ?? false,
                                   commandCancelled: command?.cancelled ?? false,
                                   verificationDuration: verificationDuration,
                                   verification: verification)
        lastFailure = failure
        onFailure(failure)
        return failure
    }

    private func confirmsEject(_ verification: EjectVerification,
                               acceptUnmounted: Bool) -> Bool {
        verification.confirmedOffline
            || (acceptUnmounted && verification.state == .unmounted)
    }

    private func waitForEject(_ target: EjectTarget,
                              acceptUnmounted: Bool) -> (EjectVerification, TimeInterval) {
        let started = monotonicNow()
        let deadline = started + verificationTimeout
        var latest = targets.ejectVerification(target, runner: runner,
                                                timeout: max(0.05, min(Deadline.quick, verificationTimeout)))
        while !confirmsEject(latest, acceptUnmounted: acceptUnmounted)
                && monotonicNow() < deadline {
            let delay = min(verificationInterval, deadline - monotonicNow())
            if delay > 0 { sleep(delay) }
            let remaining = max(0.05, deadline - monotonicNow())
            latest = targets.ejectVerification(target, runner: runner,
                                                timeout: min(Deadline.quick, remaining))
        }
        return (latest, max(0, monotonicNow() - started))
    }

    private func ejectWithRecovery(_ approved: EjectPlan, systemOnly: Bool, started: Date) throws -> Outcome {
        for attempt in 1...3 {
            try cancellation.check()
            guard try targets.target(at: mountPoint, runner: scoped) == approved.target else {
                throw ProbeFailure(M("ejectflow.the.target.s.identity.or.related.volumes.changed.e989"))
            }
            guard cancellation.commit() else { throw ProbeFailure(M("ejectflow.operation.cancelled")) }
            onCommit()
            set("unmount", .running)
            let r = try runner.run(Tool.diskutil, ["eject", approved.target.physicalDisk], timeout: Deadline.eject)
            lastCommandOutput = r.text + "\n" + r.stderr
            if r.ok { set("unmount", .done(M("ejectflow.macos.finished.the.eject.request"))) }
            set("verify", .running)
            let (verification, verificationDuration) = waitForEject(approved.target,
                                                                     acceptUnmounted: r.ok)
            if confirmsEject(verification, acceptUnmounted: r.ok) {
                set("unmount", .done(r.timedOut ? M("ejectflow.system.command.timed.out.but.the.disk.was") : M("ejectflow.macos.ejected.the.disk")))
                let detail = verification.state == .offline
                    ? M("ejectflow.physical.disk.offline.related.volumes.unmounted")
                    : M("ejectflow.system.eject.confirmed.related.volumes.unmounted")
                set("verify", .done(detail))
                onVerifiedEject(detail)
                return .ejected(now().timeIntervalSince(started), stoppedApps: stoppedApps, stoppedDaemons: stoppedDaemons)
            }
            if r.timedOut || r.cancelled || r.ok {
                let reason = M("ejectflow.eject.result.pending.verification")
                let failure = recordFailure(approved.target, stage: "verify", message: reason,
                                            command: r, verification: verification,
                                            verificationDuration: verificationDuration)
                set("verify", .failed(reason))
                return .verificationPending(failure, reason + "\n" + completedDetail)
            }
            // A definite refusal has completed. It is now safe to cancel/reconfirm.
            cancellation.finishRefusedAttempt()
            onSystemReturned()
            let reason = Self.dissenterMessage(lastCommandOutput) ?? M("ejectflow.macos.refused.to.eject.the.disk")
            recordFailure(approved.target, stage: "unmount", message: reason, command: r,
                          verification: verification, verificationDuration: verificationDuration)
            set("unmount", .failed(reason)); set("verify", .done(M("ejectflow.disk.still.connected")))
            let fresh = try prepare()
            guard fresh.target == approved.target else { throw ProbeFailure(M("ejectflow.the.target.drive.changed")) }
            // Never turn a dissenter PID alone into permission to signal it: only
            // fresh file evidence and verified identity can enable preparation.
            if !fresh.processScope.isEmpty || !fresh.images.isEmpty {
                return previewOutcome(fresh, notice: reason)
            }
            guard !fresh.incomplete, !systemOnly || !approved.incomplete,
                  EjectFailure.isTransientBusy(lastCommandOutput), attempt < 3 else {
                throw ProbeFailure(reason)
            }
            set("unmount", .pending)
            set("verify", .pending)
            let retryAt = now().addingTimeInterval(Double(attempt))
            while now() < retryAt {
                try cancellation.check()
                sleep(0.1)
            }
            let next = try prepare()
            guard next.target == approved.target else { throw ProbeFailure(M("ejectflow.the.target.drive.changed")) }
            if next.incomplete || !next.processScope.isEmpty || !next.images.isEmpty {
                return previewOutcome(next, notice: reason)
            }
        }
        throw ProbeFailure(M("ejectflow.macos.refused.to.eject.the.disk"))
    }

    static func secs(_ t: TimeInterval) -> String {
        t < 1 ? String(format: L("ejectflow.f.ms"), t * 1000) : String(format: L("ejectflow.f.s"), t)
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
    static func dissenterMessage(_ text: String) -> Message? {
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
            return name.map { M("ejectflow.blocked.by.pid", $0, pid) } ?? M("ejectflow.blocked.by.pid.7388", pid)
        }

        let line = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return line.map { M("ejectflow.unmount.failed", $0) }
    }

    // MARK: - Step bookkeeping

    private func set(_ id: String, _ state: StepState) {
        guard let i = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[i].state = state
        emit()
    }

    private func emit() { onUpdate(steps) }
}
