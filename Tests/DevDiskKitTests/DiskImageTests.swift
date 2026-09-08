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

// MARK: - Flow integration

@MainActor
final class EjectWithDiskImagesTests: XCTestCase {

    private let mount = "/Volumes/Developer"
    private let psIdle = "  332 root     /System/Library/CoreServices/fseventsd"

    private func flow(_ runner: MockCommandRunner) -> EjectFlow {
        let f = EjectFlow(runner: runner, mountPoint: mount)
        f.sleep = { _ in }
        f.quitTimeout = 2
        return f
    }

    private func plist(path: String, writable: Bool, dev: String) -> Data {
        let d: [String: Any] = ["images": [[
            "image-path": path,
            "writeable": writable,
            "system-entities": [["dev-entry": dev]],
        ]]]
        return try! PropertyListSerialization.data(
            fromPropertyList: d, format: .xml, options: 0)
    }

    func testReadOnlyImageIsDetachedAndTheEjectProceeds() throws {
        let m = MockCommandRunner()
        m.stub("ps -axo pid=,user=,args=", stdout: psIdle)
        m.stub("hdiutil info -plist",
               data: plist(path: mount + "/Installers/x.dmg", writable: false,
                           dev: "/dev/disk13"))
        m.stub("hdiutil detach /dev/disk13", stdout: "detached")
        m.stub("diskutil eject \(mount)", stdout: "ejected")

        guard case .ejected = flow(m).run(indexingOn: false) else {
            return XCTFail("expected .ejected")
        }
        XCTAssertTrue(m.log.contains("hdiutil detach /dev/disk13"))
    }

    /// A writable image may hold unsaved work, so it is named and the flow stops —
    /// same rule the GUI applications follow.
    func testWritableImageStopsTheFlow() throws {
        let m = MockCommandRunner()
        m.stub("ps -axo pid=,user=,args=", stdout: psIdle)
        m.stub("hdiutil info -plist",
               data: plist(path: mount + "/scratch.dmg", writable: true,
                           dev: "/dev/disk13"))
        m.stub("diskutil eject \(mount)", stdout: "should not happen")

        guard case .aborted(let why) = flow(m).run(indexingOn: false) else {
            return XCTFail("expected .aborted")
        }
        XCTAssertTrue(why.contains("scratch.dmg"), why)
        XCTAssertFalse(m.log.contains { $0.hasPrefix("hdiutil detach") },
                       "a writable image must never be detached automatically")
        XCTAssertFalse(m.log.contains { $0.hasPrefix("diskutil eject") },
                       "must not unmount while a writable image is attached")
    }

    func testNoImagesSkipsTheStep() throws {
        let m = MockCommandRunner()
        m.stub("ps -axo pid=,user=,args=", stdout: psIdle)
        m.stub("hdiutil info -plist",
               data: try! PropertyListSerialization.data(
                fromPropertyList: ["images": []], format: .xml, options: 0))
        m.stub("diskutil eject \(mount)", stdout: "ejected")

        let f = flow(m)
        var final: [EjectFlow.Step] = []
        f.onUpdate = { final = $0 }
        guard case .ejected = f.run(indexingOn: false) else {
            return XCTFail("expected .ejected")
        }
        XCTAssertEqual(final.first { $0.id == "images" }?.state,
                       .skipped("盘上没有已挂载的磁盘映像"))
    }

    func testDetachFailureStopsTheFlow() throws {
        let m = MockCommandRunner()
        m.stub("ps -axo pid=,user=,args=", stdout: psIdle)
        m.stub("hdiutil info -plist",
               data: plist(path: mount + "/x.dmg", writable: false, dev: "/dev/disk13"))
        m.stub("hdiutil detach /dev/disk13", stdout: "busy", exitCode: 1)
        m.stub("diskutil eject \(mount)", stdout: "should not happen")

        guard case .aborted(let why) = flow(m).run(indexingOn: false) else {
            return XCTFail("expected .aborted")
        }
        XCTAssertTrue(why.contains("x.dmg"), why)
        XCTAssertFalse(m.log.contains { $0.hasPrefix("diskutil eject") })
    }
}
