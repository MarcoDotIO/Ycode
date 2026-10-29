import AppKit
import Foundation
import Testing
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// `specs/ide/reference-ui-6.md` R43: menu clean-up (§8, M1–M6) and the
/// pass-6b editor defaults (§4.5, E9).
@MainActor
@Suite(.serialized) struct MenuR43Tests {
    // MARK: E9 — the minimap is on in the factory state

    @Test func minimapIsOnInTheFactoryState() {
        let t = TestDefaults("r43-minimap")
        defer { t.remove() }
        let p = Preferences(defaults: t.defaults)
        #expect(p.showMinimap)
        // Registered, not stored: nothing is written until the user sets it.
        #expect(t.defaults.persistentDomain(forName: t.suite)?["Ycode.minimap"] == nil)
        p.showMinimap = false
        // A user who turned it off keeps it off.
        #expect(!Preferences(defaults: t.defaults).showMinimap)
        p.showMinimap = true
        #expect(Preferences(defaults: t.defaults).showMinimap)
    }

    // MARK: M1 — one Open Recent

    @Test func fileMenuHasOneOpenRecent() throws {
        try MenuBarGoldenTests().withFactoryBar { bar in
            // AppKit is told not to add its own (it does when the bundle
            // declares document types and this is not 0).
            #expect(YcodeDocumentController().maximumRecentDocumentCount == 0)
            let file = try #require(bar.item(withTitle: "File")?.submenu)
            // One that shows up anyway, as AppKit adds it after Open…
            let foreign = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
            foreign.submenu = NSMenu(title: "Open Recent")
            foreign.submenu?.addItem(NSMenuItem(title: "Clear Menu", action: NSSelectorFromString("clearRecentDocuments:"), keyEquivalent: ""))
            let open = try #require(file.items.firstIndex { $0.title == "Open…" })
            file.insertItem(foreign, at: open + 1)
            #expect(file.items.filter { $0.title == "Open Recent" }.count == 2)
            MenuBarDelegate.shared.update(file, controller: nil)
            let recents = file.items.filter { $0.title == "Open Recent" }
            #expect(recents.count == 1 && recents.first?.submenu is CommandMenu)
            #expect(recents.first?.submenu?.delegate === RecentProjectsMenuDelegate.shared)
        }
    }

    // MARK: M2 — no system feedback item in Help

    @Test func helpMenuHasNoSystemFeedbackItem() throws {
        try MenuBarGoldenTests().withFactoryBar { bar in
            let help = try #require(bar.item(withTitle: "Help")?.submenu)
            // What AppKit puts at the top when the menu is first read.
            help.insertItem(NSMenuItem(title: "Send Ycode Feedback to Apple", action: NSSelectorFromString("_openFeedbackAssistant:"), keyEquivalent: ""), at: 0)
            help.insertItem(.separator(), at: 1)
            MenuBarDelegate.shared.update(help, controller: nil)
            #expect(help.items.first?.title == "Developer Documentation")
            #expect(!help.items.contains { $0.title.contains("Feedback to Apple") })
            // The table's own Provide Feedback… stays.
            #expect(help.items.contains { $0.title == "Provide Feedback…" })
            // Also when it arrives just before the menu is shown.
            help.insertItem(NSMenuItem(title: "Send Ycode Feedback to Apple", action: NSSelectorFromString("_openFeedbackAssistant:"), keyEquivalent: ""), at: 0)
            help.insertItem(.separator(), at: 1)
            MenuBarDelegate.shared.menuWillOpen(help)
            #expect(help.items.first?.title == "Developer Documentation")
        }
    }

    // MARK: Helpers

    let r32 = WindowChromeR32Tests()

    func outline(_ wc: WorkspaceWindowController) throws -> NSOutlineView {
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        return try #require(all(wc.navigator.view).compactMap { $0 as? NSOutlineView }.first)
    }

    /// Selects the project navigator row for `path`; returns the row's path.
    @discardableResult
    func select(_ path: String, in wc: WorkspaceWindowController) throws -> String {
        wc.navigator.select(0)
        let o = try outline(wc)
        o.expandItem(nil, expandChildren: true)
        func real(_ p: String) -> String { URL(fileURLWithPath: p).resolvingSymlinksInPath().path }
        func rowPath(_ r: Int) -> String? { (o.item(atRow: r) as? OutlineItem).flatMap { $0.nodePath ?? $0.path } }
        let row = try #require((0..<o.numberOfRows).first { rowPath($0).map(real) == real(path) })
        o.selectRowIndexes([row], byExtendingSelection: false)
        return try #require(rowPath(row))
    }

