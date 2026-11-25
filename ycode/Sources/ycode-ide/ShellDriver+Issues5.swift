import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_ISSUES5=<prefix>: P-120's states (`specs/ide/issues.md`) on the
// workspace given as the path (an unbuilt project whose settings differ
// from the recommended set), in light then dark:
//
//   live        the Issue navigator with the project row and the warning,
//               a file open (the jump bar's stepper), the toolbar capsule
//   checklist   the warning's row clicked: the checklist sheet
//   cancelled   Cancel: the sheet gone, the warning still there
//
// Each state writes <prefix>-<state>-<appearance>.png and .txt (texts and
// identified views). Nothing is written to the project.
extension ShellDriver {
    #if os(Linux)
    static func issues5Walk(_ app: ShellAppModel, prefix: String) async {
        guard let w = app.workspace else { say("issues5: no workspace"); return }
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
            say("issues5 \(state): " + OpenViewsAutomation.screenshot(0, to: "\(prefix)-\(state).png"))
        }
        let source = w.root.allFiles.compactMap(\.path).first { $0.hasSuffix(".swift") }
        for appearance in [Preferences.Appearance.light, .dark] {
            Preferences.shared.appearance = appearance
            let name = appearance == .light ? "light" : "dark"
            if let source { w.open(source) }
            w.showNavigator(.issues)
            say("issues5 \(name) counts \(w.issueCounts) groups \(w.issueGroups.map { "\($0.title) \($0.countText) \($0.issues.map(\.message))" })")
            await shot("live-\(name)")
            w.issueSelection = nil
            w.issueSelection = w.allIssues.first { $0.file == nil }?.id
            say("issues5 \(name) sheet \(w.recommendedSettings.isShown) rows \(w.recommendedSettings.checklist?.rows.map(\.id) ?? [])")
            await shot("checklist-\(name)")
            w.recommendedSettings.cancel()
            await shot("cancelled-\(name)")
            say("issues5 \(name) after cancel counts \(w.issueCounts)")
        }
    }
    #endif
}
