import Foundation
import Testing
import YcodeBuild
import YcodeEditorKit
import YcodeIDECore
import YcodeSyntax
@testable import YcodeIDEShell

/// Editing in the shell: buffers across files, saving, prompts, changes on
/// disk, recovery copies, find, jumps and builds.
@MainActor
@Suite struct ShellEditingTests {
    func model(_ pkg: TempPackage, engine: BuildEngine = ScriptedEngine(lines: [], issues: [])) throws -> WorkspaceShellModel {
        let m = try WorkspaceShellModel(url: pkg.url, engine: engine)
        m.recovery = EditorRecovery(directory: pkg.url.path + "/.recovery-test")
        return m
    }

    func contents(_ path: String) -> String { String(decoding: FileManager.default.contents(atPath: path) ?? Data(), as: UTF8.self) }

    @Test func openingAFileGivesAnEditableBuffer() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try model(pkg)
        let p = pkg.path("README.md")
        m.open(p)
        let d = try #require(m.editor)
        #expect(d.path == p && m.document?.name == "README.md" && !d.isDirty)
        #expect(!m.isEnabled(.save) && !m.isEnabled(.saveAll))
    }

    @Test func editingMarksTheFileAndSavingWritesIt() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try model(pkg)
        let p = pkg.path("README.md")
        m.open(p)
        let b = try #require(m.editor?.buffer)
        b.setCaret(0)
        b.insertText("X")
        #expect(m.editedPaths == [p] && m.isEnabled(.save) && m.isEnabled(.saveAll))
        #expect(m.windowTitle.hasSuffix("README.md — Edited"))
        #expect(m.projectRows.first { $0.isEdited }?.title.hasPrefix("README") == true)
        m.perform(.save)
        #expect(m.editedPaths.isEmpty && !m.isEnabled(.save))
        #expect(contents(p).hasPrefix("X") && !m.windowTitle.contains("Edited"))
        // Undo past the save is an edit again; redo is the saved text.
        b.undo()
        #expect(m.editedPaths == [p])
        b.redo()
        #expect(m.editedPaths.isEmpty)
    }

    @Test func unsavedTextStaysWhileAnotherFileIsShownAndSaveAllWritesBoth() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try model(pkg)
        let a = pkg.path("README.md"), b = pkg.path("Package.swift")
        m.open(a)
        m.editor?.buffer.setCaret(0)
        m.editor?.buffer.insertText("A")
        m.open(b)
        m.editor?.buffer.setCaret(0)
        m.editor?.buffer.insertText("/")
        #expect(m.editedPaths == [a, b])
        #expect(Set(m.editedDocumentNames) == ["README.md", "Package.swift"])
        m.goBack()
        #expect(m.editor?.path == a && m.editor?.buffer.text.hasPrefix("A") == true)
        m.perform(.saveAll)
        #expect(m.editedPaths.isEmpty && contents(a).hasPrefix("A") && contents(b).hasPrefix("/"))
    }

    @Test func aChangeOnDiskIsNotOverwrittenWithoutAsking() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try model(pkg)
        let p = pkg.path("README.md")
        m.open(p)
        m.editor?.buffer.setCaret(0)
        m.editor?.buffer.insertText("mine ")
        try Data("theirs\n".utf8).write(to: URL(fileURLWithPath: p))
        #expect(!m.saveCurrent())
        #expect(m.saveAlert == .conflict(path: p, change: .modified) && contents(p) == "theirs\n" && m.editedPaths == [p])
        m.overwriteOnConflict()
        #expect(m.saveAlert == nil && contents(p).hasPrefix("mine ") && m.editedPaths.isEmpty)
    }

    @Test func aCleanFileFollowsTheDiskAnEditedOneAsks() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try model(pkg)
        let p = pkg.path("README.md")
        m.open(p)
        try Data("second\n".utf8).write(to: URL(fileURLWithPath: p))
        m.checkOpenFilesOnDisk()
        #expect(m.editor?.buffer.text == "second\n" && m.editedPaths.isEmpty && m.editor?.diskChange == nil)
        m.editor?.buffer.setCaret(0)
        m.editor?.buffer.insertText("x")
        try Data("third\n".utf8).write(to: URL(fileURLWithPath: p))
        m.checkOpenFilesOnDisk()
        #expect(m.editor?.buffer.text == "xsecond\n" && m.editor?.diskChange == .modified && m.editedPaths == [p])
        m.reloadFromDisk()
        #expect(m.editor?.buffer.text == "third\n" && m.editor?.diskChange == nil && m.editedPaths.isEmpty)
        // Reloading can be undone: the edit comes back, as an edit.
        m.editor?.buffer.undo()
        #expect(m.editor?.buffer.text == "xsecond\n" && m.editedPaths == [p])
    }

    @Test func aDeletedFileShowsAndKeepingSavesItAgain() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try model(pkg)
        let p = pkg.path("README.md")
        m.open(p)
        let text = m.editor?.buffer.text
        try FileManager.default.removeItem(atPath: p)
        m.checkOpenFilesOnDisk()
        #expect(m.editor?.diskChange == .deleted && m.editor?.buffer.text == text)
        m.keepEditorVersion()
        #expect(m.editor?.diskChange == nil && m.isEnabled(.closeDocument))
        m.editor?.buffer.setCaret(0)
        m.editor?.buffer.insertText("x")
        #expect(m.saveCurrent())
        #expect(contents(p).hasPrefix("x"))
    }

    @Test func aFailedSaveKeepsTheTextAndSaysWhy() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try model(pkg)
        let p = pkg.path("README.md")
        m.open(p)
        m.editor?.buffer.setCaret(0)
        m.editor?.buffer.insertText("keep me")
        try FileManager.default.removeItem(atPath: p)
        try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        m.keepEditorVersion()
        #expect(!m.saveCurrent())
        guard case .failed(_, let message)? = m.saveAlert else {
            Issue.record("expected a failure, got \(String(describing: m.saveAlert))")
            return
        }
        #expect(message.contains("README"))
        #expect(m.editor?.buffer.text.hasPrefix("keep me") == true && m.editedPaths == [p])
    }

    // MARK: Closing

    @Test func closingTheWorkspaceAsksAboutUnsavedChanges() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let app = ShellAppModel(recentProjects: RecentProjects(defaults: UserDefaults(suiteName: "edit-\(UUID().uuidString)")!), engine: { ScriptedEngine(lines: [], issues: []) })
        #expect(app.open(path: pkg.url.path))
        let m = try #require(app.workspace)
        m.recovery = EditorRecovery(directory: pkg.url.path + "/.recovery-test")
        let p = pkg.path("README.md")
        m.open(p)
        m.editor?.buffer.setCaret(0)
        m.editor?.buffer.insertText("x")
        app.perform(.closeWorkspace)
        #expect(app.pendingClose == .closeWorkspace && app.workspace != nil)
        app.answerClose(.cancel)
        #expect(app.pendingClose == nil && app.workspace != nil && m.editedPaths == [p])
        app.perform(.closeWorkspace)
        app.answerClose(.saveAll)
        #expect(app.workspace == nil && contents(p).hasPrefix("x"))
    }

    @Test func quittingAsksAndDiscardingLosesOnlyWhatWasGivenUp() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let app = ShellAppModel(recentProjects: RecentProjects(defaults: UserDefaults(suiteName: "edit-\(UUID().uuidString)")!), engine: { ScriptedEngine(lines: [], issues: []) })
        var ended = 0
        app.terminateApp = { ended += 1 }
        #expect(app.shouldQuit())
        #expect(app.open(path: pkg.url.path))
        #expect(app.shouldQuit())
        let m = try #require(app.workspace)
        m.recovery = EditorRecovery(directory: pkg.url.path + "/.recovery-test")
        let p = pkg.path("README.md")
        let before = contents(p)
        m.open(p)
        m.editor?.buffer.setCaret(0)
        m.editor?.buffer.insertText("x")
        m.writeRecoveryCopies()
        #expect(m.recovery.entry(for: p) != nil)
        #expect(!app.shouldQuit())
        #expect(app.pendingClose == .quit && ended == 0)
        app.answerClose(.discard)
        #expect(ended == 1 && contents(p) == before && m.recovery.entry(for: p) == nil)
    }

    @Test func aSaveAllThatNeedsTheUserStopsTheClose() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let app = ShellAppModel(recentProjects: RecentProjects(defaults: UserDefaults(suiteName: "edit-\(UUID().uuidString)")!), engine: { ScriptedEngine(lines: [], issues: []) })
        #expect(app.open(path: pkg.url.path))
        let m = try #require(app.workspace)
        m.recovery = EditorRecovery(directory: pkg.url.path + "/.recovery-test")
        let p = pkg.path("README.md")
        m.open(p)
        m.editor?.buffer.setCaret(0)
        m.editor?.buffer.insertText("x")
        try Data("theirs".utf8).write(to: URL(fileURLWithPath: p))
        app.perform(.closeWorkspace)
        app.answerClose(.saveAll)
        #expect(app.workspace != nil && m.saveAlert != nil && m.editedPaths == [p] && contents(p) == "theirs")
    }

    @Test func closeDocumentAsksThenForgetsTheBuffer() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try model(pkg)
        let p = pkg.path("README.md")
        let before = contents(p)
        m.open(p)
        m.editor?.buffer.setCaret(0)
        m.editor?.buffer.insertText("x")
        m.perform(.closeDocument)
        #expect(m.closeDocumentPrompt && m.document != nil)
        m.closeCurrentDocument(discard: true)
        #expect(m.document == nil && m.editor == nil && m.editedPaths.isEmpty && contents(p) == before)
        m.open(p)
        #expect(m.editor?.isDirty == false && m.editor?.buffer.text == before)
    }

    // MARK: Recovery

    @Test func unsavedTextComesBackInTheNextSession() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let p = pkg.path("README.md")
        let first = try model(pkg)
        first.open(p)
        first.editor?.buffer.setCaret(0)
        first.editor?.buffer.insertText("unsaved ")
        first.writeRecoveryCopies()
        // A crash: nothing was saved, the next session opens the file.
        let second = try model(pkg)
        second.open(p)
        #expect(second.editor?.buffer.text.hasPrefix("unsaved ") == true)
        #expect(second.editedPaths == [p] && second.recoveredPaths == [p])
        #expect(!contents(p).hasPrefix("unsaved "))
        // Undo gives the file's own text.
        second.editor?.buffer.undo()
        #expect(second.editor?.buffer.text == contents(p) && second.editedPaths.isEmpty)
        second.editor?.buffer.redo()
        #expect(second.saveCurrent())
        #expect(contents(p).hasPrefix("unsaved ") && second.recovery.entry(for: p) == nil && second.recoveredPaths.isEmpty)
    }

    @Test func recoveredTextCanBeDiscarded() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let p = pkg.path("README.md")
        let first = try model(pkg)
        first.open(p)
        first.editor?.buffer.setCaret(0)
        first.editor?.buffer.insertText("unsaved ")
        first.writeRecoveryCopies()
        let second = try model(pkg)
        second.open(p)
        second.discardRecoveredText()
        #expect(second.editor?.buffer.text == contents(p) && second.editedPaths.isEmpty && second.recovery.entry(for: p) == nil)
    }

    // MARK: Find, jump

    @Test func findSelectsMatchesAndWraps() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try model(pkg)
        let p = pkg.path("README.md")
        try Data("one two one\nthree one\n".utf8).write(to: URL(fileURLWithPath: p))
        m.open(p)
        let b = try #require(m.editor?.buffer)
        m.perform(.find)
        #expect(m.findBar.isShown && !m.findBar.showsReplace)
        m.findBar.query = "one"
        m.findBar.refresh()
        #expect(m.findBar.matches.count == 3 && m.findBar.countText == "1 of 3" && b.selection == EditorSelection(anchor: 0, head: 3))
        m.perform(.findNext)
        #expect(b.selection == EditorSelection(anchor: 8, head: 11) && m.findBar.countText == "2 of 3")
        m.perform(.findNext)
        m.perform(.findNext)
        #expect(b.selection == EditorSelection(anchor: 0, head: 3))
        m.perform(.findPrevious)
        #expect(b.selection == EditorSelection(anchor: 18, head: 21))
        m.findBar.query = "absent"
        m.findBar.refresh()
        #expect(m.findBar.countText == "No matches")
    }

    @Test func replaceAndReplaceAllAreUndoable() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try model(pkg)
        let p = pkg.path("README.md")
        let original = "one two one\nthree one\n"
        try Data(original.utf8).write(to: URL(fileURLWithPath: p))
        m.open(p)
        let b = try #require(m.editor?.buffer)
        m.perform(.findAndReplace)
        #expect(m.findBar.showsReplace)
        m.findBar.query = "one"
        m.findBar.replacement = "1"
        m.findBar.refresh()
        m.findBar.replaceCurrent()
        #expect(b.text == "1 two one\nthree one\n" && m.findBar.matches.count == 2)
        #expect(b.selection == EditorSelection(anchor: 6, head: 9))
        #expect(m.findBar.replaceAll() == 2)
        #expect(b.text == "1 two 1\nthree 1\n")
        b.undo()
        #expect(b.text == "1 two one\nthree one\n")
        b.undo()
        #expect(b.text == original && m.editedPaths.isEmpty)
    }

    @Test func regularExpressionReplacementUsesTemplates() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try model(pkg)
        let p = pkg.path("README.md")
        try Data("a1 b2\n".utf8).write(to: URL(fileURLWithPath: p))
        m.open(p)
        m.perform(.findAndReplace)
        m.findBar.options.regularExpression = true
        m.findBar.query = "([a-z])([0-9])"
        m.findBar.replacement = "$2$1"
        m.findBar.refresh()
        #expect(m.findBar.replaceAll() == 2)
        #expect(m.editor?.buffer.text == "1a 2b\n")
    }

    @Test func useSelectionForFind() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try model(pkg)
        let p = pkg.path("README.md")
        try Data("word here word\n".utf8).write(to: URL(fileURLWithPath: p))
        m.open(p)
        let b = try #require(m.editor?.buffer)
        b.setSelection(EditorSelection(anchor: 0, head: 4))
        m.perform(.useSelectionForFind)
        #expect(m.findBar.query == "word")
    }

    @Test func jumpToLine() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try model(pkg)
        let p = pkg.path("README.md")
        try Data("a\nbb\nccc\n".utf8).write(to: URL(fileURLWithPath: p))
        m.open(p)
        let b = try #require(m.editor?.buffer)
        #expect(!m.jumpToLine("x") && !m.jumpToLine("") && !m.jumpToLine("0"))
        #expect(m.jumpToLine("2"))
        #expect(b.caret == 2 && m.markedLine == 2)
        #expect(m.jumpToLine("3:2"))
        #expect(b.caret == 6)
        #expect(m.jumpToLine("999"))
        #expect(b.caretLine == b.lineCount - 1)
    }

    @Test func structureCommands() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try model(pkg)
        let p = pkg.path("Sources/DemoCore/Edit.swift")
        try Data("let a = 1\nlet b = 2\n".utf8).write(to: URL(fileURLWithPath: p))
        m.open(p)
        let b = try #require(m.editor?.buffer)
        b.setCaret(0)
        m.perform(.commentSelection)
        #expect(b.text == "// let a = 1\nlet b = 2\n")
        b.undo()
        m.perform(.shiftRight)
        #expect(b.text.hasPrefix("    let a"))
        m.perform(.shiftLeft)
        #expect(b.text.hasPrefix("let a"))
        m.perform(.moveLineDown)
        #expect(b.text == "let b = 2\nlet a = 1\n")
        m.perform(.moveLineUp)
        #expect(b.text == "let a = 1\nlet b = 2\n")
    }

    // MARK: Building

    @Test func aBuildSavesFirst() async throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try model(pkg)
        let p = pkg.path("README.md")
        m.open(p)
        m.editor?.buffer.setCaret(0)
        m.editor?.buffer.insertText("x")
        _ = await m.build()
        #expect(m.editedPaths.isEmpty && contents(p).hasPrefix("x") && m.buildCount == 1)
    }

    @Test func aSaveThatNeedsTheUserStopsTheBuild() async throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try model(pkg)
        let p = pkg.path("README.md")
        m.open(p)
        m.editor?.buffer.setCaret(0)
        m.editor?.buffer.insertText("x")
        try Data("theirs".utf8).write(to: URL(fileURLWithPath: p))
        _ = await m.build()
        #expect(m.saveAlert != nil && m.buildCount == 0)
    }

    @Test func issuesShowInTheOpenFileAndJumpToTheirPlace() async throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let main = pkg.path("Sources/Demo/main.swift")
        let error = Diagnostic(severity: .error, message: "bad thing", location: .init(file: main, line: 2, column: 5))
        let warning = Diagnostic(severity: .warning, message: "odd thing", location: .init(file: main, line: 2, column: 1))
        let m = try model(pkg, engine: ScriptedEngine(lines: [], issues: [warning, error]))
        _ = await m.build()
        let row = try #require(m.allIssues.first { $0.message == "Bad thing" })
        m.issueSelection = row.id
        #expect(m.document?.path == main && m.markedLine == 2)
        let b = try #require(m.editor?.buffer)
        #expect(b.caretLine == 1 && b.caretColumn == 4)
        #expect(m.editorIssues[2] == EditorLineIssue(isError: true, message: "Bad thing"))
    }

    @Test func readOnlyFilesCantBeEditedOrSaved() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try model(pkg)
        let p = pkg.path("README.md")
        let bytes: [UInt8] = Array("caf".utf8) + [0xE9, 0x0A]
        try Data(bytes).write(to: URL(fileURLWithPath: p))
        m.open(p)
        #expect(m.editor?.readOnlyReason != nil)
        m.editor?.buffer.insertText("x")
        #expect(m.editedPaths.isEmpty && !m.isEnabled(.save) && !m.isEnabled(.commentSelection))
        #expect([UInt8](FileManager.default.contents(atPath: p) ?? Data()) == bytes)
    }

    @Test func newTypingSettingsReachOpenBuffers() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try model(pkg)
        m.open(pkg.path("README.md"))
        let saved = Preferences.shared
        defer { Preferences.shared = saved }
        let defaults = UserDefaults(suiteName: "edit-prefs-\(UUID().uuidString)")!
        Preferences.shared = Preferences(defaults: defaults)
        Preferences.shared.indentWithTabs = true
        m.preferencesChanged()
        #expect(m.editor?.buffer.typingOptions.indent.usesTabs == true)
    }

    // MARK: Completion

    @Test func snippetsBecomePlainTextWithTheCaretAtTheFirstStop() {
        let (a, ia) = EditorCompletion.plain(snippet: "add(${1:x: Int}, ${2:y})")
        #expect(a == "add(x: Int, y)" && ia == 4)
        let (b, ib) = EditorCompletion.plain(snippet: "foo($1)$0")
        #expect(b == "foo()" && ib == 4)
        let (c, ic) = EditorCompletion.plain(snippet: #"cost \$5"#)
        #expect(c == "cost $5" && ic == nil)
        let (d, id) = EditorCompletion.plain(snippet: "plain")
        #expect(d == "plain" && id == nil)
    }

    @Test func completionsFilterByPrefixThenSubstring() {
        let items = ["append", "count", "isEmpty", "reserveCapacity", "Appendable"].map { EditorCompletion(label: $0, text: $0) }
        #expect(EditorCompletion.filter(items, prefix: "app").map(\.label) == ["append", "Appendable"])
        #expect(EditorCompletion.filter(items, prefix: "cap").map(\.label) == ["reserveCapacity"])
        #expect(EditorCompletion.filter(items, prefix: "").count == 5)
    }

    @Test func noLanguageServerGivesNoCompletionsAtOnce() async throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try model(pkg)
        m.open(pkg.path("Sources/DemoCore/Greeting.swift"))
        let t0 = Date()
        #expect(await m.completions().isEmpty)
        #expect(Date().timeIntervalSince(t0) < 1)
    }
}
