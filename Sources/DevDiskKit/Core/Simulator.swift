import Foundation

/// A CoreSimulator device whose storage paths and runtime can be verified from
/// `simctl`. Paths are retained in the approved plan so a reused UDID cannot widen
/// the operation scope.
struct SimulatorDevice: Equatable, Identifiable {
    let udid: String
    let name: String
    let runtimeIdentifier: String
    let state: String
    let dataPath: String?
    let runtimePath: String?

    var id: String { udid }
    var isShutdown: Bool { state.caseInsensitiveCompare("Shutdown") == .orderedSame }
    var needsShutdown: Bool { !isShutdown }
    var displayRuntime: String {
        runtimeIdentifier.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
    }
}

protocol SimulatorInspecting {
    func devices(runner: CommandRunner) throws -> [SimulatorDevice]
    func shutdown(_ device: SimulatorDevice, runner: CommandRunner) throws
}

struct SystemSimulatorInspector: SimulatorInspecting {
    func devices(runner: CommandRunner) throws -> [SimulatorDevice] {
        let devices = try runner.run(Tool.xcrun, ["simctl", "list", "devices", "--json"], timeout: Deadline.quick)
        try devices.requireSuccess(M("simulatorprobe.list.devices"))
        let runtimes = try runner.run(Tool.xcrun, ["simctl", "list", "runtimes", "--json"], timeout: Deadline.quick)
        try runtimes.requireSuccess(M("simulatorprobe.list.runtimes"))
        return try Self.parse(devices: devices.stdout, runtimes: runtimes.stdout)
    }

    func shutdown(_ device: SimulatorDevice, runner: CommandRunner) throws {
        let result = try runner.run(Tool.xcrun, ["simctl", "shutdown", device.udid], timeout: Deadline.eject)
        try result.requireSuccess(M("simulatorprobe.shutdown", device.name))
    }

    static func parse(devices data: Data, runtimes runtimeData: Data) throws -> [SimulatorDevice] {
        guard let deviceRoot = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimeGroups = deviceRoot["devices"] as? [String: [[String: Any]]],
              let runtimeRoot = try? JSONSerialization.jsonObject(with: runtimeData) as? [String: Any],
              let runtimeRows = runtimeRoot["runtimes"] as? [[String: Any]] else {
            throw ProbeFailure(M("simulatorprobe.invalid.output"))
        }

        let runtimePaths = Dictionary(runtimeRows.compactMap { row -> (String, String)? in
            guard let identifier = row["identifier"] as? String,
                  let path = row["bundlePath"] as? String, !path.isEmpty else { return nil }
            return (identifier, path)
        }, uniquingKeysWith: { first, _ in first })

        var result: [SimulatorDevice] = []
        var ids = Set<String>()
        for (runtimeIdentifier, rows) in runtimeGroups {
            for row in rows {
                guard let udid = row["udid"] as? String, !udid.isEmpty,
                      let name = row["name"] as? String, !name.isEmpty,
                      let state = row["state"] as? String, !state.isEmpty else {
                    throw ProbeFailure(M("simulatorprobe.invalid.device"))
                }
                guard ids.insert(udid).inserted else {
                    throw ProbeFailure(M("simulatorprobe.duplicate.device"))
                }
                let dataPath = row["dataPath"] as? String
                let runtimePath = runtimePaths[runtimeIdentifier]
                // A running or transitioning device without both paths cannot be
                // proven unrelated to the target volume, so the caller must fail closed.
                if state.caseInsensitiveCompare("Shutdown") != .orderedSame,
                   (dataPath?.isEmpty != false || runtimePath?.isEmpty != false) {
                    throw ProbeFailure(M("simulatorprobe.device.scope.unknown", name))
                }
                result.append(.init(udid: udid, name: name,
                                    runtimeIdentifier: runtimeIdentifier, state: state,
                                    dataPath: dataPath, runtimePath: runtimePath))
            }
        }
        return result.sorted { $0.udid < $1.udid }
    }
}

enum SimulatorScope {
    static func isRelated(_ device: SimulatorDevice, to roots: [String]) -> Bool {
        [device.dataPath, device.runtimePath].compactMap { $0 }.contains { path in
            roots.contains { DiskImageProbe.contains(path, under: $0) }
        }
    }
}
