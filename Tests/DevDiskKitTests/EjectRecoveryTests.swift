import XCTest
@testable import DevDiskKit

final class EjectRecoveryTests: XCTestCase {
    private let busy = CommandResult(stdout: Data(), stderr: "Resource busy (kDAReturnBusy)", exitCode: 1)
    private let eject = "diskutil eject disk90"

    func testUnknownTaskIsUncheckedAndRequiresExplicitSelection() throws {
        let h = FlowHarness(); h.add(executable: "/bin/zsh", args: "zsh", paths: [FlowHarness.mount])
        let flow = h.flow
        var plan = try flow.prepare()
        XCTAssertTrue(plan.selectedTasks.isEmpty)
        XCTAssertFalse(plan.canPrepare)
        guard case .preview = flow.execute(plan, systemOnly: false) else { return XCTFail("must confirm") }
        XCTAssertFalse(h.calls.contains { $0.hasPrefix("kill") })
        plan.selectedTasks.insert(try XCTUnwrap(plan.manual.first?.identity))
        XCTAssertTrue(plan.canPrepare)
        guard case .ejected(_, _, let stopped) = flow.execute(plan, systemOnly: false) else { return XCTFail("must eject") }
        XCTAssertEqual(stopped, 1)
        XCTAssertTrue(h.calls.contains("kill -TERM 123"))
    }

    func testUnselectedTaskPreventsPartialCleanup() throws {
        let h = FlowHarness(); h.add(executable: "/bin/zsh", args: "zsh"); h.add(pid: 456)
        let f = h.flow, plan = try f.prepare()
        guard case .preview = f.execute(plan, systemOnly: false) else { return XCTFail("needs selection") }
        XCTAssertFalse(h.calls.contains { $0.hasPrefix("kill") })
    }

    func testUserOwnedSystemServiceAndSelfCannotBeTerminated() throws {
        for (pid, path) in [(Int32(123), "/System/Library/Frameworks/CoreServices.framework/mdworker_shared"),
                            (124, "/usr/libexec/containermanagerd"), (getpid(), "/opt/devdisk")] {
            let h = FlowHarness(); h.add(pid: pid, executable: path, args: path)
            let f = h.flow
            var plan = try f.prepare()
            XCTAssertTrue(plan.manual.isEmpty)
            XCTAssertTrue(plan.holders.contains { $0.identity?.pid == pid && $0.kind == .system })
            plan.selectedTasks = Set(plan.holders.compactMap(\.identity))
            _ = f.execute(plan, systemOnly: false)
            XCTAssertFalse(h.calls.contains { $0.hasPrefix("kill") })
            XCTAssertTrue(h.processes.quits.isEmpty)
        }
    }

    func testAppCanReleaseHandlesWithoutExiting() throws {
        let h = FlowHarness(); h.add(app: "review.editor"); h.processes.refuseQuit = true
        h.processes.onQuit = { h.files[123] = [] }
        let f = h.flow, plan = try f.prepare()
        guard case .ejected(_, let apps, _) = f.execute(plan, systemOnly: false) else { return XCTFail("released") }
        XCTAssertEqual(apps, 0, "Do not claim an app quit just because its handles closed")
        XCTAssertNotNil(h.processes.live[123])
    }

    func testSaveDialogContinuesWithoutRepeatingQuitAndCountsLaterExit() throws {
        let h = FlowHarness(); h.add(app: "review.editor"); h.processes.refuseQuit = true
        let f = h.flow, plan = try f.prepare()
        guard case .preview(let pending) = f.execute(plan, systemOnly: false) else { return XCTFail("wait for save") }
        XCTAssertTrue(pending.needsContinuation)
        XCTAssertNotNil(pending.notice)
        XCTAssertEqual(pending.failure?.stage, "apps")
        XCTAssertEqual(pending.failure?.blockingPID, 123)
        XCTAssertEqual(h.processes.quits, [123])
        guard case .preview(let stillPending) = h.flow.execute(pending, systemOnly: false) else { return XCTFail("still waiting") }
        XCTAssertEqual(h.processes.quits, [123])
        h.processes.live.removeValue(forKey: 123)
        guard case .ejected(_, let apps, _) = h.flow.execute(stillPending, systemOnly: false) else { return XCTFail("continue") }
        XCTAssertEqual(apps, 1)
        XCTAssertEqual(h.processes.quits, [123])
    }

