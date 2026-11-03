import Foundation
import Testing
@testable import YcodeAssistant

@Suite struct JSONRPCTests {
    @Test func jsonKeepsBooleansAndNumbersApartAndWritesOneLine() throws {
        let v = try AnyJSON.parse(#"{"a": true, "b": 1, "c": 1.5, "d": "x\ny", "e": [null, false, 0], "f": {}}"#)
        #expect(v["a"] == .bool(true) && v["b"] == .int(1) && v["c"] == .double(1.5))
        #expect(v["e"] == [.null, .bool(false), .int(0)])
        #expect(v["d"]?.string == "x\ny")
        let text = v.text
        #expect(!text.contains("\n"))
        #expect(try AnyJSON.parse(text) == v)
        // Sorted keys, slashes not escaped.
        #expect(AnyJSON.object(["b": "/x", "a": 1]).text == #"{"a":1,"b":"/x"}"#)
        #expect(AnyJSON.double(3).int == 3 && AnyJSON.double(3.5).int == nil)
    }

    @Test func messagesParseAndSerialize() throws {
        #expect(try JSONRPCMessage.parse(Data(#"{"jsonrpc":"2.0","id":7,"method":"ping"}"#.utf8)) == .request(id: .int(7), method: "ping", params: nil))
        #expect(try JSONRPCMessage.parse(Data(#"{"jsonrpc":"2.0","id":"a","method":"m","params":{"x":1}}"#.utf8))
                == .request(id: .string("a"), method: "m", params: ["x": 1]))
        #expect(try JSONRPCMessage.parse(Data(#"{"jsonrpc":"2.0","method":"n"}"#.utf8)) == .notification(method: "n", params: nil))
        #expect(try JSONRPCMessage.parse(Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)) == .result(id: .int(1), result: [:]))
        let e = try JSONRPCMessage.parse(Data(#"{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"no"}}"#.utf8))
        #expect(e == .error(id: .int(1), error: JSONRPCError(code: -32601, message: "no")))
        // Not JSON-RPC 2.0, batches, null ids on requests, garbage.
        #expect(throws: JSONRPCError.self) { try JSONRPCMessage.parse(Data(#"{"id":1,"method":"m"}"#.utf8)) }
        #expect(throws: JSONRPCError.self) { try JSONRPCMessage.parse(Data(#"[{"jsonrpc":"2.0","method":"m"}]"#.utf8)) }
        #expect(throws: JSONRPCError.self) { try JSONRPCMessage.parse(Data(#"{"jsonrpc":"2.0","id":null,"method":"m"}"#.utf8)) }
        do {
            _ = try JSONRPCMessage.parse(Data("{nope".utf8))
            Issue.record("parsed garbage")
        } catch let err as JSONRPCError {
            #expect(err.code == -32700)
        }
        let line = JSONRPCMessage.request(id: .int(1), method: "m", params: ["s": "a\nb"]).line
        #expect(line.last == 0x0A && line.dropLast().allSatisfy { $0 != 0x0A })
    }

    @Test func framingSplitsLinesAcrossReads() {
        var f = LineFramer()
        #expect(f.append(Data("{\"a\":1}\n{\"b\"".utf8)) == [Data("{\"a\":1}".utf8)])
        #expect(f.append(Data(":2}\r\n\n".utf8)) == [Data("{\"b\":2}".utf8)])
        #expect(f.append(Data("tail".utf8)).isEmpty)
        #expect(f.flush() == Data("tail".utf8))
        #expect(f.flush() == nil)
    }

    /// Two peers wired back to back.
    static func pair() -> (JSONRPCPeer, JSONRPCPeer) {
        final class Box: @unchecked Sendable { var a: JSONRPCPeer?; var b: JSONRPCPeer? }
        let box = Box()
        let a = JSONRPCPeer { data in DispatchQueue.global().async { box.b?.receive(data.dropLast()) } }
        let b = JSONRPCPeer { data in DispatchQueue.global().async { box.a?.receive(data.dropLast()) } }
        box.a = a
        box.b = b
        return (a, b)
    }

    @Test func peersAnswerRequestsAndReportErrors() async throws {
        let (client, server) = Self.pair()
        server.onRequest { _, method, params in
            { () async throws -> AnyJSON in
                switch method {
                case "add": return .int((params?["a"]?.int ?? 0) + (params?["b"]?.int ?? 0))
                case "fail": throw JSONRPCError.invalidParams("bad")
                default: throw JSONRPCError.methodNotFound(method)
                }
            }
        }
        let got = try await client.request("add", ["a": 2, "b": 3])
        #expect(got == .int(5))
        await #expect(throws: JSONRPCError.invalidParams("bad")) { try await client.request("fail") }
        do {
            _ = try await client.request("nope")
            Issue.record("no error")
        } catch let e as JSONRPCError {
            #expect(e.code == -32601)
        }
        // Concurrent requests are matched by id.
        async let x = client.request("add", ["a": 1, "b": 1])
        async let y = client.request("add", ["a": 10, "b": 10])
        #expect(try await [x, y] == [.int(2), .int(20)])
    }

    @Test func aCancelledRequestGetsNoReplyAndClosingFailsWaiters() async throws {
        let (client, server) = Self.pair()
        final class Flag: @unchecked Sendable { var cancelled = false }
        let flag = Flag()
        server.onRequest { _, _, _ in
            {
                do { try await Task.sleep(for: .seconds(30)) } catch { flag.cancelled = true; throw error }
                return .null
            }
        }
        server.onNotification { method, params in
            if method == "notifications/cancelled", let id = JSONRPCID(params?["requestId"]) { server.cancelIncoming(id) }
        }
        let waiting = Task { try await client.request("slow") }
        try await Task.sleep(for: .milliseconds(200))
        #expect(server.incomingCount == 1)
        client.notify("notifications/cancelled", ["requestId": 0])
        try await Task.sleep(for: .milliseconds(300))
        #expect(flag.cancelled && server.incomingCount == 0)
        client.close(JSONRPCError(code: -1, message: "closed"))
        await #expect(throws: JSONRPCError(code: -1, message: "closed")) { try await waiting.value }
    }
}
