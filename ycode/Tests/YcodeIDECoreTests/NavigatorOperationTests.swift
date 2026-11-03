import Foundation
import Testing
import YcodeBuild
@testable import YcodeIDECore
import YcodeProject

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/NavigatorOps")

/// A small project on disk for the navigator's file operations: two tool
/// targets, a group with a folder ("Nav"), one without ("Support") and a
/// synchronized folder ("Shared") with an exception for NavTool. Its
/// project file is `Fixtures/NavigatorOps/Base.pbxproj`; each operation's
/// expected file is a hand-written fixture next to it.
struct NavigatorSample {
    static let root = "0E0000000000000000000010"
    static let navGroup = "0D0000000000000000000002"
    static let support = "0D0000000000000000000004"
    static let shared = "0D0000000000000000000010"
    static let mainSwift = "0B0000000000000000000001"
    static let model = "0B0000000000000000000002"
    static let readme = "0B0000000000000000000003"
    static let toolMain = "0B0000000000000000000007"
    static let navTarget = "0E0000000000000000000001"
    static let toolTarget = "0E0000000000000000000002"

    let top: URL
    var dir: URL { top.appendingPathComponent("proj") }
    var extern: URL { top.appendingPathComponent("extern") }
    var xcodeproj: URL { dir.appendingPathComponent("Nav.xcodeproj") }
    var bin: TrashBin { .folder(top.appendingPathComponent("trash")) }

    init() throws {
        top = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("ycode-navops-\(UUID().uuidString)")
        let files: [(String, String)] = [
            ("proj/Nav.xcodeproj/project.pbxproj", try Self.fixture("Base")),
            ("proj/Nav/main.swift", "print(greeting(), Model().value, helper(), debugInfo())\n"),
            ("proj/Nav/Model.swift", "struct Model {\n    var value = 1\n}\n"),
            ("proj/Nav/Helpers.swift", "func helper() -> Int { 2 }\n"),
            ("proj/Nav/ToolMain.swift", "@main\nstruct ToolMain {\n    static func main() { print(Model().value) }\n}\n"),
            ("proj/Shared/Greeting.swift", "func greeting() -> String { \"hi\" }\n"),
            ("proj/Shared/Debug.swift", "func debugInfo() -> String { \"debug\" }\n"),
            ("proj/README.md", "# Nav\n"),
            ("proj/Plugins/Plugin.swift", "func plugin() -> Int { 3 }\n"),
            ("proj/Docs/guide.md", "Guide\n"),
            ("extern/Lib/A.swift", "func a() -> Int { 1 }\n"),
            ("extern/Lib/Assets.xcassets/Contents.json", "{\n  \"info\" : {\n    \"author\" : \"xcode\",\n    \"version\" : 1\n  }\n}\n"),
            ("extern/Lib/data.json", "{}\n"),
            ("extern/Lib/Sub/B.swift", "func b() -> Int { 2 }\n"),
        ]
        for (path, text) in files {
            let u = top.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
    }

    static func fixture(_ name: String) throws -> String {
        try String(contentsOf: fixtures.appendingPathComponent(name + ".pbxproj"), encoding: .utf8)
    }

    func remove() { try? FileManager.default.removeItem(at: top) }

    /// Operations on the sample with predictable new IDs (AA000000…01, …02, …).
    func operations() throws -> ProjectFileOperations {
        var proj = try PBXProj(contentsOf: xcodeproj)
        proj.idSequence = ObjectIDSequence(prefix: "AA")
        return ProjectFileOperations(project: proj, xcodeprojURL: xcodeproj, bin: bin)
    }

    func text(_ p: PBXProj?) -> String { p?.serialized(projectName: "Nav") ?? "" }

    func path(_ rel: String) -> String { dir.appendingPathComponent(rel).path }
    func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: path(rel)) }

    /// Every file and folder under the project folder (but the project
    /// file) with its contents.
    func snapshot() -> [String: String] {
        var out: [String: String] = [:]
        let e = FileManager.default.enumerator(atPath: dir.path)
        while let rel = e?.nextObject() as? String {
            guard !rel.hasPrefix("Nav.xcodeproj"), !rel.hasSuffix(".DS_Store") else { continue }
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: path(rel), isDirectory: &isDir)
            out[rel] = isDir.boolValue ? "<dir>" : (try? String(contentsOfFile: path(rel), encoding: .utf8)) ?? "?"
        }
        return out
    }
}

