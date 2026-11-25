import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell

// YCODE_IDE_POPOVERS5=<prefix>: beta 5's popover walk (B5-POPOVERS,
// `specs/ide/popovers.md`), with a project open:
//
//   1. the scheme chooser from a click on the scheme half (P-111): its
//      frame, rows and highlight; Down, Up; Escape closes it
//   2. the destination chooser (P-113); Escape
//   3. New Scheme… from the scheme chooser: the sheet (P-112); Cancel
//   4. Jump to Line (⌘L): the capsule; "3", Return jumps and closes; again,
//      Escape fades it (P-086, P-195)
//   5. Quick Actions: the empty capsule; "build" lists commands (P-086)
//   6. Quick New Project: the panel and its rows (P-180)
//
// Each state writes <prefix>-<state>.png; each step prints
// "popovers5 <state>: …" with the frames the IDE reports.
extension ShellDriver {
    #if os(Linux)
    static func popovers5Walk(_ app: ShellAppModel, prefix: String) async {
        guard let w = app.workspace else {
            say("popovers5: run with a project path")
            return
        }
        func shot(_ state: String) async {
            await pause(0.5)
            say("popovers5 \(state): " + OpenViewsAutomation.screenshot(to: "\(prefix)-\(state).png"))
        }
        func frames(_ names: [String]) -> String {
            names.map { n in frame(n).map { String(format: "%@ %.0f,%.0f %.0fx%.0f", n, $0.minX, $0.minY, $0.width, $0.height) } ?? "\(n) none" }
                .joined(separator: "; ")
        }
        func rows() -> String {
            w.popovers.list.rows.enumerated().map { i, r in
                (i == w.popovers.list.highlighted ? "[" : "") + (r.kind == .separator ? "—" : r.title) + (r.isChecked ? " ✓" : "")
                    + (r.trailing.map { " \($0)" } ?? "") + (i == w.popovers.list.highlighted ? "]" : "")
            }.joined(separator: " | ")
        }
        await shot("workspace")

        // 1. The scheme chooser.
        await click("tb scheme")
        let sp = w.popovers.placement(.scheme)
        say("popovers5 scheme-open: shown \(w.popovers.chooser.map { "\($0)" } ?? "none") anchor \(w.popovers.anchors[.scheme].map { "\($0)" } ?? "none") "
            + "body \(sp.map { "\($0.body)" } ?? "none") tip \(sp.map { "\($0.arrowTip)" } ?? "none")")
        say("popovers5 scheme-rows: \(rows())")
        say("popovers5 scheme-frames: " + frames(["scheme chooser", "chooser filter", "tb scheme"]))
        await shot("scheme-chooser")
        OpenViewsAutomation.press(.downArrow)
        await pause(0.2)
        say("popovers5 scheme-down: \(rows())")
        await shot("scheme-down")
        OpenViewsAutomation.press(.upArrow)
        await pause(0.2)
        OpenViewsAutomation.press(.escape)
        await pause(0.2)
        say("popovers5 scheme-escape: shown \(w.popovers.chooser.map { "\($0)" } ?? "none")")

        // 2. The destination chooser.
        await click("tb destination")
        say("popovers5 destination-rows: \(rows())")
        say("popovers5 destination-frames: " + frames(["destination chooser", "tb destination"]))
        await shot("destination-chooser")
        OpenViewsAutomation.press(.escape)
        await pause(0.2)

        // 3. New Scheme… from the chooser.
        await click("tb scheme")
        if let i = w.popovers.list.rows.firstIndex(where: { SchemeChooser.command($0) == .new }) {
            await click("chooser row \(i)")
        }
        await pause(0.5)
        say("popovers5 new-scheme: \(w.popovers.newScheme.map { "targets \($0.targets.map(\.name)) name \($0.name)" } ?? "closed") "
            + frames(["new scheme sheet", "new scheme ok", "new scheme cancel"]))
        await shot("new-scheme")
        await click("new scheme cancel")
        say("popovers5 new-scheme-cancel: \(w.popovers.newScheme == nil ? "closed" : "open")")

        // 4. Jump to Line, in the first Swift file.
        if let f = w.session.model.root.allFiles.first(where: { $0.name.hasSuffix(".swift") })?.path { w.open(f) }
        await pause(0.6)
        say("popovers5 opened: length \(w.editor?.buffer.length ?? 0) edited \(w.editedPaths.count)")
        app.perform(.jumpToLine)
        await pause(0.4)
        say("popovers5 jump-open: shown \(w.isJumpToLineShown) " + frames(["jump to line", "jump field"]))
        await shot("jump-to-line")
        OpenViewsAutomation.type("3")
        await pause(0.2)
        say("popovers5 jump-typed: \"\(w.popovers.jumpText)\" lines \(w.editor?.buffer.lineCount ?? 0) edited \(w.editedPaths.count)")
        OpenViewsAutomation.press(.return)
        await pause(0.3)
        say("popovers5 jump-return: shown \(w.isJumpToLineShown) caret line \((w.editor?.buffer.caretLine).map { $0 + 1 } ?? 0) edited \(w.editedPaths.count)")
        app.perform(.jumpToLine)
        await pause(0.4)
        OpenViewsAutomation.press(.escape)
        await pause(0.05)
        say("popovers5 jump-escape: fading \(w.popovers.jumpFading)")
        await pause(0.4)
        say("popovers5 jump-faded: shown \(w.isJumpToLineShown) edited \(w.editedPaths.count)")

        // 5. Quick Actions.
        w.showQuickActions(ShellQuickActions.collect(app: app))
        await pause(0.4)
        say("popovers5 quick-actions: commands \(w.popovers.quickActions?.all.count ?? 0) " + frames(["quick actions", "quick actions field"]))
        await shot("quick-actions")
        OpenViewsAutomation.type("build")
        await pause(0.4)
        say("popovers5 quick-actions-build: \((w.popovers.quickActions?.shown ?? []).prefix(6).map(\.title)) " + frames(["quick actions"]))
        await shot("quick-actions-build")
        say("popovers5 quick-actions-edited: \(w.editedPaths.count)")
        OpenViewsAutomation.press(.escape)
        await pause(0.3)

        // 6. Quick New Project.
        w.showQuickNewProject()
        await pause(0.4)
        say("popovers5 quick-new-project: \((w.popovers.quickNewProject?.shown ?? []).map(\.title)) " + frames(["quick new project"]))
        await shot("quick-new-project")
        OpenViewsAutomation.press(.downArrow)
        await pause(0.2)
        await shot("quick-new-project-down")
        OpenViewsAutomation.press(.escape)
        await pause(0.3)
        say("popovers5 done: " + state(app))
    }
    #endif
}
