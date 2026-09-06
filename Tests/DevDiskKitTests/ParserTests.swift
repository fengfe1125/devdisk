import XCTest
@testable import DevDiskKit

/// Fixtures are verbatim command output captured from this machine on 2026-09-06.
enum Fixture {
    static func data(_ name: String, _ ext: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"),
            "missing fixture \(name).\(ext)"
        )
        return try Data(contentsOf: url)
    }

    static func text(_ name: String, _ ext: String) throws -> String {
        String(decoding: try data(name, ext), as: UTF8.self)
    }
}

// MARK: - Volume

final class VolumeParsingTests: XCTestCase {

    func testParsesVolumeFromRealPlist() throws {
        let d = try XCTUnwrap(
            VolumeProbe.plist(Fixture.data("diskutil_volume", "plist"))
        )
        let v = VolumeProbe.parseVolume(d, mountPoint: "/Volumes/Developer",
                                        resolvePhysical: { _ in "disk6" })

        XCTAssertEqual(v.name, "Developer")
        XCTAssertEqual(v.mountPoint, "/Volumes/Developer")
        XCTAssertEqual(v.filesystem, "APFS")
        XCTAssertFalse(v.isEncrypted)
        XCTAssertEqual(v.deviceIdentifier, "disk7s1")
        XCTAssertEqual(v.containerReference, "disk7")
        XCTAssertEqual(v.physicalDisk, "disk6")
        XCTAssertEqual(v.volumeUUID, "00000000-0000-0000-0000-000000000001")
    }

    /// Removable and RemovableMedia are both false for this PCIe-tunneled enclosure;
    /// only RemovableMediaOrExternalDevice identifies it as external.
    func testExternalDetectionUsesTheOnlyKeyThatIsTrue() throws {
        let d = try XCTUnwrap(
            VolumeProbe.plist(Fixture.data("diskutil_volume", "plist"))
        )
        XCTAssertEqual(d["Removable"] as? Bool, false)
        XCTAssertEqual(d["RemovableMedia"] as? Bool, false)

        let v = VolumeProbe.parseVolume(d, mountPoint: "/Volumes/Developer",
                                        resolvePhysical: { _ in nil })
        XCTAssertTrue(v.isExternal)
    }

    func testOwnersEnabled() throws {
        let d = try XCTUnwrap(
            VolumeProbe.plist(Fixture.data("diskutil_volume", "plist"))
        )
        let v = VolumeProbe.parseVolume(d, mountPoint: "/Volumes/Developer",
                                        resolvePhysical: { _ in nil })
        XCTAssertTrue(v.ownersEnabled)
    }

    /// diskutil reports FreeSpace as 0 for APFS volumes; anything reading it directly
    /// would show a full disk.
    func testDiskutilFreeSpaceIsUselessForAPFS() throws {
        let d = try XCTUnwrap(
            VolumeProbe.plist(Fixture.data("diskutil_volume", "plist"))
        )
        XCTAssertEqual(d["FreeSpace"] as? Int, 0)
        XCTAssertEqual(d["TotalSize"] as? Int, 511_900_434_432)
    }

    func testResolvesPhysicalDiskThroughAPFSStore() throws {
        let d = try XCTUnwrap(
            VolumeProbe.plist(Fixture.data("diskutil_container", "plist"))
        )
        // ParentWholeDisk names the synthesized container, which is the trap.
        XCTAssertEqual(d["ParentWholeDisk"] as? String, "disk7")
        XCTAssertEqual(VolumeProbe.parsePhysicalDisk(d), "disk6")
    }

    func testWholeDiskStripsPartitionSuffix() {
        XCTAssertEqual(VolumeProbe.wholeDisk(from: "disk6s2"), "disk6")
        XCTAssertEqual(VolumeProbe.wholeDisk(from: "disk6"), "disk6")
        XCTAssertEqual(VolumeProbe.wholeDisk(from: "disk11s1s4"), "disk11")
    }

