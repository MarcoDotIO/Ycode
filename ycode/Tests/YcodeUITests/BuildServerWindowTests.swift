import AppKit
import Foundation
import Testing
import YcodeBuildServer
import YcodeLanguage
@testable import YcodeUI

/// A workspace window on an iOS project with an app, a framework and a test
/// bundle: the session starts sourcekit-lsp through Ycode's build server
/// (`specs/ide/language.md` §Build server) and gets live issues, completion
/// of the framework's members and a definition in the framework.
@MainActor
@Suite(.serialized, .heavyIntegration, .timeLimit(.minutes(5))) struct BuildServerWindowTests {
    static let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func projectWindowUsesTheBuildServer() async throws {
        let bsp = Self.packageRoot.appendingPathComponent(".build/debug/ycode-bsp").path
        let sdks = (try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link")).map {
            $0 + "/Platforms/iPhoneSimulator.platform/Developer/SDKs"
        }
        guard SourceKitLSP.locate() != nil, FileManager.default.isExecutableFile(atPath: bsp),
              let sdks, !((try? FileManager.default.contentsOfDirectory(atPath: sdks)) ?? []).isEmpty else { return }
        setenv("YCODE_BSP", bsp, 1)
        defer { unsetenv("YCODE_BSP") }
        let dir = Self.packageRoot.appendingPathComponent(".build-ide/bsp-window")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let project = try SampleProject.write(.iOS, in: dir)
        let main = project.deletingLastPathComponent().appendingPathComponent("App/AppMain.swift")

        _ = NSApplication.shared
        let session = WorkspaceSession(model: try WorkspaceModel(url: project))
        session.scheme = "App"
        await session.startLanguageService()
        let language = try #require(session.language)
        // The server was opened on Ycode's private folder, which names ycode-bsp.
        let config = BuildServerLaunch.workspaceFolder(for: project).appendingPathComponent(".bsp/ycode.json")
        let argv = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any]
        #expect((argv?["argv"] as? [String])?.prefix(3) == [bsp, "serve", project.standardizedFileURL.path])
        #expect((argv?["argv"] as? [String])?.contains("App") == true)

        // A deliberate error becomes a live issue.
        let text = try String(contentsOf: main, encoding: .utf8) + "let broken: Int = \"not a number\"\n"
        language.open(main, text: text)
        #expect(await waitUntil(120) {
            session.displayedIssues.contains { $0.message.lowercased().contains("cannot convert") }
                && !session.displayedIssues.contains { $0.message.lowercased().contains("no such module") }
        }, "\(session.displayedIssues.map(\.message))")

        // Completion of the framework's members in the app.
        let lines = text.components(separatedBy: "\n")
        let line = try #require(lines.firstIndex { $0.contains("return g.") })
        let column = (lines[line] as NSString).range(of: "return g.").upperBound
        let items = await session.completions(main, at: Position(line: line, character: column))
        #expect(items.contains { $0.label.hasPrefix("greet(times:") })

        // Jump to Definition into the framework.
        _ = try await language.client.request("workspace/synchronize", ["index": true])
        let use = try #require(lines.firstIndex { $0.contains("let g = Greeter") })
        let column2 = (lines[use] as NSString).range(of: "let g = Gree").upperBound
        let def = await session.definition(main, at: Position(line: use, character: column2))
        #expect(def?.url.path.hasSuffix("Kit/Greeter.swift") == true, "\(String(describing: def))")
        #expect(def?.start.line == 3)
        await language.stop()
    }

    @Test func settingOffOpensTheProjectFolder() throws {
        let defaults = try #require(UserDefaults(suiteName: "ycode-bsp-test-\(UUID().uuidString)"))
        defaults.set(false, forKey: BuildServerLaunch.defaultsKey)
        let project = URL(fileURLWithPath: "/tmp/P/App.xcodeproj")
        #expect(BuildServerLaunch.prepareWorkspaceFolder(container: project, environment: ["YCODE_BSP": "/bin/sh"], defaults: defaults) == nil)
        #expect(!BuildServerLaunch.isEnabled(environment: ["YCODE_BUILD_SERVER": "0"], defaults: .standard))
        #expect(BuildServerLaunch.isEnabled(environment: ["YCODE_BUILD_SERVER": "1"], defaults: defaults))
        // Packages never use it.
        defaults.set(true, forKey: BuildServerLaunch.defaultsKey)
        #expect(BuildServerLaunch.prepareWorkspaceFolder(container: URL(fileURLWithPath: "/tmp/P"), environment: ["YCODE_BSP": "/bin/sh"],
                                                         defaults: defaults) == nil)
    }
}
