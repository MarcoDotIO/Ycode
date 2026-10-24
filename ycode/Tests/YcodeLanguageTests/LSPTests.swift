import Foundation
import Testing
import YcodeDebug
@testable import YcodeLanguage

/// An in-memory server that answers each request with `handler`.
final class FakeServer: DAPTransport, @unchecked Sendable {
    var receiving: (@Sendable (Data?) -> Void)?
    var decoder = DAPFraming.Decoder()
    var received: [JSON] = []
    let handler: (JSON) -> JSON?

    init(handler: @escaping (JSON) -> JSON?) { self.handler = handler }
    func start(receiving: @escaping @Sendable (Data?) -> Void) throws { self.receiving = receiving }
    func push(_ msg: JSON) { receiving?(DAPFraming.frame(msg.encoded())) }

    func send(_ data: Data) {
        for body in decoder.append(data) {
            let msg = try! JSON.decode(body)
            received.append(msg)
            guard let id = msg["id"], msg["method"] != nil else { continue }
            if let result = handler(msg) {
                push(["jsonrpc": "2.0", "id": id, "result": result])
            } else {
                push(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "nope"]])
            }
        }
    }
    func close() { receiving?(nil) }
}

@Suite struct LSPClientTests {
    @Test func requestsNotificationsAndServerRequests() async throws {
        let server = FakeServer { msg in
            switch msg["method"]?.string {
            case "initialize": ["capabilities": ["completionProvider": [:]]]
            case "textDocument/completion": ["isIncomplete": false, "items": [
                ["label": "greet(times:)", "insertText": "greet(times:)", "detail": "String", "kind": 2],
                ["label": "name", "textEdit": ["newText": "name", "range": ["start": ["line": 3, "character": 2], "end": ["line": 3, "character": 2]]]],
            ]]
            case "textDocument/definition": [["uri": "file:///p/a.swift", "range": ["start": ["line": 1, "character": 7], "end": ["line": 1, "character": 14]]]]
            default: nil
            }
        }
        let client = try LSPClient(transport: server)
        try await client.initialize(root: URL(fileURLWithPath: "/p"))
        #expect(client.capabilities["completionProvider"] != nil)
        #expect(server.received.map { $0["method"]?.string } == ["initialize", "initialized"])

        let file = URL(fileURLWithPath: "/p/a.swift")
        client.didOpen(file, text: "let x = 1")
        client.didChange(file, text: "let x = 2", version: 2)
        #expect(server.received[3]["params"]?["contentChanges"]?.array?.first?["text"] == "let x = 2")

        let items = try await client.completion(file, at: Position(line: 3, character: 2))
        #expect(items.map(\.label) == ["greet(times:)", "name"])
        #expect(items[1].replaceStart == Position(line: 3, character: 2))
        let defs = try await client.definition(file, at: Position(line: 5, character: 9))
        #expect(defs.first?.url.path == "/p/a.swift" && defs.first?.start == Position(line: 1, character: 7))
        await #expect(throws: LSPClient.ResponseError.self) { try await client.request("unknown/method") }

        // A server request is answered; a notification is delivered.
        server.push(["jsonrpc": "2.0", "id": 99, "method": "workspace/configuration", "params": ["items": [[:], [:]]]])
        #expect(server.received.last?["id"]?.int == 99 && server.received.last?["result"]?.array?.count == 2)
        server.push(["jsonrpc": "2.0", "method": "textDocument/publishDiagnostics", "params": [
            "uri": "file:///p/a.swift",
            "diagnostics": [["range": ["start": ["line": 0, "character": 4], "end": ["line": 0, "character": 5]], "severity": 2, "message": "unused"]],
        ]])
        server.close()
        var notes: [LSPClient.Notification] = []
        for await n in client.notifications { notes.append(n) }
        let (url, diags) = try #require(LSPDiagnostic.published(notes[0].params))
        #expect(url.path == "/p/a.swift" && diags.first?.severity == 2 && diags.first?.start.character == 4)
    }
}

/// Talks to the real sourcekit-lsp about a small package (headless).
@Suite(.serialized, .timeLimit(.minutes(3))) struct SourceKitLSPEndToEndTests {
    static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent(".build-ide/lsp-e2e")

    static let source = """
    struct Greeter {
        let name: String
        func greet(times: Int) -> String { String(repeating: name, count: times) }
    }

    let g = Greeter(name: "Ycode")
    print(g.greet(times: 2))
    print(missing)

    """

    @Test func diagnosticsCompletionDefinition() async throws {
        guard let server = SourceKitLSP.locate() else { return }
        let src = Self.dir.appendingPathComponent("Sources/E2E")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"E2E\", targets: [.executableTarget(name: \"E2E\")])\n"
            .write(to: Self.dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let file = src.appendingPathComponent("main.swift")
        try Self.source.write(to: file, atomically: true, encoding: .utf8)

        let client = try LSPClient(transport: ProcessTransport(executable: server))
        defer { client.close() }
        try await client.initialize(root: Self.dir)
        client.didOpen(file, text: Self.source)

        // Diagnostics arrive as notifications; wait for the semantic error.
        var it = client.notifications.makeAsyncIterator()
        var found: [LSPDiagnostic] = []
        while let n = await it.next() {
            guard n.method == "textDocument/publishDiagnostics", let (url, d) = LSPDiagnostic.published(n.params),
                  url.standardizedFileURL.path == file.standardizedFileURL.path else { continue }
            if d.contains(where: { $0.message.contains("missing") }) { found = d; break }
        }
        let missing = try #require(found.first { $0.message.contains("missing") })
        #expect(missing.severity == 1 && missing.start.line == 7)

        // Completion after `g.` on line 7 (0-based 6).
        let items = try await client.completion(file, at: Position(line: 6, character: 8))
        #expect(items.contains { $0.label.hasPrefix("greet(times:") })
        #expect(items.contains { $0.label == "name" })

        // Definition of `Greeter` at its use on line 6 (0-based 5).
        let defs = try await client.definition(file, at: Position(line: 5, character: 10))
        #expect(defs.first?.start.line == 0)

        // Document highlights of `Greeter`: its declaration and its use.
        let highlights = try await client.documentHighlights(file, at: Position(line: 5, character: 10))
        #expect(Set(highlights.map(\.start.line)) == [0, 5])
        await client.shutdown()
    }
}
