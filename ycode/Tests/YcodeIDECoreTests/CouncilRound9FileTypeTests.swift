import Foundation
import Testing
import YcodeBuild
import YcodeDebug
import YcodeLanguage
@testable import YcodeIDECore

/// Council round 9, group C (rows 228–230), shared by both IDEs: only
/// Swift and C-family sources go to the language service; the File
/// inspector's Type and its resource sections follow the file's type.
@MainActor
@Suite(.serialized) struct CouncilRound9FileTypeTests {
    /// A server that, like sourcekit-lsp given a file it cannot compile,
    /// publishes a line-1 error for every document it is told about, and
    /// records which documents it was told about.
    final class CompilingServer: DAPTransport, @unchecked Sendable {
        static let message = "Unable to handle compilation, expected exactly one compiler job in ''"
        private let lock = NSLock()
        private var receiving: (@Sendable (Data?) -> Void)?
        private var decoder = DAPFraming.Decoder()
        private var seen: [String] = []
        /// "method uri" for every document notification, in order.
        var documentNotifications: [String] { lock.withLock { seen } }

        func start(receiving: @escaping @Sendable (Data?) -> Void) throws { lock.withLock { self.receiving = receiving } }

        func reply(_ msg: JSON) {
            let r = lock.withLock { receiving }
            r?(DAPFraming.frame(msg.encoded()))
        }

