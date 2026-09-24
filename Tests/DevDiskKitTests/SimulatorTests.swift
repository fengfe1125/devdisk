import XCTest
@testable import DevDiskKit

final class SimulatorTests: XCTestCase {
    private let devicesJSON = #"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-18-4":[{"udid":"00000000-0000-0000-0000-000000000001","name":"iPhone Review","state":"Booted","dataPath":"/Volumes/Developer/Applications/CoreSimulatorData/Devices/0001/data"}]}}"#
    private let runtimesJSON = #"{"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-18-4","bundlePath":"/Volumes/Developer/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 18.4.simruntime"}]}"#

    func testParsesBootedDeviceAndRuntimeStorage() throws {
        let devices = try SystemSimulatorInspector.parse(devices: Data(devicesJSON.utf8),
                                                         runtimes: Data(runtimesJSON.utf8))
        let device = try XCTUnwrap(devices.first)
        XCTAssertEqual(device.name, "iPhone Review")
        XCTAssertTrue(device.needsShutdown)
        XCTAssertEqual(device.dataPath, "/Volumes/Developer/Applications/CoreSimulatorData/Devices/0001/data")
        XCTAssertTrue(SimulatorScope.isRelated(device, to: ["/Volumes/Developer"]))
        XCTAssertFalse(SimulatorScope.isRelated(device, to: ["/Volumes/Develop"]))
    }

    func testBootedDeviceWithoutVerifiableStorageIsRejected() {
        let input = #"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-18-4":[{"udid":"device-1","name":"iPhone Review","state":"Booted"}]}}"#
        XCTAssertThrowsError(try SystemSimulatorInspector.parse(devices: Data(input.utf8),
                                                                  runtimes: Data(runtimesJSON.utf8)))
    }

    func testNormalShutdownUsesOnlyTheSelectedDeviceID() throws {
        let runner = MockCommandRunner()
        let device = SimulatorDevice(udid: "device-1", name: "iPhone Review",
                                     runtimeIdentifier: "runtime", state: "Booted",
                                     dataPath: "/Volumes/Developer/device", runtimePath: "/Volumes/Developer/runtime")
        try SystemSimulatorInspector().shutdown(device, runner: runner)
        XCTAssertEqual(runner.log, ["xcrun simctl shutdown device-1"])
        XCTAssertFalse(runner.log.contains { $0.contains("shutdown all") })
    }
}

final class SimulatorEjectSafetyTests: XCTestCase {
    private func device(_ id: String = "device-1", state: String = "Booted",
                        dataPath: String? = nil, runtimePath: String? = nil) -> SimulatorDevice {
        .init(udid: id, name: "iPhone \(id)", runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-4",
              state: state,
              dataPath: dataPath ?? FlowHarness.mount + "/Applications/CoreSimulatorData/Devices/\(id)/data",
              runtimePath: runtimePath ?? FlowHarness.mount + "/Applications/Xcode.app/Runtime.simruntime")
    }

    private func relatedImage() -> DiskImage {
        .init(path: FlowHarness.mount + "/Applications/CoreSimulatorData/CoreSimulatorStore-review.sparseimage",
              writable: true, devEntries: ["/dev/disk91"], mountPoints: [])
    }

    func testRelatedSimulatorShutsDownBeforeItsImageAndDisk() throws {
        let h = FlowHarness()
        h.images = [relatedImage()]
        h.simulatorInspector.live = [device()]
        h.simulatorInspector.onShutdown = { h.calls.append("simctl shutdown " + $0.udid) }
        let flow = h.flow
        let plan = try flow.prepare()
        XCTAssertEqual(plan.simulators.map(\.udid), ["device-1"])
        XCTAssertTrue(plan.canPrepare)
        XCTAssertFalse(plan.canSystemOnly)
        XCTAssertTrue(h.simulatorInspector.shutdowns.isEmpty)

        guard case .ejected = flow.execute(plan, mode: .prepared) else { return XCTFail("confirmed shutdown and eject should finish") }
        let shutdown = try XCTUnwrap(h.calls.firstIndex(of: "simctl shutdown device-1"))
        let detach = try XCTUnwrap(h.calls.firstIndex(of: "hdiutil detach /dev/disk91"))
        let eject = try XCTUnwrap(h.calls.firstIndex(of: "diskutil eject disk90"))
        XCTAssertLessThan(shutdown, detach)
        XCTAssertLessThan(detach, eject)
        guard case .done = try XCTUnwrap(flow.steps.first(where: { $0.id == "simulators" })).state else {
            return XCTFail("simulator shutdown progress should complete before eject")
        }
    }

