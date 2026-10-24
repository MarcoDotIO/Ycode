import Foundation
import Testing
@testable import YcodeBuild

@Suite struct SwiftBuildMessageReaderTests {
    @Test func readsTheMessageStream() {
        var r = SwiftBuildMessageReader()
        let text = "hello\\n".data(using: .utf8)!.base64EncodedString()
        let lines = [
            "120",
            #"{"kind":"taskStarted","executionDescription":"Compile main.c (arm64)","id":5}"#,
            #"{"kind":"output","data":"\#(Data("a\nb\n".utf8).base64EncodedString())"}"#,
            #"{"kind":"error","message":"expected ';'","location":{"locationType":"path","path":"/p/main.c","line":2,"column":44},"#
                + #""fixIts":[{"sourceRange":{"path":"/p/main.c","startLine":2,"startColumn":44,"endLine":2,"endColumn":44},"textToInsert":";"}],"#
                + #""childDiagnostics":[{"kind":"note","message":"here","location":{"locationType":"unknown"}}]}"#,
            #"{"kind":"warning","message":"global","location":{"locationType":"unknown"}}"#,
            #"{"kind":"buildCompleted","result":"failed"}"#,
            "error: build failed",
        ]
        let events = lines.flatMap { r.feed($0) }
        _ = text
        #expect(events.first == .activity("Compile main.c (arm64)"))
        #expect(events.contains(.output("a")) && events.contains(.output("b")))
        #expect(r.issues.count == 2)
        let e = r.issues[0]
        #expect(e.location == .init(file: "/p/main.c", line: 2, column: 44))
        #expect(e.fixIts.first?.replacement == ";" && e.notes.first?.severity == .note)
        #expect(r.issues[1].location == nil && r.issues[1].severity == .warning)
        #expect(r.completed == false)
        #expect(events.last == .output("error: build failed"))
    }

    @Test func invocationArguments() throws {
        let projURL = try writeToolProject(at: ideScratch.appendingPathComponent("pif-args"))
        let inv = try SwiftBuildEngine.invocation(
            for: BuildRequest(container: .project(projURL.path), scheme: "Tool", configuration: "Release",
                              derivedDataPath: "/tmp/dd", settings: [("FOO", "1")]),
            pifPath: URL(fileURLWithPath: "/w/p.json"), parametersPath: URL(fileURLWithPath: "/w/q.json"))
        #expect(inv.arguments == ["build", "/w/p.json", "--target", "Tool", "--buildParametersFile", "/w/q.json", "--derivedDataPath", "/tmp/dd"])
        let params = try JSONSerialization.jsonObject(with: inv.parameters) as! [String: Any]
        #expect(params["configurationName"] as? String == "Release")
        let table = ((params["overrides"] as! [String: Any])["commandLine"] as! [String: Any])["table"] as! [String: String]
        #expect(table == ["SDK_STAT_CACHE_ENABLE": "NO", "CODE_SIGN_IDENTITY": "-", "ENTITLEMENTS_DESTINATION": "", "ENTITLEMENTS_REQUIRED": "NO", "FOO": "1"])
        // No destination means My Mac: the host architecture only.
        #expect((params["activeRunDestination"] as? [String: Any])?["targetArchitecture"] as? String == SwiftBuildEngine.hostArchitecture)
    }
}

/// Builds the tool project with a real `swbuild` (from `YCODE_SWBUILD`, PATH,
/// or the probe build under .build-ide). Skipped when none is available.
@Suite(.serialized, .timeLimit(.minutes(5))) struct SwiftBuildEndToEndTests {
    static var swbuild: String? {
        SwiftBuildEngine.locate() ?? {
            let p = ideScratch.appendingPathComponent("sb-probe/.build/debug/swbuild").path
            return FileManager.default.isExecutableFile(atPath: p) ? p : nil
        }()
    }

    @Test func buildsAndReportsErrors() async throws {
        #if os(macOS)
        guard let tool = Self.swbuild else { return }
        let dir = ideScratch.appendingPathComponent("swiftbuild-e2e")
        let projURL = try writeToolProject(at: dir)
        let engine = SwiftBuildEngine(swbuild: tool)
        let request = BuildRequest(container: .project(projURL.path), scheme: "Tool",
                                   derivedDataPath: dir.appendingPathComponent("dd").path)
        var activities: [String] = []
        let ok = await engine.start(request).run { if case .activity(let a) = $0 { activities.append(a) } }
        #expect(ok.status == .succeeded)
        #expect(activities.contains { $0.contains("main.c") })
        let product = dir.appendingPathComponent("dd/Products/Debug/Tool")
        let run = Process()
        run.executableURL = product
        let out = Pipe()
        run.standardOutput = out
        try run.run()
        run.waitUntilExit()
        #expect(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "hello from swift-build\n")

        // A broken source: structured errors with location and fix-it.
        try "#include <stdio.h>\nint main(void) { undefined_call(); return 0 }\n"
            .write(to: dir.appendingPathComponent("Tool/main.c"), atomically: true, encoding: .utf8)
        let bad = await engine.start(request).run()
        #expect(bad.status == .failed)
        let errors = bad.issues.filter { $0.severity == .error && $0.location?.file.hasSuffix("main.c") == true }
        #expect(errors.contains { $0.location?.line == 2 && $0.location?.column == 18 })
        #expect(errors.contains { $0.fixIts.first?.replacement == ";" })
        #endif
    }
}
