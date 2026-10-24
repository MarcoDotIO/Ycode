import Foundation

public struct DAPError: Error, Equatable, CustomStringConvertible, Sendable {
    public var command: String
    public var message: String
    public var description: String { "\(command): \(message)" }
}

/// An event the adapter sent, such as `stopped`, `output` or `terminated`.
public struct DAPEvent: Equatable, Sendable {
    public var event: String
    public var body: JSON
}

/// A Debug Adapter Protocol client. Requests are `async` and return the
/// response body; events arrive on `events`. See `specs/ide/debug.md`.
public final class DAPClient: @unchecked Sendable {
    public let events: AsyncStream<DAPEvent>
    private let eventSink: AsyncStream<DAPEvent>.Continuation
    private let transport: DAPTransport
    private let lock = NSLock()
    private var seq = 0
    private var pending: [Int: (String, CheckedContinuation<JSON, Error>)] = [:]
    private var decoder = DAPFraming.Decoder()
    private var closed = false
    /// Capabilities from the `initialize` response.
    public private(set) var capabilities: JSON = [:]

    public init(transport: DAPTransport) throws {
        self.transport = transport
        (events, eventSink) = AsyncStream<DAPEvent>.makeStream()
        try transport.start { [weak self] data in self?.receive(data) }
    }

    // MARK: Messages

