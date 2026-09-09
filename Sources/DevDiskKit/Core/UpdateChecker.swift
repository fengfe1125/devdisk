import Foundation

// MARK: - Version

enum AppVersion {
    /// Kept in sync with Resources/Info.plist. The plist is the source of truth for
    /// a packaged build; this constant only covers `swift run` during development,
    /// where there is no bundle Info.plist to read.
    static let fallback = "1.0.9"

    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? fallback
    }
}

/// Semantic version comparison.
///
/// String comparison is wrong here and fails silently: `"1.10.0" < "1.9.0"` is
/// correct lexicographically and wrong in every way that matters, so a user on
/// 1.9.0 would never be told about 1.10.0. Components are compared numerically.
enum SemVer {
    /// Splits "v1.10.0-beta.2" into ([1, 10, 0], "beta.2").
    static func parse(_ raw: String) -> (numbers: [Int], prerelease: String?) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }

        let buildSplit = s.split(separator: "+", maxSplits: 1)
        s = String(buildSplit.first ?? "")

        let preSplit = s.split(separator: "-", maxSplits: 1)
        let core = String(preSplit.first ?? "")
        let pre = preSplit.count > 1 ? String(preSplit[1]) : nil

        let numbers = core.split(separator: ".").map { Int($0) ?? 0 }
        return (numbers.isEmpty ? [0] : numbers, pre)
    }

    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let (na, pa) = parse(a)
        let (nb, pb) = parse(b)

        for i in 0..<max(na.count, nb.count) {
            let x = i < na.count ? na[i] : 0
            let y = i < nb.count ? nb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }

        // 1.0.0 is a later release than 1.0.0-beta.1.
        switch (pa, pb) {
        case (nil, nil):        return .orderedSame
        case (nil, _):          return .orderedDescending
        case (_, nil):          return .orderedAscending
        case (let x?, let y?):  return x == y ? .orderedSame
                                             : (x < y ? .orderedAscending : .orderedDescending)
        }
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }
}

// MARK: - Release

struct Release: Equatable {
    var version: String
    var url: URL
    var name: String?

    static func parse(_ data: Data) -> Release? {
        guard let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        // Drafts and prereleases are not offered as updates.
        if d["draft"] as? Bool == true { return nil }
        if d["prerelease"] as? Bool == true { return nil }

        guard let tag = d["tag_name"] as? String,
              let link = d["html_url"] as? String,
              let url = URL(string: link)
        else { return nil }

        return Release(version: tag, url: url, name: d["name"] as? String)
    }
}

// MARK: - Fetching

protocol ReleaseFetcher {
    func fetchLatest() async throws -> Data
}

struct GitHubReleaseFetcher: ReleaseFetcher {
    var owner = "fengfe1125"
    var repo = "devdisk"

    func fetchLatest() async throws -> Data {
        let url = URL(string:
            "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("DevDisk/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

// MARK: - Checker

/// Checks GitHub Releases at most once a day and reports whether a newer version
/// exists. It never downloads or replaces anything — the app is only ad-hoc signed,
/// so a silent self-replacement would hand the user a build Gatekeeper then blocks
/// with no explanation. Telling them plainly and linking the release is honest.
@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var available: Release?
    @Published private(set) var checking = false

    let currentVersion: String
    private let fetcher: ReleaseFetcher
    private let defaults: UserDefaults
    private let interval: TimeInterval

    private enum Key {
        static let lastCheck = "updateLastCheck"
        static let enabled = "updateCheckEnabled"
    }

    init(fetcher: ReleaseFetcher = GitHubReleaseFetcher(),
         currentVersion: String = AppVersion.current,
         defaults: UserDefaults = .standard,
         interval: TimeInterval = 24 * 60 * 60,
         initialAvailable: Release? = nil) {
        self.available = initialAvailable
        self.fetcher = fetcher
        self.currentVersion = currentVersion
        self.defaults = defaults
        self.interval = interval
    }

    /// Users who opt out are never contacted; `defaults write com.sakura.devdisk
    /// updateCheckEnabled -bool false`.
    var isEnabled: Bool {
        defaults.object(forKey: Key.enabled) as? Bool ?? true
    }

    var isDue: Bool {
        guard isEnabled else { return false }
        guard let last = defaults.object(forKey: Key.lastCheck) as? Date
        else { return true }
        return Date().timeIntervalSince(last) >= interval
    }

    func checkIfDue() {
        guard isDue else { return }
        Task { await check() }
    }

    func checkNow() {
        Task { await check(force: true) }
    }

    func check(force: Bool = false) async {
        guard force || isDue, !checking else { return }
        checking = true
        defer { checking = false }

        // Any failure — offline, rate limited, malformed payload — is silent. A tool
        // for watching a disk has no business raising an alert because GitHub was
        // unreachable.
        guard let data = try? await fetcher.fetchLatest(),
              let release = Release.parse(data)
        else {
            defaults.set(Date(), forKey: Key.lastCheck)
            return
        }

        defaults.set(Date(), forKey: Key.lastCheck)
        available = SemVer.isNewer(release.version, than: currentVersion)
            ? release
            : nil
    }
}