/// The navigator's file operations (`specs/ide/navigators.md` §Ycode
/// implementation): each one's project file against a hand-written
/// fixture, its effect on disk, and undo and redo.
@Suite(.serialized) struct NavigatorOperationTests {
    typealias S = NavigatorSample

    /// Runs `op` on a fresh sample: the project must match `fixture` and
    /// `disk` must hold; undo restores the base file and the folder; redo
    /// brings the result back.
    func check(_ fixture: String, _ op: (inout ProjectFileOperations, NavigatorSample) throws -> ProjectEdit,
               disk: (NavigatorSample) -> Bool = { _ in true }) throws {
        let s = try NavigatorSample()
        defer { s.remove() }
        var ops = try s.operations()
        let base = try NavigatorSample.fixture("Base")
        #expect(s.text(ops.project) == base)
        let before = s.snapshot()
        var edit = try op(&ops, s)
        let expected = try NavigatorSample.fixture(fixture)
        let written = s.text(ops.project)
        #expect(written == expected, "\(fixture):\n\(written)")
        #expect(disk(s), "\(fixture): disk")
        let after = s.snapshot()
        #expect(s.text(try edit.undo(bin: s.bin)) == base, "\(fixture): undo")
        #expect(s.snapshot() == before, "\(fixture): undo on disk")
        #expect(s.text(try edit.redo(bin: s.bin)) == expected, "\(fixture): redo")
        #expect(s.snapshot() == after, "\(fixture): redo on disk")
    }

    // MARK: Groups and folders

    @Test func newGroupMakesAFolder() throws {
        try check("NewGroup", { ops, _ in try ops.newGroup(named: "Views", in: .object(S.navGroup), withFolder: true) },
                  disk: { $0.exists("Nav/Views") })
    }

    @Test func newGroupWithoutFolderGoesBeforeProducts() throws {
        try check("NewGroupWithoutFolder", { ops, _ in try ops.newGroup(named: "Extras", in: .object(S.root), withFolder: false) },
                  disk: { !$0.exists("Extras") })
    }

    @Test func newFolderInAGroupIsSynchronized() throws {
        try check("NewFolder", { ops, _ in try ops.newFolder(named: "Feature", in: .object(S.navGroup)) }, disk: { $0.exists("Nav/Feature") })
    }

    @Test func newFolderInAFolderIsOnlyADirectory() throws {
        try check("Base", { ops, _ in try ops.newFolder(named: "Sub", in: .object(S.shared)) }, disk: { $0.exists("Shared/Sub") })
    }

    @Test func groupsAreRefusedInFolders() throws {
        let s = try NavigatorSample()
        defer { s.remove() }
        var ops = try s.operations()
        #expect(throws: NavigatorEditError.self) { try ops.newGroup(named: "G", in: .object(S.shared), withFolder: true) }
        #expect(throws: NavigatorEditError.self) { try ops.newGroup(named: "a/b", in: .object(S.navGroup), withFolder: true) }
        #expect(throws: NavigatorEditError.self) { try ops.newFolder(named: "Model.swift", in: .object(S.navGroup)) }
        #expect(s.text(ops.project) == (try NavigatorSample.fixture("Base")))
        #expect(!s.exists("Shared/G"))
    }

    @Test func groupFromSelectionMovesTheFiles() throws {
        try check("GroupFromSelection", { ops, _ in
            try ops.groupFromSelection([.object(S.model), .object(S.mainSwift)], named: "Core", withFolder: true)
        }, disk: { $0.exists("Nav/Core/main.swift") && $0.exists("Nav/Core/Model.swift") && !$0.exists("Nav/main.swift") })
    }

    @Test func groupFromSelectionWithoutFolderLeavesTheFiles() throws {
        try check("GroupFromSelectionWithoutFolder", { ops, _ in
            try ops.groupFromSelection([.object(S.mainSwift), .object(S.model)], named: "Core", withFolder: false)
        }, disk: { $0.exists("Nav/main.swift") && !$0.exists("Nav/Core") })
    }

    @Test func folderFromSelectionMakesASynchronizedFolder() throws {
        try check("FolderFromSelection", { ops, _ in
            try ops.folderFromSelection([.object(S.model), .object(S.toolMain)], named: "Kit")
        }, disk: { $0.exists("Nav/Kit/Model.swift") && $0.exists("Nav/Kit/ToolMain.swift") && !$0.exists("Nav/Model.swift") })
    }

