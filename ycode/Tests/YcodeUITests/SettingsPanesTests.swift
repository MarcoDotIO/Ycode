import AppKit
import Foundation
import Testing
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@MainActor
@Suite(.serialized) struct SettingsPanesTests {
    /// A private Preferences (own defaults suite and themes folder),
    /// installed as `shared` for the duration of `body`.
    func withPrefs(_ body: (Preferences, URL) throws -> Void) throws {
        let name = "ycode-settings-\(UUID().uuidString)"
        let t = TestDefaults("settings-panes")
        let d = t.defaults
        let dir = ycodeDir.appendingPathComponent(".build-ide/settings/\(name)")
        let p = Preferences(defaults: d, themesDirectory: dir.appendingPathComponent("Themes"))
        let old = Preferences.shared
        Preferences.shared = p
        defer {
            Preferences.shared = old
            NotificationCenter.default.post(name: Preferences.didChange, object: nil)
            t.remove()
            try? FileManager.default.removeItem(at: dir)
        }
        try body(p, dir)
    }

    @Test func panesInOrder() {
        let t = TestDefaults("order")
        defer { t.remove() }
        let wc = SettingsWindowController(prefs: Preferences(defaults: t.defaults), components: [])
        #expect(wc.tabs.tabViewItems.map(\.label) == ["General", "Appearance", "Accounts", "Coding Assistant", "Behaviors", "Navigation",
                                                       "Notifications", "Editing", "Shortcuts", "Source Control", "Components",
                                                       "Simulators", "Locations"])
        #expect(wc.sidebar.numberOfRows == 13 && wc.selectedPane == "General")
        wc.select(7)
        wc.select(4)
        #expect(wc.selectedPane == "Behaviors")
        wc.goBack()
        #expect(wc.selectedPane == "Editing")
        wc.goForward()
        #expect(wc.selectedPane == "Behaviors")
    }

    @Test func themesBuiltInDuplicateEditImportExport() throws {
        try withPrefs { p, dir in
            #expect(p.themes.map(\.name) == ["Ycode Default", "Ycode Paper", "Ycode Dusk", "Ycode High Contrast"])
            p.themeName = "Ycode Dusk"
            #expect(Theme.backgroundColor == EditorTheme.color("#1E2128"))
            #expect(Theme.color(for: .keyword) == EditorTheme.color("#E58AB8"))
            let pane = ThemesSettingsPane(prefs: p)
            _ = pane.view
            pane.duplicateClicked()
            #expect(p.themeName == "Ycode Dusk Copy")
            pane.edit { $0.tokens["keyword"] = "#123456"; $0.fontSize = 15 }
            #expect(p.theme.tokens["keyword"] == "#123456" && Theme.font.pointSize == 15)
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Themes/Ycode Dusk Copy.ycodetheme").path))
            let out = dir.appendingPathComponent("exported.ycodetheme")
            try p.exportTheme(p.theme, to: out)
            p.deleteTheme(named: "Ycode Dusk Copy")
            #expect(p.themeName == "Ycode Default" && !p.themes.contains { $0.name == "Ycode Dusk Copy" })
            let imported = try p.importTheme(from: out)
            #expect(imported.name == "Ycode Dusk Copy" && p.themeName == "Ycode Dusk Copy")
            // Built-ins cannot be overwritten.
            #expect(throws: (any Error).self) { try p.save(EditorTheme.builtIns[1]) }
            _ = try WindowSnapshotTests().render(pane.view, to: "settings-themes.png")
        }
    }

    @Test func textEditingAppliesLiveToEditors() throws {
        try withPrefs { p, dir in
            let src = dir.appendingPathComponent("Sources/T")
            try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
            try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"T\", targets: [.target(name: \"T\")])\n"
                .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
            let file = src.appendingPathComponent("T.swift")
            try "let a = 1   \nfunc f() {\n}\n".write(to: file, atomically: true, encoding: .utf8)
            _ = NSApplication.shared
            let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: dir)), loadDestinations: false, startLanguageService: false)
            wc.window?.appearance = NSAppearance(named: .aqua)
            wc.applyDefaultLayout()
            wc.open(path: file.path, line: nil)
            let e = wc.editor
            p.showLineNumbers = false
            p.showMinimap = true
            p.showPageGuide = true
            p.pageGuideColumn = 40
            p.wrapLines = false
            p.showFoldingRibbon = false
            #expect(!e.showsLineNumbers && e.showsMinimap && e.pageGuideColumn == 40 && !e.wrapsLines && !e.gutter.showsRibbon)
            p.themeName = "Ycode Paper"
            #expect(e.textView.backgroundColor == EditorTheme.color("#FBF8F1"))
            #expect(wc.debugArea.consoleFont?.pointSize == 11)
            _ = try WindowSnapshotTests().render(wc.window!.contentView!.superview!, to: "settings-applied-editor.png")
            // Indentation: tabs, then spaces.
            p.indentWithTabs = true
            e.textView.setSelectedRange(NSRange(location: (e.text as NSString).range(of: "func").location, length: 0))
            e.textView.insertTab(nil)
            #expect(e.text.contains("\tfunc"))
            p.indentWithTabs = false
            p.indentWidth = 2
            e.textView.insertTab(nil)
            #expect(e.text.contains("\t  func"))
            // Trailing whitespace trimmed on save.
            try e.save()
            #expect(try String(contentsOf: file, encoding: .utf8).hasPrefix("let a = 1\n"))
            // Hidden extensions in the navigator.
            p.fileExtensions = .hide
            func titles(_ items: [OutlineItem]) -> [String] { items.flatMap { [$0.title] + titles($0.children) } }
            #expect(titles(wc.navigator.rows(0)).contains("T") && !titles(wc.navigator.rows(0)).contains("T.swift"))
        }
    }

    @Test func keyBindingsSearchConflictsAndMenus() throws {
        try withPrefs { p, _ in
            let pane = KeyBindingsSettingsPane(prefs: p)
            _ = pane.view
            pane.query = "clean build"
            // Clean Build Folder Immediately is a command too since R36.
            #expect(pane.rows.map(\.title) == ["Clean Build Folder…", "Clean Build Folder Immediately"] && pane.rows[0].command.shortcutText == "⇧⌘K")
            // ⌘B is Build's: refused, with the conflict named.
            #expect(!pane.setShortcut("⌘B", forRow: 0))
            #expect(pane.lastConflicts.map(\.title) == ["Build"])
            // ⌃⌥⌘K stays with Clear Test Results (reference-ui-5.md §1.1).
            #expect(!pane.setShortcut("⌃⌥⌘K", forRow: 0))
            #expect(pane.lastConflicts.map(\.title) == ["Clear Test Results"] && pane.lastConflicts[0].menu == "Product")
            #expect(pane.setShortcut("⌃⌥⇧⌘K", forRow: 0))
            #expect(pane.rows[0].command.shortcutText == "⌃⌥⇧⌘K" && pane.rows[0].customized)
            let menu = MainMenu.make()
            let item = menu.items.compactMap(\.submenu).flatMap(\.items).first { $0.title == "Clean Build Folder…" }
            #expect(item?.keyEquivalent == "k" && item?.keyEquivalentModifierMask == [.command, .option, .control, .shift])
            KeyBindings.reset(pane.rows[0].id, p)
            #expect(KeyBindings.search("clean build", p).first?.command.shortcutText == "⇧⌘K")
            #expect(KeyBindings.entries(p).count > 100)
        }
    }

    @Test func behaviorsNavigationAccountsSourceControlComponents() throws {
        try withPrefs { p, dir in
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"B\")\n"
                .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
            for n in ["A.swift", "B.swift"] { try "let x = 1\n".write(to: dir.appendingPathComponent(n), atomically: true, encoding: .utf8) }
            _ = NSApplication.shared
            let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: dir)), loadDestinations: false, startLanguageService: false)
            wc.applyDefaultLayout()
            // Behaviors: a failed build shows the Issue navigator (default);
            // a custom start behavior shows the Report navigator.
            let pane = BehaviorsSettingsPane(prefs: p)
            _ = pane.view
            pane.select(.buildStarts)
            pane.update { $0.showNavigator = 8; $0.showDebugArea = true }
            wc.applyBehaviors(for: .building("Building B"))
            #expect(wc.lastBehavior?.event == .buildStarts && wc.navigator.selectedIndex == 8)
            wc.applyBehaviors(for: .finished("Build Failed"))
            #expect(wc.lastBehavior?.event == .buildFails && wc.lastBehavior?.behavior.notify == true)
            // Category list, then the Build events with their actions.
            pane.open(category: nil)
            #expect(pane.count(in: "Build") == 4 && pane.count(in: "Running") == 3)
            #expect(p.behavior(.buildErrors).actionTitles == ["Navigator: Issues"])
            #expect(p.behavior(.runEnds).actionTitles == ["Debugger: Hide Debugger If No Output"])
            pane.add("Navigator: Reports", to: .buildWarnings)
            #expect(p.behavior(.buildWarnings).showNavigator == 8)
            pane.remove("Navigator: Reports", from: .buildWarnings)
            #expect(p.behavior(.buildWarnings).actionTitles.isEmpty)
            // Navigation: ⌥-click uses a new unpinned tab (reference-ui-5.md §9.2).
            wc.openFromNavigator(path: dir.appendingPathComponent("A.swift").path, line: nil, modifiers: [])
            wc.openFromNavigator(path: dir.appendingPathComponent("B.swift").path, line: nil, modifiers: .option)
            #expect(wc.editorArea.tabs.count >= 2 && wc.editor.fileURL?.lastPathComponent == "B.swift" && !wc.editorArea.tab.isPinned)
            // Accounts: + explains; nothing is stored.
            let acc = AccountsSettingsPane(prefs: p)
            _ = acc.view
            acc.addClicked()
            #expect(acc.shownMessage?.contains("never asks for or stores passwords") == true)
            // Source control: from git config (read-only), injected here.
            let sc = SourceControlSettingsPane(prefs: p) { $0 == "user.name" ? "Test Author" : nil }
            #expect(sc.authorName == "Test Author" && sc.authorEmail == "Not set")
            // Components: runtimes parsed from synthetic simctl JSON.
            let rt = ComponentsSettingsPane.runtimes(fromSimctlJSON: Data("""
            {"runtimes": [{"name": "iOS 30.0", "version": "30.0", "isAvailable": true}, {"name": "tvOS 30.0", "version": "30.0", "isAvailable": false}]}
            """.utf8))
            #expect(rt.map(\.kind) == ["Simulator Runtime", "Simulator Runtime (unavailable)"])
            // General: live issues off.
            p.showLiveIssues = false
            #expect(!wc.session.includeLiveIssues)
            p.showRegisters = true
            #expect(wc.session.showRegisters)
        }
    }
}
