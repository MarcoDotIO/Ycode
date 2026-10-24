import AppKit
import Foundation
import Testing
import YcodeBuild
@testable import YcodeUI

@Suite struct IndexTests {
    @Test func searchFindsEveryMatchWithLines() {
        let m = WorkspaceSearch.search("greet", inText: "struct Greeter {\n    func greet() {}\n}\nlet g = Greeter()\n")
        #expect(m.map(\.line) == [1, 2, 4])
        #expect(m[1].text == "func greet() {}")
        #expect(m[0].range == NSRange(location: 7, length: 5))
    }

    @Test func swiftTopLevelSymbols() {
        let text = """
        /// struct NotThis {}
        import Foundation
        public struct Point { var x: Int; func length() -> Int { 0 } }
        final class Box<T> {
            class func make() -> Box { Box() }
            struct Inner {}
        }
        enum Kind { case a }
        protocol P {}
        extension Point: P {}
        actor Counter {}
        typealias Pair = (Int, Int)
        func main() { let s = "func fake()" }
        """
        let s = SymbolScanner.symbols(in: text, language: .swift)
        #expect(s.map(\.name) == ["Point", "Box", "Kind", "P", "Point", "Counter", "Pair", "main"])
        #expect(s.map(\.kind) == [.struct, .class, .enum, .protocol, .extension, .actor, .typealias, .function])
        #expect(s.last?.line == 13)
    }

    @Test func cAndObjCSymbols() {
        let c = "#define X(a) (a)\nstruct Pair { int a; };\nstatic int add(int a, int b) {\n  if (a) { return add(a, b); }\n  return a;\n}\nint proto(void);\n"
        #expect(SymbolScanner.symbols(in: c, language: .c).map(\.name) == ["Pair", "add"])
        let m = "@interface Foo : NSObject\n- (void)x;\n@end\n@implementation Foo\n- (void)x {}\n@end\n"
        #expect(SymbolScanner.symbols(in: m, language: .objc).map(\.kind) == [.interface, .implementation])
    }
}

/// A fake engine that writes a short log and succeeds or fails.
struct LogEngine: BuildEngine {
    var fail: Bool
    var name: String { "log" }
    func start(_ request: BuildRequest) -> BuildOperation {
        let (s, c) = AsyncStream<BuildEvent>.makeStream()
        c.yield(.output("CompileSwift normal arm64 /x/main.swift"))
        c.yield(.output(fail ? "** BUILD FAILED **" : "** BUILD SUCCEEDED **"))
        c.yield(.finished(BuildResult(status: fail ? .failed : .succeeded, exitCode: fail ? 65 : 0, issues: [])))
        c.finish()
        return BuildOperation(events: s, cancel: {})
    }
}

@MainActor
@Suite(.serialized) struct NavigatorContentTests {
    @Test func findSymbolAndReportNavigators() async throws {
        _ = NSApplication.shared
        let snapshots = WindowSnapshotTests()
        let dir = try snapshots.samplePackage()
        let session = WorkspaceSession(model: try WorkspaceModel(url: dir))
        let wc = WorkspaceWindowController(session: session, loadDestinations: false, startLanguageService: false)
        let window = try #require(wc.window)
        window.appearance = NSAppearance(named: .aqua)
        wc.applyDefaultLayout()
        let frame = window.contentView!.superview!

        // Find navigator.
        wc.navigator.select(3)
        wc.navigator.find("greet")
        let files = wc.navigator.rows(3)
        #expect(files.count == 1)
        #expect(files[0].children.map(\.line) == [1, 2, 5, 14, 15])
        _ = try snapshots.render(frame, to: "find-navigator.png")

        // Symbols (jump bar / Open Quickly; Bookmarks took the navigator).
        wc.navigator.refreshSymbols()
        let syms = wc.navigator.symbolRows
        #expect(syms.first?.title == "main.swift")
        #expect(syms.first?.children.map(\.title) == ["Greeter"])

        // Report navigator: newest first; selecting shows the log read-only.
        session.engine = LogEngine(fail: true)
        await session.build()
        session.engine = LogEngine(fail: false)
        await session.build()
        // One group per scheme; the failed build carries an error badge.
        let reports = wc.navigator.rows(8).first?.children ?? []
        #expect(reports.count == 2)
        #expect(reports[0].badge == nil && reports[1].badge != nil && reports[0].title == "Build")
        wc.navigator.select(8)
        wc.navigator.onOpenReport?(1)
        #expect(wc.editor.text.contains("** BUILD FAILED **"))
        #expect(!wc.editor.textView.isEditable && wc.editor.fileURL == nil)
        _ = try snapshots.render(frame, to: "report-navigator.png")
    }
}
