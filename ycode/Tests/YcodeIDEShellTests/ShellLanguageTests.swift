import Foundation
import Testing
import YcodeBuild
import YcodeDebug
import YcodeEditorKit
import YcodeIDECore
import YcodeLanguage
@testable import YcodeIDEShell

/// A language server in memory for the shell: answers each request with
/// `handler` and records every message.
final class ShellFakeServer: DAPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var receiving: (@Sendable (Data?) -> Void)?
    private var decoder = DAPFraming.Decoder()
    private var log: [JSON] = []
    let handler: @Sendable (String, JSON) -> JSON?

    init(handler: @escaping @Sendable (String, JSON) -> JSON?) { self.handler = handler }

    var methods: [String] { lock.withLock { log.compactMap { $0["method"]?.string } } }

    func start(receiving: @escaping @Sendable (Data?) -> Void) throws { lock.withLock { self.receiving = receiving } }

    func send(_ data: Data) {
        let bodies = lock.withLock { decoder.append(data) }
        for body in bodies {
            guard let msg = try? JSON.decode(body) else { continue }
            lock.withLock { log.append(msg) }
            guard let id = msg["id"], let method = msg["method"]?.string else { continue }
            let result: JSON = method == "initialize" ? ["capabilities": [:]] : (handler(method, msg["params"] ?? .null) ?? .null)
            let r = lock.withLock { receiving }
            r?(DAPFraming.frame(JSON.object(["jsonrpc": "2.0", "id": id, "result": result]).encoded()))
        }
    }

    func close() {
        let r = lock.withLock { () -> (@Sendable (Data?) -> Void)? in
            defer { receiving = nil }
            return receiving
        }
        r?(nil)
    }
}

/// Quick Help, Jump to Definition, rename, references and the Report
/// navigator in the shell (`specs/ide/language.md`, `refactoring.md`,
/// `navigators.md` §Report navigator), against a scripted server.
@MainActor
@Suite struct ShellLanguageTests {
    nonisolated static func range(_ l1: Int, _ c1: Int, _ l2: Int, _ c2: Int) -> JSON {
        ["start": ["line": .number(Double(l1)), "character": .number(Double(c1))], "end": ["line": .number(Double(l2)), "character": .number(Double(c2))]]
    }

    nonisolated static func uri(_ path: String) -> JSON { .string(URL(fileURLWithPath: path).absoluteString) }

    /// A model of the temporary package with the scripted server running.
    func model(_ pkg: TempPackage, _ handler: @escaping @Sendable (String, JSON) -> JSON?) async throws -> (WorkspaceShellModel, ShellFakeServer) {
        let m = try WorkspaceShellModel(url: pkg.url, engine: ScriptedEngine(lines: ["[1/2] Compiling Demo main.swift", "[2/2] Linking Demo"], issues: []))
        m.recovery = EditorRecovery(directory: pkg.url.path + "/.recovery-test")
        let server = ShellFakeServer(handler: handler)
        await m.session.startLanguageService(transport: server)
        return (m, server)
    }

    /// main.swift: `print(Greeting(name: "x").text)`; the caret on "Greeting".
    func openMain(_ m: WorkspaceShellModel, _ pkg: TempPackage) throws -> EditorBuffer {
        m.open(pkg.path("Sources/Demo/main.swift"))
        let b = try #require(m.editor?.buffer)
        b.setCaret(b.document.lineStart(1) + 8)
        return b
    }

