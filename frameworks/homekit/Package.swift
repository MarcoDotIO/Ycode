// swift-tools-version: 6.0
// ycode-homekit: open, Linux-buildable HomeKit written from specs/frameworks/homekit/.
import PackageDescription

let package = Package(
    name: "ycode-homekit",
    platforms: [.macOS(.v14)],
    products: [
        // The library module carries the Apple framework's module name (an
        // interop identifier) so that `import HomeKit` source compiles.
        .library(name: "HomeKit", targets: ["HomeKit"]),
    ],
    targets: [
        .target(
            name: "HomeKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "HomeKitTests",
            dependencies: ["HomeKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
