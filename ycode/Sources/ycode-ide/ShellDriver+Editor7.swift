import Foundation
import SwiftUI
import YcodeEditorKit
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_EDITOR7=<prefix>: council round 7, group B, on the Linux IDE
// (`fidelity-council.md` rows 176–181, `editor-area.md` I.1–I.6). Open a
// workspace holding the council's GlassScroll (a long `Long.swift` and
// `Models/Model01.swift`); run at 1250 × 880 and again at 1180 × 880
// (`YCODE_IDE_WINDOW_SIZE`) for the jump bar.
//
// 1. X05, the slow flick (8 gesture events of 15 points, 566.7 points of
//    momentum) from 600 below the top: `editor7 x05` with the frames and
//    whether the top was reached, the stretch past it.
// 2. X03, main 04's flick mirrored, from 600 above the bottom: `editor7 x03`.
// 3. The final empty line: the caret at the document's end (⌘↓), the text
//    at its maximum offset: `editor7 final` with the last numbered line, its
//    row's bottom and the text area's middle; <prefix>-editor7-final.png.
// 4. The re-wrap: line 50 at the top, then Add Editor Pane on Right:
//    `editor7 rewrap` with the left pane's top line before and after;
//    <prefix>-editor7-rewrap.png.
// 5. The jump bar: both panes on Long.swift, then Model01.swift in the
//    right pane: <prefix>-editor7-jumpbar-long.png, -model01.png, and the
//    path parts' frames (`editor7 path`).
extension ShellDriver {
    #if os(Linux)
    static func editor7Walk(_ app: ShellAppModel, prefix: String) async {
        guard let w = app.workspace else { say("editor7: no workspace"); return }
        let files = w.root.allFiles.compactMap(\.path).filter { $0.hasSuffix(".swift") }
        guard let path = files.first(where: { $0.hasSuffix("/Long.swift") }) ?? files.first else { say("editor7: no Swift file"); return }
        if let ids = w.root.idPath(to: path) { for id in ids.dropLast() { w.setExpanded(id, true) } }
        w.open(path)
        await pause(1.0)
        guard let doc = w.editor, let source = frame("source") else { say("editor7: no editor"); return }
        let c = SourceEditorController.of(doc)
        let center = CGPoint(x: source.midX, y: source.midY)
        let window = OpenViewsAutomation.windowSize()?.points ?? .zero
        say("editor7 file \(path) lines=\(doc.buffer.lineCount) viewport=\(c.viewport) text=\(c.textHeight) overscroll=\(c.overscroll) window=\(window)")
        var maxY: CGFloat { max(0, c.contentHeight - c.viewport.height) }

        func record(_ name: String, from start: CGFloat, top toTop: Bool, events: (TimeInterval) -> [ScrollEvent]) async {
            c.scroll(x: 0, y: start)
            await pause(0.5)
            var frames: [(TimeInterval, CGFloat)] = []
            c.frameProbe = { t, y in frames.append((t, y)) }
            let t0 = OpenViewsAutomation.now
            for e in events(t0) { OpenViewsAutomation.postScroll(e) }
            await pause(1.8)
            c.frameProbe = nil
            let edge = toTop ? 0 : maxY
            let curve = frames.map { (ms: ($0.0 - t0) * 1000, y: Double($0.1)) }
            say("editor7 \(name): " + curve.map { String(format: "%.0f:%.1f", $0.ms, $0.y) }.joined(separator: " "))
            let past = edge == 0 ? -(curve.map(\.y).min() ?? 0) : (curve.map(\.y).max() ?? 0) - Double(maxY)
            let reached = curve.first { edge == 0 ? $0.y <= 0 : $0.y >= Double(maxY) }?.ms ?? -1
            say(String(format: "editor7 \(name) summary: from %.0f, edge %@ reached at %.0f ms, stretch %.1f, rest %.1f", Double(start),
                       edge == 0 ? "top" : "bottom", reached, max(0, past), Double(c.top)))
        }

        // 1. X05 from 600 below the top.
        await record("x05", from: 600, top: true) { t0 in Self.flick7(at: center, t0: t0, step: 15, points: 566.7, n: 134, span: 1.11) }
        // 2. X03 from 600 above the bottom.
        await record("x03", from: maxY - 600, top: false) { t0 in Self.flick7(at: center, t0: t0, step: -40, points: -1544, n: 173, span: 1.43) }

        // 3. The final empty line.
        doc.buffer.setSelection(EditorSelection(anchor: doc.buffer.length, head: doc.buffer.length))
        c.scroll(x: 0, y: maxY)
        c.invalidate()
        await pause(0.6)
        let last = doc.buffer.lineCount - 1
        let rowBottom = c.lineTop(last) + c.lineHeight - c.top
        say(String(format: "editor7 final: lines %d, caret line %d, last row bottom %.1f in a viewport %.1f tall (middle %.1f), visible %@",
                   doc.buffer.lineCount, doc.buffer.caretLine + 1, Double(rowBottom), Double(c.viewport.height), Double(c.viewport.height / 2),
                   "\(c.visibleLines(height: c.viewport.height))"))
        say("editor7 final shot: " + OpenViewsAutomation.screenshot(to: "\(prefix)-editor7-final.png"))

        // 4. The re-wrap: line 50 at the top, then split.
        let target = min(49, doc.buffer.lineCount - 1)
        c.scroll(x: 0, y: c.lineTop(target) + 3)
        await pause(0.4)
        func topLine(_ c: SourceEditorController) -> Int { c.line(atRow: max(0, Int((c.top - SourceEditorController.topInset) / c.lineHeight))) + 1 }
        let before = topLine(c)
        w.perform(.splitEditor)
        await pause(1.0)
        let after = topLine(c)
        say("editor7 rewrap: left pane's top line \(before) before the split, \(after) after (columns \(c.wrapColumns ?? 0))")
        say("editor7 rewrap shot: " + OpenViewsAutomation.screenshot(to: "\(prefix)-editor7-rewrap.png"))

        // 5. The jump bar.
        func printPath(_ tag: String) {
            let f = OpenViewsAutomation.identifiedFrames().filter { $0.key.hasPrefix("jump bar") || $0.key.hasPrefix("jump path") }
            say("editor7 path \(tag): " + f.map { String(format: "%@=%.1f-%.1f", $0.key, Double($0.value.minX), Double($0.value.maxX)) }.sorted().joined(separator: " "))
        }
        printPath("long")
        say("editor7 jumpbar long: " + OpenViewsAutomation.screenshot(to: "\(prefix)-editor7-jumpbar-long.png"))
        if let model01 = files.first(where: { $0.hasSuffix("/Model01.swift") }) {
            w.open(model01)
            await pause(0.8)
            printPath("model01")
            say("editor7 jumpbar model01: " + OpenViewsAutomation.screenshot(to: "\(prefix)-editor7-jumpbar-model01.png"))
        }
    }

