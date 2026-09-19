import Foundation

enum EjectMode { case prepared, systemOnly, force }

struct EjectPlan: Equatable {
    let target: EjectTarget
    let createdAt: Date
    let holders: [Holder]
    let images: [DiskImage]
    let issues: [Message]
    var imagesKnown = true
    var forceConfirmation = false
    var forceUsed = false
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
        !incomplete && !target.multipleVolumes
            && manual.allSatisfy { $0.canTerminateTask && $0.identity.map(approvedTasks.contains) == true }
    }
    var needsContinuation: Bool { !requested.isEmpty }
    var requiresConfirmation: Bool {
        incomplete || target.multipleVolumes || !manual.isEmpty || !images.isEmpty || !apps.isEmpty || !daemons.isEmpty
    }
    var canSystemOnly: Bool { true }
    var canForce: Bool {
        imagesKnown && failure?.allowsForce == true && !target.affected.isEmpty
            && target.affected.allSatisfy { !$0.uuid.isEmpty }
    }
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
        case ejected(TimeInterval, stoppedApps: Int, stoppedDaemons: Int, forced: Bool = false)
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
    private var forceUsed = false
    private var relatedImages: [DiskImage] = []
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

    func prepare(indexingOn: Bool? = nil, unmountedTarget: EjectTarget? = nil) throws -> EjectPlan {
        try cancellation.check()
        let target: EjectTarget
        if let unmountedTarget {
            try targets.validateUnmounted(unmountedTarget, runner: scoped)
            target = unmountedTarget
        } else { target = try targets.target(at: mountPoint, runner: scoped) }
        if let expectedVolume, target.volume.device != expectedVolume.device || target.volume.uuid != expectedVolume.uuid || target.volume.mount != expectedVolume.mount {
            throw ProbeFailure(M("ejectflow.the.selected.volume.s.identity.changed.select.it"))
        }
        var occ = Occupancy(runner: scoped)
        occ.inspector = inspector
        let images = ProbeResult<[DiskImage]>.capture {
            try DiskImageProbe(runner: scoped).images(on: target.affected.map(\.mount))
        }
        var holders: [Holder] = []
        var issues = images.issues
        let mounts = Set(target.affected.map(\.mount) + (images.value ?? []).flatMap(\.mountPoints))
        for mount in mounts.sorted() {
            let result = ProbeResult<OccupancyReport>.capture {
                try occ.fullScan(mountPoint: mount, indexingOn: indexingOn)
            }
            issues += result.issues + (result.value?.issues ?? [])
            for holder in result.value?.holders ?? [] {
                if let i = holders.firstIndex(where: { $0.id == holder.id && $0.identity == holder.identity }) {
                    if let n = holders[i].openFileCount, let extra = holder.openFileCount {
                        holders[i].evidence = .scanned(openFiles: n + extra,
                            sampleFiles: Array(Set(holders[i].sampleFiles + holder.sampleFiles)).sorted().prefix(6).map { $0 })
                    }
                } else { holders.append(holder) }
            }
        }
        try cancellation.check()
        if unmountedTarget != nil { try targets.validateUnmounted(target, runner: scoped) }
        else if try targets.target(at: mountPoint, runner: scoped) != target {
            throw ProbeFailure(M("ejectflow.the.target.drive.or.related.volumes.changed.during"))
        }
        return EjectPlan(target: target, createdAt: now(), holders: holders,
                         images: images.value ?? [], issues: issues, imagesKnown: images.isComplete)
    }

    /// No side effect until preflight either needs no preparation or receives confirmation.
    func run(indexingOn: Bool?) -> Outcome {
        do {
            let plan = try prepare(indexingOn: indexingOn)
            if plan.requiresConfirmation { return .preview(plan) }
            return execute(plan, mode: .prepared)
        } catch { return .aborted(error.displayMessage) }
    }

    func execute(_ approved: EjectPlan, mode: EjectMode) -> Outcome {
        if mode == .force { return executeForce(approved) }
        let systemOnly = mode == .systemOnly
        let started = now()
        stoppedApps = approved.completedApps; stoppedDaemons = approved.completedDaemons; detachedImages = approved.completedImages
        selectedTasks = approved.selectedTasks; requested = approved.requested; credited = approved.credited
        lastFailure = approved.failure; lastCommandOutput = ""
        forceUsed = approved.forceUsed
        relatedImages = approved.images + (approved.failure?.relatedImages ?? [])
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
                    if let outcome = detachImage(image, target: approved.target, force: false) { return outcome }
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

    /// A separate read-only step creates a fresh, single-use force confirmation.
    func prepareForce(_ failure: EjectFailure) -> Outcome {
        stoppedApps = failure.completedApps; stoppedDaemons = failure.completedProcesses
        detachedImages = failure.completedImages; forceUsed = failure.forceUsed
        relatedImages = failure.relatedImages; lastFailure = failure
        do {
            guard failure.allowsForce else { throw ProbeFailure(M("ejectforce.not.allowed")) }
            var plan: EjectPlan
            plan = try prepareForForce(failure.target)
            guard plan.target.volume == failure.target.volume,
                  plan.target.physicalDisk == failure.target.physicalDisk else {
                throw ProbeFailure(M("ejectforce.target.changed"))
            }
            plan.forceConfirmation = true
            return previewOutcome(plan)
        } catch { return .aborted(error.displayMessage) }
    }

    private func prepareForForce(_ expected: EjectTarget) throws -> EjectPlan {
        do { return try prepare() }
        catch {
            try cancellation.check()
            return try prepare(unmountedTarget: expected)
        }
    }

    private func executeForce(_ approved: EjectPlan) -> Outcome {
        stoppedApps = approved.completedApps; stoppedDaemons = approved.completedDaemons
        detachedImages = approved.completedImages; forceUsed = approved.forceUsed
        relatedImages = approved.images + (approved.failure?.relatedImages ?? [])
        lastFailure = approved.failure
        steps = [Step(id: "validate", title: M("ejectflow.verify.target.and.scope"), state: .running),
                 Step(id: "images", title: M("ejectforce.detach.images")),
                 Step(id: "force-unmount", title: M("ejectforce.unmount.disk")),
                 Step(id: "unmount", title: M("ejectflow.ask.macos.to.eject")),
                 Step(id: "verify", title: M("ejectflow.verify.eject.result"))]
        emit()
        let started = now()
        do {
            guard approved.forceConfirmation, approved.canForce else { throw ProbeFailure(M("ejectforce.not.allowed")) }
            func freshPlan() throws -> EjectPlan {
                var plan = try prepareForForce(approved.target)
                guard plan.target.volume == approved.target.volume,
                      plan.target.physicalDisk == approved.target.physicalDisk else {
                    throw ProbeFailure(M("ejectforce.target.changed"))
                }
                plan.forceConfirmation = true
                return plan
            }
            func inScope(_ plan: EjectPlan) -> Bool {
                plan.imagesKnown && plan.target == approved.target
                    && plan.images.allSatisfy { approved.images.contains($0) }
                    && now().timeIntervalSince(approved.createdAt) <= 30
            }
            let fresh = try freshPlan()
            guard inScope(fresh) else { return previewOutcome(fresh) }
            set("validate", .done(M("ejectflow.operation.scope.verified")))
            set("images", .running)
            for image in fresh.images {
                try cancellation.check()
                let current = try freshPlan()
                guard inScope(current) else { return previewOutcome(current) }
                guard current.images.contains(image) else { continue }
                if let outcome = detachImage(image, target: approved.target, force: true) { return outcome }
            }
            set("images", .done(M("ejectflow.images.ejected", detachedImages)))
            let current = try freshPlan()
            guard inScope(current) else { return previewOutcome(current) }
            guard current.images.isEmpty, try DiskImageProbe(runner: scoped).areDetached(relatedImages) else {
                throw ProbeFailure(M("ejectforce.images.still.attached"))
            }
            try targets.validateUnmounted(approved.target, runner: scoped)
            let before = targets.ejectVerification(approved.target, runner: scoped, timeout: Deadline.quick)
            guard before.relatedMountsKnown, before.issue == nil else {
                throw ProbeFailure(M("ejectforce.target.changed"))
            }
            if !before.mountedVolumes.isEmpty {
                set("force-unmount", .running)
                guard cancellation.commit() else { throw ProbeFailure(M("ejectflow.operation.cancelled")) }
                forceUsed = true
                onCommit()
                let r: CommandResult
                do { r = try runner.run(Tool.diskutil, ["unmountDisk", "force", approved.target.physicalDisk], timeout: Deadline.eject) }
                catch { return pendingPreparation(approved.target, stage: "force-unmount", error: error.displayMessage) }
                lastCommandOutput = r.text + "\n" + r.stderr
                let after = targets.ejectVerification(approved.target, runner: runner, timeout: Deadline.quick)
                if after.state != .unmounted && after.state != .offline {
                    let pending = r.ok || r.timedOut || r.cancelled || after.issue != nil
                    let reason = M(pending ? "ejectflow.eject.result.pending.verification" : "ejectforce.unmount.failed")
                    let failure = recordFailure(approved.target, stage: "force-unmount", message: reason,
                                                command: r, verification: after, allowsForce: !pending)
                    set("force-unmount", .failed(reason))
                    if pending { return .verificationPending(failure, reason) }
                    cancellation.finishRefusedAttempt(); onSystemReturned()
                    return .aborted(reason + "\n" + completedDetail)
                }
                cancellation.finishRefusedAttempt(); onSystemReturned()
                set("force-unmount", .done(nil))
            } else { set("force-unmount", .skipped(M("ejectforce.already.unmounted"))) }
            try cancellation.check()
            // UUID/device/physical-store checks still work after all mount paths disappear.
            try targets.validateUnmounted(approved.target, runner: scoped)
            return try ejectWithRecovery(approved, systemOnly: true, started: started, allowUnmounted: true)
        } catch {
            let reason = error.displayMessage
            recordFailure(approved.target, stage: steps.first(where: { $0.state == .running })?.id ?? "validate", message: reason,
                          allowsForce: forceUsed || approved.failure?.allowsForce == true)
            for step in steps where step.state == .running { set(step.id, .failed(reason)) }
            return .aborted(reason + "\n" + completedDetail)
        }
    }

    /// Disk commands are committed while running. Cancellation can stop the next step,
    /// but cannot claim an in-flight detach has been undone.
    private func detachImage(_ image: DiskImage, target: EjectTarget, force: Bool) -> Outcome? {
        let stage = force ? "force-images" : "images"
        do {
            guard cancellation.commit() else { throw ProbeFailure(M("ejectflow.operation.cancelled")) }
            if force { forceUsed = true }
            onCommit()
            let r: CommandResult
            do { r = try DiskImageProbe(runner: runner).detach(image, force: force) }
            catch { return pendingPreparation(target, stage: stage, error: error.displayMessage, image: image) }
            lastCommandOutput = r.text + "\n" + r.stderr
            let detached: Bool
            do { detached = try DiskImageProbe(runner: runner).areDetached([image]) }
            catch { return pendingPreparation(target, stage: stage, error: error.displayMessage, image: image, command: r) }
            if detached {
                detachedImages += 1
                cancellation.finishRefusedAttempt(); onSystemReturned()
                return nil
            }
            let pending = r.ok || r.timedOut || r.cancelled
            let reason = M(pending ? "ejectflow.eject.result.pending.verification" : "ejectflow.could.not.eject.image", image.name)
            let failure = recordFailure(target, stage: stage, message: reason, command: r,
                                        allowsForce: !pending, pendingImage: pending ? image : nil)
            set("images", .failed(reason))
            if pending { return .verificationPending(failure, reason) }
            cancellation.finishRefusedAttempt(); onSystemReturned()
            return .aborted(reason + "\n" + completedDetail)
        } catch { return .aborted(error.displayMessage) }
    }

    private func pendingPreparation(_ target: EjectTarget, stage: String, error: Message,
                                    image: DiskImage? = nil, command: CommandResult? = nil) -> Outcome {
        let reason = M("ejectflow.eject.result.pending.verification") + "\n" + error
        let failure = recordFailure(target, stage: stage, message: reason, command: command, pendingImage: image)
        set(stage == "force-images" ? "images" : stage, .failed(reason))
        return .verificationPending(failure, reason)
    }

    /// A read-only recheck never resumes disk commands by itself.
    private func reverifyPreparation(_ previous: EjectFailure) -> Outcome {
        do {
            try targets.validateUnmounted(previous.target, runner: scoped)
            if let image = previous.pendingImage,
               try DiskImageProbe(runner: scoped).areDetached([image]) { detachedImages += 1 }
            var fresh = try prepare(unmountedTarget: previous.forceUsed ? previous.target : nil)
            guard fresh.target == previous.target else { throw ProbeFailure(M("ejectforce.target.changed")) }
            var failure = previous
            failure.pendingImage = nil
            // If an uncertain ordinary detach is still attached, retry normally first.
            failure.allowsForce = previous.forceUsed
            failure.completedImages = detachedImages
            lastFailure = failure
            fresh.forceConfirmation = previous.forceUsed
            return previewOutcome(fresh, notice: M("ejectforce.rechecked"))
        } catch { return .verificationPending(previous, error.displayMessage) }
    }

    private func observeEject(_ target: EjectTarget, timeout: TimeInterval) -> EjectVerification {
        let observed = targets.ejectVerification(target, runner: runner, timeout: timeout)
        guard observed.state == .offline || observed.state == .unmounted else { return observed }
        do {
            guard try DiskImageProbe(runner: runner).areDetached(relatedImages, backingMounts: target.affected.map(\.mount), timeout: timeout) else {
                return .init(state: .unavailable, physicalDiskPresent: observed.physicalDiskPresent,
                             mountedVolumes: observed.mountedVolumes, relatedMountsKnown: observed.relatedMountsKnown,
                             issue: M("ejectforce.images.still.attached"))
            }
            return observed
        } catch {
            return .init(state: .unavailable, physicalDiskPresent: observed.physicalDiskPresent,
                         mountedVolumes: observed.mountedVolumes, relatedMountsKnown: observed.relatedMountsKnown,
                         issue: error.displayMessage)
        }
    }

    /// Read-only refresh keeps completed actions and pending quit requests.
    func recheck(_ previous: EjectPlan) -> Outcome {
        stoppedApps = previous.completedApps; stoppedDaemons = previous.completedDaemons
        detachedImages = previous.completedImages; selectedTasks = previous.selectedTasks
        requested = previous.requested; credited = previous.credited; lastFailure = previous.failure
        forceUsed = previous.forceUsed; relatedImages = previous.images
        do {
            var fresh = try prepare(unmountedTarget: previous.forceUsed ? previous.target : nil)
            fresh.forceConfirmation = previous.forceConfirmation
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
        forceUsed = previous.forceUsed; relatedImages = previous.relatedImages
        if previous.pendingImage != nil || previous.stage == "force-unmount" {
            return reverifyPreparation(previous)
        }
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
            return .ejected(now().timeIntervalSince(started), stoppedApps: stoppedApps, stoppedDaemons: stoppedDaemons, forced: forceUsed)
        }
        if (previous.commandTimedOut || previous.commandCancelled || previous.commandExitCode == nil),
           verification.state == .present || (previous.forceUsed && verification.state == .unmounted) {
            return reverifyPreparation(previous)
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
                                   verificationDuration: duration, verification: verification, forceUsed: forceUsed,
                                   relatedImages: relatedImages)
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
        updated.forceUsed = forceUsed
        return .preview(updated)
    }

    private enum ReleaseState { case exited, released, waiting }

    private func waitForRelease(_ expected: ProcessIdentity) throws -> ReleaseState {
        let end = now().addingTimeInterval(quitTimeout)
        while now() < end {
            try cancellation.check()
            guard let live = try inspector.identity(expected.pid) else { return .exited }
            if live != expected { return .exited } // never signal its replacement
            let report = try prepare()
            guard !report.incomplete else {
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
                               verificationDuration: TimeInterval? = nil, allowsForce: Bool = false,
                               pendingImage: DiskImage? = nil) -> EjectFailure {
        let failure = EjectFailure(target: target, stage: stage, message: message,
                                   commandOutput: String(lastCommandOutput.prefix(16_384)),
                                   blockingPID: blockingPID ?? EjectFailure.blockingPID(in: lastCommandOutput),
                                   completedApps: stoppedApps, completedProcesses: stoppedDaemons,
                                   completedImages: detachedImages,
                                   commandExitCode: command?.exitCode,
                                   commandTimedOut: command?.timedOut ?? false,
                                   commandCancelled: command?.cancelled ?? false,
                                   verificationDuration: verificationDuration,
                                   verification: verification, forceUsed: forceUsed, allowsForce: allowsForce,
                                   relatedImages: relatedImages, pendingImage: pendingImage)
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
        var latest = observeEject(target,
                                                timeout: max(0.05, min(Deadline.quick, verificationTimeout)))
        while !confirmsEject(latest, acceptUnmounted: acceptUnmounted)
                && monotonicNow() < deadline {
            let delay = min(verificationInterval, deadline - monotonicNow())
            if delay > 0 { sleep(delay) }
            let remaining = max(0.05, deadline - monotonicNow())
            latest = observeEject(target,
                                                timeout: min(Deadline.quick, remaining))
        }
        return (latest, max(0, monotonicNow() - started))
    }

    private func ejectWithRecovery(_ approved: EjectPlan, systemOnly: Bool, started: Date, allowUnmounted: Bool = false) throws -> Outcome {
        for attempt in 1...3 {
            try cancellation.check()
            if forceUsed || allowUnmounted { try targets.validateUnmounted(approved.target, runner: scoped) }
            else if try targets.target(at: mountPoint, runner: scoped) != approved.target {
                throw ProbeFailure(M("ejectflow.the.target.s.identity.or.related.volumes.changed.e989"))
            }
            guard cancellation.commit() else { throw ProbeFailure(M("ejectflow.operation.cancelled")) }
            onCommit()
            set("unmount", .running)
            lastCommandOutput = ""
            let r: CommandResult
            do { r = try runner.run(Tool.diskutil, ["eject", approved.target.physicalDisk], timeout: Deadline.eject) }
            catch { return pendingPreparation(approved.target, stage: "verify", error: error.displayMessage) }
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
                return .ejected(now().timeIntervalSince(started), stoppedApps: stoppedApps, stoppedDaemons: stoppedDaemons, forced: forceUsed)
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
                          verification: verification, verificationDuration: verificationDuration, allowsForce: true)
            set("unmount", .failed(reason)); set("verify", .done(M("ejectflow.disk.still.connected")))
            if forceUsed || allowUnmounted { return .aborted(reason + "\n" + completedDetail) }
            let fresh = try prepare()
            guard fresh.target == approved.target else { throw ProbeFailure(M("ejectflow.the.target.drive.changed")) }
            // Never turn a dissenter PID alone into permission to signal it: only
            // fresh file evidence and verified identity can enable preparation.
            if !fresh.processScope.isEmpty || !fresh.images.isEmpty {
                return previewOutcome(fresh, notice: reason)
            }
            guard !fresh.incomplete, !systemOnly || !approved.incomplete,
                  EjectFailure.isTransientBusy(lastCommandOutput), attempt < 3 else {
                return .aborted(reason + "\n" + completedDetail)
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
