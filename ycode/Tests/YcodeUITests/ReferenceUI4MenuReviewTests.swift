import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
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
