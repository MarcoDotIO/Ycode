import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
import YcodeLanguage
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@MainActor
@Suite(.serialized) struct PlaceholderTests {
    func window() throws -> (WorkspaceWindowController, URL) {
        _ = NSApplication.shared
        let dir = ycodeDir.appendingPathComponent(".build-ide/placeholders")
        try? FileManager.default.removeItem(at: dir)
        let src = dir.appendingPathComponent("Sources/P")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"P\", targets: [.target(name: \"P\")])\n"
            .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let file = src.appendingPathComponent("P.swift")
        try "let v = add(<#lhs#>, <#rhs#>)\n".write(to: file, atomically: true, encoding: .utf8)
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: dir)), loadDestinations: false, startLanguageService: false)
        wc.window?.appearance = NSAppearance(named: .aqua)
        wc.applyDefaultLayout()
        wc.open(path: file.path, line: nil)
        return (wc, file)
    }

    func key(_ code: UInt16, _ chars: String, shift: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? .shift : [], timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    @Test func tabReturnAndRendering() throws {
        let (wc, _) = try window()
        let tv = wc.editor.textView
        let ns = { tv.string as NSString }
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.keyDown(with: key(48, "\t"))
        #expect(ns().substring(with: tv.selectedRange()) == "<#lhs#>")
        tv.keyDown(with: key(48, "\t"))
        #expect(ns().substring(with: tv.selectedRange()) == "<#rhs#>")
        tv.keyDown(with: key(48, "\t", shift: true))
        #expect(ns().substring(with: tv.selectedRange()) == "<#lhs#>")
        // Delimiters are hidden; the token text keeps the editor font.
        let attrs = tv.textStorage!.attributes(at: 12, effectiveRange: nil)
        #expect((attrs[.foregroundColor] as? NSColor) == .clear)
        _ = try WindowSnapshotTests().render(wc.window!.contentView!.superview!, to: "editor-placeholders.png")
        // Return accepts the selected token's text.
        tv.keyDown(with: key(36, "\r"))
        #expect(tv.string == "let v = add(lhs, <#rhs#>)\n")
        // Typing replaces a selected token.
        tv.keyDown(with: key(48, "\t"))
        tv.insertText("2", replacementRange: tv.selectedRange())
        #expect(tv.string == "let v = add(lhs, 2)\n")
        // No placeholders left: Tab inserts a tab.
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(!wc.editor.selectPlaceholder())
    }

    @Test func completionSnippetSelectsFirstToken() throws {
        let (wc, _) = try window()
        let tv = wc.editor.textView
        tv.string = "gr\n"
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        var item = CompletionItem(label: "greet(times:)", insertText: "greet(times: ${1:Int})")
        item.isSnippet = true
        var m = CompletionModel()
        m.reset(items: [item], wordStart: 0, prefix: "gr")
        wc.editor.showCompletions(m)
        wc.editor.acceptCompletion()
        #expect(tv.string == "greet(times: <#Int#>)\n")
        #expect((tv.string as NSString).substring(with: tv.selectedRange()) == "<#Int#>")
    }
}
