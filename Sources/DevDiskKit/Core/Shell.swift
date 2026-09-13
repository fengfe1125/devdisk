import Foundation

struct CommandResult {
    let stdout: Data
    let stderr: String
    let exitCode: Int32
    /// True when the command blew its deadline and had to be killed. Distinguishing
    /// this from a plain non-zero exit lets callers say "timed out" instead of
    /// reporting a misleading failure.
    var timedOut: Bool = false
    var cancelled: Bool = false

    var text: String { String(data: stdout, encoding: .utf8) ?? "" }
    var ok: Bool { exitCode == 0 && !timedOut && !cancelled }
}

/// Per-command deadlines. `diskutil eject` either succeeds or names a dissenter
/// quickly, so it gets a short one; the tree-walking commands get longer.
enum Deadline {
    static let quick: TimeInterval = 15    // diskutil info, ps, mdutil, tmutil, pmset
    static let eject: TimeInterval = 30
    static let scan: TimeInterval = 30     // lsof +D
    static let walk: TimeInterval = 60     // du -sk
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

protocol CommandRunner: Sendable {
    func run(_ path: String, _ args: [String], timeout: TimeInterval,
             cancellation: CancellationToken?) throws -> CommandResult
    @discardableResult
    func run(_ path: String, _ args: [String]) throws -> CommandResult

    /// Runs with an explicit deadline. Mocks inherit the default below and ignore it.
    @discardableResult
    func run(_ path: String, _ args: [String],
             timeout: TimeInterval) throws -> CommandResult
}

extension CommandRunner {
    func run(_ path: String, _ args: [String], timeout: TimeInterval,
             cancellation: CancellationToken?) throws -> CommandResult {
        try cancellation?.check()
        return try run(path, args, timeout: timeout)
    }
    @discardableResult
    func run(_ path: String, _ args: [String],
             timeout: TimeInterval) throws -> CommandResult {
        try run(path, args)
    }
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
    static let hdiutil        = "/usr/bin/hdiutil"

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
    /// Default deadline for commands that do not ask for a specific one.
    var timeout: TimeInterval = Deadline.quick

    func run(_ path: String, _ args: [String]) throws -> CommandResult {
        try run(path, args, timeout: timeout)
    }

    func run(_ path: String, _ args: [String], timeout: TimeInterval) throws -> CommandResult {
        try run(path, args, timeout: timeout, cancellation: nil)
    }

    /// Nonblocking pipe reads cannot strand reader threads when a grandchild keeps
    /// a write end open. Deadlines use monotonic time, independent of wall-clock changes.
    func run(_ path: String, _ args: [String], timeout: TimeInterval,
             cancellation: CancellationToken?) throws -> CommandResult {
        try cancellation?.check()
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
        let handles = [out.fileHandleForReading, err.fileHandleForReading]
        for handle in handles {
            let fd = handle.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
        defer { handles.forEach { try? $0.close() } }
        var data = [Data(), Data()]
        var buffer = [UInt8](repeating: 0, count: 65536)
        func drain() {
            for i in handles.indices {
                // Bound each drain so a continuously writing process cannot starve cancellation.
                for _ in 0..<16 {
                    let count = read(handles[i].fileDescriptor, &buffer, buffer.count)
                    if count <= 0 { break }
                    data[i].append(contentsOf: buffer.prefix(count))
                }
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var timedOut = false
        var cancelled = false
        while proc.isRunning {
            drain()
            cancelled = cancellation?.isCancelled == true
            timedOut = ProcessInfo.processInfo.systemUptime >= deadline
            if cancelled || timedOut { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        if proc.isRunning {
            proc.terminate()
            let grace = ProcessInfo.processInfo.systemUptime + 0.3
            while proc.isRunning && ProcessInfo.processInfo.systemUptime < grace {
                drain(); Thread.sleep(forTimeInterval: 0.01)
            }
            if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            let reap = ProcessInfo.processInfo.systemUptime + 2
            while proc.isRunning && ProcessInfo.processInfo.systemUptime < reap {
                drain(); Thread.sleep(forTimeInterval: 0.01)
            }
        }
        drain()
        return CommandResult(stdout: data[0], stderr: String(decoding: data[1], as: UTF8.self),
                             exitCode: proc.isRunning ? -1 : proc.terminationStatus,
                             timedOut: timedOut, cancelled: cancelled)
    }
}

/// Returns canned output keyed by "<basename> <args joined>", and records every
/// invocation so tests can assert on the exact command sequence.
/// Test-only runner, configured before use and confined to a single test operation.
final class MockCommandRunner: CommandRunner, @unchecked Sendable {
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
