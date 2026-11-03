import Foundation
import Testing
import YcodeBuild
@testable import YcodeDebug
@testable import YcodeIDECore

@MainActor
@Suite struct DebugMenuTests {
    @Test func consoleRowParsing() {
        #expect(ConsoleRows.sourceLocation(in: "Shapes/Shapes.swift:12: Fatal error: x")! == ("Shapes/Shapes.swift", 12))
        #expect(ConsoleRows.sourceLocation(in: "/tmp/a.c:7:3: warning: y")! == ("/tmp/a.c", 7))
        #expect(ConsoleRows.sourceLocation(in: "Fatal error: z: file App/Model.swift, line 40")! == ("App/Model.swift", 40))
        #expect(ConsoleRows.sourceLocation(in: "sum=5") == nil)
        #expect(ConsoleRows.sourceLocation(in: "version 1.2:3") == nil)
        let files = ["/w/App/Model.swift", "/w/Other/Model.swift", "/w/App/Sub/View.swift"]
        #expect(ConsoleRows.resolve("App/Model.swift", files: files) == "/w/App/Model.swift")
        #expect(ConsoleRows.resolve("View.swift", files: files) == "/w/App/Sub/View.swift")
        #expect(ConsoleRows.resolve("Missing.swift", files: files) == nil)
        #expect(ConsoleRows.lastParagraph(in: "a\n\nb\nc\n\n") == NSRange(location: 3, length: 3))
        #expect(ConsoleRows.lastParagraph(in: "\n\n") == nil)
        #expect(ConsoleRows.rows([ConsoleEntry(kind: .debugger, text: "x")]).map(\.text) == ["x"])
    }
}
