import AppKit
import Combine
import SwiftUI

@MainActor
final class DiskStore: ObservableObject {
    enum Screen: Equatable {
        case connected, scan, settings, drives, preview, ejecting
        case ejected(TimeInterval, apps: Int, daemons: Int)
        case disconnected
    }
    enum Operation: Equatable {
        case idle, preflight, awaitingConfirmation, executing, cancelling, finished
        var locksTarget: Bool { self == .preflight || self == .awaitingConfirmation || self == .executing || self == .cancelling }
    }
    @Published var screen: Screen = .disconnected
    @Published private(set) var operation: Operation = .idle
    @Published var snapshot: DiskSnapshot?
    @Published var directories: [DirectoryUsage] = []
    @Published var directoriesLoading = false
    @Published var directoryIssue: String?
    @Published var occupancy: OccupancyReport?
    @Published var occupancyScanning = false
    @Published var ejectSteps: [EjectFlow.Step] = []
    @Published var lastError: String?
    @Published var ejectFailure: String?
    @Published var lastEjectSummary: String?
    @Published var ejectPlan: EjectPlan?
    @Published var waitingForSystem = false
    @Published private var verifiedEjected: Screen?
    @Published var mountPoint = ""
    @Published var drives: [DiscoveredVolume] = []
    @Published private(set) var mounted = false

    private let runner: CommandRunner
    private let defaults: UserDefaults
    private let work = DispatchQueue(label: "devdisk.probe", qos: .userInitiated)
    private let ejectQueue = DispatchQueue(label: "devdisk.eject", qos: .userInitiated)
    private var observers: [NSObjectProtocol] = []
    private var settingsObserver: NSObjectProtocol?
    private var generation = 0
    private var session = UUID()
    private var selectedIdentity: VolumeIdentity?
    private var scanToken = CancellationToken()
    private var operationToken: CancellationToken?
    private var refreshActive = false
    private var pendingRefresh = false
    private var cache: [VolumeIdentity: (Date, [DirectoryUsage])] = [:]
    private var lastDirectoryVisible = false

    // Injectable boundaries make task races testable without a real disk or process.
    var discover: (CommandRunner) -> ProbeResult<[DiscoveredVolume]> = { runner in
        VolumeDiscovery(runner: runner).result()
    }
    var probeVolume: (String, CommandRunner) -> Result<DiskSnapshot, Error> = DiskStore.probe
    var directoryUsage: (String, CommandRunner) throws -> [DirectoryUsage] = { mount, runner in
        try VolumeProbe(runner: runner).directoryUsage(mountPoint: mount)
    }
    var makeFlow: (CommandRunner, String, CancellationToken) -> EjectFlow = {
        EjectFlow(runner: $0, mountPoint: $1, cancellation: $2)
    }
    var now: () -> Date = Date.init

    var pinnedMountPoint: String {
        get { defaults.string(forKey: "targetMountPoint") ?? "/Volumes/Developer" }
        set {
            guard !operation.locksTarget else { return }
            defaults.removeObject(forKey: "targetVolumeUUID")
            defaults.set(newValue, forKey: "targetMountPoint")
        }
    }
    var isMounted: Bool { mounted }
    var canCancel: Bool { operation.locksTarget && !waitingForSystem && operationToken?.isCommitted != true }
    var statusScreen: Screen {
        operation.locksTarget ? activeScreen : verifiedEjected ?? (mounted ? .connected : .disconnected)
    }
    var activeScreen: Screen {
        switch operation {
        case .preflight, .executing, .cancelling: return .ejecting
        case .awaitingConfirmation: return .preview
        default: return screen
        }
    }
    private var directoriesVisible: Bool {
        defaults.bool(forKey: PanelSetting.capacity) && defaults.bool(forKey: PanelSetting.breakdownOpen)
    }

