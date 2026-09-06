import AppKit
import SwiftUI

/// Renders each panel screen to a PNG with `ImageRenderer`, driven by the real
/// probes against the real volume. Used to check layout without needing to click a
/// menu bar item — a menu bar agent has no ordinary window to screenshot.
///
/// Invoked as `DevDisk --snapshot <dir> [mount-point]`.

/// Never reached — snapshot mode must not touch the network.
private struct StubFetcher: ReleaseFetcher {
    func fetchLatest() async throws -> Data { throw URLError(.cancelled) }
}

private func previewDefaults() -> UserDefaults {
    UserDefaults(suiteName: "devdisk.preview") ?? .standard
}

@MainActor
public enum Snapshot {


    /// `DevDisk --eject <mount>` runs the real eject flow from the command line and
    /// prints each step. Used for end-to-end verification against a scratch volume.
    public static func runEject(arguments: [String]) -> Bool {
        guard let i = arguments.firstIndex(of: "--eject"),
              i + 1 < arguments.count else { return false }
        let mount = arguments[i + 1]

        let runner = SystemCommandRunner()
        let indexing = try? ConfigProbe(runner: runner).spotlightIndexing(mountPoint: mount)
        let flow = EjectFlow(runner: runner, mountPoint: mount)
        var printed = Set<String>()
        flow.onUpdate = { steps in
            for s in steps {
                let line: String
                switch s.state {
                case .pending, .running: continue
                case .done(let d):    line = "  ✓ \(s.title)" + (d.map { " — \($0)" } ?? "")
                case .skipped(let d): line = "  – \(s.title) — \(d)"
                case .failed(let d):  line = "  ✗ \(s.title) — \(d)"
                }
                if printed.insert(s.id).inserted { print(line) }
            }
        }

        print("弹出 \(mount)")
        switch flow.run(indexingOn: indexing) {
        case .ejected(let t, let apps, let daemons):
            print("成功 · \(String(format: "%.1f", t)) 秒 · 应用 \(apps) · 守护进程 \(daemons)")
        case .aborted(let why):
            print("中止：\(why)")
        }
        return true
    }

    public static func run(arguments: [String]) -> Bool {
        guard let i = arguments.firstIndex(of: "--snapshot"),
              i + 1 < arguments.count else { return false }

        let dir = arguments[i + 1]
        let mount = i + 2 < arguments.count ? arguments[i + 2] : "/Volumes/Developer"
        render(into: dir, mountPoint: mount)
        return true
    }

    static func render(into dir: String, mountPoint: String) {
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)

        let runner = SystemCommandRunner()
        let store = DiskStore(runner: runner)
        store.mountPoint = mountPoint

        // No network in snapshot mode: one checker with nothing to report, one
        // pre-loaded with an update so the notice variant gets rendered too.
        let noUpdate = UpdateChecker(fetcher: StubFetcher(),
                                     currentVersion: AppVersion.fallback,
                                     defaults: previewDefaults())
        let withUpdate = UpdateChecker(
            fetcher: StubFetcher(),
            currentVersion: AppVersion.fallback,
            defaults: previewDefaults(),
            initialAvailable: Release(
                version: "v1.1.0",
                url: URL(string: "https://github.com/fengfe1125/devdisk/releases")!,
                name: nil))

        // Probe synchronously so the rendered image is fully populated rather than
        // catching a loading state.
        let vp = VolumeProbe(runner: runner)
        let cp = ConfigProbe(runner: runner)

        if let volume = try? vp.volume(at: mountPoint) {
            let hardware = (try? vp.hardware(physicalDisk: volume.physicalDisk))
                ?? DriveHardware()
            var health: SmartHealth?
            var reason: String?
            do {
                health = try HealthProbe(runner: runner).health(
                    physicalDisk: volume.physicalDisk)
            } catch {
                reason = error.localizedDescription
            }
            let indexing = try? cp.spotlightIndexing(mountPoint: mountPoint)
            let occ = try? Occupancy(runner: runner).fullScan(
                mountPoint: mountPoint, indexingOn: indexing)

            store.snapshot = DiskSnapshot(
                volume: volume, hardware: hardware, health: health,
                healthUnavailableReason: reason,
                checks: cp.checks(volume: volume, health: health),
                directories: [], occupancy: occ)
            store.occupancy = occ
            store.directories =
                (try? vp.directoryUsage(mountPoint: mountPoint)) ?? []
        } else {
            FileHandle.standardError.write(Data(
                "警告：\(mountPoint) 未挂载，只能渲染未连接状态\n".utf8))
        }

        let hasVolume = store.snapshot != nil
        var screens: [(String, DiskStore.Screen)] = [("disconnected", .disconnected)]
        if hasVolume {
            screens = [("connected", .connected),
                       ("scan", .scan),
                       ("ejecting", .ejecting),
                       ("ejected", .ejected(6.2, apps: 1, daemons: 2)),
                       ("disconnected", .disconnected)]
        }

        store.lastEjectSummary = "耗时 6.2 秒 · 停止了 1 个应用 · 2 个守护进程"
        store.ejectSteps = demoSteps

        // Bundle.module traps if the resource bundle is missing, so surface icon
        // availability explicitly rather than discovering it in the menu bar.
        let iconNames = ["connected", "warning", "ejecting", "ejected", "disconnected"]
        let missing = iconNames.filter { MenuBarIcon.image(named: $0) == nil }
        print(missing.isEmpty
              ? "菜单栏图标：5/5 已从 Bundle.module 载入"
              : "菜单栏图标缺失：\(missing.joined(separator: ", "))")

        var jobs = screens.map { ($0.0, $0.1, noUpdate) }
        if hasVolume { jobs.append(("update", .connected, withUpdate)) }

        for (name, screen, checker) in jobs {
            store.screen = screen
            for (suffix, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
                let view = PanelView()
                    .environmentObject(store)
                    .environmentObject(checker)
                    .environment(\.colorScheme, scheme)
                    .frame(width: UI.width)
                    .background(scheme == .dark
                                ? Color(white: 0.17) : Color(white: 0.96))

                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                guard let image = renderer.nsImage,
                      let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:])
                else {
                    print("渲染失败：\(name)-\(suffix)")
                    continue
                }
                let path = "\(dir)/\(name)-\(suffix).png"
                try? png.write(to: URL(fileURLWithPath: path))
                print("\(path)  \(Int(image.size.width))×\(Int(image.size.height))")
            }
        }
    }

    /// A representative mid-flight state; the live flow produces these for real.
    static var demoSteps: [EjectFlow.Step] {
        [
            .init(id: "scan", title: "扫描占用者",
                  state: .done("发现 1 个应用、2 个守护进程")),
            .init(id: "apps", title: "请求应用退出",
                  state: .done("Android Studio 已退出")),
            .init(id: "daemons", title: "停止守护进程",
                  state: .done("2 个进程已结束")),
            .init(id: "recheck", title: "复查占用", state: .running),
            .init(id: "unmount", title: "卸载卷", state: .pending),
        ]
    }
}