    @Test func folderFromSelectionInAFolderMovesTheExceptions() throws {
        try check("FolderFromSelectionInFolder", { ops, s in
            try ops.folderFromSelection([.disk(s.path("Shared/Debug.swift"))], named: "Diag")
        }, disk: { $0.exists("Shared/Diag/Debug.swift") })
    }

    // MARK: New files

    @Test func newFileGoesAfterTheSelectedFile() throws {
        try check("NewFile", { ops, _ in
            let place = ops.insertionPoint(for: .object(S.model))
            #expect(place.container == .object(S.navGroup) && place.index == 2)
            return try ops.newFiles([("Thing.swift", "struct Thing {}\n")], in: place.container, at: place.index, targets: [S.navTarget])
        }, disk: { (try? String(contentsOfFile: $0.path("Nav/Thing.swift"), encoding: .utf8)) == "struct Thing {}\n" })
    }

    @Test func newFileInAFolderWritesExceptions() throws {
        try check("NewFileSynchronized", { ops, _ in
            try ops.newFiles([("Extra.swift", "")], in: .object(S.shared), targets: [])
        }, disk: { $0.exists("Shared/Extra.swift") })
    }

    @Test func newFileInAFolderForItsTargetsChangesNothing() throws {
        try check("Base", { ops, _ in
            try ops.newFiles([("Extra.swift", "")], in: .object(S.shared), targets: [S.navTarget, S.toolTarget])
        }, disk: { $0.exists("Shared/Extra.swift") })
    }

    @Test func newFileNeverOverwrites() throws {
        let s = try NavigatorSample()
        defer { s.remove() }
        var ops = try s.operations()
        #expect(throws: NavigatorEditError.exists("Model.swift")) { try ops.newFiles([("Model.swift", "x")], in: .object(S.navGroup)) }
        #expect((try? String(contentsOfFile: s.path("Nav/Model.swift"), encoding: .utf8)) == "struct Model {\n    var value = 1\n}\n")
    }

    // MARK: Add Files

    @Test func addFilesCopiesAFolderAsGroups() throws {
        try check("AddFilesGroups", { ops, s in
            try ops.addFiles([s.extern.appendingPathComponent("Lib")], to: .object(S.navGroup),
                             options: AddFilesOptions(action: .copy, grouping: .groups, targets: [S.toolTarget]))
        }, disk: { $0.exists("Nav/Lib/Sub/B.swift") && FileManager.default.fileExists(atPath: $0.extern.appendingPathComponent("Lib/A.swift").path) })
    }

    @Test func addFilesAddsASynchronizedFolder() throws {
        try check("AddFilesFolders", { ops, s in
            try ops.addFiles([s.dir.appendingPathComponent("Plugins")], to: .object(S.root),
                             options: AddFilesOptions(action: .reference, grouping: .folders, targets: [S.navTarget]))
        })
    }

    @Test func addFilesAddsAFolderReference() throws {
        try check("AddFilesFolderReference", { ops, s in
            try ops.addFiles([s.dir.appendingPathComponent("Docs")], to: .object(S.root),
                             options: AddFilesOptions(action: .copy, grouping: .folderReferences, targets: []))
        }, disk: { $0.exists("Docs/guide.md") })
    }

    @Test func addFilesReferencesOutsideFilesInPlace() throws {
        let s = try NavigatorSample()
        defer { s.remove() }
        var ops = try s.operations()
        let src = s.extern.appendingPathComponent("Lib/A.swift")
        let edit = try ops.addFiles([src], to: .object(S.navGroup), options: AddFilesOptions(action: .reference, targets: [S.navTarget]))
        guard case .object(let ref)? = edit.result.first else { Issue.record("no reference"); return }
        // A path that climbs out of the group keeps the file's name.
        #expect(ops.project?[ref]?.string("path") == "../../extern/Lib/A.swift" && ops.project?[ref]?.string("name") == "A.swift")
        #expect(ops.project?.resolvedPath(of: ref, projectDirectory: s.dir) == src.path)
        #expect(!s.exists("Nav/A.swift"))
    }

