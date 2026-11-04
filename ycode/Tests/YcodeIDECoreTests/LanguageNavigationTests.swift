import Foundation
import Testing
import YcodeBuild
import YcodeDebug
import YcodeLanguage
@testable import YcodeIDECore

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// A language server in memory: answers requests with `handler`, records
/// every message, and closes on `exit`.
final class ScriptedLanguageServer: DAPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var receiving: (@Sendable (Data?) -> Void)?
    private var decoder = DAPFraming.Decoder()
    private var messages: [JSON] = []
    let handler: @Sendable (JSON) -> JSON?

    init(handler: @escaping @Sendable (JSON) -> JSON? = { m in m["method"]?.string == "initialize" ? ["capabilities": [:]] : .null }) {
        self.handler = handler
    }

    var received: [JSON] { lock.withLock { messages } }
    var methods: [String] { received.compactMap { $0["method"]?.string } }

    func start(receiving: @escaping @Sendable (Data?) -> Void) throws { lock.withLock { self.receiving = receiving } }

    func send(_ data: Data) {
        let bodies = lock.withLock { decoder.append(data) }
        for body in bodies {
            guard let msg = try? JSON.decode(body) else { continue }
            lock.withLock { messages.append(msg) }
            if msg["method"]?.string == "exit" { close(); continue }
            guard let id = msg["id"], msg["method"] != nil else { continue }
            let result = handler(msg) ?? .null
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

/// Edits, the rename preview and references as Find results
/// (`specs/ide/refactoring.md`), shared by both IDEs.
@Suite struct LanguageNavigationTests {
    func edit(_ l1: Int, _ c1: Int, _ l2: Int, _ c2: Int, _ text: String) -> TextEdit {
        TextEdit(start: Position(line: l1, character: c1), end: Position(line: l2, character: c2), newText: text)
    }

    @Test func editsApplyLastFirstAndClampToTheLine() {
        let text = "let a = greet(1)\nlet b = greet(2)\n"
        let out = TextEditApplication.apply([edit(0, 8, 0, 13, "welcome"), edit(1, 8, 1, 13, "welcome")], to: text)
        #expect(out == "let a = welcome(1)\nlet b = welcome(2)\n")
        // A column past the line's end stops at it; UTF-16 columns.
        #expect(TextEditApplication.apply([edit(0, 3, 0, 99, "!")], to: "abcdef\nx") == "abc!\nx")
        #expect(TextEditApplication.apply([edit(0, 2, 0, 3, "B")], to: "\u{E9} a") == "\u{E9} B")
        let ranges = TextEditApplication.ranges([edit(1, 0, 1, 3, "var")], in: text)
        #expect(ranges.first?.range == NSRange(location: 17, length: 3) && ranges.first?.newText == "var")
    }

    @Test func renamePreviewListsEachFilesChangedLines() {
        let a = URL(fileURLWithPath: "/p/Sources/A.swift"), b = URL(fileURLWithPath: "/p/Sources/B.swift")
        let texts = [a.path: "func greet() {}\nlet x = greet()\n", b.path: "  greet()\n"]
        let e = WorkspaceEdit(changes: [b: [edit(0, 2, 0, 7, "welcome")], a: [edit(0, 5, 0, 10, "welcome"), edit(1, 8, 1, 13, "welcome")]])
        let p = RenamePreview(edit: e, oldName: "greet", newName: "welcome") { texts[$0.path] }
        #expect(p.files.map(\.name) == ["A.swift", "B.swift"])
        #expect(p.files[0].countText == "2 changes" && p.files[1].countText == "1 change")
        #expect(p.files[0].lines == [.init(line: 1, before: "func greet() {}", after: "func welcome() {}"),
                                     .init(line: 2, before: "let x = greet()", after: "let x = welcome()")])
        #expect(p.files[1].lines == [.init(line: 1, before: "greet()", after: "welcome()")])
        #expect(p.summary == "Rename 3 occurrences in 2 files" && p.editCount == 3)
        // A file that cannot be read is listed with its count only.
        let q = RenamePreview(edit: e, oldName: "greet", newName: "welcome") { _ in nil }
        #expect(q.files.allSatisfy(\.lines.isEmpty) && q.files.map(\.editCount) == [2, 1])
    }

    @Test func referencesBecomeFindResultsByFileAndLine() {
        let a = URL(fileURLWithPath: "/p/A.swift"), b = URL(fileURLWithPath: "/p/B.swift")
        let texts = ["/p/A.swift": "struct G {\n    func greet() {}\n}\n", "/p/B.swift": "G().greet()\nG().greet()\n"]
        let locs = [
            Location(url: b, start: Position(line: 1, character: 4), end: Position(line: 1, character: 9)),
            Location(url: a, start: Position(line: 1, character: 9), end: Position(line: 1, character: 14)),
            Location(url: b, start: Position(line: 0, character: 4), end: Position(line: 0, character: 9)),
            // The same place twice (declaration and definition): once.
            Location(url: b, start: Position(line: 0, character: 4), end: Position(line: 0, character: 9)),
            // A point location: the identifier there.
            Location(url: a, start: Position(line: 1, character: 9), end: Position(line: 1, character: 9)),
        ]
        let results = SymbolResults.fileResults(locs) { texts[$0] }
        #expect(results.map(\.path) == ["/p/A.swift", "/p/B.swift"])
        #expect(results[0].matches.count == 1)
        let m = results[0].matches[0]
        #expect(m.line == 2 && m.text == "func greet() {}" && m.column == 10)
        #expect((m.text as NSString).substring(with: m.highlight) == "greet" && m.matchedText == "greet")
        #expect(results[1].matches.map(\.line) == [1, 2])
        #expect(SymbolResults.referencesTitle("greet", count: 3) == "greet — 3 references")
        #expect(SymbolResults.referencesTitle("greet", count: 1) == "greet — 1 reference")
        #expect(SymbolResults.callersTitle("greet") == "Callers of greet")
    }

    @Test func theDeclarationAtALineAndTheDocumentItems() {
        let text = "struct A {\n    var x = 1\n    func f() {\n        print(x)\n    }\n}\n\nfunc g() {}\n"
        let symbols = SymbolScanner.symbols(in: text, language: .swift)
        let ns = text as NSString, index = LineIndex(text)
        #expect(DocumentSymbols.enclosing(symbols, line: 4, text: ns, index: index)?.name == "f")
        #expect(DocumentSymbols.enclosing(symbols, line: 2, text: ns, index: index)?.name == "x")
        #expect(DocumentSymbols.enclosing(symbols, line: 6, text: ns, index: index)?.name == "A")
        #expect(DocumentSymbols.enclosing(symbols, line: 7, text: ns, index: index) == nil)
        #expect(DocumentSymbols.enclosing(symbols, line: 8, text: ns, index: index)?.name == "g")
        #expect(DocumentSymbols.flattened(symbols).map { "\($0.depth)\(DocumentSymbols.badge($0.symbol.kind))\($0.symbol.name)" } == ["0SA", "1Vx", "1Ff", "0Fg"])
    }

    /// SwiftPM 6.4 (swift-build) prints progress lines, "[19 / 23]
    /// Greeter-product", not "Compiling" lines: one step per target.
    @Test func swiftBuildProgressLinesBecomeOneStepPerTarget() {
        var r = BuildReport(title: "Build Greeter", date: Date(), succeeded: true, log: [
            "Building for debugging...", "[Planning deferred tasks]", "[19 / 23] Greeter-product",
            "/p/Sources/Greeter/main.swift:4:9: warning: initialization of immutable value 'count' was never used",
            "[20\u{2009}/\u{2009}23]\u{2009}Greeter-product", "\r[21 / 23] GreeterCore", "[24 / 24] Greeter-product", "Build complete! (2.68 secs)",
        ], errorCount: 0, warningCount: 1)
        r.context.scheme = "Greeter"
        r.context.containerKind = "Package"
        let s = BuildLogModel.sections(r)
        #expect(s.map(\.target) == ["Greeter-product", "Greeter", "GreeterCore"])
        #expect(s[0].steps.map(\.title) == ["Linking Greeter"] && s[0].steps[0].children[0].title == "Link Greeter")
        #expect(s[0].steps[0].children[0].transcript.count == 3)
        // The warning is not the link step's: it goes to the scheme's Issues.
        #expect(s[1].steps.map(\.title) == ["Issues"] && s[1].steps[0].warningCount == 1)
        #expect(s[2].steps.map(\.title) == ["Building GreeterCore"])
        #expect(!BuildLogModel.isProgressLine("[3/7] Compiling Demo a.swift") && BuildLogModel.isProgressLine("[3 / 7] Demo"))
    }
}

