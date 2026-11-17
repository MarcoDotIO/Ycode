import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// B4-EDITOR (1.0.0-beta.4): the editor items of `specs/ide/parity-inventory.md`
/// P-003, P-054, P-059, P-062, P-064, P-065, P-066, P-068, P-071, P-083,
/// P-084, P-203. Windows stay off every display (the offscreen guard).
@MainActor
@Suite(.serialized) struct Beta4EditorTests {
    static let shots = ycodeDir.appendingPathComponent(".build-ide/b4-shots")

    func window(_ name: String = "B4Editor") throws -> (WorkspaceWindowController, URL) {
        _ = NSApplication.shared
        let dir = try WindowSnapshotTests().samplePackage(directory: name)
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: dir)), loadDestinations: false,
                                           startLanguageService: false)
        wc.window?.appearance = NSAppearance(named: .aqua)
        wc.applyDefaultLayout()
        wc.window?.setFrame(NSRect(x: -6000, y: -6000, width: 1400, height: 880), display: true)
        return (wc, dir.appendingPathComponent("Sources/Sample/main.swift"))
    }

    func shot(_ wc: WorkspaceWindowController, _ name: String) {
        try? FileManager.default.createDirectory(at: Self.shots, withIntermediateDirectories: true)
        guard let v = wc.window?.contentView?.superview, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: Self.shots.appendingPathComponent(name))
    }

    /// The enabled state AppKit would give `item`: its target, else the
    /// first object along the key window's responder chain (then the
    /// window controller) that implements the action, asked to validate.
    func enabled(_ item: NSMenuItem, in wc: WorkspaceWindowController) -> Bool {
        guard let action = item.action else { return false }
        var chain: [NSObject] = []
        var r: NSResponder? = wc.window?.firstResponder
        while let x = r { chain.append(x); r = x.nextResponder }
        chain.append(wc)
        guard let t = (item.target as? NSObject) ?? chain.first(where: { $0.responds(to: action) }) else { return false }
        if let v = t as? NSMenuItemValidation { return v.validateMenuItem(item) }
        return true
    }

    static let inFileFindItems: [(String, Int)] = [
        ("performFindPanelAction:", 1), ("performFindPanelAction:", 12), ("performFindPanelAction:", 2), ("performFindPanelAction:", 3),
        ("findAndSelectNext:", 0), ("findAndSelectPrevious:", 0), ("performFindPanelAction:", 5), ("performFindPanelAction:", 4),
        ("performFindPanelAction:", 6), ("replaceAndFindPrevious:", 0), ("performFindPanelAction:", 7), ("useSelectionForReplace:", 0),
        ("selectNextOccurrence:", 0), ("selectPreviousOccurrence:", 0), ("performFindPanelAction:", 9), ("performFindPanelAction:", 10),
        ("hideFindBar:", 0), ("findSelectedTextInWorkspace:", 0), ("findSelectedWordsInWorkspace:", 0),
    ]

    func findItems() -> [NSMenuItem] {
        Self.inFileFindItems.map { a, tag in
            let i = NSMenuItem(title: a, action: Selector(a), keyEquivalent: "")
            i.tag = tag
            return i
        }
    }

    /// P-003 and P-203: the Find menu's in-file items are enabled with a
    /// file open, from the editor and from the navigator; ⌘F from the
    /// navigator opens the bar; the hidden bar and the empty editor's text
    /// area are out of the accessibility tree.
    @Test func findMenuEnabledAndBarHidden() throws {
        let (wc, main) = try window()
        wc.open(path: main.path, line: nil)
        let ed = wc.editor
        #expect(ed.findBar.isHidden && !ed.isShowingFindBar)   // P-203
        wc.window?.makeFirstResponder(ed.textView)
        let fromEditor = findItems().filter { !enabled($0, in: wc) }.map(\.title)
        #expect(fromEditor.isEmpty, "disabled with the editor focused: \(fromEditor)")
        wc.window?.makeFirstResponder(wc.navigator.view)
        let fromNavigator = findItems().filter { !enabled($0, in: wc) }.map(\.title)
        #expect(fromNavigator.isEmpty, "disabled with the navigator focused: \(fromNavigator)")
        // ⌘F with the navigator focused: the editor's bar, which takes the keyboard.
        let find = NSMenuItem(title: "Find…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        find.tag = 1
        wc.performFindPanelAction(find)
        #expect(ed.isShowingFindBar && !ed.findBar.isHidden)
        shot(wc, "mac-p003-find-bar.png")
        ed.hideFindBar()
        #expect(ed.findBar.isHidden)
        // No file: none of them, and no text area for accessibility.
        wc.closeDocument(nil)
        let noFile = findItems().filter { enabled($0, in: wc) && $0.action != #selector(WorkspaceWindowController.findSelectedTextInWorkspace(_:)) }
        #expect(noFile.allSatisfy { $0.action == nil }, "enabled without a file: \(noFile.map(\.title))")
        #expect(!ed.textView.isAccessibilityElement() && ed.findBar.isHidden)
    }

    /// P-071: Tab never moves into the editor; the empty editor takes no typing.
    @Test func tabStaysOutOfTheEditor() throws {
        let (wc, main) = try window()
        wc.open(path: main.path, line: nil)
        let before = wc.editor.text
        #expect(!wc.editor.textView.canBecomeKeyView)
        wc.window?.makeFirstResponder(wc.navigator.view)
        for _ in 0..<6 {
            wc.window?.selectNextKeyView(nil)
            #expect(wc.window?.firstResponder !== wc.editor.textView)
        }
        #expect(wc.editor.text == before)
        wc.closeDocument(nil)
        wc.editor.textView.insertTab(nil)
        wc.editor.textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(wc.editor.text.isEmpty)
    }

    /// P-059: a click in the ribbon's column places the caret; no breakpoint.
    @Test func ribbonColumnPlacesTheCaret() throws {
        let (wc, main) = try window()
        Preferences.shared.showFoldingRibbon = false
        wc.open(path: main.path, line: nil)
        let g = wc.editor.gutter
        #expect(g.isInRibbonColumn(x: g.ruleThickness - 4) && !g.isInRibbonColumn(x: CGFloat(EditorMetrics.lineNumberEnd) - 4))
        g.placeCaret(atLine: 3)
        let ns = wc.editor.text as NSString
        let line3 = LineIndex(wc.editor.text).starts[2]
        #expect(wc.editor.textView.selectedRange() == NSRange(location: line3, length: 0))
        #expect(g.marks.breakpoints.isEmpty)
        _ = ns
    }

    /// P-062: Open in New Tab names the tab after the file, extension kept.
    @Test func openInNewTabTitles() throws {
        let (wc, main) = try window()
        wc.open(path: main.path, line: nil)
        wc.openInNewTab(nil)
        #expect(wc.editorArea.tabs.count == 2)
        #expect(wc.editorArea.tabTitles == ["main.swift", "main.swift"])
    }

    /// P-064: Editor Pane Below beside a split stacks in the focused column.
    @Test func paneBelowStacksInTheColumn() throws {
        let (wc, main) = try window()
        wc.open(path: main.path, line: nil)
        wc.splitEditor(nil)
        wc.splitEditorBelow(nil)
        let t = wc.editorArea.tab
        #expect(t.editors.count == 3 && t.sideBySide)
        #expect(t.lanes == [0, 1, 1] && t.laneGroups.map(\.count) == [1, 2])
        #expect(t.controller.splitViewItems.count == 2 && t.laneControllers.first?.splitView.isVertical == false)
        shot(wc, "mac-p064-pane-below.png")
        // Closing the lower pane leaves two columns.
        wc.closeEditor(nil)
        #expect(t.lanes == [0, 1] && t.controller.splitViewItems.count == 2)
    }

    /// P-065: the Add Editor and Editor Options menus.
    @Test func addEditorAndEditorOptionsMenus() throws {
        let (wc, main) = try window()
        wc.open(path: main.path, line: nil)
        let add = EditorOptionsMenu.addMenu()
        #expect(add.items.map { $0.isSeparatorItem ? "|" : $0.title } == ["Tab", "|", "Editor Pane On Right", "Editor Pane Below"])
        #expect(add.items.map { MainMenu.canonicalShortcut($0) } == ["⌘T", "", "⌃⌘T", "⌃⌥⌘T"])
        let opts = EditorOptionsMenu.menu()
        let layout = try #require(opts.items.first?.submenu)
        #expect(layout.items.map { $0.isSeparatorItem ? "|" : $0.title } == ["Automatic", "|", "Canvas on Right", "Canvas on Bottom"])
        let minimap = try #require(opts.items.first { $0.title == "Minimap" })
        Preferences.shared.showMinimap = true
        wc.window?.makeFirstResponder(wc.navigator.view)
        #expect(enabled(minimap, in: wc) && minimap.state == .on)
        wc.window?.makeFirstResponder(wc.editor.textView)
        minimap.state = .off
        #expect(enabled(minimap, in: wc) && minimap.state == .on)
        #expect(MainMenu.canonicalShortcut(minimap) == "⌃⇧⌘M")
        let coverage = try #require(opts.items.first { $0.title == "Code Coverage" })
        #expect(enabled(coverage, in: wc))
    }

    /// P-066: the assistant with no counterpart shows a centred "No Editor".
    @Test func assistantNoEditorPlaceholder() throws {
        let (wc, main) = try window()
        wc.open(path: main.path, line: nil)
        wc.toggleAssistant(nil)
        let a = try #require(wc.editorArea.tab.assistant)
        #expect(a.noEditorPlaceholder?.label.stringValue == "No Editor" && a.textView.string.isEmpty && a.showsNoDocument)
        shot(wc, "mac-p066-no-editor.png")
    }

    /// P-068: an unedited file follows the disk; an edited one keeps its text.
    @Test func fileChangedOnDiskReloads() throws {
        let (wc, main) = try window("B4EditorDisk")
        wc.open(path: main.path, line: nil)
        let e = wc.editor
        e.followDiskIfUnedited()   // the first look records the stamp
        let changed = "// changed on disk\n" + e.text
        try changed.write(to: main, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: main.path)
        #expect(e.followDiskIfUnedited() && e.text == changed && !e.isDirty)
        // Edited: kept.
        e.textView.insertText("let edited = 1\n", replacementRange: NSRange(location: 0, length: 0))
        try ("// again\n" + changed).write(to: main, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: main.path)
        #expect(!e.followDiskIfUnedited() && e.text.hasPrefix("let edited"))
    }

    /// P-083: Swift Markup rendered, not shown raw; no interface-file link
    /// and no documentation link for project symbols.
    @Test func quickHelpRendersMarkup() throws {
        let hover = """
        ```swift
        func sort()
        ```

        Sorts the collection in place.

        ## Complexity

        Runs in O(*n* log *n*) time---0 extra **space**.

        ```swift
        var a = [3, 1]
        a.sort()
        ```

        1. First step.
        2. Second step.
        """
        let sdk = QuickHelpDocument(hover: hover, file: "/sdk/Swift.swiftinterface")
        #expect(!sdk.showsFileLink && sdk.showsDocumentationLink)
        #expect(sdk.discussion.contains("Runs in O(n log n) time—0 extra space."))
        #expect(sdk.discussionBlocks.contains(.code("var a = [3, 1]\na.sort()")))
        #expect(sdk.discussionBlocks.contains(.listItem(marker: "2.", [QuickHelpRun("Second step.")])))
        #expect(sdk.discussionBlocks.contains(.heading([QuickHelpRun("Complexity")])))
        let runs = try #require(sdk.discussionBlocks.first { if case .paragraph = $0 { true } else { false } })
        if case .paragraph(let r) = runs { #expect(r.contains(QuickHelpRun("n", .emphasis)) && r.contains(QuickHelpRun("space", .strong))) }
        let project = QuickHelpDocument(hover: hover, file: "/project/Sort.swift")
        #expect(project.showsFileLink && !project.showsDocumentationLink)
        let v = QuickHelpView.make(sdk)
        let ids = v.arrangedSubviews.map { $0.accessibilityIdentifier() }
        #expect(ids.contains("quickhelp.code") && ids.contains("quickhelp.listItem") && !ids.contains("quickhelp.file"))
    }

    /// P-084: the edit box sits on the identifier only; the other
    /// occurrences are outlined, not filled.
    @Test func renameBoxesOnTheIdentifier() throws {
        let (wc, main) = try window()
        wc.open(path: main.path, line: nil)
        let e = wc.editor
        let ns = e.text as NSString
        let r = ns.range(of: "greet(times")
        let name = NSRange(location: r.location, length: 5)
        e.highlightOccurrences(of: "greet")
        e.showRenameField(name: "greet", at: name) { _ in }
        let word = try #require(e.textView.segmentRects(name).first)
        let field = try #require(e.renameFieldFrame)
        #expect(abs(field.minX - (word.minX - 2)) < 0.5 && abs(field.width - (word.width + 4)) < 1.5, "\(field) \(word)")
        #expect(e.isShowingRenameBoxes && e.renameBoxRects.count == e.highlightedOccurrences.count - 1)
        shot(wc, "mac-p084-rename.png")
        e.hideRenameBoxes()
        #expect(!e.isShowingRenameBoxes)
    }

    /// P-054: doc comments in the comment grey in light, as in dark.
    @Test func docCommentColour() {
        #expect(DefaultTheme.light.roles[.docComment] == DefaultTheme.light.roles[.comment])
        #expect(WorkspaceChrome.defaultThemeColors(dark: false).tokens["docComment"] == ThemeColor(hex: "#6A7084"))
    }
}
