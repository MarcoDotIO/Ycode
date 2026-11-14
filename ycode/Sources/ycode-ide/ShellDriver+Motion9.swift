import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_MOTION9=<prefix>: council round 9, group B, on the Linux IDE
// (`fidelity-council.md` rows 220–227). Open a workspace holding the
// council's GlassScroll (a long `Long.swift`, `Bands.swift` and
// `Comments.swift`).
//
// 1. The inspector's hide and show with line 1 at the top: the editor's top
//    after each (`motion9 slide`), stills mid-hide and after.
// (The flicks are checked on the shared model, `CouncilRound9GroupBTests`,
// on both machines: positioned programmatically, the walk's pane undid the
// start position.)
// 2. Long.swift's caret at line 11, column 46; Bands.swift shown, then
//    Long.swift again: the caret (`motion9 caret`), a still.
// 3. Comments.swift: the caret in "enough" in a comment, then in the
//    declaration: the instances highlighted (`motion9 instances`), stills.
extension ShellDriver {
    #if os(Linux)
    static func motion9Walk(_ app: ShellAppModel, prefix: String) async {
        guard let w = app.workspace else { say("motion9: no workspace"); return }
        let files = w.root.allFiles.compactMap(\.path)
        func path(_ name: String) -> String? { files.first { $0.hasSuffix("/" + name) } }
        guard let long = path("Long.swift") else { say("motion9: no Long.swift"); return }
        if let ids = w.root.idPath(to: long) { for id in ids.dropLast() { w.setExpanded(id, true) } }
        w.open(long)
        await pause(1.0)
        guard let doc = w.editor else { say("motion9: no editor"); return }
        let c = SourceEditorController.of(doc)

        // 1. The slide from line 1.
        c.scroll(x: 0, y: 0)
        await pause(0.4)
        for (name, mid) in [("hide", 0.15), ("show", 0.27)] {
            let start = Date()
            w.perform(.toggleInspector)
            var tops: [Double] = []
            var shot = false
            while Date().timeIntervalSince(start) < 0.8 {
                tops.append(Double(c.top))
                if !shot, Date().timeIntervalSince(start) >= mid {
                    shot = true
                    say("motion9 still \(name)-mid: " + OpenViewsAutomation.screenshot(to: "\(prefix)-motion9-\(name)-mid.png"))
                }
                await pause(0.005)
            }
            say(String(format: "motion9 slide %@: top through the slide min %.1f max %.1f, after %.1f (line 1 at the top: %@)", name,
                       tops.min() ?? -1, tops.max() ?? -1, Double(c.top), c.top == 0 ? "yes" : "no"))
            say("motion9 still \(name)-end: " + OpenViewsAutomation.screenshot(to: "\(prefix)-motion9-\(name)-end.png"))
        }

        // 2. The caret kept per document.
        let line11 = doc.buffer.document.lineRange(10)
        doc.buffer.setCaret(line11.lowerBound + min(45, line11.count))
        w.caretMoved()
        if let bands = path("Bands.swift") { w.open(bands) }
        await pause(0.5)
        w.open(long)
        await pause(0.6)
        if let d = w.editor {
            let line = d.buffer.caretLine
            let col = d.buffer.caret - d.buffer.document.lineRange(line).lowerBound
            say("motion9 caret: Long.swift shown again at line \(line + 1), column \(col + 1)")
        }
        say("motion9 still caret: " + OpenViewsAutomation.screenshot(to: "\(prefix)-motion9-caret.png"))

        // 3. Instances of the symbol at the caret.
        guard let comments = path("Comments.swift") else { return }
        w.open(comments)
        await pause(0.5)
        guard let d = w.editor else { return }
        let text = d.buffer.text as NSString
        for (name, offset) in [("comment", text.range(of: "enough").location + 2), ("code", text.range(of: "let enough").location + 6)] {
            d.buffer.setCaret(offset)
            w.caretMoved()
            await w.symbolInstancesSettled()
            await pause(0.3)
            say("motion9 instances \(name): \(w.languageFeatures.symbolInstances.map { "\($0.location)+\($0.length)" })")
            say("motion9 still instances-\(name): " + OpenViewsAutomation.screenshot(to: "\(prefix)-motion9-instances-\(name).png"))
        }
    }
    #endif
}
