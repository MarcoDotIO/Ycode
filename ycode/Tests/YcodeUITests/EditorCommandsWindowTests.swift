import AppKit
import Foundation
import Testing
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@discardableResult
private func git(_ dir: URL, _ args: String...) throws -> String {
    try GitRepository.run("/usr/bin/git", ["-C", dir.path, "-c", "user.name=Ycode Test", "-c", "user.email=test@ycode.invalid",
                                           "-c", "commit.gpgsign=false"] + args)
}

/// The Editor menu's commands, the change gutter and the per-kind Editor
/// menus in a workspace window (`specs/ide/reference-ui-5.md` §2.6–§2.8,
/// §6.3–§6.5).
@MainActor
@Suite(.serialized) struct EditorCommandsWindowTests {
    /// A package under .build-ide with the given files (relative paths).
    func workspace(_ name: String, _ files: [String: String], git commit: Bool = false) throws -> URL {
        let dir = ycodeDir.appendingPathComponent(".build-ide/r30-\(name)")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"App\", targets: [.executableTarget(name: \"App\")])\n"
            .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        for (path, text) in files {
            let u = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        if commit {
            try git(dir, "init", "-q", "-b", "main")
            try git(dir, "add", "-A")
            try git(dir, "commit", "-q", "-m", "Initial")
        }
        return dir
    }

    func window(_ dir: URL) throws -> WorkspaceWindowController {
        _ = NSApplication.shared
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: dir)), loadDestinations: false, startLanguageService: false)
        wc.window?.appearance = NSAppearance(named: .aqua)
        wc.applyDefaultLayout()
        return wc
    }

    /// Runs `body` with a throwaway Preferences.shared.
    func withPreferences(_ body: (Preferences) throws -> Void) rethrows {
        let t = TestDefaults("r30")
        let old = Preferences.shared
        let p = Preferences(defaults: t.defaults, themesDirectory: ycodeDir.appendingPathComponent(".build-ide/r30-themes"))
        Preferences.shared = p
        defer { Preferences.shared = old; t.remove() }
        try body(p)
    }

    func enabled(_ wc: WorkspaceWindowController, _ action: String, tag: Int = 0) -> (Bool, NSControl.StateValue) {
        let item = NSMenuItem(title: "", action: NSSelectorFromString(action), keyEquivalent: "")
        item.tag = tag
        let ok = wc.validateMenuItem(item)
        return (ok, item.state)
    }

    func item(tag: Int) -> NSMenuItem {
        let i = NSMenuItem()
        i.tag = tag
        return i
    }

    // MARK: Structure (M2, M6) and the Edit menu items

    @Test func structureCommands() throws {
        try withPreferences { _ in
            let source = "struct A {\nfunc f() {\nlet x = g(1, 2)\n}\n}\n"
            let dir = try workspace("structure", ["Sources/App/main.swift": source])
            let wc = try window(dir)
            let file = dir.appendingPathComponent("Sources/App/main.swift")
            wc.open(path: file.path, line: nil)
            let e = wc.editor
            let undo = try #require(e.textView.undoManager)
            undo.groupsByEvent = false

            // Re-Indent (⌃I) over the whole file.
            e.textView.setSelectedRange(NSRange(location: 0, length: (e.text as NSString).length))
            wc.reindent(nil)
            #expect(e.text == "struct A {\n    func f() {\n        let x = g(1, 2)\n    }\n}\n")

            // Move Line Up / Down: disabled on the first line, one undo step each.
            e.reveal(line: 1)
            #expect(enabled(wc, "moveLineUp:").0 == false && enabled(wc, "moveLineDown:").0 == true)
            e.reveal(line: 3)
            wc.moveLineUp(nil)
            #expect(e.text == "struct A {\n        let x = g(1, 2)\n    func f() {\n    }\n}\n" && e.currentLine == 2)
            undo.undo()
            #expect(e.text == "struct A {\n    func f() {\n        let x = g(1, 2)\n    }\n}\n")

            // Shift Right / Left (⌘] / ⌘[).
            e.reveal(line: 5)
            wc.shiftRight(nil)
            #expect(e.text.hasSuffix("\n    }\n")) // the last line "}" became "    }"
            wc.shiftLeft(nil)
            #expect(e.text.hasSuffix("\n    }\n}\n"))

            // Format to Multiple Lines (⌃M) at the call's arguments.
            let call = (e.text as NSString).range(of: "1, 2").location
            e.textView.setSelectedRange(NSRange(location: call, length: 0))
            wc.formatToMultipleLines(nil)
            #expect(e.text.contains("let x = g(\n            1,\n            2\n        )"))

            // Add Documentation (⌥⌘/) above the function.
            e.reveal(line: 2)
            wc.addDocumentation(nil)
            #expect(e.text.contains("    /// <#Description#>\n    func f() {"))
            #expect(e.textView.selectedRange().length == "<#Description#>".utf16.count)

            // Edit ▸ Duplicate (⌘D) and the copy items' text.
            e.reveal(line: 1)
            wc.duplicateSelection(nil)
            #expect(e.text.hasPrefix("struct A {\nstruct A {\n") && e.currentLine == 2)
            #expect(e.fileAndLine == "main.swift:2")
            e.reveal(line: 4)
            let fn = (e.text as NSString).range(of: "f()").location
            e.textView.setSelectedRange(NSRange(location: fn, length: 0))
            #expect(e.symbolName(qualified: false) == "f()" && e.symbolName(qualified: true) == "A.f()")
            #expect(enabled(wc, "copySymbolName:").0 && enabled(wc, "copyFileAndLine:").0)
        }
    }

    // MARK: Selection (M14)

    @Test func multipleSelections() throws {
        let dir = try workspace("multi", ["Sources/App/main.swift": "abc\nabc\nab\nlet n = 1\nprint(n + n)\n"])
        let wc = try window(dir)
        wc.open(path: dir.appendingPathComponent("Sources/App/main.swift").path, line: nil)
        let e = wc.editor
        // Select Column Down twice: three insertion points at column 2 (clamped on "ab").
        e.textView.setSelectedRange(NSRange(location: 2, length: 0))
        wc.selectColumnDown(nil)
        wc.selectColumnDown(nil)
        #expect(e.selectionRanges.map(\.location) == [2, 6, 10])
        e.insertAtSelections("X")
        #expect(e.text.hasPrefix("abXc\nabXc\nabX\n"))
        e.textView.deleteBackward(nil)
        #expect(e.text.hasPrefix("abc\nabc\nab\n") && e.selectionRanges.count == 3)
        // Escape returns to one selection.
        e.textView.cancelOperation(nil)
        #expect(e.selectionRanges.count == 1)

        // Edit All in Scope (⌃⌘E): every `n`, typed over at once.
        let n = (e.text as NSString).range(of: "n = 1").location
        e.textView.setSelectedRange(NSRange(location: n, length: 0))
        wc.editAllInScope(nil)
        #expect(e.selectionRanges.count == 3)
        e.insertAtSelections("count")
        #expect(e.text.hasSuffix("let count = 1\nprint(count + count)\n"))

        // Split Selection By Lines; Balance Delimiters.
        e.textView.setSelectedRange(NSRange(location: 0, length: 7))
        wc.splitSelectionByLines(nil)
        #expect(e.selectionRanges == [NSRange(location: 0, length: 3), NSRange(location: 4, length: 3)])
        let plus = (e.text as NSString).range(of: "+").location
        e.textView.setSelectedRange(NSRange(location: plus, length: 0))
        wc.balanceDelimiters(nil)
        #expect((e.text as NSString).substring(with: e.textView.selectedRange()) == "count + count")
    }

    // MARK: Code Folding (M7)

    @Test func foldingCommands() throws {
        let src = "// one\n// two\n// three\nstruct S {\n    func a() {\n        print(1)\n    }\n    func b() {\n        print(2)\n    }\n}\n"
        let dir = try workspace("fold", ["Sources/App/main.swift": src])
        let wc = try window(dir)
        wc.open(path: dir.appendingPathComponent("Sources/App/main.swift").path, line: nil)
        let e = wc.editor
        wc.foldMethodsAndFunctions(nil)
        #expect(e.hiddenLines == [6, 9])
        wc.foldCommentBlocks(nil)
        #expect(e.hiddenLines == [2, 3, 6, 9] && e.gutter.foldStarts[1] == true)
        wc.unfoldMethodsAndFunctions(nil)
        #expect(e.hiddenLines == [2, 3])
        wc.unfoldCommentBlocks(nil)
        #expect(e.hiddenLines.isEmpty)
        // Unfold All has no shortcut and opens every fold.
        wc.foldMethodsAndFunctions(nil)
        e.unfoldAll(nil)
        #expect(e.hiddenLines.isEmpty)
        // ⌥⌘← inside a comment block folds the block.
        e.reveal(line: 2)
        e.fold(nil)
        #expect(e.hiddenLines == [2, 3])
    }

    // MARK: Font Size (M5), Syntax Coloring, Minimap (E5)

    @Test func fontSizeColoringAndMinimap() throws {
        try withPreferences { p in
            let dir = try workspace("font", ["Sources/App/main.swift": "let x = 1\n", "Sources/App/c.c": "int x;\n"])
            let wc = try window(dir)
            wc.open(path: dir.appendingPathComponent("Sources/App/main.swift").path, line: nil)
            let base = p.theme.fontSize
            #expect(enabled(wc, "resetFontSize:").0 == false)
            wc.increaseFontSize(nil)
            wc.increaseFontSize(nil)
            #expect(p.sourceFontSize == base + 2 && Theme.font.pointSize == CGFloat(base + 2))
            #expect(wc.editor.textView.typingAttributes[.font] as? NSFont == Theme.font)
            #expect(p.theme.fontSize == base) // a user setting, not a theme edit
            wc.decreaseFontSize(nil)
            #expect(p.sourceFontSize == base + 1 && enabled(wc, "resetFontSize:").0)
            wc.resetFontSize(nil)
            #expect(p.sourceFontSize == nil && Theme.font.pointSize == CGFloat(base))
            p.sourceFontSize = 99
            #expect(p.sourceFontSize == 48 && enabled(wc, "increaseFontSize:").0 == false)
            p.sourceFontSize = nil

            // Syntax Coloring: Default (checked), the file's language mixed.
            let swiftTag = EditorMenu.syntaxTag(.swift), noneTag = EditorMenu.syntaxTag(.plain)
            #expect(enabled(wc, "setSyntaxColoring:", tag: EditorMenu.defaultSyntaxTag).1 == .on)
            #expect(enabled(wc, "setSyntaxColoring:", tag: swiftTag).1 == .mixed)
            wc.setSyntaxColoring(item(tag: noneTag))
            #expect(wc.editor.coloringLanguage == .plain && wc.editor.syntaxOverride == .plain)
            #expect(enabled(wc, "setSyntaxColoring:", tag: noneTag).1 == .on && enabled(wc, "setSyntaxColoring:", tag: swiftTag).1 == .off)
            wc.setSyntaxColoring(item(tag: EditorMenu.defaultSyntaxTag))
            #expect(wc.editor.coloringLanguage == .swift && wc.editor.syntaxOverride == nil)

            // Format is for Swift files only.
            #expect(enabled(wc, "formatFile:").0)
            wc.open(path: dir.appendingPathComponent("Sources/App/c.c").path, line: nil)
            #expect(enabled(wc, "formatFile:").0 == false && enabled(wc, "formatSelection:").0 == false)

            // Minimap: a user setting; its width follows the editor (§6.5).
            wc.editor.toggleMinimap(nil)
            #expect(p.showMinimap && wc.editor.showsMinimap)
            wc.editor.view.layoutSubtreeIfNeeded()
            #expect(wc.editor.minimapWidthValue == MinimapView.width(forEditorWidth: wc.editor.view.bounds.width))
            wc.editor.toggleMinimap(nil)
            #expect(!p.showMinimap && !wc.editor.showsMinimap)
        }
    }

    @Test func formatFileWithSwiftFormat() async throws {
        guard let tool = SwiftFormatTool.locate() else { return } // no toolchain swift-format
        let dir = try workspace("format", ["Sources/App/main.swift": "let  x=1\nfunc f( ) { }\n"])
        let wc = try window(dir)
        wc.open(path: dir.appendingPathComponent("Sources/App/main.swift").path, line: nil)
        let r = await wc.editor.formatWithSwiftFormat(selectionOnly: false, tool: tool)
        #expect(r == .success(true))
        #expect(wc.editor.text.hasPrefix("let x = 1\n"))
        #expect(MenuTitles.title(generic: "Format File", in: wc.menuContext) == "Format File with \u{2018}swift-format\u{2019}")
        // A missing tool is reported, not crashed on.
        #expect(SwiftFormatTool.format("x", fileName: "a.swift", tool: nil) == .failure(.toolNotFound))
    }

    // MARK: Change gutter (E3)

    @Test func changeGutterAcceptance() async throws {
        let lines = (1...20).map { "let v\($0) = \($0)" }.joined(separator: "\n") + "\n"
        let dir = try workspace("changes", ["Sources/App/main.swift": lines], git: true)
        let wc = try window(dir)
        let file = dir.appendingPathComponent("Sources/App/main.swift")
        wc.open(path: file.path, line: nil)
        let e = wc.editor
        await e.sourceChangesIdle()   // the baselines are read in the background
        #expect(e.showsChangeColumn && e.sourceChanges.isEmpty)
        #expect(e.gutter.ruleThickness == 48 + GutterView.changeColumnWidth)

        // Editing line 13 shows a bar on line 13 within one second.
        let r13 = try #require(e.textView.lineIndex.range(ofLine: 13))
        e.textView.setSelectedRange(NSRange(location: NSMaxRange(r13), length: 0))
        e.textView.insertText(" + 1", replacementRange: NSRange(location: NSNotFound, length: 0))
        Self.runMainRunLoop(seconds: 1) { !e.sourceChanges.isEmpty }
        #expect(e.sourceChanges == [SourceChangeRegion(kind: .modified, firstLine: 13, lineCount: 1, staged: false)])
        #expect(e.gutter.changeBarDescriptions == ["Local modification on line 13"])

        // ⌃\ moves the caret to it; ⌃| wraps back to it.
        e.reveal(line: 1)
        #expect(enabled(wc, "jumpToNextChange:").0)
        wc.jumpToNextChange(nil)
        #expect(e.currentLine == 13)
        e.reveal(line: 20)
        wc.jumpToPreviousLocalOrUpstreamChange(nil)
        #expect(e.currentLine == 13)

        // The tooltip and accessibility element of the bar.
        let row = try #require(e.gutter.visibleLines().first { $0.line == 13 })
        #expect(e.gutter.changeToolTip(atGutterY: row.rect.midY) == "Unstaged change")
        let labels = (e.gutter.accessibilityChildren() ?? []).compactMap { ($0 as? NSAccessibilityElement)?.accessibilityLabel() }
        #expect(labels.contains("Local modification on line 13"))

        // Staged: after saving and `git add`, the bar is a staged change.
        try e.save()
        try git(dir, "add", "-A")
        e.refreshSourceChanges()
        await e.sourceChangesIdle()
        #expect(e.sourceChanges.map(\.staged) == [true])
        #expect(e.gutter.changeToolTip(atGutterY: row.rect.midY) == "Staged change")
        // Deleting a line: a deletion mark before the next line.
        let r2 = try #require(e.textView.lineIndex.range(ofLine: 2))
        e.textView.setSelectedRange(NSRange(location: r2.location, length: r2.length + 1))
        e.textView.delete(nil)
        e.refreshSourceChanges()
        await e.sourceChangesIdle()
        #expect(e.sourceChanges.first == SourceChangeRegion(kind: .deleted, firstLine: 2, lineCount: 0, staged: false))

        // Clicking a bar opens Code Review, inline, on that region.
        e.gutter.onChangeClick?(2)
        #expect(e.isShowingInlineComparison && e.comparisonStyle == .inline)
        #expect(e.currentReviewChange.map { e.reviewChanges[$0].newStart } == 2)

        // A file outside git has no change column.
        let plain = try workspace("nochanges", ["Sources/App/main.swift": "let a = 1\n"])
        let wc2 = try window(plain)
        wc2.open(path: plain.appendingPathComponent("Sources/App/main.swift").path, line: nil)
        await wc2.editor.sourceChangesIdle()
        #expect(!wc2.editor.showsChangeColumn && wc2.editor.gutter.ruleThickness == 48)
    }

    /// Runs the main run loop (timers fire) until `done` or the timeout.
    static func runMainRunLoop(seconds: TimeInterval, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    // MARK: Editor menus per kind (§2.8)

    @Test func editorMenuFollowsTheFocusedEditor() throws {
        let catalog = "Sources/App/Assets.xcassets"
        let dir = try workspace("kinds", [
            "Sources/App/main.swift": "let a = 1\n",
            "Sources/App/View.xib": sampleXib,
            "Sources/App/Info.plist": """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
            \t<key>CFBundleName</key>
            \t<string>App</string>
            </dict>
            </plist>

            """,
            catalog + "/Contents.json": "{\n  \"info\" : {\n    \"author\" : \"xcode\",\n    \"version\" : 1\n  }\n}\n",
        ])
        let wc = try window(dir)
        let editorMenu = try #require(MainMenu.menu("Editor", EditorMenu.items(for: .other), path: "Editor") as? CommandMenu)
        editorMenu.editorKind = .other
        func titles() -> [String] {
            MenuBarDelegate.shared.update(editorMenu, controller: wc)
            return editorMenu.items.filter { !$0.isSeparatorItem }.map(\.title)
        }

        wc.open(path: dir.appendingPathComponent("Sources/App/main.swift").path, line: nil)
        #expect(wc.focusedEditorKind == .source && titles().contains("Font Size"))

        // Property list: Add Item, Value Type, Raw Keys and Values.
        wc.open(path: dir.appendingPathComponent("Sources/App/Info.plist").path, line: nil)
        #expect(wc.menuContext.editorKind == .propertyList)
        #expect(titles() == ["Show Editor Only", "Preview", "Assistant", "Code Review", "Layout", "Add Item", "Value Type", "Raw Keys and Values"])
        let pe = try #require(wc.plistEditor)
        #expect(pe.displayedKey("CFBundleName") == "Bundle name")
        #expect(enabled(wc, "toggleRawKeysAndValues:").1 == .off)
        wc.toggleRawKeysAndValues(nil)
        #expect(pe.showsRawKeys && pe.displayedKey("CFBundleName") == "CFBundleName" && enabled(wc, "toggleRawKeysAndValues:").1 == .on)
        pe.selectItem(at: [0])
        wc.addPlistItem(nil)
        #expect(pe.selectedItemPath == [1] && pe.selectedTypeName == "String")
        let number = PlistTree.types.firstIndex(of: "Number")!
        wc.setPlistValueType(item(tag: number))
        #expect(pe.selectedTypeName == "Number" && enabled(wc, "setPlistValueType:", tag: number).1 == .on)

        // Interface Builder: zoom and the document outline.
        wc.open(path: dir.appendingPathComponent("Sources/App/View.xib").path, line: nil)
        #expect(wc.focusedEditorKind == .interfaceBuilder && titles().contains("Resolve Auto Layout Issues"))
        let ib = try #require(wc.interfaceEditor)
        wc.zoomCanvasToPercent(item(tag: 5_000))
        #expect(abs(ib.zoom - 0.5) < 0.001 && enabled(wc, "zoomCanvasToPercent:", tag: 5_000).1 == .on)
        let outline = ib.isOutlineVisible
        #expect(enabled(wc, "toggleDocumentOutline:").1 == (outline ? .on : .off))
        wc.toggleDocumentOutline(nil)
        #expect(ib.isOutlineVisible == !outline)

        // Asset catalog: Add New Asset ▸ Image Set, Delete Selected Items.
        wc.open(path: dir.appendingPathComponent(catalog).path, line: nil)
        #expect(wc.focusedEditorKind == .assetCatalog && titles().contains("Device Image Reps"))
        let ae = try #require(wc.assetEditor)
        #expect(enabled(wc, "deleteSelectedAssets:").0 == false)
        wc.addNewAsset(item(tag: AssetCatalogEditorController.creatable["Image Set"]!))
        #expect(ae.selected?.kind == .imageSet && enabled(wc, "deleteSelectedAssets:").0)
        wc.deleteSelectedAssets(nil)
        #expect(ae.catalog.sets().isEmpty)

        // Back to source: the source menu again.
        wc.open(path: dir.appendingPathComponent("Sources/App/main.swift").path, line: nil)
        #expect(titles().contains("Structure") && editorMenu.editorKind == .source)
    }

    // MARK: Navigate: counterparts and their alternates (M12), Layout

    @Test func counterpartsAndLayout() throws {
        let dir = try workspace("counterparts", ["Sources/App/Foo.swift": "struct Foo {}\n", "Sources/App/FooTests.swift": "let t = 1\n"])
        let wc = try window(dir)
        let foo = dir.appendingPathComponent("Sources/App/Foo.swift").path
        let tests = dir.appendingPathComponent("Sources/App/FooTests.swift").path
        wc.open(path: foo, line: nil)
        wc.jumpToNextCounterpart(nil)
        #expect(wc.editor.fileURL?.path == tests)
        wc.jumpToNextCounterpart(nil)
        #expect(wc.editor.fileURL?.path == foo)
        // … using Tab: a new editor tab; … in Next Editor Pane: a new pane.
        let tabs = wc.editorArea.tabs.count
        wc.jumpToNextCounterpartUsingTab(nil)
        #expect(wc.editorArea.tabs.count == tabs + 1 && wc.editor.fileURL?.path == tests)
        wc.jumpToPreviousCounterpartInNextEditorPane(nil)
        #expect(wc.editorArea.tab.editors.count == 2 && wc.editor.fileURL?.path == foo)

        // Layout ▸ is for the canvas: disabled while it is hidden.
        #expect(enabled(wc, "setCanvasLayout:", tag: 0) == (false, .on))
        wc.setCanvasLayout(item(tag: 2))
        #expect(wc.editorArea.canvasLayout == .below && enabled(wc, "setCanvasLayout:", tag: 2).1 == .on)
        wc.setCanvasLayout(item(tag: 0))
        #expect(wc.editorArea.canvasLayout == nil)

        // Show / Hide All Issues toggles every editor.
        #expect(MenuTitles.title(generic: "Show All Issues", in: wc.menuContext) == "Hide All Issues")
        wc.toggleInlineIssues(nil)
        #expect(!wc.editor.showsInlineIssues && MenuTitles.title(generic: "Show All Issues", in: wc.menuContext) == "Show All Issues")
    }
}
