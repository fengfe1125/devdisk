import XCTest
@testable import DevDiskKit

/// The eject sequence is the only destructive part of the app, so it is exercised
/// entirely against a mock runner: these tests assert what *would* be executed,
/// in what order, without touching a real volume.
final class EjectFlowTests: XCTestCase {

    let mount = "/Volumes/Developer"

    let psWithBoth = """
      4821 example   /Applications/Android Studio.app/Contents/MacOS/studio
      5194 example   /usr/bin/java -Dgradle.user.home=/Volumes/Developer/Android/gradle GradleDaemon 8.14
       332 root     /System/Library/CoreServices/fseventsd
    """

    let psAfterQuit = """
       332 root     /System/Library/CoreServices/fseventsd
    """

    private func flow(_ runner: MockCommandRunner) -> EjectFlow {
        let f = EjectFlow(runner: runner, mountPoint: mount)
        f.sleep = { _ in }              // never actually wait
        f.quitTimeout = 2
        return f
    }

    // MARK: - Happy path

    func testFullSequenceOrder() {
        let m = MockCommandRunner()
        m.stubSequence("ps -axo pid=,user=,args=", [psWithBoth, psAfterQuit, psAfterQuit])
        m.stub("diskutil eject \(mount)", stdout: "Volume Developer on disk7s1 ejected")

        let outcome = flow(m).run(indexingOn: true)

        guard case .ejected(_, let apps, let daemons) = outcome else {
            return XCTFail("expected .ejected, got \(outcome)")
        }
        XCTAssertEqual(apps, 1)
        XCTAssertEqual(daemons, 1)

        // The app is asked to quit before any daemon is signalled, and the volume is
        // only unmounted at the very end.
        let log = m.log
        let quit = try! XCTUnwrap(log.firstIndex { $0.hasPrefix("osascript") })
        let kill = try! XCTUnwrap(log.firstIndex { $0.hasPrefix("kill") })
        let eject = try! XCTUnwrap(log.firstIndex { $0.hasPrefix("diskutil eject") })
        XCTAssertLessThan(quit, kill)
        XCTAssertLessThan(kill, eject)
        XCTAssertEqual(eject, log.count - 1)
    }

