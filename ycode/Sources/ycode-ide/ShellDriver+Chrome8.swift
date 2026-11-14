import Foundation
import SwiftUI
import YcodeBuild
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_CHROME8=<prefix>: council round 8 group A's states
// (`fidelity-council.md` rows 196–203) on the workspace given as the path
// (the parity repositories' rest copy). YCODE_IDE_CHROME8_PART chooses:
//
//   appearance (default)  Sample.swift selected in the navigator, the caret
//                         on a line, in dark, then Settings' appearance to
//                         light, then dark again (row 197); the jump bar's
//                         file logo and the scheme capsule's glyphs (199,
//                         200) are in these pictures
//   narrow                run at 1100 wide: an error and a warning, the
//                         issues collapsed to the octagon (row 198)
//   reopen-save           a split, the left pane scrolled to line 40, saved
//   reopen                the same workspace reopened: the left pane's first
//                         line (row 202)
//
// Each state writes <prefix>-<state>.png and .txt (texts and identified views).
extension ShellDriver {
    #if os(Linux)
    static func chrome8Walk(_ app: ShellAppModel, prefix: String) async {
        guard let w = app.workspace else { say("chrome8: no workspace"); return }
        let part = env["YCODE_IDE_CHROME8_PART"] ?? "appearance"
        func shot(_ state: String, settle: Double = 0.8) async {
            await pause(settle)
            let top = ShellMetrics.menuBarHeight
            var lines: [String] = []
            func box(_ f: CGRect) -> String { String(format: "%.1f %.1f %.1f %.1f", f.minX, f.minY - top, f.width, f.height) }
            for t in OpenViewsAutomation.texts(0) where !t.text.isEmpty { lines.append("text \"\(t.text)\" \(box(t.frame))") }
            for (id, f) in OpenViewsAutomation.identifiedFrames(0).sorted(by: { $0.key < $1.key }) {
                lines.append("view \(box(f)) id=\(id.replacingOccurrences(of: " ", with: "_"))")
            }
            try? lines.joined(separator: "\n").write(toFile: "\(prefix)-\(state).txt", atomically: true, encoding: .utf8)
            say("chrome8 \(state): " + OpenViewsAutomation.screenshot(0, to: "\(prefix)-\(state).png"))
        }
        let files = w.root.allFiles.compactMap(\.path)
        func path(_ name: String) -> String? { files.first { $0.hasSuffix("/" + name) } }
        func openSample() {
            guard let p = path("Sample.swift") else { say("chrome8: no Sample.swift"); return }
            if let ids = w.root.idPath(to: p) { for id in ids.dropLast() { w.setExpanded(id, true) } }
            w.selection = w.root.idPath(to: p)?.last
        }
        switch part {
        case "narrow":
            openSample()
            w.session.packageIssues = [Diagnostic(severity: .error, message: "An error"), Diagnostic(severity: .warning, message: "A warning")]
            await shot("narrow-issues")
            say("chrome8 narrow issues \(w.issueSummary.parts.map { "\($0.kind)" })")
            w.session.packageIssues = []
        case "reopen-save":
            openSample()
            w.perform(.splitEditor)
            await pause(0.8)
            if let left = w.panes.panes.first, let p = left.path, let c = PaneControllers.existing(pane: left.id, path: p) {
                c.scroll(toTopLine: 40)
                await pause(0.5)
                say("chrome8 left pane first line before save \(c.firstVisibleLine)")
            }
            await shot("reopen-before")
            w.saveWindowLayout()
        case "reopen":
            await pause(1.5)
            if let left = w.panes.panes.first, let p = left.path, let c = PaneControllers.existing(pane: left.id, path: p) {
                say("chrome8 reopened left pane first line \(c.firstVisibleLine)")
            }
            await shot("reopen-after")
        default:
            Preferences.shared.appearance = .dark
            openSample()
            await pause(0.5)
            if let e = frame("editor") { await OpenViewsAutomation.click(at: CGPoint(x: e.midX, y: e.minY + 60)) }
            say("chrome8 selected \(w.selection ?? "-") caret line \(w.editor?.buffer.caretLine ?? -1)")
            await shot("appearance-dark")
            Preferences.shared.appearance = .light
            say("chrome8 after light: selected \(w.selection ?? "-") caret line \(w.editor?.buffer.caretLine ?? -1)")
            await shot("appearance-light")
            Preferences.shared.appearance = .dark
            await shot("appearance-dark-again")
        }
    }
    #endif
}
