import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeIDEShell
import YcodeProject

/// A temporary copy of the core's navigator sample project
/// (`YcodeIDECoreTests/Fixtures/NavigatorOps/Base.pbxproj`): a group with
/// a folder ("Nav"), a group without one ("Support"), a synchronized
/// folder ("Shared"), README.md.
@MainActor
struct ShellNavigatorSample {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("YcodeIDECoreTests/Fixtures/NavigatorOps/Base.pbxproj")
    let top: URL
    var dir: URL { top.appendingPathComponent("proj") }
    var xcodeproj: URL { dir.appendingPathComponent("Nav.xcodeproj") }
    var pbxproj: URL { xcodeproj.appendingPathComponent("project.pbxproj") }
    let base: String
    let model: WorkspaceShellModel

    /// `localPackage`: the project also depends on a local package "Kit"
    /// (Kit/Package.swift, Kit/Sources/Kit/Kit.swift).
    init(localPackage: Bool = false) throws {
        top = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().appendingPathComponent("ycode-shellnav-\(UUID().uuidString)")
        var text = try String(contentsOf: Self.fixture, encoding: .utf8)
        if localPackage {
            text = text.replacingOccurrences(of: "\t\t\tmainGroup = 0D0000000000000000000001;\n",
                                             with: "\t\t\tmainGroup = 0D0000000000000000000001;\n\t\t\tpackageReferences = (\n\t\t\t\tAB0000000000000000000001 /* XCLocalSwiftPackageReference \"Kit\" */,\n\t\t\t);\n")
            text = text.replacingOccurrences(of: "/* Begin XCBuildConfiguration section */",
                                             with: "/* Begin XCLocalSwiftPackageReference section */\n\t\tAB0000000000000000000001 /* XCLocalSwiftPackageReference \"Kit\" */ = {\n\t\t\tisa = XCLocalSwiftPackageReference;\n\t\t\trelativePath = Kit;\n\t\t};\n/* End XCLocalSwiftPackageReference section */\n\n/* Begin XCBuildConfiguration section */")
        }
        base = text
        let files: [(String, String)] = [
            ("proj/Nav.xcodeproj/project.pbxproj", base),
            ("proj/Nav/main.swift", "print(greeting(), Model().value, helper(), debugInfo())\n"),
            ("proj/Nav/Model.swift", "struct Model {\n    var value = 1\n}\n"),
            ("proj/Nav/Helpers.swift", "func helper() -> Int { 2 }\n"),
            ("proj/Nav/ToolMain.swift", "@main\nstruct ToolMain {\n    static func main() { print(Model().value) }\n}\n"),
            ("proj/Shared/Greeting.swift", "func greeting() -> String { \"hi\" }\n"),
            ("proj/Shared/Debug.swift", "func debugInfo() -> String { \"debug\" }\n"),
            ("proj/README.md", "# Nav\n"),
        ] + (localPackage ? [("proj/Kit/Package.swift", "// swift-tools-version: 6.0\n"), ("proj/Kit/Sources/Kit/Kit.swift", "public let kit = 1\n")] : [])
        for (path, text) in files {
            let u = top.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        model = try WorkspaceShellModel(url: top.appendingPathComponent("proj/Nav.xcodeproj"), engine: ScriptedEngine(lines: [], issues: []))
        model.navigatorState.trashBin = .folder(top.appendingPathComponent("trash"))
    }

    func remove() { try? FileManager.default.removeItem(at: top) }

    /// The project file on disk.
    var written: String { (try? String(contentsOf: pbxproj, encoding: .utf8)) ?? "" }

    /// The project file read back has the model's object graph (the
    /// writer's output parses to what was written).
    func roundTrips() throws -> Bool {
        let reparsed = try PBXProj(contentsOf: xcodeproj)
        return reparsed.objects == model.session.model.projects[xcodeproj.path]?.objects
    }

    func path(_ rel: String) -> String { dir.appendingPathComponent(rel).path }
    func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: path(rel)) }

    /// The row with this title under the project row (its parents opened).
    func row(_ title: String) -> String? {
        func walk(_ n: NavigatorItem) -> NavigatorItem? {
            if n.name == title { return n }
            for c in n.children ?? [] { if let f = walk(c) { return f } }
            return nil
        }
        guard let item = (model.root.children ?? []).lazy.compactMap(walk).first else { return nil }
        for a in (model.root.ancestry(ofID: item.id) ?? []).dropLast() { model.setExpanded(a.id, true) }
        return item.id
    }

    func select(_ title: String) {
        guard let id = row(title) else { return }
        model.clickProjectRow(id, rows: model.projectRows)
    }
}