    init(runner: CommandRunner = SystemCommandRunner(), defaults: UserDefaults = .standard,
         start: Bool = true) {
        self.runner = runner
        self.defaults = defaults
        PanelSetting.registerDefaults(defaults)
        mountPoint = defaults.string(forKey: "targetMountPoint") ?? "/Volumes/Developer"
        lastDirectoryVisible = directoriesVisible
        if start {
            observeMounts()
            settingsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.operation.locksTarget else { return }
                    let visible = self.directoriesVisible
                    if visible != self.lastDirectoryVisible {
                        self.lastDirectoryVisible = visible
                        self.invalidateScans()
                        self.refresh()
                    }
                }
            }
            refresh()
        }
    }
    deinit {
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        scanToken.cancel()
        operationToken?.cancel()
    }

    private func observeMounts() {
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let path = (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path
                Task { @MainActor in self?.mountsChanged(path: path) }
            })
        }
    }

    func mountsChanged(path: String?) {
        session = UUID()
        invalidateScans()
        if operation.locksTarget {
            let relevant = path == nil || path == mountPoint || ejectPlan?.target.affected.contains(where: { $0.mount == path }) == true
            if relevant && operationToken?.isCommitted != true {
                if operation == .awaitingConfirmation {
                    operationToken?.cancel()
                    ejectPlan = nil
                    operation = .finished
                    screen = .connected
                    ejectFailure = "挂载状态已变化，原预览已失效，请重新检测"
                    refresh()
                } else { cancelEject() }
            }
            return
        }
        refresh()
    }

    private func invalidateScans() {
        generation += 1
        scanToken.cancel()
        scanToken = CancellationToken()
        refreshActive = false
        pendingRefresh = false
        directoriesLoading = false
        occupancyScanning = false
    }

    func refresh(force: Bool = false) {
        guard !operation.locksTarget else { return }
        if force { cache.removeAll() }
        if refreshActive { pendingRefresh = pendingRefresh || force; return }
        refreshActive = true
        let g = generation, token = scanToken, discover = self.discover
        let scoped = ScopedCommandRunner(base: runner, cancellation: token)
        work.async { [weak self] in
            let result = discover(scoped)
            Task { @MainActor in
                guard let self, self.generation == g, !token.isCancelled, !self.operation.locksTarget else { return }
                guard result.isComplete, let found = result.value else {
                    self.lastError = "磁盘发现未完成：" + result.issues.joined(separator: "；")
                    self.finishRefresh()
                    return
                }
                self.applyDiscovery(found)
                if self.mounted { self.refreshCurrent() } else { self.finishRefresh() }
            }
        }
    }

    private func finishRefresh() {
        refreshActive = false
        if pendingRefresh { pendingRefresh = false; refresh(force: true) }
    }

    func applyDiscovery(_ found: [DiscoveredVolume]) {
        drives = found
        guard !operation.locksTarget else { return }
        let pinnedUUID = defaults.string(forKey: "targetVolumeUUID")
        let chosen: DiscoveredVolume?
        if let pinnedUUID, !pinnedUUID.isEmpty {
            chosen = found.first { $0.volumeUUID == pinnedUUID }
                ?? found.first { $0.mountPoint == mountPoint && identity($0) == selectedIdentity }
                ?? (found.count == 1 ? found.first : nil)
        } else {
            chosen = found.first { $0.mountPoint == pinnedMountPoint }
                ?? found.first { $0.mountPoint == mountPoint }
                ?? (found.count == 1 ? found.first : nil)
            if let match = found.first(where: { $0.mountPoint == pinnedMountPoint }), !match.volumeUUID.isEmpty {
                defaults.set(match.volumeUUID, forKey: "targetVolumeUUID")
            }
        }
        guard let chosen else {
            mounted = false
            selectedIdentity = nil
            snapshot = nil; directories = []; occupancy = nil
            if found.isEmpty {
                if case .ejected = screen {} else { screen = .disconnected }
            } else { screen = .drives }
            return
        }
        if chosen.volumeUUID == defaults.string(forKey: "targetVolumeUUID") {
            defaults.set(chosen.mountPoint, forKey: "targetMountPoint")
        }
        let next = identity(chosen)
        if next != selectedIdentity || mountPoint != chosen.mountPoint {
            generation += 1
            scanToken.cancel(); scanToken = CancellationToken()
            snapshot = nil; directories = []; occupancy = nil
            selectedIdentity = next
        }
        mountPoint = chosen.mountPoint
        mounted = true
        verifiedEjected = nil
        if screen == .disconnected || screen == .drives { screen = .connected }
        if case .ejected = screen { screen = .connected }
    }

    private func identity(_ drive: DiscoveredVolume) -> VolumeIdentity {
        .init(uuid: drive.volumeUUID, device: drive.deviceIdentifier, session: session)
    }

    func select(_ volume: DiscoveredVolume) {
        guard !operation.locksTarget else { return }
        invalidateScans()
        selectedIdentity = identity(volume)
        mountPoint = volume.mountPoint
        mounted = true
        verifiedEjected = nil
        snapshot = nil; directories = []; occupancy = nil; ejectFailure = nil; lastError = nil
        screen = .connected
        refreshActive = true
        refreshCurrent()
    }
    func pin(_ volume: DiscoveredVolume) {
        guard !operation.locksTarget else { return }
        defaults.set(volume.mountPoint, forKey: "targetMountPoint")
        defaults.set(volume.volumeUUID, forKey: "targetVolumeUUID")
        select(volume)
    }

    private func refreshCurrent() {
        let mount = mountPoint, g = generation, token = scanToken, id = selectedIdentity
        let scoped = ScopedCommandRunner(base: runner, cancellation: token)
        let probe = probeVolume
        work.async { [weak self] in
            let result = probe(mount, scoped)
            Task { @MainActor in
                guard let self, self.accepts(g, id, mount, token) else { return }
                switch result {
                case .success(let snap):
                    guard snap.volume.mountPoint == mount,
                          self.drives.first(where: { $0.mountPoint == mount }).map({ $0.volumeUUID == snap.volume.volumeUUID }) ?? false else {
                        self.lastError = "探针返回了不同的卷，请重新检测"
                        self.finishRefresh(); return
                    }
                    self.snapshot = snap; self.occupancy = snap.occupancy; self.lastError = nil
                    self.loadDirectories(g: g, id: id, mount: mount, token: token)
                case .failure(let error):
                    self.lastError = error.localizedDescription
                    self.finishRefresh()
                }
            }
        }
    }
    private func accepts(_ g: Int, _ id: VolumeIdentity?, _ mount: String, _ token: CancellationToken) -> Bool {
        g == generation && id == selectedIdentity && mount == mountPoint && !token.isCancelled && !operation.locksTarget
    }
    private func loadDirectories(g: Int, id: VolumeIdentity?, mount: String, token: CancellationToken) {
        guard directoriesVisible, let id else { finishRefresh(); return }
        if let cached = cache[id], now().timeIntervalSince(cached.0) < 300 {
            directories = cached.1; directoryIssue = nil; finishRefresh(); return
        }
        directoriesLoading = true
        let loader = directoryUsage, scoped = ScopedCommandRunner(base: runner, cancellation: token)
        work.async { [weak self] in
            let result = ProbeResult<[DirectoryUsage]>.capture { try loader(mount, scoped) }
            Task { @MainActor in
                guard let self, self.accepts(g, id, mount, token) else { return }
                self.directoriesLoading = false
                if let value = result.value, result.isComplete {
                    self.directories = value; self.cache[id] = (self.now(), value); self.directoryIssue = nil
                } else { self.directoryIssue = result.issues.joined(separator: "；") }
                self.finishRefresh()
            }
        }
    }

    nonisolated private static func probe(mount: String, runner: CommandRunner) -> Result<DiskSnapshot, Error> {
        Result {
            let vp = VolumeProbe(runner: runner)
            guard let volume = try vp.volume(at: mount) else { throw ProbeFailure("无法读取目标卷") }
            let hardware = (try? vp.hardware(physicalDisk: volume.physicalDisk)) ?? DriveHardware()
            let health = ProbeResult<SmartHealth>.capture { try HealthProbe(runner: runner).health(physicalDisk: volume.physicalDisk) }
            let cp = ConfigProbe(runner: runner)
            let indexing = try? cp.spotlightIndexing(mountPoint: mount)
            let quick = ProbeResult<OccupancyReport>.capture { try Occupancy(runner: runner).quickScan(mountPoint: mount, indexingOn: indexing) }
            let occupancy = quick.value ?? OccupancyReport(holders: [], scanDepth: .quick, scannedAt: Date(), duration: 0,
                                                           openFilesFound: nil, state: .unavailable, issues: quick.issues)
            return DiskSnapshot(volume: volume, hardware: hardware, health: health.value,
                healthUnavailableReason: health.issues.isEmpty ? nil : health.issues.joined(separator: "；"),
                checks: cp.checks(volume: volume, health: health.value), directories: [], occupancy: occupancy)
        }
    }

    func fullScan() {
        guard mounted, !operation.locksTarget, !occupancyScanning else { return }
        invalidateScans()
        occupancyScanning = true
        let mount = mountPoint, g = generation, id = selectedIdentity, token = scanToken
        let scoped = ScopedCommandRunner(base: runner, cancellation: token)
        work.async { [weak self] in
            let result = ProbeResult<OccupancyReport>.capture { try Occupancy(runner: scoped).fullScan(mountPoint: mount, indexingOn: nil) }
            Task { @MainActor in
                guard let self, self.accepts(g, id, mount, token) else { return }
                self.occupancy = result.value ?? OccupancyReport(holders: [], scanDepth: .full, scannedAt: Date(), duration: 0,
                    openFilesFound: nil, state: .unavailable, issues: result.issues)
                self.occupancyScanning = false
            }
        }
    }

    func eject() {
        guard mounted, !operation.locksTarget else { return }
        beginPreflight()
    }
    func retryPreflight() {
        guard operation == .awaitingConfirmation else { return }
        operationToken?.cancel()
        beginPreflight()
    }
    private func beginPreflight() {
        invalidateScans()
        operation = .preflight; screen = .ejecting
        ejectPlan = nil; ejectFailure = nil; lastError = nil; waitingForSystem = false
        ejectSteps = [.init(id: "scan", title: "只读预检：确认目标与占用", state: .running)]
        let token = CancellationToken()
        operationToken = token
        let mount = mountPoint, maker = makeFlow, runner = self.runner
        let expected = drives.first(where: { $0.mountPoint == mount }).map {
            TargetVolume(name: $0.name, mount: $0.mountPoint, device: $0.deviceIdentifier, uuid: $0.volumeUUID)
        }
        let operationQueue = ejectQueue
        // Barrier behind cancelled probes: our du/lsof must release their handles first.
        work.async { [weak self] in
            operationQueue.async { [weak self] in
                let flow = maker(runner, mount, token)
                flow.expectedVolume = expected
                self?.wire(flow, token: token)
                let outcome = flow.run(indexingOn: nil)
                Task { @MainActor in self?.receive(outcome, token: token) }
            }
        }
    }
    nonisolated private func wire(_ flow: EjectFlow, token: CancellationToken) {
        flow.onUpdate = { [weak self] steps in
            Task { @MainActor in
                guard let self, self.operationToken === token, self.operation.locksTarget else { return }
                self.ejectSteps = steps
            }
        }
        flow.onCommit = { [weak self] in
            Task { @MainActor in
                guard let self, self.operationToken === token, self.operation == .preflight || self.operation == .executing || self.operation == .cancelling else { return }
                self.waitingForSystem = true
                self.operation = .executing
            }
        }
    }
    func confirmEject(systemOnly: Bool = false) {
        guard operation == .awaitingConfirmation, let plan = ejectPlan,
              let token = operationToken, !token.isCancelled else { return }
        operation = .executing; screen = .ejecting
        let flow = makeFlow(runner, mountPoint, token)
        wire(flow, token: token)
        ejectQueue.async { [weak self] in
            let outcome = flow.execute(plan, systemOnly: systemOnly)
            Task { @MainActor in self?.receive(outcome, token: token) }
        }
    }
    func cancelEject() {
        guard canCancel, let token = operationToken else { return }
        token.cancel()
        if operation == .awaitingConfirmation {
            operation = .finished; ejectPlan = nil; screen = .connected
            ejectFailure = "已取消预览，未执行处理操作"
            refresh()
        } else { operation = .cancelling }
    }
    private func receive(_ outcome: EjectFlow.Outcome, token: CancellationToken) {
        guard operationToken === token else { return }
        if token.isCancelled {
            operation = .finished; screen = .connected; ejectPlan = nil
            if case .aborted(let why) = outcome { ejectFailure = why }
            else { ejectFailure = "操作已中止；已发出的请求无法撤销" }
            refresh(); return
        }
        switch outcome {
        case .preview(let plan):
            ejectPlan = plan; operation = .awaitingConfirmation; screen = .preview
            waitingForSystem = false
        case .ejected(let duration, let apps, let daemons):
            operation = .finished; screen = .ejected(duration, apps: apps, daemons: daemons)
            verifiedEjected = screen
            mounted = false; snapshot = nil; directories = []; occupancy = nil; ejectPlan = nil
            cache.removeAll()
            lastEjectSummary = Self.summary(duration, apps: apps, daemons: daemons)
        case .aborted(let why):
            operation = .finished; screen = .connected; ejectFailure = why; ejectPlan = nil
            refresh()
        }
    }
    nonisolated static func summary(_ duration: TimeInterval, apps: Int, daemons: Int) -> String {
        "耗时 \(String(format: "%.1f", duration)) 秒 · 确认退出 \(apps) 个应用、停止 \(daemons) 个服务进程"
    }
    func dismissEjectFailure() { ejectFailure = nil }
    func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    func openSettings(_ url: String) { if let u = URL(string: url) { NSWorkspace.shared.open(u) } }
    func quit() { guard !operation.locksTarget else { return }; NSApplication.shared.terminate(nil) }
    static let mainWindowID = "devdisk.main"
}
