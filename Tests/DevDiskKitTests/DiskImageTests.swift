import XCTest
@testable import DevDiskKit

/// The case that made "safe eject" look broken: a `.dmg` downloaded onto the dev
/// drive had been attached, so `diskimages-helper` held the backing file and the
/// volume refused to unmount. diskutil named that helper — a launchd-owned system
/// process — as the blocker, which the user can neither kill nor act on. Both
/// attachments were *attached but not mounted*, so they had no Finder presence
/// either: nothing to eject, no way to see the cause.
final class DiskImageParsingTests: XCTestCase {

    private func fixture() throws -> Data {
        try Fixture.data("hdiutil_info", "plist")
    }

    func testFindsImagesBackedByFilesOnTheVolume() throws {
        let images = DiskImageProbe.parse(try fixture(), under: "/Volumes/Developer")
        XCTAssertEqual(images.count, 2)
        for i in images {
            XCTAssertEqual(i.name, "marvis_1.60.1910_arm64.dmg")
            XCTAssertTrue(i.path.hasPrefix("/Volumes/Developer/"))
        }
    }

    /// Read-only means no user data is at stake, so the flow may detach it itself.
    func testInstallerImageIsReadOnly() throws {
        let images = DiskImageProbe.parse(try fixture(), under: "/Volumes/Developer")
        XCTAssertTrue(images.allSatisfy { !$0.writable })
    }

    /// Attached but never mounted — invisible in Finder, which is why reporting
    /// "eject it yourself" would have been useless advice.
    func testImagesAreAttachedButNotMounted() throws {
        let images = DiskImageProbe.parse(try fixture(), under: "/Volumes/Developer")
        XCTAssertTrue(images.allSatisfy { !$0.isMounted })
    }

    func testDetachTargetsTheWholeDiskEntry() throws {
        let images = DiskImageProbe.parse(try fixture(), under: "/Volumes/Developer")
        for i in images {
            let dev = try XCTUnwrap(i.wholeDisk)
            XCTAssertNotNil(dev.range(of: #"^/dev/disk\d+$"#, options: .regularExpression),
                            "\(dev) is a partition, not the whole disk")
        }
    }

    func testImagesElsewhereAreIgnored() throws {
        let images = DiskImageProbe.parse(try fixture(), under: "/Volumes/Nothing")
        XCTAssertTrue(images.isEmpty)
    }

    /// A prefix match without the trailing slash would make "/Volumes/Dev" claim
    /// images that actually live on "/Volumes/Developer".
    func testPrefixDoesNotMatchASiblingVolume() throws {
        XCTAssertTrue(DiskImageProbe.parse(try fixture(), under: "/Volumes/Dev").isEmpty)
    }

    func testGarbageReturnsEmpty() {
        XCTAssertTrue(DiskImageProbe.parse(Data("not a plist".utf8),
                                           under: "/Volumes/Developer").isEmpty)
    }
}
