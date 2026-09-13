import AppKit
import DevDiskKit

// `--snapshot <dir> [mount]` renders the panel screens to PNG instead of starting
// the menu bar agent; a menu bar app has no ordinary window to screenshot.
if CommandLine.arguments.contains("--selftest") {
    let ok = MainActor.assumeIsolated { Snapshot.selftest() }
    exit(ok ? 0 : 1)
}

if CommandLine.arguments.contains("--check-update") {
    // UpdateChecker is @MainActor, so the work has to run on the main thread —
    // which means the main thread must not be blocked waiting for it. Blocking on
    // a semaphore here deadlocks: the task can never be scheduled. Drive the run
    // loop instead so the MainActor keeps making progress.
    final class Flag: @unchecked Sendable { var done = false }
    let flag = Flag()

    Task { @MainActor in
        _ = await Snapshot.runUpdateCheck(arguments: CommandLine.arguments)
        flag.done = true
    }

    let deadline = Date().addingTimeInterval(30)
    while !flag.done && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    if !flag.done { FileHandle.standardError.write(Data("更新检查超时\n".utf8)) }
    exit(flag.done ? 0 : 1)
}

if CommandLine.arguments.contains("--eject") {
    let ok = MainActor.assumeIsolated { Snapshot.runEject(arguments: CommandLine.arguments) }
    exit(ok ? 0 : 1)
}

if CommandLine.arguments.contains("--snapshot-demo") {
    NSApplication.shared.setActivationPolicy(.prohibited)
    final class SnapshotFlag { var done = false; var ok = false }
    let flag = SnapshotFlag()
    Task { @MainActor in
        flag.ok = await Snapshot.runDemo(arguments: CommandLine.arguments)
        flag.done = true
    }
    let deadline = Date().addingTimeInterval(45)
    while !flag.done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    exit(flag.done && flag.ok ? 0 : 1)
}

if CommandLine.arguments.contains("--snapshot") {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    MainActor.assumeIsolated {
        _ = Snapshot.run(arguments: CommandLine.arguments)
    }
    exit(0)
}

// SwiftUI's @main cannot live in a library target, so the App type is defined in
// DevDiskKit and started from here.
DevDiskApp.main()