/// B5-NAVIGATOR (P-052, P-041, P-043, P-051, P-037) on Linux: the Project
/// navigator's file operations through the shared `ProjectFileOperations`,
/// written through the pbxproj writer, each one read back and undone.
@MainActor
@Suite(.serialized) struct NavigatorFileOperationsShellTests {
    typealias S = ShellNavigatorSample

    @Test func newGroupIsRenamedInPlaceAndRoundTrips() throws {
        let s = try S()
        defer { s.remove() }
        s.select("Nav")
        let edit = s.model.newNavigatorGroup(withFolder: true)
        #expect(edit?.actionName == "New Group")
        #expect(s.exists("Nav/New Group"))
        #expect(try s.roundTrips())
        // The new row is selected, open (P-043) and edited in place.
        let id = try #require(s.model.selection)
        #expect(s.model.root.find(id: id)?.name == "New Group")
        #expect(s.model.navigatorState.renaming == id)
        #expect(s.model.expanded.contains(id))
        #expect(s.model.navigatorUndoTitle == "Undo New Group")
        let afterNew = s.written
        // Return commits the name.
        #expect(s.model.renameNavigatorRow(id, to: "Things") != nil)
        #expect(s.model.navigatorState.renaming == nil)
        #expect(s.exists("Nav/Things") && !s.exists("Nav/New Group"))
        #expect(try s.roundTrips())
        #expect(s.written.contains("path = Things;"))
        // Undo the rename: the file as it was, byte for byte; then the group.
        #expect(s.model.undoNavigatorEdit())
        #expect(s.written == afterNew)
        #expect(s.exists("Nav/New Group"))
        #expect(s.model.undoNavigatorEdit())
        #expect(s.written == s.base)
        #expect(!s.exists("Nav/New Group"))
        // Redo brings both back.
        #expect(s.model.navigatorRedoTitle == "Redo New Group")
        #expect(s.model.redoNavigatorEdit())
        #expect(s.written == afterNew)
        #expect(s.model.redoNavigatorEdit())
        #expect(s.exists("Nav/Things"))
        #expect(try s.roundTrips())
    }

    @Test func groupWithoutFolderAndNewFolder() throws {
        let s = try S()
        defer { s.remove() }
        s.select("Model.swift")
        #expect(s.model.newNavigatorGroup(withFolder: false)?.actionName == "New Group without Folder")
        #expect(!s.exists("Nav/New Group"))
        #expect(s.written.contains("name = \"New Group\";"))
        #expect(try s.roundTrips())
        s.select("Nav")
        #expect(s.model.newNavigatorFolder() != nil)
        #expect(s.exists("Nav/New Folder"))
        #expect(s.written.contains("PBXFileSystemSynchronizedRootGroup"))
        #expect(try s.roundTrips())
        #expect(s.model.undoNavigatorEdit() && s.model.undoNavigatorEdit())
        #expect(s.written == s.base)
    }

    @Test func deleteAsksAndRemovesReferencesOrTrashes() throws {
        let s = try S()
        defer { s.remove() }
        // The project row has no Delete (P-041).
        #expect(!s.model.isNavigatorCommandEnabled(.delete, rows: [s.model.root.id]))
        s.select("README.md")
        s.model.askDeleteNavigatorSelection()
        let prompt = try #require(s.model.navigatorState.deletePrompt)
        #expect(prompt.title == "Delete \u{201C}README.md\u{201D}?")
        #expect(prompt.buttons == ["Move to Trash", "Remove References", "Cancel"])
        #expect(s.model.answerDeletePrompt("Remove References")?.actionName == "Remove References")
        #expect(s.exists("README.md"))
        #expect(!s.written.contains("README.md"))
        #expect(try s.roundTrips())
        #expect(s.model.undoNavigatorEdit())
        #expect(s.written == s.base)
        // Move to Trash: the file goes to the trash (a folder here), back on undo.
        s.select("Model.swift")
        s.model.askDeleteNavigatorSelection()
        #expect(s.model.answerDeletePrompt("Move to Trash")?.actionName == "Move to Trash")
        #expect(!s.exists("Nav/Model.swift"))
        #expect(try s.roundTrips())
        #expect(s.model.undoNavigatorEdit())
        #expect(s.exists("Nav/Model.swift"))
        #expect(s.written == s.base)
        // Cancel does nothing.
        s.select("Model.swift")
        s.model.askDeleteNavigatorSelection()
        #expect(s.model.answerDeletePrompt("Cancel") == nil)
        #expect(s.written == s.base)
        // An item in a synchronized folder has no reference: Trash only.
        s.select("Greeting.swift")
        s.model.askDeleteNavigatorSelection()
        #expect(s.model.navigatorState.deletePrompt?.buttons == ["Move to Trash", "Cancel"])
        s.model.navigatorState.deletePrompt = nil
    }

