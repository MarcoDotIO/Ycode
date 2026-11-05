import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_CONFLICT=<prefix>: the conflict editor (B3-CONFLICT, issue
// #75) on the Merger repository of scripts/linux-conflict/make-conflict.sh.
// Through the pointer where it can: merges "feature" (the editor opens on
// the first conflicted file), compares Base and Left, resolves
// Colors.swift by choosing Left then Right, resolves Greeting.swift by
// hand (Edit, then typing), marks each resolved and continues the merge;
// cherry-picks "pick" (one conflict, Right), continues; checks out
// "topic", rebases it onto "main" and aborts the rebase from the editor;
// checks out "main" again. Writes <prefix>-conflict-<state>.png and prints
// one "conflict ..." line per step (scripts/linux-conflict/run.sh checks
// the repository afterwards).
extension ShellDriver {
    #if os(Linux)
    static func conflictWalk(_ app: ShellAppModel, prefix: String) async {
        guard let w = app.workspace else { say("conflict: no workspace"); return }
        let scm = w.sourceControl
        func line() -> String {
            let s = scm.snapshot
            guard let e = scm.conflictEditor else {
                return "branch=\(s.currentBranch ?? "-") integration=\(s.integration) pane=\(String(describing: scm.pane)) error=\(scm.errorMessage ?? "-")"
            }
            let st = e.state
            return "branch=\(s.currentBranch ?? "-") integration=\(st.integration.verb.isEmpty ? "none" : st.integration.verb) "
                + "title=\"\(st.title)\" files=\(st.fileNames) status=\"\(st.statusText)\" hunk=\"\(st.hunkLabel)\" "
                + "segment=\(st.selectedSegment.map(String.init) ?? "-") editing=\(st.isEditing) pair=\(st.pair) "
                + "continue=\(st.showsIntegrationButtons ? "\"\(st.continueTitle)\"\(st.canContinue ? "" : " disabled")" : "hidden") "
                + "error=\(scm.errorMessage ?? "-")"
        }
        func shot(_ name: String) async {
            await pause(0.7)
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
        // Mark as Resolved through the pointer, then waits for the next
        // file (or none) to be shown.
        func resolveShown() async {
            guard let e = scm.conflictEditor else { return }
            let file = e.state.currentFile
            await click("conflict resolve")
            await until("the next file") { e.state.currentFile != file && !e.isLoading && (e.state.document != nil || e.state.files.isEmpty) }
            await waitIdle()
        }
        // Answers the window's question with `title`: the alert's button
        // through the pointer, else through the model.
        func answer(_ title: String) async {
            await pause(0.5)
            if OpenViewsAutomation.texts().contains(where: { $0.text == title && $0.inPopup }) {
                await clickText(title, inPopup: true)
            }
            if let c = scm.confirmation {
                say("conflict: answered \(title) through the model")
                if let choice = c.choices.first(where: { $0.title == title }) { scm.confirm(choice) }
            }
            await waitIdle()
        }
        await waitIdle()
        // ⌘2 with the pointer: the selector's second icon.
        await click("selector 1")
        await waitIdle()

        // MARK: Merge "feature"
        scm.choose(.merge("feature"))
        await shot("merge-question")
        await answer("Merge")
        guard let editor = scm.conflictEditor else { say("conflict FAIL: the merge did not open the conflict editor: \(line())"); return }
        await until("the first file") { editor.state.document != nil && !editor.isLoading }
        await shot("opened")
        // Integrate ▸ Resolve Conflicts…, Continue Merge, Abort Merge.
        await clickText("Integrate", inPopup: false)
        await shot("integrate-menu")
        say("conflict integrate items: \(OpenViewsAutomation.texts().filter(\.inPopup).map(\.text))")
        OpenViewsAutomation.press(.escape)
        await pause(0.3)
        // Base and Left, then back to Left and Right.
        await click("conflict pair 1")
        await shot("base-left")
        await click("conflict pair 0")

        // Colors.swift: choosing sides (Left, then Right for the next conflict).
        if editor.state.fileNames.first != "Colors.swift" { editor.showFile(at: 0); await waitIdle() }
        await click("conflict choice 0")
        await shot("colors-left")
        await click("conflict choice 1")
        await shot("colors-chosen")
        await resolveShown()
        await shot("greeting")

        // Greeting.swift: by hand.
        await click("conflict choice 5")
        await shot("greeting-edit")
        let handLine = "    \"Greetings, \\(name)!\"\n"
        await click("conflict hand editor")
        OpenViewsAutomation.press(.character("a"), modifiers: [.control])
        await pause(0.2)
        OpenViewsAutomation.type(handLine)
        await pause(0.5)
        if editor.state.document.map({ $0.result.contains("Greetings, \\(name)!") && $0.isResolved }) != true {
            say("conflict: typed text missing (\(editor.editedText.debugDescription)); set through the model")
            editor.editedText = handLine
        }
        await shot("greeting-hand-edited")
        await resolveShown()
        await shot("all-resolved")
        await click("conflict continue")
        await waitIdle()
        await shot("merge-completed")
        say("conflict merge: head=\(scm.snapshot.head?.prefix(7) ?? "-") integration=\(scm.snapshot.integration) editor=\(scm.conflictEditor != nil)")

        // MARK: Cherry-pick "pick"
        scm.perform(.cherryPick("pick"))
        await waitIdle()
        await until("the pick's file") { scm.conflictEditor.map { $0.state.document != nil && !$0.isLoading } ?? true }
        await shot("pick-opened")
        if scm.conflictEditor != nil {
            await click("conflict choice 1")
            await resolveShown()
            await shot("pick-resolved")
            await click("conflict continue")
            await waitIdle()
        }
        await shot("pick-completed")

        // MARK: Rebase "topic" onto "main", then abort
        scm.perform(.checkout("topic", .carry))
        await waitIdle()
        scm.perform(.rebase("main"))
        await waitIdle()
        await until("the rebase's file") { scm.conflictEditor.map { $0.state.document != nil && !$0.isLoading } ?? true }
        await shot("rebase-opened")
        await click("conflict abort")
        await shot("rebase-abort-question")
        await answer("Abort")
        await shot("rebase-aborted")
        scm.perform(.checkout("main", .carry))
        await waitIdle()
        say("conflict walk done: branch=\(scm.snapshot.currentBranch ?? "-") integration=\(scm.snapshot.integration) "
            + "pane=\(String(describing: scm.pane)) error=\(scm.errorMessage ?? "-")")
    }
    #endif
}
