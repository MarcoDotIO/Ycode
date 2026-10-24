import AppKit
import Foundation
import Testing
import YcodeBuild
import YcodeWorkspace
import YcodeDebug
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// specs/ide/reference-ui-2.md and the round-23 audit: opening state,
/// issue navigator and capsule, editor tabs, Find navigator, reports,
/// scheme editor panes, debug-area bars.
@MainActor
@Suite(.serialized) struct ReferenceUI2Tests {
    func withWindow(_ body: (WorkspaceWindowController, URL, Preferences) throws -> Void) throws {
        let t = TestDefaults("reference-ui-2")
        let dir = ycodeDir.appendingPathComponent(".build-ide/reference-ui-2/\(UUID().uuidString)")
        let p = Preferences(defaults: t.defaults, themesDirectory: dir.appendingPathComponent("Themes"))
        let old = Preferences.shared
        Preferences.shared = p
        defer {
            Preferences.shared = old
            NotificationCenter.default.post(name: Preferences.didChange, object: nil)
            t.remove()
            try? FileManager.default.removeItem(at: dir)
        }
        let src = dir.appendingPathComponent("Pkg/Sources/Demo")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"Demo\", targets: [.executableTarget(name: \"Demo\")])\n"
            .write(to: dir.appendingPathComponent("Pkg/Package.swift"), atomically: true, encoding: .utf8)
        try "struct Greeter {\n    func greet() {\n        let name = 1\n        print(name)\n    }\n}\nlet greeting = Greeter()\n"
            .write(to: src.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        try "let other = 2\nlet greeted = other\n".write(to: src.appendingPathComponent("Other.swift"), atomically: true, encoding: .utf8)
        _ = NSApplication.shared
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: dir.appendingPathComponent("Pkg"))),
                                           loadDestinations: false, startLanguageService: false, openFirstFile: false)
        wc.applyDefaultLayout()
        try body(wc, src, p)
    }

    @Test func openingStateIssuesAndCapsule() throws {
        try withWindow { wc, src, _ in
            // Nothing selected at open (reference-ui.md §2).
            #expect(wc.editor.fileURL == nil && wc.editor.pathComponents.isEmpty)
            // Issue navigator: root "N issues", groups by file without
            // extension, sorted; issue rows wrap to three lines.
            let main = src.appendingPathComponent("main.swift").path, other = src.appendingPathComponent("Other.swift").path
            wc.navigator.setIssues([
                Diagnostic(severity: .warning, message: "unused", location: .init(file: other, line: 1)),
                Diagnostic(severity: .error, message: "broken", location: .init(file: main, line: 3)),
            ])
            let root = try #require(wc.navigator.rows(4).first)
            #expect(root.detail == "2 issues" && root.children.map(\.title) == ["main", "Other"])
            #expect(root.children[0].children.first?.maxLines == 3)
            wc.navigator.issuesErrorsOnly = true
            #expect(wc.navigator.rows(4).first?.children.map(\.title) == ["main"])
            wc.navigator.issuesErrorsOnly = false
            wc.navigator.select(4)
            #expect(wc.navigator.recentToggle.toolTip == "Show only issues from open documents and recently built sources")
            #expect(wc.navigator.sourceControlToggle.toolTip == "Show only errors")
            // The toolbar capsule: hidden with nothing, zero counts left out.
            let cap = wc.issueCapsule
            #expect(cap.isHidden)
            cap.errors = 2
            cap.failedTests = 1
            #expect(!cap.isHidden && cap.parts.map(\.1) == [2, 1])
            _ = try WindowSnapshotTests().render(wc.window!.contentView!.superview!, to: "reference2-issues.png")
        }
    }

    @Test func editorTabsPinningAndCloseCommands() throws {
        try withWindow { wc, src, _ in
            let main = src.appendingPathComponent("main.swift").path, other = src.appendingPathComponent("Other.swift").path
            wc.openFromNavigator(path: main, line: nil)
            wc.openFromNavigator(path: other, line: nil)
            #expect(wc.editorArea.tabs.count == 1) // unpinned tab is replaced
            wc.toggleEditorTabBar(nil)
            #expect(wc.editorArea.isTabBarVisible && wc.editorArea.tabTitles == ["Other"])
            wc.togglePinEditorTab(nil)
            wc.openFromNavigator(path: main, line: nil)
            #expect(wc.editorArea.tabs.count == 2 && wc.editorArea.tabTitles == ["Other", "main"])
            #expect(CommandTable.command(titled: "Close Tab, Editor Pane, Window Tab, or Window")?.shortcutText == "⌘W")
            #expect(CommandTable.command(titled: "Close Editor Pane")?.shortcutText == "⌃⇧⌘W")
            #expect(CommandTable.command(titled: "Close Window")?.shortcutText == "⇧⌘W")
            #expect(CommandTable.command(titled: "Pin Editor Tab")?.shortcutText == "⇧⌘P")
            let item = NSMenuItem(title: "Close Document", action: #selector(WorkspaceWindowController.closeDocument(_:)), keyEquivalent: "")
            #expect(wc.validateMenuItem(item) && item.title == "Close \u{201C}main.swift\u{201D}")
            wc.closeDocument(nil)
            #expect(wc.editor.fileURL == nil)
        }
    }

    @Test func findNavigatorHeaderAndScopes() throws {
        try withWindow { wc, src, _ in
            #expect(NavigatorAreaController.findKinds.count == 9 && NavigatorAreaController.findMatches == ["Containing", "Matching Word", "Starting With", "Ending With"])
            #expect(wc.navigator.findStyle.item(at: 1)?.isEnabled == false && wc.navigator.findStyle.item(at: 2)?.isEnabled == true)
            wc.navigator.select(3)
            wc.navigator.findMatch.selectItem(at: 2) // Starting With
            wc.navigator.find("greet")
            let lines = wc.navigator.rows(3).flatMap { $0.children.map(\.title) }
            #expect(lines.contains { $0.contains("func greet") } && lines.contains { $0.contains("let greeted") })
            wc.navigator.findMatch.selectItem(at: 3) // Ending With: "greet" ends no word in "greeted"
            wc.navigator.find("greet")
            #expect(!wc.navigator.rows(3).flatMap { $0.children.map(\.title) }.contains { $0.contains("greeted") })
            wc.navigator.findMatch.selectItem(at: 0)
            wc.navigator.find("other")
            wc.navigator.setFindScope(.currentResults)
            wc.navigator.find("let")
            #expect(wc.navigator.rows(3).map(\.title).allSatisfy { $0.hasPrefix("Other.swift") })
            wc.navigator.setFindScope(.group(src.path))
            #expect(wc.navigator.findScope.title == "In Demo" || wc.navigator.findScope.title.hasPrefix("In "))
            wc.navigator.setFindScope(.workspace)
            #expect(wc.navigator.findScope.title == "In Package")
        }
    }

    @Test func reportNavigatorBuildLogAndTestReport() throws {
        try withWindow { wc, _, _ in
            var build = BuildReport(title: "Build Demo", date: Date(), succeeded: false,
                                    log: ["Compiling Demo main.swift", "main.swift:3:1: error: broken", "main.swift:1:1: warning: unused"],
                                    errorCount: 1, warningCount: 1)
            build.context.scheme = "Demo"
            build.context.containerKind = "Package"
            build.context.containerName = "Demo"
            build.context.duration = 2.04
            var test = BuildReport(title: "Test Demo", date: Date(), succeeded: false, log: [], errorCount: 1, warningCount: 0)
            test.context.action = "Test"
            test.context.scheme = "Demo"
            test.context.plan = "Demo (Autocreated)"
            test.context.testTargets = 1
            test.context.tests = [TestOutcome(suite: nil, name: "circleArea", status: .passed),
                                  TestOutcome(suite: nil, name: "squareArea", status: .failed,
                                              failures: [Diagnostic(severity: .error, message: "Expectation failed", location: .init(file: "/x/ShapeTests.swift", line: 9))])]
            wc.navigator.setReports([test, build])
            let group = try #require(wc.navigator.rows(8).first)
            #expect(group.title == "Demo" && group.children.map(\.title) == ["Demo/Demo (Autocreated)", "Build"])
            #expect(group.children[0].children.map(\.title) == ["Insights", "Coverage", "Tests", "Log", "Build"])
            #expect(group.children[1].badge == "1" && group.children[1].detail?.contains(",") == true)
            let log = BuildLogView(report: build)
            #expect(log.sectionTitle == "Build target Demo" && log.sectionSubtitle.hasPrefix("Package Demo | Configuration Debug"))
            #expect(log.shownSections.flatMap(\.steps).first?.issues.count == 2) // All Issues by default
            log.kind.selectedSegment = 2
            #expect(log.shownSections.flatMap(\.steps).first?.issues.map(\.message) == ["broken"])
            #expect(log.footerLines.0.hasPrefix("Build failed ") && log.footerLines.0.hasSuffix("2.0 seconds") && log.footerLines.1 == "1 error, 1 warning")
            let summary = TestReportView(report: test, page: .summary)
            #expect(summary.lines.contains("Demo/Demo (Autocreated)") && summary.lines.contains("2 Tests"))
            #expect(summary.lines.contains("Test Failures  1 total failure"))
            let tests = TestReportView(report: test, page: .tests)
            #expect(tests.lines.contains("1 failed and 1 passed · Test plan with 1 test target"))
            #expect(tests.lines.contains { $0.hasSuffix("ShapeTests.swift:9: Expectation failed") })
        }
    }

    @Test func debugBarsAndConsoleMetadata() throws {
        try withWindow { wc, _, p in
            let d = wc.debugArea
            _ = d.view
            #expect(d.scopePopUp.itemTitles == ["Auto", "Local Variables", "All Variables, Registers, Globals and Statics"])
            d.scopePopUp.selectItem(at: 2)
            d.scopeChosen()
            #expect(p.showRegisters)
            d.scopePopUp.selectItem(at: 0)
            d.scopeChosen()
            #expect(!p.showRegisters)
            wc.session.appendConsole("hello\n", kind: .target)
            var m = ConsoleMetadata()
            m.type = true
            #expect(wc.session.consoleText(.all, metadata: m) == "[Target] hello\n")
            m.enabled = false
            #expect(wc.session.consoleText(.all, metadata: m) == "hello\n")
            // Pause/Continue is found by action; step buttons hide without a session.
            #expect(d.pauseContinueButton != nil && d.pauseContinueButton?.isHidden == true)
            #expect(NavigatorAreaController.threadTitle(DebugThread(id: 1234, name: "Thread 1 name = main queue = com.apple.main-thread")) == "Thread 1 — name = main queue = com.apple.main-thread")
        }
    }

    @Test func schemeEditorPanesAndLaunchOptions() throws {
        _ = NSApplication.shared
        let text = try String(contentsOf: ycodeDir.appendingPathComponent(
            "Tests/YcodeWorkspaceTests/Fixtures/App.xcodeproj/xcshareddata/xcschemes/App.xcscheme"), encoding: .utf8)
        var scheme = try Scheme(parsing: text, name: "App")
        let e = SchemeEditorController(scheme: scheme, configurations: ["Debug", "Release"])
        _ = e.view
        #expect(e.selectedAction == 1 && SchemeEditorController.tabs(forAction: 1) == ["Info", "Arguments", "Options", "Diagnostics"])
        #expect(SchemeEditorController.tabs(forAction: 3) == ["Info", "Arguments", "Options"] && SchemeEditorController.tabs(forAction: 4).isEmpty)
        #expect(e.subtitle(forAction: 0).hasSuffix("target") || e.subtitle(forAction: 0).hasSuffix("targets"))
        for a in 0..<6 { for t in 0..<max(1, SchemeEditorController.tabs(forAction: a).count) { e.select(action: a, tab: t) } }
        #expect(SchemeEditorController.runOptionRows.count == 18 && SchemeEditorController.diagnosticRows.first?.title == "Address Sanitizer")
        #expect(SchemeEditorController.diagnosticRows.contains { $0.title == "Log allocation stack traces" && $0.on && $0.indent })
        // Build ▸ Targets checkboxes and Find Implicit Dependencies write the scheme.
        if let entry = scheme.buildEntries.first {
            scheme.setBuild(.archiving, false, blueprintIdentifier: entry.reference.blueprintIdentifier)
            #expect(scheme.buildEntries.first?.actions.contains(.archiving) == false)
        }
        scheme.setBuildImplicitDependencies(false)
        #expect(!scheme.buildImplicitDependencies)
        // Launch options follow the scheme's enabled entries.
        #expect(scheme.launchArguments.contains { $0.isEnabled })
    }

    /// A capture of the whole workspace window for the round report.
    @Test func workspaceWindowCapture() throws {
        try withWindow { wc, src, _ in
            let main = src.appendingPathComponent("main.swift").path
            wc.openFromNavigator(path: main, line: 3)
            wc.editor.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification))
            wc.toggleEditorTabBar(nil)
            wc.navigator.setIssues([Diagnostic(severity: .warning, message: "initialization of immutable value 'name' was never used; consider replacing with assignment to '_' or removing it",
                                               location: .init(file: main, line: 3))])
            wc.issueCapsule.warnings = 1
            wc.navigator.select(4)
            wc.showDebugArea(true)
            wc.session.appendConsole("Hello, world!\n", kind: .target)
            wc.session.appendConsole("\nProgram ended with exit code: 0\n", kind: .debugger)
            wc.debugArea.setConsole(wc.session.consoleText(.all))
            _ = try WindowSnapshotTests().render(wc.window!.contentView!.superview!, to: "workspace-round23.png")
        }
    }
}
