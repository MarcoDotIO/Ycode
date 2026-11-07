import Foundation
import SwiftUI
import YcodeBuild
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_CHROME5=<prefix>: council round 5's chrome states
// (`fidelity-council.md` rows 138 and 141) on a workspace given as the
// path: the file open with an error and a warning (the toolbar's issue
// capsule; at 1100 points, run with YCODE_IDE_WINDOW_SIZE=1100x880, its
// symbols only), then the activity subtitle while the language server
// starts. Writes <prefix>-issues.png, <prefix>-activity.png and a .txt of
// the texts and identified views for each.
extension ShellDriver {
    #if os(Linux)
    static func chrome5Walk(_ app: ShellAppModel, prefix: String) async {
        guard let w = app.workspace else { say("chrome5: no workspace"); return }
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
            say("chrome5 \(state): " + OpenViewsAutomation.screenshot(0, to: "\(prefix)-\(state).png"))
        }
        if let p = w.root.allFiles.compactMap(\.path).first(where: { $0.hasSuffix("/Sample.swift") }) {
            if let ids = w.root.idPath(to: p) { for id in ids.dropLast() { w.setExpanded(id, true) } }
            w.open(p)
        }
        w.session.packageIssues = [Diagnostic(severity: .error, message: "An error for the issue capsule"),
                                   Diagnostic(severity: .warning, message: "A warning for the issue capsule")]
        await shot("issues")
        w.session.packageIssues = []
        w.session.isPreparingEditorServices = true
        await shot("activity")
        w.session.isPreparingEditorServices = false
    }
    #endif
}
