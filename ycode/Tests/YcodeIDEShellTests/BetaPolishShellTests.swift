import Foundation
import Testing
import YcodeBuild
@testable import YcodeIDECore
@testable import YcodeIDEShell

/// What a tester hits first in the Linux shell: Clone, About, Report a Bug,
/// and a machine without the tools.
@MainActor
@Suite(.serialized) struct BetaPolishShellTests {
    func temp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("beta-shell-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// A repository with a Package.swift, and a model in `dir`.
    func repository(in dir: URL) throws -> URL {
        let repo = dir.appendingPathComponent("source/Widget")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"Widget\")\n"
            .write(to: repo.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let r = try #require(try GitRepository.initialize(at: repo))
        _ = r
        _ = try GitRepository.run("/usr/bin/git", ["-C", repo.path, "add", "."])
        _ = try GitRepository.run("/usr/bin/git", ["-C", repo.path, "-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-qm", "first"])
        return repo
    }

    func app() -> (ShellAppModel, TestShellDefaults) {
        let d = TestShellDefaults()
        return (ShellAppModel(recentProjects: RecentProjects(defaults: d.defaults), engine: { PackageBuildEngine() }), d)
    }

    @Test func everyMenuCommandIsInTheTable() {
        for c in [ShellCommand.about, .help, .releaseNotes, .reportBug, .swiftBook, .clone] {
            #expect(c.menuCommand != nil, "\(c)")
            #expect(c.menuCommand?.isAvailable == true, "\(c)")
        }
        #expect(ShellCommand.reportBug.menuCommand?.title == "Report a Bug…")
    }

    @Test func aboutAndLinksWithoutAWorkspace() {
        let (a, d) = app()
        defer { d.remove() }
        var opened: [URL] = []
        a.openExternally = { opened.append($0) }
        for c in [ShellCommand.about, .help, .releaseNotes, .reportBug, .clone] { #expect(a.isEnabled(c), "\(c)") }
        a.perform(.about)
        #expect(a.isAboutShown)
        a.perform(.reportBug)
        #expect(opened.last?.absoluteString.contains("issues/new") == true)
        a.perform(.releaseNotes)
        #expect(opened.last == ProductIdentity.releasesURL)
        a.linkCouldNotOpen(ProductIdentity.bugReportURL())
        // The fallback shows the address, without the long query.
        #expect(a.notice?.message.contains("issues/new") == true)
        #expect(a.notice?.message.contains("?") == false)
    }

    @Test func cloneOpensThePackage() async throws {
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try repository(in: dir)
        let (a, d) = app()
        defer { d.remove() }
        a.showClone()
        let m = try #require(a.clone)
        m.location = dir.appendingPathComponent("into").path
        try FileManager.default.createDirectory(atPath: m.location, withIntermediateDirectories: true)
        #expect(!m.canClone)
        m.address = "  \(repo.path)  "
        #expect(m.canClone)
        #expect(m.destination.lastPathComponent == "Widget")
        await m.clone().value
        #expect(m.error == nil)
        #expect(a.clone == nil)
        #expect(a.workspace?.workspaceName == "Widget")
    }

    @Test func aFailedCloneStaysUpAndSaysWhy() async throws {
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (a, d) = app()
        defer { d.remove() }
        a.showClone()
        let m = try #require(a.clone)
        m.location = dir.path
        m.address = dir.appendingPathComponent("missing").path
        await m.clone().value
        #expect(a.clone != nil)
        #expect(m.error?.isEmpty == false)
        #expect(m.error?.contains("Cloning into") == false)
        #expect(!m.isRunning)
    }

    @Test func aRepositoryWithNothingToOpenSaysWhereItIs() async throws {
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try repository(in: dir)
        try FileManager.default.removeItem(at: repo.appendingPathComponent("Package.swift"))
        _ = try GitRepository.run("/usr/bin/git", ["-C", repo.path, "-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-qam", "gone"])
        let (a, d) = app()
        defer { d.remove() }
        a.showClone()
        let m = try #require(a.clone)
        m.location = dir.path + "/into"
        try FileManager.default.createDirectory(atPath: m.location, withIntermediateDirectories: true)
        m.address = repo.path
        await m.clone().value
        #expect(a.workspace == nil)
        #expect(a.notice?.title == "Cloned Widget")
    }

    @Test func noGitSaysSo() async {
        let m = CloneShellModel(location: "/tmp", git: "/nonexistent/git")
        m.address = "https://example.com/a.git"
        await m.clone().value
        #expect(m.error?.contains("Git was not found") == true)
    }

    @Test func noToolchainSaysWhatToInstall() async {
        #expect(ShellToolchain.locate("swift", environment: ["PATH": "/nonexistent"]) == nil)
        let op = PackageBuildEngine.failed(issue: ShellToolchain.noSwift)
        var result: BuildResult?
        for await e in op.events { if case .finished(let r) = e { result = r } }
        #expect(result?.status == .failed)
        #expect(result?.issues.first?.message.contains("Swift toolchain") == true)
        let tool = MissingToolEngine(message: ShellToolchain.noBuildTool)
        #expect(tool.executablePath(for: BuildRequest(container: .project("/x.xcodeproj"), scheme: "x", action: .build)) == nil)
        // `swift test` ends a failed build with this line; it repeats the failure.
        #expect(SwiftPMRun.isSummary(Diagnostic(severity: .error, message: "fatalError")))
    }

    /// A project's build for the host says what it takes; other destinations
    /// and Clean go to the build tool.
    @Test func projectsOnTheHostSayWhatTheyNeed() async {
        struct Stub: BuildEngine {
            var name: String { "stub" }
            func start(_ request: BuildRequest) -> BuildOperation { PackageBuildEngine.failed("reached the tool") }
        }
        let e = LinuxProjectEngine(inner: Stub())
        func first(_ r: BuildRequest) async -> (String, [Diagnostic]) {
            var line = "", issues: [Diagnostic] = []
            for await event in e.start(r).events {
                if case .output(let o) = event, line.isEmpty { line = o }
                if case .finished(let f) = event { issues = f.issues }
            }
            return (line, issues)
        }
        let host = ShellBuildSetup.hostDestination.specifier
        let (_, issues) = await first(BuildRequest(container: .project("/x.xcodeproj"), scheme: "x", destination: host, action: .build))
        #expect(issues.first?.message == ShellToolchain.noAppleSDK)
        #expect(await first(BuildRequest(container: .project("/x.xcodeproj"), scheme: "x", destination: "generic/platform=iOS Simulator", action: .build)).0 == "reached the tool")
        #expect(await first(BuildRequest(container: .project("/x.xcodeproj"), scheme: "x", destination: host, action: .clean)).0 == "reached the tool")
    }

    @Test func toolsRootFindsTheScriptsFolder() throws {
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bin = dir.appendingPathComponent(".build/debug")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try "".write(to: dir.appendingPathComponent("scripts/ycode-ios-build-linux"), atomically: true, encoding: .utf8)
        #expect(ShellRemoteRun.toolsRoot(executable: bin.appendingPathComponent("ycode-ide").path).path == dir.path)
    }

}

/// A throwaway defaults suite.
final class TestShellDefaults {
    let name = "beta-shell-\(UUID().uuidString)"
    let defaults: UserDefaults
    init() { defaults = UserDefaults(suiteName: name) ?? .standard }
    func remove() { defaults.removePersistentDomain(forName: name) }
}
