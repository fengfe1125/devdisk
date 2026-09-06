import AppKit
import DevDiskKit

// `--snapshot <dir> [mount]` renders the panel screens to PNG instead of starting
// the menu bar agent; a menu bar app has no ordinary window to screenshot.
if CommandLine.arguments.contains("--eject") {
    MainActor.assumeIsolated { _ = Snapshot.runEject(arguments: CommandLine.arguments) }
    exit(0)
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
