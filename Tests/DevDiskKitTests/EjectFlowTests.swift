import XCTest
@testable import DevDiskKit

final class EjectFlowTests: XCTestCase {
    // MARK: - Dissenter parsing

    /// Verbatim output from a real failed eject on this machine. The format is
    /// "dissented by PID N (path)" — not the "PID=N" form — and it is followed by a
    /// PPID line naming the parent shell.
    func testDissenterFromRealDiskutilOutput() throws {
        let out = try Fixture.text("eject_dissented", "txt")
        let msg = EjectFlow.dissenterMessage(out)
        XCTAssertEqual(msg, "被 tail（PID 12167）阻塞")
    }

    /// The parent-shell line must never be reported as the culprit — it would send
    /// the user after the wrong process.
    func testNeverReportsTheParentPPID() throws {
        let out = try Fixture.text("eject_dissented", "txt")
        let msg = try XCTUnwrap(EjectFlow.dissenterMessage(out))
        XCTAssertFalse(msg.contains("12165"), msg)
        XCTAssertFalse(msg.contains("zsh"), msg)
    }

    /// The alternate form diskutil uses in other contexts.
    func testDissenterEqualsForm() {
        let msg = EjectFlow.dissenterMessage(
            "Dissenter PID=1234 (Android Studio) status=0x0000c010 (kDAReturnBusy)")
        XCTAssertEqual(msg, "被 Android Studio（PID 1234）阻塞")
    }

    func testDissenterWithoutName() {
        XCTAssertEqual(EjectFlow.dissenterMessage("Unmount was dissented by PID 99"),
                       "被 PID 99 阻塞")
    }

    func testDissenterFallsBackToFirstLine() {
        let msg = EjectFlow.dissenterMessage("\n  Unmount failed for /Volumes/Developer\n")
        XCTAssertEqual(msg, "卸载失败：Unmount failed for /Volumes/Developer")
    }

    func testDissenterOnEmptyOutput() {
        XCTAssertNil(EjectFlow.dissenterMessage("\n \n"))
    }

}
