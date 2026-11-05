import Foundation
import YcodeBuild
import YcodeIDECore
import YcodeXcodebuild

/// The engine `ycode build` uses (`specs/ide/build.md`, "The command
/// line"). On Linux, also inside the Flatpak, it picks what the Linux IDE
/// picks: SwiftPM for a package folder, ycodebuild for projects and
/// workspaces. On macOS the default stays xcodebuild.
public enum CommandLineBuild {
    public enum Engine: String, Equatable, Sendable, CaseIterable {
        /// Apple's `xcrun xcodebuild` on macOS; ycodebuild on Linux.
        case xcodebuild
        /// swift-build's `swbuild` client from Ycode's PIF.
        case swiftBuild = "swift-build"
        /// The toolchain's own SwiftPM (`swift build`, `swift test`), as the
        /// Linux IDE builds packages.
        case swiftPM = "swiftpm"
    }

    /// `--engine <name>`, or nil for the default. Nil for an unknown name.
    public static func engine(named name: String?, container: BuildRequest.Container, isLinux: Bool,
                              environment: [String: String] = ProcessInfo.processInfo.environment,
                              isPackageFolder: (String) -> Bool = CommandLineBuild.isPackageFolder) -> Engine? {
        if let name { return Engine(rawValue: name) }
        guard isLinux else { return .xcodebuild }
        // `YCODE_IDE_ENGINE=ycodebuild` sends packages to ycodebuild, as in the IDE.
        if environment["YCODE_IDE_ENGINE"] == "ycodebuild" { return .xcodebuild }
        if case .package(let dir) = container, isPackageFolder(dir) { return .swiftPM }
        return .xcodebuild
    }

    /// A folder with a `Package.swift` and no project or workspace (one
    /// with both builds the project, as ycodebuild does).
    public static func isPackageFolder(_ dir: String) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: (dir as NSString).appendingPathComponent("Package.swift")) else { return false }
        let entries = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        return !entries.contains { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }
    }

    public struct Failure: Error, Equatable, CustomStringConvertible {
        public var description: String
    }

    /// The engine for a choice on this host. A missing tool is an error that
    /// says what to install or set; a missing Swift toolchain is the SwiftPM
    /// engine's own first issue (in the Flatpak, the host-tool wrapper's).
    public static func make(_ engine: Engine, isLinux: Bool,
                            environment: [String: String] = ProcessInfo.processInfo.environment,
                            locateYcodebuild: () -> String? = { TestRunnerSelection.locateYcodebuild() },
                            locateSwbuild: () -> String? = { SwiftBuildEngine.locate() }) throws -> BuildEngine {
        switch engine {
        case .swiftPM:
            return PackageBuildEngine()
        case .xcodebuild where isLinux:
            guard let tool = locateYcodebuild() else { throw Failure(description: ShellToolchain.noBuildTool) }
            return XcodebuildEngine(command: [tool])
        case .xcodebuild:
            return XcodebuildEngine()
        case .swiftBuild:
            guard let tool = locateSwbuild() else {
                throw Failure(description: "swbuild not found (set YCODE_SWBUILD). Swift packages build with --engine swiftpm"
                    + (isLinux ? ", the default here." : "."))
            }
            // The PIF of projects and workspaces is XcodePIF's, with the
            // container's Swift packages (the IDE's PIF source).
            var e = SwiftBuildEngine(swbuild: tool)
            e.pifSource = XcodePIFSource()
            return e
        }
    }

    public static var isLinuxHost: Bool {
        #if os(Linux)
        true
        #else
        false
        #endif
    }
}
