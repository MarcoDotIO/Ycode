import Foundation
import Testing
import YcodeDebug
@testable import YcodeLanguage

/// A server that reads requests and never answers (a hung language server).
final class SilentServer: DAPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var decoder = DAPFraming.Decoder()
    private var messages: [JSON] = []
    private(set) var receiving: (@Sendable (Data?) -> Void)?
    func start(receiving: @escaping @Sendable (Data?) -> Void) throws { self.receiving = receiving }
    func send(_ data: Data) {
        lock.lock()
        for body in decoder.append(data) { if let m = try? JSON.decode(body) { messages.append(m) } }
        lock.unlock()
    }
    func close() {}
    var received: [JSON] { lock.lock(); defer { lock.unlock() }; return messages }
    func push(_ msg: JSON) { receiving?(DAPFraming.frame(msg.encoded())) }
}

/// Requests end when their task is cancelled; shutdown does not wait for a
/// server that never answers (a hung server held QuickHelpTests past its
/// time limit for an hour).
@Suite struct LSPCancellationTests {
    func waitFor(_ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(10)
        while !cond() {
            if Date() > end { return false }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return true
    }

    @Test func cancellingARequestEndsItAndTellsTheServer() async throws {
        let server = SilentServer()
        let client = try LSPClient(transport: server)
        let task = Task { try await client.request("textDocument/hover", ["x": 1]) }
        #expect(await waitFor { server.received.contains { $0["method"]?.string == "textDocument/hover" } })
        let id = try #require(server.received.first { $0["method"]?.string == "textDocument/hover" }?["id"])
        task.cancel()
        let start = Date()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(server.received.contains { $0["method"]?.string == "$/cancelRequest" && $0["params"]?["id"] == id })
        // A late answer for it is ignored; the next request still works.
        server.push(["jsonrpc": "2.0", "id": id, "result": "late"])
        let next = Task { try await client.request("textDocument/definition") }
        #expect(await waitFor { server.received.contains { $0["method"]?.string == "textDocument/definition" } })
        let nextID = try #require(server.received.first { $0["method"]?.string == "textDocument/definition" }?["id"])
        server.push(["jsonrpc": "2.0", "id": nextID, "result": "here"])
        #expect(try await next.value == "here")
    }

    @Test func aRequestFromACancelledTaskIsNotSent() async throws {
        let server = SilentServer()
        let client = try LSPClient(transport: server)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.request("textDocument/hover")
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!server.received.contains { $0["method"]?.string == "textDocument/hover" })
    }

    @Test func shutdownDoesNotWaitForASilentServer() async throws {
        let server = SilentServer()
        let client = try LSPClient(transport: server)
        let start = Date()
        await client.shutdown(timeout: 0.3)
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(server.received.map { $0["method"]?.string } == ["shutdown", "$/cancelRequest", "exit"])
    }
}
