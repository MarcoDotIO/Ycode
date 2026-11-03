import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
import YcodeProject
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let fixtures = ycodeDir.appendingPathComponent("Tests/YcodeIDECoreTests/Fixtures/NavigatorOps")

/// The project navigator's file operations driven through the window:
/// menus, the context menu, inline rename, Delete, drag and drop, Add
/// Files, new files and undo (`specs/ide/navigators.md` §Ycode
/// implementation). The sample is the one of `NavigatorOperationTests`.
@MainActor
@Suite(.serialized) struct ProjectNavigatorOperationsTests {
    static let navGroup = "0D0000000000000000000002"
    static let support = "0D0000000000000000000004"
    static let shared = "0D0000000000000000000010"
    static let model = "0B0000000000000000000002"
    static let toolMain = "0B0000000000000000000007"

    @MainActor final class Sample {
        let top: URL
        var dir: URL { top.appendingPathComponent("proj") }
        var xcodeproj: URL { dir.appendingPathComponent("Nav.xcodeproj") }
        var trash: URL { top.appendingPathComponent("trash") }
        let prefs = IsolatedPreferences("navops")
        let oldBin = WorkspaceWindowController.navigatorTrashBin

        init(git: Bool = false) throws {
            top = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("ycode-navops-ui-\(UUID().uuidString)")
            let files: [(String, String)] = [
                ("proj/Nav.xcodeproj/project.pbxproj", try String(contentsOf: fixtures.appendingPathComponent("Base.pbxproj"), encoding: .utf8)),
                ("proj/Nav/main.swift", "print(greeting(), Model().value, helper(), debugInfo())\n"),
                ("proj/Nav/Model.swift", "struct Model {\n    var value = 1\n}\n"),
                ("proj/Nav/Helpers.swift", "func helper() -> Int { 2 }\n"),
                ("proj/Nav/ToolMain.swift", "@main\nstruct ToolMain {\n    static func main() { print(Model().value) }\n}\n"),
                ("proj/Shared/Greeting.swift", "func greeting() -> String { \"hi\" }\n"),
                ("proj/Shared/Debug.swift", "func debugInfo() -> String { \"debug\" }\n"),
                ("proj/README.md", "# Nav\n"),
                ("extern/Notes.txt", "notes\n"),
            ]
            for (path, text) in files {
                let u = top.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: u, atomically: true, encoding: .utf8)
            }
            if git {
                WindowChromeR32Tests.git(dir, ["init", "-q"])
                WindowChromeR32Tests.git(dir, ["add", "-A"])
                WindowChromeR32Tests.git(dir, ["-c", "user.name=Ada Tester", "-c", "user.email=ada@example.com", "commit", "-q", "-m", "Initial"])
            }
            WorkspaceWindowController.navigatorTrashBin = .folder(trash)
        }

        func window() throws -> WorkspaceWindowController {
            let wc = try WindowChromeR32Tests().window(xcodeproj)
            wc.navigator.select(0)
            return wc
        }

