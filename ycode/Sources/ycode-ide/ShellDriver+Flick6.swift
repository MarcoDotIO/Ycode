import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_FLICK6=<prefix>: council round 6's flick and Source Control
// glyphs on the Linux IDE (`fidelity-council.md` rows 157 and 166,
// `editor-area.md` H.1 and H.9; B6-OPENVIEWS). Open a workspace in a git
// repository holding a long Swift file (`YCODE_IDE_FLICK6_FILE`, else the
// first `Long.swift`, else the longest `.swift` file).
//
// 1. The council's flick from 600 points down, as its harness posts it: the
//    8 gesture events and the decaying momentum queued at once, with their
//    phases. Prints `flick6 burst` with every drawn frame's offset
//    (milliseconds after the first event : offset, negative past the top).
// 2. The same gesture as SDL delivers a touchpad's: 8 precise deltas without
//    phases stamped 8.3 ms apart; OpenViews infers the phases and
//    synthesizes the momentum. Prints `flick6 touchpad`.
// 3. The burst again, photographed near the peak, during the return and at
//    rest: <prefix>-flick6-<n>-<ms>.png.
// 4. The Repositories view with its filled group glyphs:
//    <prefix>-flick6-scm.png.
extension ShellDriver {
    #if os(Linux)
    static func flick6Walk(_ app: ShellAppModel, prefix: String) async {
        guard let w = app.workspace else { say("flick6: no workspace"); return }
        let files = w.root.allFiles.compactMap(\.path).filter { $0.hasSuffix(".swift") }
        let wanted = env["YCODE_IDE_FLICK6_FILE"]
        let path = files.first { wanted != nil && $0.hasSuffix("/" + (wanted ?? "")) }
            ?? files.first { $0.hasSuffix("/Long.swift") }
            ?? files.max { (try? String(contentsOfFile: $0, encoding: .utf8).count) ?? 0 < (try? String(contentsOfFile: $1, encoding: .utf8).count) ?? 0 }
        guard let path else { say("flick6: no Swift file"); return }
        if let ids = w.root.idPath(to: path) { for id in ids.dropLast() { w.setExpanded(id, true) } }
        w.open(path)
        await pause(1.0)
        guard let doc = w.editor, let source = frame("source") else { say("flick6: no editor"); return }
        let c = SourceEditorController.of(doc)
        let center = CGPoint(x: source.midX, y: source.midY)
        say("flick6 file \(path) lines=\(doc.buffer.lineCount) viewport=\(c.viewport) content=\(c.contentHeight)")

        func start() async {
            c.scroll(x: 0, y: 600)
            await pause(0.5)
        }
        func record(_ name: String, _ post: (TimeInterval) async -> Void) async {
            await start()
            var frames: [(TimeInterval, CGFloat)] = []
            c.frameProbe = { t, y in frames.append((t, y)) }
            let t0 = OpenViewsAutomation.now
            await post(t0)
            await pause(1.6)
            c.frameProbe = nil
            let curve = frames.map { (ms: ($0.0 - t0) * 1000, y: Double($0.1)) }
            say("flick6 \(name): " + curve.map { String(format: "%.0f:%.1f", $0.ms, $0.y) }.joined(separator: " "))
            let peak = curve.map(\.y).min() ?? 0
            let atTop = curve.first { $0.y <= 0 }?.ms ?? -1
            let peakAt = curve.first { $0.y == peak }?.ms ?? -1
            let rest = curve.last { $0.y != 0 }.map { $0.ms } ?? -1
            let gaps = zip(curve.dropFirst(), curve).filter { $0.0.ms <= rest + 20 && $0.0.ms >= atTop }.map { $0.0.ms - $0.1.ms }
            say(String(format: "flick6 \(name) summary: top reached at %.0f ms, stretch %.1f at %.0f ms (%.0f after the top), last moving frame %.0f ms, frames %d, median gap %.1f ms, max gap %.1f ms",
                       atTop, -peak, peakAt, peakAt - atTop, rest, curve.count,
                       gaps.sorted().dropFirst(gaps.count / 2).first ?? 0, gaps.max() ?? 0))
        }

        // 1. The council's harness: everything queued at once.
        await record("burst") { t0 in
            for e in Self.councilFlick(at: center, t0: t0) { OpenViewsAutomation.postScroll(e) }
        }
        // 2. A touchpad through SDL: precise deltas without phases, 8.3 ms
        //    apart by their times (SDL stamps an event when the device
        //    reports it), read in one go; the host infers the gesture and
        //    synthesizes the momentum. (Posting them live from here does not
        //    work: the driver's task wakes 15–50 ms late, and the tracker
        //    rightly reads gaps that long as separate gestures.)
        await record("touchpad") { t0 in
            for i in 0..<8 {
                OpenViewsAutomation.preciseScroll(at: center, delta: CGSize(width: 0, height: 40), timestamp: t0 + Double(i) * 0.0083)
            }
        }
        // 3. Frames of the burst: near the peak, returning, at rest.
        for (n, delay) in [(1, 0.07), (2, 0.25), (3, 0.9)] {
            await start()
            let t0 = OpenViewsAutomation.now
            for e in Self.councilFlick(at: center, t0: t0) { OpenViewsAutomation.postScroll(e) }
            while OpenViewsAutomation.now - t0 < delay { try? await Task.sleep(nanoseconds: 1_000_000) }
            let y = c.top
            say("flick6 shot \(n) at \(Int(delay * 1000)) ms offset \(y): " + OpenViewsAutomation.screenshot(to: "\(prefix)-flick6-\(n)-\(Int(delay * 1000)).png"))
            await pause(1.2)
        }
        // 4. Source Control's Repositories view, its groups expanded.
        await click("selector 1")
        await pause(0.8)
        await click("scm mode 1")
        await w.sourceControl.idle()
        for id in ["group:Recents", "group:Stashes"] { w.sourceControl.setExpanded(id, true) }
        await pause(0.8)
        say("flick6 scm: " + OpenViewsAutomation.screenshot(to: "\(prefix)-flick6-scm.png"))
        for title in ["Recents", "Stashes", "Tags", "Branches"] {
            say("flick6 scm group \(title): symbol \(RepositoriesViewStyle.groupSymbols[title] ?? "-")")
        }
    }

    /// The council's flick (H.1): 8 gesture events of 40 points 8.3 ms
    /// apart, the gesture's end, then about 1544 points of momentum decaying
    /// with a 0.33 s time constant; times from `t0`.
    static func councilFlick(at p: CGPoint, t0: TimeInterval) -> [ScrollEvent] {
        func event(_ dy: Double, _ phase: ScrollPhase, _ momentum: ScrollPhase, _ t: Double) -> ScrollEvent {
            ScrollEvent(window: 0, location: p, delta: CGSize(width: 0, height: dy), isPrecise: true, timestamp: t0 + t,
                        phase: phase, momentumPhase: momentum)
        }
        var out: [ScrollEvent] = []
        for i in 0..<8 { out.append(event(40, i == 0 ? .began : .changed, .none, Double(i) * 0.0083)) }
        out.append(event(0, .ended, .none, 0.062))
        let tau = 0.33, n = 173, total = 1.43
        let dt = total / Double(n)
        let v0 = 1544 / (tau * (1 - exp(-total / tau)))
        for i in 0..<n {
            let a = Double(i) * dt
            out.append(event(v0 * tau * (exp(-a / tau) - exp(-(a + dt) / tau)), .none, i == 0 ? .began : .changed, 0.066 + a))
        }
        out.append(event(0, .none, .ended, 0.066 + total))
        return out
    }
    #endif
}
