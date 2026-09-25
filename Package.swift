// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BaconTrackerMenu",
    platforms: [.macOS(.v13)],
    targets: [
        // Everything that can be decided without AppKit or a live process:
        // the launch command, dashboard.md, the stats payload, port ownership,
        // the log file. Kept apart so it can be unit tested.
        .target(
            name: "BaconTrackerMenuCore",
            path: "Sources/BaconTrackerMenuCore"
        ),
        .executableTarget(
            name: "BaconTrackerMenu",
            dependencies: ["BaconTrackerMenuCore"],
            path: "Sources/BaconTrackerMenu"
        ),
        .testTarget(
            name: "BaconTrackerMenuCoreTests",
            dependencies: ["BaconTrackerMenuCore"],
            path: "Tests/BaconTrackerMenuCoreTests"
        ),
    ]
)
