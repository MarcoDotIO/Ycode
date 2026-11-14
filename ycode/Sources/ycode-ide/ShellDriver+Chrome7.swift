import Foundation
import SwiftUI
import YcodeBuild
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_CHROME7=<prefix>: council round 7 group D's states
// (`fidelity-council.md` rows 186–195) on the workspace given as the path,
// opened with its saved user data: the window as restored (the split, the
// active pane, the File inspector and its Widths row), the navigator's
// logos and the Ycode mark with every row open, the indexing subtitle,
// the merge alert over the window with an issue (the capsule dimmed at the
// glyphs' tone). Welcome: run without a path and OV_SCREENSHOT.
// Writes <prefix>-<state>.png and a .txt of the texts and identified views.
extension ShellDriver {
    #if os(Linux)
    static func chrome7Walk(_ app: ShellAppModel, prefix: String) async {
        guard let w = app.workspace else { say("chrome7: no workspace"); return }
        func shot(_ state: String) async {
            await pause(0.8)
            let top = ShellMetrics.menuBarHeight
            var lines: [String] = []
            func box(_ f: CGRect) -> String { String(format: "%.1f %.1f %.1f %.1f", f.minX, f.minY - top, f.width, f.height) }
            for t in OpenViewsAutomation.texts(0) where !t.text.isEmpty { lines.append("text \"\(t.text)\" \(box(t.frame))") }
            for (id, f) in OpenViewsAutomation.identifiedFrames(0).sorted(by: { $0.key < $1.key }) {
                lines.append("view \(box(f)) id=\(id.replacingOccurrences(of: " ", with: "_"))")
            }
            try? lines.joined(separator: "\n").write(toFile: "\(prefix)-\(state).txt", atomically: true, encoding: .utf8)
            say("chrome7 \(state): " + OpenViewsAutomation.screenshot(0, to: "\(prefix)-\(state).png"))
        }
        say("chrome7 restored panes \(w.panes.panes.map { ($0.path as NSString?)?.lastPathComponent ?? "-" }) focused \(w.panes.focused) "
            + "title \(w.windowTitle) inspector \(w.isInspectorShown) tab \(w.languageFeatures.inspectorTab.rawValue)")
        await shot("reopen")
        func ids(_ item: NavigatorItem) -> [String] { (item.children == nil ? [] : [item.id]) + (item.children ?? []).flatMap(ids) }
        for id in ids(w.root) { w.setExpanded(id, true) }
        await shot("navigator-logos")
        w.session.isIndexing = true
        await shot("indexing")
        w.session.isIndexing = false
        w.session.packageIssues = [Diagnostic(severity: .error, message: "An error for the issue capsule")]
        w.sourceControl.presentMergeAlert(branch: "feature")
        await shot("alert-capsule")
        w.sourceControl.cancelMergeAlert()
        w.session.packageIssues = []
    }
    #endif
}
