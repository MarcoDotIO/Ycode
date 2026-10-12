// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Ycode",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "YcodePlist", targets: ["YcodePlist"]),
        .library(name: "YcodeProject", targets: ["YcodeProject"]),
        .library(name: "YcodeWorkspace", targets: ["YcodeWorkspace"]),
        .library(name: "YcodeSettings", targets: ["YcodeSettings"]),
        .library(name: "YcodeMachO", targets: ["YcodeMachO"]),
        .executable(name: "ycode", targets: ["ycode"]),
    ],
    targets: [
        .target(name: "YcodePlist"),
        .target(name: "YcodeProject", dependencies: ["YcodePlist"]),
        .target(name: "YcodeWorkspace", dependencies: ["YcodeProject"]),
        .target(name: "YcodeSettings", dependencies: ["YcodeProject"]),
        .target(name: "YcodeMachO"),
        .executableTarget(name: "ycode", dependencies: ["YcodePlist", "YcodeProject", "YcodeWorkspace", "YcodeSettings", "YcodeMachO"]),
        .testTarget(name: "YcodePlistTests", dependencies: ["YcodePlist"]),
        .testTarget(name: "YcodeProjectTests", dependencies: ["YcodeProject"], resources: [.copy("Fixtures")]),
        .testTarget(name: "YcodeWorkspaceTests", dependencies: ["YcodeWorkspace"], resources: [.copy("Fixtures")]),
        .testTarget(name: "YcodeSettingsTests", dependencies: ["YcodeSettings"]),
        .testTarget(name: "YcodeMachOTests", dependencies: ["YcodeMachO"]),
    ]
)