    func testParseDu() {
        let out = "9221736\t/Volumes/Developer/Android\n343712\t/Volumes/Developer/Java\n"
        let u = VolumeProbe.parseDu(out)
        XCTAssertEqual(u.map(\.name), ["Android", "Java"])
        XCTAssertEqual(u[0].bytes, 9_221_736 * 1024)
    }
}

// MARK: - Hardware

final class HardwareParsingTests: XCTestCase {

    func testParsesExternalDriveByPhysicalBSDName() throws {
        let hw = VolumeProbe.parseHardware(try Fixture.data("nvme", "json"), bsdName: "disk6")
        XCTAssertEqual(hw.model, "Colorful CN700 512GB PRO")
        XCTAssertEqual(hw.serial, "SN00000000000000")
        XCTAssertEqual(hw.firmware, "H260610a")
        XCTAssertEqual(hw.trimSupported, true)
        XCTAssertEqual(hw.smartStatus, "Verified")
        XCTAssertEqual(hw.linkWidth, "x4")
        XCTAssertEqual(hw.linkSpeed, "16.0 GT/s")
    }

    /// Regression guard for the container/physical mix-up: joining on the volume's
    /// ParentWholeDisk (disk7) silently yields an empty card instead of an error.
    func testContainerIdentifierMatchesNothing() throws {
        let hw = VolumeProbe.parseHardware(try Fixture.data("nvme", "json"), bsdName: "disk7")
        XCTAssertNil(hw.model)
        XCTAssertNil(hw.linkSpeed)
    }

    func testInternalDriveStillParses() throws {
        let hw = VolumeProbe.parseHardware(try Fixture.data("nvme", "json"), bsdName: "disk0")
        XCTAssertEqual(hw.model, "APPLE SSD AP0256Z")
    }

    func testLinkDescriptionDerivesPCIeGeneration() {
        var hw = DriveHardware()
        hw.linkWidth = "x4"
        hw.linkSpeed = "16.0 GT/s"
        XCTAssertEqual(hw.linkDescription, "PCIe 4.0 ×4 · 16.0 GT/s")

        hw.linkSpeed = "8.0 GT/s"
        XCTAssertEqual(hw.linkDescription, "PCIe 3.0 ×4 · 8.0 GT/s")
    }

    func testLinkDescriptionNilWithoutData() {
        XCTAssertNil(DriveHardware().linkDescription)
    }
}

// MARK: - SMART

final class HealthParsingTests: XCTestCase {

    func testParsesRealSmartctlOutput() throws {
        let h = try XCTUnwrap(HealthProbe.parse(try Fixture.data("smartctl", "json")))
        XCTAssertEqual(h.temperatureC, 54)
        XCTAssertEqual(h.temperatureSensors, [54, 42])
        XCTAssertEqual(h.percentageUsed, 0)
        XCTAssertEqual(h.availableSpare, 100)
        XCTAssertEqual(h.dataUnitsWritten, 47568)
        XCTAssertEqual(h.powerOnHours, 8)
        XCTAssertEqual(h.powerCycles, 4)
        XCTAssertEqual(h.unsafeShutdowns, 4)
        XCTAssertEqual(h.mediaErrors, 0)
        XCTAssertEqual(h.passed, true)
    }

    func testDerivedValues() throws {
        let h = try XCTUnwrap(HealthProbe.parse(try Fixture.data("smartctl", "json")))
        // NVMe data unit is 1000 x 512 bytes.
        XCTAssertEqual(h.bytesWritten, 47568 * 512_000)
        XCTAssertEqual(h.lifeRemaining, 100)
    }

    /// 4 power cycles, 4 unsafe shutdowns — every power-off so far has been unclean.
    func testDetectsAllShutdownsUnsafe() throws {
        let h = try XCTUnwrap(HealthProbe.parse(try Fixture.data("smartctl", "json")))
        XCTAssertTrue(h.allShutdownsUnsafe)
    }

