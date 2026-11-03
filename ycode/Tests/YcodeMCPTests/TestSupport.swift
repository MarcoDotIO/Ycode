import Foundation
import YcodeAssistant
@testable import YcodeMCP

/// The `ycode/` folder of this checkout.
let ycodeFolder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// A copy of `Samples/AgentSamples/Greeter` in a temporary folder (tests
/// build and edit the copy, never the sample).
struct TempSample {
    let root: URL
    let url: URL

    init(_ name: String = "Greeter", breaking: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-mcp-\(UUID().uuidString)")
        url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: ycodeFolder.appendingPathComponent("Samples/AgentSamples/\(name)"), to: url)
        if breaking { try breakIt() }
    }

    /// Introduces a compile error: `salutation` misspelt in the greeting.
    func breakIt() throws {
        let f = path("Sources/Greeter/Greeter.swift")
        let t = try String(contentsOfFile: f, encoding: .utf8)
        try t.replacingOccurrences(of: "\"\\(salutation), \\(name)!\"", with: "\"\\(salutaton), \\(name)!\"").write(toFile: f, atomically: true, encoding: .utf8)
    }

    func path(_ rel: String) -> String { url.appendingPathComponent(rel).path }
    func read(_ rel: String) -> String { (try? String(contentsOfFile: path(rel), encoding: .utf8)) ?? "" }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

/// `_meta` of a modern (2026-07-28) request.
let modernMeta: AnyJSON = [MCPServer.protocolVersionKey: .string(MCPServer.modernVersion), MCPServer.clientCapabilitiesKey: [:],
                           MCPServer.clientInfoKey: ["name": "tests", "version": "1"]]

extension MCPServer {
    /// Calls a tool as a legacy client would; the `CallToolResult`.
    func callTool(_ name: String, _ arguments: [String: AnyJSON] = [:], progress: MCPProgress = .none) async throws -> AnyJSON {
        try await handle(method: "tools/call", params: ["name": .string(name), "arguments": .object(arguments)], connection: Connection(), progress: progress)
    }
}

extension AnyJSON {
    /// The text of every text block of a tool result.
    var resultText: String { (self["content"]?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n") }
    var isToolError: Bool { self["isError"]?.bool == true }
    var structured: AnyJSON? { self["structuredContent"] }
}

/// Collects progress notifications.
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(Double, Double?, String?)] = []
    var progress: MCPProgress { MCPProgress { [self] p, t, m in lock.withLock { items.append((p, t, m)) } } }
    var messages: [String] { lock.withLock { items.compactMap(\.2) } }
    var count: Int { lock.withLock { items.count } }
}

/// Whether a `swift` toolchain can build packages here.
let canBuildPackages: Bool = {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["swift", "--version"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}()

/// The `ycode` executable of this build.
let ycodeExecutable: String? = {
    let p = ycodeFolder.appendingPathComponent(".build/debug/ycode").path
    return FileManager.default.isExecutableFile(atPath: p) ? p : nil
}()
