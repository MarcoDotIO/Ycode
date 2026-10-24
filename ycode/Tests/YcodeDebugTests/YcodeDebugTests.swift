import Foundation
import Testing
@testable import YcodeDebug

/// An in-memory adapter: decodes each request and answers with `handler`.
final class FakeAdapter: DAPTransport, @unchecked Sendable {
    var receiving: (@Sendable (Data?) -> Void)?
    var decoder = DAPFraming.Decoder()
    var requests: [JSON] = []
    let handler: (JSON) -> (body: JSON?, success: Bool, events: [JSON])
    private var seq = 1000

    init(handler: @escaping (JSON) -> (body: JSON?, success: Bool, events: [JSON])) { self.handler = handler }

    func start(receiving: @escaping @Sendable (Data?) -> Void) throws { self.receiving = receiving }

    func send(_ data: Data) {
        for body in decoder.append(data) {
            let req = try! JSON.decode(body)
            guard req["type"]?.string == "request" else { continue }
            requests.append(req)
            let (b, ok, events) = handler(req)
            seq += 1
            var resp: [String: JSON] = ["seq": .number(Double(seq)), "type": "response", "request_seq": req["seq"]!,
                                        "command": req["command"]!, "success": .bool(ok)]
            if let b { resp["body"] = b }
            // Deliver in two chunks to exercise reassembly.
            let framed = DAPFraming.frame(JSON.object(resp).encoded())
            receiving?(framed.prefix(7))
            receiving?(framed.dropFirst(7))
            for e in events { receiving?(DAPFraming.frame(e.encoded())) }
        }
    }

    func close() { receiving?(nil) }
}

@Suite struct DAPTests {
    @Test func framingRoundTrip() {
        var d = DAPFraming.Decoder()
        let a = DAPFraming.frame(Data("{\"a\":1}".utf8)), b = DAPFraming.frame(Data("[]".utf8))
        let all = a + b
        #expect(d.append(all.prefix(10)).isEmpty)
        #expect(d.append(all.dropFirst(10)) == [Data("{\"a\":1}".utf8), Data("[]".utf8)])
    }

    @Test func jsonCodable() throws {
        let j: JSON = ["n": 3, "b": true, "s": "x", "a": [nil, .number(1.5)]]
        #expect(try JSON.decode(j.encoded()) == j)
    }

    @Test func sessionFlow() async throws {
        let adapter = FakeAdapter { req in
            switch req["command"]!.string! {
            case "initialize": (["supportsConfigurationDoneRequest": true], true, [["type": "event", "seq": 1, "event": "initialized"]])
            case "setBreakpoints": (["breakpoints": [["id": 1, "verified": true, "line": 7]]], true, [])
            case "threads": (["threads": [["id": 42, "name": "main"]]], true, [])
            case "stackTrace": (["stackFrames": [["id": 9, "name": "main", "line": 7, "column": 1, "source": ["path": "/a.swift"]]]], true, [])
            case "scopes": (["scopes": [["name": "Locals", "variablesReference": 5, "expensive": false]]], true, [])
            case "variables": (["variables": [["name": "x", "value": "1", "type": "Int", "variablesReference": 0]]], true, [])
            case "launch": (nil, false, [])
            default: (nil, true, [["type": "event", "seq": 2, "event": "output", "body": ["category": "stdout", "output": "hi\n"]]])
            }
        }
        let client = try DAPClient(transport: adapter)
        let caps = try await client.initialize()
        #expect(caps["supportsConfigurationDoneRequest"]?.bool == true)
        let bps = try await client.setBreakpoints(file: "/a.swift", lines: [7])
        #expect(bps.first?.verified == true && bps.first?.line == 7)
        await #expect(throws: DAPError.self) { try await client.launch(program: "/bin/a") }
        try await client.configurationDone()
        let t = try await client.threads()
        #expect(t == [DebugThread(["id": 42, "name": "main"])])
        let f = try await client.stackTrace(threadID: 42)
        #expect(f.first?.file == "/a.swift")
        let s = try await client.scopes(frameID: 9)
        let v = try await client.variables(reference: s[0].variablesReference)
        #expect(v == [Variable(name: "x", value: "1", type: "Int")])
        try await client.next(threadID: 42)
        #expect(adapter.requests.last?["arguments"]?["threadId"]?.int == 42)
        #expect(adapter.requests.map { $0["seq"]!.int! } == Array(1...adapter.requests.count))

        adapter.close()
        var names: [String] = []
        for await e in client.events { names.append(e.event) }
        #expect(names == ["initialized", "output", "output"])
        await #expect(throws: DAPError.self) { try await client.threads() }
    }
}
