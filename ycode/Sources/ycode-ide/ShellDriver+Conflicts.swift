import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_CONFLICT=<prefix>: the merge workflow and the merge sheet
// (`specs/ide/merge-sheet.md`; B3-MERGE, after B3-CONFLICT's #75) on the
// Merger repository of scripts/linux-conflict/make-conflict.sh, through the
// pointer: Integrate's Merge… (the alert with its branch pop-up, then
// Cancel); the "feature" branch row's context menu, Merge “feature” into
// “main”…, the alert, Merge; the sheet (a frame mid-appearance, then at
// rest); Colors.swift resolved through its tokens' Choose menus (Left,
// then Right), the Flat file list; Greeting.swift written by hand
// (double-click the change, type); Merge (the merge commit). Then a
// cherry-pick of "pick" through the sheet (Right, Continue Cherry-Pick) and
// a rebase of "topic" cancelled from the sheet (Cancel → Abort). Writes
// <prefix>-conflict-<state>.png and prints one "conflict ..." line per step
// (scripts/linux-conflict/run.sh checks the repository afterwards).
extension ShellDriver {
    #if os(Linux)
    static func conflictWalk(_ app: ShellAppModel, prefix: String) async {
        guard let w = app.workspace else { say("conflict: no workspace"); return }
        let scm = w.sourceControl
        func line() -> String {
            let s = scm.snapshot
            var out = "branch=\(s.currentBranch ?? "-") integration=\(s.integration.verb.isEmpty ? "none" : s.integration.verb) "
                + "alert=\(scm.mergeAlert.map { "\"\($0.title)\"" } ?? "-") merging=\(scm.isMerging) error=\(scm.errorMessage ?? "-")"
            if let e = scm.conflictEditor {
                let st = e.state
                let tokens = (st.document?.hunks.indices).map { r in r.compactMap { st.token(forHunk: $0)?.glyph }.joined() } ?? ""
                out += " sheet: file=\(st.currentFile.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "-") files=\(st.fileNames) "
                    + "stepper=\(st.stepperText) tokens=\(tokens) primary=\"\(st.primaryTitle)\"\(st.canMerge ? "" : " disabled") "
                    + "editing=\(st.isEditing) footers=\"\(st.leftFooter?.commitText ?? "-")\"|\"\(st.rightFooter?.commitText ?? "-")\""
            }
            return out
        }
        func shot(_ name: String, settle: Double = 0.7) async {
            await pause(settle)
            say("conflict \(name): \(line()) " + OpenViewsAutomation.screenshot(to: "\(prefix)-conflict-\(name).png"))
        }
        func waitIdle() async {
            for _ in 0..<200 {
                await pause(0.1)
                if scm.busy == nil { break }
            }
            await scm.idle()
            if let e = scm.conflictEditor { await e.idle() }
        }
        // Waits (at most ten seconds) for `done`.
        func until(_ what: String, _ done: () -> Bool) async {
            for _ in 0..<100 {
                if done() { return }
                await pause(0.1)
            }
            say("conflict: timed out waiting for \(what)")
        }
        // Answers the window's question with `title`: the alert's button
        // through the pointer (in a pop-up, else the one nearest the
        // window's centre, where the alert is), else through the model.
        func answer(_ title: String) async {
            await pause(0.5)
            if OpenViewsAutomation.texts().contains(where: { $0.text == title && $0.inPopup }) {
                await clickText(title, inPopup: true)
            } else if let size = OpenViewsAutomation.windowSize()?.points {
                let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                let nearest = OpenViewsAutomation.texts().filter { $0.text == title && !$0.inPopup }
                    .min { hypot($0.frame.midX - centre.x, $0.frame.midY - centre.y) < hypot($1.frame.midX - centre.x, $1.frame.midY - centre.y) }
                if let t = nearest {
                    await OpenViewsAutomation.click(at: CGPoint(x: t.frame.midX, y: t.frame.midY))
                    await pause(0.4)
                }
            }
            if let c = scm.confirmation {
                say("conflict: answered \(title) through the model")
                if let choice = c.choices.first(where: { $0.title == title }) { scm.confirm(choice) }
            }
            await waitIdle()
        }
        func popupItems() -> [String] { OpenViewsAutomation.texts().filter(\.inPopup).map(\.text) }
        // The sheet is up with its file read.
        func sheetReady() async {
            await until("the sheet's file") { scm.conflictEditor.map { $0.state.document != nil && !$0.isLoading } ?? false }
            await waitIdle()
        }
        // A token's Choose menu through the pointer, then an item.
        func choose(_ hunk: Int, _ title: String, shotName: String? = nil) async {
            await click("merge token \(hunk)")
            await pause(0.3)
            say("conflict choose menu \(hunk): \(popupItems())")
            if let n = shotName { await shot(n, settle: 0.2) }
            if popupItems().contains(title) {
                await clickText(title, inPopup: true)
            } else if let e = scm.conflictEditor, let i = MergeSheetText.chooseTitles.firstIndex(of: title) {
                say("conflict: chose \(title) through the model")
                OpenViewsAutomation.press(.escape)
                e.choose(MergeSheetText.chooseChoices[i], forHunk: hunk)
            }
            await pause(0.3)
        }
        // Clicks the sheet's Merge (or Continue …) and waits.
        func merge() async {
            await click("merge merge")
            await waitIdle()
            await pause(0.5)
            await waitIdle()
        }

        await waitIdle()
        // ⌘2 with the pointer: the selector's second icon; Repositories.
        await click("selector 1")
        await waitIdle()
        await click("scm mode 1")
        await waitIdle()
        await shot("repositories")

        // MARK: Integrate ▸ Merge…: the alert with the branch pop-up.
        await clickText("Integrate", inPopup: false)
        await pause(0.4)
        say("conflict integrate items: \(popupItems())")
        await shot("integrate-menu", settle: 0.3)
        if popupItems().contains("Merge\u{2026}") {
            await clickText("Merge\u{2026}", inPopup: true)
        } else {
            OpenViewsAutomation.press(.escape)
            w.perform(.scmMerge)
        }
        await shot("alert-chooser")
        // Escape is Cancel.
        OpenViewsAutomation.press(.escape)
        await pause(0.5)
        say("conflict alert after Escape: \(scm.mergeAlert == nil ? "closed" : "still up")")
        if scm.mergeAlert != nil { await click("merge alert cancel") }
        await shot("alert-cancelled", settle: 0.5)

        // MARK: The branch row's menu, the alert, Merge
        if let row = frame("scm row feature") {
            await OpenViewsAutomation.click(at: CGPoint(x: row.midX, y: row.midY), button: 3)
            await pause(0.5)
        } else {
            say("conflict: no row feature")
        }
        say("conflict branch menu: \(popupItems())")
        await shot("branch-menu", settle: 0.2)
        let mergeItem = "Merge \u{201C}feature\u{201D} into \u{201C}main\u{201D}\u{2026}"
        if popupItems().contains(mergeItem) {
            await clickText(mergeItem, inPopup: true)
        } else {
            say("conflict: chose Merge through the model")
            OpenViewsAutomation.press(.escape)
            scm.choose(.merge("feature"))
        }
        await shot("alert-appearing", settle: 0.08)
        await shot("alert")
        // Frames of the alert going and the sheet coming in, with the
        // transitions stretched tenfold (fade 90 ms, slide 200 ms: 0.9 s and
        // 2 s), since a photograph takes longer than a frame.
        MergeOverlayLayer.timeScale = 10
        await click("merge alert merge")
        await shot("alert-leaving", settle: 0.25)
        await until("the sheet") { scm.conflictEditor != nil }
        await shot("sheet-appearing-1", settle: 0.3)
        await shot("sheet-appearing-2", settle: 0.4)
        await shot("sheet-appearing-3", settle: 0.6)
        MergeOverlayLayer.timeScale = 1
        await sheetReady()
        guard let editor = scm.conflictEditor else { say("conflict FAIL: the merge did not open the sheet: \(line())"); return }
        await shot("sheet")

        // MARK: Colors.swift through the Choose menus
        if editor.state.currentFile.map({ URL(fileURLWithPath: $0).lastPathComponent }) != "Colors.swift" {
            await click("merge file Colors.swift")
            await sheetReady()
        }
        await choose(0, "Choose Left", shotName: "choose-menu")
        await shot("colors-left")
        await click("merge stepper next")
        await shot("stepper-next", settle: 0.4)
        await choose(1, "Choose Right")
        await shot("colors-chosen")
        await click("merge flat")
        await shot("flat", settle: 0.4)
        await click("merge hierarchical")

        // MARK: Greeting.swift by hand
        await click("merge file Greeting.swift")
        await sheetReady()
        await shot("greeting")
        if let row = editor.state.sheetRows.firstIndex(where: { $0.hunk == 0 }), let f = frame("merge row \(row)") {
            // A click on the change's left lines (its line becomes the
            // current one), then a double-click there.
            let p = CGPoint(x: f.minX + 120, y: f.minY + 9)
            await OpenViewsAutomation.click(at: p)
            await pause(0.8)
            await OpenViewsAutomation.click(at: p)
            try? await Task.sleep(nanoseconds: 120_000_000)
            await OpenViewsAutomation.click(at: p)
            await pause(0.5)
            say("conflict double-click at \(Int(p.x)),\(Int(p.y)) (row \(row) \(f)): editing=\(editor.state.isEditing)")
        } else {
            say("conflict: no row of the change (\(editor.state.sheetRows.count) rows)")
        }
        if !editor.state.isEditing {
            say("conflict: hand editing started through the model")
            editor.beginEditing()
        }
        await shot("greeting-edit")
        let handLine = "    \"Greetings, \\(name)!\"\n"
        await click("merge hand editor")
        OpenViewsAutomation.press(.character("a"), modifiers: [.control])
        await pause(0.2)
        OpenViewsAutomation.type(handLine)
        await pause(0.5)
        if editor.state.document.map({ $0.result.contains("Greetings, \\(name)!") && $0.isResolved }) != true {
            say("conflict: typed text missing (\(editor.editedText.debugDescription)); set through the model")
            editor.editedText = handLine
        }
        await shot("greeting-hand-edited")
        // Merge: the commit, then the sheet goes (stretched tenfold again).
        MergeOverlayLayer.timeScale = 10
        await click("merge merge")
        await until("the sheet to close") { scm.conflictEditor == nil }
        await shot("sheet-closing", settle: 0.6)
        await waitIdle()
        await pause(2.5)
        MergeOverlayLayer.timeScale = 1
        await shot("merged")
        say("conflict merge: head=\(scm.snapshot.head?.prefix(7) ?? "-") integration=\(scm.snapshot.integration) sheet=\(scm.conflictEditor != nil)")

        // MARK: Cherry-pick "pick" through the sheet
        scm.perform(.cherryPick("pick"))
        await waitIdle()
        await sheetReady()
        await shot("pick-sheet")
        if scm.conflictEditor != nil {
            await choose(0, "Choose Right")
            await shot("pick-chosen")
            await merge()
        }
        await shot("pick-completed")

        // MARK: Rebase "topic" onto "main", then Cancel → Abort
        scm.perform(.checkout("topic", .carry))
        await waitIdle()
        scm.perform(.rebase("main"))
        await waitIdle()
        await sheetReady()
        await shot("rebase-sheet")
        await click("merge cancel")
        await shot("rebase-cancel-question", settle: 0.5)
        await answer("Abort")
        await shot("rebase-aborted")
        scm.perform(.checkout("main", .carry))
        await waitIdle()
        say("conflict walk done: branch=\(scm.snapshot.currentBranch ?? "-") integration=\(scm.snapshot.integration) "
            + "sheet=\(scm.conflictEditor != nil) error=\(scm.errorMessage ?? "-")")
    }
    #endif
}
