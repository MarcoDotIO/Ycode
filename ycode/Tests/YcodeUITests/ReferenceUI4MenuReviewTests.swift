import AppKit
import Foundation
import Testing
import YcodeLanguage
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func titles(_ items: [MenuItemSpec]) -> [String] {
    items.map { item in
        switch item {
        case .command(let c): c.title
        case .separator: "|"
        case .submenu(let t, _): t + " ▸"
        case .label(let t): "[" + t + "]"
        }
    }
}

/// reference-ui-4.md §8 (Editor menu, Refactor) and §15 (Code Review).
@Suite struct ReferenceUI4MenuTests {
    @Test func editorMenuOrder() throws {
        let editor = try #require(CommandTable.menus.first { $0.0 == "Editor" }?.1)
        let t = titles(editor)
        let expected = ["Show Editor Only", "|", "Canvas", "Assistant", "Code Review", "Layout ▸", "|",
                        "Show Completions", "Show Predictive Completion", "Show Coding Tools ▸", "Edit All in Scope", "Show Callers…",
                        "Expand Macro", "Hide All Macro Expansions", "Refactor ▸", "|",
                        // reference-ui-5.md §2.7 supersedes §8.1: "Show / Hide All Issues", Show Markdown
                        // in its own section, "Choose Theme..." as the reference spells it.
                        "Fix All Issues", "Show Issues", "Show All Issues", "|", "Show Markdown", "|",
                        "Selection ▸", "Structure ▸", "Code Folding ▸", "Syntax Coloring ▸", "Font Size ▸", "Choose Theme...", "|",
                        "Inline Comparison", "Side By Side Comparison", "|", "Minimap", "Authors", "Code Coverage", "|",
                        "Vim Mode", "Relative Line Numbers"]
        #expect(Array(t.prefix(expected.count)) == expected)
        let i = try #require(t.firstIndex(of: "Invisibles"))
        // §2.7: the menu ends here (Line Numbers moved to Settings, Add New Constraints… to Interface Builder's menu).
        #expect(Array(t[i...]) == ["Invisibles", "Scope Guides", "Wrap Lines", "|", "Show Last Change for Line", "Create Code Snippet…"])
        let shortcuts = Dictionary(uniqueKeysWithValues: editor.compactMap { item -> (String, String)? in
            if case .command(let c) = item, !c.key.isEmpty { return (c.title, c.shortcutText) } else { return nil }
        })
        #expect(shortcuts["Show Editor Only"] == "⌘↩")
        #expect(shortcuts["Canvas"] == "⌥⌘↩" && shortcuts["Assistant"] == "⌃⌥⌘↩" && shortcuts["Code Review"] == "⌥⇧⌘↩")
        #expect(shortcuts["Show Completions"] == "⌃Space")
        #expect(shortcuts["Fix All Issues"] == "⌃⌥⌘F" && shortcuts["Show Issues"] == "⌃⌥⌘L" && shortcuts["Show All Issues"] == "⌃⌘L")
        #expect(shortcuts["Minimap"] == "⌃⇧⌘M" && shortcuts["Authors"] == "⌃⇧⌘A" && shortcuts["Wrap Lines"] == "⌃⇧⌘L")
        #expect(EditorMenu.checkedByDefault == ["Inline Comparison", "Minimap", "Wrap Lines"])
    }

