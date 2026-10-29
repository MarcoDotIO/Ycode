import Foundation
import Testing
@testable import YcodeBuild

@Suite struct SwiftBuildMessageReaderTests {
    @Test func readsTheMessageStream() {
        var r = SwiftBuildMessageReader()
        let text = Data("hello\\n".utf8).base64EncodedString()
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
        #expect(events.prefix(2) == [.progress(done: 0, total: 1), .activity("Compile main.c (arm64)")])
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

/// reference-ui-6.md §3.2 (T4): the task counts behind "Building • n/m".
@Suite struct BuildTaskCountTests {
    @Test func swiftBuildMessagesCountTasks() {
        var r = SwiftBuildMessageReader()
        let lines = [
            #"{"kind":"planningOperationStarted","planningOperationID":"p"}"#,
            #"{"kind":"taskStarted","executionDescription":"Compile a.c","id":1}"#,
            #"{"kind":"taskStarted","executionDescription":"Compile b.c","id":2}"#,
            #"{"kind":"taskUpToDate","taskSignature":"s"}"#,
            #"{"kind":"taskComplete","id":1,"result":"success"}"#,
            #"{"kind":"didUpdateProgress","message":"Building 2 of 9 tasks","percentComplete":20,"showInLog":false}"#,
            #"{"kind":"taskComplete","id":2,"result":"success"}"#,
            #"{"kind":"taskComplete","id":7,"result":"success"}"#,
        ]
        let events = lines.flatMap { r.feed($0) }
        #expect(events.first == .planning)
        let progress = events.compactMap { if case .progress(let d, let t) = $0 { return "\(d)/\(t)" } else { return nil } }
        #expect(progress == ["0/1", "0/2", "1/3", "2/3", "2/9", "3/9"])
        #expect(events.contains(.activity("Compile a.c")))
        #expect(r.tasksDone == 3 && r.tasksPlanned == 9)
        #expect(SwiftBuildMessageReader.plannedTotal(inProgressText: "Scanning build tasks") == nil)
    }

    @Test func textLogsCountSteps() {
        var c = LogTaskCounter()
        #expect(c.feed("note: Using global toolchain") == nil)
        #expect(c.feed("CompileSwift normal arm64 /p/a.swift (in target 'A' from project 'P')")! == (0, 1))
        #expect(c.feed("    cd /p") == nil)
        #expect(c.feed("Ld /p/build/A normal (in target 'A' from project 'P')")! == (1, 2))
        var spm = LogTaskCounter()
        #expect(spm.feed("[3/7] Compiling Demo main.swift")! == (2, 7))
        #expect(spm.feed("[7/7] Linking Demo")! == (6, 7))
        #expect(spm.feed("[x] not a step") == nil)
    }
}