    /// Sends a request and waits for its response body.
    @discardableResult
    public func request(_ command: String, _ arguments: JSON? = nil) async throws -> JSON {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<JSON, Error>) in
            lock.lock()
            if closed {
                lock.unlock()
                c.resume(throwing: DAPError(command: command, message: "adapter closed"))
                return
            }
            seq += 1
            let n = seq
            pending[n] = (command, c)
            lock.unlock()
            var msg: [String: JSON] = ["seq": .number(Double(n)), "type": "request", "command": .string(command)]
            if let arguments { msg["arguments"] = arguments }
            transport.send(DAPFraming.frame(JSON.object(msg).encoded()))
        }
    }

    private func receive(_ data: Data?) {
        guard let data else { return shutDown() }
        lock.lock()
        let bodies = decoder.append(data)
        lock.unlock()
        for body in bodies {
            guard let msg = try? JSON.decode(body) else { continue }
            switch msg["type"]?.string {
            case "response":
                guard let n = msg["request_seq"]?.int else { continue }
                lock.lock()
                let waiter = pending.removeValue(forKey: n)
                lock.unlock()
                guard let (command, c) = waiter else { continue }
                if msg["success"]?.bool == true {
                    c.resume(returning: msg["body"] ?? .null)
                } else {
                    let text = msg["body"]?["error"]?["format"]?.string ?? msg["message"]?.string ?? "failed"
                    c.resume(throwing: DAPError(command: command, message: text))
                }
            case "event":
                eventSink.yield(DAPEvent(event: msg["event"]?.string ?? "", body: msg["body"] ?? .null))
            case "request":
                // Reverse requests (runInTerminal, startDebugging) are not
                // supported yet; answer so the adapter does not wait.
                lock.lock(); seq += 1; let n = seq; lock.unlock()
                let reply: JSON = ["seq": .number(Double(n)), "type": "response", "request_seq": msg["seq"] ?? 0,
                                   "command": msg["command"] ?? "", "success": false, "message": "not supported"]
                transport.send(DAPFraming.frame(reply.encoded()))
            default:
                continue
            }
        }
    }

    private func shutDown() {
        lock.lock()
        closed = true
        let waiting = pending
        pending = [:]
        lock.unlock()
        for (_, (command, c)) in waiting { c.resume(throwing: DAPError(command: command, message: "adapter closed")) }
        eventSink.finish()
    }

    /// Closes the transport and fails every request still waiting, so no
    /// caller stays suspended on an adapter that will never answer.
    public func close() {
        transport.close()
        shutDown()
    }

    // MARK: Requests

    @discardableResult
    public func initialize(clientName: String = "Ycode") async throws -> JSON {
        let caps = try await request("initialize", [
            "clientID": "ycode", "clientName": .string(clientName), "adapterID": "lldb-dap",
            "linesStartAt1": true, "columnsStartAt1": true, "pathFormat": "path",
            "supportsVariableType": true, "supportsRunInTerminalRequest": false,
        ])
        lock.withLock { capabilities = caps }
        return caps
    }

    public func launch(program: String, arguments: [String] = [], environment: [String: String] = [:],
                       cwd: String? = nil, stopOnEntry: Bool = false) async throws {
        var args: [String: JSON] = [
            "program": .string(program), "args": .array(arguments.map(JSON.string)),
            "env": .array(environment.sorted { $0.key < $1.key }.map { .string("\($0.key)=\($0.value)") }),
            "stopOnEntry": .bool(stopOnEntry),
        ]
        if let cwd { args["cwd"] = .string(cwd) }
        try await request("launch", .object(args))
    }

    public func attach(pid: Int? = nil, program: String? = nil, waitFor: Bool = false) async throws {
        var args: [String: JSON] = ["waitFor": .bool(waitFor)]
        if let pid { args["pid"] = .number(Double(pid)) }
        if let program { args["program"] = .string(program) }
        try await request("attach", .object(args))
    }

    /// Replaces all breakpoints of one file. Returns what the adapter verified.
    public func setBreakpoints(file: String, lines: [Int]) async throws -> [Breakpoint] {
        let body = try await request("setBreakpoints", [
            "source": ["path": .string(file), "name": .string(URL(fileURLWithPath: file).lastPathComponent)],
            "breakpoints": .array(lines.map { ["line": .number(Double($0))] }),
        ])
        return (body["breakpoints"]?.array ?? []).map(Breakpoint.init)
    }

    /// Replaces a file's breakpoints, with conditions, hit counts and log
    /// messages.
    public func setBreakpoints(file: String, breakpoints: [SourceBreakpoint]) async throws -> [Breakpoint] {
        let body = try await request("setBreakpoints", [
            "source": ["path": .string(file), "name": .string(URL(fileURLWithPath: file).lastPathComponent)],
            "breakpoints": .array(breakpoints.map(\.json)),
        ])
        return (body["breakpoints"]?.array ?? []).map(Breakpoint.init)
    }

    /// Replaces the exception breakpoints (filter ids from the adapter's
    /// `exceptionBreakpointFilters` capability).
    @discardableResult
    public func setExceptionBreakpoints(filters: [String]) async throws -> [Breakpoint] {
        let body = try await request("setExceptionBreakpoints", ["filters": .array(filters.map(JSON.string))])
        return (body["breakpoints"]?.array ?? []).map(Breakpoint.init)
    }

    /// Replaces the symbolic (function-name) breakpoints.
    @discardableResult
    public func setFunctionBreakpoints(_ breakpoints: [FunctionBreakpoint]) async throws -> [Breakpoint] {
        let body = try await request("setFunctionBreakpoints", ["breakpoints": .array(breakpoints.map(\.json))])
        return (body["breakpoints"]?.array ?? []).map(Breakpoint.init)
    }

    /// The adapter's exception filters: (id, label).
    public var exceptionFilters: [(id: String, label: String)] {
        (capabilities["exceptionBreakpointFilters"]?.array ?? []).compactMap { f in
            f["filter"]?.string.map { ($0, f["label"]?.string ?? $0) }
        }
    }

    public func configurationDone() async throws { try await request("configurationDone") }

    public func threads() async throws -> [DebugThread] {
        (try await request("threads")["threads"]?.array ?? []).map(DebugThread.init)
    }

    public func stackTrace(threadID: Int, levels: Int = 0) async throws -> [StackFrame] {
        let body = try await request("stackTrace", ["threadId": .number(Double(threadID)), "startFrame": 0, "levels": .number(Double(levels))])
        return (body["stackFrames"]?.array ?? []).map(StackFrame.init)
    }

    public func scopes(frameID: Int) async throws -> [Scope] {
        (try await request("scopes", ["frameId": .number(Double(frameID))])["scopes"]?.array ?? []).map(Scope.init)
    }

    public func variables(reference: Int) async throws -> [Variable] {
        (try await request("variables", ["variablesReference": .number(Double(reference))])["variables"]?.array ?? []).map(Variable.init)
    }

    public func evaluate(_ expression: String, frameID: Int? = nil, context: String = "repl") async throws -> String {
        var args: [String: JSON] = ["expression": .string(expression), "context": .string(context)]
        if let frameID { args["frameId"] = .number(Double(frameID)) }
        return try await request("evaluate", .object(args))["result"]?.string ?? ""
    }

    public func `continue`(threadID: Int) async throws { try await request("continue", ["threadId": .number(Double(threadID))]) }
    public func next(threadID: Int) async throws { try await request("next", ["threadId": .number(Double(threadID))]) }
    public func stepIn(threadID: Int) async throws { try await request("stepIn", ["threadId": .number(Double(threadID))]) }
    public func stepOut(threadID: Int) async throws { try await request("stepOut", ["threadId": .number(Double(threadID))]) }
    public func pause(threadID: Int) async throws { try await request("pause", ["threadId": .number(Double(threadID))]) }

    /// Sends `disconnect`. If the adapter does not answer within `timeout`,
    /// the client is closed (the adapter process is stopped and the request
    /// fails), so the caller never waits forever.
    public func disconnect(terminate: Bool = true, timeout: Duration = .seconds(5)) async throws {
        let watchdog = Task { [weak self] in
            try await Task.sleep(for: timeout)
            self?.close()
        }
        defer { watchdog.cancel() }
        try await request("disconnect", ["terminateDebuggee": .bool(terminate)])
    }
}

