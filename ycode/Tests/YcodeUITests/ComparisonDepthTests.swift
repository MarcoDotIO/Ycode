import AppKit
import Foundation
import Testing
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Depth checks for specs/ide/comparison.md.
@MainActor
@Suite(.serialized) struct ComparisonDepthTests {
    @Test func diffRules() {
        // Removals before additions; pure removal leaves a filler on the right.
        #expect(LineDiff.diff(["a", "b"], ["c"]) == [.removed("a"), .removed("b"), .added("c")])
        let rows = LineDiff.sideBySide(LineDiff.diff(["a", "b"], ["c"]))
        #expect(rows.map(\.kind) == [.changed, .removed])
        #expect(rows[1].right == nil && rows[1].left?.number == 2)
        #expect(LineDiff.sideBySide(LineDiff.diff(["x", "y"], ["x"])).map(\.kind) == [.same, .removed])
        // Three lines of context; separated hunks get "…".
        let old = (1...12).map { "l\($0)" }
        var new = old
        new[0] = "L1"; new[11] = "L12"
        let u = LineDiff.unified(LineDiff.diff(old, new))
        #expect(u == "-l1\n+L1\n l2\n l3\n l4\n…\n l9\n l10\n l11\n-l12\n+L12")
    }

    @Test func codeReviewEditorBehaviour() throws {
        _ = NSApplication.shared
        let dir = ycodeDir.appendingPathComponent(".build-ide/cmp-depth-repo")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"App\", targets: [.executableTarget(name: \"App\")])\n"
            .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let main = dir.appendingPathComponent("Sources/App/main.swift")
        try "let a = 1\n".write(to: main, atomically: true, encoding: .utf8)
        _ = try GitRepository.run("/usr/bin/git", ["-C", dir.path, "init", "-q", "-b", "main"])
        _ = try GitRepository.run("/usr/bin/git", ["-C", dir.path, "add", "-A"])
        _ = try GitRepository.run("/usr/bin/git", ["-C", dir.path, "-c", "user.name=T", "-c", "user.email=t@ycode.invalid",
                                                   "-c", "commit.gpgsign=false", "commit", "-q", "-m", "i"])
        let fresh = dir.appendingPathComponent("Sources/App/Fresh.swift")
        try "let f = 1\nlet g = 2\n".write(to: fresh, atomically: true, encoding: .utf8)

        let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: dir)),
                                           loadDestinations: false, startLanguageService: false)
        wc.applyDefaultLayout()
        wc.open(path: main.path, line: nil)
        // Unsaved edits are included on the right.
        wc.editor.textView.string = "let a = 1\nlet b = 2\n"
        wc.editor.comparisonStyle = .sideBySide
        #expect(wc.toggleComparison(nil))
        let c = wc.editor.comparison
        #expect(c.rightTitle.stringValue == "main.swift (HEAD)" && c.leftTitle.stringValue == "main.swift (Local)")
        #expect(c.rows.map(\.kind) == [.same, .added])
        #expect(c.leftView.string.contains("let b = 2"))
        // reference-ui-4 §15.3: the working copy (left) is editable.
        #expect(c.leftView.isEditable && !c.rightView.isEditable)
        // Each side numbers its own lines; the filler row has none.
        #expect(c.rightView.string.components(separatedBy: "\n")[1].trimmingCharacters(in: .whitespaces).isEmpty)
        #expect(c.leftView.string.contains("   2  let b = 2"))

        // Opening another file returns to the normal editor.
        wc.open(path: fresh.path, line: nil)
        #expect(!wc.editor.isShowingComparison)
        // A new file compares against an empty HEAD side.
        #expect(wc.toggleComparison(nil))
        #expect(wc.editor.comparison.rows.map(\.kind) == [.added, .added])
        #expect(wc.editor.comparison.rightTitle.stringValue == "Fresh.swift (HEAD)")
        #expect(!wc.toggleComparison(nil))
    }
}