    @Test func addFilesIntoAFolderCopiesAndExcludes() throws {
        let s = try NavigatorSample()
        defer { s.remove() }
        var ops = try s.operations()
        _ = try ops.addFiles([s.extern.appendingPathComponent("Lib/A.swift")], to: .object(S.shared),
                             options: AddFilesOptions(action: .reference, targets: [S.toolTarget]))
        #expect(s.exists("Shared/A.swift"))
        let m = ops.project?.targetMemberships(ofFile: s.path("Shared/A.swift"), projectDirectory: s.dir).map(\.isMember)
        #expect(m == [false, true])
    }

    // MARK: Delete

    @Test func removeReferenceKeepsTheFile() throws {
        try check("DeleteReference", { ops, _ in try ops.delete([.object(S.toolMain)], moveToTrash: false) },
                  disk: { $0.exists("Nav/ToolMain.swift") })
    }

    @Test func deleteGroupTrashesItsFiles() throws {
        try check("DeleteGroup", { ops, _ in try ops.delete([.object(S.support)], moveToTrash: true) }, disk: { s in
            let trashed = FileManager.default.enumerator(atPath: s.top.appendingPathComponent("trash").path)?.allObjects as? [String] ?? []
            return !s.exists("Nav/Helpers.swift") && trashed.contains { $0.hasSuffix("/Helpers.swift") }
        })
    }

    @Test func deleteSynchronizedFolderTrashesIt() throws {
        try check("DeleteSynchronizedFolder", { ops, _ in try ops.delete([.object(S.shared)], moveToTrash: true) },
                  disk: { !$0.exists("Shared") })
    }

    @Test func deleteFolderItemDropsItsException() throws {
        try check("DeleteFolderItem", { ops, s in try ops.delete([.disk(s.path("Shared/Debug.swift"))], moveToTrash: true) },
                  disk: { !$0.exists("Shared/Debug.swift") })
    }

    @Test func deleteRefusesTheProjectAndBareFolderItems() throws {
        let s = try NavigatorSample()
        defer { s.remove() }
        var ops = try s.operations()
        #expect(throws: NavigatorEditError.self) { try ops.delete([.object(S.root)], moveToTrash: true) }
        #expect(throws: NavigatorEditError.self) { try ops.delete([.disk(s.path("Shared/Debug.swift"))], moveToTrash: false) }
        #expect(s.exists("Shared/Debug.swift"))
    }

    @Test func deleteGroupWithFolderTrashesTheEmptyFolder() throws {
        let s = try NavigatorSample()
        defer { s.remove() }
        var ops = try s.operations()
        var edit = try ops.delete([.object(S.navGroup)], moveToTrash: true)
        #expect(!s.exists("Nav"))
        #expect(ops.project?[S.navGroup] == nil && ops.project?[S.toolMain] == nil && ops.project?[S.support] == nil)
        _ = try edit.undo(bin: s.bin)
        #expect(s.exists("Nav/main.swift") && s.exists("Nav/Helpers.swift"))
        _ = try edit.redo(bin: s.bin)
        #expect(!s.exists("Nav"))
    }

    // MARK: Rename

    @Test func renameFileOnDiskAndInTheProject() throws {
        try check("RenameFile", { ops, _ in try ops.rename(.object(S.model), to: "Store.swift") },
                  disk: { $0.exists("Nav/Store.swift") && !$0.exists("Nav/Model.swift") })
    }

    @Test func renameGroupRenamesItsFolder() throws {
        try check("RenameGroup", { ops, _ in try ops.rename(.object(S.navGroup), to: "App") }, disk: { $0.exists("App/main.swift") })
    }

    @Test func renameGroupWithoutFolderSetsItsName() throws {
        try check("RenameGroupWithoutFolder", { ops, _ in try ops.rename(.object(S.support), to: "Utilities") },
                  disk: { $0.exists("Nav/Helpers.swift") })
    }

    @Test func renameFolderItemFollowsItsException() throws {
        try check("RenameFolderItem", { ops, s in try ops.rename(.disk(s.path("Shared/Debug.swift")), to: "Diagnostics.swift") },
                  disk: { $0.exists("Shared/Diagnostics.swift") })
    }