        func send(_ data: Data) {
            let bodies = lock.withLock { decoder.append(data) }
            for body in bodies {
                guard let msg = try? JSON.decode(body) else { continue }
                let method = msg["method"]?.string
                if method == "exit" { close(); continue }
                if let method, method.hasPrefix("textDocument/did"), let uri = msg["params"]?["textDocument"]?["uri"]?.string {
                    lock.withLock { seen.append("\(method) \(uri)") }
                    if method == "textDocument/didOpen" || method == "textDocument/didChange" {
                        let range: JSON = ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 1]]
                        reply(["jsonrpc": "2.0", "method": "textDocument/publishDiagnostics", "params": [
                            "uri": .string(uri), "diagnostics": [["range": range, "severity": 1, "message": .string(Self.message)]],
                        ]])
                    }
                }
                guard let id = msg["id"], method != nil else { continue }
                reply(["jsonrpc": "2.0", "id": id, "result": method == "initialize" ? ["capabilities": [:]] : .null])
            }
        }

        func close() {
            let r = lock.withLock { () -> (@Sendable (Data?) -> Void)? in
                defer { receiving = nil }
                return receiving
            }
            r?(nil)
        }
    }

    /// A package with a Swift source, NOTES.md and palette.json.
    func package() throws -> (dir: URL, swift: URL, notes: URL, palette: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("r9-types-\(UUID().uuidString)")
        let src = dir.appendingPathComponent("Sources/App")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: \"App\", targets: [.executableTarget(name: \"App\")])\n"
            .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let swift = src.appendingPathComponent("main.swift")
        try "print(1)\n".write(to: swift, atomically: true, encoding: .utf8)
        let notes = src.appendingPathComponent("NOTES.md")
        try "# Notes\n\nSome notes.\n".write(to: notes, atomically: true, encoding: .utf8)
        let palette = src.appendingPathComponent("palette.json")
        try "{ \"accent\": \"#007AFF\" }\n".write(to: palette, atomically: true, encoding: .utf8)
        return (dir, swift, notes, palette)
    }

    // MARK: Row 228

    @Test func onlySwiftAndCFamilySourcesGoToTheLanguageService() {
        for name in ["main.swift", "a.c", "a.h", "a.m", "a.mm", "a.cpp", "a.cc", "a.cxx", "a.hpp", "A.SWIFT"] {
            #expect(LanguageService.handles(URL(fileURLWithPath: "/p/\(name)")), "\(name)")
        }
        for name in ["NOTES.md", "palette.json", "Info.plist", "README", "notes.txt", "Stripes.png", "a.xcconfig",
                     "Localizable.xcstrings", "Main.storyboard", "a.entitlements", "a.yaml", "a.markdown"] {
            #expect(!LanguageService.handles(URL(fileURLWithPath: "/p/\(name)")), "\(name)")
        }
    }

    @Test func markdownAndJSONGetNoDiagnosticsAndNoIssueCount() async throws {
        let p = try package()
        defer { try? FileManager.default.removeItem(at: p.dir) }
        let s = WorkspaceSession(model: try WorkspaceModel(url: p.dir))
        let server = CompilingServer()
        // A window reopened with NOTES.md and palette.json in its editors:
        // the subtitle does not wait on them (it would hold to the timeout).
        let start = ContinuousClock.now
        await s.startLanguageService(opening: [(p.notes, "# Notes\n"), (p.palette, "{}\n")], transport: server, timeout: .seconds(5))
        #expect(ContinuousClock.now - start < .seconds(2))
        let language = try #require(s.language)
        // Opened, edited, saved and closed: none of it reaches the server.
        for url in [p.notes, p.palette] {
            language.open(url, text: "x\n")
            language.change(url, text: "y\n")
            language.saved(url)
            language.close(url)
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(server.documentNotifications.isEmpty, "\(server.documentNotifications)")
        #expect(language.liveIssues.isEmpty && s.displayedIssues.isEmpty)
        #expect(IssueSummary(s.displayedIssues).errors == 0)

        // The same server does answer for a Swift source: the fake is live.
        language.open(p.swift, text: "print(1)\n")
        var waited = 0
        while language.liveIssues.isEmpty, waited < 100 {
            try await Task.sleep(for: .milliseconds(20))
            waited += 1
        }
        #expect(server.documentNotifications == ["textDocument/didOpen \(p.swift.absoluteString)"])
        #expect(IssueSummary(s.displayedIssues).errors == 1)
        #expect(s.displayedIssues.allSatisfy { $0.location?.file.hasSuffix("main.swift") == true })
        await language.stop()
    }

    // MARK: Rows 229, 230

    @Test func typeNamesFollowTheFilesType() {
        func name(_ f: String, _ recorded: String? = nil) -> String {
            "Default - " + WorkspaceChrome.fileTypeName(for: URL(fileURLWithPath: "/p/\(f)"), recordedType: recorded)
        }
        #expect(name("NOTES.md") == "Default - Markdown")
        #expect(name("palette.json") == "Default - JSON")
        #expect(name("Long.swift") == "Default - Swift Source")
        #expect(name("Stripes.png") == "Default - PNG Image")
        #expect(name("a.h") == "Default - C Header" && name("a.m") == "Default - Objective-C Source")
        #expect(name("Info.plist") == "Default - Property List")
        #expect(name("a.weird") == "Default - Default")
        // The project file's recorded type wins over the extension.
        #expect(name("Notes.txt", "net.daringfireball.markdown") == "Default - Markdown")
    }

    @Test func resourcesAreDecidedByTheFilesType() {
        func resource(_ f: String, _ recorded: String? = nil) -> Bool { FileTypeRoles.isResource(URL(fileURLWithPath: "/p/\(f)"), recorded: recorded) }
        #expect(resource("NOTES.md") && resource("palette.json") && resource("Stripes.png"))
        for f in ["Long.swift", "a.m", "a.h", "a.xcconfig", "App.entitlements", "Info.plist", "App.xcodeproj"] {
            #expect(!resource(f), "\(f)")
        }
        #expect(!resource("x.json", "sourcecode.swift"))
    }

    @Test func aFileReferencesRecordedTypeReachesTheInspectorInfo() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("r9-recorded-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let proj = dir.appendingPathComponent("P.xcodeproj")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        try "notes\n".write(to: dir.appendingPathComponent("Notes.txt"), atomically: true, encoding: .utf8)
        let pbx = """
        // !$*UTF8*$!
        {
        \tarchiveVersion = 1;
        \tclasses = {
        \t};
        \tobjectVersion = 77;
        \tobjects = {
        \t\tF1 = {isa = PBXFileReference; lastKnownFileType = net.daringfireball.markdown; path = Notes.txt; sourceTree = "<group>"; };
        \t\tG1 = {isa = PBXGroup; children = (F1, ); sourceTree = "<group>"; };
        \t\tP1 = {isa = PBXProject; mainGroup = G1; targets = ( ); };
        \t};
        \trootObject = P1;
        }
        """
        try pbx.write(to: proj.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
        let model = try WorkspaceModel(url: proj)
        let info = FileInspectorInfo.make(for: dir.appendingPathComponent("Notes.txt"), in: model, repositoryRoot: nil)
        #expect(info.recordedType == "net.daringfireball.markdown")
    }
}
