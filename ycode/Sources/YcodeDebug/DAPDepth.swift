import Foundation

/// An evaluation result: its text and, for structured values, a reference
/// to fetch children.
public struct EvaluateResult: Equatable, Sendable {
    public var result: String
    public var type: String?
    public var variablesReference: Int
}

/// One disassembled instruction.
public struct Instruction: Equatable, Sendable {
    public var address: String
    public var instruction: String
    public var bytes: String?
    public var symbol: String?
    public var file: String?
    public var line: Int?
    init(_ j: JSON) {
        address = j["address"]?.string ?? ""
        instruction = j["instruction"]?.string ?? ""
        bytes = j["instructionBytes"]?.string
        symbol = j["symbol"]?.string
        file = j["location"]?["path"]?.string
        line = j["line"]?.int
    }
}

/// What `dataBreakpointInfo` returns for a variable.
public struct DataBreakpointInfo: Equatable, Sendable {
    /// nil when the variable cannot be watched.
    public var dataID: String?
    public var description: String
    public var accessTypes: [String]
}

extension DAPClient {
    /// `evaluate` with the full body (result, type, children reference).
    public func evaluateFull(_ expression: String, frameID: Int? = nil, context: String = "repl") async throws -> EvaluateResult {
        var args: [String: JSON] = ["expression": .string(expression), "context": .string(context)]
        if let frameID { args["frameId"] = .number(Double(frameID)) }
        let b = try await request("evaluate", .object(args))
        return EvaluateResult(result: b["result"]?.string ?? "", type: b["type"]?.string, variablesReference: b["variablesReference"]?.int ?? 0)
    }

    /// `setVariable`: assigns `value` to `name` inside the container
    /// `reference`; returns the new value text.
    @discardableResult
    public func setVariable(reference: Int, name: String, value: String) async throws -> String {
        let b = try await request("setVariable", ["variablesReference": .number(Double(reference)), "name": .string(name), "value": .string(value)])
        return b["value"]?.string ?? value
    }

    /// `dataBreakpointInfo` for a variable in a container.
    public func dataBreakpointInfo(reference: Int, name: String) async throws -> DataBreakpointInfo {
        let b = try await request("dataBreakpointInfo", ["variablesReference": .number(Double(reference)), "name": .string(name)])
        return DataBreakpointInfo(dataID: b["dataId"]?.string, description: b["description"]?.string ?? "",
                                  accessTypes: (b["accessTypes"]?.array ?? []).compactMap(\.string))
    }

    /// `setDataBreakpoints`: replaces all watchpoints (dataId, accessType).
    @discardableResult
    public func setDataBreakpoints(_ list: [(dataID: String, accessType: String)]) async throws -> [Breakpoint] {
        let b = try await request("setDataBreakpoints", ["breakpoints": .array(list.map {
            ["dataId": .string($0.dataID), "accessType": .string($0.accessType)]
        })])
        return (b["breakpoints"]?.array ?? []).map(Breakpoint.init)
    }

    /// `disassemble` around a memory reference.
    public func disassemble(memoryReference: String, instructionOffset: Int, count: Int) async throws -> [Instruction] {
        let b = try await request("disassemble", ["memoryReference": .string(memoryReference), "instructionOffset": .number(Double(instructionOffset)),
                                                  "instructionCount": .number(Double(count)), "resolveSymbols": true])
        return (b["instructions"]?.array ?? []).map(Instruction.init)
    }

    /// Steps by one instruction (`granularity: instruction`).
    public func stepInstruction(threadID: Int, into: Bool) async throws {
        try await request(into ? "stepIn" : "next", ["threadId": .number(Double(threadID)), "granularity": "instruction"])
    }

    /// `next`, `stepIn` or `stepOut` with the DAP options: `granularity`
    /// ("instruction" steps one instruction) and `singleThread` (only this
    /// thread runs while stepping).
    public func step(_ command: String, threadID: Int, granularity: String? = nil, singleThread: Bool = false) async throws {
        var args: [String: JSON] = ["threadId": .number(Double(threadID))]
        if let granularity { args["granularity"] = .string(granularity) }
        if singleThread { args["singleThread"] = true }
        try await request(command, .object(args))
    }

    /// Attach with lldb-dap's arguments (`pid`, or `program` + `waitFor`),
    /// plus a thread format that names each thread's queue.
    public func attach(pid: Int?, program: String?, waitFor: Bool, threadFormat: String?) async throws {
        var args: [String: JSON] = ["waitFor": .bool(waitFor)]
        if let pid { args["pid"] = .number(Double(pid)) }
        if let program { args["program"] = .string(program) }
        if let threadFormat { args["threadFormat"] = .string(threadFormat) }
        try await request("attach", .object(args))
    }

    /// Launch with a thread format (see `attach`).
    public func launch(program: String, cwd: String?, threadFormat: String, arguments: [String] = [], environment: [String: String] = [:]) async throws {
        var args: [String: JSON] = ["program": .string(program), "args": .array(arguments.map { .string($0) }),
                                    "env": .array(environment.keys.sorted().map { .string("\($0)=\(environment[$0]!)") }),
                                    "stopOnEntry": false, "threadFormat": .string(threadFormat)]
        if let cwd { args["cwd"] = .string(cwd) }
        try await request("launch", .object(args))
    }
}

extension DebugThread {
    /// The thread format Ycode asks lldb-dap for: `Thread <n>`, then the
    /// name and the dispatch queue when known.
    public static let format = "Thread ${thread.index}{ name = ${thread.name}}{ queue = ${thread.queue}}"

    /// The queue name parsed from a thread name in `format`.
    public var queue: String? {
        guard let r = name.range(of: " queue = ") else { return nil }
        return String(name[r.upperBound...]).trimmingCharacters(in: .whitespaces)
    }
}