    @Test func renameChangesTheFileType() throws {
        let s = try NavigatorSample()
        defer { s.remove() }
        var ops = try s.operations()
        let edit = try ops.rename(.object(S.readme), to: "Notes.txt")
        #expect(ops.project?[S.readme]?.string("lastKnownFileType") == "text")
        #expect(edit.moved == [s.path("README.md"): s.path("Notes.txt")])
        #expect(throws: NavigatorEditError.self) { try ops.rename(.object(S.model), to: "main.swift") }
    }

    // MARK: Move

    @Test func moveIntoAGroupWithAFolderMovesTheFile() throws {
        try check("MoveToGroupWithFolder", { ops, _ in try ops.move([.object(S.readme)], to: .object(S.navGroup), at: 0) },
                  disk: { $0.exists("Nav/README.md") && !$0.exists("README.md") })
    }

    @Test func moveIntoAGroupWithoutAFolderRewritesThePath() throws {
        try check("MoveToGroupWithoutFolder", { ops, _ in try ops.move([.object(S.readme)], to: .object(S.support)) },
                  disk: { $0.exists("README.md") })
    }

    @Test func moveIntoASynchronizedFolder() throws {
        try check("MoveIntoSynchronizedFolder", { ops, _ in try ops.move([.object(S.toolMain)], to: .object(S.shared)) },
                  disk: { $0.exists("Shared/ToolMain.swift") })
    }

    @Test func moveOutOfASynchronizedFolder() throws {
        try check("MoveOutOfSynchronizedFolder", { ops, s in try ops.move([.disk(s.path("Shared/Greeting.swift"))], to: .object(S.navGroup)) },
                  disk: { $0.exists("Nav/Greeting.swift") })
    }

    @Test func moveWithinAGroupReorders() throws {
        let s = try NavigatorSample()
        defer { s.remove() }
        var ops = try s.operations()
        _ = try ops.move([.object(S.mainSwift)], to: .object(S.navGroup), at: 3)
        #expect(ops.project?[S.navGroup]?.references("children") == [S.model, S.toolMain, S.mainSwift, S.support])
        #expect(s.exists("Nav/main.swift"))
        #expect(throws: NavigatorEditError.self) { try ops.move([.object(S.navGroup)], to: .object(S.support)) }
    }

    // MARK: Sort

    @Test func sortByNameKeepsProductsLast() throws {
        try check("SortByName", { ops, _ in try ops.sort(.object(S.root), by: .name) })
    }

    @Test func sortByTypePutsGroupsFirst() throws {
        try check("SortByType", { ops, _ in try ops.sort(.object(S.navGroup), by: .type) })
    }

    // MARK: Packages

    @Test func packageOperationsWorkOnDisk() throws {
        let s = try NavigatorSample()
        defer { s.remove() }
        var ops = ProjectFileOperations(packageDirectory: s.extern, bin: s.bin)
        let lib = s.extern.appendingPathComponent("Lib")
        var edits = [try ops.newFolder(named: "New Folder", in: .disk(lib.path))]
        edits.append(try ops.rename(.disk(lib.appendingPathComponent("A.swift").path), to: "Alpha.swift"))
        edits.append(try ops.move([.disk(lib.appendingPathComponent("Alpha.swift").path)], to: .disk(lib.appendingPathComponent("New Folder").path)))
        edits.append(try ops.delete([.disk(lib.appendingPathComponent("data.json").path)], moveToTrash: true))
        #expect(FileManager.default.fileExists(atPath: lib.appendingPathComponent("New Folder/Alpha.swift").path))
        #expect(!FileManager.default.fileExists(atPath: lib.appendingPathComponent("data.json").path))
        for e in edits.reversed() { _ = try e.undo(bin: s.bin) }
        #expect(FileManager.default.fileExists(atPath: lib.appendingPathComponent("A.swift").path))
        #expect(FileManager.default.fileExists(atPath: lib.appendingPathComponent("data.json").path))
        #expect(!FileManager.default.fileExists(atPath: lib.appendingPathComponent("New Folder").path))
    }

    /// A failing step leaves nothing done.
    @Test func failedOperationsRollBack() throws {
        let s = try NavigatorSample()
        defer { s.remove() }
        var ops = try s.operations()
        try "taken\n".write(toFile: s.path("Nav/Lib"), atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) {
            try ops.addFiles([s.extern.appendingPathComponent("Lib/Sub"), s.extern.appendingPathComponent("Lib")], to: .object(S.navGroup),
                             options: AddFilesOptions(action: .copy, targets: []))
        }
        #expect(!s.exists("Nav/Sub"))
        #expect(s.text(ops.project) == (try NavigatorSample.fixture("Base")))
    }
}

