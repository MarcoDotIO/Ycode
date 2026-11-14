import Foundation
import SwiftUI
import YcodeBuild
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_CHROME9=<prefix>: council round 9 group A2's states
// (`fidelity-council.md` rows 214–219) on the workspace given as the path.
// YCODE_IDE_CHROME9_PART chooses:
//
//   toolbar (default)  the coding assistant button at rest and hovered, in
//                      light and dark (row 214); Open Quickly with one
//                      result (215); a Markdown and a JSON file ending
//                      their paths with "No Selection" (217)
//   narrow             run at 1100 wide: an error and a warning, the editor
//                      modes in the "»" capsule 5 after Add Editor's (218)
//   split              a split with a warning (the stepper), the window at
//                      the width given by YCODE_IDE_WINDOW_SIZE (216)
//
// Each state writes <prefix>-<state>.png and .txt (texts and identified views).
extension ShellDriver {
    #if os(Linux)
    static func chrome9Walk(_ app: ShellAppModel, prefix: String) async {
        guard let w = app.workspace else { say("chrome9: no workspace"); return }
        let part = env["YCODE_IDE_CHROME9_PART"] ?? "toolbar"
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
            say("chrome9 \(state): " + OpenViewsAutomation.screenshot(0, to: "\(prefix)-\(state).png"))
        }
        let files = w.root.allFiles.compactMap(\.path)
        func openFirstSwift() {
            guard let p = files.first(where: { $0.hasSuffix(".swift") }) else { say("chrome9: no Swift file"); return }
            if let ids = w.root.idPath(to: p) { for id in ids.dropLast() { w.setExpanded(id, true) } }
            w.selection = w.root.idPath(to: p)?.last
        }
        switch part {
        case "narrow":
            openFirstSwift()
            w.session.packageIssues = [Diagnostic(severity: .error, message: "An error"), Diagnostic(severity: .warning, message: "A warning")]
            for mode in [Preferences.Appearance.light, .dark] {
                Preferences.shared.appearance = mode
                await shot("narrow-\(mode.rawValue.lowercased())")
            }
            // The Add Editor capsule ends 4 after Editor Options' button.
            if let a = frame("tb editor options"), let o = frame("tb overflow") {
                say("chrome9 narrow: add editor capsule ends \(a.maxX + 4), overflow \(o.minX)–\(o.maxX), gap \(o.minX - a.maxX - 4)")
            }
            w.session.packageIssues = []
        case "split":
            openFirstSwift()
            w.session.packageIssues = [Diagnostic(severity: .warning, message: "A warning")]
            w.perform(.splitEditor)
            await pause(0.6)
            if let deep = files.max(by: { $0.split(separator: "/").count < $1.split(separator: "/").count }) { w.open(deep) }
            let width = Int(OpenViewsAutomation.windowSize()?.points.width ?? 0)
            for mode in [Preferences.Appearance.light, .dark] {
                Preferences.shared.appearance = mode
                await shot("split-\(width)-\(mode.rawValue.lowercased())")
            }
            w.session.packageIssues = []
        default:
            openFirstSwift()
            for mode in [Preferences.Appearance.light, .dark] {
                Preferences.shared.appearance = mode
                OpenViewsAutomation.move(to: CGPoint(x: 5, y: 600))
                await shot("assistant-\(mode.rawValue.lowercased())")
                if let f = frame("tb new conversation") {
                    OpenViewsAutomation.move(to: CGPoint(x: f.midX, y: f.midY))
                    await pause(0.4)
                    OpenViewsAutomation.move(to: CGPoint(x: f.midX + 0.5, y: f.midY))
                    await shot("assistant-hover-\(mode.rawValue.lowercased())", settle: 1.5)
                    OpenViewsAutomation.move(to: CGPoint(x: 5, y: 600))
                }
            }
            // Open Quickly with one result: the open file's name.
            let name = w.document.map { ($0.path as NSString).lastPathComponent } ?? "Sample.swift"
            for mode in [Preferences.Appearance.light, .dark] {
                Preferences.shared.appearance = mode
                w.perform(.openQuickly)
                await w.openQuickly.indexIdle()
                w.openQuickly.query = String(name.prefix(while: { $0 != "." }))
                say("chrome9 open quickly \"\(w.openQuickly.query)\": \(w.openQuickly.results.map(\.title)) height \(w.openQuickly.panelHeight)")
                await shot("open-quickly-\(mode.rawValue.lowercased())")
                if let p = frame("open quickly"), let r = frame("open quickly row 0") {
                    say("chrome9 open quickly panel \(p.minX) \(p.minY - ShellMetrics.menuBarHeight) \(p.width)×\(p.height), row \(r.minX - p.minX) \(r.minY - p.minY) \(r.width)×\(r.height)")
                }
                w.openQuickly.close()
            }
            // Markdown and JSON: "No Selection" after the file's name.
            let dir = (w.session.model.url.hasDirectoryPath ? w.session.model.url : w.session.model.url.deletingLastPathComponent()).path
            let notes = dir + "/NOTES.md", palette = dir + "/palette.json"
            if !FileManager.default.fileExists(atPath: notes) { try? "# Notes\n\nSome text.\n".write(toFile: notes, atomically: true, encoding: .utf8) }
            if !FileManager.default.fileExists(atPath: palette) { try? "{ \"accent\": \"#FF0000\" }\n".write(toFile: palette, atomically: true, encoding: .utf8) }
            for (p, tag) in [(notes, "md"), (palette, "json")] {
                w.open(p)
                say("chrome9 \(tag): last item \(w.jumpBarLastItem ?? "none")")
                for mode in [Preferences.Appearance.light, .dark] {
                    Preferences.shared.appearance = mode
                    await shot("nosel-\(tag)-\(mode.rawValue.lowercased())")
                }
            }
        }
    }
    #endif
}