    func testQuitsAppByBundleIdentifier() {
        let m = MockCommandRunner()
        m.stubSequence("ps -axo pid=,user=,args=", [psWithBoth, psAfterQuit])
        _ = flow(m).run(indexingOn: false)

        let quit = m.log.first { $0.hasPrefix("osascript") }
        XCTAssertEqual(quit,
            #"osascript -e tell application id "com.google.android.studio" to quit"#)
    }

    /// GUI applications must never be killed — they own unsaved user work. Only a
    /// polite AppleScript quit is allowed, and only SIGTERM ever reaches a daemon.
    func testNeverForceKillsAnything() {
        let m = MockCommandRunner()
        m.stubSequence("ps -axo pid=,user=,args=", [psWithBoth, psAfterQuit])
        _ = flow(m).run(indexingOn: false)

        for call in m.log {
            XCTAssertFalse(call.contains("-9"), "force kill in: \(call)")
            XCTAssertFalse(call.contains("-KILL"), "force kill in: \(call)")
        }
        XCTAssertFalse(m.log.contains { $0.hasPrefix("pkill") })
        XCTAssertTrue(m.log.contains { $0.hasPrefix("kill -TERM") })
    }

    func testDaemonKilledByPIDNotByPattern() {
        let m = MockCommandRunner()
        m.stubSequence("ps -axo pid=,user=,args=", [psWithBoth, psAfterQuit])
        _ = flow(m).run(indexingOn: false)

        XCTAssertTrue(m.log.contains("kill -TERM 5194"))
    }

    // MARK: - Abort paths

    /// If the app is still running after the quit request, the user most likely hit
    /// Cancel on a save dialog. The flow must stop there and never unmount.
    func testAbortsWhenAppRefusesToQuit() {
        let m = MockCommandRunner()
        m.stub("ps -axo pid=,user=,args=", stdout: psWithBoth)   // never goes away
        m.stub("diskutil eject \(mount)", stdout: "should not happen")

        let outcome = flow(m).run(indexingOn: false)

        guard case .aborted(let why) = outcome else {
            return XCTFail("expected .aborted, got \(outcome)")
        }
        XCTAssertTrue(why.contains("Android Studio"))
        XCTAssertFalse(m.log.contains { $0.hasPrefix("diskutil eject") },
                       "must not unmount after an aborted quit")
        XCTAssertFalse(m.log.contains { $0.hasPrefix("kill") },
                       "must not touch daemons after an aborted quit")
    }

    func testReportsDissenterWhenUnmountFails() {
        let m = MockCommandRunner()
        m.stubSequence("ps -axo pid=,user=,args=", [psAfterQuit, psAfterQuit])
        m.stub("diskutil eject \(mount)",
               stdout: "Unmount failed",
               exitCode: 1,
               stderr: "Dissenter PID=612 (mds_stores) status=0x0000c010 (kDAReturnBusy)")

        let outcome = flow(m).run(indexingOn: true)

        guard case .aborted(let why) = outcome else {
            return XCTFail("expected .aborted, got \(outcome)")
        }
        XCTAssertTrue(why.contains("mds_stores"), why)
        XCTAssertTrue(why.contains("612"), why)
    }

    // MARK: - Nothing to do

    func testSkipsEmptyStages() {
        let m = MockCommandRunner()
        m.stub("ps -axo pid=,user=,args=", stdout: psAfterQuit)  // only system processes
        m.stub("diskutil eject \(mount)", stdout: "ejected")

        let f = flow(m)
        var final: [EjectFlow.Step] = []
        f.onUpdate = { final = $0 }
        let outcome = f.run(indexingOn: false)

        guard case .ejected = outcome else { return XCTFail("expected .ejected") }
        XCTAssertEqual(final.first { $0.id == "apps" }?.state,
                       .skipped("没有需要退出的应用"))
        XCTAssertEqual(final.first { $0.id == "daemons" }?.state,
                       .skipped("没有运行中的守护进程"))
        XCTAssertFalse(m.log.contains { $0.hasPrefix("osascript") })
    }

    /// System daemons are never signalled — diskutil releases them.
    func testNeverTouchesSystemProcesses() {
        let m = MockCommandRunner()
        m.stub("ps -axo pid=,user=,args=", stdout: psAfterQuit)
        m.stub("diskutil eject \(mount)", stdout: "ejected")
        _ = flow(m).run(indexingOn: true)

        XCTAssertFalse(m.log.contains { $0.contains("332") },
                       "fseventsd must never be signalled")
        XCTAssertFalse(m.log.contains { $0.contains("mds_stores") })
    }

    // MARK: - Step reporting

    func testStepsProgressThroughStates() {
        let m = MockCommandRunner()
        m.stubSequence("ps -axo pid=,user=,args=", [psWithBoth, psAfterQuit])
        m.stub("diskutil eject \(mount)", stdout: "ejected")

        let f = flow(m)
        var snapshots: [[EjectFlow.Step]] = []
        f.onUpdate = { snapshots.append($0) }
        _ = f.run(indexingOn: false)

        XCTAssertEqual(snapshots.first?.map(\.id),
                       ["scan", "apps", "daemons", "images", "recheck", "unmount"])
        XCTAssertTrue(snapshots.first?.allSatisfy { $0.state == .pending } ?? false)
        // Nothing is left pending or mid-flight once the run returns.
        for step in snapshots.last ?? [] {
            XCTAssertNotEqual(step.state, .pending, step.id)
            XCTAssertNotEqual(step.state, .running, step.id)
        }
    }

    // MARK: - Dissenter parsing

    /// Verbatim output from a real failed eject on this machine. The format is
    /// "dissented by PID N (path)" — not the "PID=N" form — and it is followed by a
    /// PPID line naming the parent shell.
    func testDissenterFromRealDiskutilOutput() throws {
        let out = try Fixture.text("eject_dissented", "txt")
        let msg = EjectFlow.dissenterMessage(out)
        XCTAssertEqual(msg, "被 tail（PID 12167）阻塞")
    }

    /// The parent-shell line must never be reported as the culprit — it would send
    /// the user after the wrong process.
    func testNeverReportsTheParentPPID() throws {
        let out = try Fixture.text("eject_dissented", "txt")
        let msg = try XCTUnwrap(EjectFlow.dissenterMessage(out))
        XCTAssertFalse(msg.contains("12165"), msg)
        XCTAssertFalse(msg.contains("zsh"), msg)
    }

    /// The alternate form diskutil uses in other contexts.
    func testDissenterEqualsForm() {
        let msg = EjectFlow.dissenterMessage(
            "Dissenter PID=1234 (Android Studio) status=0x0000c010 (kDAReturnBusy)")
        XCTAssertEqual(msg, "被 Android Studio（PID 1234）阻塞")
    }

    func testDissenterWithoutName() {
        XCTAssertEqual(EjectFlow.dissenterMessage("Unmount was dissented by PID 99"),
                       "被 PID 99 阻塞")
    }

    func testDissenterFallsBackToFirstLine() {
        let msg = EjectFlow.dissenterMessage("\n  Unmount failed for /Volumes/Developer\n")
        XCTAssertEqual(msg, "卸载失败：Unmount failed for /Volumes/Developer")
    }

    func testDissenterOnEmptyOutput() {
        XCTAssertNil(EjectFlow.dissenterMessage("\n \n"))
    }

    /// End-to-end through the flow, using the recorded real failure output.
    func testFlowSurfacesRealDissenter() throws {
        let m = MockCommandRunner()
        m.stub("ps -axo pid=,user=,args=", stdout: psAfterQuit)
        m.stub("diskutil eject \(mount)",
               stdout: try Fixture.text("eject_dissented", "txt"), exitCode: 1)

        guard case .aborted(let why) = flow(m).run(indexingOn: false) else {
            return XCTFail("expected .aborted")
        }
        XCTAssertEqual(why, "被 tail（PID 12167）阻塞")
    }
}
