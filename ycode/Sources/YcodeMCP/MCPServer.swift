import Foundation
import YcodeAssistant

// The Model Context Protocol server core (modelcontextprotocol.io,
// specification revision 2026-07-28, MIT; with the initialize-based
// revisions 2025-11-25, 2025-06-18 and 2025-03-26 for older clients). The
// transports (stdio, Streamable HTTP) hand each request to `MCPServer` and
// write what it returns. See specs/ide/coding-assistant.md, "Ycode
// implementation".

/// Tool behaviour hints (`ToolAnnotations`).
public struct MCPToolAnnotations: Sendable, Equatable {
    public var readOnly: Bool
    public var destructive: Bool
    public var idempotent: Bool
    public var openWorld: Bool
    public init(readOnly: Bool, destructive: Bool = false, idempotent: Bool = false, openWorld: Bool = false) {
        self.readOnly = readOnly
        self.destructive = destructive
        self.idempotent = idempotent
        self.openWorld = openWorld
    }
    public static let read = MCPToolAnnotations(readOnly: true, idempotent: true)
}

/// Reports a long call's progress (`notifications/progress`) when the
/// client asked for it with a progress token; otherwise does nothing.
public struct MCPProgress: Sendable {
    let sink: (@Sendable (_ progress: Double, _ total: Double?, _ message: String?) -> Void)?
    public init(_ sink: (@Sendable (Double, Double?, String?) -> Void)?) { self.sink = sink }
    public static let none = MCPProgress(nil)
    public var isRequested: Bool { sink != nil }
    public func report(_ progress: Double, total: Double? = nil, message: String? = nil) { sink?(progress, total, message) }
}

/// A change a write tool is about to make, for review: the file's text
/// before (nil: a new file) and after.
public struct MCPChange: Sendable, Equatable {
    public var tool: String
    /// Absolute path.
    public var path: String
    /// Workspace-relative path (what a proposal shows).
    public var relativePath: String
    public var original: String?
    public var proposed: String
    public var summary: String
    public init(tool: String, path: String, relativePath: String, original: String?, proposed: String, summary: String) {
        self.tool = tool
        self.path = path
        self.relativePath = relativePath
        self.original = original
        self.proposed = proposed
        self.summary = summary
    }
}

/// The arguments of one `tools/call`.
public struct MCPToolCall: Sendable {
    public var name: String
    public var arguments: [String: AnyJSON]
    public var progress: MCPProgress
    /// Asks the write policy about one change (write tools call it before
    /// writing; true: go ahead).
    public var approve: @Sendable (MCPChange) async -> Bool
    public init(name: String, arguments: [String: AnyJSON], progress: MCPProgress = .none,
                approve: @escaping @Sendable (MCPChange) async -> Bool = { _ in true }) {
        self.name = name
        self.arguments = arguments
        self.progress = progress
        self.approve = approve
    }

    public func string(_ key: String) -> String? { arguments[key]?.string.flatMap { $0.isEmpty ? nil : $0 } }
    public func int(_ key: String) -> Int? { arguments[key]?.int }
    public func bool(_ key: String) -> Bool? { arguments[key]?.bool }
    public func strings(_ key: String) -> [String]? { arguments[key]?.array?.compactMap(\.string) }
    public func require(_ key: String) throws -> String {
        guard let s = arguments[key]?.string else { throw MCPToolError("missing the string argument \"\(key)\"") }
        return s
    }
}

/// A failure the tool reports to the model (`isError: true`), so it can
/// correct itself; protocol errors are `JSONRPCError`s instead.
public struct MCPToolError: Error, CustomStringConvertible, Sendable {
    public var message: String
    public var structured: AnyJSON?
    public init(_ message: String, structured: AnyJSON? = nil) {
        self.message = message
        self.structured = structured
    }
    public var description: String { message }
}

/// A tool's result: content blocks for the model, and the structured
/// result its output schema describes.
public struct MCPToolResult: Sendable, Equatable {
    public var content: [AnyJSON]
    public var structured: AnyJSON?
    public var isError: Bool
    public init(content: [AnyJSON], structured: AnyJSON? = nil, isError: Bool = false) {
        self.content = content
        self.structured = structured
        self.isError = isError
    }

    public static func text(_ s: String) -> MCPToolResult { MCPToolResult(content: [.textBlock(s)]) }

    /// A structured result with its JSON as the text block too (the spec
    /// asks servers to mirror structured content as text for older clients).
    public static func structured(_ v: AnyJSON, summary: String? = nil) -> MCPToolResult {
        var blocks: [AnyJSON] = []
        if let summary { blocks.append(.textBlock(summary)) }
        blocks.append(.textBlock(v.text))
        return MCPToolResult(content: blocks, structured: v)
    }

