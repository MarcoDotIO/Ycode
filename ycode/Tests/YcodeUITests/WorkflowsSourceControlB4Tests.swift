import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Beta 4 workflow fixes: the merge sheet's Cancel (P-131), New Branch
/// (P-132) and Activate Console (P-123). The workspace window is ordered
/// in only under the offscreen guard: nothing reaches a display, and no
/// step may start an app-modal alert (the old Cancel did).
@MainActor
@Suite(.serialized, .appearanceReader) struct WorkflowsSourceControlB4Tests {
    let base = MergeSheetUITests()

    func shownWindow(_ r: MergeSheetUITests.Repo) async throws -> WorkspaceWindowController {
        let wc = try await r.window(dark: true)
        wc.window?.orderFront(nil)
        return wc
    }

    func sheetWindows(_ wc: WorkspaceWindowController) -> [NSWindow] {
        (wc.window?.childWindows ?? []).filter { $0 is MergeSheetWindow && $0.isVisible }
    }

    // MARK: P-131

    @Test func cancelClosesTheSheetAtOnceAndAbortsTheMerge() async throws {
        let r = try MergeSheetUITests.Repo("b4-cancel")
        defer { r.cleanUp() }
        let wc = try await shownWindow(r)
        defer { wc.window?.orderOut(nil) }
        let head = try r.git("rev-parse", "HEAD")
        let sheet = try await base.openSheet(wc)
        #expect(sheet.abortsOnCancel)
        WorkflowsB4Shots.save(window: wc.sourceControl.mergeOverlay?.sheetWindow, "mac-p131-merge-sheet")
        // The accessibility press returns at once (no modal question).
        let start = Date()
        #expect(sheet.cancelButton.accessibilityPerformPress())
        #expect(Date().timeIntervalSince(start) < 1)
        #expect(wc.sourceControl.mergeSheet == nil)
        await waitFor("the abort") { await wc.sourceControl.idle() }
        await eventually("the sheet's window to go") { sheetWindows(wc).isEmpty }
        #expect(wc.sourceControl.snapshot.integration == .none)
        #expect(try r.git("rev-parse", "HEAD") == head)
        #expect(try r.git("status", "--porcelain").isEmpty)
        WorkflowsB4Shots.save(window: wc.window, "mac-p131-after-cancel")
    }

    @Test func aMergeAbortedElsewhereClosesTheSheet() async throws {
        let r = try MergeSheetUITests.Repo("b4-elsewhere")
        defer { r.cleanUp() }
        let wc = try await shownWindow(r)
        defer { wc.window?.orderOut(nil) }
        _ = try await base.openSheet(wc)
        _ = try r.git("merge", "--abort")
        wc.refreshFileStatus(nil)
        await waitFor("the refresh") { await wc.sourceControl.idle() }
        await eventually("the empty sheet to close") { wc.sourceControl.mergeSheet == nil && sheetWindows(wc).isEmpty }
    }

    @Test func cancelLeavesAnOperationStartedElsewhereStopped() async throws {
        let r = try MergeSheetUITests.Repo("b4-outside")
        defer { r.cleanUp() }
        _ = try? r.git("merge", "feature")   // conflicts: exits non-zero
        let wc = try await shownWindow(r)
        defer { wc.window?.orderOut(nil) }
        let sheet = try #require(wc.sourceControl.showConflictEditor())
        await waitFor("the sheet") { await sheet.idle() }
        #expect(!sheet.abortsOnCancel)
        sheet.cancelButton.performClick(nil)
        await waitFor("source control") { await wc.sourceControl.idle() }
        #expect(wc.sourceControl.mergeSheet == nil)
        #expect(wc.sourceControl.snapshot.integration != .none)
        _ = try r.git("merge", "--abort")
    }

    // MARK: P-132

    @Test func newBranchSheetNeedsAName() async throws {
        let r = try MergeSheetUITests.Repo("b4-branch")
        defer { r.cleanUp() }
        let wc = try await shownWindow(r)
        defer { wc.window?.orderOut(nil) }
        let sheet = wc.sourceControl.presentNewBranchSheet(from: nil)
        #expect(wc.window?.attachedSheet != nil)
        #expect(sheet.source == "main")
        #expect(NewBranchSheetController.title(repository: "Merger") == "Create new branch in \u{201C}Merger\u{201D}:")
        #expect(!sheet.createButton.isEnabled)
        sheet.setName("   ")
        #expect(!sheet.createButton.isEnabled)
        sheet.create(nil)
        #expect(wc.window?.attachedSheet != nil, "an empty name creates nothing")
        WorkflowsB4Shots.save(window: wc.window?.attachedSheet, "mac-p132-new-branch-empty")
        sheet.setName("topic")
        #expect(sheet.createButton.isEnabled)
        WorkflowsB4Shots.save(window: wc.window?.attachedSheet, "mac-p132-new-branch-named")
        sheet.create(nil)
        await waitFor("the branch") { await wc.sourceControl.idle() }
        await eventually("the sheet to close") { wc.window?.attachedSheet == nil }
        #expect(try r.git("branch", "--show-current").trimmingCharacters(in: .whitespacesAndNewlines) == "topic")
    }

    // MARK: P-123

    @Test func activateConsoleTakesTheKeyboardFromTheEditor() async throws {
        let r = try MergeSheetUITests.Repo("b4-console")
        defer { r.cleanUp() }
        let wc = try await shownWindow(r)
        defer { wc.window?.orderOut(nil) }
        let w = try #require(wc.window)
        wc.open(path: r.file, line: 1)
        #expect(w.makeFirstResponder(wc.editor.textView))
        let before = wc.editor.text
        wc.activateConsole(nil)
        #expect(wc.debugAreaHeightShown != nil)
        #expect(w.firstResponder === wc.debugArea.consoleView, "no session: the console's output has the keyboard")
        // During a debug session the lldb command line takes it.
        w.makeFirstResponder(wc.editor.textView)
        wc.debugArea.setDebugging(true)
        wc.activateConsole(nil)
        let field = wc.debugArea.consoleField
        #expect(w.firstResponder === field.currentEditor(), "the lldb prompt has the keyboard")
        (field.currentEditor() as? NSTextView)?.insertText("p 1 + 2", replacementRange: NSRange(location: 0, length: 0))
        #expect(field.stringValue == "p 1 + 2" || (field.currentEditor() as? NSTextView)?.string == "p 1 + 2")
        #expect(wc.editor.text == before, "nothing was typed into the source")
        WorkflowsB4Shots.save(window: w, "mac-p123-activate-console")
        wc.debugArea.setDebugging(false)
    }
}
