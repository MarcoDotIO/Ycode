import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_CHROME10=<prefix>: council round 10 group A's states
// (`fidelity-council.md` rows 236–247) on the workspace given as the path
// (the council's GlassScroll project with convert.py, NOTES.md,
// palette.json and an image beside Long.swift), in light and dark:
//
//   navigator     every row open: the picture and Python glyphs on whole
//                 pixels, the dark navigator's #28282A (rows 243–245)
//   jump-bar      Long.swift open: the grid, the divider, the path from 49
//                 and its 3 × 10 chevrons (row 247)
//   markdown      NOTES.md open: the jump bar's book (row 246)
//   json          palette.json open: the jump bar's JSON glyph in red (246)
//   open-quickly  Open Quickly on "long": the row's type (row 242)
//   assistant     the coding assistant button hovered (rows 238–239)
//   ring          the build ring at "Building • 36/55" (rows 236–237)
//
// Each state writes <prefix>-<state>-<appearance>.png and .txt (texts and
// identified views).
extension ShellDriver {
    #if os(Linux)
    static func chrome10Walk(_ app: ShellAppModel, prefix: String) async {
        guard let w = app.workspace else { say("chrome10: no workspace"); return }
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
            say("chrome10 \(state): " + OpenViewsAutomation.screenshot(0, to: "\(prefix)-\(state).png"))
        }
        let files = w.root.allFiles.compactMap(\.path)
        func path(_ name: String) -> String? { files.first { $0.hasSuffix("/" + name) } }
        func open(_ name: String) {
            guard let p = path(name) else { say("chrome10: no \(name)"); return }
            if let ids = w.root.idPath(to: p) { for id in ids.dropLast() { w.setExpanded(id, true) } }
            w.selection = w.root.idPath(to: p)?.last
        }
        for r in w.projectRows where r.isExpandable && !r.isExpanded { w.setExpanded(r.id, true) }
        await pause(0.5)
        for r in w.projectRows where r.isExpandable && !r.isExpanded { w.setExpanded(r.id, true) }
        for mode in [Preferences.Appearance.light, .dark] {
            Preferences.shared.appearance = mode
            let a = mode.rawValue.lowercased()
            OpenViewsAutomation.move(to: CGPoint(x: 5, y: 600))
            open("Long.swift")
            await shot("navigator-\(a)")
            for id in ["jump bar grid", "jump bar divider", "jump path icon 0"] {
                if let f = frame(id) { say("chrome10 \(a) \(id): \(String(format: "%.1f–%.1f × %.1f", f.minX, f.maxX, f.height))") }
            }
            if let bar = frame("jump bar") { say("chrome10 \(a) jump bar from \(bar.minX)") }
            await shot("jump-bar-\(a)", settle: 0.2)
            open("NOTES.md")
            await shot("markdown-\(a)")
            open("palette.json")
            await shot("json-\(a)")
            open("Long.swift")
            w.perform(.openQuickly)
            await w.openQuickly.indexIdle()
            w.openQuickly.query = "Long"
            await shot("open-quickly-\(a)")
            w.openQuickly.close()
            if let f = frame("tb new conversation") {
                OpenViewsAutomation.move(to: CGPoint(x: f.midX, y: f.midY))
                await shot("assistant-\(a)", settle: 0.4)
                OpenViewsAutomation.move(to: CGPoint(x: 5, y: 600))
            }
            w.session.noteToolActivity(.building(WorkspaceSession.BuildActivityText.accepted))
            await pause(0.3)
            if let f = frame("title mark") { say("chrome10 \(a) ring before the count: \(f)") }
            w.session.noteToolActivity(.building(WorkspaceSession.BuildActivityText.progress(done: 36, total: 55)))
            await shot("ring-\(a)", settle: 0.6)
            if let f = frame("title mark") { say("chrome10 \(a) ring at 36/55: \(f)") }
            w.session.noteToolActivity(.idle)
            await pause(0.3)
        }
    }
    #endif
}
