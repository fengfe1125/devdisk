import XCTest
@testable import DevDiskKit

final class TargetTopologyTests: XCTestCase {
    private func plist(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    }
    private func fields(mount: String, device: String = "disk90s1", uuid: String = "test", external: Bool = true) -> [String: Any] {
        // Real macOS output omits Mounted; membership is supplied by the mount table.
        ["MountPoint": mount, "DeviceIdentifier": device, "VolumeUUID": uuid,
         "ParentWholeDisk": "disk90", "RemovableMediaOrExternalDevice": external, "BusProtocol": "USB"]
    }
    func testMountedKeyIsNotRequiredAndTrailingSpacesSurvive() throws {
        let mount = "/Volumes/Test  ", runner = MockCommandRunner()
        runner.stub("diskutil info -plist " + mount, data: try plist(fields(mount: mount)))
        let probe = SystemTargetInspector(mountedPaths: { [mount] })
        XCTAssertEqual(try probe.target(at: mount, runner: runner).volume.mount, mount)
    }
    func testResidualDirectoryIsRejectedBeforeDiskutil() throws {
        let runner = MockCommandRunner(), probe = SystemTargetInspector(mountedPaths: { ["/"] })
        XCTAssertThrowsError(try probe.target(at: "/private/tmp", runner: runner))
        XCTAssertTrue(runner.calls.isEmpty)
    }
    func testMultiVolumePhysicalDiskListsBothVolumes() throws {
        let runner = MockCommandRunner()
        runner.stub("diskutil info -plist /Volumes/A", data: try plist(fields(mount: "/Volumes/A")))
        runner.stub("diskutil info -plist /Volumes/B", data: try plist(fields(mount: "/Volumes/B", device: "disk90s2", uuid: "b")))
        let probe = SystemTargetInspector(mountedPaths: { ["/Volumes/A", "/Volumes/B"] })
        let target = try probe.target(at: "/Volumes/A", runner: runner)
        XCTAssertTrue(target.multipleVolumes)
        XCTAssertEqual(target.affected.map(\.device), ["disk90s1", "disk90s2"])
    }
    func testComplexAPFSAndDiskImagesAreRejected() throws {
        let runner = MockCommandRunner(), mount = "/Volumes/A"
        var data = fields(mount: mount)
        data["BusProtocol"] = "Disk Image"
        runner.stub("diskutil info -plist " + mount, data: try plist(data))
        let probe = SystemTargetInspector(mountedPaths: { [mount] })
        XCTAssertThrowsError(try probe.target(at: mount, runner: runner))
        data["BusProtocol"] = "USB"; data["APFSContainerReference"] = "disk91"
        runner.stub("diskutil info -plist " + mount, data: try plist(data))
        runner.stub("diskutil list -plist", data: try plist(["AllDisksAndPartitions": [[
            "DeviceIdentifier": "disk91",
            "APFSPhysicalStores": [["DeviceIdentifier": "disk90s1"], ["DeviceIdentifier": "disk92s1"]]
        ]]]))
        XCTAssertThrowsError(try probe.target(at: mount, runner: runner))
    }
    func testSystemVolumeOnSameDiskPreventsEject() throws {
        let runner = MockCommandRunner()
        runner.stub("diskutil info -plist /Volumes/A", data: try plist(fields(mount: "/Volumes/A")))
        runner.stub("diskutil info -plist /", data: try plist(fields(mount: "/", device: "disk90s2", external: false)))
        let probe = SystemTargetInspector(mountedPaths: { ["/", "/Volumes/A"] })
        XCTAssertThrowsError(try probe.target(at: "/Volumes/A", runner: runner))
    }
    func testUnparseableVerificationDoesNotClaimOffline() {
        let target = FakeTargetInspector().current
        let probe = SystemTargetInspector(mountedPaths: { [] })
        XCTAssertThrowsError(try probe.isEjected(target, runner: MockCommandRunner()))
        let result = probe.ejectVerification(target, runner: MockCommandRunner(), timeout: 1)
        XCTAssertEqual(result.state, .unavailable)
        XCTAssertNil(result.physicalDiskPresent)
        XCTAssertTrue(result.relatedMountsKnown)
        XCTAssertNotNil(result.issue)
    }
    func testStructuredVerificationRequiresDiskAbsentAndEveryRelatedVolumeUnmounted() throws {
        let target = FakeTargetInspector().current
        let runner = MockCommandRunner()
        runner.stub("diskutil list -plist", data: try plist(["AllDisks": ["disk0", "disk90"]]))
        let present = SystemTargetInspector(mountedPaths: { [FlowHarness.mount] })
            .ejectVerification(target, runner: runner, timeout: 1)
        XCTAssertEqual(present.state, .present)
        XCTAssertEqual(present.physicalDiskPresent, true)
        XCTAssertEqual(present.mountedVolumes, target.affected)

        runner.stub("diskutil list -plist", data: try plist(["AllDisks": ["disk0"]]))
        let residualMount = SystemTargetInspector(mountedPaths: { [FlowHarness.mount] })
            .ejectVerification(target, runner: runner, timeout: 1)
        XCTAssertEqual(residualMount.state, .present)
        XCTAssertEqual(residualMount.physicalDiskPresent, false)

        runner.stub("diskutil list -plist", data: try plist(["AllDisks": ["disk0", "disk90"]]))
        let softwareEjected = SystemTargetInspector(mountedPaths: { [] })
            .ejectVerification(target, runner: runner, timeout: 1)
        XCTAssertEqual(softwareEjected.state, .unmounted)
        XCTAssertFalse(softwareEjected.confirmedOffline)

        runner.stub("diskutil list -plist", data: try plist(["AllDisks": ["disk0"]]))
        let offline = SystemTargetInspector(mountedPaths: { [] })
            .ejectVerification(target, runner: runner, timeout: 1)
        XCTAssertEqual(offline.state, .offline)
        XCTAssertTrue(offline.confirmedOffline)
        XCTAssertTrue(offline.mountedVolumes.isEmpty)
    }
    func testUnmountedTargetUsesUUIDAndPhysicalMappingWithoutOldMountPath() throws {
        let t = FakeTargetInspector().current, runner = MockCommandRunner()
        var data = fields(mount: t.volume.mount, uuid: t.volume.uuid)
        data.removeValue(forKey: "MountPoint")
        runner.stub("diskutil info -plist disk90s1", data: try plist(data))
        let probe = SystemTargetInspector(mountedPaths: { [] })
        XCTAssertNoThrow(try probe.validateUnmounted(t, runner: runner))
        data["VolumeUUID"] = "replacement"
        runner.stub("diskutil info -plist disk90s1", data: try plist(data))
        XCTAssertThrowsError(try probe.validateUnmounted(t, runner: runner))
    }
    func testNewMountedSiblingBlocksPreviouslyConfirmedForceScope() throws {
        let t = FakeTargetInspector().current, runner = MockCommandRunner()
        runner.stub("diskutil info -plist disk90s1", data: try plist(fields(mount: t.volume.mount, uuid: t.volume.uuid)))
        runner.stub("diskutil info -plist /Volumes/New", data: try plist(fields(mount: "/Volumes/New", device: "disk90s2", uuid: "new")))
        let probe = SystemTargetInspector(mountedPaths: { ["/Volumes/New"] })
        XCTAssertThrowsError(try probe.validateUnmounted(t, runner: runner))
    }
    func testVerificationDetectsVolumeRemountedAtAnotherPath() throws {
        let target = FakeTargetInspector().current, runner = MockCommandRunner()
        runner.stub("diskutil list -plist", data: try plist(["AllDisks": ["disk0", "disk90"]]))
        runner.stub("diskutil info -plist /Volumes/Moved", data: try plist(fields(mount: "/Volumes/Moved", uuid: target.volume.uuid)))
        let probe = SystemTargetInspector(mountedPaths: { ["/Volumes/Moved"] })
        let result = probe.ejectVerification(target, runner: runner, timeout: 1)
        XCTAssertEqual(result.state, .present)
        XCTAssertEqual(result.mountedVolumes.first?.mount, "/Volumes/Moved")
    }
    func testReadOnlyRealTargetWhenExplicitlyConfigured() throws {
        guard let mount = ProcessInfo.processInfo.environment["DEVDISK_READONLY_TARGET"] else {
            throw XCTSkip("opt-in read-only hardware check")
        }
        let probe = SystemTargetInspector(), runner = SystemCommandRunner()
        let target = try probe.target(at: mount, runner: runner)
        XCTAssertEqual(target.volume.mount, mount)
        XCTAssertFalse(target.physicalDisk.isEmpty)
        XCTAssertFalse(try probe.isEjected(target, runner: runner))
    }
}
