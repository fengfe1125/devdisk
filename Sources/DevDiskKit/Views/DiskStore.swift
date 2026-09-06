import AppKit
import Combine
import SwiftUI

/// Owns all app state and keeps the probes off the main thread. Volume arrival and
/// departure come from NSWorkspace notifications rather than polling, so an unplugged
/// drive is noticed immediately without the app touching the disk on a timer.
@MainActor
final class DiskStore: ObservableObject {

    enum Screen: Equatable {
        case connected
        case scan
        case ejecting
        case ejected(TimeInterval, apps: Int, daemons: Int)
        case disconnected
    }

    @Published var screen: Screen = .disconnected
    @Published var snapshot: DiskSnapshot?
    @Published var directories: [DirectoryUsage] = []
    @Published var directoriesLoading = false
    @Published var occupancy: OccupancyReport?
    @Published var occupancyScanning = false
    @Published var ejectSteps: [EjectFlow.Step] = []
    @Published var lastError: String?
    @Published var lastEjectSummary: String?

    /// Which volume this instance watches. Kept in defaults so it survives relaunch.
    @AppStorage("targetMountPoint") var mountPoint: String = "/Volumes/Developer"

    private let runner: CommandRunner
    private let work = DispatchQueue(label: "devdisk.probe", qos: .userInitiated)
    private var observers: [NSObjectProtocol] = []

    init(runner: CommandRunner = SystemCommandRunner()) {
        self.runner = runner
        observeMounts()
        refresh()
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
    }

    var isMounted: Bool {
        FileManager.default.fileExists(atPath: mountPoint)
    }

    // MARK: - Mount observation

    private func observeMounts() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(center.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
    }

    // MARK: - Refresh

    func refresh() {
        guard isMounted else {
            // Keep the eject-success screen up until the drive is physically unplugged
            // so the "safe to disconnect" confirmation is not lost instantly.
            if case .ejected = screen {} else { screen = .disconnected }
            snapshot = nil
            directories = []
            occupancy = nil
            return
        }

        let mount = mountPoint
        let runner = self.runner
        work.async { [weak self] in
            let result = Self.probe(mount: mount, runner: runner)
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let snap):
                    self.snapshot = snap
                    self.occupancy = snap.occupancy
                    self.lastError = nil
                    if self.screen == .disconnected { self.screen = .connected }
                    if case .ejected = self.screen { self.screen = .connected }
                case .failure(let e):
                    self.lastError = e.localizedDescription
                }
            }
            Self.loadDirectories(mount: mount, runner: runner, into: self)
        }
    }

    /// Everything except `du`, which is slow enough to load separately.
    nonisolated private static func probe(
        mount: String, runner: CommandRunner
    ) -> Result<DiskSnapshot, Error> {
        do {
            let vp = VolumeProbe(runner: runner)
            guard let volume = try vp.volume(at: mount) else {
                return .failure(CommandError.notFound(mount))
            }
            let hardware = try vp.hardware(physicalDisk: volume.physicalDisk)

            var health: SmartHealth?
            var healthReason: String?
            do {
                health = try HealthProbe(runner: runner).health(
                    physicalDisk: volume.physicalDisk)
            } catch {
                healthReason = error.localizedDescription
            }

            let cp = ConfigProbe(runner: runner)
            let indexing = try? cp.spotlightIndexing(mountPoint: mount)
            let checks = cp.checks(volume: volume, health: health)
            let occ = try? Occupancy(runner: runner).quickScan(
                mountPoint: mount, indexingOn: indexing)

            return .success(DiskSnapshot(
                volume: volume, hardware: hardware, health: health,
                healthUnavailableReason: healthReason, checks: checks,
                directories: [], occupancy: occ))
        } catch {
            return .failure(error)
        }
    }

    /// `du` walks the whole volume, so it runs after the fast probes and publishes
    /// separately rather than holding up the rest of the panel.
    nonisolated private static func loadDirectories(
        mount: String, runner: CommandRunner, into store: DiskStore?
    ) {
        Task { @MainActor in store?.directoriesLoading = true }
        let dirs = (try? VolumeProbe(runner: runner).directoryUsage(mountPoint: mount)) ?? []
        Task { @MainActor in
            store?.directories = dirs
            store?.directoriesLoading = false
        }
    }

    // MARK: - Occupancy

    /// The thorough path walks the whole volume, so it only ever runs on demand.
    func fullScan() {
        guard isMounted, !occupancyScanning else { return }
        occupancyScanning = true
        let mount = mountPoint
        let runner = self.runner
        work.async { [weak self] in
            let cp = ConfigProbe(runner: runner)
            let indexing = try? cp.spotlightIndexing(mountPoint: mount)
            let report = try? Occupancy(runner: runner).fullScan(
                mountPoint: mount, indexingOn: indexing)
            Task { @MainActor in
                guard let self else { return }
                if let report { self.occupancy = report }
                self.occupancyScanning = false
            }
        }
    }

    // MARK: - Eject

    func eject() {
        guard isMounted else { return }
        screen = .ejecting
        ejectSteps = []

        let mount = mountPoint
        let runner = self.runner
        work.async { [weak self] in
            let indexing = try? ConfigProbe(runner: runner).spotlightIndexing(mountPoint: mount)
            let flow = EjectFlow(runner: runner, mountPoint: mount)
            flow.onUpdate = { steps in
                Task { @MainActor in self?.ejectSteps = steps }
            }
            let outcome = flow.run(indexingOn: indexing)

            Task { @MainActor in
                guard let self else { return }
                switch outcome {
                case .ejected(let t, let apps, let daemons):
                    self.screen = .ejected(t, apps: apps, daemons: daemons)
                    self.lastEjectSummary = Self.summary(t, apps: apps, daemons: daemons)
                    self.snapshot = nil
                    self.directories = []
                case .aborted(let why):
                    self.lastError = why
                    self.screen = .connected
                    self.refresh()
                }
            }
        }
    }

    nonisolated static func summary(
        _ duration: TimeInterval, apps: Int, daemons: Int
    ) -> String {
        let t = String(format: "%.1f", duration)
        var parts = ["耗时 \(t) 秒"]
        if apps > 0 { parts.append("停止了 \(apps) 个应用") }
        if daemons > 0 { parts.append("\(daemons) 个守护进程") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Actions

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func openSettings(_ url: String) {
        guard let u = URL(string: url) else { return }
        NSWorkspace.shared.open(u)
    }

    func quit() { NSApplication.shared.terminate(nil) }

    static let mainWindowID = "devdisk.main"
}
