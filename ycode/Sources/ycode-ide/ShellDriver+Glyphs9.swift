import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_GLYPHS9=<prefix>: council round 9 group A1's states
// (`fidelity-council.md` rows 208–213) on the workspace given as the path
// (the council's GlassScroll project with Bands.swift, convert.py,
// NOTES.md and palette.json beside Long.swift). OV_COLOR_SCHEME chooses
// the appearance. States:
//
//   navigator         every row open, nothing selected: the line-art
//                     glyphs in their tints, the folders, the project's mark
//   markdown-focused  NOTES.md clicked in the navigator: white on the band
//   swift-unfocused   Long.swift opened, then a click in the editor: the
//                     unfocused tint on the grey band; the jump bar's glyphs
//   json              palette.json open: the JSON glyph in the navigator
//                     and the jump bar
//   building          Product ▸ Build just started: the title's build ring
//
// Each state writes <prefix>-<state>.png and .txt (texts and identified views).
extension ShellDriver {
    #if os(Linux)
    static func glyphs9Walk(_ app: ShellAppModel, prefix: String) async {
        guard let w = app.workspace else { say("glyphs9: no workspace"); return }
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
            say("glyphs9 \(state): " + OpenViewsAutomation.screenshot(0, to: "\(prefix)-\(state).png"))
        }
        let files = w.root.allFiles.compactMap(\.path)
        func path(_ name: String) -> String? { files.first { $0.hasSuffix("/" + name) } }
        // Every row open.
        for r in w.projectRows where r.isExpandable && !r.isExpanded { w.setExpanded(r.id, true) }
        await pause(0.5)
        for r in w.projectRows where r.isExpandable && !r.isExpanded { w.setExpanded(r.id, true) }
        say("glyphs9 rows \(w.projectRows.map { "\($0.title):\($0.icon.map { "\($0)" } ?? "-")" })")
        await shot("navigator")
        // The row's title (its extension may be hidden).
        let notes = w.projectRows.first { $0.title == "NOTES.md" || $0.title == "NOTES" }?.title ?? "NOTES.md"
        await click("row \(notes)")
        say("glyphs9 selected \(w.selection ?? "-")")
        await shot("markdown-focused")
        if let p = path("Long.swift") {
            w.selection = w.root.idPath(to: p)?.last
            await pause(0.6)
            if let e = frame("source") ?? frame("editor") { await OpenViewsAutomation.click(at: CGPoint(x: e.midX, y: e.minY + 60)) }
        }
        await shot("swift-unfocused")
        if let p = path("palette.json") {
            w.selection = w.root.idPath(to: p)?.last
        }
        await shot("json")
        w.perform(.build)
        await pause(0.15)
        say("glyphs9 busy \(w.isBusy)")
        await shot("building", settle: 0.1)
    }
    #endif
}
