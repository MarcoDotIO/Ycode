import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
import YcodeLanguage
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// P-080 on macOS: typing the start of a word opens the completion list
/// (the reference lists CodingKey, Counter, Codable… for "Co" on a new
/// line); the list filters as the word grows and is asked for again only
/// while the server says it is incomplete; comments never ask. Offscreen
/// (the window is never ordered in).
@MainActor
@Suite(.serialized) struct CompletionWhileTypingTests {
    final class Provider {
        var calls: [Position] = []
        var incomplete = false
        func items(prefix: String) -> [CompletionItem] {
            ["Counter", "Codable", "CodingKey", "Color", "ContentView"].map {
                var i = CompletionItem(label: $0, insertText: $0, detail: "struct", kind: 22)
                i.fromIncompleteList = incomplete
                return i
            }
        }
    }

    func editor(_ text: String) throws -> (SourceEditorController, NSWindow, Provider) {
        _ = NSApplication.shared
        let dir = ycodeDir.appendingPathComponent(".build-ide/completion-typing")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("ContentView.swift")
        try text.write(to: file, atomically: true, encoding: .utf8)
        let e = SourceEditorController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = e
        try e.open(file)
        window.makeFirstResponder(e.textView)
        let p = Provider()
        e.completionProvider = { _, pos in
            p.calls.append(pos)
            return p.items(prefix: "")
        }
        return (e, window, p)
    }

    func type(_ s: String, into tv: NSTextView) {
        for ch in s {
            let (chars, code): (String, UInt16) = ch == "\n" ? ("\r", 36) : (String(ch), 0)
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: tv.window?.windowNumber ?? 0,
                                     context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            tv.keyDown(with: e)
        }
    }

    func settle() async {
        for _ in 0..<20 { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func typingCoOnANewLineOpensTheList() async throws {
        let (e, window, p) = try editor("struct ContentView {\n    func f() {\n    }\n}\n")
        defer { withExtendedLifetime(window) {} }
        let tv = e.textView
        tv.setSelectedRange(NSRange(location: ("struct ContentView {\n    func f() {" as NSString).length, length: 0))
        type("\nC", into: tv)
        await settle()
        #expect(p.calls.count == 1)
        #expect(p.calls.first?.line == 2)
        #expect(e.isShowingCompletions)
        type("o", into: tv)
        await settle()
        // The list filters; it is not asked for again (complete list).
        #expect(p.calls.count == 1)
        #expect(e.completions.visible.map(\.label) == ["Counter", "Codable", "CodingKey", "Color", "ContentView"].filter { $0.hasPrefix("Co") })
        #expect(e.completions.wordStart == (tv.string as NSString).range(of: "Co", options: .backwards).location)
        // The list under the word, for the report (`.build-ide/b4-shots`).
        e.view.setFrameSize(NSSize(width: 640, height: 260))
        e.view.layoutSubtreeIfNeeded()
        e.showCompletions(e.completions) // placed again under the word at this size
        if let rep = e.view.bitmapImageRepForCachingDisplay(in: e.view.bounds) {
            e.view.cacheDisplay(in: e.view.bounds, to: rep)
            let shots = ycodeDir.appendingPathComponent(".build-ide/b4-shots")
            try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
            try rep.representation(using: .png, properties: [:])?.write(to: shots.appendingPathComponent("p080-completion-co-macos.png"))
        }
    }

    @Test func incompleteListsAreAskedAgainAsTheWordGrows() async throws {
        let (e, window, p) = try editor("let x = 1\n")
        defer { withExtendedLifetime(window) {} }
        p.incomplete = true
        let tv = e.textView
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        type("C", into: tv)
        await settle()
        type("o", into: tv)
        await settle()
        #expect(p.calls.count == 2)
        #expect(p.calls.last?.character == 2)
        #expect(e.isShowingCompletions)
    }

    @Test func commentsStringsAndDeclarationsDoNotAsk() async throws {
        let (e, window, p) = try editor("// \nlet s = \"\"\nlet \ns\n")
        defer { withExtendedLifetime(window) {} }
        let tv = e.textView
        let ns = { tv.string as NSString }
        func caret(after marker: String) { tv.setSelectedRange(NSRange(location: NSMaxRange(ns().range(of: marker)), length: 0)) }
        caret(after: "// ")
        type("Co", into: tv)
        caret(after: "let s = \"")
        type("Co", into: tv)
        tv.setSelectedRange(NSRange(location: ns().range(of: "let \ns").location + 4, length: 0))
        type("x", into: tv)
        await settle()
        #expect(p.calls.isEmpty)
        #expect(!e.isShowingCompletions)
        // A "." in Swift asks for members.
        tv.setSelectedRange(NSRange(location: ns().length - 1, length: 0))
        type(".", into: tv)
        await settle()
        #expect(p.calls.count == 1)
    }
}
