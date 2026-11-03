import Foundation
import Testing
@testable import YcodeXcodebuild
import YcodeBuild
import YcodeProject

/// `ycode/Samples/SyncFolderSamples` (IDE-SMALL).
private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let sampleProject = ycodeDir.appendingPathComponent("Samples/SyncFolderSamples/SyncFolderSamples.xcodeproj")

/// Synchronized folders expanded into the PIF's group tree and build phases
/// (`specs/ide/build-pif.md` §Synchronized folders).
@Suite struct SynchronizedFolderPIFTests {
    /// The PIF of the sample, with lookups by name and GUID.
    struct Loaded {
        var pif: XcodePIF
        var objects: [[String: Any]]
        /// File and group GUID → path relative to the project folder (a
        /// variant group: its localized path).
        var paths: [String: String] = [:]
        var types: [String: String] = [:]

        init(_ project: URL = sampleProject) throws {
            pif = XcodePIF(container: try ContainerLocator.loadProjectContainer(project))
            objects = pif.objects()
            let tree = try #require((objects.first { $0["type"] as? String == "project" }?["contents"] as? [String: Any])?["groupTree"] as? [String: Any])
            func walk(_ node: [String: Any], _ base: String) {
                let path = node["path"] as? String ?? ""
                let full = path.isEmpty ? base : (base.isEmpty ? path : base + "/" + path)
                if let g = node["guid"] as? String {
                    paths[g] = node["type"] as? String == "variantGroup" ? base + "/" + (node["name"] as? String ?? "") : full
                    types[g] = node["type"] as? String
                }
                for c in node["children"] as? [[String: Any]] ?? [] { walk(c, full) }
            }
            walk(tree, "")
        }

        func target(_ name: String) throws -> [String: Any] {
            try #require(objects.compactMap { $0["contents"] as? [String: Any] }.first { $0["name"] as? String == name && $0["buildPhases"] != nil })
        }

        /// A target's phases as (type, [path of each build file]).
        func phases(_ name: String) throws -> [(type: String, files: [String])] {
            try (target(name)["buildPhases"] as? [[String: Any]] ?? []).map { phase in
                (String((phase["type"] as? String ?? "").split(separator: ".").last ?? ""),
                 (phase["buildFiles"] as? [[String: Any]] ?? []).compactMap { ($0["fileReference"] as? String).flatMap { paths[$0] } })
            }
        }

