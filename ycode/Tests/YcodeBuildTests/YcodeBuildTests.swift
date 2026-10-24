import Foundation
import Testing
@testable import YcodeBuild

@Suite struct DiagnosticParserTests {
    @Test func parsesLocatedIssues() {
        let d = DiagnosticParser.parseLine("/src/App/main.swift:12:5: error: cannot find 'foo' in scope")
        #expect(d == Diagnostic(severity: .error, message: "cannot find 'foo' in scope",
                                location: .init(file: "/src/App/main.swift", line: 12, column: 5)))
        let w = DiagnosticParser.parseLine("/src/a.c:3: warning: unused variable 'x' [-Wunused-variable]")
        #expect(w?.location == .init(file: "/src/a.c", line: 3, column: 0))
        #expect(w?.severity == .warning)
    }

    @Test func parsesUnlocatedIssues() {
        #expect(DiagnosticParser.parseLine("error: no such module 'Foo'")?.location == nil)
        let ld = DiagnosticParser.parseLine("ld: warning: directory not found for option '-L/x'")
        #expect(ld?.severity == .warning && ld?.location == nil)
        let plist = DiagnosticParser.parseLine("/p/Info.plist: error: bad file")
        #expect(plist?.location == .init(file: "/p/Info.plist", line: 0))
    }

    @Test func ignoresOtherLines() {
        #expect(DiagnosticParser.parseLine("CompileSwift normal arm64 /src/main.swift") == nil)
        #expect(DiagnosticParser.parseLine("    let x = foo") == nil)
        #expect(DiagnosticParser.parseLine("        ^~~") == nil)
    }

    @Test func messageMayContainMarker() {
        let d = DiagnosticParser.parseLine("/a.swift:1:1: error: string ': warning: ' is odd")
        #expect(d?.severity == .error && d?.message == "string ': warning: ' is odd")
    }

    @Test func attachesNotesAndFixIts() {
        let log = """
        /s/a.c:4:3: error: use of undeclared identifier 'cout'
            cout << 1;
            ^
        fix-it:"/s/a.c":{4:3-4:3}:"std::"
        /s/a.c:1:1: note: did you mean 'std::cout'?
        /s/a.c:9:1: warning: control reaches end
        /s/a.c:4:3: error: use of undeclared identifier 'cout'
        fix-it:"/s/a.c":{4:3-4:3}:"std::"
        /s/a.c:1:1: note: did you mean 'std::cout'?
        ** BUILD FAILED **
        """
        let issues = DiagnosticParser.parse(log)
        #expect(issues.count == 2) // the repeated error is dropped
        #expect(issues[0].notes.map(\.message) == ["did you mean 'std::cout'?"])
        #expect(issues[0].fixIts == [.init(file: "/s/a.c", start: .init(file: "/s/a.c", line: 4, column: 3),
                                           end: .init(file: "/s/a.c", line: 4, column: 3), replacement: "std::")])
        #expect(issues[1].severity == .warning)
    }

    @Test func streamingReturnsCompletedIssues() {
        var p = DiagnosticParser()
        #expect(p.feed("/a.swift:1:1: error: one").isEmpty)
        #expect(p.feed("/a.swift:1:1: note: n").isEmpty)
        #expect(p.feed("/a.swift:2:1: error: two").map(\.message) == ["one"])
        #expect(p.finish().map(\.message) == ["two"])
    }

    @Test func lineBufferSplitsAcrossChunks() {
        var b = LineBuffer()
        #expect(b.append(Data("ab\r\ncd".utf8)) == ["ab"])
        #expect(b.append(Data("e\nf".utf8)) == ["cde"])
        #expect(b.flush() == "f")
    }
}

@Suite struct XcodebuildEngineTests {
    @Test func buildsArguments() {
        let r = BuildRequest(container: .init(path: "/p/App.xcworkspace"), scheme: "App", configuration: "Debug",
                             destination: "platform=macOS", action: .clean, settings: [("ONLY_ACTIVE_ARCH", "YES")])
        #expect(XcodebuildEngine.arguments(for: r) == ["-workspace", "/p/App.xcworkspace", "-scheme", "App", "-configuration",
                                                       "Debug", "-destination", "platform=macOS", "clean", "ONLY_ACTIVE_ARCH=YES"])
        #expect(BuildRequest.Container(path: "/p/Package.swift") == .package("/p"))
    }

    @Test func activityText() {
        #expect(XcodebuildEngine.activity(for: "CompileSwift normal arm64 /src/main.swift (in target 'A')") == "Compiling main.swift")
        #expect(XcodebuildEngine.activity(for: "note: x") == nil)
    }

    @Test func streamsFromFakeTool() async {
        let script = "printf '/x/a.swift:2:3: error: bad\\nCompileSwift normal arm64 /x/a.swift\\n'; exit 65"
        let engine = XcodebuildEngine(command: ["/bin/sh", "-c", script, "fake"])
        var events: [BuildEvent] = []
        let result = await engine.start(BuildRequest(container: .project("/x/A.xcodeproj"))).run { events.append($0) }
        #expect(result.status == .failed && result.exitCode == 65)
        #expect(result.errorCount == 1)
        #expect(events.contains(.activity("Compiling a.swift")))
    }
}