    func testRecheckPreservesSelectionAndSentRequestsWithoutSideEffects() throws {
        let h = FlowHarness(); h.add(executable: "/usr/bin/tail", args: "tail"); h.stopWorks = false
        let f = h.flow
        var plan = try f.prepare(); plan.selectedTasks = plan.processScope
        guard case .preview(let waiting) = f.execute(plan, systemOnly: false) else { return XCTFail("pending TERM") }
        let sent = h.calls.filter { $0.hasPrefix("kill") }
        guard case .preview(let refreshed) = h.flow.recheck(waiting) else { return XCTFail("refresh") }
        XCTAssertEqual(refreshed.selectedTasks, waiting.selectedTasks)
        XCTAssertEqual(refreshed.requested, waiting.requested)
        XCTAssertEqual(refreshed.failure, waiting.failure)
        XCTAssertEqual(h.calls.filter { $0.hasPrefix("kill") }, sent)
    }

    func testCancellationWhileWaitingStopsDiskOperation() throws {
        let h = FlowHarness(); h.add(app: "review.editor"); h.processes.refuseQuit = true
        let f = h.flow, plan = try f.prepare()
        f.sleep = { h.clock += $0; h.cancellation.cancel() }
        guard case .aborted = f.execute(plan, systemOnly: false) else { return XCTFail("cancelled") }
        XCTAssertFalse(h.calls.contains(eject))
    }

    func testBusyRefusalRetriesThenVerifiesSuccess() {
        let h = FlowHarness()
        var attempts = 0
        h.onCall = { key in
            if key == self.eject {
                attempts += 1
                if attempts == 1 { h.failures[key] = self.busy }
                else { h.failures.removeValue(forKey: key) }
            }
        }
        guard case .ejected = h.flow.run(indexingOn: nil) else { return XCTFail("second attempt succeeds") }
        XCTAssertEqual(attempts, 2)
    }

    func testSuccessfulCommandWaitsForDelayedOfflineStateWithoutEjectingAgain() {
        let h = FlowHarness()
        h.targetInspector.ejectedResults = [false, false, true]
        let f = h.flow

        guard case .ejected = f.run(indexingOn: nil) else {
            return XCTFail("a delayed disk registry update must not become an unknown failure")
        }

        XCTAssertEqual(h.targetInspector.verificationReads, 3)
        XCTAssertEqual(h.calls.filter { $0 == eject }.count, 1)
        XCTAssertEqual(h.clock.timeIntervalSince1970, 1000.5, accuracy: 0.001)
        XCTAssertEqual(f.steps.first(where: { $0.id == "verify" })?.state,
                       .done(M("ejectflow.physical.disk.offline.related.volumes.unmounted")))
    }

    func testSuccessfulSystemEjectAcceptsUnmountedFixedExternalDevice() {
        let h = FlowHarness()
        h.targetInspector.verificationResults = [
            .init(state: .unmounted, physicalDiskPresent: true, mountedVolumes: [],
                  relatedMountsKnown: true, issue: nil)
        ]
        let f = h.flow
        var verified: Message?
        f.onVerifiedEject = { verified = $0 }

        guard case .ejected = f.run(indexingOn: nil) else {
            return XCTFail("fixed external devices remain enumerated after a successful eject")
        }
        XCTAssertEqual(h.calls.filter { $0 == eject }.count, 1)
        XCTAssertEqual(h.targetInspector.verificationReads, 1)
        XCTAssertEqual(f.steps.first(where: { $0.id == "verify" })?.state,
                       .done(M("ejectflow.system.eject.confirmed.related.volumes.unmounted")))
        XCTAssertEqual(verified, M("ejectflow.system.eject.confirmed.related.volumes.unmounted"))
    }

    func testBusyRetryIsBoundedAndRetainsRawDiagnostic() {
        let h = FlowHarness(); h.failures[eject] = busy
        let f = h.flow
        guard case .aborted = f.run(indexingOn: nil) else { return XCTFail("must stop") }
        XCTAssertEqual(h.calls.filter { $0 == eject }.count, 3)
        XCTAssertEqual(f.lastFailure?.stage, "unmount")
        XCTAssertTrue(f.lastFailure?.commandOutput.contains("kDAReturnBusy") == true)
        XCTAssertFalse(h.cancellation.isCommitted)
    }

    func testCancellationBetweenAttemptsIsEffective() {
        let h = FlowHarness(); h.failures[eject] = busy
        let f = h.flow
        f.onSystemReturned = { h.cancellation.cancel() }
        guard case .aborted = f.run(indexingOn: nil) else { return XCTFail("cancelled") }
        XCTAssertEqual(h.calls.filter { $0 == eject }.count, 1)
        XCTAssertTrue(h.cancellation.isCancelled)
    }

