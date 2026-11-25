import Foundation
import Testing
import YcodeBuild
@testable import YcodeBuildServer
import YcodeIDECore
import YcodeLanguage

/// P-070 (beta 5): a SwiftUI app whose `ContentView.swift` uses a `Counter`
/// declared in another file of the app, opened as the IDE opens it: the
/// language server starts before the scheme and the run destination are
/// known, then follows them (a restart), and the build server's log
/// (`ycode-bsp --log`) records every file it had no arguments for.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(10))) struct B5LiveDiagnosticsTests {
    /// `ycode-bsp` of this build: next to the test bundle (any scratch
    /// path), else `.build/debug`.
    static var server: String? {
        let fm = FileManager.default
        var dirs = ([Bundle(for: B5BundleMarker.self)] + Bundle.allBundles).map { $0.bundleURL.deletingLastPathComponent().path }
        dirs.append(CrossFileLiveIssuesTests.packageRoot.appendingPathComponent(".build/debug").path)
        return dirs.map { $0 + "/ycode-bsp" }.first { fm.isExecutableFile(atPath: $0) }
    }

    static let counter = """
    import Foundation

    @Observable
    final class Counter {
        var value = 0
        func increment() { value += 1 }
    }

    """

    static let view = """
    import SwiftUI

    struct ContentView: View {
        @State private var counter = Counter()

        var body: some View {
            VStack(spacing: 12) {
                Text("\\(counter.value)")
                Button("Add") { counter.increment() }
            }
            .padding()
        }
    }

    #Preview {
        ContentView()
    }

    """

    /// The app, its Swift Testing unit tests and XCTest UI tests, from the
    /// iOS App template; `Counter.swift` beside `ContentView.swift`.
    func makeProject(in dir: URL) throws -> (project: URL, view: URL)? {
        #if os(macOS)
        guard SourceKitLSPBuildServerTests.hasIOSSimulatorSDK, let d = ProjectTemplates.find("ios.app") else { return nil }
        let form = d.makeForm([TemplateOptionID.productName: "CounterApp", TemplateOptionID.organizationIdentifier: "org.ycode.tests",
                               TemplateOptionID.testingSystem: "Swift Testing"])
        let project = try ProjectGenerator.create(d, form, in: dir)
        let root = project.deletingLastPathComponent()
        try Self.counter.write(to: root.appendingPathComponent("CounterApp/Counter.swift"), atomically: true, encoding: .utf8)
        let view = root.appendingPathComponent("CounterApp/ContentView.swift")
        try Self.view.write(to: view, atomically: true, encoding: .utf8)
        return (project, view)
        #else
        let project = try TemplateStyleProject.write(in: dir, counter: CrossFileLiveIssuesTests.counter)
        return (project, project.deletingLastPathComponent().appendingPathComponent("CounterApp/ContentView.swift"))
        #endif
    }

    @Test func counterResolvesWhenTheServerFollowsTheSchemeAndDestination() async throws {
        guard SourceKitLSP.locate() != nil, let bsp = Self.server else { print("B5LiveDiagnosticsTests: no sourcekit-lsp or ycode-bsp"); return }
        let dir = try freshScratch("b5-p070")
        guard let (project, view) = try makeProject(in: dir) else { print("B5LiveDiagnosticsTests: no iOS Simulator SDK"); return }
        // The build server with its log.
        let log = dir.appendingPathComponent("bsp.log")
        let wrapper = dir.appendingPathComponent("ycode-bsp-logged")
        try "#!/bin/sh\nexec '\(bsp)' \"$@\" --log '\(log.path)'\n".write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        setenv("YCODE_BSP", wrapper.path, 1)
        setenv("YCODE_DERIVED_DATA", dir.appendingPathComponent("DD").path, 1)
        defer { for v in ["YCODE_BSP", "YCODE_DERIVED_DATA"] { unsetenv(v) } }

        // As the window: the server starts with no scheme or destination yet.
        let session = WorkspaceSession(model: try WorkspaceModel(url: project))
        let text = try String(contentsOf: view, encoding: .utf8)
        await session.startLanguageService(opening: [(view, text)])
        #expect(session.language != nil && session.languageServedContext != nil)
        // Then the scheme and the destination arrive: the server restarts.
        session.scheme = "CounterApp"
        #if os(macOS)
        session.destination = Destination(name: "Any iOS Simulator Device", specifier: "generic/platform=iOS Simulator", platform: "iOS", kind: .generic)
        #endif
        await session.languageContextSettled()
        let language = try #require(session.language)
        defer { Task { await language.stop() } }

        let path = view.standardizedFileURL.path
        func errors() -> [String] {
            (language.liveDiagnostics[path] ?? []).filter { $0.severity == 1 }.map(\.message)
        }
        _ = await poll(240) { language.liveDiagnostics[path] != nil && errors().isEmpty }
        let bspLog = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        #expect(language.liveDiagnostics[path] != nil, "no diagnostics; build server log:\n\(bspLog)")
        #expect(errors().isEmpty, "\(errors()); build server log:\n\(bspLog)")
        #expect(!bspLog.contains("no arguments for \(path)"), "\(bspLog)")
    }

    func poll(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return condition()
    }
}

/// Finds this test bundle (`Bundle(for:)`).
private final class B5BundleMarker {}
