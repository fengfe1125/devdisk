import XCTest
@testable import DevDiskKit

final class ForceProcessTests: XCTestCase {
    private func confirmed(_ h: FlowHarness, action: ForceProcessAction = .closeAndEject,
                           select: Set<Int32>? = nil) throws -> EjectPlan {
        var plan = try h.flow.prepare()
        plan.selectedForceProcesses = Set(plan.forceEligible.filter { select?.contains($0.pid) ?? true })
        guard case .preview(let confirmation) = h.flow.prepareForceProcesses(plan, action: action) else {
            throw ProbeFailure("missing confirmation")
        }
        return confirmation
    }
    private func assertNoDiskActions(_ h: FlowHarness, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(h.calls.contains { $0.hasPrefix("diskutil eject") || $0.hasPrefix("diskutil unmountDisk") || $0.hasPrefix("hdiutil detach") }, file: file, line: line)
    }

    func testAllCategoriesEligibleButProtectedForeignAndSelfExcluded() throws {
        let h = FlowHarness()
        h.add(pid: 101, app: "editor")
        h.add(pid: 102)
        h.add(pid: 103, executable: "/bin/zsh", args: "zsh")
        h.add(pid: 104, executable: "/usr/libexec/mdworker", args: "mdworker")
        h.add(pid: 105, uid: getuid() + 1)
        h.add(pid: getpid(), executable: "/opt/devdisk", args: "devdisk")
        let p = try h.flow.prepare()
        XCTAssertTrue(p.selectedForceProcesses.isEmpty)
        XCTAssertEqual(Set(p.forceEligible.map(\.pid)), [101, 102, 103])
        XCTAssertEqual(p.apps.count, 1); XCTAssertEqual(p.daemons.count, 1); XCTAssertEqual(p.manual.count, 1)
        XCTAssertFalse(p.canCloseSelected)
        XCTAssertTrue(p.canForceProcesses)
    }

    func testNoActionsBeforeSeparateConfirmationAndLegacyForceStillRequiresFailure() throws {
        let h = FlowHarness(); h.add(app: "editor")
        var p = try h.flow.prepare(); p.selectedForceProcesses = p.forceEligible
        _ = h.flow.execute(p, mode: .forceProcesses)
        _ = h.flow.execute(p, mode: .force)
        let confirmation = try confirmed(h)
        XCTAssertNil(confirmation.failure)
        XCTAssertFalse(confirmation.forceConfirmation)
        XCTAssertFalse(confirmation.canForce)
        XCTAssertTrue(confirmation.canForceProcesses)
        XCTAssertEqual(confirmation.forceProcessConfirmation, .closeAndEject)
        XCTAssertTrue(h.processes.forced.isEmpty)
        assertNoDiskActions(h)
    }

    func testCloseOnlyNeverEjectsAndKeepsSeparateForceHistory() throws {
        let h = FlowHarness(); h.add(app: "editor"); h.add(pid: 456)
        let p = try confirmed(h, action: .closeOnly)
        guard case .preview(let next) = h.flow.execute(p, mode: .forceProcesses) else { return XCTFail("preview") }
        XCTAssertEqual(h.processes.forced, [123, 456])
        XCTAssertEqual(next.completedApps, 1); XCTAssertEqual(next.completedDaemons, 1)
        XCTAssertEqual(next.forceRequested.count, 2)
        XCTAssertFalse(next.forceUsed); XCTAssertNil(next.forceProcessConfirmation)
        XCTAssertTrue(next.selectedForceProcesses.isEmpty)
        XCTAssertTrue(h.processes.quits.isEmpty)
        assertNoDiskActions(h)
        guard case .preview(let refreshed) = h.flow.recheck(next) else { return XCTFail("refresh") }
        XCTAssertEqual(refreshed.forceRequested, next.forceRequested)
        assertNoDiskActions(h)
    }

