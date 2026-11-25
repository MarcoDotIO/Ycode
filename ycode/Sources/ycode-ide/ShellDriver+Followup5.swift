import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_FOLLOWUP5=<prefix>: B5-FOLLOWUP on the Linux IDE. Open a
// workspace holding a long Swift file (`Long.swift`, 300+ lines).
//
// 1. Run | Stop (control-states.md, the Run row): Run under the pointer
//    (`followup5-run-hover`: the divider between Run and Stop is gone),
//    Run held (`followup5-run-held`: the held fill and grow; released off
//    the control, so nothing runs).
// 2. P-199: selecting the long file and a short one in the model: the
//    call and the first frame presented after it (`followup5 select`).
// 3. P-024: a narrowing drag from 1400 to 503 points in steps: the
//    navigator's and inspector's widths, the editor's, whether Run is in
//    the toolbar (`followup5 narrow`), stills at 817, 700 and 503.
extension ShellDriver {
    #if os(Linux)
    static func followup5Walk(_ app: ShellAppModel, prefix: String) async {
        guard let w = app.workspace else { say("followup5: no workspace"); return }
        func frame(_ name: String) -> CGRect? {
            let all = OpenViewsAutomation.identifiedFrames()
            return all[name] ?? all[name.replacingOccurrences(of: " ", with: "_")]
        }
        func shot(_ name: String) async {
            await pause(0.4)
            say("followup5 \(name): " + OpenViewsAutomation.screenshot(to: "\(prefix)-followup5-\(name).png"))
        }

        // 1. Run's hover and held look.
        if let run = frame("tb run") {
            OpenViewsAutomation.move(to: CGPoint(x: 5, y: 600))
            await shot("run-rest")
            OpenViewsAutomation.move(to: CGPoint(x: run.midX, y: run.midY))
            await shot("run-hover")
            OpenViewsAutomation.mouse(.down, at: CGPoint(x: run.midX, y: run.midY))
            await shot("run-held")
            OpenViewsAutomation.mouse(.moved, at: CGPoint(x: run.midX, y: run.maxY + 300))
            await pause(0.2)
            OpenViewsAutomation.mouse(.up, at: CGPoint(x: run.midX, y: run.maxY + 300))
            await pause(0.4)
            say("followup5 run released off the control: running \(w.isEnabled(.stop))")
        } else {
            say("followup5: no Run button")
        }

        // 2. P-199: the model's selection → the first frame after it.
        let files = w.root.allFiles.compactMap(\.path)
        let long = files.first { $0.hasSuffix("Long.swift") }
        let short = files.first { $0.hasSuffix(".swift") && $0 != long }
        for path in [short, long, short, long, short, long].compactMap({ $0 }) {
            let frames0 = OpenViewsAutomation.presentedFrames()
            let start = Date()
            w.open(path)
            let call = Date().timeIntervalSince(start) * 1000
            while OpenViewsAutomation.presentedFrames() == frames0, Date().timeIntervalSince(start) < 2 { await pause(0.001) }
            let first = Date().timeIntervalSince(start) * 1000
            let lines = w.editor?.buffer.lineCount ?? 0
            say(String(format: "followup5 select %@ (%d lines): call %.1f ms, first frame after %.1f ms", (path as NSString).lastPathComponent, lines, call, first))
            await pause(0.6)
        }

        // 3. P-024: a narrowing drag.
        if !w.isNavigatorShown { w.isNavigatorShown = true }
        w.isInspectorShown = true
        OpenViewsAutomation.resize(to: CGSize(width: 1400, height: 880))
        await pause(0.8)
        var width = 1400.0
        while width >= 503 {
            OpenViewsAutomation.resize(to: CGSize(width: width, height: 880))
            await pause(0.25)
            let size = OpenViewsAutomation.windowSize()?.points.width ?? 0
            let nav = w.isNavigatorShown ? frame("navigator column").map { String(format: "%.1f", Double($0.width)) } ?? "?" : "hidden"
            let editor = frame("source").map { String(format: "%.1f", Double($0.width)) } ?? "?"
            let insp = w.isInspectorShown ? frame("inspector").map { String(format: "%.1f", Double(size) - Double($0.minX)) } ?? "?" : "hidden"
            let run = frame("tb run").map { $0.width > 0 ? "run shown" : "run out" } ?? "run out"
            say("followup5 narrow \(Int(width)) (window \(Int(size))): navigator \(nav), editor \(editor), inspector \(insp), \(run)")
            if [817.0, 700, 503].contains(width) { await shot("narrow-\(Int(width))") }
            width = width > 900 ? width - 100 : (width == 900 ? 850 : (width == 850 ? 817 : (width == 817 ? 800 : width - 25)))
            if width < 503, width > 478 { width = 503 }
        }
        OpenViewsAutomation.resize(to: CGSize(width: 1400, height: 880))
        await pause(0.6)
        say("followup5 narrow back to 1400: navigator \(w.isNavigatorShown ? "shown" : "hidden")")
    }
    #else
    static func followup5Walk(_ app: ShellAppModel, prefix: String) async {}
    #endif
}
