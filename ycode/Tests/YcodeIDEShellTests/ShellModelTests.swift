import Foundation
import Testing
import YcodeBuild
import YcodeEditorKit
@testable import YcodeIDECore
@testable import YcodeIDEShell
import YcodeSyntax

/// A package on disk for one test.
struct TempPackage {
    let url: URL

    init(_ name: String = "Demo", error: Bool = false) throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-shell-\(UUID().uuidString)").appendingPathComponent(name)
        let fm = FileManager.default
        try fm.createDirectory(at: url.appendingPathComponent("Sources/DemoCore"), withIntermediateDirectories: true)
        try fm.createDirectory(at: url.appendingPathComponent("Sources/Demo"), withIntermediateDirectories: true)
        try fm.createDirectory(at: url.appendingPathComponent("Tests/DemoCoreTests"), withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"\(name)\")\n"
            .write(to: url.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "public struct Greeting {\n\tpublic var name: String\n    // Greets.\n    public var text: String { \"Hello, \\(name)\" }\n}\n"
            .write(to: url.appendingPathComponent("Sources/DemoCore/Greeting.swift"), atomically: true, encoding: .utf8)
        try "import DemoCore\nprint(Greeting(name: \"x\").text\(error ? " + missing" : ""))\n"
            .write(to: url.appendingPathComponent("Sources/Demo/main.swift"), atomically: true, encoding: .utf8)
        try "import Testing\n@Test func greets() {}\n"
            .write(to: url.appendingPathComponent("Tests/DemoCoreTests/GreetingTests.swift"), atomically: true, encoding: .utf8)
        try "# Demo\nA greeting package.\n".write(to: url.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    }

    func path(_ rel: String) -> String { url.appendingPathComponent(rel).path }
    func remove() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}

/// A build engine that replays a fixed log and issues.
struct ScriptedEngine: BuildEngine {
    var lines: [String]
    var issues: [Diagnostic]
    var name: String { "scripted" }
    func start(_ request: BuildRequest) -> BuildOperation {
        let (stream, c) = AsyncStream<BuildEvent>.makeStream()
        for l in lines { c.yield(.output(l)) }
        for d in issues { c.yield(.issue(d)) }
        let failed = issues.contains { $0.severity == .error }
        c.yield(.finished(BuildResult(status: failed ? .failed : .succeeded, exitCode: failed ? 1 : 0, issues: issues)))
        c.finish()
        return BuildOperation(events: stream, cancel: {})
    }
}

@MainActor
@Suite struct ShellModelTests {
    // MARK: Project navigator

    @Test func packageTreeMirrorsTheCoreWithItsInitialExpansion() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try WorkspaceShellModel(url: pkg.url, engine: ScriptedEngine(lines: [], issues: []))
        #expect(m.root.name == "Demo")
        #expect(m.root.children?.map(\.name) == ["Package.swift", "Sources", "Tests", "README.md"])
        // Files are leaves; folders have children.
        #expect(m.root.children?.first?.children == nil)
        #expect(m.root.children?[1].children?.map(\.name) == ["Demo", "DemoCore"])
        // Root, Sources and Tests start expanded (reference-ui-6.md §5.3, N4), their children collapsed.
        let sources = try #require(m.root.children?[1]), tests = try #require(m.root.children?[2])
        #expect(m.expanded == [m.root.id, sources.id, tests.id])
        #expect(m.root.symbolName == "shippingbox")  // a package, as in the AppKit navigator
        #expect(m.root.find(id: sources.id)?.name == "Sources")
        #expect(m.root.allFiles.count == 5)
        #expect(m.schemes == ["Demo"])
        #expect(m.destinations.first?.name == ShellBuildSetup.hostDestination.name && m.destination == m.destinations.first)
    }

    @Test func selectingAFileOpensItHighlightedAndRevealFindsItsRow() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try WorkspaceShellModel(url: pkg.url, engine: ScriptedEngine(lines: [], issues: []))
        let greeting = pkg.path("Sources/DemoCore/Greeting.swift")
        let row = try #require(m.root.allFiles.first { $0.path == greeting })
        m.selection = row.id
        let doc = try #require(m.document)
        #expect(doc.name == "Greeting.swift" && doc.language == .swift)
        let editor = try #require(m.editor)
        editor.buffer.refineHighlighting()
        let layout = EditorLineLayout(tabWidth: 4, advance: 7)
        #expect(editor.buffer.lineCount == 6)   // After the final newline, the empty line an editor shows.
        #expect(layout.displayLine(0, in: editor.buffer).runs.contains { $0.role == .keyword && $0.text.contains("public") })
        #expect(layout.displayLine(2, in: editor.buffer).runs.contains { $0.role == .comment })
        #expect(m.windowTitle == "Demo — Greeting.swift")
        // Reveal: collapse everything, then Navigate ▸ Reveal in Project Navigator.
        m.expanded = []
        m.navigator = .find
        m.revealInProjectNavigator()
        #expect(m.navigator == .project)
        #expect(m.selection == row.id)
        #expect(m.expanded.isSuperset(of: Set(try #require(m.root.idPath(to: greeting)).dropLast())))
        #expect(!m.expanded.contains(row.id))
    }

