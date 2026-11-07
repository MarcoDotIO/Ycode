// swift-tools-version: 6.0
import Foundation
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
        .library(name: "YcodeCompletion", targets: ["YcodeCompletion"]),
        // Gauge, the profiler (specs/ide/profiler.md): trace format, analysis, Linux recording
        .library(name: "YcodeProfiler", targets: ["YcodeProfiler"]),
        // Gauge's in-process sampler for Linux processes (LD_PRELOAD; profiler.md §3.2)
        .library(name: "YcodeGaugeAgent", type: .dynamic, targets: ["CYcodeGaugeAgent"]),
        .library(name: "YcodePreviews", targets: ["YcodePreviews"]),
    ],
    targets: [
        .target(name: "YcodePlist"),
        .target(name: "YcodeProject", dependencies: ["YcodePlist"]),
        .target(name: "YcodeWorkspace", dependencies: ["YcodeProject"]),
        .target(name: "YcodeSettings", dependencies: ["YcodeProject"]),
        .target(name: "YcodeMachO"),
        // Gauge (specs/ide/profiler.md)
        .target(name: "CYcodeGauge"),
        .target(name: "CYcodeGaugeAgent"),
        .target(name: "YcodeProfiler", dependencies: ["YcodeMachO", "CYcodeGauge"]),
        .testTarget(name: "YcodeProfilerTests", dependencies: ["YcodeProfiler", "YcodeMachO"]),
        // Simulator stage 2 (specs/simulator/vm-shim-protocol.md)
        .target(name: "YcodeDarwinABI"),
        .target(name: "YcodeDarwinKernel", dependencies: ["YcodeDarwinABI"]),
        .target(name: "YcodeXPC"),
        // Host services the VMM offers the guest (stage 7: IOSurface)
        .target(name: "YcodeHostServices", dependencies: ["YcodeDarwinABI", "YcodeDarwinKernel", "YcodeXPC", "CYcodeCamera", "YcodeDisplayStream"]),
        // The host camera layer's V4L2 access, JPEG decoder and pixel conversion (specs/simulator/camera-host.md)
        .target(name: "CYcodeCamera", linkerSettings: [.linkedLibrary("m", .when(platforms: [.linux]))]),
        // Stage 8a (specs/simulator/stage8-contract.md §5): the Metal host service and its Vulkan back end
        .target(name: "YcodeMetalHost", dependencies: ["YcodeXPC", "YcodeDarwinKernel"]),
        .target(name: "CVulkan"),
        .target(name: "YcodeVulkan", dependencies: ["CVulkan", "YcodeMetalHost"], exclude: ["shaders"]),
        .target(name: "CKVM"),
        .target(name: "YcodeHypervisor", dependencies: ["CKVM", "YcodeDarwinABI"]),
        // The live display stream and viewer input (specs/simulator/display-stream.md)
        .target(name: "CYcodeCodec", linkerSettings: [.linkedLibrary("dl", .when(platforms: [.linux]))]),
        // Low-latency H.264 through NVIDIA's NVENC / NVDEC, opened at run time (display-stream.md §14)
        .target(name: "CYcodeVideo", exclude: ["nvheaders/ffnvcodec/README.md"], cSettings: [.headerSearchPath("nvheaders")], linkerSettings: [.linkedLibrary("dl", .when(platforms: [.linux]))]),
        .target(name: "YcodeDisplayStream"),
        // The simulator's settings features (specs/simulator/simulator-features.md, "Ycode implementation")
        .target(name: "YcodeSimFeatures"),
        .testTarget(name: "YcodeSimFeaturesTests", dependencies: ["YcodeSimFeatures"]),
        // Shut-down edits of a device's HealthKit store: grants and seeded samples (specs/simulator/health-simulation.md, "Ycode implementation")
        .systemLibrary(name: "CSQLite"),
        .target(name: "YcodeHealthStore", dependencies: ["CSQLite", "YcodeSimFeatures"]),
        .testTarget(name: "YcodeHealthStoreTests", dependencies: ["YcodeHealthStore", "YcodeSimFeatures"]),
        // The device windows' model: frames, zoom, the hub's sidebar, commands (specs/ide/device-hub.md, "Ycode implementation")
        .target(name: "YcodeDeviceModel"),
        .testTarget(name: "YcodeDeviceModelTests", dependencies: ["YcodeDeviceModel"]),
        .executableTarget(name: "ycode-simd", dependencies: ["YcodeRelease", "YcodeHypervisor", "YcodeDarwinABI", "YcodeDarwinKernel", "YcodeMachO", "YcodeXPC", "YcodeHostServices", "YcodeMetalHost", "YcodeVulkan", "YcodeDisplayStream", "CYcodeCodec", "CYcodeVideo", "YcodeSimFeatures", "YcodeHealthStore", "YcodeProfiler", "YcodeDebug", "YcodeXRReprojection"]),
        .executableTarget(name: "ycode", dependencies: ["YcodeRelease", "YcodePlist", "YcodeProject", "YcodeWorkspace", "YcodeSettings", "YcodeMachO", "YcodeBuild", "YcodeDebug", "YcodePreviews", "YcodeProfiler", "YcodeBuildServer", "YcodeXcodebuild", "YcodeAssetCatalog", "YcodeIDECore", "YcodeStrings", "YcodeSimLink", "YcodeCompletion"]),
        // IDE (specs/ide/): build engines and the debug-adapter client
        // Subprocess runs and the debug-build main-thread guard.
        .target(name: "YcodeSubprocess"),
        .testTarget(name: "YcodeSubprocessTests", dependencies: ["YcodeSubprocess"]),
        // The coding assistant's model providers, conversations and prompts (specs/ide/coding-assistant.md)
        .target(name: "YcodeAssistant", dependencies: ["YcodeSubprocess"]),
        .testTarget(name: "YcodeAssistantTests", dependencies: ["YcodeAssistant", "YcodeSubprocess"]),
        // Predictive code completion: context, backends (Ollama, llama-server, OpenAI-compatible), shaping, the editor session (specs/ide/predictive-completion.md)
        .target(name: "YcodeCompletion", dependencies: ["YcodeAssistant"]),
        .testTarget(name: "YcodeCompletionTests", dependencies: ["YcodeCompletion", "YcodeAssistant"]),
        .target(name: "YcodeBuild", dependencies: ["YcodeProject", "YcodePlist", "YcodeWorkspace", "YcodeSubprocess"]),
        .target(name: "YcodeDebug", dependencies: ["YcodeSubprocess"]),
        .testTarget(name: "YcodeBuildTests", dependencies: ["YcodeBuild"]),
        // Previews (specs/ide/previews.md): discovery, payload and host generation, the update planner, the screen layout
        .target(name: "YcodePreviews", dependencies: ["YcodeBuild", "YcodeSubprocess"]),
        .testTarget(name: "YcodePreviewsTests", dependencies: ["YcodePreviews"]),
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
        .testTarget(name: "YcodeHostServicesTests", dependencies: ["YcodeHostServices", "YcodeDarwinKernel", "YcodeXPC", "CYcodeCamera", "CYcodeCodec", "YcodeDisplayStream"]),
        .testTarget(name: "YcodeSimdTests", dependencies: ["ycode-simd"]),
        .testTarget(name: "YcodeDisplayStreamTests", dependencies: ["YcodeDisplayStream", "CYcodeCodec"]),
        // The portable viewer: stream client, canvas, touches, layout, scripts (display-stream.md §13)
        .target(name: "YcodeRemoteViewer", dependencies: ["YcodeDisplayStream", "CYcodeCodec", "CYcodeVideo", "YcodeDeviceModel"]),
        .testTarget(name: "YcodeRemoteViewerTests", dependencies: ["YcodeRemoteViewer", "YcodeDisplayStream", "YcodeDeviceModel", "CYcodeCodec"]),
    ]
)

