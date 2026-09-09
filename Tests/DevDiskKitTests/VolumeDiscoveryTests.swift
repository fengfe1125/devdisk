import XCTest
@testable import DevDiskKit

/// Classification is checked against three real `diskutil info` payloads recorded
/// on this machine: a USB camera card, a mounted installer .dmg, and the boot
/// volume. Getting any of them wrong shows the user the wrong thing to eject.
final class VolumeClassificationTests: XCTestCase {

    private func volume(_ fixture: String) throws -> DiscoveredVolume {
        let d = try XCTUnwrap(VolumeProbe.plist(try Fixture.data(fixture, "plist")))
        return try XCTUnwrap(VolumeDiscovery.parse(d, fallbackMountPoint: "/fallback"))
    }

    func testRealExternalDriveIsSelectable() throws {
        let v = try volume("diskutil_external_usb")
        XCTAssertTrue(v.isExternal)
        XCTAssertFalse(v.isDiskImage)
        XCTAssertFalse(v.isBoot)
        XCTAssertTrue(v.isSelectableDrive)
        XCTAssertEqual(v.busProtocol, "USB")
        XCTAssertEqual(v.filesystem, "ExFAT")
    }

    /// Volume names really do carry trailing spaces — this ExFAT camera card is
    /// literally "NIKON Z 6  ". Trimming the path anywhere makes every later
    /// diskutil call fail with a volume-not-found error.
    func testTrailingSpacesInVolumeNameArePreserved() throws {
        let v = try volume("diskutil_external_usb")
        XCTAssertEqual(v.name, "NIKON Z 6  ")
        XCTAssertEqual(v.mountPoint, "/Volumes/NIKON Z 6  ")
        XCTAssertTrue(v.mountPoint.hasSuffix("  "), "trailing spaces were lost")
    }

    /// A mounted .dmg reports RemovableMediaOrExternalDevice = true, so filtering on
    /// "external" alone would list installer images as if they were drives.
    func testMountedDiskImageIsExternalButNotADrive() throws {
        let v = try volume("diskutil_diskimage")
        XCTAssertTrue(v.isExternal, "a disk image really does report as external")
        XCTAssertTrue(v.isDiskImage)
        XCTAssertFalse(v.isSelectableDrive)
        XCTAssertEqual(v.busProtocol, "Disk Image")
    }

    func testBootVolumeIsNotADrive() throws {
        let v = try volume("diskutil_boot")
        XCTAssertTrue(v.isBoot)
        XCTAssertFalse(v.isExternal)
        XCTAssertFalse(v.isSelectableDrive)
    }

    /// The dev drive's enclosure is PCIe-tunneled: Removable and Detachable are both
    /// false, and only RemovableMediaOrExternalDevice identifies it. A filter built
    /// on the other keys would miss the drive this app is for.
    func testPCIeEnclosureCountsAsExternal() throws {
        let d = try XCTUnwrap(VolumeProbe.plist(try Fixture.data("diskutil_volume", "plist")))
        XCTAssertEqual(d["Removable"] as? Bool, false)
        XCTAssertEqual(d["RemovableMedia"] as? Bool, false)

        let v = try XCTUnwrap(VolumeDiscovery.parse(d, fallbackMountPoint: "/fallback"))
        XCTAssertTrue(v.isExternal)
        XCTAssertTrue(v.isSelectableDrive)
        XCTAssertEqual(v.busProtocol, "PCI-Express")
    }

    func testMissingMountPointIsSkipped() {
        XCTAssertNil(VolumeDiscovery.parse(["MountPoint": ""], fallbackMountPoint: ""))
    }
}

// MARK: - Auto-selection

final class VolumeChoiceTests: XCTestCase {

    private func drive(_ mount: String) -> DiscoveredVolume {
        DiscoveredVolume(mountPoint: mount, name: (mount as NSString).lastPathComponent,
                         deviceIdentifier: "disk9s1", filesystem: "APFS",
                         busProtocol: "USB", isExternal: true, isDiskImage: false,
                         isBoot: false, totalBytes: 100, freeBytes: 50)
    }

    private let dev = "/Volumes/Developer"

    /// Plugging the pinned drive back in returns to it, even when others are attached.
    func testPinnedDriveWinsWhenAttached() {
        let c = VolumeDiscovery.choose(
            drives: [drive("/Volumes/NIKON"), drive(dev)], pinned: dev)
        XCTAssertEqual(c, .pinned(dev))
    }

    /// The complaint that started this: the pinned drive was unplugged and the panel
    /// stayed blank while a camera card sat mounted.
    func testLoneOtherDriveIsShownWhenPinnedIsAbsent() {
        let c = VolumeDiscovery.choose(drives: [drive("/Volumes/NIKON")], pinned: dev)
        XCTAssertEqual(c, .only("/Volumes/NIKON"))
    }

    func testSeveralDrivesAndNoPinnedMeansPick() {
        let c = VolumeDiscovery.choose(
            drives: [drive("/Volumes/A"), drive("/Volumes/B")], pinned: dev)
        XCTAssertEqual(c, .pick)
    }

    func testNothingAttached() {
        XCTAssertEqual(VolumeDiscovery.choose(drives: [], pinned: dev), .none)
    }

    func testTrailingSpaceMountPointMatchesExactly() {
        let nikon = "/Volumes/NIKON Z 6  "
        XCTAssertEqual(VolumeDiscovery.choose(drives: [drive(nikon)], pinned: nikon),
                       .pinned(nikon))
        // The same name without its trailing spaces is a different volume.
        XCTAssertEqual(VolumeDiscovery.choose(drives: [drive(nikon)],
                                              pinned: "/Volumes/NIKON Z 6"),
                       .only(nikon))
    }
}

/// The settings field used to trim its input, which silently broke any volume whose
/// name ends in a space — and at least one real one does.
final class MountPointHandlingTests: XCTestCase {

    func testTrimmingWouldBreakARealVolumePath() {
        let real = "/Volumes/NIKON Z 6  "
        let trimmed = real.trimmingCharacters(in: .whitespaces)
        XCTAssertNotEqual(trimmed, real,
                          "if these were equal the trailing-space case would not exist")
        XCTAssertFalse(trimmed.hasSuffix("  "))
    }

    /// Discovery must compare mount points byte for byte.
    func testChoiceComparesPathsExactly() {
        let v = DiscoveredVolume(
            mountPoint: "/Volumes/NIKON Z 6  ", name: "NIKON Z 6  ",
            deviceIdentifier: "disk7s1", filesystem: "ExFAT", busProtocol: "USB",
            isExternal: true, isDiskImage: false, isBoot: false,
            totalBytes: 1, freeBytes: 1)

        XCTAssertEqual(VolumeDiscovery.choose(drives: [v], pinned: v.mountPoint),
                       .pinned(v.mountPoint))
        XCTAssertEqual(
            VolumeDiscovery.choose(drives: [v],
                                   pinned: v.mountPoint.trimmingCharacters(in: .whitespaces)),
            .only(v.mountPoint),
            "a trimmed path must not be treated as the pinned volume")
    }
}
