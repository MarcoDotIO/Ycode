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
        .library(name: "YcodeDarwinABI", targets: ["YcodeDarwinABI"]),
        .library(name: "YcodeDarwinKernel", targets: ["YcodeDarwinKernel"]),
        .library(name: "YcodeXPC", targets: ["YcodeXPC"]),
        .library(name: "YcodeSimFeatures", targets: ["YcodeSimFeatures"]),
        .executable(name: "ycode-simd", targets: ["ycode-simd"]),
        .executable(name: "ycode", targets: ["ycode"]),
        .library(name: "YcodeBuild", targets: ["YcodeBuild"]),
        .library(name: "YcodeDebug", targets: ["YcodeDebug"]),
        .library(name: "YcodeLanguage", targets: ["YcodeLanguage"]),
        .library(name: "YcodeSubprocess", targets: ["YcodeSubprocess"]),
        .library(name: "YcodeAssistant", targets: ["YcodeAssistant"]),
    ],
    targets: [
        .target(name: "YcodePlist"),
        .target(name: "YcodeProject", dependencies: ["YcodePlist"]),
        .target(name: "YcodeWorkspace", dependencies: ["YcodeProject"]),
        .target(name: "YcodeSettings", dependencies: ["YcodeProject"]),
        .target(name: "YcodeMachO"),
        // Simulator stage 2 (specs/simulator/vm-shim-protocol.md)
        .target(name: "YcodeDarwinABI"),
        .target(name: "YcodeDarwinKernel", dependencies: ["YcodeDarwinABI"]),
        .target(name: "YcodeXPC"),
        // Host services the VMM offers the guest (stage 7: IOSurface)
        .target(name: "YcodeHostServices", dependencies: ["YcodeDarwinABI", "YcodeDarwinKernel", "YcodeXPC", "CYcodeCamera"]),
        // The host camera layer's V4L2 access, JPEG decoder and pixel conversion (specs/simulator/camera-host.md)
        .target(name: "CYcodeCamera", linkerSettings: [.linkedLibrary("m", .when(platforms: [.linux]))]),
        // Stage 8a (specs/simulator/stage8-contract.md §5): the Metal host service and its Vulkan back end
        .target(name: "YcodeMetalHost", dependencies: ["YcodeXPC", "YcodeDarwinKernel"]),
        .target(name: "CVulkan"),
        .target(name: "YcodeVulkan", dependencies: ["CVulkan", "YcodeMetalHost"]),
        .target(name: "CKVM"),
        .target(name: "YcodeHypervisor", dependencies: ["CKVM", "YcodeDarwinABI"]),
        // The live display stream and viewer input (specs/simulator/display-stream.md)
        .target(name: "CYcodeCodec", linkerSettings: [.linkedLibrary("dl", .when(platforms: [.linux]))]),
        .target(name: "YcodeDisplayStream"),
        // The simulator's settings features (specs/simulator/simulator-features.md, "Ycode implementation")
        .target(name: "YcodeSimFeatures"),
        .testTarget(name: "YcodeSimFeaturesTests", dependencies: ["YcodeSimFeatures"]),
        // The device windows' model: frames, zoom, the hub's sidebar, commands (specs/ide/device-hub.md, "Ycode implementation")
        .target(name: "YcodeDeviceModel"),
        .testTarget(name: "YcodeDeviceModelTests", dependencies: ["YcodeDeviceModel"]),
        .executableTarget(name: "ycode-simd", dependencies: ["YcodeHypervisor", "YcodeDarwinABI", "YcodeDarwinKernel", "YcodeMachO", "YcodeXPC", "YcodeHostServices", "YcodeMetalHost", "YcodeVulkan", "YcodeDisplayStream", "CYcodeCodec", "YcodeSimFeatures"]),
        .executableTarget(name: "ycode", dependencies: ["YcodePlist", "YcodeProject", "YcodeWorkspace", "YcodeSettings", "YcodeMachO", "YcodeBuild", "YcodeDebug"]),
        // IDE (specs/ide/): build engines and the debug-adapter client
        // Subprocess runs and the debug-build main-thread guard.
        .target(name: "YcodeSubprocess"),
        .testTarget(name: "YcodeSubprocessTests", dependencies: ["YcodeSubprocess"]),
        // The coding assistant's model providers, conversations and prompts (specs/ide/coding-assistant.md)
        .target(name: "YcodeAssistant", dependencies: ["YcodeSubprocess"]),
        .testTarget(name: "YcodeAssistantTests", dependencies: ["YcodeAssistant", "YcodeSubprocess"]),
        .target(name: "YcodeBuild", dependencies: ["YcodeProject", "YcodePlist", "YcodeWorkspace", "YcodeSubprocess"]),
        .target(name: "YcodeDebug", dependencies: ["YcodeSubprocess"]),
        .testTarget(name: "YcodeBuildTests", dependencies: ["YcodeBuild"]),
        .testTarget(name: "YcodeDebugTests", dependencies: ["YcodeDebug"]),
        // Language services (specs/ide/language.md): LSP client for sourcekit-lsp
        .target(name: "YcodeLanguage", dependencies: ["YcodeDebug", "YcodeSubprocess"]),
        .testTarget(name: "YcodeLanguageTests", dependencies: ["YcodeLanguage", "YcodeDebug"]),
        .testTarget(name: "YcodePlistTests", dependencies: ["YcodePlist"]),
        .testTarget(name: "YcodeProjectTests", dependencies: ["YcodeProject"], resources: [.copy("Fixtures")]),
        .testTarget(name: "YcodeWorkspaceTests", dependencies: ["YcodeWorkspace"], resources: [.copy("Fixtures")]),
        .testTarget(name: "YcodeSettingsTests", dependencies: ["YcodeSettings"]),
        .testTarget(name: "YcodeMachOTests", dependencies: ["YcodeMachO"]),
        .testTarget(name: "YcodeDarwinABITests", dependencies: ["YcodeDarwinABI"]),
        .testTarget(name: "YcodeDarwinKernelTests", dependencies: ["YcodeDarwinKernel"]),
        .testTarget(name: "YcodeXPCTests", dependencies: ["YcodeXPC"]),
        .testTarget(name: "YcodeMetalHostTests", dependencies: ["YcodeMetalHost", "YcodeXPC", "YcodeDarwinKernel"]),
        .testTarget(name: "YcodeVulkanTests", dependencies: ["YcodeVulkan"]),
        .testTarget(name: "YcodeHostServicesTests", dependencies: ["YcodeHostServices", "YcodeDarwinKernel", "YcodeXPC", "CYcodeCamera", "CYcodeCodec"]),
        .testTarget(name: "YcodeSimdTests", dependencies: ["ycode-simd"]),
        .testTarget(name: "YcodeDisplayStreamTests", dependencies: ["YcodeDisplayStream", "CYcodeCodec"]),
    ]
)

