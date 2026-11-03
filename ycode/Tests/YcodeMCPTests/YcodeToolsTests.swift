import Foundation
import Testing
import YcodeAssistant
import YcodeIDECore
@testable import YcodeMCP

/// Each Ycode tool against `Samples/AgentSamples/Greeter` (a copy) and the
/// project in `Samples/PackageSamples`.
@MainActor
@Suite(.serialized) struct YcodeToolsTests {
    func opened(_ sample: TempSample, policy: MCPWritePolicy = .readOnly) async throws -> YcodeMCPHost {
        let host = YcodeMCPHost()
        host.server.writePolicy = policy
        let r = try await host.server.callTool("workspace_open", ["path": .string(sample.url.path)])
        #expect(!r.isToolError, "\(r.resultText)")
        return host
    }

    @Test func openDescribeListReadSearch() async throws {
        let sample = try TempSample()
        defer { sample.remove() }
        let host = YcodeMCPHost()
        let none = try await host.server.callTool("workspace_describe")
        #expect(none.isToolError && none.resultText.contains("workspace_open"))
        // Package.swift opens its folder.
        let open = try await host.server.callTool("workspace_open", ["path": .string(sample.path("Package.swift"))])
        let d = try #require(open.structured)
        #expect(d["name"] == "Greeter" && d["kind"] == "package" && d["schemes"] == ["Greeter"])
        #expect(d["targets"]?.array?.compactMap { $0["name"]?.string } == ["Greeter", "greet", "GreeterTests"])
        #expect(d["destinations"]?.array?.isEmpty == false && d["remoteSimulator"] == false)

        let files = try await host.server.callTool("file_list", ["glob": "*.swift"])
        let list = files.structured?["files"]?.array?.compactMap(\.string) ?? []
        #expect(list.contains("Sources/Greeter/Greeter.swift") && list.contains("Previews/GreetingView.swift") && !list.contains("Package.resolved"))
        #expect(list.allSatisfy { $0.hasSuffix(".swift") })

        let read = try await host.server.callTool("file_read", ["path": "Sources/Greeter/Greeter.swift", "startLine": 11, "lineCount": 2])
        #expect(read.structured?["text"] == "    public func greeting(for name: String) -> String {\n        \"\\(salutation), \\(name)!\"")
        #expect(read.structured?["lineCount"] == 14 && read.resultText.hasPrefix("    11\t"))
        let outside = try await host.server.callTool("file_read", ["path": "../../etc/hosts"])
        #expect(outside.isToolError && outside.resultText.contains("outside the workspace"))

        let search = try await host.server.callTool("search", ["query": "salutation"])
        let matches = search.structured?["matches"]?.array ?? []
        #expect(matches.count >= 4 && matches.allSatisfy { $0["path"] == "Sources/Greeter/Greeter.swift" || $0["path"]?.string?.hasPrefix("Tests/") == true })
        let regex = try await host.server.callTool("search", ["query": "func test[A-Z]\\w+", "regex": true])
        #expect(regex.structured?["matchCount"] == 2)

        let symbols = try await host.server.callTool("symbol_search", ["query": "greeting"])
        let sym = try #require(symbols.structured?["symbols"]?.array?.first { $0["name"] == "greeting" })
        #expect(sym["kind"] == "func" && sym["documentation"] == "A greeting for `name`, ending with an exclamation mark.")

        let settings = try await host.server.callTool("build_settings")
        #expect(settings.isToolError && settings.resultText.contains("Package.swift"))
        let issues = try await host.server.callTool("issues")
        #expect(issues.structured?["errors"] == 0)
    }

    @Test func buildSettingsOfAProject() async throws {
        let host = YcodeMCPHost()
        let project = ycodeFolder.appendingPathComponent("Samples/PackageSamples/PackageSamples.xcodeproj").path
        let open = try await host.server.callTool("workspace_open", ["path": .string(project)])
        #expect(open.structured?["kind"] == "project")
        let targets = open.structured?["targets"]?.array?.compactMap { $0["name"]?.string } ?? []
        let target = try #require(targets.first)
        let r = try await host.server.callTool("build_settings", ["target": .string(target), "configuration": "Debug", "names": ["PRODUCT_NAME", "CONFIGURATION"]])
        #expect(!r.isToolError, "\(r.resultText)")
        #expect(r.structured?["settings"]?["CONFIGURATION"] == "Debug")
        #expect(r.structured?["settings"]?.object?.keys.sorted() == ["CONFIGURATION", "PRODUCT_NAME"])
        let bad = try await host.server.callTool("build_settings", ["target": "NoSuchTarget"])
        #expect(bad.isToolError)
    }