        func buildFile(_ name: String, path: String) throws -> [String: Any] {
            let phases = try target(name)["buildPhases"] as? [[String: Any]] ?? []
            return try #require(phases.flatMap { $0["buildFiles"] as? [[String: Any]] ?? [] }
                .first { ($0["fileReference"] as? String).flatMap { paths[$0] } == path })
        }
    }

    @Test func toolSourcesExceptionsAndFlags() throws {
        let l = try Loaded()
        let phases = try l.phases("SyncTool")
        #expect(phases.map(\.type) == ["sources", "frameworks"])
        #expect(Set(phases[0].files) == ["SyncTool/main.swift", "SyncTool/Flag.swift", "SyncTool/Model/Greeting.swift",
                                          "SyncTool/Model/flag.c", "Shared/SharedName.swift"])
        #expect(try l.buildFile("SyncTool", path: "SyncTool/Model/flag.c")["additionalCompilerOptions"] as? String == "-DYCODE_SYNC_FLAG=7")
        #expect(try l.target("SyncTool")["predominantSourceCodeLanguage"] as? String == "Xcode.SourceCodeLanguage.Swift")
        #expect(l.pif.synchronizedFolderWarnings(targetNames: ["SyncTool"]).isEmpty)
    }

    @Test func appResourcesVariantGroupsAndCopyPhase() throws {
        let l = try Loaded()
        let phases = try l.phases("SyncApp")
        #expect(phases.map(\.type) == ["sources", "frameworks", "resources", "copy-files"])
        #expect(phases[0].files == ["SyncApp/SyncApp.swift"])
        #expect(phases[2].files == ["SyncApp/Assets.xcassets", "SyncApp/Data/note.txt", "SyncApp/Docs", "SyncApp/Extra.strings",
                                    "SyncApp/Localizable.xcstrings"])
        #expect(phases[3].files == ["SyncApp/Extras/extra.txt"])
        // `.lproj` files are one variant group with a file per region.
        let variant = try #require(l.paths.first { $0.value == "SyncApp/Extra.strings" }?.key)
        #expect(l.types[variant] == "variantGroup")
        #expect(Set(l.paths.filter { $0.value.hasSuffix(".lproj/Extra.strings") }.map(\.value))
            == ["SyncApp/de.lproj/Extra.strings", "SyncApp/en.lproj/Extra.strings"])
        // The explicit folder is one item, not expanded.
        #expect(!l.paths.values.contains("SyncApp/Docs/about.txt"))
    }

    @Test func frameworkHeadersByVisibility() throws {
        let l = try Loaded()
        let phases = try l.phases("SyncKit")
        #expect(phases.map(\.type) == ["headers", "sources", "frameworks", "resources"])
        #expect(phases[1].files == ["SyncKit/SKGreeter.m"])
        func visibility(_ p: String) throws -> String? { try l.buildFile("SyncKit", path: "SyncKit/" + p)["headerVisibility"] as? String }
        #expect(try visibility("SyncKit.h") == "public")
        #expect(try visibility("SKGreeter.h") == "public")
        #expect(try visibility("Internal/SKPrivate.h") == "private")
        #expect(try visibility("Internal/SKProject.h") == nil)
    }

    @Test func noSourcesIsAWarning() throws {
        let l = try Loaded()
        let w = l.pif.synchronizedFolderWarnings(targetNames: ["EmptyTool"])
        #expect(w == ["Target \u{201C}EmptyTool\u{201D} compiles no source files: its synchronized folders (\u{201C}EmptyTool\u{201D}) hold none that it builds."])
        // swift-build's engine gets the warnings with the PIF.
        let source = XcodePIFSource(sourcePackagesDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("ycode-sync-pif-packages"))
        let request = BuildRequest(container: .project(sampleProject.path), scheme: "EmptyTool", action: .build)
        let (_, targets, warnings) = try source.pifWithWarnings(for: request)
        #expect(targets == ["SyncTool", "SyncApp", "SyncKit", "EmptyTool"])
        #expect(warnings["EmptyTool"] == w && warnings["SyncTool"] == nil)
    }

    /// A target with no build phases at all (hand-written and generated
    /// projects) still gets its folder's sources; a missing folder warns.
    @Test func missingPhasesAreAddedAndMissingFoldersWarn() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-sync-pif-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let proj = dir.appendingPathComponent("Bare.xcodeproj")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Src"), withIntermediateDirectories: true)
        try "print(1)\n".write(to: dir.appendingPathComponent("Src/main.swift"), atomically: true, encoding: .utf8)
        try "{}\n".write(to: dir.appendingPathComponent("Src/data.json"), atomically: true, encoding: .utf8)
        try """
        // !$*UTF8*$!
        {
        \tarchiveVersion = 1;
        \tclasses = {
        \t};
        \tobjectVersion = 77;
        \tobjects = {
        \t\tAA0000000000000000000001 = {isa = PBXProject; buildConfigurationList = AA0000000000000000000009; mainGroup = AA0000000000000000000002; targets = (AA0000000000000000000004, AA0000000000000000000005, ); };
        \t\tAA0000000000000000000002 = {isa = PBXGroup; children = (AA0000000000000000000003, AA0000000000000000000006, ); sourceTree = "<group>"; };
        \t\tAA0000000000000000000003 = {isa = PBXFileSystemSynchronizedRootGroup; path = Src; sourceTree = "<group>"; };
        \t\tAA0000000000000000000006 = {isa = PBXFileSystemSynchronizedRootGroup; path = Gone; sourceTree = "<group>"; };
        \t\tAA0000000000000000000004 = {isa = PBXNativeTarget; buildPhases = (); fileSystemSynchronizedGroups = (AA0000000000000000000003, ); name = Tool; productType = "com.apple.product-type.tool"; };
        \t\tAA0000000000000000000005 = {isa = PBXNativeTarget; buildPhases = (); fileSystemSynchronizedGroups = (AA0000000000000000000006, ); name = Lost; productType = "com.apple.product-type.tool"; };
        \t\tAA0000000000000000000009 = {isa = XCConfigurationList; buildConfigurations = (AA000000000000000000000A, ); };
        \t\tAA000000000000000000000A = {isa = XCBuildConfiguration; buildSettings = {}; name = Debug; };
        \t};
        \trootObject = AA0000000000000000000001;
        }
        """.write(to: proj.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
        let l = try Loaded(proj)
        // A tool takes no resources, so only a Sources phase is added.
        #expect(try l.phases("Tool").map(\.type) == ["sources"])
        #expect(try l.phases("Tool")[0].files == ["Src/main.swift"])
        let w = l.pif.synchronizedFolderWarnings(targetNames: ["Lost"])
        #expect(w.count == 2)
        #expect(w.first?.hasPrefix("The synchronized folder \u{201C}Gone\u{201D} of target \u{201C}Lost\u{201D} is missing") == true)
        #expect(w.last?.contains("compiles no source files") == true)
    }

    /// swift-build's own generator rejects synchronized folders instead of
    /// describing their targets with no files.
    @Test func builtInGeneratorRejectsSynchronizedFolders() throws {
        let proj = try PBXProj(contentsOf: sampleProject)
        #expect(throws: PIFGenerator.GenerationError.self) { try PIFGenerator(proj: proj, xcodeprojURL: sampleProject).pif() }
    }
}

