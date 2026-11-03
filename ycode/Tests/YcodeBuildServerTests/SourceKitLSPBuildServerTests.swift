import Foundation
import Testing
import YcodeDebug
@testable import YcodeBuildServer
import YcodeLanguage

/// sourcekit-lsp, driven by Ycode's LSP client, on the sample project
/// through `ycode-bsp`: a deliberate error is reported, completion offers
/// the framework's members in the app, and Jump to Definition crosses from
/// the app into the framework. The iOS flavor needs the iOS Simulator SDK
/// (macOS); the portable flavor runs wherever sourcekit-lsp does.
@Suite(.serialized, .timeLimit(.minutes(6))) struct SourceKitLSPBuildServerTests {
    /// `ycode-bsp` from this build.
    static var server: String? {
        let p = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/ycode-bsp").path
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    static var hasIOSSimulatorSDK: Bool {
        #if os(macOS)
        guard let dev = try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link") else { return false }
        let sdks = dev + "/Platforms/iPhoneSimulator.platform/Developer/SDKs"
        return !((try? FileManager.default.contentsOfDirectory(atPath: sdks)) ?? []).isEmpty
        #else
        return false
        #endif
    }

    @Test func iOSAppWithFramework() async throws {
        guard Self.hasIOSSimulatorSDK else { return }
        try await run(.iOS)
    }

    @Test func portableProject() async throws {
        try await run(.portable)
    }

    /// Line and UTF-16 column of the end of `marker` in `text` (0-based).
    static func position(after marker: String, in text: String) throws -> Position {
        let range = try #require(text.range(of: marker))
        let before = text[..<range.upperBound]
        let line = before.filter { $0 == "\n" }.count
        let lineStart = before.lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        return Position(line: line, character: text[lineStart..<range.upperBound].utf16.count)
    }

    func run(_ flavor: SampleProject.Flavor) async throws {
        guard let lsp = SourceKitLSP.locate(), let bsp = Self.server else { return }
        let dir = try freshScratch(flavor == .iOS ? "e2e-ios" : "e2e-portable")
        let project = try SampleProject.write(flavor, in: dir)
        let sample = project.deletingLastPathComponent()
        // The folder sourcekit-lsp opens holds only the connection file.
        let folder = dir.appendingPathComponent("lsp-root")
        try BuildServerConfigFile.write(argv: [bsp, "serve", project.path, "--derived-data", dir.appendingPathComponent("DD").path,
                                               "--log", dir.appendingPathComponent("bsp.log").path], into: folder)

        let client = try LSPClient(transport: ProcessTransport(executable: lsp))
        defer { client.close() }
        try await client.initialize(root: folder, initializationOptions: BuildServerLaunch.initializationOptions)

        // The app's main file, with a deliberate error added.
        let mainURL = sample.appendingPathComponent(flavor == .iOS ? "App/AppMain.swift" : "App/main.swift")
        let original = try String(contentsOf: mainURL, encoding: .utf8)
        let text = original + "let broken: Int = \"not a number\"\n"
        client.didOpen(mainURL, text: text)

        // Diagnostics: the error, once the framework's module is prepared
        // (no "no such module 'Kit'").
        // One reader collects the file's diagnostics; while they lack the
        // error (a cold module cache can make the first answer empty), the
        // text is sent again every 20 s.
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var diagnostics: [LSPDiagnostic] = []
        }
        let box = Box()
        let mainPath = mainURL.standardizedFileURL.path
        let reader = Task {
            for await n in client.notifications {
                guard n.method == "textDocument/publishDiagnostics", let (url, d) = LSPDiagnostic.published(n.params),
                      url.standardizedFileURL.path == mainPath else { continue }
                box.lock.withLock { box.diagnostics = d }
            }
        }
        defer { reader.cancel() }
        func ready(_ d: [LSPDiagnostic]) -> Bool {
            d.contains { $0.message.lowercased().contains("cannot convert") } && !d.contains { $0.message.lowercased().contains("no such module") }
        }
        var version = 1
        let start = Date()
        while Date().timeIntervalSince(start) < 240, !ready(box.lock.withLock({ box.diagnostics })) {
            try await Task.sleep(for: .milliseconds(200))
            if Date().timeIntervalSince(start) > Double(version) * 20 {
                version += 1
                client.didChange(mainURL, text: text, version: version)
            }
        }
        let latest = box.lock.withLock { box.diagnostics }
        let broken = try #require(latest.first { $0.message.lowercased().contains("cannot convert") }, "diagnostics: \(latest.map(\.message))")
        #expect(broken.severity == 1)
        #expect(broken.start.line == text.split(separator: "\n", omittingEmptySubsequences: false).count - 2)
        #expect(!latest.contains { $0.severity == 1 && !$0.message.lowercased().contains("cannot convert") }, "\(latest.map(\.message))")

        // Completion of a type from the framework, in the app.
        let afterDot = try Self.position(after: flavor == .iOS ? "return g." : "print(g.", in: text)
        let items = try await client.completion(mainURL, at: afterDot)
        #expect(items.contains { $0.label.hasPrefix("greet(times:") }, "\(items.prefix(10).map(\.label))")
        #expect(items.contains { $0.label == "name" })

        // Jump to Definition from the app into the framework (needs the index).
        _ = try await client.request("workspace/synchronize", ["index": true])
        let use = try Self.position(after: "let g = Gree", in: text)
        let defs = try await client.definition(mainURL, at: use)
        let def = try #require(defs.first, "no definition")
        #expect(def.url.path.hasSuffix("Kit/Greeter.swift"))
        #expect(def.start.line == 3)

        if flavor == .iOS {
            // Objective-C in the app finds the framework's headers.
            let helper = sample.appendingPathComponent("App/Helper.m")
            let helperText = try String(contentsOf: helper, encoding: .utf8)
            client.didOpen(helper, text: helperText)
            let legacy = try Self.position(after: "[KitLe", in: helperText)
            let objcDefs = try await client.definition(helper, at: legacy)
            // (the interface, or through the index its implementation in the framework)
            #expect(["KitLegacy.h", "KitLegacy.m"].contains(objcDefs.first?.url.lastPathComponent ?? ""), "\(objcDefs.map(\.url.path))")
            #expect(objcDefs.first?.url.deletingLastPathComponent().lastPathComponent == "Kit")
            // The test bundle sees the app's types (`@testable import App`).
            let testsURL = sample.appendingPathComponent("AppTests/AppTests.swift")
            let testsText = try String(contentsOf: testsURL, encoding: .utf8)
            client.didOpen(testsURL, text: testsText)
            let delegate = try Self.position(after: "XCTAssertFalse(AppDele", in: testsText)
            let delegateDefs = try await client.definition(testsURL, at: delegate)
            #expect(delegateDefs.first?.url.lastPathComponent == "AppMain.swift", "\(delegateDefs.map(\.url.path))")
        }
        await client.shutdown()
    }
}
