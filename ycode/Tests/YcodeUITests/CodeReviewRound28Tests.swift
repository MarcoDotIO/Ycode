import AppKit
import Foundation
import Testing
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// reference-ui-4.md §15: controls in the debug bar, either source re-runs
/// the comparison, the working copy is editable side by side, insertion
/// markers; the commit sheet shows git's own diff.
@MainActor
@Suite(.serialized) struct CodeReviewRound28Tests {
    private func repo(_ name: String) throws -> (URL, URL) {
        let dir = ycodeDir.appendingPathComponent(".build-ide/\(name)")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"App\", targets: [.executableTarget(name: \"App\")])\n"
            .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let main = dir.appendingPathComponent("Sources/App/main.swift")
        func git(_ a: String...) throws { _ = try GitRepository.run("/usr/bin/git", ["-C", dir.path, "-c", "user.name=T", "-c", "user.email=t@ycode.invalid", "-c", "commit.gpgsign=false"] + a) }
        try git("init", "-q", "-b", "main")
        try "let a = 1\n".write(to: main, atomically: true, encoding: .utf8)
        try git("add", "-A"); try git("commit", "-q", "-m", "one")
        try "let a = 1\nlet b = 2\n".write(to: main, atomically: true, encoding: .utf8)
        try git("commit", "-qam", "two")
        try "let a = 10\nlet b = 2\nlet c = 3\n".write(to: main, atomically: true, encoding: .utf8)
        return (dir, main)
    }

    @Test func columnTextRoundTrip() {
        let col = "   1  let a = 1\n      \n   2  let b = 2\nnew line\n"
        #expect(ComparisonView.fileText(fromColumn: col) == "let a = 1\nlet b = 2\nnew line\n")
    }

    @Test func controlsLiveInTheDebugBarAndSourcesRerun() throws {
        _ = NSApplication.shared
        let (dir, main) = try repo("cr28-a")
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: dir)),
                                           loadDestinations: false, startLanguageService: false)
        wc.applyDefaultLayout()
        wc.open(path: main.path, line: nil)
        wc.editor.comparisonStyle = .inline
        #expect(wc.toggleComparison(nil))
        #expect(wc.debugArea.reviewSlot.arrangedSubviews.first === wc.editor.reviewBar)
        #expect(wc.editor.reviewBar.count.stringValue.contains("change"))

        // Choosing a left-hand source (a commit) re-runs as two stored versions.
        let picker = try #require(wc.reviewSourcePicker(left: true))
        _ = picker.view
        let firstCommit = try #require(wc.repository?.recentCommits(limit: 5, path: main.path).last)
        picker.onChoose?(.commit(hash: firstCommit.hash, title: firstCommit.shortHash))
        #expect(wc.editor.isShowingComparison)
        #expect(wc.editor.comparison.leftView.string.contains("let a = 1"))
        #expect(!wc.editor.comparison.leftView.string.contains("let c = 3"))
        #expect(!wc.editor.comparison.leftView.isEditable)

        #expect(!wc.toggleComparison(nil))
        #expect(wc.debugArea.reviewSlot.arrangedSubviews.isEmpty)
    }

    @Test func sideBySideWorkingCopyIsEditableWithInsertionMarkers() throws {
        _ = NSApplication.shared
        let (dir, main) = try repo("cr28-b")
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: dir)),
                                           loadDestinations: false, startLanguageService: false)
        wc.applyDefaultLayout()
        wc.open(path: main.path, line: nil)
        wc.editor.comparisonStyle = .sideBySide
        #expect(wc.toggleComparison(nil))
        let c = wc.editor.comparison
        #expect(c.workingView.isEditable)
        // "let c = 3" exists only in the working copy: marker on the source side.
        c.layoutSubtreeIfNeeded()
        #expect(c.insertionMarkers.contains { !$0.leftSide && $0.kind == .added })

        // Typing in the working column updates the file's text and re-diffs.
        let tv = c.workingView
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        tv.insertText("let d = 4", replacementRange: tv.selectedRange())
        #expect(wc.editor.textView.string.contains("let d = 4"))
        #expect(c.rows.contains { $0.right?.text == "let d = 4" || $0.left?.text == "let d = 4" })
    }

    @Test func commitSheetUsesGitDiff() throws {
        let (dir, main) = try repo("cr28-c")
        let r = try #require(GitRepository(containing: dir))
        #expect(r.diff(of: main.path) == r.diff(of: main.path, scope: .all))
        #expect(r.diff(of: main.path).hasPrefix("@@"))
    }
}