    func testUnrelatedSimulatorIsNotShutdown() throws {
        let h = FlowHarness()
        h.simulatorInspector.live = [device(dataPath: "/Users/review/Library/Developer/CoreSimulator/Devices/device-1/data",
                                            runtimePath: "/Applications/Xcode.app/Runtime.simruntime")]
        let plan = try h.flow.prepare()
        XCTAssertTrue(plan.simulators.isEmpty)
        XCTAssertTrue(plan.canSystemOnly)
        guard case .ejected = h.flow.execute(plan, mode: .prepared) else { return XCTFail("unrelated device should not block") }
        XCTAssertTrue(h.simulatorInspector.shutdowns.isEmpty)
    }

    func testUnknownInventoryBlocksEveryEjectRoute() throws {
        let h = FlowHarness()
        h.simulatorInspector.failList = true
        let flow = h.flow
        let plan = try flow.prepare()
        XCTAssertTrue(plan.incomplete)
        XCTAssertFalse(plan.canPrepare)
        XCTAssertFalse(plan.canSystemOnly)
        XCTAssertFalse(plan.canForce)
        guard case .aborted = flow.execute(plan, mode: .systemOnly) else { return XCTFail("system-only must fail closed") }
        XCTAssertFalse(h.calls.contains { $0.hasPrefix("hdiutil detach") || $0.hasPrefix("diskutil eject") })
    }

    func testSystemOnlyRefreshStopsIfSimulatorStartsAfterPreview() throws {
        let h = FlowHarness()
        let flow = h.flow
        let plan = try flow.prepare()
        XCTAssertTrue(plan.canSystemOnly)

        h.simulatorInspector.live = [device()]
        guard case .preview(let refreshed) = flow.execute(plan, mode: .systemOnly) else {
            return XCTFail("a newly booted simulator must return for review")
        }
        XCTAssertEqual(refreshed.simulators.map(\.udid), ["device-1"])
        XCTAssertFalse(refreshed.canSystemOnly)
        XCTAssertFalse(h.calls.contains { $0.hasPrefix("diskutil eject") })
    }

    func testSystemOnlyRefreshStopsIfSimulatorInventoryBecomesUnknown() throws {
        let h = FlowHarness()
        let flow = h.flow
        let plan = try flow.prepare()
        XCTAssertTrue(plan.canSystemOnly)

        h.simulatorInspector.failList = true
        guard case .preview(let refreshed) = flow.execute(plan, mode: .systemOnly) else {
            return XCTFail("an unknown simulator inventory must return for review")
        }
        XCTAssertFalse(refreshed.simulatorsKnown)
        XCTAssertFalse(refreshed.canSystemOnly)
        XCTAssertFalse(h.calls.contains { $0.hasPrefix("diskutil eject") })
    }

    func testNewSimulatorImmediatelyBeforeDiskEjectStopsTheRequest() throws {
        let h = FlowHarness()
        let flow = h.flow
        let plan = try flow.prepare()
        var inventoryReads = 0
        h.simulatorInspector.onList = {
            inventoryReads += 1
            // Execution performs an initial refresh and a final occupancy scan;
            // the next read is the just-before-eject safety check.
            if inventoryReads == 3 { h.simulatorInspector.live = [self.device()] }
        }

        guard case .preview(let refreshed) = flow.execute(plan, mode: .prepared) else {
            return XCTFail("a simulator starting at the eject boundary must stop the request")
        }
        XCTAssertEqual(refreshed.simulators.map(\.udid), ["device-1"])
        XCTAssertFalse(h.calls.contains { $0.hasPrefix("diskutil eject") })
    }

    func testUnknownImageInventoryMakesSimulatorScopeIncomplete() throws {
        let h = FlowHarness()
        h.failures["hdiutil info -plist"] = .init(stdout: Data(), stderr: "permission denied", exitCode: 1)

        let plan = try h.flow.prepare()
        XCTAssertTrue(plan.incomplete)
        XCTAssertFalse(plan.simulatorsKnown)
        XCTAssertFalse(plan.canSystemOnly)
    }

    func testForceCannotBypassActiveRelatedSimulator() throws {
        let h = FlowHarness()
        h.images = [relatedImage()]
        h.simulatorInspector.live = [device()]
        let image = relatedImage()
        let failure = EjectFailure(target: h.targetInspector.current, stage: "images",
                                   message: "image busy", commandOutput: "image busy",
                                   blockingPID: nil, completedApps: 0, completedProcesses: 0,
                                   completedImages: 0, allowsForce: true, relatedImages: [image])
        let flow = h.flow
        guard case .preview(let plan) = flow.prepareForce(failure) else { return XCTFail("force preview") }
        XCTAssertTrue(plan.forceConfirmation)
        XCTAssertFalse(plan.canForce)
        guard case .aborted = flow.execute(plan, mode: .force) else { return XCTFail("force must not bypass active simulator") }
        XCTAssertFalse(h.calls.contains { $0.contains("force") || $0.hasPrefix("hdiutil detach") || $0.hasPrefix("diskutil eject") })
    }