    @Test func refactorSubmenuOrder() throws {
        let editor = try #require(CommandTable.menus.first { $0.0 == "Editor" }?.1)
        guard case .submenu(_, let sub)? = editor.first(where: { if case .submenu("Refactor", _) = $0 { true } else { false } }) else {
            Issue.record("no Refactor"); return
        }
        #expect(titles(sub) == ["Rename…", "|",
                                "Extract to File", "Extract Selection to File", "Extract to Function", "Extract to Method", "Extract to Variable", "Extract All Occurrences", "|",
                                "Add Missing Abstract Class Overrides", "Add Missing Protocol Requirements", "Add Missing Switch Cases", "Convert to Switch",
                                "Convert to Regex Builder", "Expand Default", "Generate Memberwise Initializer", "Generate Missing Function Definitions",
                                "Wrap in NSLocalizedString", "|",
                                "Convert Function to Async", "Change Localized String Key", "Convert Localized String to Symbol", "Convert to Localized String Literal"])
    }

    @Test func refactorItemsMapToCodeActions() {
        let actions = [
            CodeAction(title: "Extract Method", kind: "refactor.extract"),
            CodeAction(title: "Generate Memberwise Initializer", kind: "refactor"),
            CodeAction(title: "Convert Function to Async", kind: "refactor.rewrite"),
            CodeAction(title: "Add stubs for conformance", kind: "quickfix"),
            CodeAction(title: "Convert string literal to interpolation", kind: "refactor.rewrite"),
        ]
        let titles = RefactorCatalog.items.map(\.title)
        func idx(_ t: String) -> Int { titles.firstIndex(of: t)! }
        #expect(RefactorCatalog.actionIndex(forItem: idx("Extract to Method"), in: actions) == 0)
        #expect(RefactorCatalog.actionIndex(forItem: idx("Extract to Function"), in: actions) == 0)
        #expect(RefactorCatalog.actionIndex(forItem: idx("Generate Memberwise Initializer"), in: actions) == 1)
        #expect(RefactorCatalog.actionIndex(forItem: idx("Convert Function to Async"), in: actions) == 2)
        #expect(RefactorCatalog.actionIndex(forItem: idx("Extract to Variable"), in: actions) == nil)
        #expect(RefactorCatalog.actionIndex(forItem: idx("Extract Selection to File"), in: actions) == nil)
        #expect(RefactorCatalog.actionIndex(forItem: 999, in: actions) == nil)
        #expect(RefactorCatalog.unmatched(actions) == [4])
    }

    @Test func reviewChangesAndStepper() {
        let rows = LineDiff.sideBySide(LineDiff.diff(["a", "b", "c", "d"], ["a", "B", "c", "d", "e"]))
        let ch = CodeReviewModel.changes(rows)
        #expect(ch.count == 2)
        #expect(ch[0].kind == .changed && ch[0].newStart == 2 && ch[0].newCount == 1)
        #expect(ch[1].kind == .added && ch[1].newStart == 5)
        #expect(CodeReviewModel.lineMarks(ch) == [2: .changed, 5: .added])
        let del = CodeReviewModel.changes(LineDiff.sideBySide(LineDiff.diff(["a", "b", "c"], ["a", "c"])))
        #expect(del == [ReviewChange(kind: .removed, newStart: 2, newCount: 0, oldStart: 2, oldCount: 1)])
        #expect(CodeReviewModel.lineMarks(del) == [2: .removed])
        #expect(CodeReviewModel.stepperTitle(1) == "1 change" && CodeReviewModel.stepperTitle(3) == "3 changes")
        #expect(CodeReviewModel.step(from: nil, count: 3, forward: true) == 0)
        #expect(CodeReviewModel.step(from: 0, count: 3, forward: false) == 2)
        #expect(CodeReviewModel.step(from: 2, count: 3, forward: true) == 0)
        #expect(CodeReviewModel.step(from: nil, count: 0, forward: true) == nil)
    }

    @Test func pickerColumns() {
        let cols = CodeReviewModel.pickerColumns(
            branches: [.init(name: "main", isCurrent: true), .init(name: "dev", isCurrent: false)], recents: ["dev"],
            commits: [.init(hash: "abc", shortHash: "abc1", author: "T", date: "2026-10-19", subject: "Init")])
        #expect(cols.branches == ["Recents", "dev", "main (current)", "dev"])
        #expect(cols.commits == ["Uncommitted Changes", "Unstaged Changes", "Staged Changes", "T · 2026-10-19 · abc1 · Init"])
    }
}

@MainActor
@Suite(.serialized) struct ReferenceUI4ReviewTests {
    func repo() throws -> (URL, URL) {
        let dir = ycodeDir.appendingPathComponent(".build-ide/review-repo")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"App\", targets: [.executableTarget(name: \"App\")])\n"
            .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let main = dir.appendingPathComponent("Sources/App/main.swift")
        try "let a = 1\nlet b = 2\nlet c = 3\n".write(to: main, atomically: true, encoding: .utf8)
        func git(_ a: String...) throws { _ = try GitRepository.run("/usr/bin/git", ["-C", dir.path] + a) }
        try git("init", "-q", "-b", "main")
        try git("add", "-A")
        try git("-c", "user.name=T", "-c", "user.email=t@ycode.invalid", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "First")
        try git("branch", "feature")
        return (dir, main)
    }

