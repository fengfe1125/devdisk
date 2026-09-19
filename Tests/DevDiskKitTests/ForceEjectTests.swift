import XCTest
@testable import DevDiskKit

final class ForceEjectTests: XCTestCase {
    private let busy = CommandResult(stdout: Data(), stderr: "image or disk busy", exitCode: 1)
    private let eject = "diskutil eject disk90"
    private let detach = "hdiutil detach /dev/disk91"
    private let unmount = "diskutil unmountDisk force disk90"

    private func image(_ device: String = "disk91", path: String? = nil, mounts: [String] = []) -> DiskImage {
        .init(path: path ?? FlowHarness.mount + "/simulator.sparseimage", writable: true,
              devEntries: ["/dev/" + device], mountPoints: mounts)
    }
    private func forcePlan(_ h: FlowHarness, images: Bool = true) throws -> EjectPlan {
        if images { h.images = [image()]; h.failures[detach] = busy }
        else { h.failures[eject] = busy }
        let flow = h.flow
        _ = flow.execute(try flow.prepare(), mode: images ? .prepared : .systemOnly)
        let failure = try XCTUnwrap(flow.lastFailure)
        XCTAssertTrue(failure.allowsForce)
        guard case .preview(let plan) = h.flow.prepareForce(failure) else { throw ProbeFailure("missing force preview") }
        return plan
    }
    func testForceRequiresBothOrdinaryFailureAndFreshConfirmation() throws {
        let h = FlowHarness(); h.images = [image()]
        let flow = h.flow, plan = try flow.prepare()
        XCTAssertFalse(plan.canForce)
        guard case .aborted = flow.execute(plan, mode: .force) else { return XCTFail("force must require confirmation") }
        XCTAssertFalse(h.calls.contains { $0.contains("force") || $0.hasPrefix("hdiutil detach") })
    }
    func testWritableImageNormalFailureThenConfirmedForceCompletesInOrder() throws {
        let h = FlowHarness(), plan = try forcePlan(h)
        XCTAssertTrue(plan.canForce)
        XCTAssertFalse(h.calls.contains { $0.contains("force") })
        guard case .ejected(_, _, _, let forced) = h.flow.execute(plan, mode: .force) else { return XCTFail("force should complete") }
        XCTAssertTrue(forced)
        let imageIndex = try XCTUnwrap(h.calls.firstIndex(of: detach + " -force"))
        let diskIndex = try XCTUnwrap(h.calls.firstIndex(of: unmount))
        let ejectIndex = try XCTUnwrap(h.calls.firstIndex(of: eject))
        XCTAssertLessThan(imageIndex, diskIndex); XCTAssertLessThan(diskIndex, ejectIndex)
        XCTAssertTrue(h.processes.quits.isEmpty)
        XCTAssertFalse(h.calls.contains { $0.hasPrefix("kill") })
    }
    func testForceFailureKeepsCommandDetailsAndNeverUnmountsBackingDisk() throws {
        let h = FlowHarness(), plan = try forcePlan(h)
        h.failures[detach + " -force"] = busy
        let flow = h.flow
        guard case .aborted = flow.execute(plan, mode: .force) else { return XCTFail("must fail") }
        XCTAssertEqual(flow.lastFailure?.stage, "force-images")
        XCTAssertEqual(flow.lastFailure?.commandExitCode, 1)
        XCTAssertTrue(flow.lastFailure?.commandOutput.contains("busy") == true)
        XCTAssertEqual(flow.lastFailure?.forceUsed, true)
        XCTAssertFalse(h.calls.contains(unmount)); XCTAssertFalse(h.calls.contains(eject))
    }
    func testSuccessfulDetachReturnWithImageStillAttachedStaysPending() throws {
        let h = FlowHarness(); h.images = [image()]
        h.failures[detach] = .init(stdout: Data(), stderr: "", exitCode: 0)
        let f = h.flow
        guard case .verificationPending(let failure, _) = f.execute(try f.prepare(), mode: .prepared) else { return XCTFail("pending") }
        XCTAssertFalse(failure.allowsForce)
        XCTAssertNotNil(failure.pendingImage)
        XCTAssertFalse(h.calls.contains(eject))
    }
    func testTimedOutImageRecheckDoesNotSubmitAnotherCommandOrOfferForce() throws {
        let h = FlowHarness(); h.images = [image()]
        h.failures[detach] = .init(stdout: Data(), stderr: "timeout details", exitCode: -1, timedOut: true)
        let f = h.flow
        guard case .verificationPending(let failure, _) = f.execute(try f.prepare(), mode: .prepared) else { return XCTFail("pending") }
        XCTAssertTrue(failure.commandTimedOut)
        h.cancellation = CancellationToken()
        let count = h.calls.count
        guard case .preview(let next) = h.flow.reverify(failure) else { return XCTFail("review current state") }
        XCTAssertFalse(next.canForce)
        XCTAssertFalse(h.calls.dropFirst(count).contains { $0.hasPrefix("hdiutil detach") || $0 == eject })
    }
    func testExpiredForceConfirmationRefreshesWithoutSideEffects() throws {
        let h = FlowHarness(), plan = try forcePlan(h)
        h.clock += 31
        guard case .preview(let fresh) = h.flow.execute(plan, mode: .force) else { return XCTFail("reconfirm") }
        XCTAssertTrue(fresh.forceConfirmation)
        XCTAssertEqual(fresh.createdAt, h.clock)
        XCTAssertFalse(h.calls.contains { $0.contains("force") })
    }
    func testNewImageOrVolumeRequiresNewForceConfirmation() throws {
        for newVolume in [false, true] {
            let h = FlowHarness(), plan = try forcePlan(h)
            if newVolume {
                let t = h.targetInspector.current
                h.targetInspector.current = .init(volume: t.volume, physicalDisk: t.physicalDisk,
                    affected: t.affected + [.init(name: "Other", mount: "/Volumes/Other", device: "disk90s2", uuid: "other")])
            } else { h.images.append(image("disk92", path: FlowHarness.mount + "/new.dmg")) }
            guard case .preview(let next) = h.flow.execute(plan, mode: .force) else { return XCTFail("expanded scope") }
            XCTAssertTrue(next.forceConfirmation)
            XCTAssertFalse(h.calls.contains { $0.contains("force") })
        }
    }
    func testImageDeviceReuseAndTargetReplacementNeverForceOldScope() throws {
        for replaceTarget in [false, true] {
            let h = FlowHarness(), plan = try forcePlan(h)
            if replaceTarget {
                let t = h.targetInspector.current
                h.targetInspector.current = .init(volume: .init(name: "Other", mount: t.volume.mount, device: t.volume.device, uuid: "replacement"), physicalDisk: t.physicalDisk, affected: t.affected)
            } else { h.images = [image(path: FlowHarness.mount + "/replacement.dmg")] }
            _ = h.flow.execute(plan, mode: .force)
            XCTAssertFalse(h.calls.contains { $0.contains("force") })
        }
    }
    func testUnreadableImageInventoryDisablesForceButKeepsNormalSystemRoute() throws {
        let h = FlowHarness(), plan = try forcePlan(h)
        h.failures["hdiutil info -plist"] = .init(stdout: Data(), stderr: "denied", exitCode: 1)
        guard case .preview(let fresh) = h.flow.execute(plan, mode: .force) else { return XCTFail("reconfirm unavailable scope") }
        XCTAssertFalse(fresh.canForce)
        XCTAssertTrue(fresh.canSystemOnly)
        XCTAssertFalse(h.calls.contains { $0.contains("force") })
    }
    func testImageMountedOccupantsAreScannedAndDuplicateProcessesActOnce() throws {
        let h = FlowHarness(); h.images = [image(mounts: ["/Volumes/Simulator"])]
        h.add(app: "editor", paths: [FlowHarness.mount + "/file", "/Volumes/Simulator/document"])
        let f = h.flow, plan = try f.prepare()
        XCTAssertEqual(plan.apps.count, 1)
        XCTAssertEqual(plan.apps.first?.openFileCount, 2)
        guard case .ejected = f.execute(plan, mode: .prepared) else { return XCTFail("normal success") }
        XCTAssertEqual(h.processes.quits, [123])
    }
    func testAppStillUsingOnlyImageIsNotMistakenForReleased() throws {
        let h = FlowHarness(); h.images = [image(mounts: ["/Volumes/Simulator"])]
        h.add(app: "editor", paths: ["/Volumes/Simulator/document"])
        h.processes.refuseQuit = true
        let f = h.flow
        guard case .preview(let waiting) = f.execute(try f.prepare(), mode: .prepared) else { return XCTFail("still waiting") }
        XCTAssertTrue(waiting.canSystemOnly)
        XCTAssertFalse(h.calls.contains(detach))
    }
    func testNestedImagesDetachBeforeTheirBackingImage() throws {
        let h = FlowHarness()
        h.images = [image("disk92", path: "/Volumes/Simulator/child.dmg"), image(mounts: ["/Volumes/Simulator"])]
        let f = h.flow
        guard case .ejected = f.execute(try f.prepare(), mode: .prepared) else { return XCTFail("detach dependencies") }
        XCTAssertLessThan(try XCTUnwrap(h.calls.firstIndex(of: "hdiutil detach /dev/disk92")),
                          try XCTUnwrap(h.calls.firstIndex(of: detach)))
    }
    func testOtherVolumeImagesIncludedInForceScope() throws {
        let h = FlowHarness()
        let t = h.targetInspector.current
        h.targetInspector.current = .init(volume: t.volume, physicalDisk: t.physicalDisk,
            affected: t.affected + [.init(name: "Other", mount: "/Volumes/Other", device: "disk90s2", uuid: "other")])
        h.images = [image(path: "/Volumes/Other/other.dmg")]
        let plan = try forcePlan(h, images: false)
        XCTAssertEqual(plan.images.count, 1)
        XCTAssertEqual(plan.target.affected.count, 2)
        h.failures.removeValue(forKey: eject)
        guard case .ejected = h.flow.execute(plan, mode: .force) else { return XCTFail("multi volume force") }
    }
    func testCancelBetweenForcedImageAndDiskPreventsUnmount() throws {
        let h = FlowHarness(), plan = try forcePlan(h), f = h.flow
        f.onSystemReturned = { h.cancellation.cancel() }
        guard case .aborted = f.execute(plan, mode: .force) else { return XCTFail("cancel") }
        XCTAssertFalse(h.calls.contains(unmount)); XCTAssertFalse(h.calls.contains(eject))
        XCTAssertEqual(f.lastFailure?.forceUsed, true)
    }
    func testCancelledForceConfirmationDoesNothing() throws {
        let h = FlowHarness(), plan = try forcePlan(h)
        h.cancellation.cancel()
        _ = h.flow.execute(plan, mode: .force)
        XCTAssertFalse(h.calls.contains { $0.contains("force") })
    }
    func testForceUnmountFailureRetainsRiskAndStopsBeforeEject() throws {
        let h = FlowHarness(), plan = try forcePlan(h)
        h.failures[unmount] = busy
        let f = h.flow
        guard case .aborted = f.execute(plan, mode: .force) else { return XCTFail("unmount failure") }
        XCTAssertEqual(f.lastFailure?.stage, "force-unmount")
        XCTAssertEqual(f.lastFailure?.forceUsed, true)
        XCTAssertFalse(h.calls.contains(eject))
    }
    func testPendingForcedCompletionKeepsForceFlagWhenReverified() throws {
        let h = FlowHarness(), plan = try forcePlan(h)
        h.failures[eject] = .init(stdout: Data(), stderr: "timeout", exitCode: -1, timedOut: true)
        guard case .verificationPending(let failure, _) = h.flow.execute(plan, mode: .force) else { return XCTFail("pending final eject") }
        XCTAssertTrue(failure.forceUsed)
        h.targetInspector.gone = true
        h.cancellation = CancellationToken()
        guard case .ejected(_, _, _, let forced) = h.flow.reverify(failure) else { return XCTFail("late success") }
        XCTAssertTrue(forced)
        XCTAssertEqual(h.calls.filter { $0 == eject }.count, 1)
    }
    func testRetryDoesNotRepeatCompletedDetachOrUnmount() throws {
        let h = FlowHarness(), plan = try forcePlan(h)
        h.failures[eject] = busy
        let f = h.flow
        guard case .aborted = f.execute(plan, mode: .force) else { return XCTFail("eject refusal") }
        let failure = try XCTUnwrap(f.lastFailure)
        guard case .preview(let retry) = h.flow.prepareForce(failure) else { return XCTFail("fresh confirmation") }
        h.failures.removeValue(forKey: eject)
        guard case .ejected(_, _, _, let forced) = h.flow.execute(retry, mode: .force) else { return XCTFail("retry eject") }
        XCTAssertTrue(forced)
        XCTAssertEqual(h.calls.filter { $0 == detach + " -force" }.count, 1)
        XCTAssertEqual(h.calls.filter { $0 == unmount }.count, 1)
    }
    func testForceUnmountTimeoutRecheckDoesNotRepeatUnmount() throws {
        let h = FlowHarness(), plan = try forcePlan(h)
        h.failures[unmount] = .init(stdout: Data(), stderr: "timeout", exitCode: -1, timedOut: true)
        guard case .verificationPending(let failure, _) = h.flow.execute(plan, mode: .force) else { return XCTFail("pending unmount") }
        XCTAssertTrue(failure.forceUsed)
        h.targetInspector.unmounted = true
        h.cancellation = CancellationToken()
        guard case .preview(let next) = h.flow.reverify(failure) else { return XCTFail("fresh confirmation") }
        XCTAssertTrue(next.forceConfirmation)
        XCTAssertTrue(next.canForce)
        guard case .ejected(_, _, _, let forced) = h.flow.execute(next, mode: .force) else { return XCTFail("finish without another unmount") }
        XCTAssertTrue(forced)
        XCTAssertEqual(h.calls.filter { $0 == unmount }.count, 1)
    }
    func testAttachmentReappearingAfterDiskEjectPreventsFalseSuccess() throws {
        let h = FlowHarness(); h.images = [image()]
        h.onCall = { key in if key == self.eject { h.images = [self.image()] } }
        let f = h.flow
        guard case .verificationPending = f.execute(try f.prepare(), mode: .prepared) else { return XCTFail("image still attached") }
    }

