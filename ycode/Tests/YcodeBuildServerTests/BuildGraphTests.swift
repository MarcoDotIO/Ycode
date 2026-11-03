import Foundation
import Testing
@testable import YcodeBuildServer
import YcodeXcodebuild

/// Scratch output for these tests (git-ignored `.build-ide`).
let scratch = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent(".build-ide/bsp")

func freshScratch(_ name: String) throws -> URL {
    let d = scratch.appendingPathComponent(name)
    try? FileManager.default.removeItem(at: d)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

@Suite struct BuildGraphTests {
    @Test func targetsSourcesHeadersAndDependencies() throws {
        let dir = try freshScratch("graph")
        let proj = try SampleProject.write(.iOS, in: dir)
        let graph = BuildGraph.load(try Container.open(proj))
        #expect(graph.targets.map(\.name) == ["Kit", "App", "AppTests"])
        let kit = try #require(graph.targets.first { $0.name == "Kit" })
        let app = try #require(graph.targets.first { $0.name == "App" })
        let tests = try #require(graph.targets.first { $0.name == "AppTests" })

        #expect(Set(kit.sources.map { ($0.path as NSString).lastPathComponent }) == ["Greeter.swift", "KitLegacy.m"])
        #expect(Set(kit.headers.map(\.visibility)) == [.public])
        #expect(kit.isFramework && kit.isLibrary && !kit.isTest)
        #expect(kit.languages == [.swift, .objectiveC])

        // App: explicit dependency on Kit; mixed sources.
        #expect(app.dependencies == [kit.id])
        #expect(Set(app.sources.map(\.language)) == [.swift, .objectiveC])
        #expect(app.isApplication)

        // AppTests: sources from its synchronized folder; depends on App.
        #expect(tests.sources.map { ($0.path as NSString).lastPathComponent } == ["AppTests.swift"])
        #expect(tests.dependencies == [app.id])
        #expect(tests.isTest)
        #expect(graph.transitiveDependencies(of: tests).map(\.name) == ["Kit", "App"])

        // Lookup by file, identifiers are URIs.
        let main = dir.appendingPathComponent("Sample-iOS/App/AppMain.swift").path
        #expect(graph.targets(containing: main).map(\.name) == ["App"])
        #expect(URL(string: app.id)?.scheme == "ycode-target")
        #expect(app.id.contains("name=App"))

        // The project file and the synchronized folder are watched.
        let watched = graph.watchedPaths()
        #expect(watched.contains { $0.hasSuffix("Sample.xcodeproj/project.pbxproj") })
        #expect(watched.contains { $0.hasSuffix("Sample-iOS/AppTests") })
    }

    @Test func implicitDependencyThroughLinkedProduct() throws {
        let dir = try freshScratch("graph-implicit")
        let proj = try SampleProject.write(.portable, in: dir)
        // Drop App's explicit dependency: linking Kit.framework still makes one.
        let pbx = proj.appendingPathComponent("project.pbxproj")
        var text = try String(contentsOf: pbx, encoding: .utf8)
        text = text.replacingOccurrences(of: "dependencies = (E00000000000000000000011);", with: "dependencies = ();")
        try text.write(to: pbx, atomically: true, encoding: .utf8)
        let graph = BuildGraph.load(try Container.open(proj))
        let app = try #require(graph.targets.first { $0.name == "App" })
        #expect(app.dependencies.compactMap { graph.target(id: $0)?.name } == ["Kit"])
    }

    @Test func synchronizedFolderExceptionsAndHeaders() throws {
        let dir = try freshScratch("graph-sync")
        let proj = try SampleProject.write(.portable, in: dir)
        let tests = dir.appendingPathComponent("Sample-portable/AppTests")
        try "".write(to: tests.appendingPathComponent("Skipped.swift"), atomically: true, encoding: .utf8)
        try "".write(to: tests.appendingPathComponent("Support.h"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: tests.appendingPathComponent("Nested"), withIntermediateDirectories: true)
        try "".write(to: tests.appendingPathComponent("Nested/More.swift"), atomically: true, encoding: .utf8)
        let pbx = proj.appendingPathComponent("project.pbxproj")
        var text = try String(contentsOf: pbx, encoding: .utf8)
        text = text.replacingOccurrences(of: "{isa = PBXFileSystemSynchronizedRootGroup; path = AppTests;",
                                         with: "{isa = PBXFileSystemSynchronizedRootGroup; exceptions = (B00000000000000000000006); path = AppTests;")
        text = text.replacingOccurrences(of: "\t\tC00000000000000000000001 =",
                                         with: "\t\tB00000000000000000000006 = {isa = PBXFileSystemSynchronizedBuildFileExceptionSet; membershipExceptions = (Skipped.swift); target = E00000000000000000000003; };\n\t\tC00000000000000000000001 =")
        try text.write(to: pbx, atomically: true, encoding: .utf8)
        let graph = BuildGraph.load(try Container.open(proj))
        let t = try #require(graph.targets.first { $0.name == "AppTests" })
        #expect(t.sources.map { ($0.path as NSString).lastPathComponent }.sorted() == ["AppTests.swift", "More.swift"])
        #expect(t.headers.map { ($0.path as NSString).lastPathComponent } == ["Support.h"])
        #expect(t.headers.first?.visibility == .project)
    }
}