// The release's version (ycode/VERSION is the source of truth); every shipped tool's `--version`.
package.targets += [
    .target(name: "YcodeRelease"),
    .testTarget(name: "YcodeReleaseTests", dependencies: ["YcodeRelease"]),
]

// The AppKit shell and app exist only on macOS.
#if os(macOS)
package.products += [.executable(name: "YcodeApp", targets: ["YcodeApp"]),
                     .executable(name: "ycode-sim-viewer", targets: ["ycode-sim-viewer"]),
                     // The agent ycodebuild inserts into a test host app (specs/ide/testing.md, "Ycode implementation").
                     // SimGuestAgents/build-test-agent.sh builds the same sources for the iOS simulator.
                     .library(name: "YcodeTestAgent", type: .dynamic, targets: ["YcodeTestAgent", "CYcodeTestAgentLoader"])]
package.targets += [
    .target(name: "CYcodeTestAgentLoader"),
    .target(name: "YcodeTestAgent"),
    // The simulator viewer (display-stream.md; scripts/ycode-sim-try)
    // The device windows (compact window, canvas, frame, controls; specs/ide/device-hub.md), shared by the viewer and the IDE
    .target(name: "YcodeDeviceUI", dependencies: ["YcodeDisplayStream", "YcodeSimFeatures", "YcodeDeviceModel"]),
    .testTarget(name: "YcodeDeviceUITests", dependencies: ["YcodeDeviceUI", "YcodeDeviceModel", "YcodeDisplayStream"]),
    .executableTarget(name: "ycode-sim-viewer", dependencies: ["YcodeRelease", "YcodeDisplayStream", "YcodeSimFeatures", "YcodeDeviceModel", "YcodeDeviceUI", "YcodeRemoteViewer", "YcodeSimLink"]),
    .target(name: "YcodeUI", dependencies: ["YcodeMCP", "YcodeIDECore", "YcodeCompletion", "YcodePreviews", "YcodeProject", "YcodeWorkspace", "YcodeSettings", "YcodeBuild", "YcodeDebug", "YcodeLanguage", "YcodeXcodebuild", "YcodeSubprocess", "YcodeAssistant", "YcodeSimFeatures", "YcodeDeviceModel", "YcodeDeviceUI", "YcodeProfiler"]),
    .executableTarget(name: "YcodeApp", dependencies: ["YcodeRelease", "YcodeUI"]),
    .testTarget(name: "YcodeUITests", dependencies: ["YcodeMCP", "YcodeUI", "YcodeIDECore", "YcodeCompletion", "YcodePreviews", "YcodeDisplayStream", "YcodeSimFeatures", "YcodeDeviceModel", "YcodeDeviceUI", "YcodeBuild", "YcodeDebug", "YcodeLanguage", "YcodeXcodebuild", "YcodeSubprocess", "YcodeAssistant", "YcodeProfiler", "YcodeBuildServer", "YcodeIDEShell"]),
]
#else
// The Linux viewer: an SDL 3 window (loaded at run time) on the portable viewer (display-stream.md §13).
package.products += [.executable(name: "ycode-sim-viewer", targets: ["ycode-sim-viewer"]),
                     .library(name: "YcodeRemoteViewerSDL", targets: ["YcodeRemoteViewerSDL"])]