    func testDiskutilFillsMissingImageMountPointsBeforeOccupancyScan() throws {
        let h = FlowHarness(); h.images = [image()]
        let info: [String: Any] = ["DeviceIdentifier": "disk91", "VolumeUUID": "image-volume", "MountPoint": "/Volumes/HiddenSimulator"]
        h.failures["diskutil info -plist /dev/disk91"] = .init(
            stdout: try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0), stderr: "", exitCode: 0)
        h.add(app: "editor", paths: ["/Volumes/HiddenSimulator/document"])
        let plan = try h.flow.prepare()
        XCTAssertEqual(plan.images.first?.mountPoints, ["/Volumes/HiddenSimulator"])
        XCTAssertEqual(plan.images.first?.volumeUUIDs["/dev/disk91"], "image-volume")
        XCTAssertEqual(plan.apps.count, 1)
    }
    func testUnverifiableImageDeviceDoesNotSilentlyDropDependency() throws {
        let h = FlowHarness(); h.images = [image()]
        h.failures["diskutil info -plist /dev/disk91"] = .init(stdout: Data(), stderr: "device disappeared", exitCode: 1)
        let plan = try h.flow.prepare()
        XCTAssertFalse(plan.imagesKnown)
        XCTAssertFalse(plan.canPrepare)
        XCTAssertTrue(plan.canSystemOnly)
        XCTAssertFalse(plan.canForce)
    }

}
