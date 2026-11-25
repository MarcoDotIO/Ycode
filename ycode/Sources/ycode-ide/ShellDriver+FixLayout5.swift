import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_FIXLAYOUT5=<prefix>: B5-FIX-LAYOUT's states (council round 12;
// `window-layout.md` §2.3, §4, §5, §6) on the workspace given as the path,
// dark:
//
//   shown, hidden        the toolbar at 1400 with the navigator shown and
//                        hidden: the group, Run | Stop and Back | Forward's
//                        frames, no "»" (P-190, §5.1)
//   hide-mid, show-mid   the navigator half-way through its slide after a
//                        click on the Navigators half: the toolbar already
//                        (hide) or still (show) in the hidden arrangement
//   debug-mid            the debug area half-way through its show (P-191)
//   drag-<w>             a narrowing in 25-point steps with the inspector
//                        hidden: the width at which the navigator collapses,
//                        each stage of the center row, the minimum (P-024,
//                        P-025)
//
// Each state writes <prefix>-<state>.png and .txt; the walk prints frames.
extension ShellDriver {
    #if os(Linux)
    static func fixLayout5Walk(_ app: ShellAppModel, prefix: String) async {
        guard let w = app.workspace else { say("fixlayout5: no workspace"); return }
        Preferences.shared.appearance = .dark
        let top = ShellMetrics.menuBarHeight
        func shot(_ state: String, settle: Double = 0.6) async {
            await pause(settle)
            var lines: [String] = []
            func box(_ f: CGRect) -> String { String(format: "%.1f %.1f %.1f %.1f", f.minX, f.minY - top, f.width, f.height) }
            for (id, f) in OpenViewsAutomation.identifiedFrames(0).sorted(by: { $0.key < $1.key }) where f.width > 0 {
                lines.append("view \(box(f)) id=\(id.replacingOccurrences(of: " ", with: "_"))")
            }
            try? lines.joined(separator: "\n").write(toFile: "\(prefix)-\(state).txt", atomically: true, encoding: .utf8)
            say("fixlayout5 \(state): " + OpenViewsAutomation.screenshot(0, to: "\(prefix)-\(state).png"))
        }
        func frames() -> String {
            let f = OpenViewsAutomation.identifiedFrames(0)
            func x(_ id: String) -> String { f[id].flatMap { $0.width > 0 ? String(format: "%.1f–%.1f", $0.minX, $0.maxX) : nil } ?? "-" }
            let overflow = (0..<CenterToolbar.stages.count).first { (f["tb overflow \($0)"]?.width ?? 0) > 0 }
            return "group \(x("tb navigator"))/\(x("tb assistant")), run \(x("tb run")), back \(x("tb back")), "
                + "» \(overflow.map { "stage \($0): \(CenterToolbar.stages[$0].out.map(\.rawValue))" } ?? "none"), navigator \(w.isNavigatorShown)"
        }
        func resize(_ width: Double) async {
            OpenViewsAutomation.resize(0, to: CGSize(width: width, height: 880))
            await pause(0.5)
        }
        OpenViewsAutomation.move(to: CGPoint(x: 5, y: 600))
        await resize(1400)
        if !w.isNavigatorShown { w.isNavigatorShown = true; await pause(0.6) }
        say("fixlayout5 shown 1400: \(frames())")
        await shot("shown")
        // P-190: a click on the Navigators half hides it with its slide.
        let hide = Motion.navigator(show: false, trigger: .click)
        PaneMotion.noteNavigatorClick()
        w.showLeftPane(assistant: false)
        await pause(hide.delay + hide.duration / 2)
        say("fixlayout5 hide-mid: \(frames())")
        await shot("hide-mid", settle: 0)
        await pause(0.5)
        say("fixlayout5 hidden 1400: \(frames())")
        await shot("hidden")
        let show = Motion.navigator(show: true, trigger: .click)
        PaneMotion.noteNavigatorClick()
        w.showLeftPane(assistant: false)
        await pause(show.delay + show.duration / 2)
        say("fixlayout5 show-mid: \(frames())")
        await shot("show-mid", settle: 0)
        await pause(0.5)
        say("fixlayout5 shown again: \(frames())")
        // P-191: the debug area half-way.
        let debug = Motion.debugArea(show: true)
        w.perform(.toggleDebugArea)
        await pause(debug.delay + debug.duration / 2)
        await shot("debug-mid", settle: 0)
        await pause(0.4)
        w.perform(.toggleDebugArea)
        await pause(0.5)
        // P-024, P-025: narrowing with the inspector hidden (round 12 (a)).
        if w.isInspectorShown { w.perform(.toggleInspector); await pause(0.6) }
        var width = 1400.0
        var lastStage = ""
        while width >= 400 {
            await resize(width)
            let line = frames()
            let stage = line.components(separatedBy: "» ").last ?? ""
            if stage != lastStage || width <= 625 {
                say("fixlayout5 drag \(Int(width)) (window \(OpenViewsAutomation.windowSize(0).map { "\($0.points.width)" } ?? "-")): \(line)")
                lastStage = stage
            }
            if [817.0, 600, 575, 500, 425].contains(width) { await shot("drag-\(Int(width))", settle: 0.3) }
            width -= 25
        }
        await resize(1400)
        say("fixlayout5 widened: navigator \(w.isNavigatorShown)")
        w.perform(.toggleInspector)
        await pause(0.6)
    }
    #endif
}