    func testDirectJointActionClosesBeforeImagesUnmountAndEject() throws {
        let h = FlowHarness(); h.add(app: "editor"); h.add(pid: 456)
        h.images = [.init(path: FlowHarness.mount + "/a.dmg", writable: true, devEntries: ["/dev/disk91"], mountPoints: [])]
        let p = try confirmed(h)
        var history: Set<ProcessIdentity> = []
        let f = h.flow; f.onForceProcesses = { history = $0 }
        h.onCall = { key in
            if key.hasPrefix("hdiutil detach") || key.hasPrefix("diskutil unmountDisk") {
                XCTAssertEqual(h.processes.forced, [123, 456])
            }
        }
        guard case .ejected(_, let apps, let processes, let forced) = f.execute(p, mode: .forceProcesses) else { return XCTFail("joint success") }
        XCTAssertTrue(forced); XCTAssertEqual(apps, 1); XCTAssertEqual(processes, 1)
        XCTAssertEqual(history.count, 2)
        let detach = try XCTUnwrap(h.calls.firstIndex(of: "hdiutil detach /dev/disk91 -force"))
        let unmount = try XCTUnwrap(h.calls.firstIndex(of: "diskutil unmountDisk force disk90"))
        let eject = try XCTUnwrap(h.calls.firstIndex(of: "diskutil eject disk90"))
        XCTAssertLessThan(detach, unmount); XCTAssertLessThan(unmount, eject)
        XCTAssertFalse(h.calls.contains { $0.hasPrefix("kill") })
    }

    func testUnselectedAndSystemOccupantsAreNotKilledByJointAction() throws {
        let h = FlowHarness(); h.add(app: "editor"); h.add(pid: 456)
        h.add(pid: 789, executable: "/usr/libexec/service", args: "service")
        let p = try confirmed(h, select: [123])
        guard case .ejected = h.flow.execute(p, mode: .forceProcesses) else { return XCTFail("known remaining scope may be unmounted") }
        XCTAssertEqual(h.processes.forced, [123])
        XCTAssertNotNil(h.processes.live[456]); XCTAssertNotNil(h.processes.live[789])
    }

    func testOrdinaryFlowNeverUsesForceSelectionAsPermissionToKill() throws {
        let h = FlowHarness(); h.add(app: "editor"); h.processes.refuseQuit = true
        var p = try h.flow.prepare(); p.selectedForceProcesses = p.forceEligible
        guard case .preview = h.flow.execute(p, mode: .prepared) else { return XCTFail("waiting") }
        XCTAssertEqual(h.processes.quits, [123]); XCTAssertTrue(h.processes.forced.isEmpty)
        assertNoDiskActions(h)
    }

    func testExpiredConfirmationRequiresReviewWithoutSideEffects() throws {
        let h = FlowHarness(); h.add(app: "editor")
        let p = try confirmed(h); h.clock += 31
        guard case .preview(let next) = h.flow.execute(p, mode: .forceProcesses) else { return XCTFail("review") }
        XCTAssertEqual(next.createdAt, h.clock)
        XCTAssertEqual(next.forceProcessConfirmation, .closeAndEject)
        XCTAssertTrue(h.processes.forced.isEmpty); assertNoDiskActions(h)
    }

    func testPIDReuseAndNewOccupantsNeverInheritSelection() throws {
        for reused in [false, true] {
            let h = FlowHarness(); h.add(app: "editor")
            let p = try confirmed(h)
            if reused {
                h.processes.live[123] = .init(pid: 123, uid: getuid(), startedSeconds: 99, startedMicros: 0,
                                             executable: "/bin/zsh")
            } else { h.add(pid: 456) }
            guard case .preview(let next) = h.flow.execute(p, mode: .forceProcesses) else { return XCTFail("review") }
            XCTAssertFalse(next.selectedForceProcesses.contains { $0.pid == (reused ? 123 : 456) })
            XCTAssertTrue(h.processes.forced.isEmpty); assertNoDiskActions(h)
        }
    }

    func testNewImageAndChangedTargetRequireReview() throws {
        for changeTarget in [false, true] {
            let h = FlowHarness(); h.add(app: "editor")
            let p = try confirmed(h)
            if changeTarget {
                let t = h.targetInspector.current
                h.targetInspector.current = .init(volume: .init(name: "replacement", mount: t.volume.mount,
                    device: t.volume.device, uuid: "replacement"), physicalDisk: t.physicalDisk, affected: t.affected)
            } else {
                h.images = [.init(path: FlowHarness.mount + "/new.dmg", writable: true, devEntries: ["/dev/disk91"], mountPoints: [])]
            }
            guard case .preview = h.flow.execute(p, mode: .forceProcesses) else { return XCTFail("review") }
            XCTAssertTrue(h.processes.forced.isEmpty); assertNoDiskActions(h)
        }
    }

