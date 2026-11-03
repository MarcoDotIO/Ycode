import Foundation

/// A JSON-RPC 2.0 request ID: a number or a string (never null in MCP).
public enum JSONRPCID: Hashable, Sendable, CustomStringConvertible {
    case int(Int)
    case string(String)

    public init?(_ v: AnyJSON?) {
        switch v {
        case .int(let i)?: self = .int(i)
        case .string(let s)?: self = .string(s)
        case .double(let d)? where d.rounded() == d: self = .int(Int(d))
        default: return nil
        }
    }

    public var json: AnyJSON {
        switch self { case .int(let i): .int(i); case .string(let s): .string(s) }
    }

    public var description: String {
        switch self { case .int(let i): String(i); case .string(let s): s }
    }
}

/// A JSON-RPC error object; thrown by handlers to answer with an error.
public struct JSONRPCError: Error, Equatable, Sendable, CustomStringConvertible {
    public var code: Int
    public var message: String
    public var data: AnyJSON?

    public init(code: Int, message: String, data: AnyJSON? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public static func parseError(_ m: String = "Parse error") -> Self { .init(code: -32700, message: m) }
    public static func invalidRequest(_ m: String = "Invalid Request") -> Self { .init(code: -32600, message: m) }
    public static func methodNotFound(_ method: String) -> Self { .init(code: -32601, message: "Method not found: \(method)") }
    public static func invalidParams(_ m: String) -> Self { .init(code: -32602, message: m) }
    public static func internalError(_ m: String) -> Self { .init(code: -32603, message: m) }

    public var json: AnyJSON {
        var o: [String: AnyJSON] = ["code": .int(code), "message": .string(message)]
        if let data { o["data"] = data }
        return .object(o)
    }

    public init?(json: AnyJSON?) {
        guard let code = json?["code"]?.int else { return nil }
        self.init(code: code, message: json?["message"]?.string ?? "", data: json?["data"])
    }

    public var description: String { "JSON-RPC error \(code): \(message)" }
}

/// One JSON-RPC 2.0 message. Batches (arrays) are not accepted: the MCP
/// revisions Ycode serves and ACP send one message per line.
public enum JSONRPCMessage: Equatable, Sendable {
    case request(id: JSONRPCID, method: String, params: AnyJSON?)
    case notification(method: String, params: AnyJSON?)
    case result(id: JSONRPCID, result: AnyJSON)
    case error(id: JSONRPCID?, error: JSONRPCError)

    public init(json: AnyJSON) throws {
        guard case .object(let o) = json else { throw JSONRPCError.invalidRequest("a JSON-RPC message is an object") }
        guard o["jsonrpc"]?.string == "2.0" else { throw JSONRPCError.invalidRequest("jsonrpc must be \"2.0\"") }
        if let method = o["method"]?.string {
            if let raw = o["id"] {
                guard let id = JSONRPCID(raw) else { throw JSONRPCError.invalidRequest("the id must be a string or an integer") }
                self = .request(id: id, method: method, params: o["params"])
            } else {
                self = .notification(method: method, params: o["params"])
            }
            return
        }
        if let e = o["error"] {
            guard let err = JSONRPCError(json: e) else { throw JSONRPCError.invalidRequest("malformed error") }
            self = .error(id: JSONRPCID(o["id"]), error: err)
            return
        }
        if let r = o["result"], let id = JSONRPCID(o["id"]) {
            self = .result(id: id, result: r)
            return
        }
        throw JSONRPCError.invalidRequest("neither a request, a notification nor a response")
    }

    public static func parse(_ data: Data) throws -> JSONRPCMessage {
        let v: AnyJSON
        do { v = try AnyJSON.parse(data) } catch { throw JSONRPCError.parseError() }
        if case .array = v { throw JSONRPCError.invalidRequest("batches are not supported") }
        return try JSONRPCMessage(json: v)
    }

    public var json: AnyJSON {
        switch self {
        case .request(let id, let method, let params):
            var o: [String: AnyJSON] = ["jsonrpc": "2.0", "id": id.json, "method": .string(method)]
            if let params { o["params"] = params }
            return .object(o)
        case .notification(let method, let params):
            var o: [String: AnyJSON] = ["jsonrpc": "2.0", "method": .string(method)]
            if let params { o["params"] = params }
            return .object(o)
        case .result(let id, let result):
            return ["jsonrpc": "2.0", "id": id.json, "result": result]
        case .error(let id, let error):
            return ["jsonrpc": "2.0", "id": id?.json ?? .null, "error": error.json]
        }
    }

    /// One line of a stdio stream: compact JSON, then a newline.
    public var line: Data { json.data() + Data([0x0A]) }
}

/// Splits a byte stream into newline-delimited messages (the stdio
/// framing of MCP and ACP: messages contain no newlines). A carriage
/// return before the newline is dropped; empty lines are skipped.
public struct LineFramer: Sendable {
    private var buffer = Data()
    /// A line longer than this without a newline is dropped (64 MB).
    public var maxLineLength = 64 << 20
    public init() {}

    public mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            var line = buffer[buffer.startIndex..<nl]
            if line.last == 0x0D { line = line.dropLast() }
            if !line.isEmpty { lines.append(Data(line)) }
            buffer = Data(buffer[buffer.index(after: nl)...])
        }
        if buffer.count > maxLineLength { buffer = Data() }
        return lines
    }

    /// The bytes after the last newline (a final line without one).
    public mutating func flush() -> Data? {
        defer { buffer = Data() }
        var line = buffer
        if line.last == 0x0D { line = line.dropLast() }
        return line.isEmpty ? nil : line
    }
}
