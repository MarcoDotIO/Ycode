import Foundation
import Testing
import YcodeLanguage
@testable import YcodeIDECore

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
