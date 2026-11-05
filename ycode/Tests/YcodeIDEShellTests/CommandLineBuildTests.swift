import Foundation
import Testing
import YcodeBuild
@testable import YcodeIDEShell

/// `ycode build`'s engine (`specs/ide/build.md`, "The command line"): on
/// Linux and in the Flatpak a package folder builds with SwiftPM, as in the
/// Linux IDE.
@Suite struct CommandLineBuildTests {
    func engine(_ name: String?, _ container: BuildRequest.Container, linux: Bool, env: [String: String] = [:],
                packages: Set<String> = ["/work/Tools"]) -> CommandLineBuild.Engine? {
        CommandLineBuild.engine(named: name, container: container, isLinux: linux, environment: env, isPackageFolder: { packages.contains($0) })
    }

    @Test func linuxBuildsPackageFoldersWithSwiftPM() {
        #expect(engine(nil, .package("/work/Tools"), linux: true) == .swiftPM)
        // The same in the Flatpak: the choice does not depend on the sandbox.
        #expect(engine(nil, .package("/work/Tools"), linux: true, env: ["FLATPAK_ID": "io.github.MarcoDotIO.Ycode"]) == .swiftPM)
    }

    @Test func linuxBuildsProjectsWithYcodebuild() {
        #expect(engine(nil, .project("/work/App/App.xcodeproj"), linux: true) == .xcodebuild)
        #expect(engine(nil, .workspace("/work/App/App.xcworkspace"), linux: true) == .xcodebuild)
        // A folder without a package (or with a project beside it).
        #expect(engine(nil, .package("/work/App"), linux: true) == .xcodebuild)
    }

    @Test func theIDEsSwitchSendsPackagesToYcodebuild() {
        #expect(engine(nil, .package("/work/Tools"), linux: true, env: ["YCODE_IDE_ENGINE": "ycodebuild"]) == .xcodebuild)
    }

    @Test func macOSKeepsXcodebuild() {
        #expect(engine(nil, .package("/work/Tools"), linux: false) == .xcodebuild)
        #expect(engine(nil, .project("/work/App/App.xcodeproj"), linux: false) == .xcodebuild)
    }

    @Test func anExplicitEngineWins() {
        #expect(engine("swiftpm", .package("/work/Tools"), linux: false) == .swiftPM)
        #expect(engine("swift-build", .package("/work/Tools"), linux: true) == .swiftBuild)
        #expect(engine("xcodebuild", .package("/work/Tools"), linux: true) == .xcodebuild)
        #expect(engine("make", .package("/work/Tools"), linux: true) == nil)
    }

    @Test func packageFolderMeansAManifestAndNoProject() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ycode-cli-engine-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        #expect(!CommandLineBuild.isPackageFolder(dir.path))
        try "// swift-tools-version: 5.9\n".write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        #expect(CommandLineBuild.isPackageFolder(dir.path))
        try fm.createDirectory(at: dir.appendingPathComponent("App.xcodeproj"), withIntermediateDirectories: true)
        #expect(!CommandLineBuild.isPackageFolder(dir.path))
    }

    @Test func linuxXcodebuildIsYcodebuild() throws {
        let e = try CommandLineBuild.make(.xcodebuild, isLinux: true, locateYcodebuild: { "/opt/ycode/bin/ycodebuild" })
        #expect((e as? XcodebuildEngine)?.command == ["/opt/ycode/bin/ycodebuild"])
        let mac = try CommandLineBuild.make(.xcodebuild, isLinux: false, locateYcodebuild: { nil })
        #expect((mac as? XcodebuildEngine)?.command == ["/usr/bin/xcrun", "xcodebuild"])
        #expect(try CommandLineBuild.make(.swiftPM, isLinux: true) is PackageBuildEngine)
    }

    @Test func missingToolsAreClearErrors() {
        let noYcodebuild = #expect(throws: CommandLineBuild.Failure.self) {
            try CommandLineBuild.make(.xcodebuild, isLinux: true, locateYcodebuild: { nil })
        }
        #expect(noYcodebuild?.description == ShellToolchain.noBuildTool)
        let noSwbuild = #expect(throws: CommandLineBuild.Failure.self) {
            try CommandLineBuild.make(.swiftBuild, isLinux: true, locateSwbuild: { nil })
        }
        #expect(noSwbuild?.description == "swift-build not found (set YCODE_SWB to Ycode's ycode-swb, or YCODE_SWBUILD to swbuild). Swift packages build with --engine swiftpm, the default here.")
    }

    /// No `swift` on the host: the build fails at once with the toolchain
    /// message as its issue (inside the Flatpak the host-tool wrapper says
    /// the same, `packaging/flatpak/host-tool.sh`).
    @Test func noHostSwiftIsOneClearIssue() async {
        let request = BuildRequest(container: .package("/work/Tools"))
        let op = PackageBuildEngine(swift: ["/usr/bin/env", "swift"], environment: ["PATH": "/nonexistent"]).start(request)
        var log: [String] = []
        var result: BuildResult?
        for await event in op.events {
            if case .output(let line) = event { log.append(line) }
            if case .finished(let r) = event { result = r }
        }
        #expect(result?.status == .failed)
        #expect(result?.issues.map(\.message) == [ShellToolchain.noSwift])
        #expect(log == [ShellToolchain.noSwift])
    }

    /// In the Flatpak `swift` is the host-tool wrapper. When it cannot run
    /// the host's Swift it explains why and exits 127; that explanation is
    /// the build's error, not only a log line.
    @Test func theHostToolWrappersExplanationIsTheError() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ycode-cli-wrapper-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let wrapper = dir.appendingPathComponent("swift")
        try """
        #!/bin/sh
        echo "Ycode: no Swift toolchain was found on this computer (swift is missing)." >&2
        echo "The Ycode Flatpak builds with the Swift toolchain installed on the host." >&2
        exit 127

        """.write(to: wrapper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let op = PackageBuildEngine(swift: [wrapper.path]).start(BuildRequest(container: .package(dir.path)))
        var result: BuildResult?
        for await event in op.events {
            if case .finished(let r) = event { result = r }
        }
        #expect(result?.status == .failed)
        #expect(result?.issues.map(\.message) == ["Ycode: no Swift toolchain was found on this computer (swift is missing). "
            + "The Ycode Flatpak builds with the Swift toolchain installed on the host."])
    }

    @Test func onlyAToolThatDidNotRunIsMissing() {
        let error = Diagnostic(severity: .error, message: "cannot find 'x' in scope", location: nil)
        #expect(SwiftPMRun.toolMissing(status: 1, log: ["boom"], issues: []) == nil)
        #expect(SwiftPMRun.toolMissing(status: 127, log: ["x"], issues: [error]) == nil)
        #expect(SwiftPMRun.toolMissing(status: 127, log: [], issues: [])?.message == ShellToolchain.noSwift)
    }
}
