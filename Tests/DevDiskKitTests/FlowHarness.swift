import Foundation
@testable import DevDiskKit

/// A simulated machine: file handles, process identities, images and disk state
/// change independently. No test in this harness can send a real signal or eject.
final class FlowHarness: CommandRunner, @unchecked Sendable {
    static let mount = "/Volumes/ReviewDisk"
    let targetInspector = FakeTargetInspector()
    let processes = FakeProcessInspector()
    var args: [Int32: String] = [:]
    var files: [Int32: [String]] = [:]
    var images: [DiskImage] = []
    var calls: [String] = []
    var failures: [String: CommandResult] = [:]
    var onCall: ((String) -> Void)?
    var stopWorks = true
    var detachWorks = true
    var cancellation = CancellationToken()
    var clock = Date(timeIntervalSince1970: 1000)
    var flow: EjectFlow {
        let flow = EjectFlow(runner: self, mountPoint: Self.mount, cancellation: cancellation)
        flow.inspector = processes
        flow.targets = targetInspector
        flow.now = { self.clock }
        flow.sleep = { self.clock += $0 }
        flow.quitTimeout = 0.3
        return flow
    }
    func add(pid: Int32 = 123, executable: String = "/usr/bin/java", args command: String = "java org.gradle.launcher.daemon.bootstrap.GradleDaemon 8.14",
             app: String? = nil, paths: [String]? = nil, uid: UInt32 = getuid()) {
        processes.live[pid] = .init(pid: pid, uid: uid, startedSeconds: 42, startedMicros: 3,
                                    executable: executable, bundleID: app, appName: app == nil ? nil : "Review Editor")
        args[pid] = command
        files[pid] = paths ?? [Self.mount + "/project/file"]
    }
    func run(_ path: String, _ arguments: [String]) throws -> CommandResult {
        let key = MockCommandRunner.key(path, arguments)
        calls.append(key)
        onCall?(key)
        if let r = failures[key] { return r }
        func output(_ text: String, code: Int32 = 0) -> CommandResult {
            .init(stdout: Data(text.utf8), stderr: "", exitCode: code)
        }
        if path == Tool.ps {
            return output("1 root /sbin/launchd\n" + processes.live.keys.sorted().map { "\($0) example \(args[$0] ?? "process")" }.joined(separator: "\n"))
        }
        if path == Tool.lsof {
            let rows = files.keys.sorted().filter { processes.live[$0] != nil && !(files[$0] ?? []).isEmpty }
            return output(rows.map { pid in
                "p\(pid)\ncprocess\nLexample\n" + (files[pid] ?? []).map { "n" + $0 + "\n" }.joined()
            }.joined(), code: rows.isEmpty ? 1 : 0)
        }
        if path == Tool.hdiutil && arguments == ["info", "-plist"] {
            let rows: [[String: Any]] = images.map { image in
                var row: [String: Any] = ["image-path": image.path, "system-entities": image.devEntries.map { ["dev-entry": $0] }]
                if image.accessKnown { row["writeable"] = image.writable }
                return row
            }
            return .init(stdout: try PropertyListSerialization.data(fromPropertyList: ["images": rows], format: .xml, options: 0), stderr: "", exitCode: 0)
        }
        if path == Tool.hdiutil && arguments.first == "detach" {
            if !detachWorks { return output("busy", code: 1) }
            images.removeAll { $0.wholeDisk == arguments.last }
            return output("detached")
        }
        if path == Tool.kill {
            if stopWorks, let pid = Int32(arguments.last ?? "") { processes.live.removeValue(forKey: pid) }
            return output("")
        }
        if path == Tool.diskutil && arguments.first == "eject" {
            targetInspector.gone = true
            return output("ejected")
        }
        throw ProbeFailure("Unexpected command: " + key)
    }
}

final class FakeProcessInspector: ProcessInspecting {
    var live: [Int32: ProcessIdentity] = [:]
    var quits: [Int32] = []
    var refuseQuit = false
    var failIdentity = false
    var onQuit: (() -> Void)?
    func identity(_ pid: Int32) throws -> ProcessIdentity? {
        if failIdentity { throw ProbeFailure("identity denied") }
        return live[pid]
    }
    func requestQuit(_ identity: ProcessIdentity) throws {
        guard live[identity.pid] == identity else { throw ProbeFailure("identity changed") }
        quits.append(identity.pid)
        if !refuseQuit { live.removeValue(forKey: identity.pid) }
        onQuit?()
    }
}

final class FakeTargetInspector: TargetInspecting {
    var current = EjectTarget(volume: .init(name: "ReviewDisk", mount: FlowHarness.mount, device: "disk90s1", uuid: "review-uuid"),
                             physicalDisk: "disk90", affected: [.init(name: "ReviewDisk", mount: FlowHarness.mount, device: "disk90s1", uuid: "review-uuid")])
    var gone = false
    var verifyError = false
    var reads = 0
    var beforeRead: (() -> Void)?
    func target(at mount: String, runner: CommandRunner) throws -> EjectTarget {
        reads += 1; beforeRead?()
        return current
    }
    func isEjected(_ target: EjectTarget, runner: CommandRunner) throws -> Bool {
        if verifyError { throw ProbeFailure("verification unavailable") }
        return gone
    }
}
