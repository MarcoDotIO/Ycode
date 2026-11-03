// swift-tools-version: 6.0
//
// ycode-swiftui ("OpenViews"): a clean-room, Linux-buildable implementation of
// SwiftUI's value types and layout system, written from
// specs/frameworks/swiftui/ (see README.md in this directory).
//
// Module names. `SwiftUI` and `SwiftUICore` are interop identifiers: on Linux
// (and other non-Apple hosts) the library modules carry exactly those names so
// that `import SwiftUI` compiles unchanged. On Apple hosts those names belong
// to the system frameworks, so the same sources build as `OpenViews` /
// `OpenViewsCore` instead (and define OPENVIEWS_RENAMED so that re-exports and
// tests import the right name). The choice is made from the host that
// evaluates this manifest; cross-compiling from macOS to Linux is not
// supported by this switch.
import PackageDescription

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
let coreModule = "OpenViewsCore"
let uiModule = "OpenViews"
let renamed: [SwiftSetting] = [.define("OPENVIEWS_RENAMED")]
#else
let coreModule = "SwiftUICore"
let uiModule = "SwiftUI"
let renamed: [SwiftSetting] = []
#endif

let package = Package(
    name: "ycode-swiftui",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: uiModule, targets: [uiModule]),
        .library(name: coreModule, targets: [coreModule]),
        .library(name: "OVText", targets: ["OVText"]),
        .library(name: "OVRender", targets: ["OVRender"]),
        .library(name: "OVPlatform", targets: ["OVPlatform"]),
        .library(name: "OVDBus", targets: ["OVDBus"]),
        .library(name: "OVAccessibilityATSPI", targets: ["OVAccessibilityATSPI"]),
        .executable(name: "ov-sample", targets: ["OVSampleApp"]),
        .executable(name: "ov-settings", targets: ["OVSettingsSample"]),
        .executable(name: "ov-mini-ide", targets: ["OVMiniIDE"]),
        .executable(name: "ov-editor-bench", targets: ["OVEditorBench"]),
    ],
    targets: [
        // Fonts, shaping, line breaking, bidi and paragraph layout (round R4).
        // Bundles Noto Sans and Noto Sans Mono (Resources/Fonts/OFL.txt) and Inter
        // (Resources/Fonts/Inter-OFL.txt), all SIL OFL 1.1.
        .target(name: "OVText", path: "Sources/OVText", resources: [.copy("Resources/Fonts")]),
        // Display list, rasteriser and compositors (round R5); the surface
        // interface the platform host implements (09-open-design.md §3.6).
        .target(name: "OVRender", dependencies: ["CThorVG", "COVVulkan"], path: "Sources/OVRender"),
        // The Vulkan compositor's C side; loads libvulkan at run time
        // (Khronos headers 1.3.275, Apache-2.0, in Sources/COVVulkan/vulkan).
        .target(name: "COVVulkan", path: "Sources/COVVulkan", exclude: ["vulkan"], publicHeadersPath: "include",
                linkerSettings: [.linkedLibrary("dl", .when(platforms: [.linux]))]),
        // ThorVG 1.1.3 (MIT), vendored unmodified: CPU engine, PNG/JPEG
        // loaders and the C API (Sources/CThorVG/config/config.h).
        .target(name: "CThorVG", path: "Sources/CThorVG",
                exclude: ["thorvg/LICENSE"],
                sources: ["thorvg/src"],
                publicHeadersPath: "include",
                cxxSettings: [
                    .headerSearchPath("config"),
                    .headerSearchPath("include"),
                    .headerSearchPath("thorvg/inc"),
                    .headerSearchPath("thorvg/src/common"),
                    .headerSearchPath("thorvg/src/renderer"),
                    .headerSearchPath("thorvg/src/renderer/cpu_engine"),
                    .headerSearchPath("thorvg/src/loaders/raw"),
                    .headerSearchPath("thorvg/src/loaders/png"),
                    .headerSearchPath("thorvg/src/loaders/jpg"),
                    .define("TVG_STATIC"),
                ]),
        .target(name: coreModule, dependencies: ["OVText", "OVRender"], path: "Sources/SwiftUICore", swiftSettings: renamed),
        // SDL3 bridge (round R7): vendored SDL 3.4.18 public headers (zlib,
        // SDL3-LICENSE.txt) and a loader that opens libSDL3 at run time, so the
        // package builds without SDL3 installed.
        .target(name: "COVSDL", path: "Sources/COVSDL",
                linkerSettings: [.linkedLibrary("dl", .when(platforms: [.linux]))]),
        // Windows, input events, run loop and display link, clipboard (R7):
        // an SDL3 back end (X11, Wayland) and a headless back end for tests.
        .target(name: "OVPlatform", dependencies: ["COVSDL"], path: "Sources/OVPlatform"),
        // A D-Bus client of our own (Unix sockets, SASL EXTERNAL, the wire
        // format, method calls and signals, exported objects; Foundation and
        // POSIX only), and the AT-SPI2 exporter on it (written from the
        // D-Bus specification and at-spi2-core's interface XML; no
        // third-party code).
        .target(name: "OVDBus", path: "Sources/OVDBus"),
        .target(name: "OVAccessibilityATSPI", dependencies: ["OVDBus"], path: "Sources/OVAccessibilityATSPI"),
        .target(name: uiModule, dependencies: [.target(name: coreModule), "OVPlatform", "OVRender", "OVAccessibilityATSPI"],
                path: "Sources/SwiftUI", swiftSettings: renamed),
        // A small OpenViews app (R7 done-criterion): a button, a draggable
        // box and a text field in a window.
        .executableTarget(name: "OVSampleApp", dependencies: [.target(name: uiModule), "OVPlatform"],
                          path: "Sources/OVSampleApp", swiftSettings: renamed),
        // The R8 sample: a settings form with every control (done-criterion runs).
        .executableTarget(name: "OVSettingsSample", dependencies: [.target(name: uiModule), "OVPlatform"],
                          path: "Sources/OVSettingsSample", swiftSettings: renamed),
        // The R9 sample: a mini IDE (split view, outline, editor, console,
        // sheet, alert).
        .executableTarget(name: "OVMiniIDE", dependencies: [.target(name: uiModule), "OVPlatform"],
                          path: "Sources/OVMiniIDE", swiftSettings: renamed),
        // R13: the scrolling benchmark of an EditorKit-style text surface.
        .executableTarget(name: "OVEditorBench", dependencies: [.target(name: uiModule), "OVPlatform"],
                          path: "Sources/OVEditorBench", swiftSettings: renamed),
        .testTarget(name: "OpenViewsTests",
                    dependencies: [.target(name: coreModule), .target(name: uiModule), "OVText", "OVRender",
                                   "OVPlatform", "OVDBus", "OVAccessibilityATSPI"],
                    path: "Tests/OpenViewsTests", exclude: ["R5/Fixtures", "R5/Goldens"], swiftSettings: renamed),
    ],
    cxxLanguageStandard: .cxx14
)
