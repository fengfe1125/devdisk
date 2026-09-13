import XCTest
@testable import DevDiskKit

final class ProbeReliabilityTests: XCTestCase {
    private func volume() -> VolumeInfo {
        .init(name: "NoSuchReviewVolume", mountPoint: "/Volumes/NoSuchReviewVolume", filesystem: "APFS", isEncrypted: true,
              isExternal: true, ownersEnabled: true, volumeUUID: "review", deviceIdentifier: "disk90s1",
              containerReference: nil, physicalDisk: "disk90", totalBytes: 100, freeBytes: 50)
    }
    func testMissingConfigDataIsUnknownNotPassing() {
        let runner = MockCommandRunner()
        let checks = ConfigProbe(runner: runner).checks(volume: volume(), health: nil)
        for id in ["timemachine", "spotlight", "disksleep"] {
            XCTAssertEqual(checks.first { $0.id == id }?.severity, .unknown)
            XCTAssertNil(checks.first { $0.id == id }?.fixCommand)
        }
    }
    func testFailedConfigCommandsDoNotTrustPlausibleOutput() {
        let runner = MockCommandRunner()
        runner.stub("tmutil isexcluded /Volumes/NoSuchReviewVolume", stdout: "[Included]", exitCode: 1)
        runner.stub("mdutil -s /Volumes/NoSuchReviewVolume", stdout: "Indexing disabled", exitCode: 1)
        runner.stub("pmset -g", stdout: "disksleep 0", exitCode: 1)
        let checks = ConfigProbe(runner: runner).checks(volume: volume(), health: nil)
        XCTAssertEqual(checks.filter { ["timemachine", "spotlight", "disksleep"].contains($0.id) && $0.severity == .unknown }.count, 3)
    }
    func testTimeMachineDoesNotPromiseBackupSuccess() {
        let runner = MockCommandRunner()
        runner.stub("tmutil isexcluded /Volumes/NoSuchReviewVolume", stdout: "[Included]")
        let check = ConfigProbe(runner: runner).checks(volume: volume(), health: nil).first { $0.id == "timemachine" }
        XCTAssertEqual(check?.title, "此卷未被整卷排除")
        XCTAssertTrue(check?.detail.contains("未验证备份") == true)
    }
    func testExFATOwnershipIsNotApplicable() {
        var v = volume(); v.filesystem = "ExFAT"; v.ownersEnabled = false
        let c = ConfigProbe(runner: MockCommandRunner()).checks(volume: v, health: nil).first { $0.id == "owners" }
        XCTAssertEqual(c?.severity, .notApplicable)
        XCTAssertNil(c?.fixCommand)
    }
    func testUUIDlessIdentityIsSessionScoped() {
        let a = VolumeIdentity(uuid: "", device: "disk90s1", session: UUID())
        let b = VolumeIdentity(uuid: "", device: "disk90s1", session: UUID())
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(VolumeIdentity(uuid: "same", device: "disk90s1", session: UUID()),
                       VolumeIdentity(uuid: "same", device: "disk92s1", session: UUID()))
    }
    func testReadOwnProcessIdentityIsStable() throws {
        let inspector = SystemProcessInspector()
        let a = try XCTUnwrap(inspector.identity(getpid()))
        XCTAssertEqual(a, try inspector.identity(getpid()))
        XCTAssertEqual(a.uid, getuid())
        XCTAssertFalse(a.executable.isEmpty)
    }
    func testCancelledCommandReturnsPromptlyAndRetainsOutput() throws {
        let token = CancellationToken()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { token.cancel() }
        let started = Date()
        let result = try SystemCommandRunner().run("/bin/sh", ["-c", "echo started; exec sleep 20"], timeout: 30, cancellation: token)
        XCTAssertTrue(result.cancelled)
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.text.contains("started"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }
    func testInheritedPipeDoesNotStrandReader() throws {
        let started = Date()
        let result = try SystemCommandRunner().run("/bin/sh", ["-c", "sleep 1 & echo done; exit 0"], timeout: 5)
        XCTAssertTrue(result.ok)
        XCTAssertTrue(result.text.contains("done"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.8)
    }
    func testPrecancelledCommandIsNeverLaunched() {
        let token = CancellationToken(); token.cancel()
        XCTAssertThrowsError(try SystemCommandRunner().run("/bin/echo", ["must not run"], timeout: 1, cancellation: token))
    }
}
