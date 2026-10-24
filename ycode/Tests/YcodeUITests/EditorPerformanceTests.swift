import AppKit
import Foundation
import Testing
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
        SourceEditorController.incrementalEditing = false
        let before = type(30)
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
        // Typing into a block comment marker falls back to a full pass.
        let c = (e.textView.string as NSString).range(of: "over two lines").location
        e.textView.setSelectedRange(NSRange(location: c, length: 0))
        e.textView.insertText("*/", replacementRange: e.textView.selectedRange())
        #expect(!e.lastHighlightWasIncremental)
        e.textView.undoManager?.removeAllActions()
    }
}

@Suite struct LineIndexEditTests {
    @Test func incrementalMatchesFull() {
        var text = "a\nbb\nccc\n"
        var idx = LineIndex(text)
        let edits: [(NSRange, String)] = [(NSRange(location: 1, length: 0), "x\ny"), (NSRange(location: 0, length: 4), ""),
                                           (NSRange(location: 2, length: 3), "\n\n"), (NSRange(location: 0, length: 0), "\n")]
        for (r, s) in edits {
            idx.applyEdit(range: r, replacement: s)
            text = (text as NSString).replacingCharacters(in: r, with: s)
            #expect(idx == LineIndex(text), "after \(r) \(s)")
        }
    }
}
