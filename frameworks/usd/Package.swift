// swift-tools-version:6.0
//
// ycode-usd: a Swift-native, Linux-buildable USD library (layers, USDA text,
// USDC crate binary, USDZ packages, a composed stage view, UsdShade/MaterialX
// networks). Written from Pixar's public OpenUSD documentation and open source
// (TOST 1.0) and the MaterialX specification and libraries (Apache-2.0) under
// the clean-room protocol of AGENTS.md. Shared by the Ycode Scene Composer
// (`composer/`) and, later, the OpenReality package.
//
// No third-party code and no system libraries: LZ4 block coding, the crate
// integer coding, ZIP, and a small XML reader are our own implementations.
import PackageDescription

let package = Package(
    name: "ycode-usd",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "USDCore", targets: ["USDCore"]),
        .library(name: "USDStage", targets: ["USDStage"]),
        .library(name: "USDShade", targets: ["USDShade"]),
    ],
    targets: [
        // Paths, values, specs and layers (the Sdf level), plus the three
        // file formats.
        .target(name: "USDCore", path: "Sources/USDCore"),
        // Composition: layer stacks, sublayers, references, payloads,
        // inherits, specializes and variants, enough for an editor hierarchy.
        .target(name: "USDStage", dependencies: ["USDCore"], path: "Sources/USDStage"),
        // UsdShade networks and the MaterialX node definition library.
        .target(
            name: "USDShade",
            dependencies: ["USDCore", "USDStage"],
            path: "Sources/USDShade",
            resources: [.copy("Resources/MaterialX")]
        ),
        .testTarget(
            name: "USDCoreTests",
            dependencies: ["USDCore"],
            path: "Tests/USDCoreTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "USDStageTests", dependencies: ["USDCore", "USDStage"], path: "Tests/USDStageTests"),
        .testTarget(name: "USDShadeTests", dependencies: ["USDCore", "USDStage", "USDShade"], path: "Tests/USDShadeTests"),
    ]
)
