// swift-tools-version: 6.0
// ycode-eventkit: open, Linux-buildable EventKit written from specs/frameworks/eventkit/.
import PackageDescription

let package = Package(
    name: "ycode-eventkit",
    platforms: [.macOS(.v14)],
    products: [
        // The library module carries the Apple framework's module name (an
        // interop identifier) so that `import EventKit` source compiles.
        .library(name: "EventKit", targets: ["EventKit"]),
    ],
    targets: [
        // The system SQLite 3 library (public domain): libsqlite3 from the
        // macOS SDK, libsqlite3-dev on Linux.
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite",
            providers: [.apt(["libsqlite3-dev"])]
        ),
        .target(
            name: "EventKit",
            dependencies: ["CSQLite"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "EventKitTests",
            dependencies: ["EventKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
