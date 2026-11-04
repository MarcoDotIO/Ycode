import Foundation
import Testing
import YcodeDebug

@Suite struct LLDBDAPLocateTests {
    @Test func theFlatpakRunsTheHostsAdapterThroughItsWrapper() {
        let env = ["FLATPAK_ID": "io.github.MarcoDotIO.Ycode", "PATH": "/nonexistent"]
        #expect(LLDBDAP.locate(environment: env, toolDirectory: "/app/libexec/ycode-host") == "/app/libexec/ycode-host/lldb-dap")
        // An explicit adapter still wins.
        #expect(LLDBDAP.locate(environment: env.merging(["YCODE_LLDB_DAP": "/opt/lldb-dap"]) { $1 }, toolDirectory: "/x") == "/opt/lldb-dap")
    }

    #if os(Linux)
    @Test func swiftlysFoldersAreSearchedAfterThePath() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-dap-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent(".local/share/swiftly/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let tool = bin.appendingPathComponent("lldb-dap").path
        FileManager.default.createFile(atPath: tool, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        #expect(LLDBDAP.locate(environment: ["HOME": home.path, "PATH": "/nonexistent"], toolDirectory: nil) == tool)
    }
    #endif
}