    @Test func inlineReviewStepperSwapAndPicker() throws {
        _ = NSApplication.shared
        let (dir, main) = try repo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: dir)),
                                           loadDestinations: false, startLanguageService: false)
        wc.applyDefaultLayout()
        wc.open(path: main.path, line: nil)
        wc.editor.textView.string = "let a = 1\nlet b = 20\nlet c = 3\nlet d = 4\n"
        #expect(wc.editor.comparisonStyle == .inline)
        #expect(wc.toggleComparison(nil))
        #expect(wc.editor.isShowingInlineComparison && !wc.editor.isShowingComparison)
        #expect(wc.editor.textView.isEditable)
        #expect(wc.editor.reviewChanges.count == 2)
        #expect(wc.editor.gutter.marks.changes == [2: .changed, 4: .added])
        #expect(wc.editor.reviewBar.count.stringValue == "2 changes")
        #expect(wc.editor.reviewBar.leftSource.title == "Uncommitted Changes" && wc.editor.reviewBar.rightSource.title == "Last Commit")
        #expect(wc.editor.stepReviewChange(forward: true) == 0)
        #expect(wc.editor.currentLine == 2)
        #expect(wc.editor.stepReviewChange(forward: true) == 1)
        // Editing updates the marks.
        wc.editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        wc.editor.textView.insertText("// top\n", replacementRange: NSRange(location: 0, length: 0))
        #expect(wc.editor.gutter.marks.changes[1] == .added)
        // Swap.
        wc.editor.reviewBar.swap.performClick(nil)
        #expect(wc.editor.reviewBar.leftSource.title == "Last Commit")
        wc.editor.reviewBar.swap.performClick(nil)

        // Source picker: branches with "(current)", commits with fixed rows.
        let picker = try #require(wc.reviewSourcePicker(left: false))
        _ = picker.view
        #expect(picker.shownBranches.contains("main (current)") && picker.shownBranches.contains("feature"))
        #expect(Array(picker.shownCommits.prefix(3)) == ["Uncommitted Changes", "Unstaged Changes", "Staged Changes"])
        #expect(picker.shownCommits.last?.hasSuffix("First") == true)
        picker.commitSearch.stringValue = "First"
        picker.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(picker.shownCommits.count == 1)
        let chosen = picker.choose(table: 1, row: 0)
        if case .commit? = chosen {} else { Issue.record("expected a commit source") }
        #expect(wc.editor.reviewBar.rightSource.title.hasSuffix("First"))
        #expect(wc.editor.isShowingInlineComparison)

        // Side by side: working copy left, ribbons between.
        wc.showSideBySideComparison(nil)
        #expect(wc.editor.isShowingComparison && !wc.editor.isShowingInlineComparison)
        #expect(wc.editor.comparison.leftView.string.contains("let b = 20"))
        #expect(!wc.editor.comparison.ribbonChanges.isEmpty)
        #expect(!wc.toggleComparison(nil))
        #expect(wc.editor.reviewBar.superview == nil)
    }

    @Test func editorMenuValidation() throws {
        _ = NSApplication.shared
        let (dir, main) = try repo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: dir)),
                                           loadDestinations: false, startLanguageService: false)
        wc.applyDefaultLayout()
        wc.open(path: main.path, line: nil)
        func item(_ sel: String, tag: Int = 0) -> NSMenuItem {
            let i = NSMenuItem(title: "", action: Selector(sel), keyEquivalent: "")
            i.tag = tag
            return i
        }
        let inline = item("showInlineComparison:")
        #expect(wc.validateMenuItem(inline) && inline.state == .on)
        let side = item("showSideBySideComparison:")
        _ = wc.validateMenuItem(side)
        #expect(side.state == .off)
        #expect(!wc.validateMenuItem(item("showInlineIssues:")))
        wc.hideInlineIssues(nil)
        #expect(wc.validateMenuItem(item("showInlineIssues:")) && !wc.editor.showsInlineIssues)
        // Refactor items follow the code actions at the cursor.
        let titles = RefactorCatalog.items.map(\.title)
        let memberwise = titles.firstIndex(of: "Generate Memberwise Initializer")!
        #expect(!wc.validateMenuItem(item("performRefactorItem:", tag: memberwise)))
        wc.cachedCodeActions = [CodeAction(title: "Generate Memberwise Initializer", kind: "refactor")]
        #expect(wc.validateMenuItem(item("performRefactorItem:", tag: memberwise)))
        #expect(!wc.validateMenuItem(item("performRefactorItem:", tag: titles.firstIndex(of: "Expand Default")!)))
    }
}
