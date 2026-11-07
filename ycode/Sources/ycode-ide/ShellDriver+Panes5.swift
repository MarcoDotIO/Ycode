import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_PANES5=<prefix>: council round 5's panes rows on the Linux IDE
// (`fidelity-council.md` rows 133, 135): the inspector's slide, timed (the
// inspector's left edge sampled every few milliseconds from the press; a
// second pass takes stills mid-slide), and an image's inspector. Open the
// "rest" copy of scripts/linux-ui-parity/make-parity5.sh. Writes
// <prefix>-p5-<state>.png and prints one line per step.
extension ShellDriver {
    #if os(Linux)
    static func panes5Walk(_ app: ShellAppModel, prefix: String) async {
        guard let w = app.workspace else { say("p5: no workspace"); return }
        let files = w.root.allFiles.compactMap(\.path)
        func path(_ name: String) -> String? { files.first { $0.hasSuffix("/" + name) } }
        if let p = path("Sample.swift") {
            if let ids = w.root.idPath(to: p) { for id in ids.dropLast() { w.setExpanded(id, true) } }
            w.open(p)
        }
        await pause(1.0)
        func edge() -> CGFloat? { frame("inspector").map(\.minX) }
        // Pass 1: positions only.
        for (name, wantShown) in [("hide", false), ("show", true)] {
            // The toolbar button's command, from the press.
            let start = Date()
            w.perform(.toggleInspector)
            var samples: [(Double, CGFloat)] = []
            while Date().timeIntervalSince(start) < 0.6 {
                samples.append((Date().timeIntervalSince(start) * 1000, edge() ?? -1))
                await pause(0.004)
            }
            var moves: [(Double, CGFloat)] = []
            for s in samples where moves.last?.1 != s.1 { moves.append(s) }
            say("p5 slide \(name) (shown \(w.isInspectorShown == wantShown)): " + moves.map { String(format: "%.0f:%.0f", $0.0, $0.1) }.joined(separator: " "))
            await pause(0.5)
        }
        // Pass 2: stills mid-slide.
        for (name, at) in [("hide", [0.12, 0.17]), ("show", [0.2, 0.27])] {
            w.perform(.toggleInspector)
            var last = 0.0
            for t in at {
                await pause(t - last)
                last = t
                say("p5 still \(name) \(Int(t * 1000)) ms: " + OpenViewsAutomation.screenshot(to: "\(prefix)-p5-\(name)-\(Int(t * 1000)).png"))
            }
            await pause(0.6)
        }
        // Row 135: an image's inspector.
        if let png = path("Stripes.png") { w.open(png) }
        await pause(1.0)
        say("p5 image: " + OpenViewsAutomation.screenshot(to: "\(prefix)-p5-image.png"))
    }
    #endif
}
