import Foundation
import Testing
@testable import YcodeAssistant
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// What a request leaves behind: no agent process, no listening socket.
@Suite struct ProcessCleanupTests {
    /// The ACP agent ends with its request, even one that would wait for
    /// more input (it was left running, holding whatever it had inherited).
    @Test func theACPAgentEndsWithTheRequest() async throws {
        let tools = try StandInTools()
        let script = tools.dir.appendingPathComponent("acp-agent")
        try """
        #!/bin/sh
        echo $$ > "\(tools.dir.path)/agent.pid"
        read l; echo '{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":1,"agentCapabilities":{}}}'
        read l; echo '{"jsonrpc":"2.0","id":1,"result":{"sessionId":"s1"}}'
        read l
        echo '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Done."}}}}'
        echo '{"jsonrpc":"2.0","id":2,"result":{"stopReason":"end_turn"}}'
        while :; do read l || sleep 1; done
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        var req = ChatRequest(model: nil, instructions: "I", messages: [ChatMessage(.user, "Q?")])
        req.workingDirectory = tools.dir
        let r = try await collect(ACPAgentProvider(command: script.path, locator: CLIToolLocator()).send(req))
        #expect(r.text == "Done.")
        let pid = try #require(pid_t(tools.recorded("agent", "pid").trimmingCharacters(in: .whitespacesAndNewlines)))
        for _ in 0..<60 where kill(pid, 0) == 0 { try await Task.sleep(nanoseconds: 100_000_000) }
        let alive = kill(pid, 0) == 0
        #expect(!alive)
        if alive { kill(pid, SIGKILL) }
    }

    /// A server nobody holds stops listening without `stop()`.
    @Test func aReleasedServerStopsListening() throws {
        var port: UInt16 = 0
        do {
            let server = try LoopbackServer { _ in .text("") }
            port = server.port
            #expect(Self.connects(port))
        }
        #expect(!Self.connects(port))
    }

    static func connects(_ port: UInt16) -> Bool {
        #if canImport(Glibc)
        let s = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let s = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard s >= 0 else { return false }
        defer { close(s) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        } == 0
    }
}