    func testReleasedHolderIsSkippedEvenIfAppIsStillRunning() throws {
        let h = FlowHarness(); h.add(app: "editor")
        let p = try confirmed(h, action: .closeOnly)
        h.files[123] = []
        guard case .preview(let next) = h.flow.execute(p, mode: .forceProcesses) else { return XCTFail("refreshed") }
        XCTAssertTrue(h.processes.forced.isEmpty); XCTAssertEqual(next.completedApps, 0)
        XCTAssertNotNil(h.processes.live[123]); assertNoDiskActions(h)
    }

    func testRefusalTimeoutAndIdentityFailureStopDiskActions() throws {
        for failure in ["refused", "timeout", "identity"] {
            let h = FlowHarness(); h.add(app: "editor")
            let p = try confirmed(h)
            if failure == "refused" { h.processes.rejectForce = true }
            if failure == "timeout" { h.processes.forceWorks = false }
            if failure == "identity" { h.processes.failIdentity = true }
            guard case .preview = h.flow.execute(p, mode: .forceProcesses) else { return XCTFail("failure preserved") }
            assertNoDiskActions(h)
        }
    }

    func testTimeoutRetryDoesNotRepeatAcceptedForceRequestAndCreditsLateExit() throws {
        let h = FlowHarness(); h.add(app: "editor"); h.processes.forceWorks = false
        let p = try confirmed(h)
        guard case .preview(let failed) = h.flow.execute(p, mode: .forceProcesses) else { return XCTFail("timeout") }
        guard case .preview(let retry) = h.flow.prepareForceProcesses(failed, action: .closeOnly) else { return XCTFail("confirm") }
        guard case .preview(let pending) = h.flow.execute(retry, mode: .forceProcesses) else { return XCTFail("still waiting") }
        XCTAssertEqual(h.processes.forced, [123])
        h.processes.live.removeValue(forKey: 123)
        var resume = pending; resume.forceProcessConfirmation = .closeOnly
        guard case .preview(let finished) = h.flow.execute(resume, mode: .forceProcesses) else { return XCTFail("released") }
        XCTAssertEqual(finished.completedApps, 1)
        XCTAssertEqual(h.processes.forced, [123]); assertNoDiskActions(h)
    }

    func testNewOccupantAfterFirstCloseStopsBeforeNextCloseOrDisk() throws {
        let h = FlowHarness(); h.add(app: "editor"); h.add(pid: 456)
        let p = try confirmed(h)
        h.processes.onForce = { h.add(pid: 789) }
        guard case .preview(let next) = h.flow.execute(p, mode: .forceProcesses) else { return XCTFail("expanded scope") }
        XCTAssertEqual(h.processes.forced, [123])
        XCTAssertFalse(next.selectedForceProcesses.contains { $0.pid == 789 })
        XCTAssertEqual(next.forceRequested.count, 1)
        assertNoDiskActions(h)
    }

    func testScanFailureAfterClosureStopsBeforeDisk() throws {
        let h = FlowHarness(); h.add(app: "editor")
        let p = try confirmed(h)
        h.processes.onForce = {
            h.failures["lsof -nP +w -F pcLfn +f -- " + FlowHarness.mount] = .init(stdout: Data(), stderr: "denied", exitCode: 1)
        }
        guard case .preview(let next) = h.flow.execute(p, mode: .forceProcesses) else { return XCTFail("unverified") }
        XCTAssertTrue(next.incomplete); assertNoDiskActions(h)
    }

    func testCancellationBeforeAndBetweenActionsStopsRemainingWork() throws {
        for before in [true, false] {
            let h = FlowHarness(); h.add(app: "editor"); h.add(pid: 456)
            let p = try confirmed(h)
            if before { h.cancellation.cancel() }
            else { h.processes.onForce = { h.cancellation.cancel() } }
            _ = h.flow.execute(p, mode: .forceProcesses)
            XCTAssertEqual(h.processes.forced, before ? [] : [123])
            assertNoDiskActions(h)
        }
    }