    @Test func moveSortAndEditorsFollowARename() throws {
        let s = try S()
        defer { s.remove() }
        // Helpers.swift (in Support, a group without a folder) to Nav.
        let helpers = try #require(s.row("Helpers.swift"))
        let nav = try #require(s.row("Nav"))
        #expect(s.model.moveNavigatorRows([helpers], to: nav)?.actionName == "Move")
        #expect(try s.roundTrips())
        // Not into itself.
        #expect(s.model.moveNavigatorRows([nav], to: nav) == nil)
        // A drag move is not undoable (P-042): move it back by hand.
        #expect(!s.model.undoNavigatorEdit())
        let moved = try #require(s.row("Helpers.swift"))
        let support = try #require(s.row("Support"))
        #expect(s.model.moveNavigatorRows([moved], to: support, at: 0) != nil)
        #expect(s.exists("Nav/Helpers.swift") && s.written == s.base)
        // Sort by Name.
        s.select("Nav")
        #expect(s.model.sortNavigatorGroup(.name)?.actionName == "Sort by Name")
        #expect(try s.roundTrips())
        #expect(s.model.undoNavigatorEdit())
        #expect(s.written == s.base)
        // The open file follows a rename.
        s.select("main.swift")
        #expect(s.model.document?.path.hasSuffix("Nav/main.swift") == true)
        let main = try #require(s.row("main.swift"))
        #expect(s.model.renameNavigatorRow(main, to: "app.swift") != nil)
        #expect(s.model.document?.path.hasSuffix("Nav/app.swift") == true)
        #expect(s.exists("Nav/app.swift"))
        #expect(try s.roundTrips())
        #expect(s.model.undoNavigatorEdit())
        #expect(s.model.document?.path.hasSuffix("Nav/main.swift") == true)
        #expect(s.written == s.base)
    }

    @Test func menusFollowTheRowKind() throws {
        let s = try S()
        defer { s.remove() }
        let titles = { (k: ProjectRowMenu.RowKind) in ProjectRowMenu.titles(ProjectRowMenu.entries(for: k), projectName: "Nav", kind: k) }
        #expect(!titles(.project).contains("Delete"))
        #expect(titles(.file).contains("Delete"))
        let model = try #require(s.row("Model.swift"))
        #expect(s.model.isNavigatorCommandEnabled(.delete, rows: [model]))
        #expect(s.model.isNavigatorCommandEnabled(.showInFinder, rows: [model]))
        // What Ycode cannot do on Linux yet is disabled.
        #expect(!s.model.isNavigatorCommandEnabled(.openInNewWindow, rows: [model]))
        // A right-clicked row outside the selection is acted on alone;
        // inside it, the selection is.
        s.select("main.swift")
        #expect(s.model.rowsForMenu(on: model) == [model])
        #expect(s.model.rowsForMenu(on: s.model.selection) == [s.model.selection!])
        // The menu bar's actions route here.
        s.select("Nav")
        #expect(s.model.validateProjectNavigatorAction("newGroup:") == true)
        #expect(s.model.validateProjectNavigatorAction("saveDocument:") == nil)
        #expect(s.model.performProjectNavigatorAction("newGroupWithoutFolder:"))
        #expect(s.model.navigatorUndoTitle == "Undo New Group without Folder")
        // File ▸ New ▸ Group is hidden in a folder; Move Item Here shows after a Cut.
        var ctx = MenuContext()
        s.select("Nav")
        s.model.fillNavigatorMenuContext(&ctx)
        #expect(!ctx.projectSelectionInFolder && !ctx.hasItemToMove)
        s.select("Greeting.swift")
        s.model.cutNavigatorSelection()
        s.model.fillNavigatorMenuContext(&ctx)
        #expect(ctx.projectSelectionInFolder && ctx.hasItemToMove)
    }

    @Test func multipleSelectionTypeSelectAndExpansion() throws {
        let s = try S()
        defer { s.remove() }
        _ = s.row("main.swift")
        let rows = s.model.projectRows
        let main = try #require(s.row("main.swift")), tool = try #require(s.row("ToolMain.swift"))
        s.model.clickProjectRow(main, rows: rows)
        s.model.clickProjectRow(tool, rows: rows, extend: true)
        #expect(s.model.selectedProjectRowIDs.count == 3)   // main, Model, ToolMain
        s.model.clickProjectRow(main, rows: rows, toggle: true)
        #expect(s.model.selectedProjectRowIDs.count == 2)
        #expect(!s.model.isProjectRowSelected(main))
        s.model.askDeleteNavigatorSelection()
        #expect(s.model.navigatorState.deletePrompt?.title == "Delete 2 items?")
        s.model.navigatorState.deletePrompt = nil
        // Type-select: the next row starting with the letters.
        #expect(OutlineRows.typeSelect(rows, current: main, prefix: "t") == tool)
        #expect(rows.first { $0.id == OutlineRows.typeSelect(rows, current: nil, prefix: "rea") }?.title.hasPrefix("README") == true)
        // ⌥← closes a row and everything under it; ⌥→ opens them all.
        let nav = try #require(s.row("Nav")), support = try #require(s.row("Support"))
        s.model.setExpandedRecursively(nav, true)
        #expect(s.model.expanded.contains(support))
        s.model.setExpandedRecursively(nav, false)
        #expect(!s.model.expanded.contains(nav) && !s.model.expanded.contains(support))
    }

