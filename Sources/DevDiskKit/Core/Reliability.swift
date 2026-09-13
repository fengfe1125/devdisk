import Foundation

enum ProbeState: Equatable { case complete, partial, unavailable, notApplicable }

struct ProbeResult<Value> {
    var value: Value?
    var state: ProbeState
    var collectedAt: Date = Date()
    var issues: [String] = []
    var isComplete: Bool { state == .complete }

    static func capture(_ body: () throws -> Value?) -> Self {
        do {
            guard let value = try body() else {
                return .init(state: .unavailable, issues: ["输出无法解析"])
            }
            return .init(value: value, state: .complete)
        } catch {
            return .init(state: .unavailable, issues: [error.localizedDescription])
        }
    }
}

struct ProbeFailure: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// A token belongs to one operation, never to a page or a reusable queue.
final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var committed = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    var isCommitted: Bool { lock.lock(); defer { lock.unlock() }; return committed }
    func cancel() { lock.lock(); defer { lock.unlock() }; if !committed { cancelled = true } }
    func check() throws { if isCancelled { throw ProbeFailure("操作已中止") } }
    /// Once the system eject is submitted, cancellation must not pretend to undo it.
    func commit() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        committed = true
        return true
    }
}

struct VolumeIdentity: Hashable {
    let key: String
    init(uuid: String, device: String, session: UUID) {
        key = uuid.isEmpty ? "session:\(session):\(device)" : "uuid:\(uuid)"
    }
}

extension CommandResult {
    func requireSuccess(_ tool: String) throws {
        guard ok else {
            let reason = cancelled ? "已中止" : timedOut ? "超时" : "执行失败（\(exitCode)）"
            throw ProbeFailure("\(tool) \(reason)" + (stderr.isEmpty ? "" : "：\(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"))
        }
    }
}

/// Binds all nested probes to the same cancellation token.
struct ScopedCommandRunner: CommandRunner {
    let base: CommandRunner
    let cancellation: CancellationToken
    func run(_ path: String, _ args: [String]) throws -> CommandResult {
        try run(path, args, timeout: Deadline.quick)
    }
    func run(_ path: String, _ args: [String], timeout: TimeInterval) throws -> CommandResult {
        try cancellation.check()
        let result = try base.run(path, args, timeout: timeout, cancellation: cancellation)
        try cancellation.check()
        return result
    }
}