    @Test func historyGoesBackAndForwardOverOpenedFiles() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try WorkspaceShellModel(url: pkg.url, engine: ScriptedEngine(lines: [], issues: []))
        m.open(pkg.path("Package.swift"))
        m.open(pkg.path("README.md"))
        m.open(pkg.path("README.md"))
        #expect(m.canGoBack && !m.canGoForward)
        m.perform(.goBack)
        #expect(m.document?.name == "Package.swift" && m.canGoForward && !m.canGoBack)
        m.perform(.goForward)
        #expect(m.document?.name == "README.md")
        #expect(m.document?.language == .markdown)
    }

    // MARK: Find

    @Test func findInWorkspaceReturnsRowsPerFileAndOpensAMatch() async throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try WorkspaceShellModel(url: pkg.url, engine: ScriptedEngine(lines: [], issues: []))
        m.perform(.findInWorkspace)
        #expect(m.navigator == .find && m.findFocusCount == 1)
        m.findText = "greeting"
        m.runFind()
        await m.waitForFind()
        #expect(!m.isSearching)
        // Greeting.swift (1), main.swift (1), GreetingTests.swift has none ("greets"), README.md (1); ignoring case.
        #expect(m.findRows.map(\.name) == ["main.swift", "Greeting.swift", "README.md"])
        #expect(m.findCountText == "3 results in 3 files")
        let match = try #require(m.findRows.first { $0.name == "Greeting.swift" }?.matches.first)
        #expect(match.match == "Greeting" && match.before == "public struct " && match.line == 1)
        #expect(m.findRows.first { $0.name == "Greeting.swift" }?.title == "Greeting.swift  (1)")
        m.findSelection = match.id
        #expect(m.document?.name == "Greeting.swift" && m.markedLine == 1)
        // Matching case leaves out the README's "greeting".
        m.findIgnoreCase = false
        m.findText = "Greeting"
        m.runFind()
        await m.waitForFind()
        #expect(m.findCountText == "2 results in 2 files")
    }

    // MARK: Build and issues

    @Test func buildFillsTheLogAndTheIssueNavigatorAndStepsThroughIssues() async throws {
        let pkg = try TempPackage(error: true)
        defer { pkg.remove() }
        let main = pkg.path("Sources/Demo/main.swift"), greeting = pkg.path("Sources/DemoCore/Greeting.swift")
        let engine = ScriptedEngine(lines: ["[1/3] Compiling Demo main.swift", "error: build failed"], issues: [
            Diagnostic(severity: .error, message: "cannot find 'missing' in scope", location: .init(file: main, line: 2, column: 36)),
            Diagnostic(severity: .warning, message: "variable was never used", location: .init(file: greeting, line: 4, column: 5)),
            Diagnostic(severity: .error, message: "link failed"),
        ])
        let m = try WorkspaceShellModel(url: pkg.url, engine: engine)
        #expect(m.isEnabled(.build) && !m.isEnabled(.stop) && !m.isEnabled(.nextIssue))
        let result = await m.build()
        #expect(result.status == .failed)
        #expect(m.buildLog.contains("[1/3] Compiling Demo main.swift"))
        #expect(m.isDebugAreaShown && m.debugPane == .buildLog)
        #expect(m.issueCounts.errors == 2 && m.issueCounts.warnings == 1)
        // A failed build shows the Issue navigator.
        #expect(m.navigator == .issues)
        if case .finished(let s) = m.activity { #expect(s == "Build Failed") } else { Issue.record("activity \(m.activity)") }
        #expect(m.activityText.hasPrefix("Build Failed \u{2022} Today at "))
        // The package's targets group the files (IssueNavigatorModel.tree); the file-less error is the project's.
        #expect(m.issueGroups.map(\.title) == ["Demo", "Demo", "DemoCore"])
        #expect(m.issueGroups[0].issues.map(\.message) == ["Link failed"])
        #expect(m.issueGroups[1].files.map(\.title) == ["main"])
        let all = m.allIssues
        #expect(Set(all.map(\.id)).count == all.count)
        // ⌘' steps in the navigator's order (the project row's own issue first), opening each issue's line; ⇧⌘' goes back, wrapping.
        #expect(all.map(\.message) == ["Link failed", "Cannot find 'missing' in scope", "Variable was never used"])
        m.perform(.nextIssue)
        #expect(m.issueSelection == all[0].id && m.document == nil)
        m.perform(.nextIssue)
        #expect(m.document?.path == main && m.markedLine == 2)
        m.perform(.nextIssue)
        #expect(m.document?.path == greeting && m.markedLine == 4)
        m.perform(.previousIssue)
        m.perform(.previousIssue)
        m.perform(.previousIssue)
        #expect(m.issueSelection == all.last?.id)
    }

    @Test func areaTogglesAndMenuTitlesFollowTheState() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try WorkspaceShellModel(url: pkg.url, engine: ScriptedEngine(lines: [], issues: []))
        #expect(ShellCommand.toggleNavigator.title(in: m.menuContext) == "Hide Navigator")
        m.perform(.toggleNavigator)
        #expect(!m.isNavigatorShown && ShellCommand.toggleNavigator.title(in: m.menuContext) == "Show Navigator")
        m.perform(.showIssueNavigator)
        #expect(m.isNavigatorShown && m.navigator == .issues)
        #expect(ShellCommand.toggleDebugArea.title(in: m.menuContext) == "Show Debug Area")
        m.perform(.activateConsole)
        #expect(m.isDebugAreaShown && m.debugPane == .console)
        m.perform(.toggleInspector)
        #expect(ShellCommand.toggleInspector.title(in: m.menuContext) == "Show Inspector")
        #expect(ShellCommand.closeWorkspace.title(in: m.menuContext) == "Close Package")
        #expect(ShellCommand.findInWorkspace.title(in: m.menuContext) == "Find in Package")
        #expect(ShellCommand.findInWorkspace.title(in: nil) == "Find in Workspace")
    }

    // MARK: App

    @Test func appOpensFromAPathRecordsItAndClosesBackToWelcome() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let suite = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-shell-recents-\(UUID().uuidString)").path
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = ShellAppModel(recentProjects: RecentProjects(defaults: defaults), engine: { ScriptedEngine(lines: [], issues: []) })
        #expect(app.workspace == nil && app.recent.isEmpty)
        #expect(!app.open(path: pkg.url.deletingLastPathComponent().path))
        #expect(app.openError?.contains("is not a project, workspace or package folder") == true)
        #expect(app.open(path: pkg.path("Package.swift")))
        #expect(app.workspace?.workspaceName == "Demo" && app.openError == nil)
        #expect(app.recent.map(\.lastPathComponent) == ["Demo"])
        #expect(app.isEnabled(.closeWorkspace) && app.title(.closeWorkspace) == "Close Package")
        app.perform(.closeWorkspace)
        #expect(app.workspace == nil && !app.isEnabled(.closeWorkspace) && app.title(.closeWorkspace) == "Close Workspace")
        app.perform(.open)
        #expect(app.isOpenSheetShown)
    }

    @Test func launchPathSkipsOptionsAndResolvesRelativePaths() {
        #expect(ShellAppModel.launchPath(["ycode-ide"]) == nil)
        #expect(ShellAppModel.launchPath(["ycode-ide", "/a/Pkg"]) == "/a/Pkg")
        #expect(ShellAppModel.launchPath(["ycode-ide", "Pkg"], workingDirectory: "/w") == "/w/Pkg")
        #expect(ShellAppModel.launchPath(["ycode-ide", "-NSDocumentRevisionsDebugMode", "YES", "--verbose", "P.xcodeproj"],
                                         workingDirectory: "/w") == "/w/P.xcodeproj")
    }
}

