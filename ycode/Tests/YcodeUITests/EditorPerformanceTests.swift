import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@MainActor
@Suite(.serialized) struct EditorPerformanceTests {
    /// 10,000 lines of Swift with comments, strings and a block comment.
    static func bigSource() -> String {
        var lines: [String] = ["import Foundation", "/* A block comment", "   over two lines */"]
        var i = 0
        while lines.count < 10_000 {
            lines += ["/// Doc for item \(i)", "struct Item\(i) {", "    var name = \"item \(i)\" // trailing", "    let value: Int = \(i * 7)",
                      "    func describe() -> String { \"\\(name)=\\(value)\" }", "}", ""]
            i += 1
        }
        return lines.prefix(10_000).joined(separator: "\n") + "\n"
    }

    func colors(_ e: SourceEditorController) -> [NSColor?] {
        let s = e.textView.textStorage!
        return stride(from: 0, to: s.length, by: 7).map { s.attribute(.foregroundColor, at: $0, effectiveRange: nil) as? NSColor }
    }

    @Test func typingLatencyOn10kLines() throws {
        _ = NSApplication.shared
        let dir = ycodeDir.appendingPathComponent(".build-ide/perf")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("Big.swift")
        try Self.bigSource().write(to: file, atomically: true, encoding: .utf8)
        let e = SourceEditorController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = e
        try e.open(file)
        func type(_ n: Int) -> Double {
            let tv = e.textView
            let at = (tv.string as NSString).range(of: "var name = \"item 5000\"").location
            tv.setSelectedRange(NSRange(location: at, length: 0))
            let t0 = Date()
            for _ in 0..<n { tv.insertText("x", replacementRange: tv.selectedRange()) }
            return Date().timeIntervalSince(t0) / Double(n) * 1000
        }
        // The full re-highlight is the slow baseline (more than a second a
        // keystroke in a debug build): a few keystrokes measure it. The whole
        // test runs on the main actor without a suspension, so every
        // keystroke here held every other suite's main-actor work (30 of
        // them held it for two minutes in a full run).
        SourceEditorController.incrementalEditing = false
        let before = type(5)
        SourceEditorController.incrementalEditing = true
        let after = type(30)
        #expect(e.lastHighlightWasIncremental)
        #expect(e.textView.lineIndex == LineIndex(e.text))
        print("TYPING-LATENCY 10k lines: full re-highlight \(String(format: "%.1f", before)) ms/keystroke, incremental \(String(format: "%.1f", after)) ms/keystroke")
        #expect(after < before / 3)
        // Incremental coloring equals a full pass.
        let incremental = colors(e)
        SourceEditorController.incrementalEditing = false
        e.textView.insertText("", replacementRange: NSRange(location: 0, length: 0))
        e.applyPreferences()
        SourceEditorController.incrementalEditing = true
        #expect(incremental == colors(e))
        // Closing a block comment early stays incremental (the document
        // re-lexes until the lexer state matches again) and still equals a
        // full pass.
        let c = (e.textView.string as NSString).range(of: "over two lines").location
        e.textView.setSelectedRange(NSRange(location: c, length: 0))
        e.textView.insertText("*/", replacementRange: e.textView.selectedRange())
        #expect(e.lastHighlightWasIncremental)
        let afterMarker = colors(e)
        SourceEditorController.incrementalEditing = false
        e.textView.insertText("", replacementRange: NSRange(location: 0, length: 0))
        SourceEditorController.incrementalEditing = true
        #expect(afterMarker == colors(e))
        e.textView.undoManager?.removeAllActions()
    }

    /// specs/ide/source-editor.md, "Ycode implementation", Performance: a
    /// 20,000-line Swift file. Full highlight (lexical, then swift-syntax's
    /// parse), the incremental highlight per keystroke, and keystroke to
    /// repaint (typed through the typing rules, then drawn).
    @Test func typingOn20kLines() async throws {
        _ = NSApplication.shared
        let dir = ycodeDir.appendingPathComponent(".build-ide/perf")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("Big20k.swift")
        try SyntaxBenchmark.swiftSource(lines: 20_000).write(to: file, atomically: true, encoding: .utf8)
        let e = SourceEditorController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = e
        var t0 = Date()
        try e.open(file)
        let openMs = Date().timeIntervalSince(t0) * 1000
        t0 = Date()
        e.refineHighlighting()   // the parse the editor runs right after opening
        let parseMs = Date().timeIntervalSince(t0) * 1000
        let tv = e.textView
        let at = (tv.string as NSString).range(of: "var name = \"item 2000\"").location
        tv.setSelectedRange(NSRange(location: at, length: 0))
        tv.scrollRangeToVisible(tv.selectedRange())
        window.displayIfNeeded()
        let typed = NSRange(location: NSNotFound, length: 0)
        var total = 0.0
        for k in 0..<30 {
            let k0 = Date()
            tv.insertText(k % 2 == 0 ? "(" : "x", replacementRange: typed)
            tv.displayIfNeeded()
            total += Date().timeIntervalSince(k0)
        }
        #expect(e.lastHighlightWasIncremental)
        // The highlighter alone, on a copy of the text: the lexical pass,
        // then the parser pass, per keystroke. It needs no view, so it runs
        // off the main actor: other suites' main-actor work goes on meanwhile.
        final class Copy: @unchecked Sendable {
            let doc: SyntaxDocument
            init(_ doc: SyntaxDocument) { self.doc = doc }
        }
        let copy = Copy(SyntaxDocument(text: tv.string, language: .swift))
        let (lexical, parser) = try await offMain { () -> (Double, Double) in
            var lexical = 0.0, parser = 0.0
            for _ in 0..<30 {
                let h0 = Date()
                copy.doc.replace(NSRange(location: at, length: 0), with: "y")
                let h1 = Date()
                copy.doc.refine()
                lexical += h1.timeIntervalSince(h0)
                parser += Date().timeIntervalSince(h1)
            }
            return (lexical, parser)
        }
        print(String(format: "EDITOR-PERF 20k lines: open %.0f ms (lexical colors), swift-syntax parse %.0f ms, incremental highlight %.2f ms lexical + %.1f ms parser pass per keystroke, keystroke-to-repaint %.1f ms",
                     openMs, parseMs, lexical / 30 * 1000, parser / 30 * 1000, total / 30 * 1000))
        #expect(lexical / 30 < 0.02)
        e.textView.undoManager?.removeAllActions()
    }
}
