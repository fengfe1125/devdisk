import XCTest
@testable import DevDiskKit

@MainActor
final class StoreReliabilityTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "devdisk.tests." + UUID().uuidString
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }
    private func drive(_ name: String, uuid: String? = nil) -> DiscoveredVolume {
        .init(mountPoint: "/Volumes/" + name, name: name, deviceIdentifier: "disk90s1", filesystem: "APFS",
              busProtocol: "PCI-Express", isExternal: true, isDiskImage: false, isBoot: false,
              totalBytes: 1000, freeBytes: 500, volumeUUID: uuid ?? name)
    }
    private nonisolated static func snapshot(_ mount: String, uuid: String) -> DiskSnapshot {
        .init(volume: .init(name: uuid, mountPoint: mount, filesystem: "APFS", isEncrypted: true, isExternal: true,
              ownersEnabled: true, volumeUUID: uuid, deviceIdentifier: "disk90s1", containerReference: nil,
              physicalDisk: "disk90", totalBytes: 1000, freeBytes: 500), hardware: .init(), health: nil,
              healthUnavailableReason: nil, checks: [], directories: [], occupancy: nil)
    }
    func testLegacyPinMigratesAndFollowsRenameNotSameNameReplacement() {
        let d = defaults(); d.set("/Volumes/Original", forKey: "targetMountPoint")
        let store = DiskStore(defaults: d, start: false)
        store.applyDiscovery([drive("Original", uuid: "stable")])
        XCTAssertEqual(d.string(forKey: "targetVolumeUUID"), "stable")
        store.applyDiscovery([drive("Renamed", uuid: "stable"), drive("Original", uuid: "replacement")])
        XCTAssertEqual(store.mountPoint, "/Volumes/Renamed")
        XCTAssertEqual(d.string(forKey: "targetMountPoint"), "/Volumes/Renamed")
        store.pinnedMountPoint = "/Volumes/New  "
        XCTAssertNil(d.string(forKey: "targetVolumeUUID"))
        XCTAssertEqual(store.pinnedMountPoint, "/Volumes/New  ")
    }
    func testResidualPathDoesNotMeanMounted() {
        let d = defaults(); d.set("/private/tmp", forKey: "targetMountPoint")
        let store = DiskStore(defaults: d, start: false)
        store.applyDiscovery([])
        XCTAssertFalse(store.isMounted)
    }
    func testOldSnapshotCannotOverwriteNewSelection() async {
        let store = DiskStore(defaults: defaults(), start: false)
        let a = drive("A"), b = drive("B")
        store.applyDiscovery([a, b])
        let started = expectation(description: "A started")
        let bFinished = expectation(description: "B finished")
        let releaseA = DispatchSemaphore(value: 0)
        store.probeVolume = { mount, _ in
            if mount == a.mountPoint {
                started.fulfill()
                _ = releaseA.wait(timeout: .now() + 3)
                return .success(Self.snapshot(mount, uuid: "A"))
            }
            bFinished.fulfill()
            return .success(Self.snapshot(mount, uuid: "B"))
        }
        store.select(a)
        await fulfillment(of: [started], timeout: 2)
        store.select(b)
        releaseA.signal()
        await fulfillment(of: [bFinished], timeout: 2)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(store.mountPoint, b.mountPoint)
        XCTAssertEqual(store.snapshot?.volume.volumeUUID, "B")
        XCTAssertNil(store.lastError)
    }
    func testOldDirectoryResultCannotOverwriteNewSelection() async {
        let d = defaults(); d.set(true, forKey: PanelSetting.breakdownOpen)
        let store = DiskStore(defaults: d, start: false)
        let a = drive("A"), b = drive("B")
        store.applyDiscovery([a, b])
        store.probeVolume = { mount, _ in .success(Self.snapshot(mount, uuid: (mount as NSString).lastPathComponent)) }
        let started = expectation(description: "directory A")
        let finished = expectation(description: "directory B")
        let release = DispatchSemaphore(value: 0)
        store.directoryUsage = { mount, _ in
            if mount == a.mountPoint { started.fulfill(); _ = release.wait(timeout: .now() + 3) }
            else { finished.fulfill() }
            return [.init(name: (mount as NSString).lastPathComponent, bytes: 12)]
        }
        store.select(a)
        await fulfillment(of: [started], timeout: 2)
        store.select(b); release.signal()
        await fulfillment(of: [finished], timeout: 2)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(store.directories.map(\.name), ["B"])
        XCTAssertFalse(store.directoriesLoading)
    }
    func testHiddenDirectoriesNeverWalk() async {
        let store = DiskStore(defaults: defaults(), start: false)
        let a = drive("A")
        store.applyDiscovery([a])
        let finished = expectation(description: "probe")
        store.probeVolume = { mount, _ in finished.fulfill(); return .success(Self.snapshot(mount, uuid: "A")) }
        store.directoryUsage = { _, _ in XCTFail("hidden section must not walk"); return [] }
        store.select(a)
        await fulfillment(of: [finished], timeout: 2)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(store.directoriesLoading)
    }
    func testOperationLockSurvivesNavigationAndDuplicateEject() async {
        let h = FlowHarness(); h.add()
        let store = DiskStore(runner: h, defaults: defaults(), start: false)
        let disk = drive("ReviewDisk", uuid: "review-uuid")
        store.applyDiscovery([disk])
        let blocked = DispatchSemaphore(value: 0)
        let entered = expectation(description: "preflight entered")
        var first = true
        h.targetInspector.beforeRead = {
            if first { first = false; entered.fulfill(); _ = blocked.wait(timeout: .now() + 3) }
        }
        store.makeFlow = { _, _, token in h.cancellation = token; return h.flow }
        store.eject()
        await fulfillment(of: [entered], timeout: 2)
        store.screen = .settings
        store.eject()
        store.select(drive("Other"))
        XCTAssertEqual(store.operation, .preflight)
        XCTAssertEqual(store.activeScreen, .ejecting)
        XCTAssertEqual(store.mountPoint, FlowHarness.mount)
        store.cancelEject()
        XCTAssertEqual(store.operation, .cancelling)
        blocked.signal()
        for _ in 0..<100 { try? await Task.sleep(nanoseconds: 1_000_000); if store.operation == .finished { break } }
        XCTAssertEqual(store.operation, .finished)
        XCTAssertFalse(h.calls.contains { $0.hasPrefix("kill") || $0.hasPrefix("diskutil eject") })
    }
}