    public static func error(_ message: String, structured: AnyJSON? = nil) -> MCPToolResult {
        MCPToolResult(content: [.textBlock(message)], structured: structured, isError: true)
    }

    public var json: AnyJSON {
        var o: [String: AnyJSON] = ["content": .array(content), "isError": .bool(isError)]
        if let structured { o["structuredContent"] = structured }
        return .object(o)
    }
}

extension AnyJSON {
    /// A `TextContent` block.
    public static func textBlock(_ s: String) -> AnyJSON { ["type": "text", "text": .string(s)] }
    /// An `ImageContent` block (base64 data).
    public static func imageBlock(_ data: Data, mimeType: String = "image/png") -> AnyJSON {
        ["type": "image", "data": .string(data.base64EncodedString()), "mimeType": .string(mimeType)]
    }
}

public struct MCPTool: Sendable {
    public var name: String
    public var title: String
    public var description: String
    public var inputSchema: AnyJSON
    public var outputSchema: AnyJSON?
    public var annotations: MCPToolAnnotations
    /// The tool changes files: the server's write policy applies.
    public var writes: Bool
    public var handler: @Sendable (MCPToolCall) async throws -> MCPToolResult

    public init(name: String, title: String, description: String, inputSchema: AnyJSON, outputSchema: AnyJSON? = nil,
                annotations: MCPToolAnnotations = .read, writes: Bool = false,
                handler: @escaping @Sendable (MCPToolCall) async throws -> MCPToolResult) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.annotations = annotations
        self.writes = writes
        self.handler = handler
    }

    /// The `Tool` object of `tools/list`.
    public var listing: AnyJSON {
        var o: [String: AnyJSON] = [
            "name": .string(name), "title": .string(title), "description": .string(description), "inputSchema": inputSchema,
            "annotations": ["title": .string(title), "readOnlyHint": .bool(annotations.readOnly),
                            "destructiveHint": .bool(annotations.destructive), "idempotentHint": .bool(annotations.idempotent),
                            "openWorldHint": .bool(annotations.openWorld)],
        ]
        if let outputSchema { o["outputSchema"] = outputSchema }
        return .object(o)
    }

    /// Checks the arguments against the input schema's `required` list and
    /// the declared types of its top-level properties; nil when they fit.
    public func argumentProblem(_ args: [String: AnyJSON]) -> String? {
        for key in inputSchema["required"]?.array?.compactMap(\.string) ?? [] where args[key] == nil || args[key] == .null {
            return "missing the required argument \"\(key)\""
        }
        let props = inputSchema["properties"]?.object ?? [:]
        for (key, value) in args {
            guard let type = props[key]?["type"]?.string else {
                if inputSchema["additionalProperties"] == .bool(false), props[key] == nil { return "unknown argument \"\(key)\"" }
                continue
            }
            let ok: Bool = switch type {
            case "string": value.string != nil
            case "integer": value.int != nil
            case "number": value.double != nil
            case "boolean": value.bool != nil
            case "array": value.array != nil
            case "object": value.object != nil
            default: true
            }
            if !ok && value != .null { return "the argument \"\(key)\" must be of type \(type)" }
        }
        return nil
    }
}

/// A resource the server lists (`resources/list`).
public struct MCPResource: Sendable, Equatable {
    public var uri: String
    public var name: String
    public var title: String?
    public var mimeType: String?
    public var description: String?
    public init(uri: String, name: String, title: String? = nil, mimeType: String? = nil, description: String? = nil) {
        self.uri = uri
        self.name = name
        self.title = title
        self.mimeType = mimeType
        self.description = description
    }
    public var json: AnyJSON {
        var o: [String: AnyJSON] = ["uri": .string(uri), "name": .string(name)]
        if let title { o["title"] = .string(title) }
        if let mimeType { o["mimeType"] = .string(mimeType) }
        if let description { o["description"] = .string(description) }
        return .object(o)
    }
}

/// Where resources come from.
public protocol MCPResourceSource: Sendable {
    func resources() async -> [MCPResource]
    /// `ResourceTemplate` objects.
    func templates() async -> [AnyJSON]
    /// The `contents` of `resources/read`; nil for an unknown URI.
    func read(_ uri: String) async throws -> [AnyJSON]?
}

/// A prompt template (`prompts/list`, `prompts/get`).
public struct MCPPrompt: Sendable {
    public struct Argument: Sendable {
        public var name: String
        public var description: String
        public var required: Bool
        public init(_ name: String, _ description: String, required: Bool = false) {
            self.name = name
            self.description = description
            self.required = required
        }
    }
    public var name: String
    public var title: String
    public var description: String
    public var arguments: [Argument]
    /// The user message text for the given arguments.
    public var render: @Sendable ([String: String]) -> String