    func testNewDissenterReturnsVerifiedUncheckedTask() throws {
        let h = FlowHarness()
        h.onCall = { key in
            if key == self.eject {
                h.add(pid: 321, executable: "/usr/bin/tail", args: "tail")
                h.failures[key] = .init(stdout: Data(), stderr: "Unmount was dissented by PID 321 (/usr/bin/tail)\nDissenter parent PPID 100 (/bin/zsh)", exitCode: 1)
            }
        }
        let f = h.flow
        guard case .preview(let plan) = f.run(indexingOn: nil) else { return XCTFail("actionable refusal") }
        XCTAssertEqual(plan.manual.first?.identity?.pid, 321)
        XCTAssertTrue(plan.selectedTasks.isEmpty)
        XCTAssertEqual(plan.failure?.blockingPID, 321)
        XCTAssertEqual(plan.failure?.stage, "unmount")
        XCTAssertFalse(h.calls.contains { $0.hasPrefix("kill") })
        XCTAssertFalse(h.cancellation.isCommitted)
        h.onCall = nil; h.failures.removeValue(forKey: eject)
        var approved = plan; approved.selectedTasks = plan.processScope
        guard case .ejected = h.flow.execute(approved, systemOnly: false) else { return XCTFail("recovered") }
    }

    func testPIDAloneNeverAllowsTermination() {
        let h = FlowHarness()
        h.failures[eject] = .init(stdout: Data(), stderr: "Unmount was dissented by PID 321 (/usr/bin/tail)", exitCode: 1)
        let f = h.flow
        guard case .aborted = f.run(indexingOn: nil) else { return XCTFail("unverified") }
        XCTAssertEqual(f.lastFailure?.blockingPID, 321)
        XCTAssertFalse(h.calls.contains { $0.hasPrefix("kill") })
    }

    func testNewHolderDuringRetryDelayRequiresConfirmation() {
        let h = FlowHarness(); h.failures[eject] = busy
        let f = h.flow
        f.sleep = { h.clock += $0; h.add() }
        guard case .preview(let plan) = f.run(indexingOn: nil) else { return XCTFail("new holder") }
        XCTAssertEqual(plan.daemons.count, 1)
        XCTAssertEqual(h.calls.filter { $0 == eject }.count, 1)
        XCTAssertFalse(h.calls.contains { $0.hasPrefix("kill") })
    }

    func testPermissionTimeoutAndUnknownResultsNeverRetry() {
        let results = [CommandResult(stdout: Data(), stderr: "Permission denied: resource busy", exitCode: 1),
                       .init(stdout: Data(), stderr: "Resource busy", exitCode: -1, timedOut: true),
                       .init(stdout: Data(), stderr: "", exitCode: 0)]
        for (index, result) in results.enumerated() {
            let h = FlowHarness(); h.failures[eject] = result
            let outcome = h.flow.run(indexingOn: nil)
            if index == 0 {
                guard case .aborted = outcome else { XCTFail("permission refusal must stop"); continue }
            } else {
                guard case .verificationPending = outcome else { XCTFail("uncertain result must remain pending"); continue }
            }
            XCTAssertEqual(h.calls.filter { $0 == eject }.count, 1)
        }
    }

    func testReadOnlyReverificationRepairsPendingResultWithoutAnotherEject() throws {
        let h = FlowHarness()
        h.failures[eject] = .init(stdout: Data("Disk disk90 ejected\n".utf8), stderr: "", exitCode: 0)
        let first = h.flow
        guard case .verificationPending(let failure, _) = first.run(indexingOn: nil) else {
            return XCTFail("must initially be pending")
        }
        XCTAssertEqual(failure.stage, "verify")
        XCTAssertEqual(failure.commandExitCode, 0)
        XCTAssertEqual(failure.verification?.state, .present)
        XCTAssertTrue(failure.report.contains("Disk disk90 ejected"))

        h.targetInspector.gone = true
        guard case .ejected = h.flow.reverify(failure) else {
            return XCTFail("later offline evidence must repair the result")
        }
        XCTAssertEqual(h.calls.filter { $0 == eject }.count, 1)
    }

    func testChangedTargetBetweenAttemptsCannotBeEjected() {
        let h = FlowHarness(); h.failures[eject] = busy
        let f = h.flow
        f.sleep = { interval in
            h.clock += interval
            let old = h.targetInspector.current
            h.targetInspector.current = .init(volume: .init(name: "Replacement", mount: FlowHarness.mount,
                device: old.volume.device, uuid: "replacement"), physicalDisk: old.physicalDisk, affected: old.affected)
        }
        guard case .aborted = f.run(indexingOn: nil) else { return XCTFail("changed target") }
        XCTAssertEqual(h.calls.filter { $0 == eject }.count, 1)
    }
}
