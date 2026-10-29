import AppKit
import Foundation
import Testing
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// specs/ide/reference-ui.md: navigators, toolbar, menus, settings
/// defaults, behaviors, debug area, File inspector, jump bar.
@MainActor
@Suite(.serialized) struct ReferenceUITests {
    func withWindow(_ body: (WorkspaceWindowController, URL, Preferences) throws -> Void) throws {
        let t = TestDefaults("reference-ui")
        let dir = ycodeDir.appendingPathComponent(".build-ide/reference-ui/\(UUID().uuidString)")
        let p = Preferences(defaults: t.defaults, themesDirectory: dir.appendingPathComponent("Themes"))
        let old = Preferences.shared
        Preferences.shared = p
        defer {
            Preferences.shared = old
            NotificationCenter.default.post(name: Preferences.didChange, object: nil)
            t.remove()
            try? FileManager.default.removeItem(at: dir)
        }
        let src = dir.appendingPathComponent("Pkg/Sources/Demo")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"Demo\", targets: [.executableTarget(name: \"Demo\")])\n"
            .write(to: dir.appendingPathComponent("Pkg/Package.swift"), atomically: true, encoding: .utf8)
        try "struct Greeter {\n    func greet() {\n        let name = 1\n        print(name)\n    }\n}\nlet g = Greeter()\n"
            .write(to: src.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        try "let other = 2\n".write(to: src.appendingPathComponent("Other.swift"), atomically: true, encoding: .utf8)
        _ = NSApplication.shared
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: dir.appendingPathComponent("Pkg"))),
                                           loadDestinations: false, startLanguageService: false, openFirstFile: false)
        wc.applyDefaultLayout()
        try body(wc, src, p)
    }

    @Test func defaultsFollowReference() {
        let t = TestDefaults("reference-defaults")
        defer { t.remove() }
        let p = Preferences(defaults: t.defaults)
        #expect(!p.showFoldingRibbon && p.wrapLines && p.wrappedLineIndent == 4 && p.trimTrailingWhitespace)
        #expect(p.highlightSelectedSymbol && p.highlightDelay == 0.25)
        #expect(CommandTable.navigators == ["Project", "Source Control", "Bookmarks", "Find", "Issues", "Tests", "Debug", "Breakpoints", "Reports"])
        #expect(p.behavior(.buildErrors).showNavigator == 4)
        #expect(p.behavior(.buildSucceeds).notify && p.behavior(.buildFails).notify)
        #expect(p.behavior(.runPauses).showNavigator == 6 && p.behavior(.runPauses).showDebugArea == true)
        #expect(p.behavior(.runOutput).showDebugArea == true && p.behavior(.runEnds).hideDebugAreaIfNoOutput)
    }

    @Test func bookmarksFilterAndAddMenu() throws {
        try withWindow { wc, src, _ in
            let main = src.appendingPathComponent("main.swift").path
            wc.open(path: main, line: 3)
            let b = wc.addLineBookmark()
            #expect(b?.line == 3 && b?.label == "let name = 1")
            wc.open(path: main, line: 6)
            wc.addLineBookmark()
            wc.addFileBookmark()
            wc.navigator.select(2)
            #expect(wc.navigator.rows(2).first?.title == "main.swift" && wc.navigator.rows(2).first?.children.count == 3)
            // Saved per user next to the package.
            #expect(FileManager.default.fileExists(atPath: wc.bookmarks.fileURL!.path))
            #expect(wc.bookmarks.fileURL!.path.contains(".swiftpm/xcode/xcuserdata/"))
            wc.open(path: main, line: 1)
            wc.jumpToNextBookmark(nil)
            #expect(wc.editor.currentLine == 3)
            wc.jumpToNextBookmark(nil)
            #expect(wc.editor.currentLine == 6)
            wc.jumpToNextBookmark(nil)
            #expect(wc.editor.currentLine == 3)
            wc.jumpToPreviousBookmark(nil)
            #expect(wc.editor.currentLine == 6)
            #expect(wc.navigator.addMenuTitles == ["Bookmark File", "Bookmark Line"])
            // Project navigator: "+" and the filters.
            wc.navigator.select(0)
            #expect(wc.navigator.addMenuTitles.first == "New File…")
            wc.navigator.filterText = "oth"
            let names = wc.navigator.rows(0).flatMap { $0.children.flatMap { $0.children.flatMap { $0.children.map(\.title) } } }
            #expect(names.contains("Other") && !names.contains("main"))  // extensions hidden by default
            wc.navigator.filterText = ""
            wc.navigator.filterRecent = true
            let recent = wc.navigator.rows(0).flatMap { $0.children.flatMap { $0.children.flatMap { $0.children.map(\.title) } } }
            #expect(recent == ["main"])
            wc.navigator.filterRecent = false
            _ = try WindowSnapshotTests().render(wc.window!.contentView!.superview!, to: "reference-bookmarks.png")
        }
    }

    @Test func toolbarMenusAndCodingAssistant() throws {
        try withWindow { wc, _, _ in
            let ids = wc.toolbarDefaultItemIdentifiers(NSToolbar()).map(\.rawValue)
            #expect(ids.first == "leftPanes" && ids.last == "inspectorToggle")
            #expect(ids.firstIndex(of: "activity")! < ids.firstIndex(of: "scheme")! && ids.firstIndex(of: "scheme")! < ids.firstIndex(of: "editorModes")!)
            #expect(wc.leftPanesControl.segmentCount == 2 && wc.editorModesControl.segmentCount == 3)
            wc.setLeftPane(codingAssistant: true)
            #expect(wc.navigator.showsCodingAssistant && !wc.navigator.assistantContainer.isHidden)
            #expect(wc.leftPanesControl.isSelected(forSegment: 1) && !wc.leftPanesControl.isSelected(forSegment: 0))
            wc.setLeftPane(codingAssistant: false)
            #expect(!wc.navigator.showsCodingAssistant && wc.leftPanesControl.isSelected(forSegment: 0))
            // Menus: Integrate, bookmarks, unavailable items disabled.
            #expect(CommandTable.command(titled: "Bookmark Line") != nil && CommandTable.command(titled: "Jump to Next Bookmark") != nil)
            let unavailable = CommandTable.command(titled: "Ycode Extensions…")
            #expect(unavailable?.action.hasPrefix("ycodeUnavailable") == true)
            #expect(!wc.responds(to: Selector(unavailable!.action)))
            _ = try WindowSnapshotTests().render(wc.window!.contentView!.superview!, to: "reference-toolbar.png")
        }
    }

    @Test func runBehaviorsDebugAreaAndInspector() throws {
        try withWindow { wc, src, _ in
            // A run without output hides the debug area on completion.
            wc.showDebugArea(true)
            wc.applyBehaviors(for: .running("Running Demo"))
            wc.applyBehaviors(for: .finished("Finished running Demo"))
            #expect(wc.debugItem.isCollapsed)
            // With output: shown on output, kept open on completion.
            wc.applyBehaviors(for: .running("Running Demo"))
            wc.session.appendConsole("hello\n", kind: .target)
            #expect(wc.lastBehavior?.event == .runOutput && !wc.debugItem.isCollapsed)
            wc.applyBehaviors(for: .finished("Finished running Demo"))
            #expect(!wc.debugItem.isCollapsed)
            // Console bar: filter, clear; halves.
            wc.session.appendConsole("Program ended with exit code: 0\n", kind: .target)
            wc.debugArea.consoleSearch.stringValue = "exit code"
            wc.debugArea.consoleSearchChanged()
            #expect(wc.debugArea.shownConsole == "Program ended with exit code: 0")
            wc.clearConsole(nil)
            #expect(wc.session.consoleEntries.isEmpty)
            wc.debugArea.toggleVariablesHalf()
            #expect(wc.debugArea.halvesShown == (false, true))
            wc.debugArea.toggleVariablesHalf()
            // Position in the debug bar; jump bar symbol; File inspector.
            wc.open(path: src.appendingPathComponent("main.swift").path, line: 3)
            wc.editor.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification))
            #expect(wc.debugArea.positionLabel.stringValue.hasPrefix("Line: 3"))
            #expect(wc.editor.jumpBarSymbol == "greet")
            wc.open(path: src.appendingPathComponent("main.swift").path, line: 7)
            wc.editor.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification))
            #expect(wc.editor.jumpBarSymbol == "No Selection")
            wc.inspector.show(file: src.appendingPathComponent("main.swift"))
            wc.inspector.select(0)
            #expect((wc.inspector.fileControls["Text Encoding"] as? NSPopUpButton)?.titleOfSelectedItem == "No Explicit Encoding")
            #expect((wc.inspector.fileControls["Line Endings"] as? NSPopUpButton)?.titleOfSelectedItem == "No Explicit Line Endings")
            #expect((wc.inspector.fileControls["Tab"] as? NSStepper)?.integerValue == 4)
            #expect(wc.inspector.nameField?.stringValue == "main.swift")
            let renamed = wc.renameFromInspector(src.appendingPathComponent("Other.swift"), to: "Renamed.swift")
            #expect(renamed.map { FileManager.default.fileExists(atPath: $0.path) } == true)
            _ = try WindowSnapshotTests().render(wc.window!.contentView!.superview!, to: "reference-debug-inspector.png")
        }
    }

    @Test func selectedSymbolHighlight() throws {
        try withWindow { wc, src, _ in
            wc.open(path: src.appendingPathComponent("main.swift").path, line: 3)
            let ns = wc.editor.textView.string as NSString
            let r = ns.range(of: "name")
            wc.editor.textView.setSelectedRange(NSRange(location: r.location + 1, length: 0))
            #expect(wc.editor.identifierAtCaret == "name")
            wc.editor.applySymbolHighlight("name")
            #expect(wc.editor.highlightedSymbol == "name" && wc.editor.highlightedOccurrences.count == 2)
        }
    }

    @Test func settingsSubPages() {
        let t = TestDefaults("reference-settings")
        defer { t.remove() }
        let p = Preferences(defaults: t.defaults)
        let wc = SettingsWindowController(prefs: p, components: [])
        wc.select(7)
        #expect(wc.selectedPane == "Editing")
        let editing = wc.pane(TextEditingSettingsPane.self)!
        _ = editing.view
        editing.page = .display
        let appearance = wc.pane(ThemesSettingsPane.self)!
        _ = appearance.view
        appearance.segment = .fonts
        #expect(appearance.title == "Appearance")
    }
}