    func testMultipleVolumesAndActiveSimulatorsBlockForceProcessActions() throws {
        let h = FlowHarness(); h.add(app: "editor")
        var p = try confirmed(h)
        let t = p.target
        p = EjectPlan(target: .init(volume: t.volume, physicalDisk: t.physicalDisk,
            affected: t.affected + [.init(name: "Other", mount: "/Volumes/Other", device: "disk90s2", uuid: "other")]),
                      createdAt: p.createdAt, holders: p.holders, images: [], issues: [])
        p.selectedForceProcesses = p.forceEligible; p.forceProcessConfirmation = .closeAndEject
        XCTAssertFalse(p.canForceProcesses)
        _ = h.flow.execute(p, mode: .forceProcesses)
        p = try confirmed(h)
        p.simulators = [.init(udid: "sim", name: "sim", runtimeIdentifier: "runtime", state: "Booted",
                             dataPath: FlowHarness.mount + "/data", runtimePath: nil)]
        XCTAssertFalse(p.canForceProcesses)
        _ = h.flow.execute(p, mode: .forceProcesses)
        XCTAssertTrue(h.processes.forced.isEmpty); assertNoDiskActions(h)
    }

    func testNewOccupantAtImageBoundaryStopsDiskUnmount() throws {
        let h = FlowHarness(); h.add(app: "editor")
        h.images = [.init(path: FlowHarness.mount + "/a.dmg", writable: true, devEntries: ["/dev/disk91"], mountPoints: [])]
        let p = try confirmed(h)
        h.onCall = { key in if key == "hdiutil detach /dev/disk91 -force" { h.add(pid: 789) } }
        guard case .preview = h.flow.execute(p, mode: .forceProcesses) else { return XCTFail("review") }
        XCTAssertFalse(h.calls.contains("diskutil unmountDisk force disk90"))
        XCTAssertFalse(h.calls.contains("diskutil eject disk90"))
    }

    func testForceHistorySurvivesUnknownDiskResultAndReadOnlyReverification() throws {
        let h = FlowHarness(); h.add(app: "editor")
        let p = try confirmed(h)
        h.failures["diskutil eject disk90"] = .init(stdout: Data(), stderr: "timeout", exitCode: -1, timedOut: true)
        guard case .verificationPending(let failure, _) = h.flow.execute(p, mode: .forceProcesses) else { return XCTFail("unknown") }
        XCTAssertEqual(failure.forceRequested.count, 1)
        XCTAssertTrue(failure.forceUsed)
        h.targetInspector.gone = true; h.cancellation = CancellationToken()
        var history: Set<ProcessIdentity> = []
        let f = h.flow; f.onForceProcesses = { history = $0 }
        guard case .ejected = f.reverify(failure) else { return XCTFail("verified") }
        XCTAssertEqual(history, failure.forceRequested)
        XCTAssertEqual(h.processes.forced, [123])
        XCTAssertEqual(h.calls.filter { $0 == "diskutil eject disk90" }.count, 1)
    }

    func testSystemInspectorRejectsProtectedIdentityBeforeAnySignal() {
        let identity = ProcessIdentity(pid: getpid(), uid: getuid(), startedSeconds: 0, startedMicros: 0,
                                       executable: "/opt/devdisk")
        XCTAssertThrowsError(try SystemProcessInspector().forceClose(identity))
    }

    func testZeroSelectionSystemOnlyOccupancyCanDirectlyConfirmDiskForce() throws {
        let h = FlowHarness(); h.add(executable: "/usr/libexec/service", args: "service")
        let p = try confirmed(h)
        XCTAssertTrue(p.selectedForceProcesses.isEmpty)
        XCTAssertTrue(p.canForceProcesses); XCTAssertFalse(p.canCloseSelected)
        XCTAssertNil(p.failure)
        guard case .ejected(_, let apps, let daemons, let forced) = h.flow.execute(p, mode: .forceProcesses) else { return XCTFail("direct disk force") }
        XCTAssertTrue(forced); XCTAssertEqual(apps + daemons, 0)
        XCTAssertTrue(h.processes.forced.isEmpty)
    }

