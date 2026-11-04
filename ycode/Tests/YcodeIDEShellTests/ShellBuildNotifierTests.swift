import Foundation
import Testing
import YcodeBuild
import YcodeIDECore
@testable import YcodeIDEShell

/// A build engine that finishes with the given issues.
private struct ResultEngine: BuildEngine {
    var issues: [Diagnostic]
    var name: String { "result" }
    func start(_ request: BuildRequest) -> BuildOperation {
        let (stream, c) = AsyncStream<BuildEvent>.makeStream()
        for d in issues { c.yield(.issue(d)) }
        let failed = issues.contains { $0.severity == .error }
        c.yield(.finished(BuildResult(status: failed ? .failed : .succeeded, exitCode: failed ? 1 : 0, issues: issues)))
        c.finish()
        return BuildOperation(events: stream, cancel: {})
    }
}

/// `specs/ide/build-notifications.md` in the SwiftUI shell's model.
@MainActor
@Suite struct ShellBuildNotifierTests {
    func package() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-shell-hud-\(UUID().uuidString)/Hud")
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Sources/Hud"), withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"Hud\")\n"
            .write(to: url.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "print(1)\n".write(to: url.appendingPathComponent("Sources/Hud/main.swift"), atomically: true, encoding: .utf8)
        return url
    }

    func waitUntil(_ cond: () -> Bool) async {
        for _ in 0..<2000 where !cond() { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    @Test func buildResultsShowTheBezelReplaceItAndFade() async throws {
        let url = try package()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let prefs = Preferences(defaults: UserDefaults(suiteName: "ycode.shell-hud.\(UUID().uuidString)")!)
        let m = try WorkspaceShellModel(url: url, engine: ResultEngine(issues: []))
        let n = m.notifier
        n.preferences = { prefs }
        n.timeScale = 0.05
        var announced: [String] = []
        n.announce = { announced.append($0) }
        _ = await m.build()
        #expect(n.bezel == BuildNotice(title: "Build Succeeded", symbolName: "hammer", outcome: .succeeded))
        #expect(announced == ["Build Succeeded"] && n.workspaceName == "Hud")
        // The fade lasts a few milliseconds at this time scale: count it
        // rather than poll for it.
        await waitUntil { n.fadesStarted == 1 }
        #expect(n.fadesStarted == 1)
        await waitUntil { n.bezel == nil }
        #expect(n.bezel == nil && !n.isFading)

        // An error: "Build Failed"; then a second result replaces it.
        m.session.engine = ResultEngine(issues: [Diagnostic(severity: .error, message: "bad", location: nil)])
        _ = await m.build()
        #expect(n.bezel?.title == "Build Failed")
        n.notify(BuildNotice(title: "Build Succeeded", symbolName: "hammer", outcome: .succeeded))
        #expect(n.bezel?.title == "Build Succeeded" && n.timeline.showCount == 3)
        await waitUntil { n.bezel == nil }
        #expect(n.log == ["bezel Build Succeeded", "bezel Build Failed", "bezel Build Succeeded"])

        // Reduce Motion: no fading phase.
        n.reduceMotion = true
        n.notify(BuildNotice(title: "Build Failed", symbolName: "hammer", outcome: .failed))
        var faded = false
        for _ in 0..<200 where n.bezel != nil {
            faded = faded || n.isFading
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(!faded && n.bezel == nil)

        // The window not in front: a system notification instead.
        var posted: [(String, String)] = []
        n.postSystemNotification = { posted.append(($0.title, $1)) }
        n.isWindowActive = false
        m.session.engine = ResultEngine(issues: [])
        _ = await m.build()
        #expect(n.bezel == nil && posted.count == 1 && posted.first?.0 == "Build Succeeded" && posted.first?.1 == "Hud")
        #expect(n.log.last == "system Build Succeeded")
    }
}
