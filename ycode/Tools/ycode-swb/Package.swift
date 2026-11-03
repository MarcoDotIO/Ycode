// swift-tools-version: 6.0
// ycode-swb: a small helper that talks to swift-build's build service as a
// library, for queries its `swbuild` command line does not offer (exported
// build settings). It is a separate package so that the Ycode package itself
// takes no dependency on swift-build. See specs/xcodebuild/show-build-settings.md.
//
//     swift build --product ycode-swb
//     swift build --product SWBBuildServiceBundle
//
// ycodebuild finds the helper through YCODE_SWB, then PATH, then next to
// itself. The pinned revision is the head of swift-build's release/6.4.x
// branch: its exported settings matched the reference tool exactly on the
// test corpus, while main exports 16 newer settings (see
// specs/xcodebuild/show-build-settings.md §6).
import PackageDescription

let package = Package(
    name: "ycode-swb",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-build", revision: "5d44ed6ba16c53d56cac5fc6a2d572635aa4a979"),
    ],
    targets: [
        // Sources/YcodeSigning is a symbolic link to ycode/Sources/YcodeSigning
        // (Foundation only): the signing logic is tested in the Ycode package.
        .target(name: "YcodeSigning"),
        // Sources/YcodeRelease is a link to ycode/Sources/YcodeRelease, the release's version.
        .target(name: "YcodeRelease"),
        .executableTarget(name: "ycode-swb", dependencies: [.product(name: "SwiftBuild", package: "swift-build"), "YcodeSigning", "YcodeRelease"]),
    ]
)
