import Foundation
import Testing
@testable import YcodeIDECore

/// The conflict editor's shared state (`ConflictEditorState`), which the
/// AppKit and Linux conflict editors both draw (`specs/ide/comparison.md`,
/// "Conflict editor").
struct ConflictEditorStateTests {
    /// Two conflicts with a one-sided change between them.
    func twoConflicts() -> MergeDocument {
        MergeDocument(base: "a\nb\nc\nd\ne\nf\ng\nh\n", ours: "a\nB1\nc\nd\ne\nf\nG1\nh\n", theirs: "a\nB2\nc\nd\nE2\nf\nG2\nh\n",
                      oursLabel: "main", theirsLabel: "feature")
    }

    @Test func loadSelectsTheFirstUndecidedHunk() {
        var s = ConflictEditorState()
        s.files = ["/r/A.swift"]
        s.currentFile = "/r/A.swift"
        s.load(twoConflicts())
        let doc = s.document ?? MergeDocument(chunks: [])
        #expect(doc.chunks.map(\.kind) == [.unchanged, .conflict, .unchanged, .theirsOnly, .unchanged, .conflict, .unchanged])
        #expect(s.currentHunk == 0 && s.hunkLabel == "Change 1 of 3 (conflict)" && s.currentIsConflict)
        #expect(s.title == "Conflicts in A.swift" && s.fileNames == ["A.swift"])
        #expect(s.statusText == "2 conflicts unresolved" && !s.canMarkResolved && s.selectedSegment == nil)
        #expect(s.resultLines.filter { $0.tint == .unresolved }.count == 10)
        #expect(s.resultLines.first { $0.tint == .unresolved }?.isSelected == true)
        #expect(s.resultStartLine == 1)
    }

    @Test func choicesMoveOnToTheNextUndecidedConflict() {
        var s = ConflictEditorState()
        s.currentFile = "/r/A.swift"
        s.load(twoConflicts())
        s.chooseSegment(0)               // Left
        #expect(s.currentHunk == 2 && s.hunkLabel == "Change 3 of 3 (conflict)" && s.statusText == "1 conflict unresolved")
        s.chooseSegment(1)               // Right; nothing undecided is left
        #expect(s.currentHunk == 2 && s.selectedSegment == 1 && s.statusText == "Resolved" && s.canMarkResolved)
        #expect(s.document?.result == "a\nB1\nc\nd\nE2\nf\nG2\nh\n")
        s.previousHunk()
        #expect(s.currentHunk == 1 && s.hunkLabel == "Change 2 of 3" && s.selectedSegment == 1)
        s.nextHunk()
        s.nextHunk()
        #expect(s.currentHunk == 0)      // wraps
        s.chooseSegment(2)               // Left + Right
        #expect(s.document?.result == "a\nB1\nB2\nc\nd\nE2\nf\nG2\nh\n")
        s.choose(.unresolved)
        #expect(s.statusText == "1 conflict unresolved" && !s.canMarkResolved && s.currentHunk == 0)
    }

    @Test func handEditing() {
        var s = ConflictEditorState()
        s.currentFile = "/r/A.swift"
        s.load(twoConflicts())
        s.chooseSegment(ConflictEditorState.editSegment)
        #expect(s.isEditing && s.selectedSegment == 5 && s.editedText == "B1\nB2\n")
        s.setEditedText("hand\nwritten")
        #expect(s.isEditing && s.currentHunk == 0 && s.document?.result.hasPrefix("a\nhand\nwritten\nc\n") == true)
        #expect(s.editedText == "hand\nwritten\n")
        // Another hunk leaves the editor; coming back opens it again.
        s.nextHunk()
        #expect(!s.isEditing && s.editedText == "")
        s.previousHunk()
        #expect(s.isEditing && s.editedText == "hand\nwritten\n")
        // A side's choice ends hand editing and moves on to the undecided one.
        s.chooseSegment(1)
        #expect(!s.isEditing && s.currentHunk == 2 && s.selectedSegment == nil)
        // Edit on a decided hunk starts from its lines.
        s.selectHunk(0)
        s.beginEditing()
        #expect(s.editedText == "B2\n")
        // Not editing: typing is ignored.
        s.chooseSegment(0)
        s.setEditedText("ignored")
        #expect(s.document?.result.contains("ignored") == false)
    }

    @Test func pairsAndComparisonRows() {
        var s = ConflictEditorState()
        s.load(twoConflicts())
        #expect(s.comparison.oldTitle == "Left: main" && s.comparison.newTitle == "Right: feature")
        #expect(s.comparisonRows.contains { $0.kind == .changed })
        s.setPair(.baseLeft)
        #expect(s.comparison.oldTitle == "Base: Base" && s.comparison.new == "a\nB1\nc\nd\ne\nf\nG1\nh\n")
        s.setPair(.baseRight)
        #expect(s.comparison.new == "a\nB2\nc\nd\nE2\nf\nG2\nh\n")
        #expect(s.comparisonRow(in: s.comparisonRows) == 1)
        // Two files without an ancestor: always left and right, no Base.
        var two = ConflictEditorState(source: .files(hasAncestor: false))
        two.load(MergeDocument(chunks: ThreeWayMerge.compare(left: ["x", "y"], right: ["x", "Y"])))
        two.setPair(.baseRight)
        #expect(two.pair == .leftRight && !two.hasBase && !two.isSegmentEnabled(4) && two.isSegmentEnabled(1))
        #expect(two.hunkLabel == "Difference 1 of 1" && !two.canMarkResolved && !two.showsIntegrationButtons)
    }

    @Test func integrationButtonsAndSnapshots() {
        var s = ConflictEditorState()
        #expect(s.statusText == "All conflicts resolved" && s.title == "No Conflicts" && !s.showsIntegrationButtons)
        #expect(s.update(integration: .merging(branch: "feature"), conflicted: ["/r/A.swift", "/r/B.swift"]) == .keep)
        s.currentFile = "/r/A.swift"
        #expect(s.showsIntegrationButtons && !s.canContinue && s.continueTitle == "Continue Merge" && s.abortTitle == "Abort Merge")
        // A.swift was resolved elsewhere: show B.swift.
        #expect(s.update(integration: .merging(branch: "feature"), conflicted: ["/r/B.swift"]) == .show("/r/B.swift"))
        s.currentFile = "/r/B.swift"
        #expect(s.update(integration: .merging(branch: "feature"), conflicted: ["/r/B.swift"]) == .keep)
        #expect(s.update(integration: .merging(branch: "feature"), conflicted: []) == .show(nil))
        #expect(s.canContinue)
        _ = s.update(integration: .rebasing(branch: "topic", onto: "1a2b3c4", step: 1, total: 2), conflicted: [])
        #expect(s.continueTitle == "Continue Rebase" && s.abortTitle == "Abort Rebase")
        _ = s.update(integration: .cherryPicking(commit: "abcdef0"), conflicted: [])
        #expect(s.continueTitle == "Continue Cherry-Pick")
        #expect(ConflictEditorState.target(wanted: "/r/B.swift", in: ["/r/A.swift", "/r/B.swift"]) == "/r/B.swift")
        #expect(ConflictEditorState.target(wanted: "/r/C.swift", in: ["/r/A.swift"]) == "/r/A.swift")
        s.lastError = "The file still has conflict markers."
        #expect(s.statusText == "The file still has conflict markers.")
    }
}