    @Test func jumpToDefinitionOpensTheFileAndSelectsTheSymbol() async throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let greeting = pkg.path("Sources/DemoCore/Greeting.swift")
        let (m, server) = try await model(pkg) { method, _ in
            // A point, as sourcekit-lsp gives definitions: the name there is selected.
            method == "textDocument/definition" ? [["uri": Self.uri(greeting), "range": Self.range(0, 14, 0, 14)]] : nil
        }
        _ = try openMain(m, pkg)
        #expect(m.isEnabled(.jumpToDefinition) && m.isEnabled(.renameSymbol) && m.isEnabled(.showQuickHelp))
        #expect(await m.jumpToDefinition())
        #expect(m.document?.name == "Greeting.swift" && m.canGoBack)
        let b = try #require(m.editor?.buffer)
        #expect(b.selectedText == "Greeting")
        // The server had the editor's text before the request.
        #expect(server.methods.contains("textDocument/didChange"))
        m.goBack()
        #expect(m.document?.name == "main.swift")
    }

    @Test func theJumpBarFollowsTheDeclarationAtTheCaret() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try WorkspaceShellModel(url: pkg.url, engine: ScriptedEngine(lines: [], issues: []))
        m.open(pkg.path("Sources/DemoCore/Greeting.swift"))
        let b = try #require(m.editor?.buffer)
        b.setCaret(b.document.lineStart(3) + 6)
        m.updateCaretSymbol()
        #expect(m.languageFeatures.documentSymbols.map(\.name) == ["Greeting"])
        #expect(m.languageFeatures.caretSymbol?.name == "text")
        // Its menu: choosing a declaration goes to its line.
        m.openSymbol(try #require(m.languageFeatures.documentSymbols.first))
        #expect(b.caretLine == 0 && m.languageFeatures.caretSymbol?.name == "Greeting")
        m.closeCurrentDocument()
        m.updateCaretSymbol()
        #expect(m.languageFeatures.caretSymbol == nil && m.languageFeatures.documentSymbols.isEmpty)
    }

    @Test func nothingFoundLeavesANotice() async throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let (m, _) = try await model(pkg) { _, _ in nil }
        _ = try openMain(m, pkg)
        #expect(await m.jumpToDefinition() == false)
        #expect(m.document?.name == "main.swift" && m.languageFeatures.notice == "No definition found")
        #expect(await m.showQuickHelp() == nil && m.languageFeatures.popover == nil)
        #expect(await m.beginRename() == false && m.languageFeatures.rename == nil)
    }

    @Test func quickHelpShowsAPopoverAndFillsTheInspector() async throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let greeting = pkg.path("Sources/DemoCore/Greeting.swift")
        let (m, _) = try await model(pkg) { method, _ in
            switch method {
            case "textDocument/hover":
                ["contents": ["kind": "markdown", "value": "```swift\npublic struct Greeting\n```\n\n---\n\nA greeting for someone.\n\n- Note: Kind words."]]
            case "textDocument/definition": [["uri": Self.uri(greeting), "range": Self.range(0, 14, 0, 22)]]
            default: nil
            }
        }
        let b = try openMain(m, pkg)
        let doc = try #require(await m.showQuickHelp())
        #expect(doc.title == "Greeting" && doc.declaration == "public struct Greeting" && doc.file == greeting)
        let p = try #require(m.languageFeatures.popover)
        // The popover hangs under the symbol's start.
        #expect(p.offset == b.document.lineStart(1) + 6 && p.path == m.document?.path)
        #expect(m.languageFeatures.inspectorHelp == doc)
        // Moving the caret closes it; ⌥⌘3 shows the inspector's tab.
        m.caretMoved()
        #expect(m.languageFeatures.popover == nil)
        m.isInspectorShown = false
        m.perform(.showQuickHelpInspector)
        #expect(m.isInspectorShown && m.languageFeatures.inspectorTab == .quickHelp)
        await m.quickHelpInspectorSettled()
        #expect(m.languageFeatures.inspectorHelp?.title == "Greeting")
        m.perform(.showFileInspector)
        #expect(m.languageFeatures.inspectorTab == .file)
    }

    @Test func renameInOneFileIsOneUndoStep() async throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let main = pkg.path("Sources/Demo/main.swift")
        let (m, _) = try await model(pkg) { method, _ in
            switch method {
            case "textDocument/prepareRename": ["range": Self.range(1, 6, 1, 14), "placeholder": "Greeting"]
            case "textDocument/documentHighlight": [["range": Self.range(1, 6, 1, 14), "kind": 1]]
            case "textDocument/rename": ["changes": [Self.uri(main).string!: [["range": Self.range(1, 6, 1, 14), "newText": "Welcome"]]]]
            default: nil
            }
        }
        let b = try openMain(m, pkg)
        let before = b.text
        #expect(await m.beginRename())
        let r = try #require(m.languageFeatures.rename)
        #expect(r.oldName == "Greeting" && r.range == NSRange(location: b.document.lineStart(1) + 6, length: 8))
        #expect(m.languageFeatures.highlights == [r.range])
        // The same name, or an empty one: nothing to do.
        #expect(await m.commitRename(to: "Greeting") == nil && m.languageFeatures.rename == nil)
        #expect(await m.beginRename())
        let edit = try #require(await m.commitRename(to: "Welcome"))
        #expect(edit.files.count == 1 && m.languageFeatures.rename == nil && m.languageFeatures.renamePreview == nil)
        #expect(b.text == before.replacingOccurrences(of: "Greeting(", with: "Welcome(") && m.editedPaths == [main])
        b.undo()
        #expect(b.text == before && m.editedPaths.isEmpty)
    }

    @Test func renameAcrossFilesShowsThePreviewThenAppliesIt() async throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let main = pkg.path("Sources/Demo/main.swift"), greeting = pkg.path("Sources/DemoCore/Greeting.swift")
        let (m, server) = try await model(pkg) { method, _ in
            switch method {
            case "textDocument/prepareRename": ["start": ["line": 1, "character": 6], "end": ["line": 1, "character": 14]]
            case "textDocument/rename": ["documentChanges": [
                ["textDocument": ["uri": Self.uri(main), "version": .null], "edits": [["range": Self.range(1, 6, 1, 14), "newText": "Welcome"]]],
                ["textDocument": ["uri": Self.uri(greeting), "version": .null], "edits": [["range": Self.range(0, 14, 0, 22), "newText": "Welcome"]]],
            ]]
            default: nil
            }
        }
        let b = try openMain(m, pkg)
        let oldGreeting = try String(contentsOfFile: greeting, encoding: .utf8)
        #expect(await m.beginRename())
        #expect(m.languageFeatures.rename?.oldName == "Greeting")
        _ = await m.commitRename(to: "Welcome")
        let p = try #require(m.languageFeatures.renamePreview)
        #expect(p.summary == "Rename 2 occurrences in 2 files")
        #expect(p.files.map(\.name) == ["main.swift", "Greeting.swift"])
        #expect(p.files[1].lines.first?.after == "public struct Welcome {")
        #expect(p.files[0].lines.first?.after == "print(Welcome(name: \"x\").text)")
        // Nothing changes until Rename.
        let unchanged = try String(contentsOfFile: greeting, encoding: .utf8)
        #expect(!b.isDirty && unchanged == oldGreeting)
        let changed = m.applyRenamePreview()
        #expect(Set(changed) == [main, greeting])
        #expect(b.text.contains("print(Welcome(") && m.editedPaths == [main])
        // The file that is not open was rewritten on disk; its old text is kept.
        let rewritten = try String(contentsOfFile: greeting, encoding: .utf8)
        #expect(rewritten.hasPrefix("public struct Welcome {"))
        #expect(m.languageFeatures.diskBackups[greeting] == oldGreeting)
        #expect(server.methods.contains("workspace/didChangeWatchedFiles"))
        #expect(m.languageFeatures.rename == nil && m.languageFeatures.highlights.isEmpty)
    }

    @Test func referencesAndCallersFillTheFindNavigator() async throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let main = pkg.path("Sources/Demo/main.swift"), greeting = pkg.path("Sources/DemoCore/Greeting.swift")
        let caller: JSON = ["name": "main", "kind": 12, "uri": Self.uri(main), "range": Self.range(1, 0, 1, 31), "selectionRange": Self.range(1, 0, 1, 5)]
        let (m, _) = try await model(pkg) { method, params in
            switch method {
            case "textDocument/references": [
                ["uri": Self.uri(main), "range": Self.range(1, 6, 1, 14)],
                ["uri": Self.uri(greeting), "range": Self.range(0, 14, 0, 22)],
            ]
            case "textDocument/prepareCallHierarchy": [["name": "Greeting.init(name:)", "kind": 9, "uri": Self.uri(greeting),
                                                        "range": Self.range(0, 0, 4, 1), "selectionRange": Self.range(0, 14, 0, 22)]]
            // main has no callers of its own.
            case "callHierarchy/incomingCalls": params["item"]?["name"]?.string == "main" ? [] : [["from": caller, "fromRanges": [Self.range(1, 6, 1, 14)]]]
            default: nil
            }
        }
        _ = try openMain(m, pkg)
        #expect(await m.findSelectedSymbolInWorkspace() == 2)
        #expect(m.navigator == .find && m.findText == "Greeting" && m.findCountText == "Greeting — 2 references")
        // Files in path order ("Sources/Demo/" before "Sources/DemoCore/").
        #expect(m.findRows.map(\.name) == ["main.swift", "Greeting.swift"])
        #expect(m.findRows[0].matches.first.map { $0.before + $0.match + $0.after } == "print(Greeting(name: \"x\").text)")
        #expect(m.findRows[0].matches.first?.match == "Greeting")
        // A row opens its place.
        m.findSelection = m.findRows[1].matches[0].id
        #expect(m.document?.name == "Greeting.swift")
        _ = try openMain(m, pkg)
        #expect(await m.findCallHierarchy() == 1)
        // The tree under "Callers of Greeting": the initializer, then main.
        #expect(m.findCountText == "Callers of Greeting" && m.findRows.isEmpty)
        #expect(m.callHierarchy.rows.map(\.name) == ["Greeting.init(name:)", "main"])
        #expect(m.callHierarchy.rows.map(\.detail) == ["Greeting.swift:1", "main.swift:2"])
        // A row opens the function's declaration.
        m.callHierarchy.selection = m.callHierarchy.rows[1].id
        #expect(m.document?.name == "main.swift" && m.editor?.buffer.caretLine == 1)
        // A search of its own replaces the title and the tree.
        m.findText = "Hello"
        m.runFind()
        await m.waitForFind()
        #expect(m.findResultsTitle == nil && m.findCountText != "Callers of Greeting" && m.callHierarchy.tree == nil)
    }

    /// `refactoring.md` §Find: two levels of callers, as the macOS IDE's
    /// tree; a function already on the path is not followed again, and a
    /// third level is not asked for.
    @Test func callHierarchyIsTwoLevelsDeep() async throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let main = pkg.path("Sources/Demo/main.swift"), greeting = pkg.path("Sources/DemoCore/Greeting.swift")
        let item: @Sendable (String, String, Int) -> JSON = { name, path, line in
            ["name": .string(name), "kind": 12, "uri": Self.uri(path), "range": Self.range(line, 0, line, 20), "selectionRange": Self.range(line, 0, line, 5)]
        }
        let asked = LockedNames()
        let (m, _) = try await model(pkg) { method, params in
            switch method {
            case "textDocument/prepareCallHierarchy": return [item("greet", greeting, 0)]
            case "callHierarchy/incomingCalls":
                let name = params["item"]?["name"]?.string ?? ""
                asked.add(name)
                switch name {
                case "greet": return [["from": item("printAll", main, 1), "fromRanges": [Self.range(1, 6, 1, 11), Self.range(1, 20, 1, 25)]],
                                      ["from": item("greetAll", greeting, 3), "fromRanges": [Self.range(3, 8, 3, 13)]]]
                case "printAll": return [["from": item("run", main, 0), "fromRanges": [Self.range(0, 2, 0, 10)]]]
                // greetAll calls itself: not followed again.
                case "greetAll": return [["from": item("greetAll", greeting, 3), "fromRanges": [Self.range(4, 2, 4, 10)]]]
                default: return [["from": item("deeper", main, 5), "fromRanges": [Self.range(5, 0, 5, 3)]]]
                }
            default: return nil
            }
        }
        _ = try openMain(m, pkg)
        #expect(await m.findCallHierarchy() == 4)
        let rows = m.callHierarchy.rows
        #expect(rows.map(\.name) == ["greet", "printAll", "run", "greetAll", "greetAll"])
        #expect(rows.map(\.level) == [0, 1, 2, 1, 2])
        #expect(rows[1].detail == "main.swift:2  (2 calls)")
        // The callers of the second level's functions are never asked for.
        #expect(asked.names.sorted() == ["greet", "greetAll", "printAll"])
        // Collapsing a caller hides its callers.
        m.callHierarchy.setExpanded(rows[1].id, false)
        #expect(m.callHierarchy.rows.map(\.name) == ["greet", "printAll", "greetAll", "greetAll"])
    }

    @Test func languageCommandsNeedAServerAndAFile() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try WorkspaceShellModel(url: pkg.url, engine: ScriptedEngine(lines: [], issues: []))
        for c in [ShellCommand.jumpToDefinition, .jumpToOriginalSource, .renameSymbol, .showQuickHelp, .findSelectedSymbol, .showCallHierarchy] {
            #expect(!m.isEnabled(c), "\(c)")
            #expect(c.menuCommand?.isAvailable == true, "\(c)")
        }
        #expect(ShellCommand.jumpToDefinition.shortcut?.text == "⌃⌘J" && ShellCommand.jumpToDefinition.menu == "Navigate")
        #expect(ShellCommand.renameSymbol.title(in: nil) == "Rename…")
        #expect(ShellCommand.showQuickHelpInspector.shortcut?.text == "⌥⌘3")
        #expect(ShellCommand.findSelectedSymbol.shortcut?.text == "⌃⇧⌘F" && ShellCommand.showCallHierarchy.shortcut?.text == "⌃⇧⌘H")
    }
}

