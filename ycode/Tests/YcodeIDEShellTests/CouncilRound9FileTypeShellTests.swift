import Foundation
import Testing
import YcodeBuild
import YcodeDebug
import YcodeLanguage
@testable import YcodeIDECore
@testable import YcodeIDEShell

/// Council round 9, group C (`specs/ide/fidelity-council.md` rows 228–230)
/// in the Linux IDE's model, as the macOS IDE
/// (`CouncilRound9FileTypeUITests`): NOTES.md and palette.json in a Swift
/// project get no language-service diagnostic and no toolbar error count;
/// the File inspector reads "Default - Markdown" / "Default - JSON" and
/// shows a resource's Tags field and Localization section.
@MainActor
@Suite(.serialized) struct CouncilRound9FileTypeShellTests {
    /// A server that publishes a line-1 compile error for every document it
    /// is told about (as sourcekit-lsp did for Markdown and JSON), and
    /// records those documents.
    final class CompilingServer: DAPTransport, @unchecked Sendable {
        static let message = "Unable to handle compilation, expected exactly one compiler job in ''"
        private let lock = NSLock()
        private var receiving: (@Sendable (Data?) -> Void)?
        private var decoder = DAPFraming.Decoder()
        private var seen: [String] = []
        var documents: [String] { lock.withLock { seen } }

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
                    lock.withLock { seen.append(URL(string: uri)?.lastPathComponent ?? uri) }
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