package.targets += [
    .target(name: "YcodeRemoteViewerSDL", dependencies: ["YcodeRemoteViewer", "YcodeDisplayStream", "YcodeDeviceModel", "YcodeSimLink"],
            linkerSettings: [.linkedLibrary("dl")]),
    .executableTarget(name: "ycode-sim-viewer", dependencies: ["YcodeRelease", "YcodeRemoteViewerSDL", "YcodeRemoteViewer", "YcodeDisplayStream"]),
]
#endif

// The simulator link (specs/simulator/sim-link.md): Ycode's own authenticated,
// encrypted connection between a client (the IDE, the viewer, `ycode sim
// remote`) and a simulator host's `ycode-simhost`: Noise XX handshakes with
// pinned Ed25519 identities, pairing codes, the control protocol, uploads and
// the UDP media channel. Cryptography from swift-crypto (Apache-2.0).
package.dependencies += [.package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0")]
package.products += [.library(name: "YcodeSimLink", targets: ["YcodeSimLink"]),
                     .executable(name: "ycode-simhost", targets: ["ycode-simhost"])]
package.targets += [
    .target(name: "YcodeSimLink", dependencies: ["YcodeDisplayStream", .product(name: "Crypto", package: "swift-crypto")]),
    .testTarget(name: "YcodeSimLinkTests", dependencies: ["YcodeSimLink", "YcodeDisplayStream"]),
    .executableTarget(name: "ycode-simhost", dependencies: ["YcodeRelease", "YcodeSimLink"]),
]

// The headset viewer (specs/simulator/xr-viewer.md): a visionOS device in an
// OpenXR headset. CYcodeOpenXR opens the Khronos OpenXR loader and the Vulkan
// loader at run time (headers vendored: OpenXR-SDK 1.1.47, Apache-2.0 OR MIT;
// the CVulkan target's Vulkan headers); no runtime is linked. On macOS it
// builds as stubs and the viewer reports that OpenXR is not offered.
package.products += [.executable(name: "ycode-xr-viewer", targets: ["ycode-xr-viewer"])]
package.targets += [
    .target(name: "CYcodeOpenXR", exclude: ["openxr/LICENSE"], linkerSettings: [.linkedLibrary("dl", .when(platforms: [.linux]))]),
    .target(name: "YcodeXRViewer", dependencies: ["CYcodeOpenXR", "CYcodeVideo", "CYcodeCodec", "YcodeDisplayStream", "YcodeRemoteViewer", "YcodeXRReprojection"]),
    .executableTarget(name: "ycode-xr-viewer", dependencies: ["YcodeRelease", "YcodeXRViewer", "YcodeSimLink", "YcodeDisplayStream"]),
    .testTarget(name: "YcodeXRViewerTests", dependencies: ["YcodeXRViewer", "YcodeDisplayStream", "YcodeRemoteViewer", "CYcodeCodec", "CYcodeOpenXR", "CYcodeVideo"]),
]

// Depth re-projection for the headset viewer (specs/simulator/xr-depth.md):
// the depth codec, the re-projection math, the CPU reference warp and, in
// CYcodeXRReprojection, the GPU path (Vulkan through vkGetInstanceProcAddr on
// the viewer's OpenXR device, or a device of its own for tests; Ycode's own
// GLSL, compiled once to SPIR-V by scripts/xr-depth-shaders.sh). Builds and
// tests everywhere; the GPU tests run where a Vulkan loader is installed.
package.targets += [
    .target(name: "CYcodeXRReprojection", exclude: ["shaders"], linkerSettings: [.linkedLibrary("dl", .when(platforms: [.linux])), .linkedLibrary("pthread", .when(platforms: [.linux]))]),
    .target(name: "YcodeXRReprojection", dependencies: ["CYcodeXRReprojection", "CYcodeCodec", "YcodeDisplayStream"]),
    .testTarget(name: "YcodeXRReprojectionTests", dependencies: ["YcodeXRReprojection", "YcodeDisplayStream", "CYcodeVideo"]),
]

// The editor's portable syntax layer (specs/ide/source-editor.md, "Ycode
// implementation"): highlighting tokens for Swift (swift-syntax's parser,
// Apache-2.0) and hand-written line lexers for the other languages, the
// incremental highlighter, the bracket structure and the typing rules.
// Builds and tests on macOS and Linux; YcodeIDECore and the editors use it.
package.dependencies += [.package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "604.0.0")]
package.products += [.library(name: "YcodeSyntax", targets: ["YcodeSyntax"])]
package.targets += [
    .target(name: "YcodeSyntax", dependencies: [.product(name: "SwiftSyntax", package: "swift-syntax"),
                                                .product(name: "SwiftParser", package: "swift-syntax"),
                                                .product(name: "SwiftIDEUtils", package: "swift-syntax")]),
    .testTarget(name: "YcodeSyntaxTests", dependencies: ["YcodeSyntax"]),
    // Highlighting and typing measurements (build it in release).
    .executableTarget(name: "ycode-syntax-bench", dependencies: ["YcodeSyntax"]),
]