    func testRefusedShutdownStopsBeforeDetachingOrEjecting() throws {
        let h = FlowHarness()
        h.images = [relatedImage()]
        h.simulatorInspector.live = [device()]
        h.simulatorInspector.refuseShutdown = true
        guard case .preview(let plan) = h.flow.run(indexingOn: nil) else { return XCTFail("active simulator needs confirmation") }
        let flow = h.flow
        guard case .aborted = flow.execute(plan, mode: .prepared) else { return XCTFail("refused shutdown must abort") }
        XCTAssertFalse(h.calls.contains { $0.hasPrefix("hdiutil detach") || $0.hasPrefix("diskutil eject") })
        guard case .failed = try XCTUnwrap(flow.steps.first(where: { $0.id == "simulators" })).state else {
            return XCTFail("shutdown failure should be visible in progress")
        }
    }

    func testShutdownTimeoutStopsBeforeDetachingOrEjecting() throws {
        let h = FlowHarness()
        h.images = [relatedImage()]
        h.simulatorInspector.live = [device()]
        h.simulatorInspector.shutdownCompletes = false
        let flow = h.flow
        guard case .preview(let plan) = flow.run(indexingOn: nil) else { return XCTFail("active simulator needs confirmation") }
        guard case .aborted = flow.execute(plan, mode: .prepared) else { return XCTFail("unverified shutdown must abort") }
        XCTAssertFalse(h.calls.contains { $0.hasPrefix("hdiutil detach") || $0.hasPrefix("diskutil eject") })
    }

    func testNewBootedSimulatorReturnsForFreshConfirmation() throws {
        let h = FlowHarness()
        h.images = [relatedImage()]
        h.simulatorInspector.live = [device()]
        h.simulatorInspector.onShutdown = { [weak inspector = h.simulatorInspector] _ in
            inspector?.live.append(self.device("device-2"))
        }
        let flow = h.flow
        guard case .preview(let plan) = flow.run(indexingOn: nil) else { return XCTFail("active simulator needs confirmation") }
        guard case .preview(let updated) = flow.execute(plan, mode: .prepared) else { return XCTFail("new device requires confirmation") }
        XCTAssertEqual(updated.simulators.map(\.udid), ["device-2"])
        XCTAssertFalse(h.calls.contains { $0.hasPrefix("hdiutil detach") || $0.hasPrefix("diskutil eject") })
    }

    func testTargetChangeDuringShutdownStopsBeforeImageDetach() throws {
        let h = FlowHarness()
        h.images = [relatedImage()]
        h.simulatorInspector.live = [device()]
        h.simulatorInspector.onShutdown = { _ in
            let old = h.targetInspector.current
            let replacement = TargetVolume(name: old.volume.name, mount: old.volume.mount,
                                           device: old.volume.device, uuid: "replacement-uuid")
            h.targetInspector.current = EjectTarget(volume: replacement, physicalDisk: old.physicalDisk,
                                                     affected: old.affected)
        }
        let flow = h.flow
        guard case .preview(let plan) = flow.run(indexingOn: nil) else { return XCTFail("active simulator needs confirmation") }
        guard case .preview = flow.execute(plan, mode: .prepared) else { return XCTFail("changed target must return for review") }
        XCTAssertFalse(h.calls.contains { $0.hasPrefix("hdiutil detach") || $0.hasPrefix("diskutil eject") })
    }

    func testSimulatorDisappearingBeforeShutdownIsNotTreatedAsShutdown() throws {
        let h = FlowHarness()
        h.images = [relatedImage()]
        h.simulatorInspector.live = [device()]
        let flow = h.flow
        guard case .preview(let plan) = flow.run(indexingOn: nil) else { return XCTFail("active simulator needs confirmation") }
        var reads = 0
        h.simulatorInspector.onList = {
            reads += 1
            // Keep it active in the execution refresh, then remove it before the
            // per-device state check. Missing inventory must fail closed.
            if reads == 2 { h.simulatorInspector.live.removeAll() }
        }

        guard case .aborted = flow.execute(plan, mode: .prepared) else {
            return XCTFail("missing simulator state must abort")
        }
        XCTAssertTrue(h.simulatorInspector.shutdowns.isEmpty)
        XCTAssertFalse(h.calls.contains { $0.hasPrefix("hdiutil detach") || $0.hasPrefix("diskutil eject") })
    }
}
