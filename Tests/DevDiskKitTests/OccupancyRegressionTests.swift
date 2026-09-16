import XCTest
@testable import DevDiskKit

final class OccupancyRegressionTests: XCTestCase {
    func testRealMacOSFileDescriptorFieldsAreValid() throws {
        // Real macOS -F pcLn output shape, with an anonymized second process.
        let text = try Fixture.text("lsof_volume", "txt")
        XCTAssertTrue(Occupancy.validLsof(text))
        let sets = Occupancy.parseLsof(text)
        XCTAssertEqual(sets.map(\.pid), [37309, 37310])
        XCTAssertEqual(sets[0].files, ["/Volumes/Developer"])
        XCTAssertEqual(sets[1].files.count, 2)
    }

    func testPreflightQueriesFilesystemWithoutTraversingProtectedDirectories() throws {
        let h = FlowHarness(); h.add()
        let oldCommand = "lsof -nP +w -F pcLn +D " + FlowHarness.mount
        h.failures[oldCommand] = .init(stdout: Data(), stderr: "can't opendir(.Spotlight-V100): Permission denied", exitCode: 1)
        let plan = try h.flow.prepare()
        XCTAssertFalse(plan.incomplete)
        XCTAssertEqual(plan.daemons.count, 1)
        XCTAssertFalse(h.calls.contains(oldCommand))
        XCTAssertTrue(h.calls.contains("lsof -nP +w -F pcLfn +f -- " + FlowHarness.mount))
    }

    func testMalformedFileRecordsAndPermissionErrorsRemainIncomplete() throws {
        XCTAssertFalse(Occupancy.validLsof("p123\ncfoo\nLuser\nn/Volumes/Developer/file\n"))
        XCTAssertFalse(Occupancy.validLsof("p123\nf\nn/Volumes/Developer/file\n"))
        let h = FlowHarness(); h.add()
        h.failures["lsof -nP +w -F pcLfn +f -- " + FlowHarness.mount] = .init(
            stdout: Data("p123\ncjava\nLuser\nf3\nn\(FlowHarness.mount)/file\n".utf8),
            stderr: "Permission denied", exitCode: 1)
        let plan = try h.flow.prepare()
        XCTAssertTrue(plan.incomplete)
        XCTAssertFalse(plan.canPrepare)
    }

    func testReadOnlyRealFilesystemScanWhenExplicitlyConfigured() throws {
        guard let mount = ProcessInfo.processInfo.environment["DEVDISK_READONLY_TARGET"] else {
            throw XCTSkip("Set DEVDISK_READONLY_TARGET for a read-only filesystem scan")
        }
        // This descriptor belongs only to the test. No write, signal or eject.
        let descriptor = open(mount, O_RDONLY)
        guard descriptor >= 0 else { return XCTFail("Cannot open configured volume") }
        defer { close(descriptor) }
        let report = try Occupancy().fullScan(mountPoint: mount, indexingOn: nil)
        XCTAssertEqual(report.state, .complete, report.issues.map(\.text).joined(separator: "\n"))
        XCTAssertTrue(report.holders.contains { $0.identity?.pid == getpid() && $0.sampleFiles.contains(mount) })
    }
}