/// The language server follows the scheme and the destination
/// (`specs/ide/language.md` §Build server, "Context changes").
@MainActor
@Suite(.serialized) struct LanguageContextTests {
    let mac = Destination(name: "My Mac", specifier: "platform=macOS,arch=arm64", platform: "macOS", kind: .mac)
    let phone = Destination(name: "iPhone 17", specifier: "platform=iOS Simulator,id=A1", platform: "iOS Simulator", kind: .simulator)

    func session(_ name: String) throws -> (WorkspaceSession, URL) {
        let dir = ycodeDir.appendingPathComponent(".build-ide/lang-context/\(name)-\(UUID().uuidString)")
        let proj = try writeToolProject(at: dir)
        return (WorkspaceSession(model: try WorkspaceModel(url: proj)), dir)
    }

    @Test func destinationChangeRestartsTheServerWithTheOpenDocuments() async throws {
        let (s, dir) = try session("restart")
        defer { try? FileManager.default.removeItem(at: dir) }
        s.scheme = "Tool"
        s.destination = mac
        var servers: [ScriptedLanguageServer] = []
        let first = ScriptedLanguageServer()
        s.languageTransportFactory = {
            let n = ScriptedLanguageServer()
            servers.append(n)
            return n
        }
        await s.startLanguageService(transport: first)
        let service = try #require(s.language)
        #expect(s.languageServedContext == LanguageBuildContext(scheme: "Tool", destination: mac.specifier))
        var applied: [WorkspaceEdit] = []
        service.onApplyEdit = { applied.append($0) }
        let main = dir.appendingPathComponent("Tool/main.swift")
        service.open(main, text: "print(1)\n")
        service.change(main, text: "print(2)\n")

        // The same destination again: nothing to do.
        s.destination = mac
        await s.languageContextSettled()
        #expect(s.languageRestartCount == 0 && s.language === service)

        s.destination = phone
        await s.languageContextSettled()
        #expect(s.languageRestartCount == 1)
        #expect(first.methods.contains("shutdown") && first.methods.contains("exit"))
        let second = try #require(servers.first)
        #expect(second.methods.prefix(2) == ["initialize", "initialized"])
        let reopened = second.received.first { $0["method"]?.string == "textDocument/didOpen" }
        #expect(reopened?["params"]?["textDocument"]?["text"]?.string == "print(2)\n")
        #expect(s.languageServedContext == LanguageBuildContext(scheme: "Tool", destination: phone.specifier))
        // The window's edit handler carries over.
        let new = try #require(s.language)
        #expect(new !== service)
        new.onApplyEdit?(WorkspaceEdit(changes: [:]))
        #expect(applied.count == 1)

        // A scheme change too; a burst of changes restarts once.
        s.scheme = "Other"
        s.destination = mac
        s.scheme = "Tool"
        await s.languageContextSettled()
        #expect(s.languageRestartCount == 2 && servers.count == 2)
        #expect(s.languageServedContext == LanguageBuildContext(scheme: "Tool", destination: mac.specifier))
    }

