import AppKit

/// Explicit, isolated UI acceptance mode. Every process/disk operation is simulated;
/// this runner never forwards an unrecognised command to the system.
final class DemoMachine: CommandRunner, ProcessInspecting, TargetInspecting, @unchecked Sendable {
    let scenario: String
    let mount = "/Volumes/DevDisk 演示盘"
    private var live: [Int32: ProcessIdentity] = [:]
    private(set) var gone = false
    init(scenario: String) {
        self.scenario = scenario
        for index in 1...(scenario.contains("long") ? 8 : 1) {
            let pid = Int32(90000 + index)
            live[pid] = .init(pid: pid, uid: getuid(), startedSeconds: 42, startedMicros: 0,
                             executable: "/Applications/演示编辑器.app/Contents/MacOS/editor",
                             bundleID: "devdisk.demo.editor\(index)", appName: "演示编辑器 \(index)")
        }
    }
    var targetValue: EjectTarget {
        let volume = TargetVolume(name: "DevDisk 演示盘", mount: mount, device: "disk900s1", uuid: "DEMO-ONLY")
        return .init(volume: volume, physicalDisk: "disk900", affected: [volume])
    }
    var drive: DiscoveredVolume {
        .init(mountPoint: mount, name: "DevDisk 演示盘", deviceIdentifier: "disk900s1", filesystem: "APFS",
              busProtocol: "演示数据", isExternal: true, isDiskImage: false, isBoot: false,
              totalBytes: 1_000_000_000_000, freeBytes: 650_000_000_000, volumeUUID: "DEMO-ONLY")
    }
    var snapshot: DiskSnapshot {
        .init(volume: .init(name: drive.name, mountPoint: mount, filesystem: "APFS", isEncrypted: true,
              isExternal: true, ownersEnabled: true, volumeUUID: "DEMO-ONLY", deviceIdentifier: drive.deviceIdentifier,
              containerReference: nil, physicalDisk: "disk900", totalBytes: drive.totalBytes, freeBytes: drive.freeBytes),
              hardware: .init(model: "演示数据 · 不操作真实设备"), health: nil,
              healthUnavailableReason: "UI 验收专用模拟数据", checks: [
                .init(id: "demo", severity: .unknown, title: "隔离演示模式", detail: "本窗口不会退出真实应用或弹出真实硬盘。", fixCommand: nil, settingsURL: nil)
              ], directories: [], occupancy: nil)
    }
    func identity(_ pid: Int32) throws -> ProcessIdentity? { live[pid] }
    func requestQuit(_ identity: ProcessIdentity) throws {
        if !scenario.contains("running") { live.removeValue(forKey: identity.pid) }
    }
    func target(at mount: String, runner: CommandRunner) throws -> EjectTarget { targetValue }
    func isEjected(_ target: EjectTarget, runner: CommandRunner) throws -> Bool { gone }
    func run(_ path: String, _ args: [String]) throws -> CommandResult {
        func result(_ text: String, code: Int32 = 0) -> CommandResult {
            .init(stdout: Data(text.utf8), stderr: "", exitCode: code)
        }
        switch path {
        case Tool.ps: return result("1 root /sbin/launchd\n" + live.keys.map { "\($0) demo /Applications/Demo.app/Contents/MacOS/editor" }.joined(separator: "\n"))
        case Tool.lsof:
            if scenario.contains("unknown") { return .init(stdout: Data(), stderr: "演示：检测超时，结果不完整", exitCode: -1, timedOut: true) }
            return result(live.keys.sorted().map { "p\($0)\nceditor\nLdemo\nn\(mount)/Projects/Example-\($0)/Sources/document.swift\n" }.joined(), code: live.isEmpty ? 1 : 0)
        case Tool.hdiutil:
            guard args == ["info", "-plist"] else { throw ProbeFailure("演示不支持此操作") }
            return .init(stdout: try PropertyListSerialization.data(fromPropertyList: ["images": []], format: .xml, options: 0), stderr: "", exitCode: 0)
        case Tool.diskutil:
            guard args == ["eject", "disk900"] else { throw ProbeFailure("演示不支持此操作") }
            if scenario.contains("waiting") { Thread.sleep(forTimeInterval: 8) }
            gone = true; return result("simulated eject")
        default: throw ProbeFailure("隔离演示模式禁止执行系统命令")
        }
    }
}

@MainActor
enum DemoFixture {
    static func makeStore(scenario: String) -> DiskStore {
        let machine = DemoMachine(scenario: scenario)
        let defaults = UserDefaults(suiteName: "devdisk.demo." + UUID().uuidString)!
        defaults.set(false, forKey: "updateCheckEnabled")
        let store = DiskStore(runner: machine, defaults: defaults, start: false)
        store.discover = { _ in .init(value: machine.gone ? [] : [machine.drive], state: .complete) }
        store.probeVolume = { _, _ in .success(machine.snapshot) }
        store.directoryUsage = { _, _ in [] }
        store.makeFlow = { _, mount, token in
            let flow = EjectFlow(runner: machine, mountPoint: mount, cancellation: token)
            flow.targets = machine; flow.inspector = machine
            return flow
        }
        store.applyDiscovery([machine.drive])
        store.snapshot = machine.snapshot
        store.eject()
        return store
    }
}
