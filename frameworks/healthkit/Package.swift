// swift-tools-version:6.0
// ycode-healthkit: clean-room open HealthKit (see README.md and specs/frameworks/healthkit/).
import PackageDescription

let package = Package(
    name: "ycode-healthkit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HealthKit", targets: ["HealthKit"]),
    ],
    targets: [
        // Thin wrapper over the system libsqlite3 (macOS SDK / libsqlite3-dev on Linux).
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite", providers: [.apt(["libsqlite3-dev"])]),
        .target(name: "HealthKit", dependencies: ["CSQLite"], path: "Sources/HealthKit"),
        .testTarget(name: "HealthKitTests", dependencies: ["HealthKit"], path: "Tests/HealthKitTests"),
    ]
)
