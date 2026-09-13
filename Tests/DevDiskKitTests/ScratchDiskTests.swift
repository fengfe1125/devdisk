import XCTest
@testable import DevDiskKit

final class ScratchDiskTests: XCTestCase {
    /// Opt-in integration test. Only the image created here may be unmounted.
    func testScratchImageOccupancyRefusalAndSuccessfulEject() throws {
        guard ProcessInfo.processInfo.environment["DEVDISK_SCRATCH_TEST"] == "1" else {
            throw XCTSkip("opt-in disposable disk-image test")
        }
        let runner = SystemCommandRunner()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("devdisk-scratch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("scratch.dmg").path
        let label = "DevDisk-Test-" + String(UUID().uuidString.prefix(8))
        try runner.run(Tool.hdiutil, ["create", "-size", "32m", "-fs", "HFS+", "-volname", label, image], timeout: 30).requireSuccess("create scratch image")
        let attached = try runner.run(Tool.hdiutil, ["attach", "-nobrowse", "-plist", image], timeout: 30)
        try attached.requireSuccess("attach scratch image")
        let root = try XCTUnwrap(VolumeProbe.plist(attached.stdout))
        let entities = try XCTUnwrap(root["system-entities"] as? [[String: Any]])
        let mount = try XCTUnwrap(entities.compactMap { $0["mount-point"] as? String }.first)
        let disk = try XCTUnwrap(entities.compactMap { $0["dev-entry"] as? String }.first { $0.range(of: #"^/dev/disk\d+$"#, options: .regularExpression) != nil })
        defer { _ = try? runner.run(Tool.hdiutil, ["detach", disk], timeout: 15) }
        XCTAssertEqual((mount as NSString).lastPathComponent, label)
        // Production preflight must never auto-accept even this controlled image as hardware.
        XCTAssertThrowsError(try SystemTargetInspector().target(at: mount, runner: runner))
        let file = URL(fileURLWithPath: mount).appendingPathComponent("held.txt")
        try Data("fixture\n".utf8).write(to: file)
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        holder.arguments = ["-f", file.path]
        holder.standardOutput = FileHandle.nullDevice
        holder.standardError = FileHandle.nullDevice
        try holder.run()
        defer { if holder.isRunning { holder.terminate() } }
        var found = false
        for _ in 0..<10 {
            let report = try Occupancy(runner: runner).fullScan(mountPoint: mount, indexingOn: nil)
            if report.holders.contains(where: { $0.pids.contains(holder.processIdentifier) }) { found = true; break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(found, "must find the controlled file handle")
        let refused = try runner.run(Tool.diskutil, ["eject", disk], timeout: 15)
        XCTAssertFalse(refused.ok)
        XCTAssertNotNil(EjectFlow.dissenterMessage(refused.text + refused.stderr))
        holder.terminate()
        let end = Date().addingTimeInterval(3)
        while holder.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertFalse(holder.isRunning)
        let ejected = try runner.run(Tool.diskutil, ["eject", disk], timeout: 15)
        XCTAssertTrue(ejected.ok, ejected.stderr)
        let target = EjectTarget(volume: .init(name: label, mount: mount, device: disk, uuid: "scratch"),
                                 physicalDisk: String(disk.dropFirst(5)),
                                 affected: [.init(name: label, mount: mount, device: disk, uuid: "scratch")])
        XCTAssertTrue(try SystemTargetInspector().isEjected(target, runner: runner))
    }
}