    public init(name: String, title: String, description: String, arguments: [Argument] = [], render: @escaping @Sendable ([String: String]) -> String) {
        self.name = name
        self.title = title
        self.description = description
        self.arguments = arguments
        self.render = render
    }

    public var listing: AnyJSON {
        ["name": .string(name), "title": .string(title), "description": .string(description),
         "arguments": .array(arguments.map { ["name": .string($0.name), "description": .string($0.description), "required": .bool($0.required)] })]
    }
}

/// Decides whether a write tool may write. Read-only refuses every write
/// tool; `allow` lets them write; `review` shows each change to someone
/// (the IDE's proposal review) and writes only what they accept.
public enum MCPWritePolicy: Sendable {
    case readOnly
    case allow
    case review(@Sendable (MCPChange) async -> Bool)

    public var allowsWrites: Bool {
        if case .readOnly = self { return false }
        return true
    }
}

public final class MCPServer: @unchecked Sendable {
    /// The revision served statelessly (per-request `_meta`).
    public static let modernVersion = "2026-07-28"
    /// The initialize-based revisions served to older clients, newest first.
    public static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]
    public static var supportedVersions: [String] { [modernVersion] + legacyVersions }

    public static let protocolVersionKey = "io.modelcontextprotocol/protocolVersion"
    public static let clientCapabilitiesKey = "io.modelcontextprotocol/clientCapabilities"
    public static let clientInfoKey = "io.modelcontextprotocol/clientInfo"
    public static let serverInfoKey = "io.modelcontextprotocol/serverInfo"

    /// The methods this server answers (others: method not found).
    public static let methods: Set<String> = ["initialize", "ping", "server/discover", "tools/list", "tools/call", "resources/list",
                                              "resources/templates/list", "resources/read", "prompts/list", "prompts/get", "logging/setLevel"]

    public var name: String
    public var version: String
    public var title: String
    public var instructions: String
    private let lock = NSLock()
    private var _tools: [MCPTool] = []
    private var _policy: MCPWritePolicy = .readOnly
    public var resources: MCPResourceSource?
    public var prompts: [MCPPrompt] = []

    public init(name: String = "ycode", version: String = "1.0", title: String = "Ycode", instructions: String = "") {
        self.name = name
        self.version = version
        self.title = title
        self.instructions = instructions
    }

    public var tools: [MCPTool] {
        get { lock.withLock { _tools } }
        set { lock.withLock { _tools = newValue } }
    }

    public var writePolicy: MCPWritePolicy {
        get { lock.withLock { _policy } }
        set { lock.withLock { _policy = newValue } }
    }

    /// Per-connection state: the legacy revision an `initialize` chose (a
    /// stdio process, an HTTP client that initialized).
    public final class Connection: @unchecked Sendable {
        private let lock = NSLock()
        private var _legacy: String?
        public init() {}
        public var legacyVersion: String? {
            get { lock.withLock { _legacy } }
            set { lock.withLock { _legacy = newValue } }
        }
    }

    var serverInfo: AnyJSON { ["name": .string(name), "version": .string(version), "title": .string(title)] }

    var capabilities: AnyJSON {
        var c: [String: AnyJSON] = ["tools": ["listChanged": false]]
        if resources != nil { c["resources"] = ["listChanged": false, "subscribe": false] }
        if !prompts.isEmpty { c["prompts"] = ["listChanged": false] }
        c["logging"] = [:]
        return .object(c)
    }

    /// Which revision a request speaks: modern when its `_meta` names a
    /// protocol version (validated here), else legacy.
    public enum Era: Equatable, Sendable { case modern, legacy }

    public static func era(of params: AnyJSON?) throws -> Era {
        guard let v = params?["_meta"]?[protocolVersionKey] else { return .legacy }
        guard let version = v.string else { throw JSONRPCError.invalidParams("\(protocolVersionKey) must be a string") }
        guard version == modernVersion else {
            if legacyVersions.contains(version) {
                // A handshake revision named per request: served as legacy.
                return .legacy
            }
            throw JSONRPCError(code: -32022, message: "Unsupported protocol version",
                               data: ["supported": .strings(supportedVersions), "requested": .string(version)])
        }
        guard params?["_meta"]?[clientCapabilitiesKey]?.object != nil else {
            throw JSONRPCError.invalidParams("\(clientCapabilitiesKey) is required in _meta")
        }
        return .modern
    }

    /// Answers one request. Throws `JSONRPCError` for protocol errors.
    public func handle(method: String, params: AnyJSON?, connection: Connection, progress: MCPProgress = .none) async throws -> AnyJSON {
        let era = try Self.era(of: params)
        let result = try await dispatch(method: method, params: params, connection: connection, era: era, progress: progress)
        guard era == .modern else { return result }
        var o = result.object ?? [:]
        o["resultType"] = "complete"
        var meta = o["_meta"]?.object ?? [:]
        meta[Self.serverInfoKey] = serverInfo
        o["_meta"] = .object(meta)
        return .object(o)
    }

    private func dispatch(method: String, params: AnyJSON?, connection: Connection, era: Era, progress: MCPProgress) async throws -> AnyJSON {
        switch method {
        case "initialize":
            let asked = params?["protocolVersion"]?.string ?? ""
            let chosen = Self.legacyVersions.contains(asked) ? asked : Self.legacyVersions[0]
            connection.legacyVersion = chosen
            var r: [String: AnyJSON] = ["protocolVersion": .string(chosen), "capabilities": capabilities, "serverInfo": serverInfo]
            if !instructions.isEmpty { r["instructions"] = .string(instructions) }
            return .object(r)
        case "server/discover":
            var r: [String: AnyJSON] = ["supportedVersions": .strings(Self.supportedVersions), "capabilities": capabilities,
                                          "_meta": [Self.serverInfoKey: serverInfo]]
            if !instructions.isEmpty { r["instructions"] = .string(instructions) }
            return .object(r)
        case "ping", "logging/setLevel":
            return [:]
        case "tools/list":
            return ["tools": .array(tools.map(\.listing))]
        case "tools/call":
            guard let name = params?["name"]?.string else { throw JSONRPCError.invalidParams("tools/call needs a tool name") }
            guard let tool = tools.first(where: { $0.name == name }) else { throw JSONRPCError.invalidParams("Unknown tool: \(name)") }
            let args = params?["arguments"]?.object ?? [:]
            let call = MCPToolCall(name: name, arguments: args, progress: progress)
            return await run(tool, call).json
        case "resources/list":
            return ["resources": .array(await (resources?.resources() ?? []).map(\.json))]
        case "resources/templates/list":
            return ["resourceTemplates": .array(await resources?.templates() ?? [])]
        case "resources/read":
            guard let uri = params?["uri"]?.string else { throw JSONRPCError.invalidParams("resources/read needs a uri") }
            guard let contents = try await resources?.read(uri) else {
                // Modern revisions use invalid params; earlier ones -32002.
                throw JSONRPCError(code: era == .modern ? -32602 : -32002, message: "Resource not found", data: ["uri": .string(uri)])
            }
            return ["contents": .array(contents)]
        case "prompts/list":
            return ["prompts": .array(prompts.map(\.listing))]
        case "prompts/get":
            guard let name = params?["name"]?.string, let p = prompts.first(where: { $0.name == name }) else {
                throw JSONRPCError.invalidParams("Unknown prompt: \(params?["name"]?.string ?? "")")
            }
            var args: [String: String] = [:]
            for (k, v) in params?["arguments"]?.object ?? [:] { args[k] = v.string ?? v.text }
            for a in p.arguments where a.required && args[a.name] == nil {
                throw JSONRPCError.invalidParams("prompt \(name) needs the argument \"\(a.name)\"")
            }
            return ["description": .string(p.description),
                    "messages": [["role": "user", "content": .textBlock(p.render(args))]]]
        default:
            throw JSONRPCError.methodNotFound(method)
        }
    }

    public static func readOnlyMessage(_ tool: String) -> String {
        "\(tool) changes files, and this Ycode MCP server is read-only. Start it with `ycode mcp --allow-writes`, or use agent mode in the Ycode IDE, where each change is reviewed as a proposal."
    }

    /// The text a write tool returns when the review rejects its change.
    public static let rejectedMessage = "The change was rejected in Ycode's review; nothing was written."

    /// Runs a tool under the write policy; failures become `isError` results.
    public func run(_ tool: MCPTool, _ call: MCPToolCall) async -> MCPToolResult {
        if let problem = tool.argumentProblem(call.arguments) { return .error("\(tool.name): \(problem)") }
        var call = call
        if tool.writes {
            switch writePolicy {
            case .readOnly:
                return .error(Self.readOnlyMessage(tool.name))
            case .allow:
                call.approve = { _ in true }
            case .review(let ask):
                call.approve = ask
            }
        } else {
            call.approve = { _ in false }
        }
        do {
            return try await tool.handler(call)
        } catch let e as MCPToolError {
            return .error(e.message, structured: e.structured)
        } catch is CancellationError {
            return .error("cancelled")
        } catch {
            return .error("\(tool.name) failed: \(error)")
        }
    }
}