// The IDE's portable core (docs/PARITY.md §5, milestone L0): the model
// shared by the macOS AppKit shell and the Linux SwiftUI shell. Builds and
// tests on macOS and Linux; YcodeUI re-exports it.
package.targets += [
    .target(name: "YcodeIDECore", dependencies: ["YcodeRelease", "YcodeSyntax", "YcodeProject", "YcodeWorkspace", "YcodeSettings", "YcodePlist", "YcodeBuild", "YcodeDebug",
                                                 "YcodeLanguage", "YcodeXcodebuild", "YcodeSubprocess", "YcodeAssistant", "YcodeCompletion", "YcodeProfiler",
                                                 "YcodePreviews", "YcodeDeviceModel", "YcodeSimFeatures", "YcodeStrings",
                                                 // SHA-256 and the asset service's ES256 chain (runtime downloads, route B).
                                                 .product(name: "Crypto", package: "swift-crypto")]),
    .testTarget(name: "YcodeIDECoreTests", dependencies: ["YcodeIDECore", "YcodeSyntax", "YcodeProject", "YcodeWorkspace", "YcodeSettings", "YcodePlist",
                                                          "YcodeBuild", "YcodeDebug", "YcodeLanguage", "YcodeXcodebuild", "YcodeSubprocess",
                                                          "YcodeAssistant", "YcodeProfiler", "YcodePreviews", "YcodeDeviceModel", "YcodeSimFeatures"],
                exclude: ["Fixtures"]),
]

