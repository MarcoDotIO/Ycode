import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Depth checks for specs/ide/comparison.md.
@MainActor
@Suite(.serialized) struct ComparisonDepthTests {
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
