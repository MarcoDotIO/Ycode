import Foundation
import Testing
@testable import YcodeDebug
@testable import YcodeUI

/// A minimal in-memory adapter for the debug.md audit items: two frames,
/// one expandable variable, a failing `evaluate`.
private final class AuditAdapter: DAPTransport, @unchecked Sendable {
    var receiving: (@Sendable (Data?) -> Void)?
    var decoder = DAPFraming.Decoder()
    private(set) var requests: [JSON] = []
    private let lock = NSRecursiveLock()
    private var seq = 500

    func start(receiving: @escaping @Sendable (Data?) -> Void) throws { self.receiving = receiving }
    func close() { receiving?(nil) }
    func count(_ cmd: String) -> Int { lock.withLock { requests.filter { $0["command"]?.string == cmd }.count } }
    func last(_ cmd: String) -> JSON? { lock.withLock { requests.last { $0["command"]?.string == cmd } } }

    private func emit(_ o: [String: JSON]) {
        seq += 1
        var o = o
        o["seq"] = .number(Double(seq))
        receiving?(DAPFraming.frame(JSON.object(o).encoded()))
    }

    func send(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        for raw in decoder.append(data) {
            let req = try! JSON.decode(raw)
            guard req["type"]?.string == "request", let cmd = req["command"]?.string else { continue }
            requests.append(req)
            let args = req["arguments"] ?? .null
            var body: JSON = [:]
            var ok = true
            var after: [(String, JSON)] = []
            switch cmd {
            case "initialize": after = [("initialized", [:])]
            case "configurationDone": after = [("stopped", ["reason": "breakpoint", "threadId": 1])]
            case "threads": body = ["threads": [["id": 1, "name": "Thread 1"]]]
            case "stackTrace": body = ["stackFrames": [["id": 1, "name": "inner", "line": 3, "source": ["path": "/tmp/a.c"]],
                                                       ["id": 2, "name": "outer", "line": 9, "source": ["path": "/tmp/a.c"]]]]
            case "scopes": body = ["scopes": [["name": "Locals", "variablesReference": .number(Double(10 + (args["frameId"]?.int ?? 0))), "expensive": false]]]
            case "variables":
                let ref = args["variablesReference"]?.int ?? 0
                body = ref >= 100 ? ["variables": [["name": "x", "value": "1", "variablesReference": 0]]]
                    : ["variables": [["name": .string("p\(ref)"), "value": "{...}", "variablesReference": 100]]]
            case "evaluate":
                if args["expression"]?.string == "bad" { ok = false; body = ["error": ["format": "use of undeclared identifier 'bad'"]] }
                else { body = ["result": .string("frame \(args["frameId"]?.int ?? 0)"), "variablesReference": 0] }
            case "continue": after = [("continued", ["threadId": 1])]
            default: break
            }
            emit(["type": "response", "request_seq": req["seq"]!, "command": .string(cmd), "success": .bool(ok), "body": body])
            for (n, b) in after { emit(["type": "event", "event": .string(n), "body": b]) }
        }
    }
}

@MainActor
@Suite(.serialized, .heavyIntegration) struct DebugAuditTests {
    private func pausedSession() async throws -> (WorkspaceSession, AuditAdapter) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-dbgaudit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"D\")\n"
            .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let session = WorkspaceSession(model: try WorkspaceModel(url: dir))
        let adapter = AuditAdapter()
        await session.attach(to: "77", adapter: adapter)
        #expect(await waitUntil(30) { session.stoppedThread == 1 && !session.variables.isEmpty })
        return (session, adapter)
    }

    @Test func childrenAreFetchedOncePerStop() async throws {
        let (session, adapter) = try await pausedSession()
        let before = adapter.count("variables")
        _ = await session.children(of: 100)
        let kids = await session.children(of: 100)
        #expect(kids.map(\.name) == ["x"])
        #expect(adapter.count("variables") == before + 1)
        // A reload (here: selecting another frame) invalidates them.
        await session.selectFrame(2)
        let afterSelect = adapter.count("variables")
        _ = await session.children(of: 100)
        #expect(adapter.count("variables") == afterSelect + 1)
        session.stop()
    }

    @Test func selectingAFrameReevaluatesWatches() async throws {
        let (session, adapter) = try await pausedSession()
        session.watchExpressions = ["w"]
        #expect(await waitUntil(30) { session.watchValues.first?.value == "frame 1" })
        await session.selectFrame(2)
        #expect(session.selectedFrameID == 2)
        #expect(session.watchValues.first?.value == "frame 2")
        #expect(adapter.last("evaluate")?["arguments"]?["context"]?.string == "watch")
        session.stop()
    }

    @Test func consoleErrorsPrintAdapterMessage() async throws {
        let (session, _) = try await pausedSession()
        let r = await session.evaluateInConsole("bad")
        #expect(r == nil)
        let text = session.consoleText(.debugger)
        #expect(text.contains("(lldb) bad\nerror: use of undeclared identifier 'bad'\n"))
        #expect(!text.contains("evaluate:"))
        session.stop()
    }
}