@Suite struct ShellCommandTests {
    @Test func everyCommandIsInTheCoreTableWithAUniqueShortcut() {
        var seen: [ShellShortcut: ShellCommand] = [:]
        for c in ShellCommand.allCases {
            #expect(c.menuCommand != nil, "\(c) has no CommandTable entry")
            // Save All and View Memory: the AppKit IDE lists them unavailable; this shell performs them.
            #expect(c.menuCommand?.isAvailable == true || c == .saveAll || c == .viewMemory, "\(c) is unavailable in the core")
            if let s = c.shortcut {
                #expect(seen[s] == nil, "\(c) and \(seen[s].map { "\($0)" } ?? "") share \(s.text)")
                seen[s] = c
            }
        }
        #expect(ShellCommand.build.shortcut?.text == "⌘B")
        #expect(ShellCommand.findInWorkspace.shortcut?.text == "⇧⌘F")
        #expect(ShellCommand.showFindNavigator.shortcut?.text == "⌘4")
        #expect(ShellCommand.showIssueNavigator.shortcut?.text == "⌘5")
        // ⌘" is ⇧⌘' for toolkits that take unshifted keys.
        #expect(ShellCommand.previousIssue.shortcut == ShellShortcut(key: "'", modifiers: [.command, .shift]))
        #expect(ShellCommand.goBack.shortcut == ShellShortcut(key: Key.left, modifiers: [.command, .control]))
        #expect(ShellCommand.toggleNavigator.shortcut == nil)
    }

