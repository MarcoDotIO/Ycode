import Foundation
#if os(Linux)
import OVPlatform
import SwiftUI
import YcodeEditorKit
import YcodeIDEShell

// YCODE_IDE_EDITOR_BENCH=<file>: what a large file costs in the real window,
// measured on the window's own frames (update, layout, drawing, presenting)
// and from a key's event to the frame that shows it. Input goes through the back
// end's queue, one step per display frame. Build in release.

@MainActor
enum EditorBench {
    static func say(_ s: String) { ShellDriver.say("bench " + s) }

    static func report(_ name: String, _ seconds: [Double]) {
        guard !seconds.isEmpty else {
            say("\(name): no samples")
            return
        }
        let s = seconds.sorted()
        let mean = s.reduce(0, +) / Double(s.count)
        func ms(_ v: Double) -> String { String(format: "%.1f", v * 1000) }
        say("\(name): n=\(s.count) mean=\(ms(mean)) ms p50=\(ms(s[s.count / 2])) p95=\(ms(s[s.count * 95 / 100])) max=\(ms(s[s.count - 1]))")
    }

    static func frames(during body: () async -> Void) async -> [Double] {
        OpenViewsAutomation.frameDurations = []
        await body()
        defer { OpenViewsAutomation.frameDurations = nil }
        return OpenViewsAutomation.frameDurations ?? []
    }

    /// Waits for the next presented frame after `before`, up to a second;
    /// returns the time waited.
    static func waitForFrame(after before: Int) async -> Double {
        let t0 = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<1000 {
            if OpenViewsAutomation.presentedFrames() > before { break }
            try? await Task.sleep(nanoseconds: 500_000)
        }
        return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
    }

    static func run(_ app: ShellAppModel, file: String) async {
        guard let w = app.workspace else {
            say("no workspace")
            return
        }
        let t0 = DispatchTime.now().uptimeNanoseconds
        w.open(file)
        guard let doc = w.editor else {
            say("cannot open \(file): \(w.document?.message ?? "?")")
            return
        }
        let b = doc.buffer
        let opened = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
        say("file \(file) lines=\(b.lineCount) units=\(b.length)")
        say(String(format: "open (read, lex): %.0f ms", opened * 1000))
        let before = OpenViewsAutomation.presentedFrames()
        let first = await waitForFrame(after: before)
        say(String(format: "first frame after: %.0f ms", first * 1000))
        // The parser's first pass runs shortly after the first frame.
        for _ in 0..<600 where !b.document.hasParsed { try? await Task.sleep(nanoseconds: 10_000_000) }
        say(String(format: "first parse: %.0f ms (hasParsed=%@)", b.document.lastRefineDuration * 1000, b.document.hasParsed ? "yes" : "no"))
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard let source = OpenViewsAutomation.identifiedFrames()["source"] else {
            say("no editor view")
            return
        }
        let center = CGPoint(x: source.midX, y: source.midY)

        // Scrolling down and back: one wheel step of 37 points per display frame.
        let scroll = await frames {
            for i in 0..<600 {
                let dir: CGFloat = (i / 300) % 2 == 0 ? -37 : 37
                OpenViewsAutomation.scroll(at: center, delta: CGSize(width: 0, height: dir))
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
        report("scroll 37 pt per frame, frame", scroll)

        // Far jumps: new lines every frame.
        let controller = SourceEditorController.of(doc)
        let jumps = await frames {
            for i in 0..<120 {
                controller.scroll(x: 0, y: CGFloat((i * 397) % b.lineCount) * controller.lineHeight)
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
        report("page jump, frame", jumps)

        // Typing in the middle of the file, from the key's event to its frame.
        b.setCaret(b.document.lineStart(b.lineCount / 2))
        controller.noteActivity()
        try? await Task.sleep(nanoseconds: 300_000_000)
        var latency: [Double] = []
        let text = Array("let answer = 42 + other.value // typed here ")
        let typing = await frames {
            for i in 0..<400 {
                let before = OpenViewsAutomation.presentedFrames()
                OpenViewsAutomation.type(String(text[i % text.count]))
                latency.append(await waitForFrame(after: before))
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
        }
        report("typing, frame", typing)
        report("typing, key to frame", latency)
        say(String(format: "refine after typing: %.1f ms", b.document.lastRefineDuration * 1000))

        // Holding Delete, and undoing it all.
        let deleting = await frames {
            for _ in 0..<100 {
                OpenViewsAutomation.press(.backspace)
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
        }
        report("backspace, frame", deleting)

        let t1 = DispatchTime.now().uptimeNanoseconds
        while b.canUndo { b.undo() }
        controller.noteActivity()
        say(String(format: "undo all: %.0f ms; dirty=%@", Double(DispatchTime.now().uptimeNanoseconds - t1) / 1e6, b.isDirty ? "yes" : "no"))

        // Save.
        b.setCaret(0)
        b.insertText("// x\n")
        let t2 = DispatchTime.now().uptimeNanoseconds
        let r = doc.save()
        say(String(format: "save: %.1f ms (%@)", Double(DispatchTime.now().uptimeNanoseconds - t2) / 1e6, "\(r)"))
        say("done")
    }
}
#endif
