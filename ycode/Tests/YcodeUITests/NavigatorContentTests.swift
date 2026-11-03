import AppKit
import Foundation
import Testing
import YcodeBuild
@testable import YcodeIDECore
@testable import YcodeUI

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
