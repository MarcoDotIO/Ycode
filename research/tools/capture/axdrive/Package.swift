// swift-tools-version:6.0
// axdrive: drives one app through the Accessibility API and events posted to
// that app's process only. See ../README.md.
import PackageDescription

let package = Package(
    name: "axdrive",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "axdrive", path: "Sources/axdrive")
    ],
    swiftLanguageModes: [.v5]
)