    /// A menu-bar item for an action, validated in the window (title in context).
    func validated(_ wc: WorkspaceWindowController, _ action: String) throws -> (enabled: Bool, title: String) {
        let spec = try #require(CommandTable.command(action: action))
        let i = CommandMenuItem(title: spec.title, action: NSSelectorFromString(action), keyEquivalent: "")
        i.spec = spec
        let ok = wc.validateMenuItem(i)
        return (ok, i.title)
    }

    /// File ▸ New as the menu bar shows it for `wc`.
    func newMenu(_ wc: WorkspaceWindowController) throws -> NSMenu {
        let bar = MainMenu.make()
        let new = try #require(bar.item(withTitle: "File")?.submenu?.item(withTitle: "New")?.submenu)
        MenuBarDelegate.shared.update(new, controller: wc)
        return new
    }

    func visible(_ m: NSMenu) -> [String] { m.items.filter { !$0.isHidden && !$0.isSeparatorItem }.map(\.title) }

    // MARK: M3 / M6 — File ▸ New ▸ (New) File from Clipboard

    @Test func fileFromClipboardFollowsThePasteboard() throws {
        let dir = try r32.package("r43-clipboard")
        defer { try? FileManager.default.removeItem(at: dir) }
        let board = NSPasteboard(name: NSPasteboard.Name("org.ycode.tests.r43.\(UUID().uuidString)"))
        let old = WorkspaceWindowController.menuPasteboard
        WorkspaceWindowController.menuPasteboard = board
        defer { WorkspaceWindowController.menuPasteboard = old; board.releaseGlobally() }
        let wc = try r32.window(dir)
        wc.open(path: dir.appendingPathComponent("Sources/Chrome/Model.swift").path, line: nil)
        board.clearContents()
        var v = try validated(wc, "newFileFromClipboard:")
        #expect(!v.enabled && v.title == "File from Clipboard")
        board.setString("let pasted = 42\n", forType: .string)
        v = try validated(wc, "newFileFromClipboard:")
        #expect(v.enabled && v.title == "New File from Clipboard")
        let url = try #require(wc.newFileFromClipboard(nil))
        #expect(url.lastPathComponent == "File" && url.deletingLastPathComponent().lastPathComponent == "Chrome")
        #expect(try String(contentsOf: url, encoding: .utf8) == "let pasted = 42\n")
        #expect(wc.editor.fileURL?.standardizedFileURL == url.standardizedFileURL && wc.editor.text == "let pasted = 42\n")
        // With no workspace window the generic (disabled) title shows.
        #expect(MenuTitles.title(generic: "File from Clipboard", in: nil) == "File from Clipboard")
    }

    // MARK: M6 — Group items, Folder, Find in Selected File… / Groups…

    @Test func newMenuAndFindFollowTheNavigatorSelection() throws {
        let dir = try r32.package("r43-selection")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wc = try r32.window(dir)
        let groups = ["Group", "Group without Folder", "Group from Selection", "Group from Selection without Folder"]
        // No selection: all six listed; Folder and Find disabled.
        #expect(wc.projectNavigatorSelection == nil)
        #expect(Set(groups + ["Folder", "Folder from Selection"]).isSubset(of: visible(try newMenu(wc))))
        #expect(try validated(wc, "newFolder:").enabled == false)
        var find = try validated(wc, "findInSelectedGroups:")
        #expect(!find.enabled && find.title == "Find in Selected Groups…")
        // A file in a folder: the Group items are hidden; Folder enabled.
        let model = try select(dir.appendingPathComponent("Sources/Chrome/Model.swift").path, in: wc)
        #expect(wc.projectNavigatorSelection?.kind == .file && wc.projectSelectionIsInFolder)
        let shown = visible(try newMenu(wc))
        #expect(groups.allSatisfy { !shown.contains($0) } && shown.suffix(2) == ["Folder", "Folder from Selection"])
        #expect(try validated(wc, "newFolder:").enabled)
        find = try validated(wc, "findInSelectedGroups:")
        #expect(find.enabled && find.title == "Find in Selected File…")
        // Find in Selected File…: the Find navigator, scoped to that file.
        wc.findInSelectedGroups(nil)
        #expect(wc.navigator.selectedIndex == 3 && wc.navigator.findScopeValue == .group(model))
        wc.navigator.find("public")
        #expect(wc.navigator.shownRows.count == 1 && wc.navigator.shownRows.first?.title.hasPrefix("Model.swift") == true)
        // A folder: "Find in Selected Groups…", scoped to the folder.
        let folder = try select(dir.appendingPathComponent("Sources/Chrome").path, in: wc)
        find = try validated(wc, "findInSelectedGroups:")
        #expect(find.enabled && find.title == "Find in Selected Groups…")
        wc.findInSelectedGroups(nil)
        wc.navigator.find("public")
        #expect(wc.navigator.findScopeValue == .group(folder) && wc.navigator.shownRows.count == 2)
    }

