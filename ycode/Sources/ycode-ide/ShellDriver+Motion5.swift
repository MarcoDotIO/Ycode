import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_MOTION5=<prefix>: beta 5's motion layer on the Linux IDE
// (B5-MOTION; `parity-inventory.md` P-024, P-137, P-190–P-192). Open a
// workspace holding a long `Long.swift`.
//
// 1. The navigator's, the inspector's and the debug area's hide and show:
//    the pane's edge as sampled every 2 ms against the curve's start and
//    end (`motion5 slide <pane> hide|show`), the frames presented and their
//    work; stills mid-slide and after.
// 2. ⌥⌘2 on the shown inspector hides it, the next shows it
//    (`motion5 selector`).
// 3. The merge alert's drop: the alert card's top through its motion
//    (`motion5 alert`), a still mid-drop.
// 4. Narrow windows: 817, 700 and 503 points wide, the panes' widths and
//    whether the navigator is shown (`motion5 narrow`), stills.
//
// Until OpenViews draws every display frame (P-200, B5-OPENVIEWS) the
// slides show only the positions the toolkit presents: the walk reports
// them, the curves are checked on the shared model (`B5MotionTests`).
// With YCODE_IDE_MOTION5_FPS=1 it measures only each slide's frame rate
// (`motion5 fps`), with nothing else on the main thread.
extension ShellDriver {
    #if os(Linux)
    static func motion5Walk(_ app: ShellAppModel, prefix: String) async {
        guard let w = app.workspace else { say("motion5: no workspace"); return }
        let files = w.root.allFiles.compactMap(\.path)
        if let long = files.first(where: { $0.hasSuffix("/Long.swift") }) {
            if let ids = w.root.idPath(to: long) { for id in ids.dropLast() { w.setExpanded(id, true) } }
            w.open(long)
        }
        await pause(1.0)

        // 1. The slides.
        let panes: [(name: String, target: String, command: ShellCommand, curve: (Bool) -> Motion.Curve, edge: (CGRect) -> CGFloat)] = [
            ("navigator", "navigator filter", .toggleNavigator, { Motion.navigator(show: $0) }, { $0.maxX }),
            ("inspector", "inspector", .toggleInspector, { Motion.inspector(show: $0) }, { $0.minX }),
            ("debug", "debug area", .toggleDebugArea, { Motion.debugArea(show: $0) }, { $0.minY }),
        ]
        for pane in panes {
            let order: [Bool] = pane.name == "debug" ? [true, false] : [false, true]
            for show in order {
                let c = pane.curve(show)
                let frames0 = OpenViewsAutomation.presentedFrames()
                OpenViewsAutomation.frameDurations = []
                if env["YCODE_IDE_MOTION5_FPS"] != nil {
                    // The frame rate over the curve's motion: frames presented
                    // between its start and its end (no stills, no sampling).
                    w.perform(pane.command)
                    await pause(c.delay)
                    let f1 = OpenViewsAutomation.presentedFrames(), t1 = Date()
                    OpenViewsAutomation.frameDurations = []
                    await pause(c.duration)
                    let f2 = OpenViewsAutomation.presentedFrames(), t2 = Date()
                    let durations = (OpenViewsAutomation.frameDurations ?? []).sorted()
                    let span = t2.timeIntervalSince(t1)
                    let median = durations.isEmpty ? 0 : durations[durations.count / 2] * 1000
                    say("motion5 fps \(pane.name) \(show ? "show" : "hide"): \(f2 - f1) frames in \(Int(span * 1000)) ms = "
                        + "\(Int((Double(f2 - f1) / max(0.001, span)).rounded())) fps; frame work median \(Int(median.rounded())) max "
                        + "\(Int(((durations.last ?? 0) * 1000).rounded())) ms")
                    await pause(0.4)
                    continue
                }
                let edge0 = frame(pane.target).map(pane.edge)
                let start = Date()
                w.perform(pane.command)
                // A still at the curve's middle (a sampling loop is too slow
                // for a debug build on a loaded machine: the edge is read
                // at the middle and after the end).
                await pause(c.delay + c.duration / 2)
                let midMs = Date().timeIntervalSince(start) * 1000
                let edgeMid = frame(pane.target).map(pane.edge)
                say("motion5 still \(pane.name)-\(show ? "show" : "hide")-mid: "
                    + OpenViewsAutomation.screenshot(to: "\(prefix)-motion5-\(pane.name)-\(show ? "show" : "hide")-mid.png"))
                await pause(max(0, c.total + 0.25 - Date().timeIntervalSince(start)))
                let edge1 = frame(pane.target).map(pane.edge)
                let durations = OpenViewsAutomation.frameDurations ?? []
                let presented = OpenViewsAutomation.presentedFrames() - frames0
                func ms(_ v: Double) -> String { String(Int(v.rounded())) }
                func pt(_ v: CGFloat?) -> String { v.map { ms(Double($0)) } ?? "none" }
                let median = (durations.sorted().dropFirst(durations.count / 2).first ?? 0) * 1000
                say("motion5 slide \(pane.name) \(show ? "show" : "hide"): curve \(ms(c.delay * 1000)) → \(ms(c.total * 1000)) ms; "
                    + "edge \(pt(edge0)) → \(pt(edgeMid)) at \(ms(midMs)) ms → \(pt(edge1)); "
                    + "\(presented) frames presented, work median \(ms(median)) max \(ms((durations.max() ?? 0) * 1000)) ms")
                say("motion5 still \(pane.name)-\(show ? "show" : "hide")-end: "
                    + OpenViewsAutomation.screenshot(to: "\(prefix)-motion5-\(pane.name)-\(show ? "show" : "hide")-end.png"))
                await pause(0.3)
            }
        }

        if env["YCODE_IDE_MOTION5_FPS"] != nil { return }

        // 2. ⌥⌘2 on the shown inspector (P-192).
        w.toggleInspector(bySelector: w.languageFeatures.inspectorTab)
        await pause(0.6)
        let hidden = !w.isInspectorShown
        w.toggleInspector(bySelector: w.languageFeatures.inspectorTab)
        await pause(0.6)
        say("motion5 selector: hid \(hidden ? "yes" : "no"), shown again \(w.isInspectorShown ? "yes" : "no")")

        // 3. The merge alert (P-137): the card's top through its drop.
        do {
            let m = Motion.mergeAlertSheet
            let start = Date()
            w.sourceControl.presentMergeAlert(branch: "feature")
            let top0 = frame("merge alert")?.minY
            await pause(m.delay + m.duration / 2)
            let topMid = frame("merge alert")?.minY
            say("motion5 still alert-mid: " + OpenViewsAutomation.screenshot(to: "\(prefix)-motion5-alert-mid.png"))
            await pause(max(0, m.total + 0.2 - Date().timeIntervalSince(start)))
            let top1 = frame("merge alert")?.minY
            say("motion5 alert: curve \(Int(m.delay * 1000)) → \(Int(m.total * 1000)) ms; top \(top0.map { "\(Int($0))" } ?? "none") → "
                + "\(topMid.map { "\(Int($0))" } ?? "none") → \(top1.map { "\(Int($0))" } ?? "none")")
            say("motion5 still alert-end: " + OpenViewsAutomation.screenshot(to: "\(prefix)-motion5-alert-end.png"))
            w.sourceControl.cancelMergeAlert()
            await pause(0.6)
        }

        // 4. Narrow windows (P-024).
        if !w.isNavigatorShown { w.isNavigatorShown = true }
        await pause(0.5)
        for width in [1400.0, 817, 700, 503] {
            OpenViewsAutomation.resize(to: CGSize(width: width, height: 880))
            await pause(0.8)
            let size = OpenViewsAutomation.windowSize()?.points.width ?? 0
            let navEdge = frame("navigator filter").map { Double($0.maxX) }
            let nav = w.isNavigatorShown ? navEdge.map { "edge \(Int($0))" } ?? "?" : "hidden"
            let editor = frame("source").map { String(format: "%.1f", Double($0.width)) } ?? "?"
            let insp = w.isInspectorShown ? frame("inspector").map { String(format: "%.1f", Double(size) - Double($0.minX)) } ?? "?" : "hidden"
            say("motion5 narrow \(Int(width)) (window \(Int(size))): navigator \(nav), editor \(editor), inspector \(insp)")
            say("motion5 still narrow-\(Int(width)): " + OpenViewsAutomation.screenshot(to: "\(prefix)-motion5-narrow-\(Int(width)).png"))
        }
        OpenViewsAutomation.resize(to: CGSize(width: 1400, height: 880))
        await pause(0.6)
        say("motion5 narrow back to 1400: navigator \(w.isNavigatorShown ? "shown" : "hidden")")
    }
    #else
    static func motion5Walk(_ app: ShellAppModel, prefix: String) async {}
    #endif
}
