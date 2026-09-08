import XCTest
@testable import DevDiskKit

/// Guards the defect that hung the whole eject flow: the runner used to send
/// SIGTERM on timeout and then call `waitUntilExit()` with no bound, so a child
/// that ignores SIGTERM blocked the caller forever. The UI sat on
/// "正在安全弹出" indefinitely with nothing to tell the user why.
final class CommandDeadlineTests: XCTestCase {

    private let runner = SystemCommandRunner()

    func testNormalCommandSucceeds() throws {
        let r = try runner.run("/bin/echo", ["hello"], timeout: 5)
        XCTAssertTrue(r.ok)
        XCTAssertFalse(r.timedOut)
        XCTAssertEqual(r.text.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
    }

    func testNonZeroExitIsNotATimeout() throws {
        let r = try runner.run("/bin/sh", ["-c", "exit 3"], timeout: 5)
        XCTAssertFalse(r.ok)
        XCTAssertFalse(r.timedOut)
        XCTAssertEqual(r.exitCode, 3)
    }

    /// A cooperative child: SIGTERM ends it, so the deadline is enforced quickly.
    func testSlowCommandIsKilledAtTheDeadline() throws {
        let started = Date()
        let r = try runner.run("/bin/sleep", ["30"], timeout: 1)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertTrue(r.timedOut)
        XCTAssertFalse(r.ok, "a timed-out command must never look successful")
        XCTAssertLessThan(elapsed, 8, "took \(elapsed)s — the deadline was not enforced")
    }

    /// The case that actually caused the hang: the child traps SIGTERM and keeps
    /// running. Only the SIGKILL escalation gets rid of it, and the call must return
    /// either way.
    func testChildIgnoringSIGTERMStillReturns() throws {
        let started = Date()
        let r = try runner.run(
            "/bin/sh", ["-c", "trap '' TERM; sleep 30"], timeout: 1)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertTrue(r.timedOut)
        XCTAssertFalse(r.ok)
        XCTAssertLessThan(elapsed, 10,
                          "took \(elapsed)s — SIGTERM was ignored and nothing escalated")
    }

    /// Output larger than a pipe buffer must not deadlock against process exit.
    func testLargeOutputDoesNotDeadlock() throws {
        let r = try runner.run(
            "/bin/sh", ["-c", "for i in $(seq 1 20000); do echo line-$i; done"],
            timeout: 20)
        XCTAssertTrue(r.ok)
        XCTAssertGreaterThan(r.text.count, 100_000)
    }

    func testStderrIsCaptured() throws {
        let r = try runner.run("/bin/sh", ["-c", "echo oops >&2; exit 1"], timeout: 5)
        XCTAssertTrue(r.stderr.contains("oops"))
        XCTAssertFalse(r.timedOut)
    }

    func testMissingExecutableThrows() {
        XCTAssertThrowsError(try runner.run("/nonexistent/binary", [], timeout: 5))
    }

    /// Deadlines are per command: the tree-walking ones need longer than a status
    /// query, and eject sits in between.
    func testDeadlinesAreOrdered() {
        XCTAssertLessThan(Deadline.quick, Deadline.eject)
        XCTAssertLessThanOrEqual(Deadline.eject, Deadline.scan)
        XCTAssertLessThan(Deadline.scan, Deadline.walk)
    }
}
