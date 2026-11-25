import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell

// YCODE_IDE_POPOVERSFIX=<prefix>: the beta 5 fix round's popover walk
// (B5-FIX-POPOVERS, council round 12), with a project open:
//
//   1. the destination chooser: the checked row highlighted on opening,
//      Ycode's rows the last of Simulators (P-113, `popovers.md` §2.7)
//   2. Quick Actions with "build": two-line 56-point rows (P-086, §5.1)
//   3. Quick Help for a module in an import, and for a body symbol's
//      declaration box (P-083, §4.1, §4.2)
//   4. the Run tooltip after 1.56 s, held then swapped for Stop's, then
//      fading away (P-197, `control-states.md` §8, §8.1)
//
// Each state writes <prefix>-<state>.png; each step prints
// "popoversfix <state>: …".
extension ShellDriver {
    #if os(Linux)
    static func popoversFixWalk(_ app: ShellAppModel, prefix: String) async {
        guard let w = app.workspace else {
            say("popoversfix: run with a project path")
            return
        }
        func shot(_ state: String, settle: Double = 0.5) async {
            await pause(settle)
            say("popoversfix \(state): " + OpenViewsAutomation.screenshot(to: "\(prefix)-\(state).png"))
        }
        func frames(_ names: [String]) -> String {
            names.map { n in frame(n).map { String(format: "%@ %.0f,%.0f %.0fx%.0f", n, $0.minX, $0.minY, $0.width, $0.height) } ?? "\(n) none" }
                .joined(separator: "; ")
        }
        await shot("workspace")

        // 1. The destination chooser.
        await click("tb destination")
        let l = w.popovers.list
        say("popoversfix destination: highlighted \(l.current.map { "\($0.title) checked \($0.isChecked)" } ?? "none") rows "
            + l.rows.map { $0.kind == .separator ? "—" : $0.title }.joined(separator: " | "))
        await shot("destination-chooser")
        OpenViewsAutomation.press(.escape)
        await pause(0.2)

        // 2. Quick Actions with "build".
        w.showQuickActions(ShellQuickActions.collect(app: app))
        await pause(0.4)
        OpenViewsAutomation.type("build")
        await pause(0.4)
        say("popoversfix quick-actions: " + (w.popovers.quickActions?.shown ?? []).prefix(8)
            .map { "\($0.entry.displayTitle) / \($0.entry.subtitle) [\($0.entry.symbol)] \($0.shortcut)" }.joined(separator: " | ")
            + " — " + frames(["quick actions", "palette row 0", "palette row 1"]))
        await shot("quick-actions-build")
        OpenViewsAutomation.press(.downArrow)
        await pause(0.2)
        await shot("quick-actions-down")
        OpenViewsAutomation.press(.escape)
        await pause(0.3)

        // 3. Quick Help: a module in an import, then a body symbol.
        let files = w.session.model.root.allFiles.filter { $0.name.hasSuffix(".swift") && $0.name != "Package.swift" }
        if let f = (files.first(where: { (try? String(contentsOfFile: $0.path ?? "", encoding: .utf8))?.contains("import ") == true }) ?? files.first)?.path {
            w.open(f)
        }
        await pause(0.6)
        // Every import's module (an SDK module: title and link; the
        // package's own, with a catalog: its abstract and Overview).
        let text = (w.editor?.buffer.text ?? "") as NSString
        var from = 0, n = 0
        while n < 2 {
            let r = text.range(of: "import ", range: NSRange(location: from, length: text.length - from)).location
            guard r != NSNotFound else { break }
            n += 1
            from = r + 7
            let doc = w.showModuleQuickHelp(at: r + 8)
            say("popoversfix quickhelp-module-\(n): \(doc.map { "\($0.title) summary \($0.summary ?? "none") sections \($0.sectionOrder)" } ?? "none") "
                + frames(["quickhelp hairline", "quickhelp heading", "quickhelp documentation"]))
            await shot("quickhelp-module-\(n)")
            w.dismissQuickHelp()
        }
        if let d = w.editor {
            var doc = QuickHelpDocument(hover: "```swift\nnonisolated let name: String\n```", file: d.path)
            doc.title = "name"
            // The last `let`'s name (a body symbol), else the start.
            let s = (d.buffer.text as NSString).range(of: "let ", options: .backwards).location
            let at = s == NSNotFound ? 0 : min(d.buffer.length, s + 4)
            w.showQuickHelpPopover(doc, at: at, text: "name")
            await pause(0.4)
            say("popoversfix quickhelp-symbol: " + frames(["quickhelp popover", "quickhelp declaration", "quickhelp file"]))
            await shot("quickhelp-symbol")
            w.dismissQuickHelp()
        }

        // 4. Tooltips: Run's after 1.56 s; straight onto Stop: swapped after the hold; away: fading.
        if let run = frame("tb run"), let stop = frame("tb stop") {
            OpenViewsAutomation.move(to: CGPoint(x: run.midX, y: run.midY))
            await pause(1.3)
            await shot("tooltip-before-delay", settle: 0)
            await pause(0.45)
            await shot("tooltip-run", settle: 0)
            OpenViewsAutomation.move(to: CGPoint(x: stop.midX, y: stop.midY))
            await pause(0.2)
            await shot("tooltip-held", settle: 0)
            await pause(0.3)
            await shot("tooltip-stop", settle: 0)
            OpenViewsAutomation.move(to: CGPoint(x: run.midX, y: run.maxY + 300))
            await pause(0.55)
            await shot("tooltip-fading", settle: 0)
            await pause(0.5)
            await shot("tooltip-gone", settle: 0)
        } else {
            say("popoversfix tooltips: no run/stop frames")
        }
        say("popoversfix done: " + state(app))
    }
    #endif
}
