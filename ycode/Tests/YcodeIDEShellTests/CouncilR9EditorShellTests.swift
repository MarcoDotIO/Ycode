import Foundation
import Testing
import YcodeBuild
import YcodeEditorKit
@testable import YcodeIDECore
@testable import YcodeIDEShell

/// Council round 9, group B, rows 226 and 227 on the Linux IDE's model
/// (`specs/ide/fidelity-council.md`): each document keeps its caret while
/// the window is open, and instance highlighting only for symbols in code.
@MainActor
@Suite(.serialized) struct CouncilR9EditorShellTests {
    /// Row 226: a file's caret at line 9, column 46; another file shown,
    /// then the first again: its caret (and the status bar's line and
    /// column, which read it) come back.
    @Test func showingAFileAgainKeepsItsCaret() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let long = pkg.path("Sources/DemoCore/Long.swift")
        var text = ""
        for i in 0..<40 { text += "let value\(i) = \"a line that is long enough to have a forty-sixth column\" // \(i)\n" }
        try text.write(toFile: long, atomically: true, encoding: .utf8)
        let m = try WorkspaceShellModel(url: pkg.url, engine: ScriptedEngine(lines: [], issues: []))
        m.open(long)
        let buffer = try #require(m.editor?.buffer)
        let line9 = (text as NSString).range(of: "let value8").location
        buffer.setCaret(line9 + 45)
        m.open(pkg.path("Sources/DemoCore/Greeting.swift"))
        #expect(m.editor?.path == pkg.path("Sources/DemoCore/Greeting.swift"))
        m.open(long)
        #expect(m.editor?.path == long)
        #expect(m.editor?.buffer.caret == line9 + 45, "\(m.editor?.buffer.caret ?? -1)")
        #expect(m.editor?.buffer.caretLine == 8)
    }

    /// Row 227: the caret in a word inside a comment highlights nothing; in
    /// an identifier in code, its instances in code after the delay.
    @Test func instancesOnlyForSymbolsInCode() async throws {
        let saved = Preferences.shared
        defer { Preferences.shared = saved }
        let suite = "ycode-r9-instances-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        Preferences.shared = Preferences(defaults: defaults)
        Preferences.shared.highlightDelay = 0
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let file = pkg.path("Sources/DemoCore/Comments.swift")
        let text = "/* long enough,\n   enough */\nlet enough = 1\nlet x = enough + enough // enough\n"
        try text.write(toFile: file, atomically: true, encoding: .utf8)
        let m = try WorkspaceShellModel(url: pkg.url, engine: ScriptedEngine(lines: [], issues: []))
        m.open(file)
        let buffer = try #require(m.editor?.buffer)
        let ns = text as NSString
        buffer.setCaret(ns.range(of: "enough").location + 2)
        m.caretMoved()
        await m.symbolInstancesSettled()
        #expect(m.languageFeatures.symbolInstances.isEmpty)
        buffer.setCaret(ns.range(of: "let enough").location + 5)
        m.caretMoved()
        await m.symbolInstancesSettled()
        let found = m.languageFeatures.symbolInstances
        #expect(found.count == 3, "\(found)")
        #expect(found.allSatisfy { ns.substring(with: $0) == "enough" && $0.location > ns.range(of: "*/").location })
    }
}