    @Test func navigatorsKeepTheirPlaceInTheFullSelectorBar() {
        #expect(ShellNavigator.allCases.map(\.title) == ["Project", "Source Control", "Symbols", "Find", "Issues", "Tests", "Debug", "Breakpoints", "Reports"])
        #expect(ShellNavigator.allCases.map { $0.command.shortcut?.text } == ["⌘1", "⌘2", "⌘3", "⌘4", "⌘5", "⌘6", "⌘7", "⌘8", "⌘9"])
        #expect(ShellCommand.scmCommit.shortcut?.text == "⌥⌘C")
        #expect(ShellCommand.scmCommit.menu == "Integrate")
    }
}

@Suite struct SourceTextTests {
    @Test func linesSplitOnNewlinesWithoutATrailingEmptyLine() {
        #expect(SourceDocument.highlight("a\nb\n", language: .plain).map(\.text) == ["a", "b"])
        #expect(SourceDocument.highlight("a\r\nb", language: .plain).map(\.text) == ["a", "b"])
        #expect(SourceDocument.highlight("", language: .plain).map(\.text) == [""])
        #expect(SourceDocument.highlight("a\n\n", language: .plain).map(\.text) == ["a", ""])
    }

    @Test func tokensBecomeRolesAndTabsExpandToStops() {
        let lines = SourceDocument.highlight("\tlet x = 12 // n\n", language: .swift)
        #expect(lines.count == 1)
        let runs = lines[0].runs
        #expect(lines[0].text == "    let x = 12 // n")
        #expect(runs.first { $0.text == "let" }?.role == .keyword)
        #expect(runs.first { $0.text == "12" }?.role == .number)
        #expect(runs.last?.role == .comment)
        // Identifiers draw in the plain color.
        #expect(runs.contains { $0.role == nil && $0.text.contains("x") })
        var col = 2
        #expect(SourceDocument.expandTabs("a\tb", column: &col) == "a b" && col == 5)
    }

    @Test func documentsReportBinaryAndMissingFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-shell-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bin = dir.appendingPathComponent("blob.dat")
        try Data([0x41, 0x00, 0x42]).write(to: bin)
        #expect(SourceDocument.load(path: bin.path).message == "Binary file")
        #expect(SourceDocument.load(path: dir.appendingPathComponent("gone.swift").path).message == "Cannot read gone.swift")
    }

    @Test func paletteFollowsTheSelectedTheme() throws {
        // "Ycode Default" (the AppKit editor's default): the system colors
        // as values, per appearance.
        let light = SourcePalette.forAppearance(dark: false), dark = SourcePalette.forAppearance(dark: true)
        #expect(light.background.hex == "#FFFFFF" && dark.background.hex == "#1E1E1E")
        #expect(light.color(.keyword) == WorkspaceChrome.defaultThemeColors(dark: false).tokens["keyword"])
        #expect(dark.color(.keyword) == WorkspaceChrome.defaultThemeColors(dark: true).tokens["keyword"])
        #expect(light.color(nil) == light.foreground && light.color(.identifier) == light.foreground)
        // A theme with its own colors: those.
        let paper = try #require(EditorTheme.builtIns.first { $0.name == "Ycode Paper" })
        let p = SourcePalette.forAppearance(dark: true, theme: paper)
        #expect(p.background.hex == "#FBF8F1" && p.color(.keyword).hex == "#8A2D5E")
    }
}