    @Test func buildReadIssueFixRebuildTestRunClean() async throws {
        guard canBuildPackages else { return }
        let sample = try TempSample(breaking: true)
        defer { sample.remove() }
        let host = try await opened(sample, policy: .allow)
        let progress = ProgressLog()
        let failed = try await host.server.callTool("build", [:], progress: progress.progress)
        #expect(failed.structured?["status"] == "failed", "\(failed.resultText)")
        #expect(progress.count >= 2 && progress.messages.last == "Build Failed")
        let issue = try #require(failed.structured?["issues"]?.array?.first { $0["severity"] == "error" })
        #expect(issue["path"] == "Sources/Greeter/Greeter.swift" && issue["line"] == 12)
        #expect(issue["message"]?.string?.contains("salutaton") == true)
        let issues = try await host.server.callTool("issues")
        #expect((issues.structured?["errors"]?.int ?? 0) >= 1)
        let log = try await host.server.callTool("build_log", ["tail": 5])
        #expect((log.structured?["lineCount"]?.int ?? 0) > 0)

        let fix = try await host.server.callTool("file_edit", ["path": "Sources/Greeter/Greeter.swift", "oldText": "salutaton", "newText": "salutation"])
        #expect(!fix.isToolError, "\(fix.resultText)")
        #expect(sample.read("Sources/Greeter/Greeter.swift").contains("\"\\(salutation), \\(name)!\""))
        let ok = try await host.server.callTool("build")
        #expect(ok.structured?["status"] == "succeeded", "\(ok.resultText)")
        #expect(try await host.server.callTool("issues").structured?["errors"] == 0)

        let tests = try await host.server.callTool("test")
        #expect(tests.structured?["status"] == "succeeded" && tests.structured?["passed"] == 2, "\(tests.resultText)")
        let one = try await host.server.callTool("test", ["tests": ["GreeterTests/testSalutation"]])
        #expect(one.structured?["passed"] == 1 && one.structured?["tests"]?[0]?["name"] == "testSalutation", "\(one.resultText)")
        let unknown = try await host.server.callTool("test", ["tests": ["Nope/testNothing"]])
        #expect(unknown.isToolError && unknown.resultText.contains("GreeterTests/testGreeting"))

        let run = try await host.server.callTool("run", ["arguments": ["Ycode"], "waitSeconds": 60])
        #expect(run.structured?["output"]?.array?.contains("Hello, Ycode!") == true, "\(run.resultText)")
        #expect(run.structured?["state"] == "exited with status 0")
        let out = try await host.server.callTool("run_output")
        #expect(out.structured?["runId"] == run.structured?["runId"])

        let clean = try await host.server.callTool("clean")
        #expect(clean.structured?["status"] == "succeeded", "\(clean.resultText)")
    }

    @Test func writesAreGatedAndReviewed() async throws {
        let sample = try TempSample()
        defer { sample.remove() }
        let ro = try await opened(sample)
        let refused = try await ro.server.callTool("file_write", ["path": "Sources/Greeter/New.swift", "content": "let x = 1\n"])
        #expect(refused.isToolError && refused.resultText.contains("read-only"))
        #expect(!FileManager.default.fileExists(atPath: sample.path("Sources/Greeter/New.swift")))

        final class Reviews: @unchecked Sendable { var changes: [MCPChange] = []; var accept = false }
        let reviews = Reviews()
        let reviewed = try await opened(sample, policy: .review { c in reviews.changes.append(c); return reviews.accept })
        let rejected = try await reviewed.server.callTool("file_edit", ["path": "Sources/Greeter/Greeter.swift", "oldText": "\"Hello\"", "newText": "\"Hi\""])
        #expect(rejected.isToolError && rejected.resultText == MCPServer.rejectedMessage)
        #expect(sample.read("Sources/Greeter/Greeter.swift").contains("\"Hello\""))
        let change = try #require(reviews.changes.first)
        #expect(change.relativePath == "Sources/Greeter/Greeter.swift" && change.original?.contains("\"Hello\"") == true && change.proposed.contains("\"Hi\""))
        reviews.accept = true
        let created = try await reviewed.server.callTool("file_write", ["path": "Sources/Greeter/New.swift", "content": "let x = 1\n"])
        #expect(created.structured?["created"] == true && sample.read("Sources/Greeter/New.swift") == "let x = 1\n")
        #expect(reviews.changes.last?.original == nil)
        // Ambiguous and missing edits are explained, not applied.
        let ambiguous = try await reviewed.server.callTool("file_edit", ["path": "Sources/Greeter/Greeter.swift", "oldText": "salutation", "newText": "s"])
        #expect(ambiguous.isToolError && ambiguous.resultText.contains("occurs"))
        let missing = try await reviewed.server.callTool("file_edit", ["path": "Sources/Greeter/Greeter.swift", "oldText": "nowhere", "newText": "s"])
        #expect(missing.isToolError && missing.resultText.contains("does not occur"))
        let escape = try await reviewed.server.callTool("file_write", ["path": "/tmp/ycode-mcp-escape.txt", "content": "x"])
        #expect(escape.isToolError && escape.resultText.contains("outside the workspace"))
    }

