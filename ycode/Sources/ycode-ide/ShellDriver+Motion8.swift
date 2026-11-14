import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_MOTION8=<prefix>: council round 8, group B, on the Linux IDE
// (`fidelity-council.md` rows 204–207). Open a workspace holding the
// council's GlassScroll (a long `Long.swift` and `Bands.swift`).
//
// 1. The inspector's hide and show: the frames presented while it slides,
//    each frame's work and the longest, the edge's positions as sampled
//    (`motion8 slide hide|show`); stills mid-slide.
// 2. X05 (the slow flick) from 600 below the top: where the text comes to
//    rest (`motion8 x05`); main 04 (the fast flick): the stretch past the
//    top and when it is back (`motion8 m04`).
// 3. Selecting Bands.swift, then Long.swift: the time from the open to the
//    first frame presented after it, that frame's work, and whether the
//    editor and the inspector both show the file in it (`motion8 select`).
extension ShellDriver {
    #if os(Linux)
    static func motion8Walk(_ app: ShellAppModel, prefix: String) async {
        guard let w = app.workspace else { say("motion8: no workspace"); return }
        let files = w.root.allFiles.compactMap(\.path)
        func path(_ name: String) -> String? { files.first { $0.hasSuffix("/" + name) } }
        guard let long = path("Long.swift") else { say("motion8: no Long.swift"); return }
        if let ids = w.root.idPath(to: long) { for id in ids.dropLast() { w.setExpanded(id, true) } }
        w.open(long)
        await pause(1.0)
        OpenViewsAutomation.frameDurations = []
        let phase = env["YCODE_IDE_SAMPLE_PHASE"]
        // A profile of the slide's frames (YCODE_IDE_SAMPLE, MainThreadSampler.swift).
        if phase == "slide" {
            MainThreadSampler.startIfAsked()
            for _ in 0..<12 {
                w.perform(.toggleInspector)
                await pause(0.6)
            }
            MainThreadSampler.stop()
        }

        // 1. The slide.
        for (name, delayStill) in [("hide", 0.15), ("show", 0.27)] {
            let frames0 = OpenViewsAutomation.presentedFrames()
            OpenViewsAutomation.frameDurations = []
            let start = Date()
            w.perform(.toggleInspector)
            var edges: [(Double, CGFloat)] = []
            var still = false
            while Date().timeIntervalSince(start) < 0.7 {
                let ms = Date().timeIntervalSince(start) * 1000
                let x = frame("inspector")?.minX ?? -1
                if edges.last?.1 != x { edges.append((ms, x)) }
                if !still, ms >= delayStill * 1000 {
                    still = true
                    say("motion8 still \(name): " + OpenViewsAutomation.screenshot(to: "\(prefix)-motion8-\(name).png"))
                }
                await pause(0.002)
            }
            let durations = OpenViewsAutomation.frameDurations ?? []
            let presented = OpenViewsAutomation.presentedFrames() - frames0
            let moving = edges.count
            say(String(format: "motion8 slide %@: %d frames presented in 700 ms, frame work median %.1f max %.1f ms; edge %@", name, presented,
                       (durations.sorted().dropFirst(durations.count / 2).first ?? 0) * 1000, (durations.max() ?? 0) * 1000,
                       edges.map { String(format: "%.0f:%.0f", $0.0, Double($0.1)) }.joined(separator: " ")))
            say("motion8 slide \(name) positions sampled: \(moving)")
            await pause(0.4)
        }

        // 2. The flicks.
        guard let doc = w.editor, let source = frame("source") else { say("motion8: no editor"); return }
        let c = SourceEditorController.of(doc)
        let center = CGPoint(x: source.midX, y: source.midY)
        func flick(_ name: String, step: Double, points: Double, n: Int, span: Double) async {
            c.scroll(x: 0, y: 600)
            await pause(0.5)
            var frames: [(TimeInterval, CGFloat)] = []
            c.frameProbe = { t, y in frames.append((t, y)) }
            let t0 = OpenViewsAutomation.now
            for e in Self.flick7(at: center, t0: t0, step: step, points: points, n: n, span: span) { OpenViewsAutomation.postScroll(e) }
            await pause(1.8)
            c.frameProbe = nil
            let curve = frames.map { (ms: ($0.0 - t0) * 1000, y: Double($0.1)) }
            let peak = -(curve.map(\.y).min() ?? 0)
            let back = curve.last { $0.y != 0 }?.ms ?? -1
            say(String(format: "motion8 %@: rest %.1f below the top (travel %.1f of 600), stretch %.1f, last frame past the top %.0f ms after posting",
                       name, Double(c.top), 600 - Double(c.top), max(0, peak), back))
        }
        await flick("x05", step: 15, points: 566.7, n: 134, span: 1.11)
        await flick("m04", step: 40, points: 1544, n: 173, span: 1.43)

        // 3. Selection.
        if phase == "select", let a = path("Bands.swift") {
            MainThreadSampler.startIfAsked()
            for i in 0..<12 {
                w.open(i % 2 == 0 ? a : long)
                await pause(0.6)
            }
            MainThreadSampler.stop()
        }
        for name in ["Bands.swift", "Long.swift", "Bands.swift"] {
            guard let p = path(name) else { continue }
            let frames0 = OpenViewsAutomation.presentedFrames()
            OpenViewsAutomation.frameDurations = []
            let start = Date()
            w.open(p)
            let call = Date().timeIntervalSince(start) * 1000
            while OpenViewsAutomation.presentedFrames() == frames0, Date().timeIntervalSince(start) < 2 { await pause(0.001) }
            let first = Date().timeIntervalSince(start) * 1000
            // The File inspector is drawn from the same model state as the
            // editor (`fileInspector` from `document`), so one update shows both.
            let editorShows = w.document?.path == p
            let inspectorShows = w.document?.path == p && !w.fileInspector.isEmpty
            say(String(format: "motion8 select %@: call %.1f ms, first frame after %.1f ms (its work %.1f ms); editor %@, inspector %@ in it", name, call, first,
                       (OpenViewsAutomation.frameDurations?.first ?? 0) * 1000, editorShows ? "yes" : "no", inspectorShows ? "yes" : "no"))
            await pause(0.5)
        }
        say("motion8 select shot: " + OpenViewsAutomation.screenshot(to: "\(prefix)-motion8-select.png"))
        OpenViewsAutomation.frameDurations = nil
    }
    #endif
}
