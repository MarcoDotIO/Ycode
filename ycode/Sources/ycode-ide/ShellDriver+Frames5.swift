import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_FRAMES5=<prefix>: B5-OPENVIEWS's frame-pipeline measurements
// (`parity-inventory.md` P-200, P-211; `docs/beta5/b5-openviews.md`). Open a
// workspace with `Long.swift` and `Bands.swift` and a few dozen other files.
// Each line reads "frames5 <name>: …"; run a release build.
//
// 1. Slides: the inspector's hide and show, and a navigator slide (the
//    navigator's divider dragged 200 points in and back over 300 ms each, a
//    pointer move per 8 ms: every frame lays the navigator, the editor and
//    the toolbar out at a new width, as a slide does). For each: the frames
//    presented, their rate (frames per second from the first to the last),
//    each frame's work (median and longest) and the longest gap. Nothing is
//    looked up while it runs (frame lookups build the accessibility tree,
//    which costs the main thread as much as a frame).
// 2. A list selection change: clicking file rows in the project navigator
//    in turn: the time from the click to the first frame presented after it,
//    and that frame's work.
// 3. Latencies (P-211): opening a file (the model's open), Split Editor,
//    Open Quickly, the find bar: the time to the first frame and its work.
//
// `YCODE_IDE_SAMPLE=<file>` with `YCODE_IDE_FRAMES5_PROFILE=slide|select`
// samples the main thread over 12 repetitions of that part
// (MainThreadSampler.swift).
extension ShellDriver {
    #if os(Linux)
    static func frames5Walk(_ app: ShellAppModel, prefix: String) async {
        guard let w = app.workspace else { say("frames5: no workspace"); return }
        let files = w.root.allFiles.compactMap(\.path)
        func path(_ name: String) -> String? { files.first { $0.hasSuffix("/" + name) } }
        guard let long = path("Long.swift") else { say("frames5: no Long.swift"); return }
        for f in files { if let ids = w.root.idPath(to: f) { for id in ids.dropLast() { w.setExpanded(id, true) } } }
        w.open(long)
        await pause(1.0)
        let profile = env["YCODE_IDE_FRAMES5_PROFILE"]
        let ids = OpenViewsAutomation.identifiedFrames()
        say("frames5 targets: " + ids.keys.filter { $0.hasPrefix("row") || $0.contains("navigator") || $0.contains("inspector") }.sorted()
            .prefix(40).joined(separator: ", "))

        // 1. Slides.
        if profile == "slide" {
            MainThreadSampler.startIfAsked()
            for _ in 0..<12 {
                w.perform(.toggleInspector)
                await pause(0.6)
            }
            MainThreadSampler.stop()
        }
        for name in ["hide", "show"] {
            await frames5Slide("inspector-\(name)", track: "inspector", edge: \.minX) { w.perform(.toggleInspector) }
            await pause(0.4)
        }
        _ = OpenViewsAutomation.screenshot(to: "\(prefix)-frames5-rest.png")
        if let filter = frame("navigator filter") {
            // The navigator's divider: at the navigator column's width.
            let y = filter.minY - 200, x0 = CGFloat(WorkspaceChrome.navigatorWidth) + 0.5
            let drag: () async -> Void = {
                OpenViewsAutomation.pointer(.down, at: CGPoint(x: x0, y: y))
                await pause(0.02)
                for (from, to) in [(0.0, -200.0), (-200.0, 0.0)] {
                    let steps = 38
                    for i in 1...steps {
                        let p = Double(i) / Double(steps)
                        OpenViewsAutomation.pointer(.moved, at: CGPoint(x: x0 + from + (to - from) * p, y: y))
                        await pause(0.008)
                    }
                }
                OpenViewsAutomation.pointer(.up, at: CGPoint(x: x0, y: y))
            }
            if profile == "drag" {
                MainThreadSampler.startIfAsked()
                for _ in 0..<6 { await drag(); await pause(0.3) }
                MainThreadSampler.stop()
            }
            await frames5Slide("navigator-slide", ms: 900, track: "navigator filter", edge: \.maxX, drag)
            await pause(0.4)
        }

        // 2. Selection in the project navigator.
        let names = files.map { ($0 as NSString).lastPathComponent }.filter { $0.hasSuffix(".swift") }
        let rowFrames = OpenViewsAutomation.identifiedFrames()
        let rows = names.prefix(12).compactMap { n in rowFrames["row \((n as NSString).deletingPathExtension)"].map { (n, $0) } }
        if profile == "select", !rows.isEmpty {
            MainThreadSampler.startIfAsked()
            for i in 0..<12 {
                let r = rows[i % max(rows.count, 1)].1
                OpenViewsAutomation.pointer(.down, at: CGPoint(x: r.midX, y: r.midY))
                OpenViewsAutomation.pointer(.up, at: CGPoint(x: r.midX, y: r.midY))
                await pause(0.6)
            }
            MainThreadSampler.stop()
        }
        var select: [(Double, Double)] = []
        for (n, r) in rows.prefix(8) {
            let (first, work) = await frames5First {
                OpenViewsAutomation.pointer(.down, at: CGPoint(x: r.midX, y: r.midY))
                OpenViewsAutomation.pointer(.up, at: CGPoint(x: r.midX, y: r.midY))
            }
            select.append((first, work))
            say(String(format: "frames5 select %@: first frame %.1f ms after the click, its work %.1f ms; document %@", n, first, work,
                       w.document?.name ?? "none"))
            await pause(0.5)
        }
        if !select.isEmpty {
            let firsts = select.map(\.0).sorted(), works = select.map(\.1).sorted()
            say(String(format: "frames5 select summary: first frame median %.1f ms, work median %.1f max %.1f ms",
                       firsts[firsts.count / 2], works[works.count / 2], works.last ?? 0))
        }
        _ = OpenViewsAutomation.screenshot(to: "\(prefix)-frames5-select.png")

        // 3. Latencies.
        if let bands = path("Bands.swift") {
            for (i, p) in [bands, long, bands, long].enumerated() {
                let (first, work) = await frames5First { w.open(p) }
                say(String(format: "frames5 open-%d %@: first frame %.1f ms, its work %.1f ms", i, (p as NSString).lastPathComponent, first, work))
                await pause(0.5)
            }
        }
        let latencies: [(String, () -> Void, () -> Void)] = [
            ("split", { w.perform(.splitEditor) }, { if let last = w.panes.panes.last, w.panes.panes.count > 1 { w.closePane(last.id) } }),
            ("openquickly", { OpenViewsAutomation.press(.character("o"), modifiers: [.control, .shift]) }, { OpenViewsAutomation.press(.escape) }),
            ("findbar", { OpenViewsAutomation.press(.character("f"), modifiers: [.control]) }, { w.findBar.isShown = false }),
        ]
        for (name, act, back) in latencies {
            for i in 0..<3 {
                let (first, work) = await frames5First(act)
                say(String(format: "frames5 %@-%d: first frame %.1f ms, its work %.1f ms", name, i, first, work))
                if i == 0 { _ = OpenViewsAutomation.screenshot(to: "\(prefix)-frames5-\(name).png") }
                await pause(0.4)
                back()
                await pause(0.5)
            }
        }
        OpenViewsAutomation.frameDurations = nil
    }

