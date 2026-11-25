import AppKit
import Foundation
import Testing
import YcodeBuild
@testable import YcodeIDECore
import YcodeProject
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// P-120 (`specs/ide/issues.md`): an unbuilt project whose settings differ
/// from the recommended set shows the live warning in the toolbar capsule,
/// the Issue navigator and every jump bar's stepper; its row opens the
/// project editor and the checklist sheet; Perform Changes writes only the
/// checked settings; Cancel writes nothing. Offscreen (`CYcodeTestOffscreen`).
@MainActor
@Suite(.serialized) struct RecommendedSettingsUITests {
    func scratch(_ name: String) -> URL {
        ycodeDir.appendingPathComponent(".build-ide/b5-issues/\(name)-\(UUID().uuidString)")
    }

    /// The command-line tool project, rewritten once by Ycode's writer so
    /// the file is in the writer's own layout (a later write changes only
    /// what was edited).
    func toolProject(_ dir: URL) throws -> (project: URL, file: URL) {
        let project = try writeToolProject(at: dir)
        let file = project.appendingPathComponent("project.pbxproj")
        try PBXProj(contentsOf: project).serialized(projectName: "Tool").write(to: file, atomically: true, encoding: .utf8)
        return (project, file)
    }

    func window(_ session: WorkspaceSession) -> WorkspaceWindowController {
        _ = NSApplication.shared
        let wc = WorkspaceWindowController(session: session, loadDestinations: false, startLanguageService: false)
        wc.window?.appearance = NSAppearance(named: .aqua)
        wc.applyDefaultLayout()
        return wc
    }

    func pump(_ s: Double = 0.1) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    /// Lines of `b` that are not in `a` (a multiset difference).
    func addedLines(_ a: String, _ b: String) -> [String] {
        var pool = a.components(separatedBy: "\n")
        return b.components(separatedBy: "\n").filter { line in
            if let i = pool.firstIndex(of: line) { pool.remove(at: i); return false }
            return true
        }
    }

    static func shot(_ w: NSWindow?, _ name: String) {
        guard let w else { return }
        let dir = ProcessInfo.processInfo.environment["YCODE_B5_SHOTS"] ?? ycodeDir.appendingPathComponent(".build-ide/b5-shots").path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        UISpacingProbeTests.shot(w, URL(fileURLWithPath: dir).appendingPathComponent(name))
    }

    /// §1–§4: the live warning before any build: one file-less warning,
    /// the capsule "⚠ 1", the navigator's project row with "1 issue", the
    /// stepper in the jump bar; › opens the project editor without the sheet.
    @Test func theUnbuiltProjectShowsTheLiveWarning() throws {
        let dir = scratch("live")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (project, _) = try toolProject(dir)
        let session = WorkspaceSession(model: try WorkspaceModel(url: project))
        let wc = window(session)
        #expect(session.projectIssues.map(\.message) == ["Update to recommended settings"])
        #expect(session.projectIssues.allSatisfy { $0.severity == .warning && $0.location == nil })
        // The capsule: one warning, shown.
        #expect(wc.issueCapsule.warnings == 1 && wc.issueCapsule.errors == 0 && !wc.issueCapsule.isHidden)
        #expect(wc.issueCapsule.parts.map(\.1) == [1])
        // The Issue navigator: the project row, "1 issue", the warning under it.
        wc.navigator.select(4)
        let root = try #require(wc.navigator.roots[4].first)
        #expect(root.title == session.issueGrouping.projectName && root.detail == "1 issue", "\(root.title) \(root.detail ?? "-")")
        #expect(root.children.map(\.title) == ["Update to recommended settings"])
        #expect(root.children.first?.symbol == "exclamationmark.triangle.fill" && root.children.first?.path == nil)
        // The jump bar's stepper, with a file open.
        wc.open(path: project.deletingLastPathComponent().appendingPathComponent("Tool/main.swift").path, line: nil)
        pump()
        #expect(wc.editorArea.allEditors.allSatisfy { !$0.jumpBar.issueStack.arrangedSubviews.isEmpty })
        #expect(wc.editorArea.allEditors.first?.jumpBarIssueKind == .warning)
        Self.shot(wc.window, "mac-p120-live-warning-light.png")
        // ›: the project editor, no sheet.
        wc.stepIssue(+1)
        #expect(wc.projectEditor != nil && wc.pendingRecommendedSettings == nil)
    }