    func testZeroSelectionCannotBypassCancellationOrIncompleteScan() throws {
        for cancel in [true, false] {
            let h = FlowHarness(); h.add(executable: "/usr/libexec/service", args: "service")
            let p = try confirmed(h)
            if cancel { h.cancellation.cancel() }
            else { h.processes.failIdentity = true }
            _ = h.flow.execute(p, mode: .forceProcesses)
            assertNoDiskActions(h)
            XCTAssertTrue(h.processes.forced.isEmpty)
        }
    }

    func testAllClosedThenExpandedScopeCanBeReconfirmedWithoutReclosing() throws {
        for newImage in [false, true] {
            let h = FlowHarness(); h.add(app: "editor")
            let p = try confirmed(h)
            h.processes.onForce = {
                if newImage {
                    h.images = [.init(path: FlowHarness.mount + "/new.dmg", writable: true,
                                      devEntries: ["/dev/disk91"], mountPoints: [])]
                } else { h.add(pid: 789) }
            }
            guard case .preview(let review) = h.flow.execute(p, mode: .forceProcesses) else { return XCTFail("expanded scope") }
            XCTAssertTrue(review.selectedForceProcesses.isEmpty)
            XCTAssertEqual(review.forceProcessConfirmation, .closeAndEject)
            XCTAssertTrue(review.canForceProcesses)
            assertNoDiskActions(h)
            guard case .ejected(_, let apps, _, _) = h.flow.execute(review, mode: .forceProcesses) else { return XCTFail("reconfirmed disk only") }
            XCTAssertEqual(apps, 1)
            XCTAssertEqual(h.processes.forced, [123])
        }
    }

    func testZeroSelectionCloseOnlyAndWrongExecutionModesHaveNoEffects() throws {
        let h = FlowHarness(); h.add(executable: "/usr/libexec/service", args: "service")
        let p = try confirmed(h, action: .closeOnly)
        _ = h.flow.execute(p, mode: .forceProcesses)
        _ = h.flow.execute(p, mode: .prepared)
        _ = h.flow.execute(p, mode: .force)
        assertNoDiskActions(h)
        XCTAssertTrue(h.processes.forced.isEmpty)
    }

    func testPostUnmountScanFailureRequiresFreshProofVolumesRemainUnmounted() throws {
        for state in ["unmounted", "remounted", "unknown"] {
            let h = FlowHarness(); h.add(app: "editor")
            let p = try confirmed(h)
            let f = h.flow
            f.onSystemReturned = {
                guard h.targetInspector.unmounted else { return }
                h.failures["lsof -nP +w -F pcLfn +f -- " + FlowHarness.mount] =
                    .init(stdout: Data(), stderr: "filesystem unavailable", exitCode: 1)
                if state == "remounted" { h.targetInspector.unmounted = false }
                if state == "unknown" { h.targetInspector.verifyError = true }
            }
            let result = f.execute(p, mode: .forceProcesses)
            if state == "unmounted" {
                guard case .ejected = result else { return XCTFail("verified unmounted target can finish") }
                XCTAssertTrue(h.calls.contains("diskutil eject disk90"))
            } else {
                guard case .preview(let review) = result else { return XCTFail("unknown scope must stop: \(state)") }
                XCTAssertTrue(review.incomplete)
                XCTAssertFalse(h.calls.contains("diskutil eject disk90"))
            }
        }
    }

    func testForcedImageFailureRetainsProcessHistoryInDiagnostic() throws {
        let h = FlowHarness(); h.add(app: "editor")
        h.images = [.init(path: FlowHarness.mount + "/a.dmg", writable: true, devEntries: ["/dev/disk91"], mountPoints: [])]
        h.detachWorks = false
        let f = h.flow, p = try confirmed(h)
        guard case .aborted = f.execute(p, mode: .forceProcesses) else { return XCTFail("failed detach") }
        XCTAssertEqual(f.lastFailure?.forceRequested.count, 1)
        XCTAssertTrue(f.lastFailure?.forceUsed == true)
        guard case .preview(let retry) = h.flow.prepareForce(try XCTUnwrap(f.lastFailure)) else { return XCTFail("legacy disk retry") }
        h.detachWorks = true
        guard case .ejected = h.flow.execute(retry, mode: .force) else { return XCTFail("disk retry") }
        XCTAssertEqual(h.processes.forced, [123])
    }
}
