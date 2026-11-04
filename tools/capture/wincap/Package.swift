// swift-tools-version:6.0
// wincap: records one app window (or one app's windows) with ScreenCaptureKit.
// Generic: it knows nothing about any particular app. See ../README.md.
import PackageDescription

let package = Package(
    name: "wincap",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "wincap", path: "Sources/wincap")
    ],
    swiftLanguageModes: [.v5]
)