    /// The council's GlassScroll project (one synchronized folder, one app
    /// target) with Long.swift, NOTES.md, palette.json and a PNG.
    func project() throws -> (dir: URL, src: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("r9c-\(UUID().uuidString)")
        let src = dir.appendingPathComponent("GlassScroll")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("GlassScroll.xcodeproj"), withIntermediateDirectories: true)
        try Self.pbxproj.write(to: dir.appendingPathComponent("GlassScroll.xcodeproj/project.pbxproj"), atomically: true, encoding: .utf8)
        try "import Foundation\n\nstruct Long {}\n".write(to: src.appendingPathComponent("Long.swift"), atomically: true, encoding: .utf8)
        try "# Notes\n\nSome notes about the project.\n".write(to: src.appendingPathComponent("NOTES.md"), atomically: true, encoding: .utf8)
        try "{\n  \"accent\": \"#007AFF\"\n}\n".write(to: src.appendingPathComponent("palette.json"), atomically: true, encoding: .utf8)
        // A 1 × 1 PNG (signature, IHDR, IDAT, IEND).
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D, 0x49, 0x48, 0x44, 0x52, 0, 0, 0, 1, 0, 0, 0, 1,
                            8, 2, 0, 0, 0, 0x90, 0x77, 0x53, 0xDE, 0, 0, 0, 0x0C, 0x49, 0x44, 0x41, 0x54, 0x08, 0xD7, 0x63, 0xF8, 0xFF,
                            0xFF, 0x3F, 0, 0x05, 0xFE, 0x02, 0xFE, 0xDC, 0xCC, 0x59, 0xE7, 0, 0, 0, 0, 0x49, 0x45, 0x4E, 0x44, 0xAE,
                            0x42, 0x60, 0x82]
        try Data(png).write(to: src.appendingPathComponent("Stripes.png"))
        return (dir, src)
    }

    func model(_ dir: URL) throws -> WorkspaceShellModel {
        try WorkspaceShellModel(url: dir.appendingPathComponent("GlassScroll.xcodeproj"), engine: ScriptedEngine(lines: [], issues: []))
    }

    // MARK: Row 228

    @Test func markdownAndJSONShowNoLanguageServiceErrorOrErrorCount() async throws {
        let (dir, src) = try project()
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = try model(dir)
        let server = CompilingServer()
        await m.session.startLanguageService(opening: [], transport: server)
        let language = try #require(m.session.language)
        for name in ["NOTES.md", "palette.json"] {
            m.open(src.appendingPathComponent(name).path)
            #expect(m.document?.name == name)
            try await Task.sleep(for: .milliseconds(400))
            #expect(m.editorIssues.isEmpty, "\(name): \(m.editorIssues)")
            #expect(m.issueCounts.errors == 0 && m.issueCounts.warnings == 0, "\(name)")
            #expect(m.allIssues.isEmpty, "\(name)")
        }
        #expect(server.documents.isEmpty, "\(server.documents)")

        // The same server answers for a Swift source: the count shows it.
        m.open(src.appendingPathComponent("Long.swift").path)
        var waited = 0
        while m.issueCounts.errors == 0, waited < 200 {
            try await Task.sleep(for: .milliseconds(20))
            waited += 1
        }
        #expect(m.issueCounts.errors == 1 && server.documents == ["Long.swift"])
        m.open(src.appendingPathComponent("NOTES.md").path)
        #expect(m.editorIssues.isEmpty)
        await language.stop()
    }

    // MARK: Rows 229, 230

    @Test func fileInspectorReadsTheTypeAndShowsAResourcesSections() throws {
        let (dir, src) = try project()
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = try model(dir)
        for (name, type) in [("NOTES.md", "Default - Markdown"), ("palette.json", "Default - JSON")] {
            m.open(src.appendingPathComponent(name).path)
            let sections = m.fileInspector
            #expect(sections.map(\.title) == ["Identity and Type", "On Demand Resource Tags", "Localization", "Target Membership", "Text Settings"],
                    "\(name): \(sections.map(\.title))")
            #expect(sections.first?.rows.first { $0.key == "Type" }?.value == .popUp(type), "\(name)")
            #expect(sections[1].rows.first?.value == .tags(placeholder: "Tags", enabled: true), "\(name)")
            #expect(sections[2].rows.first?.value == .button("Localize…"), "\(name)")
        }
        m.open(src.appendingPathComponent("Long.swift").path)
        let swift = m.fileInspector
        #expect(swift.first?.rows.first { $0.key == "Type" }?.value == .popUp("Default - Swift Source"))
        #expect(!swift.map(\.title).contains("Localization"))
        #expect(swift[1].rows.first?.value == .tags(placeholder: "Only resources are taggable", enabled: false))
        m.open(src.appendingPathComponent("Stripes.png").path)
        let image = m.fileInspector
        #expect(image.first?.rows.first { $0.key == "Type" }?.value == .popUp("Default - PNG Image"))
        #expect(image.map(\.title) == ["Identity and Type", "On Demand Resource Tags", "Image Properties", "Localization", "Target Membership"])
    }

    static let pbxproj = """
    // !$*UTF8*$!
    {
    \tarchiveVersion = 1;
    \tclasses = {
    \t};
    \tobjectVersion = 77;
    \tobjects = {
    \t\t0B0000000000000000000001 /* GlassScroll.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = GlassScroll.app; sourceTree = BUILT_PRODUCTS_DIR; };
    \t\t0D0000000000000000000010 /* GlassScroll */ = {isa = PBXFileSystemSynchronizedRootGroup; path = GlassScroll; sourceTree = "<group>"; };
    \t\t0D0000000000000000000001 = {isa = PBXGroup; children = (0D0000000000000000000010 /* GlassScroll */, 0D0000000000000000000003 /* Products */, ); sourceTree = "<group>"; };
    \t\t0D0000000000000000000003 /* Products */ = {isa = PBXGroup; children = (0B0000000000000000000001 /* GlassScroll.app */, ); name = Products; sourceTree = "<group>"; };
    \t\t0E0000000000000000000001 /* GlassScroll */ = {isa = PBXNativeTarget; buildConfigurationList = 0F0000000000000000000011; buildPhases = (); buildRules = (); dependencies = (); fileSystemSynchronizedGroups = (0D0000000000000000000010 /* GlassScroll */, ); name = GlassScroll; productName = GlassScroll; productReference = 0B0000000000000000000001 /* GlassScroll.app */; productType = "com.apple.product-type.application"; };
    \t\t0A0000000000000000000001 /* Project object */ = {isa = PBXProject; buildConfigurationList = 0F0000000000000000000001; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base, ); mainGroup = 0D0000000000000000000001; productRefGroup = 0D0000000000000000000003 /* Products */; projectDirPath = ""; projectRoot = ""; targets = (0E0000000000000000000001 /* GlassScroll */, ); };
    \t\t0F0000000000000000000002 /* Debug */ = {isa = XCBuildConfiguration; buildSettings = {SDKROOT = macosx; }; name = Debug; };
    \t\t0F0000000000000000000012 /* Debug */ = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_NAME = "$(TARGET_NAME)"; }; name = Debug; };
    \t\t0F0000000000000000000001 = {isa = XCConfigurationList; buildConfigurations = (0F0000000000000000000002 /* Debug */, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
    \t\t0F0000000000000000000011 = {isa = XCConfigurationList; buildConfigurations = (0F0000000000000000000012 /* Debug */, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
    \t};
    \trootObject = 0A0000000000000000000001 /* Project object */;
    }

    """
}