// MARK: Model

public struct Breakpoint: Equatable, Sendable {
    public var id: Int?
    public var verified: Bool
    public var line: Int?
    public var message: String?
    init(_ j: JSON) {
        id = j["id"]?.int
        verified = j["verified"]?.bool ?? false
        line = j["line"]?.int
        message = j["message"]?.string
    }
}

public struct DebugThread: Equatable, Sendable {
    public var id: Int
    public var name: String
    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }
    init(_ j: JSON) {
        id = j["id"]?.int ?? 0
        name = j["name"]?.string ?? ""
    }
}

public struct StackFrame: Equatable, Sendable {
    public var id: Int
    public var name: String
    public var file: String?
    public var line: Int
    public var column: Int
    /// The program counter (for disassembly).
    public var instructionPointer: String?
    init(_ j: JSON) {
        instructionPointer = j["instructionPointerReference"]?.string
        id = j["id"]?.int ?? 0
        name = j["name"]?.string ?? ""
        file = j["source"]?["path"]?.string
        line = j["line"]?.int ?? 0
        column = j["column"]?.int ?? 0
    }
}

public struct Scope: Equatable, Sendable {
    public var name: String
    public var variablesReference: Int
    public var expensive: Bool
    init(_ j: JSON) {
        name = j["name"]?.string ?? ""
        variablesReference = j["variablesReference"]?.int ?? 0
        expensive = j["expensive"]?.bool ?? false
    }
}

public struct Variable: Equatable, Sendable {
    public var name: String
    public var value: String
    public var type: String?
    /// Nonzero when the variable has children to fetch.
    public var variablesReference: Int
    init(_ j: JSON) {
        name = j["name"]?.string ?? ""
        value = j["value"]?.string ?? ""
        type = j["type"]?.string
        variablesReference = j["variablesReference"]?.int ?? 0
    }
    public init(name: String, value: String, type: String? = nil, variablesReference: Int = 0) {
        self.name = name
        self.value = value
        self.type = type
        self.variablesReference = variablesReference
    }
}

/// A line breakpoint as sent to the adapter.
public struct SourceBreakpoint: Equatable, Sendable {
    public var line: Int
    /// A column breakpoint's 1-based column (DAP `column`); nil for a line.
    public var column: Int?
    public var condition: String?
    /// Hit condition; lldb-dap reads a number as "ignore this many hits".
    public var hitCondition: String?
    /// When set, the breakpoint logs instead of stopping (`{expr}` is
    /// interpolated by the adapter).
    public var logMessage: String?
    public init(line: Int, column: Int? = nil, condition: String? = nil, hitCondition: String? = nil, logMessage: String? = nil) {
        self.line = line
        self.column = column
        self.condition = condition
        self.hitCondition = hitCondition
        self.logMessage = logMessage
    }
    var json: JSON {
        var o: [String: JSON] = ["line": .number(Double(line))]
        if let column { o["column"] = .number(Double(column)) }
        if let condition, !condition.isEmpty { o["condition"] = .string(condition) }
        if let hitCondition, !hitCondition.isEmpty { o["hitCondition"] = .string(hitCondition) }
        if let logMessage, !logMessage.isEmpty { o["logMessage"] = .string(logMessage) }
        return .object(o)
    }
}

/// A symbolic breakpoint: stop in every function with this name.
public struct FunctionBreakpoint: Equatable, Sendable {
    public var name: String
    public var condition: String?
    public init(name: String, condition: String? = nil) {
        self.name = name
        self.condition = condition
    }
    var json: JSON {
        var o: [String: JSON] = ["name": .string(name)]
        if let condition, !condition.isEmpty { o["condition"] = .string(condition) }
        return .object(o)
    }
}
