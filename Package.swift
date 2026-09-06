// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DevDisk",
    platforms: [.macOS(.v14)],
    targets: [
        // Everything lives here so tests can reach it with @testable, avoiding both
        // the executable-target testing pitfalls and a wall of `public` annotations.
        .target(
            name: "DevDiskKit",
            path: "Sources/DevDiskKit",
            // Vector menu bar artwork, read at runtime through Bundle.module.
            // package.sh must copy the generated resource bundle into the .app or
            // Bundle.module traps at launch.
            resources: [.copy("Resources/MenuBarIcons")]
        ),
        // Thin entry point: SwiftUI's @main cannot live in a library target.
        .executableTarget(
            name: "DevDisk",
            dependencies: ["DevDiskKit"],
            path: "Sources/DevDisk"
        ),
        .testTarget(
            name: "DevDiskKitTests",
            dependencies: ["DevDiskKit"],
            path: "Tests/DevDiskKitTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
