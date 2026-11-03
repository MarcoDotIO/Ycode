import Foundation
import Testing
@testable import YcodeProject

/// `ycode/Samples/SyncFolderSamples` (IDE-SMALL).
let syncSamples = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Samples/SyncFolderSamples")

/// Synchronized folders as the build reads them (`SynchronizedFolder`,
/// `PBXProj.synchronizedMembers`; `specs/formats/pbxproj.md`
/// §Synchronized folders).
@Suite struct SynchronizedFolderTests {
    static func sample() throws -> (PBXProj, URL) {
        let url = syncSamples.appendingPathComponent("SyncFolderSamples.xcodeproj")
        let proj = try PBXProj(contentsOf: url)
        return (proj, proj.projectDirectory(xcodeprojURL: url))
    }

    static func target(_ proj: PBXProj, _ name: String) throws -> PBXObject {
        try #require(proj.targets.first { $0.string("name") == name })
    }

    static func members(_ proj: PBXProj, _ dir: URL, _ name: String) throws -> [SynchronizedMember] {
        let t = try target(proj, name)
        return proj.synchronizedMembers(ofTarget: t.id, projectDirectory: dir).flatMap(\.members)
    }

    @Test func membershipKeysOfLocalizedFiles() {
        #expect(SynchronizedFolder.membershipKey(forRelativePath: "de.lproj/Extra.strings") == "/Localized: Extra.strings")
        #expect(SynchronizedFolder.membershipKey(forRelativePath: "Res/Base.lproj/Main.storyboard") == "/Localized: Res/Main.storyboard")
        #expect(SynchronizedFolder.membershipKey(forRelativePath: "Model/Greeting.swift") == "Model/Greeting.swift")
        // A listed folder covers what is below it.
        #expect(SynchronizedFolder.listed("Excluded/NotBuilt.swift", in: ["Excluded"]))
        #expect(SynchronizedFolder.listed("/Localized: Res/Main.storyboard", in: ["Res"]))
        #expect(!SynchronizedFolder.listed("ExcludedToo.swift", in: ["Excluded"]))
    }

