import SwiftUI
import XCTest
@testable import DevDiskKit

/// The bar under 已用空间构成 was visibly cut off on a camera card: one folder held
/// 99.6% of the used space and fourteen tiny ones followed. Per-segment minimum
/// widths plus 1pt gaps pushed the row past its track, and the clip shape hid the
/// tail. These pin down the property that broke: the widths must always add up to
/// exactly the space available.
final class CapacityBarWidthTests: XCTestCase {

    private let track: CGFloat = 352   // the real inner width at 380pt panel width

    private func assertFits(_ widths: [CGFloat], _ available: CGFloat,
                            file: StaticString = #filePath, line: UInt = #line) {
        let sum = widths.reduce(0, +)
        XCTAssertEqual(sum, available, accuracy: 0.5,
                       "widths sum to \(sum) in \(available)pt", file: file, line: line)
        XCTAssertFalse(widths.contains { $0 < 0 }, "negative width", file: file, line: line)
    }

    /// The exact shape that broke: NIKON Z 6, DCIM 208.59 GB of 209.4 GB used.
    func testOneHugeSegmentWithManyTinyOnes() {
        var bytes: [Int64] = [208_590_000_000]
        bytes.append(contentsOf: Array(repeating: 1_000_000, count: 14))

        let w = CapacityBar.segmentWidths(bytes: bytes, available: track)
        assertFits(w, track)
        XCTAssertEqual(w.count, bytes.count)
        XCTAssertTrue(w.allSatisfy { $0 >= 2 - 0.001 },
                      "every slice should still be visible: \(w)")
    }

    func testEvenSplit() {
        let w = CapacityBar.segmentWidths(bytes: Array(repeating: 100, count: 4),
                                          available: track)
        assertFits(w, track)
        for width in w { XCTAssertEqual(width, track / 4, accuracy: 0.5) }
    }

    func testSingleSegmentTakesTheWholeTrack() {
        let w = CapacityBar.segmentWidths(bytes: [42], available: track)
        assertFits(w, track)
        XCTAssertEqual(w[0], track, accuracy: 0.5)
    }

    /// More segments than the track can give a minimum to: proportional wins, and
    /// crucially the total still does not overflow.
    func testTooManySegmentsToAllHaveAMinimumStillFits() {
        let bytes = Array(repeating: Int64(1), count: 400)
        let w = CapacityBar.segmentWidths(bytes: bytes, available: track)
        assertFits(w, track)
    }

    func testZeroSizedSegmentsDoNotBreakTheMath() {
        let w = CapacityBar.segmentWidths(bytes: [100, 0, 0, 50], available: track)
        assertFits(w, track)
    }

    func testEmptyAndDegenerateInputs() {
        XCTAssertTrue(CapacityBar.segmentWidths(bytes: [], available: track).isEmpty)
        XCTAssertEqual(CapacityBar.segmentWidths(bytes: [1, 2], available: 0), [0, 0])
        assertFits(CapacityBar.segmentWidths(bytes: [0, 0], available: track), track)
    }

    /// A narrow track cannot fit a 2pt minimum per slice; it must still not overflow.
    func testNarrowTrack() {
        let w = CapacityBar.segmentWidths(bytes: Array(repeating: 1, count: 20),
                                          available: 10)
        assertFits(w, 10)
    }

    /// The old implementation, kept here as the counter-example: it overflowed, which
    /// is why the bar appeared truncated.
    func testOldApproachWouldHaveOverflowed() {
        var bytes: [Int64] = [208_590_000_000]
        bytes.append(contentsOf: Array(repeating: 1_000_000, count: 14))
        let total = CGFloat(bytes.reduce(0, +))

        let old = bytes.map { max(1, track * CGFloat($0) / total) }
        let gaps = CGFloat(bytes.count - 1) * 1
        XCTAssertGreaterThan(old.reduce(0, +) + gaps, track,
                             "if this no longer overflows the regression is not being tested")
    }
}