/// After each operation the sample still builds with `ycode build` (the
/// xcodebuild engine on macOS). Opt in with `YCODE_NAV_OPS_BUILD=1`; it
/// needs `.build/debug/ycode` (`swift build`). Operations that take a file
/// some code needs are checked with the targets that do not need it.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["YCODE_NAV_OPS_BUILD"] == "1"))
struct NavigatorOperationBuildTests {
    typealias S = NavigatorSample
    static let ycode = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/debug/ycode")

    static let cases: [(String, [String], @Sendable (inout ProjectFileOperations, NavigatorSample) throws -> ProjectEdit)] = [
        ("base", ["Nav", "NavTool"], { ops, _ in try ops.sort(.object(S.navGroup), by: .name) }),
        ("new group", ["Nav", "NavTool"], { ops, _ in try ops.newGroup(named: "Views", in: .object(S.navGroup), withFolder: true) }),
        ("new folder", ["Nav", "NavTool"], { ops, _ in try ops.newFolder(named: "Feature", in: .object(S.navGroup)) }),
        ("new file", ["Nav", "NavTool"], { ops, _ in
            try ops.newFiles([("Thing.swift", "struct Thing {}\n")], in: .object(S.navGroup), at: 2, targets: [S.navTarget])
        }),
        ("new file in folder", ["Nav", "NavTool"], { ops, _ in
            try ops.newFiles([("Extra.swift", "func extra() {}\n")], in: .object(S.shared), targets: [S.toolTarget])
        }),
        ("add files as groups", ["Nav", "NavTool"], { ops, s in
            try ops.addFiles([s.extern.appendingPathComponent("Lib/Sub")], to: .object(S.navGroup),
                             options: AddFilesOptions(action: .copy, grouping: .groups, targets: [S.toolTarget]))
        }),
        ("add synchronized folder", ["Nav", "NavTool"], { ops, s in
            try ops.addFiles([s.dir.appendingPathComponent("Plugins")], to: .object(S.root),
                             options: AddFilesOptions(action: .reference, grouping: .folders, targets: [S.navTarget]))
        }),
        ("remove reference", ["Nav"], { ops, _ in try ops.delete([.object(S.toolMain)], moveToTrash: false) }),
        ("trash group", ["NavTool"], { ops, _ in try ops.delete([.object(S.support)], moveToTrash: true) }),
        ("trash synchronized folder", ["NavTool"], { ops, _ in try ops.delete([.object(S.shared)], moveToTrash: true) }),
        ("trash folder item", ["NavTool"], { ops, s in try ops.delete([.disk(s.path("Shared/Debug.swift"))], moveToTrash: true) }),
        ("rename file", ["Nav", "NavTool"], { ops, _ in try ops.rename(.object(S.model), to: "Store.swift") }),
        ("rename group", ["Nav", "NavTool"], { ops, _ in try ops.rename(.object(S.navGroup), to: "App") }),
        ("rename folder item", ["Nav", "NavTool"], { ops, s in try ops.rename(.disk(s.path("Shared/Debug.swift")), to: "Diagnostics.swift") }),
        ("move to group without folder", ["Nav", "NavTool"], { ops, _ in try ops.move([.object(S.model)], to: .object(S.root)) }),
        ("move into folder", ["Nav", "NavTool"], { ops, _ in try ops.move([.object(S.toolMain)], to: .object(S.shared)) }),
        ("move out of folder", ["Nav", "NavTool"], { ops, s in try ops.move([.disk(s.path("Shared/Greeting.swift"))], to: .object(S.support)) }),
        ("group from selection", ["Nav", "NavTool"], { ops, _ in
            try ops.groupFromSelection([.object(S.mainSwift), .object(S.model)], named: "Core", withFolder: true)
        }),
        ("folder from selection", ["Nav", "NavTool"], { ops, _ in try ops.folderFromSelection([.object(S.model), .object(S.toolMain)], named: "Kit") }),
    ]

