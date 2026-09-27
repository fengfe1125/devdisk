import XCTest
@testable import DevDiskKit

final class PanelLayoutTests: XCTestCase {
    func testExpandedFooterKeepsWindowWithinAvailableHeight() {
        let available: CGFloat = 923
        let chrome: CGFloat = 320
        let body = UI.boundedBodyHeight(preferred: 703, available: available, chrome: chrome)
        XCTAssertEqual(body, 555)
        XCTAssertLessThanOrEqual(body + chrome + 48, available)
    }

    func testPopoverStillUsesPreferredCapOnLargeDisplay() {
        XCTAssertEqual(UI.boundedBodyHeight(preferred: 520, available: 1400, chrome: 320), 520)
    }

    func testShortScreenShrinksBodyRatherThanHidingActions() {
        XCTAssertEqual(UI.boundedBodyHeight(preferred: 520, available: 600, chrome: 330), 222)
        XCTAssertEqual(UI.boundedBodyHeight(preferred: 520, available: 300, chrome: 330), 1)
    }
}