    /// A flick as the council's harness posts it: `step`-point gesture
    /// events 8.3 ms apart, the gesture's end, then `points` of momentum in
    /// `n` events over `span` seconds decaying with a 0.33 s time constant.
    static func flick7(at p: CGPoint, t0: TimeInterval, step: Double, points: Double, n: Int, span: Double) -> [ScrollEvent] {
        func event(_ dy: Double, _ phase: ScrollPhase, _ momentum: ScrollPhase, _ t: Double) -> ScrollEvent {
            ScrollEvent(window: 0, location: p, delta: CGSize(width: 0, height: dy), isPrecise: true, timestamp: t0 + t,
                        phase: phase, momentumPhase: momentum)
        }
        var out: [ScrollEvent] = []
        for i in 0..<8 { out.append(event(step, i == 0 ? .began : .changed, .none, Double(i) * 0.0083)) }
        out.append(event(0, .ended, .none, 0.062))
        let tau = 0.33, dt = span / Double(n)
        let v0 = points / (tau * (1 - exp(-span / tau)))
        for i in 0..<n {
            let a = Double(i) * dt
            out.append(event(v0 * tau * (exp(-a / tau) - exp(-(a + dt) / tau)), .none, i == 0 ? .began : .changed, 0.066 + a))
        }
        out.append(event(0, .none, .ended, 0.066 + span))
        return out
    }
    #endif
}