    @Test(arguments: 0..<cases.count) func stillBuilds(_ i: Int) throws {
        let (name, schemes, op) = Self.cases[i]
        try #require(FileManager.default.isExecutableFile(atPath: Self.ycode.path), "build ycode first")
        let s = try NavigatorSample()
        defer { s.remove() }
        var ops = try s.operations()
        _ = try op(&ops, s)
        try s.text(ops.project).write(to: s.xcodeproj.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
        for scheme in schemes {
            let p = Process()
            p.executableURL = Self.ycode
            p.arguments = ["build", s.xcodeproj.path, "-scheme", scheme, "-derivedDataPath", s.top.appendingPathComponent("dd").path, "--quiet"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            try p.run()
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            #expect(p.terminationStatus == 0, "\(name), \(scheme):\n\(out)")
        }
    }
}

/// Edit ▸ Convert ▸ To Group / To Folder: memberships are kept both ways.
@Suite(.serialized) struct NavigatorConversionTests {
    typealias S = NavigatorSample

    @Test func convertFolderToGroup() throws {
        try NavigatorOperationTests().check("ConvertToGroup", { ops, _ in try ops.convertToGroup(.object(S.shared)) },
                                             disk: { $0.exists("Shared/Debug.swift") })
    }

    @Test func convertGroupBackToFolder() throws {
        let s = try NavigatorSample()
        defer { s.remove() }
        var ops = try s.operations()
        let toGroup = try ops.convertToGroup(.object(S.shared))
        guard case .object(let group)? = toGroup.result.first else { Issue.record("no group"); return }
        #expect(ops.folderConversionProblems(.object(group)).isEmpty)
        var toFolder = try ops.convertToFolder(.object(group))
        #expect(s.text(ops.project) == (try NavigatorSample.fixture("ConvertBackToFolder")))
        #expect(s.text(try toFolder.undo(bin: s.bin)) == (try NavigatorSample.fixture("ConvertToGroup")))
        #expect(s.text(try toFolder.redo(bin: s.bin)) == (try NavigatorSample.fixture("ConvertBackToFolder")))
    }

    @Test func preflightNamesWhatStopsAConversion() throws {
        let s = try NavigatorSample()
        defer { s.remove() }
        var ops = try s.operations()
        // Nav holds Support, a group without a folder.
        #expect(ops.folderConversionProblems(.object(S.navGroup)) == ["“Support” is not in its group's folder."])
        #expect(!ops.folderConversionProblems(.object(S.root)).isEmpty)
        #expect(throws: NavigatorEditError.self) { try ops.convertToFolder(.object(S.navGroup)) }
        #expect(throws: NavigatorEditError.self) { try ops.convertToGroup(.object(S.navGroup)) }
        // A file only on disk in the group's folder is excluded from every target.
        _ = try ops.delete([.object(S.support)], moveToTrash: false)
        try "let x = 1\n".write(toFile: s.path("Nav/Loose.swift"), atomically: true, encoding: .utf8)
        let edit = try ops.convertToFolder(.object(S.navGroup))
        guard case .object(let folder)? = edit.result.first else { Issue.record("no folder"); return }
        let m = { (rel: String) in ops.project?.targetMemberships(ofFile: s.path(rel), projectDirectory: s.dir).map(\.isMember) }
        #expect(m("Nav/Loose.swift") == [false, false] && m("Nav/Helpers.swift") == [false, false])
        #expect(m("Nav/main.swift") == [true, false] && m("Nav/Model.swift") == [true, true] && m("Nav/ToolMain.swift") == [false, true])
        #expect(ops.project?[folder]?.string("path") == "Nav")
    }
}

extension NavigatorConversionTests {
    /// A template with nested folders: undo takes every new folder back.
    @Test func newFilesInNewFoldersUndoCompletely() throws {
        let s = try NavigatorSample()
        defer { s.remove() }
        var ops = try s.operations()
        let before = s.snapshot()
        var edit = try ops.newFiles([("Art.xcassets/Contents.json", "{}\n"), ("Art.xcassets/Tint.colorset/Contents.json", "{}\n")],
                                    in: .object(S.navGroup), targets: [])
        #expect(s.exists("Nav/Art.xcassets/Tint.colorset/Contents.json"))
        #expect(ops.project?[S.navGroup]?.references("children").count == 5)
        _ = try edit.undo(bin: s.bin)
        #expect(s.snapshot() == before)
        _ = try edit.redo(bin: s.bin)
        #expect(s.exists("Nav/Art.xcassets/Tint.colorset/Contents.json"))
    }
}