/// The Symbol navigator (⌘3): files and their declarations, the filter,
/// the server's workspace symbols, opening a declaration.
@MainActor
@Suite struct SymbolNavigatorTests {
    @Test func filesWithTheirDeclarationsAndTheFilter() async throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        try "struct Helper {\n    func assist() {}\n    var level = 1\n}\n\nfunc greetLater() {}\n"
            .write(to: pkg.url.appendingPathComponent("Sources/Demo/Helper.swift"), atomically: true, encoding: .utf8)
        let m = try WorkspaceShellModel(url: pkg.url, engine: ScriptedEngine(lines: [], issues: []))
        m.perform(.showSymbolNavigator)
        #expect(m.navigator == .symbols && ShellCommand.showSymbolNavigator.shortcut?.text == "⌘3")
        m.refreshSymbolNavigator()
        while m.symbols.isScanning { await Task.yield() }
        let s = m.symbols
        // Navigator order: Sources/Demo, Sources/DemoCore, then Tests.
        #expect(s.rows.map { String(repeating: " ", count: $0.level) + $0.title }
                == ["Helper.swift", " Helper", "  assist", "  level", " greetLater", "Greeting.swift", " Greeting", "  name", "  text", "GreetingTests.swift", " greets"])
        #expect(s.rows[1].kind == .struct && s.rows[2].kind == .function && s.rows[3].kind == .property && s.rows[0].kind == nil)
        // A collapsed file hides its declarations.
        s.setExpanded(s.rows[0].id, false)
        #expect(s.rows.map(\.title) == ["Helper.swift", "Greeting.swift", "Greeting", "name", "text", "GreetingTests.swift", "greets"])
        s.setExpanded(s.rows[0].id, true)
        // The filter keeps matches and the types around them.
        s.filterText = "gre"
        #expect(s.rows.map(\.title) == ["Helper.swift", "greetLater", "Greeting.swift", "Greeting", "GreetingTests.swift", "greets"])
        s.filterText = "assist"
        #expect(s.rows.map(\.title) == ["Helper.swift", "Helper", "assist"])
        // Opening a declaration goes to its line.
        let row = try #require(s.rows.last)
        m.openSymbolRow(row)
        #expect(m.document?.name == "Helper.swift" && m.editor?.buffer.caretLine == 1 && s.selection == row.id)
        // An edited buffer is read as edited.
        m.editor?.buffer.setCaret(0)
        m.editor?.buffer.insertText("enum Mode {}\n")
        s.filterText = ""
        m.refreshSymbolNavigator()
        while m.symbols.isScanning { await Task.yield() }
        #expect(s.rows.contains { $0.title == "Mode" && $0.kind == .enum })
    }

    @Test func theServersWorkspaceSymbolsJoinTheFilter() async throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let main = pkg.path("Sources/Demo/main.swift")
        let m = try WorkspaceShellModel(url: pkg.url, engine: ScriptedEngine(lines: [], issues: []))
        let server = ShellFakeServer { method, params in
            guard method == "workspace/symbol" else { return nil }
            #expect(params["query"]?.string == "loc")
            return [["name": "localHelper()", "kind": 12, "location": ["uri": ShellLanguageTests.uri(main), "range": ShellLanguageTests.range(1, 4, 1, 15)]],
                    ["name": "elsewhere", "kind": 13, "location": ["uri": "untitled:x", "range": ShellLanguageTests.range(0, 0, 0, 1)]]]
        }
        await m.session.startLanguageService(transport: server)
        m.refreshSymbolNavigator()
        while m.symbols.isScanning { await Task.yield() }
        m.symbols.filterText = "loc"
        await m.symbols.serverQuerySettled()
        #expect(m.symbols.rows.map(\.title) == ["main.swift", "localHelper"])
        #expect(m.symbols.rows[1].kind == .function && m.symbols.rows[1].line == 2)
        #expect(SymbolNavigatorModel.kind(lsp: 23) == .struct && SymbolNavigatorModel.kind(lsp: 5) == .class)
    }
}

/// Names a scripted server was asked about, from its thread.
final class LockedNames: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ s: String) { lock.withLock { list.append(s) } }
    var names: [String] { lock.withLock { list } }
}