    /// L-110: the Package Dependencies section after the project; its
    /// files open; the file operations leave it alone.
    @Test func packageDependenciesSection() throws {
        let s = try S(localPackage: true)
        defer { s.remove() }
        #expect(s.base.contains("XCLocalSwiftPackageReference"))
        let section = try #require(s.model.packageSection)
        #expect(section.name == "Package Dependencies")
        s.model.setExpanded(section.id, true)
        let kit = try #require(section.children?.first)
        s.model.setExpanded(kit.id, true)
        for id in [kit.id] + kit.descendantIDs { s.model.setExpanded(id, true) }
        let rows = s.model.filteredProjectRows
        let at = try #require(rows.firstIndex { $0.id == section.id })
        #expect(rows[at].level == 0 && at > rows.firstIndex { $0.title.hasPrefix("README") }!)
        let file = try #require(rows.first { $0.title.hasPrefix("Kit") && $0.opens })
        s.model.clickProjectRow(file.id, rows: rows)
        #expect(s.model.document?.path.hasSuffix("Kit/Sources/Kit/Kit.swift") == true)
        #expect(!s.model.isNavigatorCommandEnabled(.delete, rows: [file.id]))
    }

    @Test func filterSettlesEmphasizesAndRemembers() async throws {
        let s = try S()
        defer { s.remove() }
        let nav = ShellNavigator.project.selectorIndex
        s.model.setFilterText("mod", navigator: nav)
        // Not before the pause after the last key.
        #expect(s.model.appliedFilter(nav).isEmpty)
        #expect(s.model.isFilterActive(nav))
        // After it: the pause, then however long a loaded run takes to get
        // to the settle (the parallel suites hold the main actor).
        try await Task.sleep(nanoseconds: UInt64(NavigatorFilterModel.settleDelay * 1_000_000_000))
        let end = Date().addingTimeInterval(10)
        while s.model.appliedFilter(nav) != "mod", Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(s.model.appliedFilter(nav) == "mod")
        let rows = s.model.filteredProjectRows
        let model = try #require(rows.first { $0.title.hasPrefix("Model") })
        #expect(model.filterMatch == .init(before: "", match: "Mod", after: "el"))
        #expect(rows.first { $0.title == "Nav" && $0.level > 0 }?.isFilterContext == true)
        #expect(!rows.contains { $0.title.hasPrefix("README") })
        #expect(!s.model.navigatorFilterLeavesNoRows)
        // Nothing matches: "No Filter Results", the inspector "No Selection".
        s.model.setFilterText("zzz", navigator: nav)
        s.model.applyFilter(nav)
        #expect(s.model.navigatorFilterLeavesNoRows)
        #expect(NavigatorFilterModel.emptyState(navigator: nav, filterText: "zzz", hadRows: true, shownRows: 0) == ["No Filter Results"])
        // Recent filters, newest first, then Clear Recents.
        s.model.chooseRecentFilter("mod", navigator: nav)
        s.model.setFilterText("help", navigator: nav)
        s.model.noteFilterRecent(nav)
        #expect(s.model.filterMenu(nav) == [.recent("help"), .recent("mod"), .separator, .clearRecents(enabled: true)])
        s.model.clearFilterRecents(nav)
        #expect(s.model.filterMenu(nav) == [.clearRecents(enabled: false)])
        // The recent-files toggle keeps only files opened here.
        s.model.setFilterText("", navigator: nav)
        s.select("Helpers.swift")
        s.model.setFilterToggle(0, on: true, navigator: nav)
        let recent = s.model.filteredProjectRows.filter { $0.opens }.map(\.title)
        #expect(recent.count == 1 && recent[0].hasPrefix("Helpers"))
        // Other navigators: the rows above a match stay, dimmed.
        let generic = [OutlineRow(id: "a", level: 0, title: "Target", symbol: "", tint: .accent),
                       OutlineRow(id: "b", level: 1, title: "File.swift", symbol: "", tint: .accent),
                       OutlineRow(id: "c", level: 1, title: "Other.swift", symbol: "", tint: .accent)]
        let kept = OutlineRows.filtered(generic, query: "file")
        #expect(kept.map(\.id) == ["a", "b"])
        #expect(kept[0].isFilterContext && kept[1].filterMatch?.match == "File")
    }
}