    /// §5: the row opens the project editor and the checklist (581 × 364,
    /// Cancel and Perform Changes, the default); Cancel writes nothing.
    @Test func theRowOpensTheChecklistAndCancelWritesNothing() throws {
        let dir = scratch("cancel")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (project, file) = try toolProject(dir)
        let before = try String(contentsOf: file, encoding: .utf8)
        let session = WorkspaceSession(model: try WorkspaceModel(url: project))
        let wc = window(session)
        wc.window?.orderBack(nil)
        defer { wc.window?.orderOut(nil) }
        wc.navigator.select(4)
        wc.openProjectIssue("Update to recommended settings")
        pump(0.3)
        let sheet = try #require(wc.pendingRecommendedSettings)
        #expect(wc.projectEditor != nil)
        #expect(sheet.view.frame.size == NSSize(width: 581, height: 364))
        #expect(wc.window?.attachedSheet != nil)
        // The rows: the Build Settings group, then its changes in order.
        #expect(sheet.checklist.rows.map(\.id).first == "group|Build Settings")
        #expect(sheet.checklist.changes.map(\.title) == [
            "Target 'Tool' - Enable Weak References in Manual Retain Release",
            "Target 'Tool' - Enable Weak References in Manual Retain Release",
            "Target 'Tool' \u{2014} Enable Dead Code Stripping",
            "Project 'Tool' - Enable Recommended Warnings",
            "Project 'Tool' \u{2014} Enable Dead Code Stripping",
            "Enable User Script Sandboxing",
        ])
        #expect(sheet.checkboxes.values.allSatisfy { $0.state == .on })
        // Row heights: a heading 18, a one-line change 30, the warnings list taller.
        #expect(sheet.rowFrames["group|Build Settings"]?.height == 18)
        #expect(sheet.rowFrames[sheet.checklist.changes[2].id]?.height == 44 || sheet.rowFrames[sheet.checklist.changes[2].id]?.height == 30)
        #expect((sheet.rowFrames["warnings"]?.height ?? 0) > 300)
        #expect(sheet.scrollView.frame.width == 522)
        // The buttons: Cancel 84 × 23 and Perform Changes 130 × 23, 12 apart,
        // 20 from the right and 17 from the bottom; Return and Escape.
        #expect(sheet.cancelButton.frame == NSRect(x: 335, y: 324, width: 84, height: 23))
        #expect(sheet.performButton.frame == NSRect(x: 431, y: 324, width: 130, height: 23))
        #expect(sheet.performButton.keyEquivalent == "\r", "\(Array(sheet.performButton.keyEquivalent.unicodeScalars))")
        #expect(sheet.cancelButton.keyEquivalent == "\u{1b}", "\(Array(sheet.cancelButton.keyEquivalent.unicodeScalars))")
        if let panel = wc.window?.attachedSheet { Self.shot(panel, "mac-p120-checklist-light.png") }
        sheet.cancelClicked()
        pump(0.3)
        #expect(wc.pendingRecommendedSettings == nil && wc.window?.attachedSheet == nil)
        #expect(try String(contentsOf: file, encoding: .utf8) == before)
        #expect(session.projectIssues.map(\.message) == ["Update to recommended settings"])
    }

    /// §6 item 3: Perform Changes writes the checked rows' settings and the
    /// running `LastUpgradeCheck` through the pbxproj writer and nothing
    /// else; the warning goes, and with it the capsule and the stepper.
    @Test func performChangesWritesOnlyTheCheckedSettings() throws {
        let dir = scratch("perform")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (project, file) = try toolProject(dir)
        let before = try String(contentsOf: file, encoding: .utf8)
        let session = WorkspaceSession(model: try WorkspaceModel(url: project))
        let wc = window(session)
        // Uncheck the warnings row; the group turns mixed.
        let sheet = try #require(wc.showRecommendedSettings())
        _ = sheet.view
        sheet.toggle(rowID: "warnings")
        #expect(sheet.checkboxes["warnings"]?.state == .off && sheet.checkboxes["group|Build Settings"]?.state == .mixed)
        sheet.performClicked()
        let after = try String(contentsOf: file, encoding: .utf8)
        let added = addedLines(before, after)
        #expect(addedLines(after, before).isEmpty, "nothing rewritten")
        // The checked rows' settings, and the running version in
        // LastUpgradeCheck (`issues.md` §1 item 5, §8 item 8); the
        // attributes dictionary's own lines when the file had none.
        let rows = added.filter { $0.contains(" = YES;") }
        #expect(rows.count == 2 + 2 + 2 + 2, "\(added)")
        #expect(rows.allSatisfy { l in ["CLANG_ENABLE_OBJC_WEAK = YES;", "DEAD_CODE_STRIPPING = YES;", "ENABLE_USER_SCRIPT_SANDBOXING = YES;"].contains { l.contains($0) } })
        #expect(added.contains { $0.contains("LastUpgradeCheck = \(RecommendedSettings.ideVersionDigits);") }, "\(added)")
        #expect(added.filter { !rows.contains($0) && !$0.contains("LastUpgradeCheck") }
            .allSatisfy { $0.contains("attributes = {") || $0.trimmingCharacters(in: .whitespaces) == "};" }, "\(added)")
        #expect(wc.pendingRecommendedSettings == nil)
        // The project is current now: the warning goes with the capsule, and
        // the unchecked warnings row is not offered again by this version.
        #expect(session.projectIssues.isEmpty)
        #expect(wc.issueCapsule.isHidden && wc.issueCapsule.warnings == 0)
        #expect(wc.showRecommendedSettings() == nil)
    }
}
