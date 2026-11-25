import Foundation
import Testing
import YcodeBuild
import YcodeDebug
import YcodeLanguage
@testable import YcodeIDECore

/// Council round 8, row 201 (completing row 189), shared by both IDEs: a
/// workspace that opens with editors shows the preparing subtitle from the
/// language server's start until the server has published diagnostics for
/// each of them, then the indexing subtitle while it reports progress.
@MainActor
@Suite(.serialized) struct EditorServicesPreparationTests {
    /// A server that answers `initialize`, then publishes empty diagnostics
    /// for each opened document after `delay`.
    final class Server: DAPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var receiving: (@Sendable (Data?) -> Void)?
        private var decoder = DAPFraming.Decoder()
        let delay: Double
        let publishes: Bool
        /// Holds every publication until `release()` (a test decides when
        /// the server answers, not the clock).
        let held: Bool
        private var pending: [JSON] = []
        private var released = false
        private var openCount = 0
        init(delay: Double, publishes: Bool = true, held: Bool = false) {
            self.delay = delay
            self.publishes = publishes
            self.held = held
        }

        /// The documents opened so far.
        var opened: Int { lock.withLock { openCount } }

        /// Publishes what was held, and from now on at once.
        func release() {
            let out = lock.withLock { () -> [JSON] in
                released = true
                defer { pending = [] }
                return pending
            }
            for m in out { reply(m) }
        }

        private func publish(_ uri: JSON) {
            let m: JSON = ["jsonrpc": "2.0", "method": "textDocument/publishDiagnostics", "params": ["uri": uri, "diagnostics": []]]
            let hold = lock.withLock { () -> Bool in
                guard held, !released else { return false }
                pending.append(m)
                return true
            }
            if !hold { reply(m) }
        }

        func start(receiving: @escaping @Sendable (Data?) -> Void) throws { lock.withLock { self.receiving = receiving } }

        func reply(_ msg: JSON) {
            let r = lock.withLock { receiving }
            r?(DAPFraming.frame(msg.encoded()))
        }

        func send(_ data: Data) {
            let bodies = lock.withLock { decoder.append(data) }
            for body in bodies {
                guard let msg = try? JSON.decode(body) else { continue }
                let method = msg["method"]?.string
                if method == "exit" { close(); continue }
                if method == "textDocument/didOpen" { lock.withLock { openCount += 1 } }
                if method == "textDocument/didOpen", publishes, let uri = msg["params"]?["textDocument"]?["uri"] {
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in publish(uri) }
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
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("r8-prep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        try "// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: \"App\", targets: [.executableTarget(name: \"App\")])\n"
            .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let file = dir.appendingPathComponent("Sources/App/main.swift")
        try "print(1)\n".write(to: file, atomically: true, encoding: .utf8)
        return (WorkspaceSession(model: try WorkspaceModel(url: dir)), file)
    }

    /// Waits (up to `limit`) until `done` holds; the main actor stays free
    /// meanwhile, so a loaded run only takes longer.
    func waitUntil(_ limit: Duration = .seconds(20), _ done: () -> Bool) async -> Bool {
        let end = ContinuousClock.now + limit
        while !done(), ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(10)) }
        return done()
    }

    /// The server answers when the test releases it, not after a delay, so
    /// the checks hold at any load (they used to rest on a 200 ms sleep
    /// and a 400 ms answer, which a loaded full run could overrun).
    @Test func subtitleStaysUntilTheRestoredEditorsHaveTheirFirstAnswer() async throws {
        let (s, file) = try session()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        var seen: [String] = []
        s.observe { c in if c == .activity { seen.append(WorkspaceChrome.idleActivityText(preparingEditorServices: s.isPreparingEditorServices, indexing: s.isIndexing)) } }
        let server = Server(delay: 0, held: true)
        let task = Task { await s.startLanguageService(opening: [(file, "print(1)\n")], transport: server) }
        // Started, the document opened, no answer yet: still preparing,
        // however long the answer takes.
        #expect(await waitUntil { s.language != nil && server.opened == 1 })
        #expect(s.isPreparingEditorServices)
        try await Task.sleep(for: .milliseconds(300))
        #expect(s.isPreparingEditorServices && s.language?.liveDiagnostics[file.standardizedFileURL.path] == nil)
        // The first answer ends it.
        server.release()
        await task.value
        #expect(!s.isPreparingEditorServices)
        #expect(s.language?.liveDiagnostics[file.standardizedFileURL.path] != nil)
        #expect(seen.first == WorkspaceChrome.preparingEditorServicesText && seen.last == "")
        await s.language?.stop()
    }

    @Test func aServerThatNeverAnswersEndsTheSubtitleAtTheTimeout() async throws {
        let (s, file) = try session()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        await s.startLanguageService(opening: [(file, "print(1)\n")], transport: Server(delay: 0, publishes: false), timeout: .milliseconds(300))
        #expect(!s.isPreparingEditorServices && s.language != nil)
        // Without restored editors the subtitle ends with the start (row 141).
        let (t, f2) = try session()
        defer { try? FileManager.default.removeItem(at: f2.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        await t.startLanguageService(opening: [], transport: Server(delay: 0))
        #expect(!t.isPreparingEditorServices)
        await s.language?.stop()
        await t.language?.stop()
    }
}
