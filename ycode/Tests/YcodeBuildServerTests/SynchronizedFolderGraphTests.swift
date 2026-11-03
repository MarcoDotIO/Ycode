import Foundation
import Testing
@testable import YcodeBuildServer
import YcodeIDECore
import YcodeProject
import YcodeXcodebuild

private let sampleProject = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Samples/SyncFolderSamples/SyncFolderSamples.xcodeproj")

/// The build server, the PIF and the project navigator read synchronized
/// folders through one model (`SynchronizedFolder`), so they list the same
/// files (IDE-SMALL; `language.md` §Build server, `navigators.md`).
@Suite struct SynchronizedFolderGraphTests {
    static func name(_ p: String) -> String {
        p.replacingOccurrences(of: sampleProject.deletingLastPathComponent().standardizedFileURL.path + "/", with: "")
    }

    @Test func sourcesHeadersAndFlagsFromTheSample() throws {
        let graph = BuildGraph.load(try Container.open(sampleProject))
        let tool = try #require(graph.targets.first { $0.name == "SyncTool" })
        #expect(Set(tool.sources.map { Self.name($0.path) }) == ["SyncTool/main.swift", "SyncTool/Flag.swift", "SyncTool/Model/Greeting.swift",
                                                                  "SyncTool/Model/flag.c", "Shared/SharedName.swift"])
        #expect(tool.sources.first { $0.path.hasSuffix("flag.c") }?.flags == "-DYCODE_SYNC_FLAG=7")
        // The tool has no Headers phase: its header is a project header for the index.
        #expect(tool.headers.map { Self.name($0.path) } == ["SyncTool/Model/flag.h"])
        let kit = try #require(graph.targets.first { $0.name == "SyncKit" })
        let headers = Dictionary(uniqueKeysWithValues: kit.headers.map { (Self.name($0.path), $0.visibility) })
        #expect(headers == ["SyncKit/SyncKit.h": .public, "SyncKit/SKGreeter.h": .public, "SyncKit/Internal/SKPrivate.h": .private,
                            "SyncKit/Internal/SKProject.h": .project])
        let empty = try #require(graph.targets.first { $0.name == "EmptyTool" })
        #expect(empty.sources.isEmpty)
        // The `.lproj` folders are watched with the other sub-folders.
        let watched = graph.watchedPaths()
        #expect(watched.contains { $0.hasSuffix("SyncApp/de.lproj") } && watched.contains { $0.hasSuffix("SyncTool/Model") })
        #expect(!watched.contains { $0.hasSuffix("SyncApp/Docs") })
    }

    @Test func navigatorAndBuildServerSeeTheSameFiles() throws {
        let container = try Container.open(sampleProject)
        let graph = BuildGraph.load(container)
        let proj = try PBXProj(contentsOf: sampleProject)
        let tree = NavigatorTree.project(proj, xcodeprojURL: sampleProject)
        let dir = proj.projectDirectory(xcodeprojURL: sampleProject)
        for g in proj.objects(isa: "PBXFileSystemSynchronizedRootGroup") {
            let folder = try #require(proj.synchronizedFolder(g.id, projectDirectory: dir))
            let row = try #require(tree.children.first { $0.objectID == g.id })
            // The navigator's file rows are the folder's files.
            #expect(Set(row.allFiles.compactMap(\.path)) == Set(folder.filePaths), "\(folder.directory)")
        }
        // Every file the build server compiles is a navigator row.
        let rows = Set(tree.allFiles.compactMap(\.path))
        for t in graph.targets {
            for s in t.sources { #expect(rows.contains(s.path), "\(t.name): \(s.path)") }
            for h in t.headers { #expect(rows.contains(h.path), "\(t.name): \(h.path)") }
        }
    }
}