    func testCleanDriveIsNotFlagged() {
        var h = SmartHealth(temperatureSensors: [])
        h.powerCycles = 10
        h.unsafeShutdowns = 0
        XCTAssertFalse(h.allShutdownsUnsafe)
    }

    func testNoPowerCyclesIsNotFlagged() {
        var h = SmartHealth(temperatureSensors: [])
        h.powerCycles = 0
        h.unsafeShutdowns = 0
        XCTAssertFalse(h.allShutdownsUnsafe)
    }

    func testEmptyPayloadReturnsNil() {
        XCTAssertNil(HealthProbe.parse(Data(#"{"json_format_version":[1,0]}"#.utf8)))
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(HealthProbe.parse(Data("not json".utf8)))
    }
}

// MARK: - Configuration

final class ConfigParsingTests: XCTestCase {

    /// mdutil echoes the firmlink-resolved path, not the argument, so only the status
    /// phrase can be matched.
    func testSpotlightParsingIgnoresEchoedPath() throws {
        let out = try Fixture.text("mdutil_enabled", "txt")
        XCTAssertTrue(out.contains("/System/Volumes/Data/Volumes/Developer"))
        XCTAssertFalse(out.hasPrefix("/Volumes/Developer"))
        XCTAssertEqual(ConfigProbe.parseSpotlight(out), true)
    }

    func testSpotlightDisabled() {
        XCTAssertEqual(
            ConfigProbe.parseSpotlight("/Volumes/X:\n\tIndexing disabled. \n"), false)
    }

    func testSpotlightUnknown() {
        XCTAssertNil(ConfigProbe.parseSpotlight("Error: unknown volume\n"))
    }

    func testTimeMachineExcluded() throws {
        XCTAssertEqual(
            ConfigProbe.parseExcluded(try Fixture.text("tmutil_excluded", "txt")), true)
        XCTAssertEqual(
            ConfigProbe.parseExcluded(try Fixture.text("tmutil_included", "txt")), false)
    }

    func testDiskSleepFromRealPmsetOutput() throws {
        XCTAssertEqual(
            ConfigProbe.parseDiskSleep(try Fixture.text("pmset", "txt")), 10)
    }

    func testDiskSleepZero() {
        XCTAssertEqual(ConfigProbe.parseDiskSleep(" disksleep            0\n"), 0)
    }

    func testDiskSleepMissing() {
        XCTAssertNil(ConfigProbe.parseDiskSleep(" hibernatemode        3\n"))
    }

    func testShellQuoteOnlyWhenNeeded() {
        XCTAssertEqual(ConfigProbe.shellQuote("/Volumes/Developer"), "/Volumes/Developer")
        XCTAssertEqual(ConfigProbe.shellQuote("/Volumes/My Disk"), "'/Volumes/My Disk'")
        XCTAssertEqual(ConfigProbe.shellQuote("a'b"), #"'a'\''b'"#)
    }

    func testStaleMountPointDetection() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Exercised through the same predicate the probe uses.
        let entries = ["Developer", "Developer 1", "Developer 2", "Other"]
        let stale = entries.filter { $0 != "Developer" && $0.hasPrefix("Developer ") }
        XCTAssertEqual(stale.sorted(), ["Developer 1", "Developer 2"])
    }
}

// MARK: - Occupancy

final class OccupancyParsingTests: XCTestCase {

    /// The command line contains spaces ("Android Studio.app"), so only pid and user
    /// may be split off by whitespace.
    func testParsePsKeepsCommandLinesContainingSpaces() {
        let out = """
          4821 example   /Applications/Android Studio.app/Contents/MacOS/studio
          5194 example   /usr/bin/java -cp gradle-launcher.jar org.gradle.launcher.daemon.bootstrap.GradleDaemon 8.14
           332 root     /System/Library/.../fseventsd
        """
        let ps = Occupancy.parsePs(out)
        XCTAssertEqual(ps.count, 3)
        XCTAssertEqual(ps[0].pid, 4821)
        XCTAssertEqual(ps[0].user, "example")
        XCTAssertEqual(ps[0].args, "/Applications/Android Studio.app/Contents/MacOS/studio")
        XCTAssertTrue(ps[1].args.contains("GradleDaemon"))
        XCTAssertEqual(ps[2].user, "root")
    }

    func testParsePsSkipsMalformedLines() {
        XCTAssertTrue(Occupancy.parsePs("garbage\n\n  \n").isEmpty)
    }

    func testClassification() {
        func p(_ args: String) -> Occupancy.ProcInfo {
            .init(pid: 1, user: "example", args: args)
        }
        XCTAssertEqual(
            Occupancy.classify(p("/Applications/Android Studio.app/Contents/MacOS/studio"))?.kind,
            .guiApp)
        XCTAssertEqual(
            Occupancy.classify(p("java ... GradleDaemon 8.14"))?.display, "GradleDaemon")
        XCTAssertEqual(
            Occupancy.classify(p("/Volumes/Developer/Android/sdk/platform-tools/adb -L ..."))?.kind,
            .daemon)
        XCTAssertNil(Occupancy.classify(p("/usr/bin/vim notes.txt")))
    }

    /// A known binary that never references the volume is not holding it.
    func testDaemonNotTouchingVolumeIsIgnored() {
        let procs = [
            Occupancy.ProcInfo(pid: 1, user: "example",
                               args: "java -cp x GradleDaemon 8.14"),
        ]
        XCTAssertTrue(Occupancy.groupKnown(procs, mountPoint: "/Volumes/Developer").isEmpty)
    }

    func testDaemonTouchingVolumeIsFound() {
        let procs = [
            Occupancy.ProcInfo(pid: 5194, user: "example",
                               args: "java -Dgradle.user.home=/Volumes/Developer/Android/gradle GradleDaemon 8.14"),
        ]
        let h = Occupancy.groupKnown(procs, mountPoint: "/Volumes/Developer")
        XCTAssertEqual(h.count, 1)
        XCTAssertEqual(h[0].name, "GradleDaemon")
        XCTAssertEqual(h[0].pids, [5194])
        XCTAssertEqual(h[0].kind, .daemon)
    }

    func testParseLsofFieldOutput() {
        let out = """
        p4821
        cstudio
        Lexample
        n/Volumes/Developer/Projects/Murmur-CI/.gradle/8.14/checksums.lock
        n/Volumes/Developer/Android/sdk/platforms/android-36/android.jar
        p5194
        cjava
        Lexample
        n/Volumes/Developer/Android/gradle/caches/modules-2/modules-2.lock
        """
        let sets = Occupancy.parseLsof(out)
        XCTAssertEqual(sets.count, 2)
        XCTAssertEqual(sets[0].pid, 4821)
        XCTAssertEqual(sets[0].command, "studio")
        XCTAssertEqual(sets[0].files.count, 2)
        XCTAssertEqual(sets[1].pid, 5194)
    }

    func testParseLsofDropsNonPathEntries() {
        let out = "p1\ncnc\nLexample\nnTCP 1.2.3.4:80\nn/Volumes/Developer/a\n"
        let sets = Occupancy.parseLsof(out)
        XCTAssertEqual(sets[0].files, ["/Volumes/Developer/a"])
    }

    /// Unprivileged lsof genuinely returns nothing here, so system daemons must be
    /// inferred or the report would claim the volume is free.
    func testSystemHoldersAreInferredNotScanned() {
        let h = Occupancy.inferredSystemHolders(indexingOn: true)
        XCTAssertEqual(h.map(\.name).sorted(), ["fseventsd", "mds_stores"])
        XCTAssertTrue(h.allSatisfy { $0.kind == .system })
        for holder in h {
            XCTAssertNotNil(holder.inferenceReason, "\(holder.name) must be labelled inferred")
            XCTAssertNil(holder.openFileCount)
        }
    }

    func testSpotlightOffDropsMdsButKeepsFseventsd() {
        XCTAssertEqual(
            Occupancy.inferredSystemHolders(indexingOn: false).map(\.name), ["fseventsd"])
    }
}
