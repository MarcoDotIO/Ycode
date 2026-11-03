// swift-tools-version: 6.0
// Gauge's Linux sample (specs/ide/profiler.md §10): a SwiftPM executable whose
// hot function is known, for `ycode profile record --linux`.
import PackageDescription

let package = Package(
    name: "HotLoop",
    targets: [.executableTarget(name: "HotLoop")],
    swiftLanguageModes: [.v5]
)
