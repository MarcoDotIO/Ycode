import AppKit
import Foundation
import Testing
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// reference-ui-5.md §1–§2 behavior: titles in context (§1.3), conditional
/// items and separators (§1.5), the system's items (§1.6), menus filled
/// from state, the jump-bar keyboard menus (§2.4, §6.1.3), Quick Actions
/// (§2.4 item 5) and the commands added with the menu bar.
@MainActor
@Suite(.serialized) struct MenuBarBehaviorTests {
    func withWindow(_ body: @MainActor (WorkspaceWindowController, URL) throws -> Void) throws {
        let t = TestDefaults("menu-behavior")
        let dir = ycodeDir.appendingPathComponent(".build-ide/menu-behavior/\(UUID().uuidString)")
        let p = Preferences(defaults: t.defaults, themesDirectory: dir.appendingPathComponent("Themes"))
        let old = Preferences.shared
        Preferences.shared = p
        defer {
            Preferences.shared = old
            t.remove()
            try? FileManager.default.removeItem(at: dir)
        }
        let src = dir.appendingPathComponent("Pkg/Sources/Demo")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"Demo\", targets: [.executableTarget(name: \"Demo\")])\n"
            .write(to: dir.appendingPathComponent("Pkg/Package.swift"), atomically: true, encoding: .utf8)
        try "struct Greeter {\n    func greet() {\n        print(<#name#>)\n    }\n}\nlet greeting = Greeter()\n"
            .write(to: src.appendingPathComponent("Demo.swift"), atomically: true, encoding: .utf8)
        try "let other = 2\n".write(to: src.appendingPathComponent("DemoTests.swift"), atomically: true, encoding: .utf8)
        try "let more = 3\n".write(to: src.appendingPathComponent("More.swift"), atomically: true, encoding: .utf8)
        _ = NSApplication.shared
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: dir.appendingPathComponent("Pkg"))),
                                           loadDestinations: false, startLanguageService: false, openFirstFile: false)
        wc.applyDefaultLayout()
        try body(wc, src)
    }

    func visible(_ m: NSMenu) -> [String] {
        m.items.filter { !$0.isHidden && !$0.isAlternate }.map { $0.isSeparatorItem ? "—" : $0.title }
    }

    @Test func titlesInContext() {
        // No workspace: the generic titles.
        #expect(MenuTitles.title(generic: "Close Document", in: nil) == "Close Document")
        var c = MenuContext()
        c.containerKind = .package
        c.workspaceName = "Obs"
        c.fileName = "Model.swift"
        c.caretLine = 12
        #expect(MenuTitles.title(generic: "Close Tab, Editor Pane, Window Tab, or Window", in: c) == "Close Window")
        c.editorTabCount = 2
        #expect(MenuTitles.title(generic: "Close Tab, Editor Pane, Window Tab, or Window", in: c) == "Close Tab")
        #expect(MenuTitles.title(generic: "Close Document", in: c) == "Close \u{201C}Model.swift\u{201D}")
        #expect(MenuTitles.title(generic: "Close Workspace", in: c) == "Close Package")
        #expect(MenuTitles.title(generic: "Workspace Settings…", in: c) == "Package Settings…")
        #expect(MenuTitles.title(generic: "Add Files…", in: c) == "Add Files to \u{201C}Obs\u{201D}…")
        #expect(MenuTitles.title(generic: "Find in Workspace", in: c) == "Find in Package")
        #expect(MenuTitles.title(generic: "Find and Replace in Workspace…", in: c) == "Find and Replace in Package…")
        #expect(MenuTitles.title(generic: "Find in Selected Groups…", in: c) == "Find in Selected Groups…")
        #expect(MenuTitles.title(generic: "Jump to Line…", in: c) == "Jump to Line in \u{201C}Model.swift\u{201D}…")
        #expect(MenuTitles.title(generic: "Compile File", in: c) == "Compile \u{201C}Model.swift\u{201D}")
        #expect(MenuTitles.title(generic: "Bookmark Line", in: c) == "Bookmark \u{201C}Model.swift\u{201D} Line 12")
        #expect(MenuTitles.title(generic: "Bookmark File With Dialog", in: c) == "Bookmark \u{201C}Model.swift\u{201D}…")
        #expect(MenuTitles.title(generic: "Stage Selected Files", in: c) == "Stage Changes in \u{201C}Model.swift\u{201D}")
        #expect(MenuTitles.title(generic: "Discard Changes in Selected Files…", in: c) == "Discard Changes in \u{201C}Model.swift\u{201D}…")
        #expect(MenuTitles.title(generic: "Mark as Resolved", in: c) == "Mark Selected Files as Resolved")
        c.hasNavigatorFileSelection = true
        #expect(MenuTitles.title(generic: "Stage Selected Files", in: c) == "Stage Changes in Selected Files")
        c.selectedFileIsUntracked = true
        #expect(MenuTitles.title(generic: "Discard Changes in Selected Files…", in: c) == "Move Selected Files to Trash…")
        c.containerKind = .project
        #expect(MenuTitles.title(generic: "Find Next in Workspace", in: c) == "Find Next in Project")
        #expect(MenuTitles.title(generic: "Close Workspace", in: c) == "Close Project")
        c.windowTabCount = 2
        #expect(MenuTitles.title(generic: "Close Window", in: c) == "Close Window Tab")
        c.isPaused = true
        c.breakpointsActive = false
        #expect(MenuTitles.title(generic: "Pause", in: c) == "Continue")
        #expect(MenuTitles.title(generic: "Deactivate Breakpoints", in: c) == "Activate Breakpoints")
    }

    @Test func separatorsCollapseAroundHiddenItems() {
        // item, —, (hidden), —, item, —, (hidden) → one separator, none trailing.
        let shown = MenuConditions.visibleSeparators(isSeparator: [false, true, false, true, false, true, false],
                                                     isVisible: [true, false, false, false, true, false, false])
        #expect(shown == [false, true, false, false, false, false, false])
        #expect(MenuConditions.visibleSeparators(isSeparator: [true, false, true], isVisible: [false, true, false]) == [false, false, false])
    }

    /// §1.5 and §2.6: the source-editor items of Navigate show only with a
    /// source editor focused, and their separators collapse.
    @Test func conditionalNavigateItems() throws {
        try withWindow { wc, src in
            let bar = MainMenu.make()
            let nav = try #require(bar.item(withTitle: "Navigate")?.submenu)
            MenuBarDelegate.shared.update(nav, controller: nil)
            #expect(visible(nav).suffix(2) == ["—", "Jump to Program Counter"])
            MenuBarDelegate.shared.update(nav, controller: wc)
            #expect(visible(nav).last == "Jump to Program Counter")
            wc.open(path: src.appendingPathComponent("Demo.swift").path, line: nil)
            MenuBarDelegate.shared.update(nav, controller: wc)
            let v = visible(nav)
            #expect(Array(v.suffix(10)) == ["—", "Jump to Next Counterpart", "Jump to Previous Counterpart",
                                            "Jump to Line in \u{201C}Demo.swift\u{201D}…", "—", "Jump to Next Placeholder", "Jump to Previous Placeholder",
                                            "—", "Jump to Next Change", "Jump to Previous Change"])
            #expect(v.contains("Jump to Line in \u{201C}Demo.swift\u{201D}…") && v.last == "Jump to Previous Change")
            // The file's titles reach the other menus too.
            let product = try #require(bar.item(withTitle: "Product")?.submenu?.item(withTitle: "Perform Action")?.submenu)
            MenuBarDelegate.shared.update(product, controller: wc)
            #expect(product.items.contains { $0.title == "Compile \u{201C}Demo.swift\u{201D}" })
            let find = try #require(bar.item(withTitle: "Find")?.submenu)
            MenuBarDelegate.shared.update(find, controller: wc)
            #expect(find.items.first?.title == "Find in Package")
            // Back to no workspace: generic titles again.
            MenuBarDelegate.shared.update(find, controller: nil)
            #expect(find.items.first?.title == "Find in Workspace")
            // ⇧⌘W is hidden while ⌘W reads Close Window (one tab), with its alternate.
            let file = try #require(bar.item(withTitle: "File")?.submenu)
            MenuBarDelegate.shared.update(file, controller: wc)
            let closeWindow = try #require(file.items.first { $0.action == #selector(NSWindow.performClose(_:)) })
            #expect(closeWindow.isHidden && file.item(withTitle: "Close Other Window Tabs")?.isHidden == true)
            #expect(file.items.first { $0.keyEquivalent == "w" && $0.keyEquivalentModifierMask == .command }?.title == "Close Window")
            wc.newTab(nil)
            MenuBarDelegate.shared.update(file, controller: wc)
            #expect(!closeWindow.isHidden)
            #expect(file.items.first { $0.keyEquivalent == "w" && $0.keyEquivalentModifierMask == .command }?.title == "Close Tab")
        }
    }

    /// §1.6: the system's items that collide with the table go; others stay.
    @Test func systemItemsGiveWay() throws {
        _ = NSApplication.shared
        let bar = MainMenu.make()
        let file = try #require(bar.item(withTitle: "File")?.submenu)
        let closeAll = NSMenuItem(title: "Close All", action: NSSelectorFromString("closeAll:"), keyEquivalent: "w")
        closeAll.keyEquivalentModifierMask = [.command, .option, .shift]
        file.addItem(closeAll)
        let view = try #require(bar.item(withTitle: "View")?.submenu)
        let full = NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        full.keyEquivalentModifierMask = [.function]
        view.addItem(full)
        let edit = try #require(bar.item(withTitle: "Edit")?.submenu)
        edit.addItem(NSMenuItem(title: "Start Dictation…", action: NSSelectorFromString("startDictation:"), keyEquivalent: ""))
        for m in [file, view, edit] { MainMenu.removeSystemConflicts(in: m) }
        #expect(file.item(withTitle: "Close All") == nil)
        #expect(view.items.filter { $0.action == #selector(NSWindow.toggleFullScreen(_:)) }.isEmpty)
        #expect(view.items.filter { $0.title == "Enter Full Screen" }.map { MainMenu.canonicalShortcut($0) } == ["⌃⌘F"])
        #expect(edit.item(withTitle: "Start Dictation…") != nil)
    }

    @Test func menusFilledFromState() throws {
        // Ycode ▸ Open Developer Tool: the tools found, in the reference order.
        let dev = URL(fileURLWithPath: "/Dev")
        let found = DeveloperTools.tools(inDeveloperDirectory: dev) { ["/Dev/Applications/FileMerge.app", "/Dev/Applications/Instruments.app"].contains($0) }
        #expect(found.map(\.name) == ["Instruments", "FileMerge"])
        _ = NSApplication.shared
        let bar = MainMenu.make()
        let tools = try #require(bar.item(withTitle: "Ycode")?.submenu?.item(withTitle: "Open Developer Tool")?.submenu)
        DynamicMenus.fillDeveloperTools(tools, tools: found)
        DynamicMenus.fillDeveloperTools(tools, tools: found)
        #expect(visible(tools) == ["Instruments", "FileMerge", "—", "More Developer Tools…"])
        #expect(tools.items.first?.target === AppCommands.shared)
        // View ▸ Inspectors follows the focused editor's tabs.
        let insp = try #require(bar.item(withTitle: "View")?.submenu?.item(withTitle: "Inspectors")?.submenu)
        DynamicMenus.fillInspectors(insp, names: ["File", "History", "Quick Help", "Identity", "Attributes"])
        #expect(visible(insp) == ["File", "History", "Quick Help", "Identity", "Attributes", "—", "Show Inspector"])
        #expect(insp.items[4].keyEquivalent == "5" && insp.items[4].keyEquivalentModifierMask == [.command, .option] && insp.items[4].tag == 4)
        // Product ▸ Scheme: one row per scheme, the active one checked.
        let scheme = try #require(bar.item(withTitle: "Product")?.submenu?.item(withTitle: "Scheme")?.submenu)
        DynamicMenus.fillSchemes(scheme, names: ["App", "AppTests"], active: "AppTests", target: nil)
        #expect(visible(scheme).suffix(3) == ["—", "App", "AppTests"])
        #expect(scheme.items.last?.state == .on && scheme.items[scheme.items.count - 2].state == .off)
    }

    /// §1.1: a disabled command keeps its shortcut; Key Bindings reports it
    /// as a conflict.
    @Test func disabledCommandsHoldTheirShortcuts() {
        let t = TestDefaults("menu-keys")
        defer { t.remove() }
        let p = Preferences(defaults: t.defaults, themesDirectory: ycodeDir.appendingPathComponent(".build-ide/menu-keys/Themes"))
        let build = KeyBindings.entries(p).first { $0.title == "Build" }!
        let c = KeyBindings.set(build.id, key: "b", modifiers: [.command, .control], p)
        #expect(c.map(\.title) == ["Compile File"])
        // Any spelling of a keystroke: "{" with ⌘ is ⇧⌘[.
        let c2 = KeyBindings.conflicts(key: "[", modifiers: [.command, .shift], excluding: build.id, p)
        #expect(c2.map(\.title) == ["Show Previous Tab"])
        #expect(p.keyBindingOverrides.isEmpty)
    }

    @Test func jumpBarMenus() throws {
        try withWindow { wc, src in
            let demo = src.appendingPathComponent("Demo.swift").path, tests = src.appendingPathComponent("DemoTests.swift").path
            let more = src.appendingPathComponent("More.swift").path
            #expect(wc.jumpBarEntries(.previousHistory).isEmpty)
            wc.open(path: more, line: nil)
            wc.open(path: demo, line: nil)
            // ⌃1: recent files, then counterparts.
            let related = wc.jumpBarEntries(.relatedItems)
            #expect(related.map(\.title) == ["Recent Files", "More.swift", "Counterparts", "DemoTests.swift"])
            #expect(related[0].isLabel && related[3].path == tests)
            // ⌃2 / ⌃3: history.
            #expect(wc.jumpBarEntries(.previousHistory).map(\.path) == [more])
            wc.goBack(nil)
            #expect(wc.jumpBarEntries(.nextHistory).map(\.path) == [demo] && wc.jumpBarEntries(.nextFilesHistory).map(\.path) == [demo])
            wc.goForward(nil)
            // ⌃5: the group's files; ⌃4: the top level.
            #expect(Set(wc.jumpBarEntries(.groupFiles).map(\.title)) == ["Demo.swift", "DemoTests.swift", "More.swift"])
            #expect(!wc.jumpBarEntries(.topLevelItems).isEmpty)
            // ⌃6: the document's symbols, members indented.
            let items = wc.jumpBarEntries(.documentItems)
            #expect(items.map(\.title).prefix(2) == ["Greeter", "  greet"] && items.first?.line == 1)
            let menu = wc.popUpJumpBarMenu(.documentItems)
            #expect(menu.items.first?.title == "Greeter")
            wc.jumpBarEntryChosen(menu.items[1])
            #expect(wc.editor.currentLine == 2)
            // The menu commands are enabled while their menu has entries.
            let i = NSMenuItem(title: "", action: #selector(WorkspaceWindowController.showDocumentItemsMenu(_:)), keyEquivalent: "")
            #expect(wc.validateMenuItem(i))
        }
    }

    @Test func navigateAndFileCommands() throws {
        try withWindow { wc, src in
            let demo = src.appendingPathComponent("Demo.swift").path
            wc.open(path: demo, line: nil)
            // Counterparts: Demo.swift ↔ DemoTests.swift.
            wc.jumpToNextCounterpart(nil)
            #expect(wc.editor.fileURL?.lastPathComponent == "DemoTests.swift")
            wc.jumpToPreviousCounterpart(nil)
            #expect(wc.editor.fileURL?.lastPathComponent == "Demo.swift")
            // Placeholders: ⌃/ selects the next one.
            wc.editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
            wc.jumpToNextPlaceholder(nil)
            let sel = wc.editor.textView.selectedRange()
            #expect((wc.editor.textView.string as NSString).substring(with: sel) == "<#name#>")
            // §2.0: Show Code Actions moves to the source editor's context menu.
            let ctx = wc.editor.textView(wc.editor.textView, menu: NSMenu(), for: NSEvent(), at: 0)
            #expect(ctx?.items.first?.title == "Show Code Actions" && ctx?.items.first?.action == NSSelectorFromString("showCodeActions:"))
            // Edit ▸ Delete (⌘⌫): the selection, else to the start of the line.
            let tv = wc.editor.textView
            tv.setSelectedRange(NSRange(location: 6, length: 0))
            let del = NSMenuItem(title: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
            #expect(tv.validateMenuItem(del))
            tv.delete(nil)
            #expect(tv.string.hasPrefix(" Greeter {"))
            tv.undoManager?.undo()
            // Close Other Tabs keeps the selected tab.
            wc.newTab(nil)
            wc.open(path: src.appendingPathComponent("More.swift").path, line: nil)
            #expect(wc.editorArea.tabs.count == 2)
            let other = NSMenuItem(title: "", action: #selector(WorkspaceWindowController.closeOtherTabs(_:)), keyEquivalent: "")
            #expect(wc.validateMenuItem(other))
            wc.closeOtherTabs(nil)
            #expect(wc.editorArea.tabs.count == 1 && wc.editor.fileURL?.lastPathComponent == "More.swift")
            #expect(!wc.validateMenuItem(other))
            // The menu-bar titles come from the context.
            let item = CommandMenuItem(title: "", action: #selector(WorkspaceWindowController.closeWorkspace(_:)), keyEquivalent: "")
            item.spec = CommandTable.command(action: "closeWorkspace:")
            _ = wc.validateMenuItem(item)
            #expect(item.title == "Close Package")
            // Find ▸ Select All Find Matches selects every match.
            wc.editor.setFind("let")
            wc.editor.performFind(tag: 9)
            #expect(wc.editor.textView.selectedRanges.count == 1)
            wc.open(path: demo, line: nil)
            wc.editor.setFind("e")
            wc.editor.performFind(tag: 9)
            #expect(wc.editor.textView.selectedRanges.count > 3)
            // Product ▸ Scheme rows select the scheme.
            if let first = wc.session.model.schemeNames.first {
                wc.selectSchemeRow(0)
                #expect(wc.session.scheme == first)
            }
        }
    }

    @Test func quickActions() throws {
        try withWindow { wc, src in
            wc.open(path: src.appendingPathComponent("Demo.swift").path, line: nil)
            let bar = MainMenu.make()
            let all = QuickActions.collect(from: bar, controller: wc)
            #expect(all.contains { $0.title == "Build" && $0.path == "Product" && $0.shortcut == "⌘B" })
            // Disabled and hidden commands are not listed, nor the palette itself.
            #expect(!all.contains { $0.title == "Ycode Extensions…" || $0.title == "Show Quick Actions…" })
            #expect(!all.contains { $0.title == "Load Symbols…" })
            let f = QuickActions.filter(all, "clean build")
            #expect(f.first?.title == "Clean Build Folder…")
            #expect(QuickActions.filter(all, "").count == all.count)
            let c = try #require(wc.showQuickActions(nil))
            c.setQuery("jump to line")
            #expect(c.shown.first?.title == "Jump to Line in \u{201C}Demo.swift\u{201D}…")
        }
    }

    /// File ▸ Open… works unbundled (no Info.plist document types).
    @Test func openIsEnabledUnbundled() {
        _ = NSApplication.shared
        let dc = NSDocumentController.shared as? YcodeDocumentController ?? YcodeDocumentController()
        let item = NSMenuItem(title: "Open…", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
        #expect(dc.validateUserInterfaceItem(item))
    }

    @Test func appCommandLinks() {
        var opened: [URL] = []
        let old = AppCommands.open
        AppCommands.open = { opened.append($0) }
        defer { AppCommands.open = old }
        AppCommands.shared.showDeveloperDocumentation(nil)
        AppCommands.shared.showHumanInterfaceGuidelines(nil)
        AppCommands.shared.showSwiftBook(nil)
        #expect(opened.map(\.host) == ["developer.apple.com", "developer.apple.com", "docs.swift.org"])
        #expect(AppCommands.Links.documentationSearch("NSMenu item")?.absoluteString == "https://developer.apple.com/search/?q=NSMenu%20item")
        #expect(AppCommands.handles("showDownloads:") && !AppCommands.handles("buildProduct:"))
    }
}
