import XCTest
@testable import DevDiskKit

final class SemVerTests: XCTestCase {

    /// The reason this comparison exists at all: string ordering puts 1.10.0 before
    /// 1.9.0, which would silently hide every update after .9 from users.
    func testDoubleDigitMinorBeatsSingleDigit() {
        XCTAssertTrue(SemVer.isNewer("1.10.0", than: "1.9.0"))
        XCTAssertFalse(SemVer.isNewer("1.9.0", than: "1.10.0"))
        XCTAssertTrue("1.10.0" < "1.9.0", "string ordering is the trap being guarded against")
    }

    func testOrdering() {
        XCTAssertTrue(SemVer.isNewer("1.0.1", than: "1.0.0"))
        XCTAssertTrue(SemVer.isNewer("1.1.0", than: "1.0.9"))
        XCTAssertTrue(SemVer.isNewer("2.0.0", than: "1.99.99"))
        XCTAssertFalse(SemVer.isNewer("1.0.0", than: "1.0.0"))
        XCTAssertFalse(SemVer.isNewer("0.9.0", than: "1.0.0"))
    }

    func testTolerantOfTagPrefixAndShortForms() {
        XCTAssertTrue(SemVer.isNewer("v1.1.0", than: "1.0.0"))
        XCTAssertTrue(SemVer.isNewer("1.1", than: "1.0.9"))
        XCTAssertEqual(SemVer.compare("1.0", "1.0.0"), .orderedSame)
        XCTAssertEqual(SemVer.compare("v2.0.0", "2.0.0"), .orderedSame)
    }

    /// A final release supersedes its own prereleases.
    func testPrereleaseOrdering() {
        XCTAssertTrue(SemVer.isNewer("1.0.0", than: "1.0.0-beta.1"))
        XCTAssertFalse(SemVer.isNewer("1.0.0-beta.1", than: "1.0.0"))
        XCTAssertTrue(SemVer.isNewer("1.0.0-beta.2", than: "1.0.0-beta.1"))
    }

    func testBuildMetadataIgnored() {
        XCTAssertEqual(SemVer.compare("1.0.0+abc", "1.0.0"), .orderedSame)
    }

    func testGarbageDoesNotCrash() {
        XCTAssertEqual(SemVer.compare("", ""), .orderedSame)
        XCTAssertFalse(SemVer.isNewer("not-a-version", than: "1.0.0"))
    }
}

final class ReleaseParsingTests: XCTestCase {

    private func payload(tag: String = "v1.2.0",
                         draft: Bool = false,
                         prerelease: Bool = false) -> Data {
        Data("""
        {
          "tag_name": "\(tag)",
          "name": "DevDisk \(tag)",
          "draft": \(draft),
          "prerelease": \(prerelease),
          "html_url": "https://github.com/fengfe1125/devdisk/releases/tag/\(tag)"
        }
        """.utf8)
    }

    func testParsesRelease() throws {
        let r = try XCTUnwrap(Release.parse(payload()))
        XCTAssertEqual(r.version, "v1.2.0")
        XCTAssertEqual(r.url.absoluteString,
                       "https://github.com/fengfe1125/devdisk/releases/tag/v1.2.0")
    }

    func testDraftsAndPrereleasesAreNotOffered() {
        XCTAssertNil(Release.parse(payload(draft: true)))
        XCTAssertNil(Release.parse(payload(prerelease: true)))
    }

    func testMalformedPayloadReturnsNil() {
        XCTAssertNil(Release.parse(Data("not json".utf8)))
        XCTAssertNil(Release.parse(Data("{}".utf8)))
    }
}

// MARK: - Checker

private struct StubFetcher: ReleaseFetcher {
    var data: Data?
    var error: Error?
    func fetchLatest() async throws -> Data {
        if let error { throw error }
        return data ?? Data()
    }
}

@MainActor
final class UpdateCheckerTests: XCTestCase {

    private func defaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "devdisk.tests.\(UUID().uuidString)")!
        return d
    }

    private func json(_ tag: String) -> Data {
        Data("""
        {"tag_name":"\(tag)","draft":false,"prerelease":false,
         "html_url":"https://github.com/fengfe1125/devdisk/releases/tag/\(tag)"}
        """.utf8)
    }

    func testReportsNewerRelease() async {
        let c = UpdateChecker(fetcher: StubFetcher(data: json("v1.2.0")),
                              currentVersion: "1.0.0", defaults: defaults())
        await c.check(force: true)
        XCTAssertEqual(c.available?.version, "v1.2.0")
    }

    func testSameVersionIsNotAnUpdate() async {
        let c = UpdateChecker(fetcher: StubFetcher(data: json("v1.0.0")),
                              currentVersion: "1.0.0", defaults: defaults())
        await c.check(force: true)
        XCTAssertNil(c.available)
    }

    func testOlderReleaseIsNotAnUpdate() async {
        let c = UpdateChecker(fetcher: StubFetcher(data: json("v0.9.0")),
                              currentVersion: "1.0.0", defaults: defaults())
        await c.check(force: true)
        XCTAssertNil(c.available)
    }

    /// Being offline must never surface as an error — it just means "no news".
    func testNetworkFailureIsSilent() async {
        let c = UpdateChecker(fetcher: StubFetcher(error: URLError(.notConnectedToInternet)),
                              currentVersion: "1.0.0", defaults: defaults())
        await c.check(force: true)
        XCTAssertNil(c.available)
        XCTAssertFalse(c.checking)
    }

    func testChecksAreRateLimitedToOncePerInterval() async {
        let d = defaults()
        let c = UpdateChecker(fetcher: StubFetcher(data: json("v1.2.0")),
                              currentVersion: "1.0.0", defaults: d,
                              interval: 24 * 60 * 60)
        XCTAssertTrue(c.isDue, "a checker that has never run is due")
        await c.check(force: true)
        XCTAssertFalse(c.isDue, "should not check again within the interval")
    }

    func testOptOutSuppressesChecks() {
        let d = defaults()
        d.set(false, forKey: "updateCheckEnabled")
        let c = UpdateChecker(fetcher: StubFetcher(data: json("v1.2.0")),
                              currentVersion: "1.0.0", defaults: d)
        XCTAssertFalse(c.isEnabled)
        XCTAssertFalse(c.isDue)
    }
}
