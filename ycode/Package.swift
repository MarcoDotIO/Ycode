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
        .executable(name: "ycode-simd", targets: ["ycode-simd"]),
        .executable(name: "ycode", targets: ["ycode"]),
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
        .target(name: "YcodeHostServices", dependencies: ["YcodeDarwinABI", "YcodeDarwinKernel", "YcodeXPC"]),
        // Stage 8a (specs/simulator/stage8-contract.md §5): the Metal host service and its Vulkan back end
        .target(name: "YcodeMetalHost", dependencies: ["YcodeXPC", "YcodeDarwinKernel"]),
        .target(name: "CVulkan"),
        .target(name: "YcodeVulkan", dependencies: ["CVulkan", "YcodeMetalHost"]),
        .target(name: "CKVM"),
        .target(name: "YcodeHypervisor", dependencies: ["CKVM", "YcodeDarwinABI"]),
        .executableTarget(name: "ycode-simd", dependencies: ["YcodeHypervisor", "YcodeDarwinABI", "YcodeDarwinKernel", "YcodeMachO", "YcodeXPC", "YcodeHostServices", "YcodeMetalHost", "YcodeVulkan"]),
        .executableTarget(name: "ycode", dependencies: ["YcodePlist", "YcodeProject", "YcodeWorkspace", "YcodeSettings", "YcodeMachO"]),
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
        .testTarget(name: "YcodeHostServicesTests", dependencies: ["YcodeHostServices", "YcodeDarwinKernel", "YcodeXPC"]),
    ]
)
