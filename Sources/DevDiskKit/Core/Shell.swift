import Foundation

struct CommandResult {
    let stdout: Data
    let stderr: String
    let exitCode: Int32
    /// True when the command blew its deadline and had to be killed. Distinguishing
    /// this from a plain non-zero exit lets callers say "timed out" instead of
    /// reporting a misleading failure.
    var timedOut: Bool = false

    var text: String { String(data: stdout, encoding: .utf8) ?? "" }
    var ok: Bool { exitCode == 0 && !timedOut }
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

protocol CommandRunner {
    @discardableResult
    func run(_ path: String, _ args: [String]) throws -> CommandResult

    /// Runs with an explicit deadline. Mocks inherit the default below and ignore it.
    @discardableResult
    func run(_ path: String, _ args: [String],
             timeout: TimeInterval) throws -> CommandResult
}

extension CommandRunner {
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

    /// Runs a child process under a hard deadline.
    ///
    /// The previous version sent SIGTERM on timeout and then called
    /// `waitUntilExit()` unconditionally — which blocks forever if the child does
    /// not die. `diskutil` waiting on `diskarbitrationd` does exactly that, and it
    /// hung the whole eject flow with the UI stuck on "正在安全弹出" and no way for
    /// the user to know why. This escalates SIGTERM → SIGKILL and, if even that
    /// fails, gives up and returns rather than blocking the caller.
    func run(_ path: String, _ args: [String],
             timeout deadline: TimeInterval) throws -> CommandResult {
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

        // Drain both pipes off-thread; a full pipe buffer would otherwise deadlock
        // against process exit for anything verbose (lsof, system_profiler). The
        // box is lock-protected because the two reads run concurrently.
        let box = OutputBox()
        let group = DispatchGroup()
        for (pipe, isStdout) in [(out, true), (err, false)] {
            group.enter()
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                box.set(data, stdout: isStdout)
                group.leave()
            }
        }

        var timedOut = false
        if group.wait(timeout: .now() + deadline) == .timedOut {
            timedOut = true
            proc.terminate()                                   // SIGTERM
            if group.wait(timeout: .now() + 2) == .timedOut {
                kill(proc.processIdentifier, SIGKILL)          // then SIGKILL
                _ = group.wait(timeout: .now() + 2)
            }
        }

        // Never `waitUntilExit()` — it has no bound. Poll instead, and return even
        // if the process somehow outlives SIGKILL (an uninterruptible kernel wait),
        // so a wedged child can never take the app down with it.
        let reapBy = Date().addingTimeInterval(2)
        while proc.isRunning && Date() < reapBy {
            Thread.sleep(forTimeInterval: 0.02)
        }

        return CommandResult(
            stdout: box.stdout,
            stderr: String(data: box.stderr, encoding: .utf8) ?? "",
            exitCode: proc.isRunning ? -1 : proc.terminationStatus,
            timedOut: timedOut
        )
    }
}

/// Collects the two pipe reads, which land on different threads.
private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func set(_ data: Data, stdout: Bool) {
        lock.lock(); defer { lock.unlock() }
        if stdout { out = data } else { err = data }
    }
    var stdout: Data { lock.lock(); defer { lock.unlock() }; return out }
    var stderr: Data { lock.lock(); defer { lock.unlock() }; return err }
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