    @Test func packagesAndServersWithoutAContextDoNotRestart() async throws {
        let dir = ycodeDir.appendingPathComponent(".build-ide/lang-context/pkg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sources/P"), withIntermediateDirectories: true)
        try "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"P\", targets: [.target(name: \"P\")])\n"
            .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "public let p = 1\n".write(to: dir.appendingPathComponent("Sources/P/P.swift"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pkg = WorkspaceSession(model: try WorkspaceModel(url: dir))
        pkg.languageTransportFactory = { ScriptedLanguageServer() }
        await pkg.startLanguageService(transport: ScriptedLanguageServer())
        #expect(pkg.languageServedContext == nil)
        pkg.destination = phone
        await pkg.languageContextSettled()
        #expect(pkg.languageRestartCount == 0)

        // A project whose server came from a transport without a factory
        // (no build server to follow): left alone.
        let (s, pdir) = try session("no-factory")
        defer { try? FileManager.default.removeItem(at: pdir) }
        await s.startLanguageService(transport: ScriptedLanguageServer())
        #expect(s.languageServedContext == nil)
        s.destination = phone
        await s.languageContextSettled()
        #expect(s.languageRestartCount == 0)
    }

    /// The build server's command line names the new destination: the
    /// connection file sourcekit-lsp starts it from.
    @Test func theConnectionFileNamesTheNewContext() throws {
        let folder = ycodeDir.appendingPathComponent(".build-ide/lang-context/bsp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let container = URL(fileURLWithPath: "/w/Tool.xcodeproj")
        for d in [mac, phone] {
            let file = try BuildServerLaunch.writeConfig(argv: BuildServerLaunch.argv(server: "/bin/ycode-bsp", container: container, scheme: "Tool",
                                                                                      destination: d.specifier), into: folder)
            let argv = try JSON.decode(Data(contentsOf: file))["argv"]?.array?.compactMap(\.string) ?? []
            #expect(argv.suffix(4) == ["--scheme", "Tool", "--destination", d.specifier])
        }
    }
}