    /// Runs `action`, then waits for the first frame presented after it:
    /// the time from the action to that frame and the frame's work (ms).
    static func frames5First(_ action: () async -> Void) async -> (Double, Double) {
        let f0 = OpenViewsAutomation.presentedFrames()
        OpenViewsAutomation.frameDurations = []
        let start = Date()
        await action()
        while OpenViewsAutomation.presentedFrames() == f0, Date().timeIntervalSince(start) < 3 { await pause(0.0005) }
        let first = Date().timeIntervalSince(start) * 1000
        let work = (OpenViewsAutomation.frameDurations ?? []).max() ?? 0
        OpenViewsAutomation.frameDurations = nil
        return (first, work * 1000)
    }

    /// Runs `action` and samples for `ms`: the frames presented after it,
    /// their rate from the first to the last, each frame's work and the
    /// longest gap. Nothing else runs on the main thread meanwhile (no
    /// frame lookups: they build the accessibility tree). With `track`,
    /// the tracked view's edge is read once at the end.
    static func frames5Slide(_ name: String, ms: Double = 800, track: String, edge: KeyPath<CGRect, CGFloat>,
                             _ action: () async -> Void) async {
        var times: [Double] = []
        var last = OpenViewsAutomation.presentedFrames()
        OpenViewsAutomation.frameDurations = []
        let start = Date()
        let edge0 = frame(track)?[keyPath: edge]
        let sampler = Task { @MainActor in
            while Date().timeIntervalSince(start) * 1000 < ms {
                let f = OpenViewsAutomation.presentedFrames()
                if f != last {
                    for _ in last..<f { times.append(Date().timeIntervalSince(start) * 1000) }
                    last = f
                }
                await pause(0.0005)
            }
        }
        await action()
        await sampler.value
        let work = (OpenViewsAutomation.frameDurations ?? []).map { $0 * 1000 }.sorted()
        OpenViewsAutomation.frameDurations = nil
        let span = (times.last ?? 0) - (times.first ?? 0)
        let fps = times.count > 1 && span > 0 ? Double(times.count - 1) / span * 1000 : 0
        let gaps = zip(times.dropFirst(), times).map { $0 - $1 }
        let edge1 = frame(track)?[keyPath: edge]
        say(String(format: "frames5 %@: %d frames from %.0f to %.0f ms (%.0f fps); work median %.1f max %.1f ms; longest gap %.0f ms; edge %@ -> %@",
                   name, times.count, times.first ?? -1, times.last ?? -1, fps, work.isEmpty ? 0 : work[work.count / 2], work.last ?? 0,
                   gaps.max() ?? 0, edge0.map { String(format: "%.0f", Double($0)) } ?? "-", edge1.map { String(format: "%.0f", Double($0)) } ?? "-"))
        say("frames5 \(name) times: " + times.map { String(format: "%.0f", $0) }.joined(separator: " "))
    }
    #endif
}
