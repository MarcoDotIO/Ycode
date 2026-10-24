// swift-tools-version: 6.0
//
// ycode-swiftui ("OpenViews"): a clean-room, Linux-buildable implementation of
// SwiftUI's value types and layout system, written from
// specs/frameworks/swiftui/ (see README.md in this directory).
//
// Module names. `SwiftUI` and `SwiftUICore` are interop identifiers: on Linux
// (and other non-Apple hosts) the library modules carry exactly those names so
// that `import SwiftUI` compiles unchanged. On Apple hosts those names belong
// to the system frameworks, so the same sources build as `OpenViews` /
// `OpenViewsCore` instead (and define OPENVIEWS_RENAMED so that re-exports and
// tests import the right name). The choice is made from the host that
// evaluates this manifest; cross-compiling from macOS to Linux is not
// supported by this switch.
import PackageDescription

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
let coreModule = "OpenViewsCore"
let uiModule = "OpenViews"
let renamed: [SwiftSetting] = [.define("OPENVIEWS_RENAMED")]
#else
let coreModule = "SwiftUICore"
let uiModule = "SwiftUI"
let renamed: [SwiftSetting] = []
#endif

let package = Package(
    name: "ycode-swiftui",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: uiModule, targets: [uiModule]),
        .library(name: coreModule, targets: [coreModule]),
        .library(name: "OVText", targets: ["OVText"]),
    ],
    targets: [
        // Fonts, shaping, line breaking, bidi and paragraph layout (round R4).
        // Bundles Noto Sans (SIL OFL 1.1, Resources/Fonts/OFL.txt).
        .target(name: "OVText", path: "Sources/OVText", resources: [.copy("Resources/Fonts")]),
        .target(name: coreModule, dependencies: ["OVText"], path: "Sources/SwiftUICore", swiftSettings: renamed),
        .target(name: uiModule, dependencies: [.target(name: coreModule)],
                path: "Sources/SwiftUI", swiftSettings: renamed),
        .testTarget(name: "OpenViewsTests",
                    dependencies: [.target(name: coreModule), .target(name: uiModule), "OVText"],
                    path: "Tests/OpenViewsTests", swiftSettings: renamed),
    ]
)