@Suite struct PackageBuildEngineTests {
    @Test func argumentsPerAction() {
        func r(_ a: BuildRequest.Action, config: String? = nil) -> BuildRequest {
            var q = BuildRequest(container: .package("/p"), scheme: "P", destination: nil, action: a)
            q.configuration = config
            return q
        }
        #expect(PackageBuildEngine.arguments(for: r(.build)) == ["build", "--package-path", "/p"])
        #expect(PackageBuildEngine.arguments(for: r(.build, config: "Release")) == ["build", "--package-path", "/p", "-c", "release"])
        #expect(PackageBuildEngine.arguments(for: r(.clean)) == ["package", "--package-path", "/p", "clean"])
        #expect(PackageBuildEngine.arguments(for: r(.test)) == ["test", "--package-path", "/p"])
        #expect(PackageBuildEngine.arguments(for: BuildRequest(container: .project("/a.xcodeproj"), scheme: nil, destination: nil, action: .build)) == nil)
    }

    @Test func activityTextFromSwiftPMLines() {
        #expect(PackageBuildEngine.activity(for: "[3/9] Compiling GreeterCore Greeting.swift") == "Compiling Greeting.swift")
        #expect(PackageBuildEngine.activity(for: "[8/9] Linking Greeter") == "Linking Greeter")
        #expect(PackageBuildEngine.activity(for: "Building for debugging...") == "Planning")
        #expect(PackageBuildEngine.activity(for: "Build complete! (1.2s)") == nil)
        #expect(PackageBuildEngine.activity(for: "/p/a.swift:1:2: error: x") == nil)
    }

    @Test func executableProductsFromDescribe() {
        let json = #"{"name":"G","products":[{"name":"GKit","type":{"library":["automatic"]}},{"name":"g","type":{"executable":null}}]}"#
        #expect(PackageBuildEngine.executableProducts(describeJSON: Data(json.utf8)) == ["g"])
        #expect(PackageBuildEngine.executableProducts(describeJSON: Data("nope".utf8)) == nil)
    }

    @Test func swiftPMOutputLosesColoursAndRepeatedFailures() {
        #expect(SwiftPMRun.stripANSI("\u{1B}[1;31merror: \u{1B}[1;39mbad\u{1B}[0m") == "error: bad")
        #expect(SwiftPMRun.stripANSI("plain") == "plain")
        #expect(SwiftPMRun.isSummary(Diagnostic(severity: .error, message: "Build failed")))
        #expect(SwiftPMRun.isSummary(Diagnostic(severity: .error, message: "SwiftCompile normal x86_64 failed with a nonzero exit code. Command line: cd /p")))
        #expect(!SwiftPMRun.isSummary(Diagnostic(severity: .error, message: "Build failed", location: .init(file: "/a.swift", line: 1))))
        #expect(!SwiftPMRun.isSummary(Diagnostic(severity: .error, message: "undefined reference to 'x'")))
    }

    @Test func aProjectGetsAClearFailureFromThePackageEngine() async {
        let op = PackageBuildEngine().start(BuildRequest(container: .project("/a.xcodeproj"), scheme: nil, destination: nil, action: .build))
        var lines: [String] = []
        let result = await op.run { if case .output(let l) = $0 { lines.append(l) } }
        #expect(result.status == .failed)
        #expect(lines.first?.contains("Swift packages only") == true)
    }
}

