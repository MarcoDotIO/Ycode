import Foundation
import Testing
@testable import YcodeWorkspace

@Suite struct SchemeEditingTests {
    func fixture() throws -> (text: String, scheme: Scheme) {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/App.xcodeproj/xcshareddata/xcschemes/App", withExtension: "xcscheme"))
        let text = try String(contentsOf: url, encoding: .utf8)
        return (text, try Scheme(parsing: text, name: "App"))
    }

    @Test func settingSameValuesKeepsBytes() throws {
        var (text, s) = try fixture()
        s.setLaunchArguments(s.launchArguments)
        s.setLaunchEnvironment(s.launchEnvironment)
        s.setConfiguration("Debug", for: "LaunchAction")
        #expect(s.serialized() == text)
    }

    @Test func editsArgumentsEnvironmentAndConfiguration() throws {
        var (text, s) = try fixture()
        s.setLaunchArguments([.init(value: "-x", isEnabled: true)])
        s.setLaunchEnvironment([])
        s.setConfiguration("Release", for: "LaunchAction")
        s.setCustomWorkingDirectory("/tmp/work")
        let again = try Scheme(parsing: s.serialized(), name: "App")
        #expect(again.launchArguments == [.init(value: "-x", isEnabled: true)])
        #expect(again.launchEnvironment.isEmpty)
        #expect(again.document.child("LaunchAction")?.child("EnvironmentVariables") == nil)
        #expect(again.configuration(for: "LaunchAction") == "Release")
        #expect(again.customWorkingDirectory == "/tmp/work")
        // Undo every edit: the original bytes come back.
        s.setLaunchArguments([.init(value: "--verbose \"quoted\" & more", isEnabled: true), .init(value: "--off", isEnabled: false)])
        s.setLaunchEnvironment([.init(key: "SCRIPT", value: "line1\nline2", isEnabled: true)])
        s.setConfiguration("Debug", for: "LaunchAction")
        s.setCustomWorkingDirectory(nil)
        #expect(s.serialized() == text)
    }

    @Test func createsElementsInCanonicalOrder() throws {
        var s = try Scheme(parsing: "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Scheme version = \"1.7\">\n<BuildAction></BuildAction>\n<ArchiveAction></ArchiveAction>\n</Scheme>\n", name: "N")
        s.setLaunchEnvironment([.init(key: "A", value: "1", isEnabled: false)])
        s.setLaunchArguments([.init(value: "a", isEnabled: true)])
        #expect(s.document.children.map(\.name) == ["BuildAction", "LaunchAction", "ArchiveAction"])
        #expect(s.document.child("LaunchAction")?.children.map(\.name) == ["CommandLineArguments", "EnvironmentVariables"])
    }

    @Test func sharingMovesTheFile() throws {
        let (text, _) = try fixture()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build-ide/scheme-share/P.xcodeproj")
        try? FileManager.default.removeItem(at: root)
        let shared = Scheme.fileURL(container: root, name: "App", shared: true)
        try FileManager.default.createDirectory(at: shared.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: shared, atomically: true, encoding: .utf8)
        var s = try Scheme(contentsOf: shared, isShared: true)
        try s.setShared(false, user: "tester")
        let user = root.appendingPathComponent("xcuserdata/tester.xcuserdatad/xcschemes/App.xcscheme")
        #expect(s.url == user && !FileManager.default.fileExists(atPath: shared.path))
        #expect(try String(contentsOf: user, encoding: .utf8) == text)
        try s.setShared(true, user: "tester")
        #expect(s.url?.path == shared.path && FileManager.default.fileExists(atPath: shared.path))
        #expect(try s.save() == false) // unchanged: not rewritten
    }
}