    @Test func stringCatalogs() async throws {
        let sample = try TempSample()
        defer { sample.remove() }
        let host = try await opened(sample, policy: .allow)
        let cats = try await host.server.callTool("strings_catalogs")
        let cat = try #require(cats.structured?["catalogs"]?.array?.first)
        #expect(cat["path"] == "Strings/Localizable.xcstrings" && cat["keys"] == 2)
        #expect(cat["languages"]?.array?.compactMap { $0["language"]?.string } == ["en", "de"])
        let missing = try await host.server.callTool("strings_list", ["language": "de", "missingOnly": true])
        #expect(missing.structured?["strings"]?.array?.compactMap { $0["key"]?.string } == ["world"])
        #expect(missing.structured?["progress"] == 50)
        let set = try await host.server.callTool("strings_set", ["key": "world", "language": "de", "value": "Welt"])
        #expect(set.structured?["progress"] == 100, "\(set.resultText)")
        let after = try await host.server.callTool("strings_list", ["language": "de"])
        #expect(after.structured?["strings"]?.array?.first { $0["key"] == "world" }?["translation"] == "Welt")
        #expect(sample.read("Strings/Localizable.xcstrings").contains("\"Welt\""))
        let unknown = try await host.server.callTool("strings_set", ["key": "nope", "language": "de", "value": "x"])
        #expect(unknown.isToolError)
        // A new language column.
        let fr = try await host.server.callTool("strings_list", ["language": "fr", "missingOnly": true])
        #expect(fr.structured?["strings"]?.array?.count == 2)
    }

    @Test func previewsAndResources() async throws {
        let sample = try TempSample()
        defer { sample.remove() }
        let host = try await opened(sample)
        let list = try await host.server.callTool("preview_list", ["path": "Previews/GreetingView.swift"])
        #expect(list.structured?["previews"]?.array?.compactMap { $0["name"]?.string } == ["Greeting", "Dark"])
        #expect(list.structured?["previews"]?[0]?["line"] == 12)
        let c = MCPServer.Connection()
        let res = try await host.server.handle(method: "resources/list", params: nil, connection: c)
        let uris = res["resources"]?.array?.compactMap { $0["uri"]?.string } ?? []
        #expect(uris.contains(YcodeResources.buildLogURI) && uris.contains { $0.hasSuffix("Sources/Greeter/Greeter.swift") })
        let fileURI = try #require(uris.first { $0.hasSuffix("Sources/greet/main.swift") })
        let read = try await host.server.handle(method: "resources/read", params: ["uri": .string(fileURI)], connection: c)
        #expect(read["contents"]?[0]?["text"]?.string?.contains("Greeter().greeting") == true)
        await #expect(throws: JSONRPCError.self) {
            try await host.server.handle(method: "resources/read", params: ["uri": "file:///etc/hosts"], connection: c)
        }
    }

    /// A stand-in `ssh` that records its command and prints a PNG.
    static func standInSSH(_ dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("ssh")
        try """
        #!/bin/sh
        for a in "$@"; do last="$a"; done
        printf '%s\\n' "$last" >> "\(dir.path)/ssh.commands"
        printf '\\211PNG\\r\\n\\032\\nIMAGE'
        """.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test func simulatorToolsUseTheRemoteHost() async throws {
        let host = YcodeMCPHost()
        let unset = try await host.server.callTool("simulator_screenshot")
        #expect(unset.isToolError && unset.resultText.contains("no Ycode Simulator host"))
        #expect(try await host.server.callTool("simulator_list").structured?["configured"] == false)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-mcp-ssh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        host.remoteSimulator = RemoteSimulatorSettings(destination: "user@sim-host", dataDirectory: "/data", runtimeRoot: "/data/rt/iOS_27.0.simruntime",
                                                       simdPath: "/data/bin/ycode-sim", deviceName: "phone", ssh: try Self.standInSSH(dir).path)
        let list = try await host.server.callTool("simulator_list")
        let sim = try #require(list.structured?["simulators"]?.array?.first)
        #expect(sim["running"] == false && sim["name"]?.string?.isEmpty == false)
        let shot = try await host.server.callTool("simulator_screenshot")
        let image = try #require(shot["content"]?.array?.first { $0["type"] == "image" })
        #expect(image["mimeType"] == "image/png")
        #expect(Data(base64Encoded: image["data"]?.string ?? "") == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data("IMAGE".utf8))
        let command = (try? String(contentsOf: dir.appendingPathComponent("ssh.commands"), encoding: .utf8)) ?? ""
        #expect(command.contains("'/data/bin/ycode-sim' --device '/data/devices/") && command.contains("--control 'screenshot' 'active' '/data/shots/agent-"))
        #expect(command.contains("&& cat '/data/shots/agent-") && command.contains("rm -f"))
        let missing = try await host.server.callTool("simulator_screenshot", ["simulator": "Nonexistent"])
        #expect(missing.isToolError)
    }
}
