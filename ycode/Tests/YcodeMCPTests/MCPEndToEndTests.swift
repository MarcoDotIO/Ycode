import Foundation
import Testing
import YcodeAssistant
@testable import YcodeMCP

/// `ycode mcp` as a coding agent sees it: a subprocess speaking MCP on
/// standard input and output.
final class MCPProcessClient: @unchecked Sendable {
    let process = Process()
    let peer: JSONRPCPeer
    private let toServer = Pipe(), fromServer = Pipe()
    private let lock = NSLock()
    private var notes: [AnyJSON] = []

    init(_ executable: String, _ arguments: [String], directory: URL) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = toServer
        process.standardOutput = fromServer
        process.standardError = FileHandle.nullDevice
        let write = toServer.fileHandleForWriting.fileDescriptor
        peer = JSONRPCPeer { FDWriter.write(write, $0) }
        peer.onNotification { [weak self] method, params in
            guard let self else { return }
            lock.withLock { notes.append(["method": .string(method), "params": params ?? .null]) }
        }
        try process.run()
        let peer = peer
        LineReader(fileDescriptor: fromServer.fileHandleForReading.fileDescriptor, onLine: { peer.receive($0) }, onEnd: { peer.close() }).start()
    }

    var notifications: [AnyJSON] { lock.withLock { notes } }

    func tool(_ name: String, _ args: [String: AnyJSON] = [:], progressToken: String? = nil) async throws -> AnyJSON {
        var params: AnyJSON = ["name": .string(name), "arguments": .object(args)]
        if let progressToken { params = params.setting("_meta", ["progressToken": .string(progressToken)]) }
        return try await peer.request("tools/call", params)
    }

    func close() {
        try? toServer.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate() }
    }
}

@Suite(.serialized, .timeLimit(.minutes(15))) struct MCPEndToEndTests {
    /// Opens the sample package, builds it with an error, reads the issue,
    /// fixes it with a write tool, builds green and runs the tests: on
    /// macOS and on Linux.
    @Test func anAgentFixesTheBuildThroughYcodeMCP() async throws {
        guard let ycode = ycodeExecutable, canBuildPackages else { return }
        let sample = try TempSample(breaking: true)
        defer { sample.remove() }
        let client = try MCPProcessClient(ycode, ["mcp", "--allow-writes"], directory: sample.url)
        defer { client.close() }

        let initialized = try await client.peer.request("initialize", ["protocolVersion": "2025-11-25", "capabilities": [:],
                                                                       "clientInfo": ["name": "e2e", "version": "1"]])
        #expect(initialized["protocolVersion"] == "2025-11-25" && initialized["serverInfo"]?["name"] == "ycode")
        client.peer.notify("notifications/initialized")
        let tools = try await client.peer.request("tools/list")
        #expect(tools["tools"]?.array?.count == 29)

        // The workspace in the current folder is open already; open it by path anyway.
        let open = try await client.tool("workspace_open", ["path": .string(sample.url.path)])
        #expect(open["structuredContent"]?["name"] == "Greeter")

        let failed = try await client.tool("build", progressToken: "b1")
        #expect(failed["structuredContent"]?["status"] == "failed", "\(failed.resultText)")
        #expect(client.notifications.contains { $0["method"] == "notifications/progress" && $0["params"]?["progressToken"] == "b1" })
        let issues = try await client.tool("issues")
        let issue = try #require(issues["structuredContent"]?["issues"]?.array?.first { $0["severity"] == "error" })
        let path = try #require(issue["path"]?.string)
        let line = try #require(issue["line"]?.int)
        #expect(path == "Sources/Greeter/Greeter.swift")

        let read = try await client.tool("file_read", ["path": .string(path), "startLine": .int(line), "lineCount": 1])
        let broken = try #require(read["structuredContent"]?["text"]?.string)
        #expect(broken.contains("salutaton"))
        let edit = try await client.tool("file_edit", ["path": .string(path), "oldText": .string(broken),
                                                       "newText": .string(broken.replacingOccurrences(of: "salutaton", with: "salutation"))])
        #expect(edit["isError"] == false, "\(edit.resultText)")

        let ok = try await client.tool("build")
        #expect(ok["structuredContent"]?["status"] == "succeeded", "\(ok.resultText)")
        let tests = try await client.tool("test")
        #expect(tests["structuredContent"]?["status"] == "succeeded" && tests["structuredContent"]?["passed"] == 2, "\(tests.resultText)")
    }

    @Test func readOnlyByDefaultAndModernRequestsOverStdio() async throws {
        guard let ycode = ycodeExecutable else { return }
        let sample = try TempSample()
        defer { sample.remove() }
        let client = try MCPProcessClient(ycode, ["mcp", "--workspace", sample.url.path], directory: FileManager.default.temporaryDirectory)
        defer { client.close() }
        // A modern client: no handshake, the version in every request's _meta.
        let discover = try await client.peer.request("server/discover", ["_meta": modernMeta])
        #expect(discover["supportedVersions"]?.array?.first == .string(MCPServer.modernVersion))
        let describe = try await client.peer.request("tools/call", ["name": "workspace_describe", "_meta": modernMeta])
        #expect(describe["resultType"] == "complete" && describe["structuredContent"]?["name"] == "Greeter")
        let write = try await client.peer.request("tools/call", ["name": "file_write", "arguments": ["path": "x.txt", "content": "x"], "_meta": modernMeta])
        #expect(write["isError"] == true && write.resultText.contains("read-only"))
        #expect(!FileManager.default.fileExists(atPath: sample.path("x.txt")))
    }

    @Test func parsesItsCommandLine() throws {
        var o = try MCPCommand.parse(["--workspace", "/w", "--allow-writes", "--http", "8123", "--simulator-config", "s.json"])
        #expect(o.workspace == "/w" && o.allowWrites && o.httpPort == 8123 && o.simulatorConfig == "s.json")
        o = try MCPCommand.parse(["--http"])
        #expect(o.httpPort == 0 && !o.allowWrites)
        #expect(throws: MCPCommand.ParseError.help) { try MCPCommand.parse(["--help"]) }
        #expect(throws: MCPCommand.ParseError.self) { try MCPCommand.parse(["--bogus"]) }
        let env = ["YCODE_MCP_SIM_DESTINATION": "u@h", "YCODE_MCP_SIM_DATA": "/d", "YCODE_MCP_SIM_RUNTIME": "/d/iOS_27.0.simruntime",
                   "YCODE_MCP_SIM_LAUNCHER": "/d/bin/ycode-sim", "YCODE_MCP_SIM_DEVICE": "p18"]
        let s = try #require(try MCPCommand.simulatorSettings(file: nil, environment: env))
        #expect(s.isConfigured && s.deviceName == "p18" && s.runtimeVersion == "27.0")
        #expect(try MCPCommand.simulatorSettings(file: nil, environment: [:]) == nil)
    }
}