/// The sample built by ycodebuild through swift-build (skipped without the
/// `ycode-swb` helper): the products run and print what their folders gave
/// them; a target with no sources warns.
@Suite(.serialized, .timeLimit(.minutes(10))) struct SynchronizedFolderBuildTests {
    @Test func samplesBuildAndRun() throws {
        #if os(macOS)
        guard let helper = SwiftBuildEndToEndTests.helper else { return }
        let e2e = SwiftBuildEndToEndTests()
        let dd = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-sync-build-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: dd) }
        let cwd = sampleProject.deletingLastPathComponent().path
        func output(_ exe: String) throws -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            let pipe = Pipe()
            p.standardOutput = pipe
            try p.run()
            p.waitUntilExit()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        let products = dd + "/Build/Products/Debug"
        let tool = e2e.run(["-scheme", "SyncTool", "-derivedDataPath", dd, "build"], cwd: cwd, helper: helper)
        #expect(tool.code == 0, "\(tool.out)\n\(tool.err)")
        #expect(try output(products + "/SyncTool").contains("Hello from a nested synchronized folder from a shared folder [flag 7]"))
        let app = e2e.run(["-scheme", "SyncApp", "-derivedDataPath", dd, "build"], cwd: cwd, helper: helper)
        #expect(app.code == 0, "\(app.out)\n\(app.err)")
        let line = try output(products + "/SyncApp.app/Contents/MacOS/SyncApp")
        #expect(line.contains("table: word") && line.contains("note: a resource") && line.contains("docs: a folder")
            && line.contains("extra: copied") && line.contains("assets: compiled"), "\(line)")
        let kit = e2e.run(["-scheme", "SyncKit", "-derivedDataPath", dd, "build"], cwd: cwd, helper: helper)
        #expect(kit.code == 0, "\(kit.out)\n\(kit.err)")
        let headers = (try? FileManager.default.contentsOfDirectory(atPath: products + "/SyncKit.framework/Versions/A/Headers")) ?? []
        #expect(Set(headers) == ["SKGreeter.h", "SyncKit.h"])
        #expect(FileManager.default.fileExists(atPath: products + "/SyncKit.framework/Versions/A/PrivateHeaders/SKPrivate.h"))
        let empty = e2e.run(["-scheme", "EmptyTool", "-derivedDataPath", dd, "build"], cwd: cwd, helper: helper)
        #expect(empty.out.contains("warning: Target \u{201C}EmptyTool\u{201D} compiles no source files"), "\(empty.out)")
        #endif
    }
}