    @Test func groupItemsStayForAFileInAGroup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-r43-groups-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let proj = dir.appendingPathComponent("Hello.xcodeproj")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: ycodeDir.appendingPathComponent("Tests/YcodeProjectTests/Fixtures/Hello.xcodeproj/project.pbxproj"),
                                         to: proj.appendingPathComponent("project.pbxproj"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Hello"), withIntermediateDirectories: true)
        let main = dir.appendingPathComponent("Hello/main.swift")
        try "print(1)\n".write(to: main, atomically: true, encoding: .utf8)
        let wc = try r32.window(proj)
        let path = try #require(wc.session.model.root.allFiles.compactMap(\.path).first { $0.hasSuffix("/main.swift") })
        try select(path, in: wc)
        #expect(wc.projectNavigatorSelection?.kind == .file && !wc.projectSelectionIsInFolder)
        let shown = visible(try newMenu(wc))
        #expect(["Group", "Group without Folder", "Group from Selection", "Group from Selection without Folder", "Folder"].allSatisfy(shown.contains))
    }

    // MARK: M4 — Edit ▸ Copy ▸ and Paste ▸

    @Test func copyAndPasteAreSubmenus() throws {
        try MenuBarGoldenTests().withFactoryBar { bar in
            let edit = try #require(bar.item(withTitle: "Edit")?.submenu)
            let top = edit.items.prefix(9).map { $0.isSeparatorItem ? "—" : $0.title }
            #expect(top == ["Undo", "Redo", "—", "Cut", "Copy", "Paste", "Duplicate", "Delete", "—"])
            let copy = try #require(edit.item(withTitle: "Copy"))
            let paste = try #require(edit.item(withTitle: "Paste"))
            // No shortcut on the parents; the commands are plain items.
            #expect(copy.keyEquivalent.isEmpty && paste.keyEquivalent.isEmpty)
            #expect(copy.submenu?.items.map(\.title) == ["Copy", "Copy File and Line", "Copy Symbol Name", "Copy Qualified Symbol Name"])
            #expect(copy.submenu?.items.allSatisfy { !$0.isAlternate } == true)
            #expect(copy.submenu?.items.map { MainMenu.canonicalShortcut($0) } == ["⌘C", "⌃⌥⌘C", "⌃⇧⌘C", "⌃⌥⇧⌘C"])
            #expect(paste.submenu?.items.map(\.title) == ["Paste", "Move Item Here", "Paste and Preserve Formatting"])
            // Move Item Here is hidden while there is nothing to move.
            #expect(paste.submenu?.item(withTitle: "Move Item Here")?.isHidden == true)
            var ctx = MenuContext()
            #expect(!MenuConditions.isShown(.itemToMove, in: ctx))
            ctx.hasItemToMove = true
            #expect(MenuConditions.isShown(.itemToMove, in: ctx))
        }
    }

    @Test func copyVariantsAndPasteAreEnabledOnTheirOwn() throws {
        let dir = try r32.package("r43-copy")
        defer { try? FileManager.default.removeItem(at: dir) }
        let board = NSPasteboard(name: NSPasteboard.Name("org.ycode.tests.r43.\(UUID().uuidString)"))
        let old = WorkspaceWindowController.menuPasteboard
        WorkspaceWindowController.menuPasteboard = board
        defer { WorkspaceWindowController.menuPasteboard = old; board.releaseGlobally() }
        let wc = try r32.window(dir)
        wc.open(path: dir.appendingPathComponent("Sources/Chrome/Model.swift").path, line: nil)
        let tv = wc.editor.textView
        tv.setSelectedRange(NSRange(location: 14, length: 0))   // in "Model", no selection
        // Copy is the text view's: disabled with no selection; the variants are enabled.
        #expect(!tv.validateMenuItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")))
        #expect(try validated(wc, "copyFileAndLine:").enabled)
        #expect(try validated(wc, "copySymbolName:").enabled && (try validated(wc, "copyQualifiedSymbolName:").enabled))
        // Paste and Preserve Formatting inserts the text exactly as it is.
        board.clearContents()
        #expect(try validated(wc, "pasteAndPreserveFormatting:").enabled == false)
        board.setString("    let x = 1\n", forType: .string)
        #expect(try validated(wc, "pasteAndPreserveFormatting:").enabled)
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        wc.pasteAndPreserveFormatting(nil)
        #expect(wc.editor.text.hasPrefix("    let x = 1\npublic struct Model"))
    }
}
