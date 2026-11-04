import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
import YcodeLanguage
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The Find navigator in a window (specs/ide/navigators.md §Find
/// navigator, "Ycode implementation"): Replace mode with per-match and
/// per-file inclusion, Replace All through an unsaved editor and the
/// disk, one undo for every file, stepping and keyboard navigation, the
/// streamed search, scopes, history, and the Find menu's items.
@MainActor
@Suite(.serialized) struct FindNavigatorWindowTests {
    static let files: [String: String] = [
        "Sources/Demo/main.swift": "let old = 1\nprint(old)\n",
        "Sources/Demo/Other.swift": "let older = 2\nlet old2 = old\n",
        "Sources/Demo/notes.txt": "old notes\n",
    ]

    func withWindow(_ body: @MainActor (WorkspaceWindowController, URL) async throws -> Void) async throws {
        let prefs = IsolatedPreferences("find-window")
        let dir = ycodeDir.appendingPathComponent(".build-ide/find-window/\(UUID().uuidString)/Pkg")
        defer {
            prefs.restore()
            try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
        }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sources/Demo"), withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"Demo\", targets: [.executableTarget(name: \"Demo\")])\n"
            .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        for (rel, text) in Self.files { try text.write(to: dir.appendingPathComponent(rel), atomically: true, encoding: .utf8) }
        var blob = Data("old".utf8)
        blob.append(contentsOf: [0, 0, 7])
        try blob.write(to: dir.appendingPathComponent("Sources/Demo/blob.bin"))
        _ = NSApplication.shared
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: dir)),
                                           loadDestinations: false, startLanguageService: false, openFirstFile: false)
        wc.applyDefaultLayout()
        try await body(wc, dir)
    }

    func cell(_ nav: NavigatorAreaController, _ item: OutlineItem) -> NSTableCellView? {
        let r = nav.outlineView.row(forItem: item)
        return r < 0 ? nil : nav.outlineView.view(atColumn: 0, row: r, makeIfNecessary: true) as? NSTableCellView
    }

    func checkbox(_ c: NSTableCellView?) -> FindCheckbox? { c?.subviews.compactMap { $0 as? FindCheckbox }.first }

    @Test func replaceModeInclusionReplaceAllAndOneUndoForEveryFile() async throws {
        try await withWindow { wc, dir in
            let main = dir.appendingPathComponent("Sources/Demo/main.swift"), other = dir.appendingPathComponent("Sources/Demo/Other.swift")
            let undo = try #require(wc.window?.undoManager)
            undo.groupsByEvent = false
            wc.open(path: main.path, line: nil)
            let e = wc.editor
            #expect(e.textView.undoManager === undo)
            // An unsaved edit: searched and replaced in the editor, not on disk.
            #expect(e.replaceText(with: e.text + "// old again\n", actionName: "Typing"))
            #expect(e.isDirty)
            let nav = wc.navigator
            wc.findAndReplaceInWorkspace(nil)
            #expect(nav.selectedIndex == 3 && nav.isShowingFindReplaceRow && nav.findMode.titleOfSelectedItem == "Replace")
            nav.setFindOptions(match: FindQuery.Match.matchingWord.rawValue)
            nav.find("old")
            // Binaries are skipped; files in navigator order; the unsaved line found.
            #expect(nav.rows(3).map(\.title) == ["main.swift  (3)", "notes.txt  (1)", "Other.swift  (1)"])
            #expect(nav.rows(3)[0].children.map(\.title) == ["let old = 1", "print(old)", "// old again"])
            #expect(nav.findCountText == "5 results in 3 files")
            // Leave out notes.txt and main.swift's second match.
            nav.setFindInclusion(false, file: 1, match: nil)
            nav.setFindInclusion(false, file: 0, match: 1)
            nav.findReplaceField.stringValue = "new"
            nav.replacementChanged()
            #expect(nav.findModel.plan?.includedCount == 3 && nav.findReplaceAllButton.isEnabled)
            let rows = nav.rows(3)
            #expect(checkbox(cell(nav, rows[0]))?.state == .mixed && checkbox(cell(nav, rows[1]))?.state == .off)
            #expect(checkbox(cell(nav, rows[0].children[0]))?.state == .on && checkbox(cell(nav, rows[0].children[1]))?.state == .off)
            // The preview: the match struck out, the replacement after it.
            let preview = try #require(cell(nav, rows[0].children[0])?.textField?.attributedStringValue)
            #expect(preview.string == "let oldnew = 1")
            #expect(preview.attribute(.strikethroughStyle, at: 4, effectiveRange: nil) != nil)
            _ = try WindowSnapshotTests().render(wc.window!.contentView!.superview!, to: "find-replace-preview.png")

            let t = try #require(nav.replaceAllFindMatches())
            #expect(t.replacedCount == 3 && t.changes.count == 2)
            #expect(nav.findCountText == "Replaced 3 occurrences in 2 files")
            #expect(e.text == "let new = 1\nprint(old)\n// new again\n" && e.isDirty)
            #expect(try String(contentsOf: main, encoding: .utf8) == "let old = 1\nprint(old)\n")
            #expect(try String(contentsOf: other, encoding: .utf8) == "let older = 2\nlet old2 = new\n")
            // The results follow: what is left.
            #expect(nav.findModel.matchCount == 2)
            // One undo restores the editor and the file on disk; redo replays both.
            #expect(undo.undoActionName == "Replace 3 Occurrences")
            undo.undo()
            #expect(e.text == "let old = 1\nprint(old)\n// old again\n")
            #expect(try String(contentsOf: other, encoding: .utf8) == "let older = 2\nlet old2 = old\n")
            undo.redo()
            #expect(e.text == "let new = 1\nprint(old)\n// new again\n")
            #expect(try String(contentsOf: other, encoding: .utf8) == "let older = 2\nlet old2 = new\n")
            // Replace: only the selected row's match.
            nav.setFindOptions(match: FindQuery.Match.containing.rawValue)
            nav.find("old")
            let printRow = try #require(nav.rows(3).first?.children.first { $0.title == "print(old)" })
            nav.outlineView.selectRowIndexes([nav.outlineView.row(forItem: printRow)], byExtendingSelection: false)
            #expect(nav.findReplaceButton.isEnabled)
            #expect(nav.replaceSelectedFindMatches()?.replacedCount == 1)
            #expect(e.text == "let new = 1\nprint(new)\n// new again\n")
            undo.removeAllActions()
        }
    }

    @Test func steppingKeyboardStreamingHistoryAndScopes() async throws {
        try await withWindow { wc, dir in
            let nav = wc.navigator
            let main = dir.appendingPathComponent("Sources/Demo/main.swift").path
            wc.showFindNavigator()
            // Return in the field: a streamed search, noted in the history.
            nav.findField.stringValue = "old"
            _ = nav.findField.target?.perform(nav.findField.action, with: nav.findField)
            await nav.runningFind?.value
            #expect(nav.recentSearches.first == "old" && nav.findModel.recent == ["old"])
            #expect(nav.rows(3).map(\.title) == ["main.swift  (2)", "notes.txt  (1)", "Other.swift  (3)"])
            // A new search cancels the running one.
            let first = nav.beginFind("zzz")
            let second = nav.beginFind("older")
            await first.value
            await second.value
            #expect(nav.rows(3).map(\.title) == ["Other.swift  (1)"] && nav.findCountText == "1 result in 1 file")
            nav.find("old")

            // Find Next / Previous in Workspace open each match, selected.
            let next = NSMenuItem(title: "", action: #selector(WorkspaceWindowController.findNextInWorkspace(_:)), keyEquivalent: "")
            #expect(wc.validateMenuItem(next))
            wc.findNextInWorkspace(nil)
            #expect(wc.editor.fileURL?.path == main && wc.editor.textView.selectedRange() == NSRange(location: 4, length: 3))
            wc.findNextInWorkspace(nil)
            #expect(wc.editor.textView.selectedRange() == NSRange(location: 18, length: 3))
            wc.findPreviousInWorkspace(nil)
            wc.findPreviousInWorkspace(nil)
            #expect(wc.editor.fileURL?.lastPathComponent == "Other.swift" && wc.editor.currentLine == 2)
            // The keyboard: the down arrow moves to the next match and opens it.
            let rows = nav.rows(3)
            nav.outlineView.selectRowIndexes([nav.outlineView.row(forItem: rows[0].children[0])], byExtendingSelection: false)
            wc.window?.makeFirstResponder(nav.outlineView)
            let down = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: wc.window?.windowNumber ?? 0,
                                                     context: nil, characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125))
            nav.outlineView.keyDown(with: down)
            #expect(nav.selectedItem === rows[0].children[1])
            #expect(wc.editor.fileURL?.path == main && wc.editor.textView.selectedRange() == NSRange(location: 18, length: 3))

            // Scopes: open files (two tabs), a custom scope from the editor, current results.
            wc.newTab(nil)
            wc.open(path: dir.appendingPathComponent("Sources/Demo/Other.swift").path, line: nil)
            nav.setFindScope(.openFiles)
            #expect(nav.findScope.title == "In Open Files")
            nav.find("old")
            #expect(nav.rows(3).map(\.title) == ["main.swift  (2)", "Other.swift  (3)"])
            // The scope goes into the shared preferences: put back what was
            // there, or later tests see an extra item in the scope menu.
            let savedScopes = Preferences.shared.findCustomScopes
            defer { Preferences.shared.findCustomScopes = savedScopes }
            nav.editCustomScopes()
            let editor = try #require(nav.lastScopeEditor)
            _ = editor.view
            editor.addScope()
            editor.setName("Text files")
            editor.setRule(0, .init(.extension, .is, "txt"))
            #expect(editor.ruleTitles == ["Extension is txt"])
            editor.save()
            #expect(Preferences.shared.findCustomScopes.map(\.name) == ["Text files"])
            nav.rebuildScopeMenu()
            #expect(nav.findScope.menu?.item(withTitle: "Text files") != nil)
            nav.setFindScope(.custom("Text files"))
            nav.find("old")
            #expect(nav.rows(3).map(\.title) == ["notes.txt  (1)"] && nav.findScope.title == "In Text files")
            nav.setFindScope(.workspace)
            nav.find("let")
            nav.setFindScope(.currentResults)
            nav.find("old")
            #expect(nav.rows(3).map(\.title) == ["main.swift  (2)", "Other.swift  (3)"])
            nav.setFindScope(.workspace)
        }
    }

    @Test func findMenuItemsAndEditorCommands() async throws {
        try await withWindow { wc, dir in
            // The workspace items are commands now, not unavailable ones.
            for t in ["Find and Replace in Workspace…", "Find Next in Workspace", "Find Previous in Workspace", "Find Selected Text in Workspace",
                      "Find Selected Words in Workspace", "Find Ancestor Types", "Find Descendent Types", "Find Conforming Types",
                      "Find and Select Next", "Find and Select Previous", "Replace and Find Previous", "Use Selection for Replace",
                      "Select Next Occurrence", "Select Previous Occurrence"] {
                #expect(CommandTable.command(titled: t)?.action.hasPrefix("ycodeUnavailable") == false, "\(t)")
            }
            let main = dir.appendingPathComponent("Sources/Demo/main.swift").path
            wc.open(path: main, line: nil)
            let e = wc.editor, tv = e.textView
            let selected = NSMenuItem(title: "", action: #selector(WorkspaceWindowController.findSelectedWordsInWorkspace(_:)), keyEquivalent: "")
            #expect(!wc.validateMenuItem(selected))
            #expect(!wc.validateMenuItem(NSMenuItem(title: "", action: #selector(WorkspaceWindowController.findAncestorTypes(_:)), keyEquivalent: "")))
            // Find Selected Text / Words in Workspace.
            tv.setSelectedRange(NSRange(location: 4, length: 3))   // "old"
            #expect(wc.validateMenuItem(selected))
            wc.findSelectedWordsInWorkspace(nil)
            #expect(wc.navigator.findMatch.titleOfSelectedItem == "Matching Word" && wc.navigator.findField.stringValue == "old")
            #expect(wc.navigator.findModel.matchCount == 4)
            wc.open(path: main, line: nil)
            tv.setSelectedRange(NSRange(location: 4, length: 3))
            wc.findSelectedTextInWorkspace(nil)
            #expect(wc.navigator.findMatch.titleOfSelectedItem == "Containing" && wc.navigator.findModel.matchCount == 6)

            // In the file: Find and Select Next adds the next match to the selection.
            let undo = try #require(tv.undoManager)
            undo.groupsByEvent = false
            e.setFind("old")
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            e.findAndSelectNext(nil)
            e.findAndSelectNext(nil)
            #expect(tv.selectedRanges.map(\.rangeValue) == [NSRange(location: 4, length: 3), NSRange(location: 18, length: 3)])
            e.findAndSelectPrevious(nil)
            #expect(tv.selectedRanges.count == 2)
            // Select Next Occurrence: the selected text's next occurrence.
            tv.setSelectedRange(NSRange(location: 4, length: 3))
            e.selectNextOccurrence(nil)
            #expect(tv.selectedRanges.map(\.rangeValue) == [NSRange(location: 4, length: 3), NSRange(location: 18, length: 3)])
            tv.setSelectedRange(NSRange(location: 1, length: 0))
            e.selectNextOccurrence(nil)
            #expect(tv.selectedRange() == NSRange(location: 0, length: 3))   // the word "let"
            // Use Selection for Replace, then Replace and Find Previous.
            tv.setSelectedRange(NSRange(location: 0, length: 3))
            e.useSelectionForReplace(nil)
            #expect(e.findBarReplacement == "let")
            e.showFindBar(replace: true)
            e.setFind("old", replacement: "neu")
            e.findStep(forward: true)   // the second "old"
            undo.beginUndoGrouping()
            e.replaceAndFindPrevious(nil)
            undo.endUndoGrouping()
            #expect(e.text == "let old = 1\nprint(neu)\n" && tv.selectedRange() == NSRange(location: 4, length: 3))
            undo.removeAllActions()
        }
    }

    /// The semantic kinds from the navigator (a stand-in for the server)
    /// and their header: Symbols lists Definitions and References.
    @Test func semanticKindsInTheNavigator() async throws {
        try await withWindow { wc, dir in
            let nav = wc.navigator
            wc.showFindNavigator()
            nav.setFindOptions(kind: .symbols)
            #expect(nav.findMatch.itemTitles == ["Definitions", "References"] && nav.findField.placeholderString == "Symbols")
            nav.findSemantic = { q in
                SemanticFind.Result(heading: "\(q.text) — 1 definition", nodes: [
                    FindResultNode(kind: .file, title: "main.swift", detail: "(1)", children: [
                        FindResultNode(kind: .symbol, title: "Thing", path: dir.appendingPathComponent("Sources/Demo/main.swift").path, line: 1, symbolKind: 23),
                    ]),
                ], count: 1)
            }
            nav.find("Thing")
            await nav.runningFind?.value
            #expect(nav.rows(3).map(\.title) == ["Thing — 1 definition"])
            #expect(nav.rows(3)[0].children.first?.children.first?.symbol == "s.square.fill")
            #expect(nav.findQuery("x").symbolRole == .definitions && nav.findQuery("x").match == .containing)
            nav.findMatch.selectItem(at: 1)
            #expect(nav.findQuery("x").symbolRole == .references && nav.findQuery("x").match == .matchingWord)
            // Replace mode is for the textual kinds.
            nav.setFindOptions(mode: .replace)
            #expect(nav.findModel.plan == nil && !nav.findReplaceField.isEnabled && !nav.findReplaceAllButton.isEnabled)
            nav.setFindOptions(mode: .find, kind: .callHierarchy)
            #expect(nav.findMatch.itemTitles == NavigatorAreaController.findMatches)
            // No server: the count line says so.
            nav.findSemantic = nil
            nav.find("x")
            await nav.runningFind?.value
            #expect(nav.findCountText == "No language server")
            nav.setFindOptions(kind: .text)
        }
    }
}