// The AppKit shell and app exist only on macOS.
#if os(macOS)
package.products += [.executable(name: "YcodeApp", targets: ["YcodeApp"]),
                     .executable(name: "ycode-sim-viewer", targets: ["ycode-sim-viewer"])]
package.targets += [
    // The simulator viewer (display-stream.md; scripts/ycode-sim-try)
    // The device windows (compact window, canvas, frame, controls; specs/ide/device-hub.md), shared by the viewer and the IDE
    .target(name: "YcodeDeviceUI", dependencies: ["YcodeDisplayStream", "YcodeSimFeatures", "YcodeDeviceModel"]),
    .testTarget(name: "YcodeDeviceUITests", dependencies: ["YcodeDeviceUI", "YcodeDeviceModel", "YcodeDisplayStream"]),
    .executableTarget(name: "ycode-sim-viewer", dependencies: ["YcodeDisplayStream", "YcodeSimFeatures", "YcodeDeviceModel", "YcodeDeviceUI"]),
    .target(name: "YcodeUI", dependencies: ["YcodeProject", "YcodeWorkspace", "YcodeSettings", "YcodeBuild", "YcodeDebug", "YcodeLanguage", "YcodeXcodebuild", "YcodeSubprocess", "YcodeAssistant", "YcodeSimFeatures", "YcodeDeviceModel", "YcodeDeviceUI"]),
    .executableTarget(name: "YcodeApp", dependencies: ["YcodeUI"]),
    .testTarget(name: "YcodeUITests", dependencies: ["YcodeUI", "YcodeSimFeatures", "YcodeDeviceModel", "YcodeDeviceUI", "YcodeBuild", "YcodeDebug", "YcodeLanguage", "YcodeXcodebuild", "YcodeSubprocess", "YcodeAssistant"]),
]
#endif

// ycodebuild: an xcodebuild-compatible command line (specs/xcodebuild/).
package.products += [.executable(name: "ycodebuild", targets: ["ycodebuild-cli"])]
package.targets += [
    .target(name: "YcodeXcodebuild", dependencies: ["YcodeProject", "YcodeWorkspace", "YcodeSettings", "YcodePlist", "YcodeBuild", "YcodeSubprocess"]),
    // Target and directory are not named "ycodebuild": that collides with YcodeBuild on case-insensitive file systems.
    .executableTarget(name: "ycodebuild-cli", dependencies: ["YcodeXcodebuild"], path: "Sources/ycodebuild-cli"),
    .testTarget(name: "YcodeXcodebuildTests", dependencies: ["YcodeXcodebuild", "YcodeProject"]),
]
