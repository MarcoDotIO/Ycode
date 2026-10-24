import AppKit
import Foundation
import Testing
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@Suite struct LineDiffTests {
    @Test func diffAndLayout() {
        let old = ["a", "b", "c", "d"], new = ["a", "B", "c", "d", "e"]
        let ops = LineDiff.diff(old, new)
        #expect(ops == [.same("a"), .removed("b"), .added("B"), .same("c"), .same("d"), .added("e")])
        let rows = LineDiff.sideBySide(ops)
        #expect(rows.map(\.kind) == [.same, .changed, .same, .same, .added])
        #expect(rows[1].left?.number == 2 && rows[1].right?.text == "B")
        #expect(rows[4].left == nil && rows[4].right?.number == 5)
        #expect(LineDiff.unified(ops, context: 0) == "-b\n+B\n…\n+e")
        #expect(LineDiff.unified(LineDiff.diff(old, old)).isEmpty)
        #expect(LineDiff.diff([], ["x"]) == [.added("x")])
        #expect(LineDiff.lines("a\nb\n") == ["a", "b"])
    }
}

@MainActor
@Suite(.serialized) struct ComparisonTests {
    @Test func codeReviewAndCommitDiff() async throws {
        _ = NSApplication.shared
        let dir = ycodeDir.appendingPathComponent(".build-ide/cmp-repo")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"App\", targets: [.executableTarget(name: \"App\")])\n"
            .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let main = dir.appendingPathComponent("Sources/App/main.swift")
        try "let a = 1\nlet b = 2\nprint(a + b)\n".write(to: main, atomically: true, encoding: .utf8)
        func git(_ args: String...) throws {
            _ = try GitRepository.run("/usr/bin/git", ["-C", dir.path, "-c", "user.name=Ycode Test", "-c", "user.email=test@ycode.invalid",
                                                       "-c", "commit.gpgsign=false"] + args)
        }
        try git("init", "-q", "-b", "main")
        try git("add", "-A")
        try git("commit", "-q", "-m", "Initial")
        try "let a = 1\nlet b = 20\nprint(a + b)\nprint(\"done\")\n".write(to: main, atomically: true, encoding: .utf8)

        let session = WorkspaceSession(model: try WorkspaceModel(url: dir))
        let wc = WorkspaceWindowController(session: session, loadDestinations: false, startLanguageService: false)
        wc.window?.appearance = NSAppearance(named: .aqua)
        wc.applyDefaultLayout()
        wc.open(path: main.path, line: nil)
        let repo = try #require(wc.repository)
        #expect(repo.headContents(of: main.path) == "let a = 1\nlet b = 2\nprint(a + b)\n")

        wc.editor.comparisonStyle = .sideBySide
        #expect(wc.toggleComparison(nil) && wc.editor.isShowingComparison)
        #expect(wc.editor.comparison.rows.map(\.kind) == [.same, .changed, .same, .added])
        #expect(wc.editor.comparison.rightView.string.contains("let b = 2") && wc.editor.comparison.leftView.string.contains("let b = 20"))
        _ = try WindowSnapshotTests().render(wc.window!.contentView!.superview!, to: "comparison-editor.png")
        #expect(!wc.toggleComparison(nil) && !wc.editor.isShowingComparison)

        let sheet = try #require(await wc.presentCommitSheet())
        _ = sheet.view
        await sheet.diffIdle()   // git diff runs in the background
        #expect(sheet.diffView.string.contains("-let b = 2\n+let b = 20"))
        #expect(sheet.diffView.string.contains("+print(\"done\")"))
        let w = NSWindow(contentRect: sheet.view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .aqua)
        w.contentView = sheet.view
        _ = try WindowSnapshotTests().render(sheet.view, to: "commit-sheet-diff.png")
    }
}
