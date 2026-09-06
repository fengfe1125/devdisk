import Foundation

struct CommandResult {
    let stdout: Data
    let stderr: String
    let exitCode: Int32

    var text: String { String(data: stdout, encoding: .utf8) ?? "" }
    var ok: Bool { exitCode == 0 }
}

enum CommandError: Error, LocalizedError {
    case notFound(String)
    case launchFailed(String, Error)

    var errorDescription: String? {
        switch self {
        case .notFound(let p):          return "找不到可执行文件：\(p)"
        case .launchFailed(let p, let e): return "启动 \(p) 失败：\(e.localizedDescription)"
        }
    }
}

protocol CommandRunner {
    @discardableResult
    func run(_ path: String, _ args: [String]) throws -> CommandResult
}

/// A GUI app launched from Finder does not inherit the user's shell PATH, so every
/// binary is addressed by absolute path. Homebrew tools are located by probing the
/// two standard prefixes rather than assuming either one.
enum Tool {
    static let diskutil       = "/usr/sbin/diskutil"
    static let systemProfiler = "/usr/sbin/system_profiler"
    static let mdutil         = "/usr/bin/mdutil"
    static let tmutil         = "/usr/bin/tmutil"
    static let pmset          = "/usr/bin/pmset"
    static let lsof           = "/usr/sbin/lsof"
    static let ps             = "/bin/ps"
    static let pgrep          = "/usr/bin/pgrep"
    static let pkill          = "/usr/bin/pkill"
    static let kill           = "/bin/kill"
    static let du             = "/usr/bin/du"
    static let osascript      = "/usr/bin/osascript"

    /// nil when smartmontools is not installed — the health section degrades instead of failing.
    static let smartctl: String? = {
        ["/opt/homebrew/bin/smartctl", "/usr/local/bin/smartctl"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// adb lives on the external volume itself, so it is resolved from ANDROID_HOME at call time.
    static func adb(androidHome: String?) -> String? {
        guard let home = androidHome else { return nil }
        let p = home + "/platform-tools/adb"
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }
}

struct SystemCommandRunner: CommandRunner {
    /// Commands that walk the whole volume (du, lsof +D) can run for seconds.
    var timeout: TimeInterval = 60

    func run(_ path: String, _ args: [String]) throws -> CommandResult {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw CommandError.notFound(path)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args

        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err

        do { try proc.run() } catch { throw CommandError.launchFailed(path, error) }

        // Drain both pipes on background queues; a full pipe buffer would otherwise
        // deadlock against waitUntilExit for anything verbose (lsof, system_profiler).
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        for (pipe, sink) in [(out, { outData = $0 }), (err, { errData = $0 })] {
            group.enter()
            DispatchQueue.global().async {
                sink(pipe.fileHandleForReading.readDataToEndOfFile())
                group.leave()
            }
        }

        let deadline = DispatchTime.now() + timeout
        if group.wait(timeout: deadline) == .timedOut {
            proc.terminate()
            _ = group.wait(timeout: .now() + 2)
        }
        proc.waitUntilExit()

        return CommandResult(
            stdout: outData,
            stderr: String(data: errData, encoding: .utf8) ?? "",
            exitCode: proc.terminationStatus
        )
    }
}

/// Returns canned output keyed by "<basename> <args joined>", and records every
/// invocation so tests can assert on the exact command sequence.
final class MockCommandRunner: CommandRunner {
    private(set) var calls: [(path: String, args: [String])] = []
    var responses: [String: CommandResult] = [:]
    var fallback = CommandResult(stdout: Data(), stderr: "", exitCode: 0)

    init(responses: [String: CommandResult] = [:]) {
        self.responses = responses
    }

    static func key(_ path: String, _ args: [String]) -> String {
        ([(path as NSString).lastPathComponent] + args).joined(separator: " ")
    }

    func stub(_ key: String, stdout: String, exitCode: Int32 = 0, stderr: String = "") {
        responses[key] = CommandResult(
            stdout: Data(stdout.utf8), stderr: stderr, exitCode: exitCode
        )
    }

    func stub(_ key: String, data: Data, exitCode: Int32 = 0) {
        responses[key] = CommandResult(stdout: data, stderr: "", exitCode: exitCode)
    }

    /// Successive calls to the same command return successive outputs; the last one
    /// repeats. Needed to model state that changes mid-flow — a process table that
    /// still lists an app before it quits and no longer lists it after.
    private var sequences: [String: [CommandResult]] = [:]

    func stubSequence(_ key: String, _ outputs: [String]) {
        sequences[key] = outputs.map {
            CommandResult(stdout: Data($0.utf8), stderr: "", exitCode: 0)
        }
    }

    func run(_ path: String, _ args: [String]) throws -> CommandResult {
        let k = Self.key(path, args)
        calls.append((path, args))
        if var queued = sequences[k], !queued.isEmpty {
            let next = queued.removeFirst()
            if !queued.isEmpty { sequences[k] = queued }
            return next
        }
        return responses[k] ?? fallback
    }

    /// Command lines in invocation order, e.g. "diskutil eject /Volumes/Developer".
    var log: [String] { calls.map { Self.key($0.path, $0.args) } }
}