// App icons and compiled asset catalogs (specs/formats/README-icon.md): the
// .icon document model, and the Assets.car writer, reader and compiler.
// Portable (Foundation only).
package.products += [.library(name: "YcodeIcon", targets: ["YcodeIcon"]),
                     .library(name: "YcodeAssetCatalog", targets: ["YcodeAssetCatalog"])]
package.targets += [
    .target(name: "YcodeIcon"),
    .target(name: "YcodeAssetCatalog", dependencies: ["YcodeIcon"]),
    .testTarget(name: "YcodeIconTests", dependencies: ["YcodeIcon"]),
    .testTarget(name: "YcodeAssetCatalogTests", dependencies: ["YcodeAssetCatalog", "YcodeIcon"]),
]

// String Catalogs (specs/ide/string-catalog.md, "Ycode implementation"): the
// catalog model, the compiler to .strings/.stringsdict (`ycode strings
// compile`, also swift-build's `xcstringstool`), extraction from Swift
// (swift-syntax) and Objective-C sources, merging, and conversion of
// .strings/.stringsdict tables. Portable (macOS and Linux).
package.products += [.library(name: "YcodeStrings", targets: ["YcodeStrings"])]
package.targets += [
    .target(name: "YcodeStrings", dependencies: [.product(name: "SwiftSyntax", package: "swift-syntax"),
                                                 .product(name: "SwiftParser", package: "swift-syntax")]),
    .testTarget(name: "YcodeStringsTests", dependencies: ["YcodeStrings"]),
]

// ycodebuild: an xcodebuild-compatible command line (specs/xcodebuild/).
package.products += [.executable(name: "ycodebuild", targets: ["ycodebuild-cli"]),
                     .library(name: "YcodeBuildServer", targets: ["YcodeBuildServer"]),
                     .executable(name: "ycode-bsp", targets: ["ycode-bsp"])]
package.targets += [
    // Code signing (specs/ide/signing.md): Foundation only, because ycode-swb compiles the same sources.
    .target(name: "YcodeSigning"),
    .testTarget(name: "YcodeSigningTests", dependencies: ["YcodeSigning"]),
    .target(name: "YcodeXcodebuild", dependencies: ["YcodeRelease", "YcodeProject", "YcodeWorkspace", "YcodeSettings", "YcodePlist", "YcodeBuild", "YcodeSubprocess", "YcodeSigning"]),
    // Target and directory are not named "ycodebuild": that collides with YcodeBuild on case-insensitive file systems.
    .executableTarget(name: "ycodebuild-cli", dependencies: ["YcodeRelease", "YcodeXcodebuild"], path: "Sources/ycodebuild-cli"),
    .testTarget(name: "YcodeXcodebuildTests", dependencies: ["YcodeXcodebuild", "YcodeProject"]),
    // The build server sourcekit-lsp asks for compiler arguments in projects and workspaces (specs/ide/language.md §BSP)
    .target(name: "YcodeBuildServer", dependencies: ["YcodeXcodebuild", "YcodeBuild", "YcodeProject", "YcodeWorkspace", "YcodeSettings", "YcodeDebug", "YcodeSubprocess"]),
    .executableTarget(name: "ycode-bsp", dependencies: ["YcodeRelease", "YcodeBuildServer"]),
    .testTarget(name: "YcodeBuildServerTests", dependencies: ["YcodeBuildServer", "YcodeLanguage", "YcodeDebug", "YcodeXcodebuild", "ycode-bsp", "YcodeIDECore",
                                                              "YcodeSubprocess", "YcodeWorkspace"]),
]

