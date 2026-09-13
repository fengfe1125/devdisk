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
        let flow = EjectFlow(runner: runner, mountPoint: mount)
        flow.onUpdate = { steps in
            if let active = steps.first(where: { $0.state == .running }) { print(active.title) }
        }
        var outcome = flow.run(indexingOn: nil)
        while case .preview(let plan) = outcome {
            print("弹出影响：\(plan.target.volume.name) · \(plan.target.volume.mount)")
            for volume in plan.target.affected { print("关联卷：\(volume.name) · \(volume.mount)") }
            for holder in plan.apps + plan.daemons + plan.manual {
                print("\(holder.name) · \(holder.openFileCount ?? 0) 个文件 · \(holder.kind)")
                holder.sampleFiles.forEach { print("  " + $0) }
            }
            plan.images.forEach { print("映像：\($0.path) · \($0.writable ? "需手动处理" : "只读")") }
            plan.issues.forEach { print("检测不完整：" + $0) }
            guard isatty(STDIN_FILENO) == 1 else {
                print("需要交互确认；未执行退出、停止或弹出操作。")
                return false
            }
            if plan.canSystemOnly {
                print("输入 system 仅尝试普通系统弹出；其他输入取消：")
                guard readLine() == "system" else { return false }
                outcome = flow.execute(plan, systemOnly: true)
            } else if plan.canPrepare {
                print("退出应用影响整个应用，后台服务可能仍在工作。输入 yes 确认处理并弹出；其他输入取消：")
                guard readLine() == "yes" else { return false }
                outcome = flow.execute(plan, systemOnly: false)
            } else {
                print("请手动处理上述阻塞对象后重新运行。")
                return false
            }
        }
        switch outcome {
        case .ejected(let t, let apps, let daemons):
            print("成功 · \(String(format: "%.1f", t)) 秒 · 应用 \(apps) · 服务进程 \(daemons)")
            return true
        case .aborted(let why): print("中止：\(why)"); return false
        case .preview: return false
        }
    }

    /// `DevDisk --check-update [version]` runs a real update check against GitHub
    /// and prints the verdict. Pass a version to simulate running an older build.
    public static func runUpdateCheck(arguments: [String]) async -> Bool {
        guard let i = arguments.firstIndex(of: "--check-update") else { return false }
        let pretend = i + 1 < arguments.count && !arguments[i + 1].hasPrefix("-")
            ? arguments[i + 1] : AppVersion.current

        let checker = UpdateChecker(
            currentVersion: pretend,
            defaults: UserDefaults(suiteName: "devdisk.cli") ?? .standard)
        print("当前版本 \(pretend) — 正在查询 GitHub…")
        await checker.check(force: true)

        if let r = checker.available {
            print("有新版本 \(r.version)\n\(r.url.absoluteString)")
        } else {
            print("已是最新（或无法获取）")
        }
        return true
    }

    /// `DevDisk --selftest` verifies a packaged build can actually reach everything
    /// it needs, and exits non-zero if not. Run by package.sh and by CI, because a
    /// missing resource only surfaces at launch — a build that compiles, packages
    /// and signs cleanly can still die instantly on a user's machine.
    public static func selftest() -> Bool {
        var problems: [String] = []

        let missing = MenuBarIcon.missing
        if missing.isEmpty {
            print("  ✓ 菜单栏图标 5/5")
        } else {
            problems.append("菜单栏图标缺失: " + missing.joined(separator: ", "))
        }

        print("  ✓ 版本 \(AppVersion.current)")
        if let id = Bundle.main.bundleIdentifier {
            print("  ✓ bundle id \(id)")
        } else {
            problems.append("Info.plist 未被读取到，bundle id 为空")
        }

        for p in problems { print("  ✗ " + p) }
        return problems.isEmpty
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
        let store = DiskStore(runner: runner, defaults: previewDefaults(), start: false)
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
                let view = PanelView(presentation: .snapshot)
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

    /// Deterministic snapshots of the real views. All operations use DemoMachine.
    public static func runDemo(arguments: [String]) async -> Bool {
        guard let i = arguments.firstIndex(of: "--snapshot-demo"), i + 1 < arguments.count else { return false }
        let dir = URL(fileURLWithPath: arguments[i + 1])
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { print(error.localizedDescription); return false }
        let checker = UpdateChecker(fetcher: StubFetcher(), defaults: previewDefaults())
        for scenario in ["short", "long", "unknown", "running", "waiting"] {
            let store = DemoFixture.makeStore(scenario: scenario)
            for _ in 0..<300 {
                if store.operation == .awaitingConfirmation { break }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            guard store.ejectPlan != nil else { print("演示预检未完成：" + scenario); return false }
            if scenario == "running" || scenario == "waiting" {
                store.confirmEject()
                for _ in 0..<300 {
                    if scenario == "waiting" ? store.waitingForSystem : store.ejectSteps.contains(where: { $0.id == "apps" && $0.state == .running }) { break }
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
            }
            for (suffix, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
                let view = PanelView(presentation: .snapshot)
                    .environmentObject(store).environmentObject(checker)
                    .environment(\.colorScheme, scheme).frame(width: UI.width)
                    .background(scheme == .dark ? Color(white: 0.17) : Color(white: 0.96))
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                guard let nsImage = renderer.nsImage, let tiff = nsImage.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { return false }
                do { try png.write(to: dir.appendingPathComponent("\(scenario)-\(suffix).png")) }
                catch { return false }
            }
            store.cancelEject()
        }
        return true
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
