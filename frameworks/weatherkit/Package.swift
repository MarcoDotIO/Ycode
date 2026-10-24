// swift-tools-version:6.0
//
// ycode-weatherkit: an open, Linux-buildable WeatherKit written from
// specs/frameworks/weatherkit/ under the clean-room protocol of AGENTS.md.
//
// The library module is named `WeatherKit` (an interop identifier) so that
// existing `import WeatherKit` code compiles against it. On Linux the package
// also provides a minimal `CoreLocation` module with the location types the
// WeatherKit API needs; on Apple platforms the system CoreLocation is used
// and the shim target is not part of the build.
import PackageDescription

#if os(Linux) || os(Windows) || os(Android) || os(FreeBSD) || os(OpenBSD)
let coreLocationTargets: [Target] = [
    .target(name: "CoreLocation", path: "Sources/CoreLocation")
]
let coreLocationProducts: [Product] = [
    .library(name: "CoreLocation", targets: ["CoreLocation"])
]
let weatherKitDependencies: [Target.Dependency] = ["CoreLocation"]
#else
let coreLocationTargets: [Target] = []
let coreLocationProducts: [Product] = []
let weatherKitDependencies: [Target.Dependency] = []
#endif

let package = Package(
    name: "ycode-weatherkit",
    platforms: [.macOS(.v15), .iOS(.v18), .tvOS(.v18), .watchOS(.v11), .visionOS(.v2)],
    products: coreLocationProducts + [
        .library(name: "WeatherKit", targets: ["WeatherKit"])
    ],
    dependencies: [
        // Apache-2.0. ES256 developer tokens for the Apple REST backend (R4).
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.2")
    ],
    targets: coreLocationTargets + [
        .target(
            name: "WeatherKit",
            dependencies: weatherKitDependencies + [.product(name: "Crypto", package: "swift-crypto")],
            path: "Sources/WeatherKit",
            resources: [.copy("Resources/Fixtures")]
        ),
        .testTarget(
            name: "WeatherKitTests",
            dependencies: ["WeatherKit", .product(name: "Crypto", package: "swift-crypto")],
            path: "Tests/WeatherKitTests"
        ),
    ]
)