// The SwiftUI workspace shell (docs/PARITY.md §5, milestone L1).
// YcodeIDEShell holds its view models (no toolkit, tested everywhere);
// ycode-ide holds the views and the app. On Linux the views build against
// OpenViews (frameworks/swiftui, Ycode's own SwiftUI: its `SwiftUI`
// module); they are left out when that folder is not next to this package
// (an rsync of ycode/ alone). On macOS they build against Apple's SwiftUI;
// the macOS product is still the AppKit YcodeApp.
// YcodeEditorKit is the source editor's model without a toolkit (docs/PARITY.md §5.9).
package.products += [.library(name: "YcodeIDEShell", targets: ["YcodeIDEShell"]), .library(name: "YcodeEditorKit", targets: ["YcodeEditorKit"])]
package.targets += [
    .target(name: "YcodeEditorKit", dependencies: ["YcodeSyntax"]),
    .testTarget(name: "YcodeEditorKitTests", dependencies: ["YcodeEditorKit", "YcodeSyntax"]),
    .target(name: "YcodeIDEShell", dependencies: ["YcodeIDECore", "YcodeSyntax", "YcodeBuild", "YcodeXcodebuild", "YcodeSimLink", "YcodeEditorKit", "YcodeDebug", "YcodeAssistant",
                                                  "YcodePreviews", "YcodeDeviceModel"]),
    .testTarget(name: "YcodeIDEShellTests", dependencies: ["YcodeIDEShell", "YcodeIDECore", "YcodeSyntax", "YcodeBuild", "YcodeEditorKit", "YcodeCompletion", "YcodeDebug", "YcodeAssistant",
                                                          "YcodePreviews"]),
]
// Agent mode (specs/ide/coding-assistant.md, "Ycode implementation"): the
// Ycode MCP server (`ycode mcp`, and in-process for the IDE's agents), the
// JSON-RPC layer it shares with the Agent Client Protocol client, and ACP
// agents as coding-assistant back ends. Portable (macOS and Linux).
package.products += [.library(name: "YcodeMCP", targets: ["YcodeMCP"])]
package.targets += [
    .target(name: "YcodeMCP", dependencies: ["YcodeIDECore", "YcodeIDEShell", "YcodeAssistant", "YcodeCompletion", "YcodeBuild", "YcodePreviews",
                                             "YcodeProject", "YcodeSettings", "YcodeWorkspace", "YcodeSubprocess"]),
    .testTarget(name: "YcodeMCPTests", dependencies: ["YcodeMCP", "YcodeIDECore", "YcodeAssistant", "YcodeCompletion", "YcodeBuild", "ycode"]),
]
if let i = package.targets.firstIndex(where: { $0.name == "ycode" }) {
    package.targets[i].dependencies += ["YcodeMCP", "YcodeIDEShell"]
}

#if os(Linux)
if FileManager.default.fileExists(atPath: Context.packageDirectory + "/../frameworks/swiftui/Package.swift") {
    package.dependencies += [.package(path: "../frameworks/swiftui")]
    package.products += [.executable(name: "ycode-ide", targets: ["ycode-ide"])]
    package.targets += [
        .executableTarget(name: "ycode-ide", dependencies: ["YcodeRelease", "YcodeIDEShell", "YcodeIDECore", "YcodeSyntax", "YcodeBuild", "YcodeEditorKit", "YcodeCompletion", "YcodeAssistant",
                                                          "YcodePreviews",
                                                          .product(name: "SwiftUI", package: "swiftui"),
                                                          .product(name: "OVPlatform", package: "swiftui"),
                                                          .product(name: "OVDBus", package: "swiftui")]),
    ]
    // The device window's toolbar and inspector are drawn by OpenViews (cross-platform-parity.md §13).
    if let i = package.targets.firstIndex(where: { $0.name == "ycode-sim-viewer" }) {
        package.targets[i].dependencies += ["YcodeRemoteViewer", .product(name: "SwiftUI", package: "swiftui"), .product(name: "OVRender", package: "swiftui")]
    }
}
#else
package.products += [.executable(name: "ycode-ide", targets: ["ycode-ide"])]
package.targets += [
    .executableTarget(name: "ycode-ide", dependencies: ["YcodeRelease", "YcodeIDEShell", "YcodeIDECore", "YcodeSyntax", "YcodeBuild", "YcodeEditorKit", "YcodeCompletion", "YcodeAssistant",
                                                      "YcodePreviews"]),
]
#endif