/// The chrome the shell draws from the AppKit IDE's rules
/// (`WorkspaceChrome`, `docs/PARITY.md` §5.10): outline rows, the jump bar,
/// the File inspector, the menu bar's shortcuts.
@MainActor
@Suite struct ShellChromeTests {
    @Test func projectRowsAreTheAppKitOutlinesRows() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try WorkspaceShellModel(url: pkg.url, engine: ScriptedEngine(lines: [], issues: []))
        let rows = OutlineRows.project(m.root, expanded: m.expanded, hideExtensions: true)
        // The package, its manifest without extension, Sources and Tests
        // expanded with their (collapsed) target folders.
        #expect(rows.map(\.title) == ["Demo", "Package", "Sources", "Demo", "DemoCore", "Tests", "DemoCoreTests", "README"])
        #expect(rows.map(\.level) == [0, 1, 1, 2, 2, 1, 2, 1])
        #expect(rows[0].symbol == "shippingbox" && rows[1].symbol == "chevron.left.forwardslash.chevron.right")
        #expect(rows[2].symbol == "folder.fill" && rows[2].isExpandable && rows[2].isExpanded)
        #expect(rows[3].isExpandable && !rows[3].isExpanded && !rows[1].isExpandable && rows[1].opens)
        #expect(OutlineRows.project(m.root, expanded: m.expanded, hideExtensions: false)[1].title == "Package.swift")
        m.setExpanded(rows[2].id, false)
        #expect(m.projectRows.map(\.title) == ["Demo", "Package", "Sources", "Tests", "DemoCoreTests", "README"])
    }

    @Test func jumpBarAndFileInspectorFollowTheAppKitIDE() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try WorkspaceShellModel(url: pkg.url, engine: ScriptedEngine(lines: [], issues: []))
        #expect(m.jumpPath.isEmpty && m.fileInspector.isEmpty)
        m.open(pkg.path("Sources/DemoCore/Greeting.swift"))
        let hide = m.hidesFileExtensions
        #expect(m.jumpPath.map(\.title) == ["Demo", "Sources", "DemoCore", hide ? "Greeting" : "Greeting.swift"])
        #expect(m.jumpPath.map(\.symbol) == ["shippingbox", "folder.fill", "folder.fill", "chevron.left.forwardslash.chevron.right"])
        let sections = m.fileInspector
        #expect(sections.map(\.title) == ["Identity and Type", "Text Settings"])
        #expect(sections[0].rows.map(\.key) == ["Name", "Type", "Location", "", "Full Path"])
        #expect(sections[0].rows[0].value == .field("Greeting.swift"))
        #expect(sections[0].rows[1].value == .popUp("Default - Swift Source"))
        #expect(sections[1].rows.map(\.key) == ["Text Encoding", "Line Endings", "Indent Using", "Widths"])
        #expect(sections[1].rows[0].value == .popUp(WorkspaceChrome.textEncodingItems[0]))
    }

    @Test func findAndIssueRows() throws {
        let file = "/p/Sources/A/a.swift"
        let match = FindMatchRow.rows([WorkspaceSearch.FileResult(path: file, matches: [
            WorkspaceSearch.Match(line: 3, text: "let x = Greeting()", range: NSRange(location: 8, length: 8), column: 9,
                                  highlight: NSRange(location: 8, length: 8)),
        ])])
        #expect(match.first?.title == "a.swift  (1)")
        let rows = OutlineRows.find(match, collapsed: [])
        #expect(rows.map(\.level) == [0, 1] && rows[0].isBold && rows[0].symbol == "doc.text")
        #expect(rows[1].title == "let x = Greeting()" && rows[1].match?.match == "Greeting" && rows[1].opens)
        #expect(OutlineRows.find(match, collapsed: [file]).count == 1)
        let issue = IssueRow(id: "i", severity: .error, message: "Oops", file: file, line: 3, column: 1, isStale: false)
        let groups = [IssueGroupRow(id: "g", title: "P", countText: "1 issue", issues: [],
                                    files: [IssueFileRow(id: "g|" + file, title: "a", issues: [issue])])]
        let ir = OutlineRows.issues(groups, collapsed: [])
        #expect(ir.map(\.title) == ["P", "a", "Oops"] && ir.map(\.level) == [0, 1, 2])
        #expect(ir[0].detail == "1 issue" && ir[0].isBold && ir[1].symbol == "chevron.left.forwardslash.chevron.right")
        #expect(ir[2].tint == .error && ir[2].symbol == "xmark.circle.fill" && ir[2].opens)
    }

    @Test func everyMenuCommandHasAShortcutTheToolkitsTake() {
        // A command listed in two menus (Developer Documentation) keeps one
        // shortcut; two different commands never share one.
        var seen: [ShellShortcut: (title: String, action: String)] = [:]
        func walk(_ items: [MenuItemSpec]) {
            for i in items {
                switch i {
                case .command(let c):
                    guard let s = ShellShortcut(command: c) else { continue }
                    #expect(Key.shiftedBase[s.key] == nil, "\(c.title)")
                    if !c.isAlternate, c.condition == nil, let other = seen[s], other.action != c.action {
                        Issue.record("\(c.title) and \(other.title) share \(s.text)")
                    }
                    seen[s] = (c.title, c.action)
                case .submenu(_, let sub): walk(sub)
                case .separator, .label: break
                }
            }
        }
        for (_, items) in CommandTable.menus { walk(items) }
        #expect(seen.count > 100)
        #expect(WorkspaceChrome.activityFinishedText("Build Succeeded", at: Date()).hasPrefix("Build Succeeded \u{2022} Today at "))
    }
}