        /// The project file on disk.
        var written: String { (try? String(contentsOf: xcodeproj.appendingPathComponent("project.pbxproj"), encoding: .utf8)) ?? "" }
        var base: String { (try? String(contentsOf: fixtures.appendingPathComponent("Base.pbxproj"), encoding: .utf8)) ?? "" }
        func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent(rel).path) }
        func path(_ rel: String) -> String { dir.appendingPathComponent(rel).path }

        func remove() {
            WorkspaceWindowController.navigatorTrashBin = oldBin
            prefs.restore()
            try? FileManager.default.removeItem(at: top)
        }
    }

    func outline(_ wc: WorkspaceWindowController) -> NSOutlineView { wc.navigator.outlineView }

    /// Selects the rows whose object IDs (or paths) are given.
    @discardableResult
    func select(_ wc: WorkspaceWindowController, ids: [String] = [], paths: [String] = []) -> [OutlineItem] {
        wc.navigator.selectProjectRows { row in
            (row.objectID.map(ids.contains) ?? false) || (row.objectID == nil && (row.nodePath.map(paths.contains) ?? false))
        }
    }

    func row(_ wc: WorkspaceWindowController, id: String) -> OutlineItem? {
        func find(_ items: [OutlineItem]) -> OutlineItem? {
            for i in items { if i.objectID == id { return i }; if let f = find(i.children) { return f } }
            return nil
        }
        return find(wc.navigator.rows(0))
    }

    func validated(_ wc: WorkspaceWindowController, _ action: String) -> Bool {
        let i = NSMenuItem(title: "", action: NSSelectorFromString(action), keyEquivalent: "")
        return wc.validateMenuItem(i)
    }

    // MARK: Menus

    @Test func fileAndEditMenuItemsArePerformed() throws {
        let file = CommandTable.menus.first { $0.0 == "File" }!.1
        guard case .submenu(_, let new)? = file.first else { Issue.record("no New submenu"); return }
        let actions = new.compactMap { if case .command(let c) = $0 { c.action } else { nil } }
        for a in ["newGroup:", "newGroupWithoutFolder:", "newGroupFromSelection:", "newGroupFromSelectionWithoutFolder:", "newFolder:",
                  "newFolderFromSelection:"] {
            #expect(actions.contains(a), "\(a)")
        }
        #expect(CommandTable.command(action: "addFiles:")?.shortcutText == "⌥⌘A")
        #expect(CommandTable.command(action: "sortByName:") != nil && CommandTable.command(action: "sortByType:") != nil)
    }

    @Test func enablementFollowsTheSelection() throws {
        let s = try Sample()
        defer { s.remove() }
        let wc = try s.window()
        // No selection: groups, folders and sorting are disabled; Add Files is not.
        for a in ["newGroup:", "newGroupFromSelection:", "newFolder:", "newFolderFromSelection:", "sortByName:"] { #expect(!validated(wc, a), "\(a)") }
        #expect(validated(wc, "addFiles:"))
        // Two files in one group: everything applies.
        select(wc, ids: [Self.model, Self.toolMain])
        for a in ["newGroup:", "newGroupWithoutFolder:", "newGroupFromSelection:", "newFolder:", "newFolderFromSelection:", "sortByType:",
                  "deleteNavigatorSelection:"] { #expect(validated(wc, a), "\(a)") }
        #expect(!validated(wc, "renameNavigatorSelection:"))
        // A file in the synchronized folder: no groups; Folder from Selection works.
        select(wc, paths: [s.path("Shared/Debug.swift")])
        #expect(wc.projectSelectionIsInFolder)
        #expect(!validated(wc, "newGroup:") && validated(wc, "newFolderFromSelection:") && validated(wc, "renameNavigatorSelection:"))
    }

    @Test func contextMenuListsTheOperations() throws {
        let s = try Sample()
        defer { s.remove() }
        let wc = try s.window()
        select(wc, ids: [Self.model])
        let menu = NSMenu()
        wc.navigator.rebuildRowMenu(menu)
        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        #expect(titles == ["Show in Finder", "New File from Template…", "New Empty File", "Add Files to \u{201C}Nav\u{201D}…", "Rename", "Delete",
                           "New Group", "New Group without Folder", "New Group from Selection", "New Group from Selection without Folder",
                           "New Folder", "New Folder from Selection", "Sort by Name", "Sort by Type", "Find in Selected File…"])
        #expect(menu.item(withTitle: "Delete")?.isEnabled == true)
        // In a folder the group and sort items are left out.
        select(wc, paths: [s.path("Shared/Debug.swift")])
        wc.navigator.rebuildRowMenu(menu)
        #expect(menu.item(withTitle: "New Group") == nil && menu.item(withTitle: "Sort by Name") == nil && menu.item(withTitle: "New Folder") != nil)
    }

    // MARK: Groups and folders, with undo

    @Test func newGroupWritesTheProjectAndUndoes() throws {
        let s = try Sample()
        defer { s.remove() }
        let wc = try s.window()
        select(wc, ids: [Self.model])
        let edit = try #require(wc.newNavigatorGroup(withFolder: true))
        guard case .object(let id)? = edit.result.first else { Issue.record("no group"); return }
        #expect(s.written.contains("\(id) /* New Group */ = {") && s.exists("Nav/New Group"))
        // The new group sits after Model.swift and is selected.
        let proj = try PBXProj(contentsOf: s.xcodeproj)
        #expect(proj[Self.navGroup]?.references("children").dropFirst(2).first == id)
        #expect(wc.navigator.selectedProjectRows.map(\.objectID) == [id])
        #expect(wc.window?.undoManager?.undoActionName == "New Group")
        wc.window?.undoManager?.undo()
        #expect(s.written == s.base && !s.exists("Nav/New Group"))
        wc.window?.undoManager?.redo()
        #expect(s.written.contains("/* New Group */") && s.exists("Nav/New Group"))
    }

    @Test func groupAndFolderFromSelection() throws {
        let s = try Sample()
        defer { s.remove() }
        let wc = try s.window()
        select(wc, ids: [Self.model, Self.toolMain])
        _ = try #require(wc.folderFromNavigatorSelection())
        #expect(s.exists("Nav/New Folder/Model.swift") && s.exists("Nav/New Folder/ToolMain.swift"))
        let proj = try PBXProj(contentsOf: s.xcodeproj)
        #expect(proj.objects(isa: "PBXFileSystemSynchronizedRootGroup").count == 2 && proj[Self.model] == nil)
        wc.window?.undoManager?.undo()
        #expect(s.written == s.base && s.exists("Nav/Model.swift"))
        select(wc, ids: [Self.model])
        _ = try #require(wc.groupFromNavigatorSelection(withFolder: false))
        #expect(try PBXProj(contentsOf: s.xcodeproj).objects(isa: "PBXGroup").contains { $0.string("name") == "New Group" })
    }

    @Test func newFolderInAGroupIsSynchronizedInAFolderPlain() throws {
        let s = try Sample()
        defer { s.remove() }
        let wc = try s.window()
        select(wc, ids: [Self.toolMain])
        let url = try #require(wc.newFolder(nil))
        #expect(url.path == s.path("Nav/New Folder") && s.written.contains("/* New Folder */ = {\n\t\t\tisa = PBXFileSystemSynchronizedRootGroup;"))
        select(wc, paths: [s.path("Shared/Debug.swift")])
        let before = s.written
        let inner = try #require(wc.newFolder(nil))
        #expect(inner.path == s.path("Shared/New Folder") && s.written == before)
    }

    // MARK: Rename

    @Test func inlineRenameRenamesTheFileAndTheEditorFollows() throws {
        let s = try Sample()
        defer { s.remove() }
        let wc = try s.window()
        wc.open(path: s.path("Nav/Model.swift"), line: nil)
        let row = try #require(select(wc, ids: [Self.model]).first)
        // Return starts the rename.
        let ret = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        outline(wc).keyDown(with: ret)
        #expect(wc.navigator.renamingRow === row)
        wc.navigator.commitRename("Store.swift")
        #expect(s.exists("Nav/Store.swift") && !s.exists("Nav/Model.swift"))
        #expect(s.written.contains("path = Store.swift;") && !s.written.contains("Model.swift"))
        #expect(wc.editor.fileURL?.lastPathComponent == "Store.swift")
        #expect(wc.navigator.selectedProjectRows.map(\.nodePath) == [s.path("Nav/Store.swift")])
        // The field starts from the full name even where extensions are hidden.
        #expect(wc.navigator.editableName(try #require(wc.navigator.selectedProjectRows.first)) == "Store.swift")
        wc.window?.undoManager?.undo()
        #expect(s.exists("Nav/Model.swift") && s.written == s.base && wc.editor.fileURL?.lastPathComponent == "Model.swift")
    }

    @Test func renameIsStagedInGit() async throws {
        let s = try Sample(git: true)
        defer { s.remove() }
        let wc = try s.window()
        let row = try #require(select(wc, ids: [Self.model]).first)
        _ = try #require(wc.renameNavigatorRow(row, to: "Store.swift"))
        var status = ""
        for _ in 0..<50 {
            status = WindowChromeR32Tests.git(s.dir, ["status", "--porcelain"])
            if status.contains("Nav/Model.swift -> Nav/Store.swift") { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(status.contains("R  Nav/Model.swift -> Nav/Store.swift"), "\(status)")
    }

    // MARK: Delete

    @Test func deleteKeyAsksThenTrashesAndUndoRestores() throws {
        let s = try Sample()
        defer { s.remove() }
        let wc = try s.window()
        select(wc, ids: [Self.support])
        // Without a visible window Delete asks nothing and changes nothing.
        let del = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: 51))
        outline(wc).keyDown(with: del)
        #expect(s.written == s.base)
        _ = try #require(wc.deleteNavigatorItems(moveToTrash: true))
        #expect(!s.exists("Nav/Helpers.swift") && !s.written.contains("Support") && !s.written.contains("Helpers.swift"))
        let trashed = FileManager.default.enumerator(atPath: s.trash.path)?.allObjects as? [String] ?? []
        #expect(trashed.contains { $0.hasSuffix("Helpers.swift") })
        #expect(wc.window?.undoManager?.undoActionName == "Move to Trash")
        wc.window?.undoManager?.undo()
        #expect(s.exists("Nav/Helpers.swift") && s.written == s.base)
        // Remove References keeps the file.
        select(wc, ids: [Self.toolMain])
        _ = try #require(wc.deleteNavigatorItems(moveToTrash: false))
        #expect(s.exists("Nav/ToolMain.swift") && !s.written.contains("ToolMain.swift"))
    }

    // MARK: Drag and drop

    @Test func dragMovesRowsIntoGroupsAndFolders() throws {
        let s = try Sample()
        defer { s.remove() }
        let wc = try s.window()
        let o = outline(wc)
        let readme = try #require(row(wc, id: "0B0000000000000000000003"))
        let root = try #require(wc.navigator.rows(0).first)
        // Files and groups can be dragged; the project row cannot.
        #expect(wc.navigator.outlineView(o, pasteboardWriterForItem: readme) != nil)
        #expect(wc.navigator.outlineView(o, pasteboardWriterForItem: root) == nil)
        // A drop on a file lands after it in its group.
        let model = try #require(row(wc, id: Self.model))
        let target = try #require(wc.navigator.dropTarget(model, NSOutlineViewDropOnItemIndex))
        #expect(target.0.objectID == Self.navGroup && target.1 == 2)
        let nav = try #require(row(wc, id: Self.navGroup))
        _ = try #require(wc.moveNavigatorRows([readme], to: nav, at: 0))
        #expect(s.exists("Nav/README.md") && !s.exists("README.md"))
        #expect(try PBXProj(contentsOf: s.xcodeproj)[Self.navGroup]?.references("children").first == "0B0000000000000000000003")
        wc.window?.undoManager?.undo()
        #expect(s.exists("README.md") && s.written == s.base)
        // Into the synchronized folder: the reference goes, Nav gets an exception.
        let tool = try #require(row(wc, id: Self.toolMain))
        let shared = try #require(row(wc, id: Self.shared))
        _ = try #require(wc.moveNavigatorRows([tool], to: shared, at: nil))
        #expect(s.exists("Shared/ToolMain.swift") && s.written.contains("Exceptions for \"Shared\" folder in \"Nav\" target"))
    }

    // MARK: Add Files and new files

    @Test func addFilesReferencesOrCopies() throws {
        let s = try Sample()
        defer { s.remove() }
        let wc = try s.window()
        select(wc, ids: [Self.model])
        let notes = s.top.appendingPathComponent("extern/Notes.txt")
        _ = try #require(wc.addFilesToNavigator([notes], options: AddFilesOptions(action: .copy, targets: [])))
        #expect(s.exists("Nav/Notes.txt") && s.written.contains("/* Notes.txt */ = {isa = PBXFileReference; lastKnownFileType = text; path = Notes.txt;"))
        wc.window?.undoManager?.undo()
        #expect(!s.exists("Nav/Notes.txt") && s.written == s.base && FileManager.default.fileExists(atPath: notes.path))
        // The accessory reads back what it shows.
        let acc = AddFilesAccessory(project: try PBXProj(contentsOf: s.xcodeproj),
                                    options: AddFilesOptions(action: .reference, grouping: .folders, targets: ["0E0000000000000000000002"]))
        #expect(acc.options == AddFilesOptions(action: .reference, grouping: .folders, targets: ["0E0000000000000000000002"]))
        #expect(acc.targetBoxes.map(\.title) == ["Nav", "NavTool"])
    }

    @Test func newFileGoesIntoTheSelectedGroup() throws {
        let s = try Sample()
        defer { s.remove() }
        let wc = try s.window()
        // Support has no folder: its files live in Nav/, yet the file joins Support.
        select(wc, ids: [Self.support])
        #expect(wc.newFileDirectory.path == s.path("Nav"))
        let urls = try wc.createFile(entry: TemplateEntry("Swift File"), name: "Tool", targets: ["Nav"])
        #expect(urls.map(\.path) == [s.path("Nav/Tool.swift")])
        let proj = try PBXProj(contentsOf: s.xcodeproj)
        let ref = try #require(proj.objects(isa: "PBXFileReference").first { $0.string("path") == "Tool.swift" })
        #expect(proj[Self.support]?.references("children").last == ref.id)
        #expect(wc.window?.undoManager?.undoActionName == "New File")
        wc.window?.undoManager?.undo()
        #expect(!s.exists("Nav/Tool.swift") && s.written == s.base)
    }

    @Test func newFileInAFolderWritesTheUnchosenTargetsExceptions() throws {
        let s = try Sample()
        defer { s.remove() }
        let wc = try s.window()
        select(wc, paths: [s.path("Shared/Debug.swift")])
        _ = try wc.createFile(entry: TemplateEntry("Swift File"), name: "Extra", targets: ["Nav"])
        #expect(s.exists("Shared/Extra.swift"))
        let proj = try PBXProj(contentsOf: s.xcodeproj)
        #expect(proj["0C0000000000000000000001"]?.references("membershipExceptions") == ["Debug.swift", "Extra.swift"])
    }

    @Test func sortCommandsReorderTheGroup() throws {
        let s = try Sample()
        defer { s.remove() }
        let wc = try s.window()
        select(wc, ids: [Self.model])
        _ = try #require(wc.sortNavigatorGroup(.type))
        #expect(try PBXProj(contentsOf: s.xcodeproj)[Self.navGroup]?.references("children").first == Self.support)
    }

    @Test func cutThenMoveItemHere() throws {
        let s = try Sample()
        defer { s.remove() }
        let wc = try s.window()
        #expect(!validated(wc, "moveItemHere:") && !wc.menuContext.hasItemToMove)
        select(wc, ids: ["0B0000000000000000000003"])
        wc.navigator.cut(nil)
        #expect(wc.menuContext.hasItemToMove && s.exists("README.md"))
        select(wc, ids: [Self.toolMain])
        #expect(validated(wc, "moveItemHere:"))
        _ = try #require(wc.moveCutItemsHere())
        #expect(s.exists("Nav/README.md") && wc.navigator.itemsToMove == nil)
        #expect(try PBXProj(contentsOf: s.xcodeproj)[Self.navGroup]?.references("children")
            == ["0B0000000000000000000001", Self.model, Self.toolMain, "0B0000000000000000000003", Self.support])
    }

    @Test func convertCommandsFollowTheSelection() throws {
        let s = try Sample()
        defer { s.remove() }
        let wc = try s.window()
        select(wc, ids: [Self.shared])
        #expect(validated(wc, "convertToGroup:") && !validated(wc, "convertToFolder:"))
        let edit = try #require(wc.convertNavigatorSelection(toFolder: false))
        guard case .object(let group)? = edit.result.first else { Issue.record("no group"); return }
        #expect(wc.navigator.selectedProjectRows.map(\.objectID) == [group])
        #expect(validated(wc, "convertToFolder:") && wc.preflightConversionToFolder(nil).isEmpty)
        _ = try #require(wc.convertNavigatorSelection(toFolder: true))
        #expect(try PBXProj(contentsOf: s.xcodeproj).objects(isa: "PBXFileSystemSynchronizedRootGroup").count == 1)
        // Nav holds a group without a folder.
        select(wc, ids: [Self.navGroup])
        #expect(wc.preflightConversionToFolder(nil) == ["“Support” is not in its group's folder."])
    }

    // MARK: Packages

    @Test func packageRowsRenameAndTrashOnDisk() throws {
        let r32 = WindowChromeR32Tests()
        let dir = try r32.package("navops-package")
        let prefs = IsolatedPreferences("navops-pkg")
        let oldBin = WorkspaceWindowController.navigatorTrashBin
        WorkspaceWindowController.navigatorTrashBin = .folder(dir.appendingPathComponent(".trash-test"))
        defer { WorkspaceWindowController.navigatorTrashBin = oldBin; prefs.restore(); try? FileManager.default.removeItem(at: dir) }
        let wc = try r32.window(dir)
        wc.navigator.select(0)
        let helper = dir.appendingPathComponent("Sources/Chrome/Helper.swift").path
        let row = try #require(select(wc, paths: [helper]).first)
        _ = try #require(wc.renameNavigatorRow(row, to: "Helpers.swift"))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Sources/Chrome/Helpers.swift").path))
        #expect(wc.session.model.root.find(path: dir.appendingPathComponent("Sources/Chrome/Helpers.swift").path) != nil)
        select(wc, paths: [dir.appendingPathComponent("Sources/Chrome/Helpers.swift").path])
        _ = try #require(wc.deleteNavigatorItems(moveToTrash: true))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("Sources/Chrome/Helpers.swift").path))
        // Both edits happened in one event, so one undo takes back both.
        wc.window?.undoManager?.undo()
        #expect(FileManager.default.fileExists(atPath: helper))
    }
}
