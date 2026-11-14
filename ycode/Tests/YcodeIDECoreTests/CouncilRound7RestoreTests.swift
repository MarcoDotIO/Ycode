import Foundation
import Testing
@testable import YcodeIDECore

/// Council round 7, group D, rows 186–187 (`workspace-window.md` W7.1,
/// `navigators.md` round 7 §4): the editors and inspector kept in the
/// per-workspace user data, and the navigator's expansion on reopen.
@Suite struct CouncilRound7RestoreTests {
    /// The council's tree: the project row (the main group), the
    /// GlassScroll folder with Models in it, the Plain group with Sub in it.
    static func councilTree() -> NavigatorNode {
        NavigatorNode(name: "GlassScroll", kind: .container, path: "/tmp/r7/GlassScroll.xcodeproj", children: [
            NavigatorNode(name: "GlassScroll", kind: .folder, path: "/tmp/r7/GlassScroll", children: [
                NavigatorNode(name: "Models", kind: .folder, path: "/tmp/r7/GlassScroll/Models", children: [
                    NavigatorNode(name: "Model01.swift", kind: .file, path: "/tmp/r7/GlassScroll/Models/Model01.swift"),
                ]),
            ]),
            NavigatorNode(name: "Plain", kind: .group, path: "/tmp/r7/Plain", objectID: "PLAIN", children: [
                NavigatorNode(name: "Sub", kind: .group, path: "/tmp/r7/Plain/Sub", objectID: "SUB", children: [
                    NavigatorNode(name: "Inner.swift", kind: .file, path: "/tmp/r7/Plain/Sub/Inner.swift"),
                ]),
            ]),
        ])
    }

    @Test func reopenKeepsTheMainGroupsChildrenAndClosesDeeperRows() {
        let root = Self.councilTree()
        // X15: GlassScroll and its folder, Plain and Sub expanded; Models not.
        let saved = ["/tmp/r7/GlassScroll.xcodeproj", "/tmp/r7/GlassScroll", "PLAIN", "SUB", "other-section"]
        // R01: Sub opens collapsed; the rest as saved; unknown keys kept.
        #expect(NavigatorTree.reopenedExpansion(saved, root: root) == ["/tmp/r7/GlassScroll.xcodeproj", "/tmp/r7/GlassScroll", "PLAIN", "other-section"])
        // Models (two levels down) stays closed when it was saved open.
        #expect(!NavigatorTree.reopenedExpansion(saved + ["/tmp/r7/GlassScroll/Models"], root: root).contains("/tmp/r7/GlassScroll/Models"))
        // The first-open default is untouched by the rule.
        let first = NavigatorTree.initiallyExpanded(root)
        #expect(NavigatorTree.reopenedExpansion(first, root: root) == first)
    }

    @Test func layoutRoundTripsThroughTheUserData() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-r7-restore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("ycode-ui-state.json")
        // An older file without the new keys still loads, keeping its values.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"recentFiles":["/a"],"destinations":{},"expandedRows":["x"]}"#.write(to: url, atomically: true, encoding: .utf8)
        var state = WorkspaceUserState.load(from: url)
        #expect(state.recentFiles == ["/a"] && state.editorLayout == nil && state.inspector == nil)
        let layout = WorkspaceEditorLayout(panes: [.init(path: "/p/Long.swift", topLine: 30, selectionStart: 12, selectionLength: 3),
                                                   .init(path: "/p/Model01.swift")],
                                           sideBySide: true, fractions: [0.5, 0.5], focused: 1)
        state.editorLayout = layout
        state.inspector = WorkspaceInspectorState(isShown: true, tab: 0)
        state.save(to: url)
        let back = WorkspaceUserState.load(from: url)
        #expect(back.editorLayout == layout && back.inspector == WorkspaceInspectorState(isShown: true, tab: 0))
        #expect(back.recentFiles == ["/a"] && back.expandedRows == ["x"])
    }

    @Test func restorableDropsMissingFilesAndRepairsTheShares() {
        let layout = WorkspaceEditorLayout(panes: [.init(path: "/here", topLine: 0), .init(path: "/gone", topLine: 9)],
                                           sideBySide: false, fractions: [3, 1, 4], focused: 7)
        let r = layout.restorable { $0 == "/here" }
        #expect(r.panes == [.init(path: "/here", topLine: 1), .init(path: nil)])
        #expect(r.fractions == [0.5, 0.5] && r.focused == 1 && !r.sideBySide)
        #expect(WorkspaceEditorLayout(panes: [], fractions: []).restorable().panes == [.init(path: nil)])
        // Unequal shares sum to 1.
        let u = WorkspaceEditorLayout(panes: [.init(path: nil), .init(path: nil)], fractions: [600, 200]).restorable()
        #expect(u.fractions == [0.75, 0.25])
        // A selection beyond a shorter file is clamped.
        #expect(WorkspaceEditorLayout.Pane(path: "/x", selectionStart: 50, selectionLength: 10).selection(clampedTo: 52) == NSRange(location: 50, length: 2))
    }

    @Test func dividerPositionsFollowTheShares() {
        let two = WorkspaceEditorLayout(panes: [.init(path: nil), .init(path: nil)], fractions: [0.5, 0.5])
        #expect(two.dividerPositions(total: 901, divider: 1) == [450])
        let three = WorkspaceEditorLayout(panes: [.init(path: nil), .init(path: nil), .init(path: nil)], fractions: [0.25, 0.25, 0.5])
        #expect(three.dividerPositions(total: 802, divider: 1) == [200, 401])
        #expect(WorkspaceEditorLayout.fractions(sizes: [450, 450]) == [0.5, 0.5])
        #expect(WorkspaceEditorLayout.fractions(sizes: [0, 0]) == [0.5, 0.5])
        #expect(WorkspaceInspectorState(isShown: true, tab: 9).tab(clampedTo: 3) == 2)
    }
}
