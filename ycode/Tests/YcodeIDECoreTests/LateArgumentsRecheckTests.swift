import Foundation
import Testing
import YcodeBuild
import YcodeDebug
import YcodeLanguage
@testable import YcodeIDECore

/// P-070 (beta 5): a document diagnosed before the build server's arguments
/// arrived ("Cannot find 'Counter' in scope" with fallback settings) is sent
/// again once, a while after its errors came, even when no work progress
/// ends afterwards; a real error comes back the same and is not sent again.
@MainActor
@Suite(.serialized) struct LateArgumentsRecheckTests {
    /// Publishes `first` for the opened document, `later` for every resend.
    final class Server: DAPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var receiving: (@Sendable (Data?) -> Void)?
        private var decoder = DAPFraming.Decoder()
        let first: [String], later: [String]
        private(set) var changes = 0
        init(first: [String], later: [String]) { self.first = first; self.later = later }

        func start(receiving: @escaping @Sendable (Data?) -> Void) throws { lock.withLock { self.receiving = receiving } }

        func reply(_ msg: JSON) {
            let r = lock.withLock { receiving }
            r?(DAPFraming.frame(msg.encoded()))
        }

        func publish(_ uri: JSON, _ messages: [String]) {
            let d: [JSON] = messages.map { m in
                ["range": ["start": ["line": 3, "character": 4], "end": ["line": 3, "character": 11]], "severity": 1, "message": .string(m)]
            }
            reply(["jsonrpc": "2.0", "method": "textDocument/publishDiagnostics", "params": ["uri": uri, "diagnostics": .array(d)]])
        }

        func send(_ data: Data) {
            let bodies = lock.withLock { decoder.append(data) }
            for body in bodies {
                guard let msg = try? JSON.decode(body) else { continue }
                let method = msg["method"]?.string
                if method == "exit" { close(); continue }
                if method == "textDocument/didOpen", let uri = msg["params"]?["textDocument"]?["uri"] { publish(uri, first) }
                if method == "textDocument/didChange", let uri = msg["params"]?["textDocument"]?["uri"] {
                    lock.withLock { changes += 1 }
                    publish(uri, later)
                }
                guard let id = msg["id"], method != nil else { continue }
                reply(["jsonrpc": "2.0", "id": id, "result": method == "initialize" ? ["capabilities": [:]] : .null])
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

    func session() throws -> (WorkspaceSession, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("b5-late-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        try "// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: \"App\", targets: [.executableTarget(name: \"App\")])\n"
            .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let file = dir.appendingPathComponent("Sources/App/ContentView.swift")
        try "struct ContentView {\n    var counter = Counter()\n}\n".write(to: file, atomically: true, encoding: .utf8)
        return (WorkspaceSession(model: try WorkspaceModel(url: dir)), file)
    }

    func errors(_ s: WorkspaceSession, _ file: URL) -> [String] {
        (s.language?.liveDiagnostics[file.standardizedFileURL.path] ?? []).filter { $0.severity == 1 }.map(\.message)
    }

    func poll(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    @Test func fallbackErrorsGoOnceTheDocumentIsSentAgain() async throws {
        let saved = LanguageService.lateRecheckDelay
        LanguageService.lateRecheckDelay = .milliseconds(300)
        defer { LanguageService.lateRecheckDelay = saved }
        let (s, file) = try session()
        let server = Server(first: ["Cannot find 'Counter' in scope"], later: [])
        await s.startLanguageService(opening: [(file, try String(contentsOf: file, encoding: .utf8))], transport: server)
        #expect(errors(s, file) == ["Cannot find 'Counter' in scope"])
        #expect(await poll(5) { errors(s, file).isEmpty }, "\(errors(s, file))")
        #expect(server.changes == 1)
        await s.language?.stop()
    }

    @Test func aRealErrorIsSentAgainOnlyOnce() async throws {
        let saved = LanguageService.lateRecheckDelay
        LanguageService.lateRecheckDelay = .milliseconds(200)
        defer { LanguageService.lateRecheckDelay = saved }
        let (s, file) = try session()
        let real = ["Cannot convert value of type 'String' to specified type 'Int'"]
        let server = Server(first: real, later: real)
        await s.startLanguageService(opening: [(file, try String(contentsOf: file, encoding: .utf8))], transport: server)
        _ = await poll(3) { server.changes >= 1 }
        try await Task.sleep(for: .milliseconds(1000))
        #expect(server.changes == 1 && errors(s, file) == real)
        await s.language?.stop()
    }
}