    @Test func treeWithNestedFoldersVariantGroupsAndExplicitFolders() throws {
        let (proj, dir) = try Self.sample()
        let app = try #require(proj.objects(isa: "PBXFileSystemSynchronizedRootGroup").first { $0.string("path") == "SyncApp" })
        let folder = try #require(proj.synchronizedFolder(app.id, projectDirectory: dir))
        #expect(folder.exists)
        let rows = folder.entries.map { "\($0.name):\($0.kind)" }
        // Finder order, folders and files mixed; `.lproj` folders become one
        // localized item; `Docs` (explicitFolders) and the asset catalog are
        // single items; `Data` and `Extras` are groups.
        #expect(rows == ["Assets.xcassets:file", "Data:group", "Docs:file", "Extra.strings:variantGroup", "Extras:group",
                         "Localizable.xcstrings:file", "SyncApp.swift:file"])
        let variant = try #require(folder.entries.first { $0.kind == .variantGroup })
        #expect(variant.children.map(\.region) == ["de", "en"])
        #expect(variant.membershipKey == "/Localized: Extra.strings")
        #expect(folder.entries.first { $0.name == "Docs" }?.fileType == "folder")
        // explicitFileTypes wins over the extension.
        #expect(folder.items.first { $0.path == "Data/note.txt" }?.fileType == "text")
        #expect(folder.filePaths.contains(folder.directory + "/de.lproj/Extra.strings"))
        #expect(!folder.filePaths.contains { $0.hasSuffix("Docs/about.txt") })
    }

    @Test func ownersExcludeAndOtherTargetsInclude() throws {
        let (proj, dir) = try Self.sample()
        let tool = try Self.members(proj, dir, "SyncTool")
        let sources = tool.filter { $0.phase == .sources }.map(\.entry.path)
        // The folder's own target leaves out `Excluded/` (a folder in
        // membershipExceptions); the Shared folder, which the target does
        // not list, gives it only the file its exception set names.
        #expect(Set(sources) == ["Flag.swift", "main.swift", "Model/flag.c", "Model/Greeting.swift", "SharedName.swift"])
        #expect(tool.first { $0.entry.path == "Model/flag.c" }?.compilerFlags == "-DYCODE_SYNC_FLAG=7")
        // No Headers phase and no visibility: the header is not built.
        #expect(!tool.contains { $0.entry.path == "Model/flag.h" })
        let t = try Self.target(proj, "SyncTool")
        #expect(proj.synchronizedFolderIDs(ofTarget: t.id).count == 2)
    }

    @Test func headersVisibilityAndPhaseExceptions() throws {
        let (proj, dir) = try Self.sample()
        let kit = try Self.members(proj, dir, "SyncKit")
        let headers = Dictionary(uniqueKeysWithValues: kit.filter { $0.phase == .headers }.map { ($0.entry.path, $0.headerVisibility?.rawValue ?? "project") })
        #expect(headers == ["SyncKit.h": "public", "SKGreeter.h": "public", "Internal/SKPrivate.h": "private", "Internal/SKProject.h": "project"])
        #expect(kit.filter { $0.phase == .sources }.map(\.entry.path) == ["SKGreeter.m"])

        let app = try Self.members(proj, dir, "SyncApp")
        let copy = try #require(proj.targets.first { $0.string("name") == "SyncApp" }?.references("buildPhases")
            .first { proj[$0]?.isa == "PBXCopyFilesBuildPhase" })
        // The phase exception moves the file out of Resources into its phase.
        #expect(app.filter { $0.phase == .buildPhase(copy) }.map(\.entry.path) == ["Extras/extra.txt"])
        let resources = app.filter { $0.phase == .resources }.map(\.entry.path)
        #expect(resources == ["Assets.xcassets", "Data/note.txt", "Docs", "Extra.strings", "Localizable.xcstrings"])
        #expect(app.filter { $0.phase == .sources }.map(\.entry.path) == ["SyncApp.swift"])
    }

    @Test func phasesByFileType() {
        func phase(_ name: String) -> String? { BuildFileTypes.phase(forType: BuildFileTypes.type(forPath: name), path: name) }
        #expect(phase("a.swift") == "sources" && phase("b.metal") == "sources" && phase("M.xcdatamodeld") == "sources")
        #expect(phase("Kit.framework") == "frameworks" && phase("libz.tbd") == "frameworks" && phase("x.xcframework") == "frameworks")
        #expect(phase("x.h") == "headers")
        #expect(phase("Info.plist") == nil && phase("App.entitlements") == nil && phase("Base.xcconfig") == nil
            && phase("All.xctestplan") == nil && phase("module.modulemap") == nil)
        #expect(phase("Other.plist") == "resources" && phase("Main.storyboard") == "resources" && phase("PrivacyInfo.xcprivacy") == "resources")
    }

    @Test func membershipInversion() throws {
        let text = """
        // !$*UTF8*$!
        {
        \tarchiveVersion = 1;
        \tclasses = {
        \t};
        \tobjectVersion = 77;
        \tobjects = {
        \t\tAA0000000000000000000001 = {isa = PBXProject; mainGroup = AA0000000000000000000002; targets = (AA0000000000000000000004, AA0000000000000000000005, ); };
        \t\tAA0000000000000000000002 = {isa = PBXGroup; children = (AA0000000000000000000003, ); sourceTree = "<group>"; };
        \t\tAA0000000000000000000003 = {isa = PBXFileSystemSynchronizedRootGroup; exceptions = (AA0000000000000000000006, AA0000000000000000000007, ); path = App; sourceTree = "<group>"; };
        \t\tAA0000000000000000000004 = {isa = PBXNativeTarget; buildPhases = (); fileSystemSynchronizedGroups = (AA0000000000000000000003, ); name = App; };
        \t\tAA0000000000000000000005 = {isa = PBXNativeTarget; buildPhases = (); name = Widget; };
        \t\tAA0000000000000000000006 = {isa = PBXFileSystemSynchronizedBuildFileExceptionSet; membershipExceptions = (Secret.swift, ); target = AA0000000000000000000004; };
        \t\tAA0000000000000000000007 = {isa = PBXFileSystemSynchronizedBuildFileExceptionSet; membershipExceptions = (Model.swift, "/Localized: Main.strings", ); target = AA0000000000000000000005; };
        \t};
        \trootObject = AA0000000000000000000001;
        }
        """
        let p = try PBXProj(parsing: text)
        let g = "AA0000000000000000000003", app = "AA0000000000000000000004", widget = "AA0000000000000000000005"
        #expect(p.isSynchronizedMember(key: "Model.swift", folder: g, target: app))
        #expect(!p.isSynchronizedMember(key: "Secret.swift", folder: g, target: app))
        #expect(p.isSynchronizedMember(key: "Model.swift", folder: g, target: widget))
        #expect(!p.isSynchronizedMember(key: "Secret.swift", folder: g, target: widget))
        #expect(p.isSynchronizedMember(key: "/Localized: Main.strings", folder: g, target: widget))
        #expect(p.synchronizedFolderIDs(ofTarget: widget) == [g])
    }
}
