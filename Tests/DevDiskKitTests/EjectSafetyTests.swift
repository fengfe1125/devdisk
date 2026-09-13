import XCTest
@testable import DevDiskKit

final class EjectSafetyTests: XCTestCase {
    func testUnrelatedXcodeIsNeverQuit() {
        let h = FlowHarness()
        h.add(executable: "/Applications/Xcode.app/Contents/MacOS/Xcode", args: "Xcode", app: "com.apple.dt.Xcode", paths: [])
        guard case .ejected = h.flow.run(indexingOn: nil) else { return XCTFail("idle disk should eject") }
        XCTAssertTrue(h.processes.quits.isEmpty)
    }
    func testActualFileEvidenceFindsAppWithoutMountInArguments() throws {
        let h = FlowHarness()
        h.add(executable: "/Applications/Editor.app/Contents/MacOS/Editor", args: "Editor", app: "review.editor")
        let f = h.flow
        guard case .preview(let plan) = f.run(indexingOn: nil) else { return XCTFail("must preview") }
        XCTAssertEqual(plan.apps.count, 1)
        XCTAssertTrue(h.processes.quits.isEmpty)
        XCTAssertFalse(h.calls.contains { $0.hasPrefix("diskutil eject") })
        guard case .ejected(_, let apps, _) = f.execute(plan, systemOnly: false) else { return XCTFail("confirmed plan should eject") }
        XCTAssertEqual(apps, 1)
        XCTAssertEqual(h.processes.quits, [123])
    }
    func testDaemonRequiresConfirmationAndStopsByPID() throws {
        let h = FlowHarness(); h.add()
        let f = h.flow, plan = try f.prepare()
        XCTAssertEqual(plan.daemons.count, 1)
        XCTAssertFalse(h.calls.contains { $0.hasPrefix("kill") })
        guard case .ejected(_, _, let stopped) = f.execute(plan, systemOnly: false) else { return XCTFail("must eject") }
        XCTAssertEqual(stopped, 1)
        XCTAssertTrue(h.calls.contains("kill -TERM 123"))
        XCTAssertFalse(h.calls.contains { $0.hasPrefix("pkill") || $0.contains("-KILL") })
    }
    func testForegroundBuildVMAndUnknownAreManual() throws {
        for (exe, args) in [("java", "java org.gradle.wrapper.GradleWrapperMain"),
                            ("qemu-system-aarch64", "qemu-system-aarch64"), ("vim", "vim file")] {
            let h = FlowHarness(); h.add(executable: "/usr/bin/" + exe, args: args)
            let f = h.flow, plan = try f.prepare()
            XCTAssertEqual(plan.manual.count, 1)
            guard case .preview = f.execute(plan, systemOnly: false) else { XCTFail("must remain preview"); continue }
            XCTAssertFalse(h.calls.contains { $0.hasPrefix("kill") || $0.hasPrefix("diskutil eject") })
        }
    }
    func testOtherUsersProcessesAreNeverSignalled() throws {
        let h = FlowHarness(); h.add(uid: getuid() + 1)
        let f = h.flow, plan = try f.prepare()
        XCTAssertTrue(plan.daemons.isEmpty)
        _ = f.execute(plan, systemOnly: false)
        XCTAssertFalse(h.calls.contains { $0.hasPrefix("kill") })
    }
    func testPrefixCollisionIsIncompleteNotAnAction() throws {
        let h = FlowHarness(); h.add(paths: [FlowHarness.mount + "Other/a"])
        let p = try h.flow.prepare()
        XCTAssertTrue(p.daemons.isEmpty)
        XCTAssertTrue(p.incomplete)
    }
    func testTimeoutKeepsUnknownAndSystemOnlyDoesNoCleanup() throws {
        let h = FlowHarness(); h.add()
        let key = "lsof -nP +w -F pcLn +D " + FlowHarness.mount
        h.failures[key] = .init(stdout: Data(), stderr: "", exitCode: 0, timedOut: true)
        let f = h.flow, plan = try f.prepare()
        XCTAssertTrue(plan.incomplete)
        guard case .ejected = f.execute(plan, systemOnly: true) else { return XCTFail("system only") }
        XCTAssertTrue(h.processes.quits.isEmpty)
        XCTAssertFalse(h.calls.contains { $0.hasPrefix("kill") || $0.hasPrefix("hdiutil detach") })
    }
    func testProbeFailuresAreNotEmptySuccess() throws {
        for command in ["ps -axo pid=,user=,args=", "hdiutil info -plist", "lsof -nP +w -F pcLn +D " + FlowHarness.mount] {
            let h = FlowHarness()
            h.failures[command] = .init(stdout: Data(), stderr: "permission denied", exitCode: 1)
            let p = try h.flow.prepare()
            XCTAssertTrue(p.incomplete, command)
        }
    }
    func testMalformedLsofAndPSAreUnknown() throws {
        for command in ["ps -axo pid=,user=,args=", "lsof -nP +w -F pcLn +D " + FlowHarness.mount] {
            let h = FlowHarness()
            h.failures[command] = .init(stdout: Data("garbage\n".utf8), stderr: "", exitCode: 0)
            XCTAssertTrue(try h.flow.prepare().incomplete)
        }
    }
    func testTERMReturnDoesNotMeanProcessExited() throws {
        let h = FlowHarness(); h.add(); h.stopWorks = false
        let f = h.flow, p = try f.prepare()
        guard case .aborted(let why) = f.execute(p, systemOnly: false) else { return XCTFail("must abort") }
        XCTAssertTrue(why.contains("仍在运行"))
        XCTAssertTrue(why.contains("停止服务进程 0"))
        XCTAssertFalse(h.calls.contains { $0.hasPrefix("diskutil eject") })
    }
    func testRefusedAppQuitNeverEscalates() throws {
        let h = FlowHarness(); h.add(app: "review.editor"); h.processes.refuseQuit = true
        let f = h.flow, p = try f.prepare()
        guard case .aborted = f.execute(p, systemOnly: false) else { return XCTFail("must abort") }
        XCTAssertFalse(h.calls.contains { $0.hasPrefix("kill") || $0.hasPrefix("diskutil eject") })
    }
    func testPIDReuseReturnsNewPreview() throws {
        let h = FlowHarness(); h.add()
        let f = h.flow, p = try f.prepare()
        h.processes.live[123] = .init(pid: 123, uid: getuid(), startedSeconds: 99, startedMicros: 0, executable: "/usr/bin/java")
        guard case .preview = f.execute(p, systemOnly: false) else { return XCTFail("must reconfirm new identity") }
        XCTAssertFalse(h.calls.contains { $0.hasPrefix("kill") })
    }
    func testNewHolderAfterConfirmationCannotExpandScope() throws {
        let h = FlowHarness(); h.add()
        let f = h.flow, p = try f.prepare()
        h.add(pid: 456)
        guard case .preview(let new) = f.execute(p, systemOnly: false) else { return XCTFail("must reconfirm") }
        XCTAssertEqual(new.daemons.count, 2)
        XCTAssertFalse(h.calls.contains { $0.hasPrefix("kill") })
    }
    func testExpiredPlanRepreparesWithoutEffects() throws {
        let h = FlowHarness(); h.add()
        let f = h.flow, p = try f.prepare(); h.clock += 31
        guard case .preview = f.execute(p, systemOnly: false) else { return XCTFail("expired") }
        XCTAssertFalse(h.calls.contains { $0.hasPrefix("kill") })
    }
    func testCancelAfterQuitPreventsDaemonAndEject() throws {
        let h = FlowHarness(); h.add(app: "review.editor"); h.add(pid: 456)
        h.processes.onQuit = { h.cancellation.cancel() }
        let f = h.flow, p = try f.prepare()
        guard case .aborted = f.execute(p, systemOnly: false) else { return XCTFail("cancelled") }
        XCTAssertFalse(h.calls.contains { $0.hasPrefix("kill") || $0.hasPrefix("diskutil eject") })
    }
    func testCommitPreventsMisleadingCancel() throws {
        let h = FlowHarness(), f = h.flow
        f.onCommit = { h.cancellation.cancel() }
        guard case .ejected = f.run(indexingOn: nil) else { return XCTFail("system operation must finish") }
        XCTAssertFalse(h.cancellation.isCancelled)
        XCTAssertTrue(h.cancellation.isCommitted)
    }
    func testWritableAndUnknownAccessImagesNeverDetach() throws {
        for known in [true, false] {
            let h = FlowHarness()
            h.images = [.init(path: FlowHarness.mount + "/work.dmg", writable: known, accessKnown: known, devEntries: ["/dev/disk91"], mountPoints: [])]
            let f = h.flow, p = try f.prepare()
            XCTAssertFalse(p.canPrepare)
            guard case .preview = f.execute(p, systemOnly: false) else { return XCTFail("manual") }
            XCTAssertFalse(h.calls.contains { $0.hasPrefix("hdiutil detach") || $0.hasPrefix("diskutil eject") })
        }
    }
    func testReadOnlyImageDetachesOnlyAfterConfirmation() throws {
        let h = FlowHarness()
        h.images = [.init(path: FlowHarness.mount + "/install.dmg", writable: false, devEntries: ["/dev/disk91"], mountPoints: [])]
        let f = h.flow, p = try f.prepare()
        XCTAssertFalse(h.calls.contains { $0.hasPrefix("hdiutil detach") })
        guard case .ejected = f.execute(p, systemOnly: false) else { return XCTFail("ejected") }
        XCTAssertTrue(h.calls.contains("hdiutil detach /dev/disk91"))
    }
    func testDetachFailureStopsExecution() throws {
        let h = FlowHarness(); h.detachWorks = false
        h.images = [.init(path: FlowHarness.mount + "/install.dmg", writable: false, devEntries: ["/dev/disk91"], mountPoints: [])]
        let f = h.flow, p = try f.prepare()
        guard case .aborted = f.execute(p, systemOnly: false) else { return XCTFail("abort") }
        XCTAssertFalse(h.calls.contains { $0.hasPrefix("diskutil eject") })
    }
    func testMultiVolumeOnlyAllowsExplicitSystemEject() throws {
        let h = FlowHarness(); h.add()
        let t = h.targetInspector.current
        h.targetInspector.current = .init(volume: t.volume, physicalDisk: t.physicalDisk,
            affected: t.affected + [.init(name: "Other", mount: "/Volumes/Other", device: "disk90s2", uuid: "other")])
        let f = h.flow, p = try f.prepare()
        XCTAssertFalse(p.canPrepare)
        XCTAssertTrue(p.canSystemOnly)
        guard case .ejected = f.execute(p, systemOnly: true) else { return XCTFail("system") }
        XCTAssertFalse(h.calls.contains { $0.hasPrefix("kill") })
    }
    func testTargetChangeAbortsBeforeActions() throws {
        let h = FlowHarness(); h.add()
        let f = h.flow, p = try f.prepare()
        let t = h.targetInspector.current
        h.targetInspector.current = .init(volume: .init(name: "Other", mount: t.volume.mount, device: t.volume.device, uuid: "replacement"), physicalDisk: t.physicalDisk, affected: t.affected)
        guard case .aborted = f.execute(p, systemOnly: false) else { return XCTFail("target changed") }
        XCTAssertFalse(h.calls.contains { $0.hasPrefix("kill") || $0.hasPrefix("diskutil eject") })
    }
    func testEjectSuccessWithoutVerificationDoesNotSaySafe() {
        let h = FlowHarness(); h.targetInspector.verifyError = true
        guard case .aborted(let why) = h.flow.run(indexingOn: nil) else { return XCTFail("must not claim safe") }
        XCTAssertTrue(why.contains("未确认可拔线"))
    }
    func testEjectTimeoutWithDiskPresentIsUnknown() {
        let h = FlowHarness()
        h.failures["diskutil eject disk90"] = .init(stdout: Data(), stderr: "", exitCode: -1, timedOut: true)
        guard case .aborted(let why) = h.flow.run(indexingOn: nil) else { return XCTFail("unknown") }
        XCTAssertTrue(why.contains("结果未知"))
    }
    func testEjectRefusalReportsDissenter() throws {
        let h = FlowHarness()
        h.failures["diskutil eject disk90"] = .init(stdout: Data(), stderr: "Unmount was dissented by PID 12167 (/usr/bin/tail)", exitCode: 1)
        guard case .aborted(let why) = h.flow.run(indexingOn: nil) else { return XCTFail("refused") }
        XCTAssertTrue(why.contains("tail"))
    }
    func testGUIServiceImageAndDiskOrder() throws {
        let h = FlowHarness(); h.add(app: "review.editor"); h.add(pid: 456)
        h.images = [.init(path: FlowHarness.mount + "/installer.dmg", writable: false, devEntries: ["/dev/disk91"], mountPoints: [])]
        h.processes.onQuit = { h.calls.append("GUI quit") }
        let f = h.flow, p = try f.prepare()
        guard case .ejected = f.execute(p, systemOnly: false) else { return XCTFail("must finish") }
        let app = try XCTUnwrap(h.calls.firstIndex(of: "GUI quit"))
        let service = try XCTUnwrap(h.calls.firstIndex(of: "kill -TERM 456"))
        let image = try XCTUnwrap(h.calls.firstIndex(of: "hdiutil detach /dev/disk91"))
        let disk = try XCTUnwrap(h.calls.firstIndex(of: "diskutil eject disk90"))
        XCTAssertLessThan(app, service); XCTAssertLessThan(service, image); XCTAssertLessThan(image, disk)
    }
    func testCompletedActionsSurviveAnUpdatedPreview() throws {
        let h = FlowHarness(); h.add(app: "review.editor")
        h.processes.onQuit = { h.add(pid: 456) }
        let f = h.flow, p = try f.prepare()
        guard case .preview(let next) = f.execute(p, systemOnly: false) else { return XCTFail("new holder requires preview") }
        XCTAssertEqual(next.completedApps, 1)
        let nextFlow = h.flow
        guard case .ejected(_, let apps, let daemons) = nextFlow.execute(next, systemOnly: false) else { return XCTFail("confirmed update") }
        XCTAssertEqual(apps, 1); XCTAssertEqual(daemons, 1)
    }
    func testSelectedVolumeCannotBeReplacedBeforePreflight() {
        let h = FlowHarness(), f = h.flow
        f.expectedVolume = .init(name: "original", mount: FlowHarness.mount, device: "disk90s1", uuid: "original")
        guard case .aborted = f.run(indexingOn: nil) else { return XCTFail("must reject replacement") }
        XCTAssertTrue(h.calls.isEmpty)
    }
}
