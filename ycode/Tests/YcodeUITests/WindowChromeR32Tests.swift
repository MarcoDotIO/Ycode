import AppKit
import Foundation
import Testing
import YcodeBuild
import YcodeProject
@testable import YcodeDebug
@testable import YcodeUI

/// R32 (`specs/ide/reference-ui-5.md` §4, §5.2–§5.3, §6.1–§6.2, §7, §8):
/// window chrome — toolbar, jump bars, debug bar, navigators' bottom bars,
/// inspectors and the debug area's bars.
@MainActor
@Suite(.serialized) struct WindowChromeR32Tests {
    func tempDir(_ tag: String) throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-r32-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u.resolvingSymlinksInPath()
    }

    /// A package "Chrome" with two Swift files; with `git`, committed in a
    /// fresh repository (author "Ada Tester").
    func package(_ tag: String, git: Bool = false) throws -> URL {
        let dir = try tempDir(tag)
        let src = dir.appendingPathComponent("Sources/Chrome")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"Chrome\", targets: [.target(name: \"Chrome\")])\n"
            .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "public struct Model {\n    public var value = 1\n}\n".write(to: src.appendingPathComponent("Model.swift"), atomically: true, encoding: .utf8)
        try "public func helper() -> Int {\n    1\n}\n".write(to: src.appendingPathComponent("Helper.swift"), atomically: true, encoding: .utf8)
        if git {
            Self.git(dir, ["init", "-q"])
            Self.git(dir, ["add", "-A"])
            Self.git(dir, ["-c", "user.name=Ada Tester", "-c", "user.email=ada@example.com", "commit", "-q", "-m", "Initial import"])
        }
        return dir
    }

    @discardableResult
    static func git(_ dir: URL, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir.path] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return "" }
        p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    func window(_ url: URL) throws -> WorkspaceWindowController {
        _ = NSApplication.shared
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: url)), loadDestinations: false,
                                           startLanguageService: false, openFirstFile: false)
        wc.applyDefaultLayout()
        return wc
    }

    func selected(_ c: NSSegmentedControl) -> [Bool] { (0..<c.segmentCount).map { c.isSelected(forSegment: $0) } }

    // MARK: T2 — Navigators | Coding Assistant

    @Test func leftSegmentsFollowTheLeftArea() throws {
        let dir = try package("t2")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wc = try window(dir)
        let c = wc.leftPanesControl
        #expect((0..<2).map { c.toolTip(forSegment: $0) } == ["Navigators", "Coding Assistant"])
        // At open, Navigators is selected.
        #expect(selected(c) == [true, false] && wc.shownLeftPane == .navigators)
        // View ▸ Navigators ▸ Hide Navigator: neither.
        wc.toggleNavigator(nil)
        #expect(selected(c) == [false, false] && wc.shownLeftPane == nil)
        wc.toggleNavigator(nil)
        #expect(selected(c) == [true, false])
        // ⌘0: Coding Assistant.
        wc.showCodingAssistant(nil)
        #expect(selected(c) == [false, true] && wc.navigator.showsCodingAssistant)
        // ⌘4 brings the navigators back.
        let item = NSMenuItem(title: "Issues", action: nil, keyEquivalent: "")
        item.tag = 4
        wc.showNavigator(item)
        #expect(selected(c) == [true, false] && !wc.navigator.showsCodingAssistant && wc.navigator.selectedIndex == 4)
        // Clicking the selected segment hides the area; neither is selected.
        wc.setLeftPane(codingAssistant: false)
        #expect(selected(c) == [false, false])
        // Clicking the unselected one opens the area with that content.
        wc.setLeftPane(codingAssistant: true)
        #expect(selected(c) == [false, true])
    }

    // MARK: T3 — Canvas | Assistant | Code Review

    @Test func editorModesAreExclusive() throws {
        let dir = try package("t3", git: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wc = try window(dir)
        let model = dir.appendingPathComponent("Sources/Chrome/Model.swift").path
        wc.open(path: model, line: nil)
        let c = wc.editorModesControl
        #expect((0..<3).map { c.toolTip(forSegment: $0) } == ["Show Canvas", "Show Assistant", "Show Code Review"])
        #expect(selected(c) == [false, false, false])
        wc.toggleCanvas(nil)
        #expect(selected(c) == [true, false, false] && wc.activeEditorMode == .canvas)
        // Turning on the Assistant while the canvas is shown hides the canvas.
        wc.toggleAssistant(nil)
        #expect(wc.canvas == nil && wc.editorArea.tab.assistant != nil)
        #expect(selected(c) == [false, true, false])
        // Code Review while the Assistant is shown closes the assistant pane.
        #expect(wc.toggleComparison(nil))
        #expect(wc.editorArea.tab.assistant == nil && wc.editorArea.tab.editors.count == 1)
        #expect(wc.editor.isShowingComparison || wc.editor.isShowingInlineComparison)
        #expect(selected(c) == [false, false, true] && wc.activeEditorMode == .codeReview)
        // Canvas ends Code Review.
        wc.setEditorMode(.canvas)
        #expect(!(wc.editor.isShowingComparison || wc.editor.isShowingInlineComparison) && wc.canvas != nil)
        // Clicking the selected segment leaves no mode on.
        wc.setEditorMode(.canvas)
        #expect(wc.activeEditorMode == nil && selected(c) == [false, false, false])
        // The Editor menu items mirror the same state.
        wc.setEditorMode(.assistant)
        let items = [("Canvas", #selector(WorkspaceWindowController.toggleCanvas(_:))), ("Assistant", #selector(WorkspaceWindowController.toggleAssistant(_:))),
                     ("Code Review", #selector(WorkspaceWindowController.toggleComparison(_:)))].map { NSMenuItem(title: $0.0, action: $0.1, keyEquivalent: "") }
        for i in items { _ = wc.validateMenuItem(i) }
        #expect(items.map { $0.state == .on } == selected(c))
    }

    // MARK: T5–T7 — tooltips, New Conversation, the pill's names

    @Test func toolbarCenterItems() throws {
        let dir = try package("t5")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wc = try window(dir)
        let ids = wc.toolbarDefaultItemIdentifiers(NSToolbar()).map(\.rawValue)
        #expect(ids.firstIndex(of: "newConversation")! + 1 == ids.firstIndex(of: "scheme")!)
        let conv = try #require(wc.toolbar(NSToolbar(), itemForItemIdentifier: .init("newConversation"), willBeInsertedIntoToolbar: false))
        #expect(!conv.isEnabled && conv.label == "New Conversation")
        let run = try #require(wc.toolbar(NSToolbar(), itemForItemIdentifier: .init("run"), willBeInsertedIntoToolbar: false)?.view as? NSSegmentedControl)
        #expect((0..<2).map { run.toolTip(forSegment: $0) } == ["Build and then run the current scheme", "Stop the running scheme or application"])
        let history = try #require(wc.toolbar(NSToolbar(), itemForItemIdentifier: .init("history"), willBeInsertedIntoToolbar: false)?.view as? NSSegmentedControl)
        #expect((0..<2).map { history.toolTip(forSegment: $0) } == ["Show Previous Location in History", "Show Next Location in History"])
        let pill = try #require(wc.toolbar(NSToolbar(), itemForItemIdentifier: .init("scheme"), willBeInsertedIntoToolbar: false)?.view as? NSStackView)
        let names = pill.arrangedSubviews.compactMap { $0 as? NSPopUpButton }.map { $0.accessibilityLabel() ?? "" }
        #expect(names == ["Active Scheme", "Active Run Destination"])
    }

    // MARK: E1, E2, E4 — jump bars

    @Test func jumpBarHasNoHistoryButtonsAndKeepsKeyboardMenus() throws {
        let dir = try package("e1")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wc = try window(dir)
        wc.open(path: dir.appendingPathComponent("Sources/Chrome/Model.swift").path, line: nil)
        let titles = wc.editor.jumpBarTitles
        #expect(titles.first == "Navigate to Related Items")
        #expect(!titles.contains { ["Back", "Forward", "Go Back", "Go Forward"].contains($0) })
        #expect(titles.contains("Model") && titles.contains("Chrome"))
        // No issues in the workspace: no issue controls.
        #expect(wc.editor.jumpBarIssueTitles == nil && !titles.contains("Issues"))
        // The Related Items button opens ⌃1's menu; ⌃1–⌃6 still list entries.
        wc.editor.jumpBar.relatedItemsButton?.performClick(nil)
        #expect(wc.popUpJumpBarMenu(.documentItems).items.map(\.title).contains("Model"))
        #expect(wc.popUpJumpBarMenu(.groupFiles).items.map(\.title).contains { $0.hasPrefix("Helper") })
        #expect(wc.popUpJumpBarMenu(.topLevelItems).items.count > 0)
        // History stays in the menus and the toolbar.
        wc.open(path: dir.appendingPathComponent("Sources/Chrome/Helper.swift").path, line: nil)
        wc.goBack(nil)
        #expect(wc.editor.fileURL?.lastPathComponent == "Model.swift")
    }

    @Test func jumpBarIssueControlsStepThroughIssues() throws {
        let dir = try package("e2")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wc = try window(dir)
        let model = dir.appendingPathComponent("Sources/Chrome/Model.swift").path
        let helper = dir.appendingPathComponent("Sources/Chrome/Helper.swift").path
        wc.open(path: model, line: 1)
        wc.session.packageIssues = [
            Diagnostic(severity: .warning, message: "value is never read", location: .init(file: model, line: 2)),
            Diagnostic(severity: .error, message: "missing return", location: .init(file: helper, line: 1)),
            Diagnostic(severity: .error, message: "cannot find 'x'", location: .init(file: model, line: 3)),
        ]
        let titles = wc.editor.jumpBarTitles
        #expect(Array(titles.suffix(3)) == ["Show Previous Issue", "Issues", "Show Next Issue"])
        #expect(wc.editor.jumpBarIssueTitles == ["value is never read", "cannot find 'x'"])
        func at() -> String { "\(wc.editor.fileURL!.lastPathComponent):\(wc.editor.currentLine)" }
        wc.editor.onNextIssue?()
        #expect(at() == "Model.swift:2")
        wc.editor.onNextIssue?()
        #expect(at() == "Model.swift:3")
        // Then the next file's issues.
        wc.editor.onNextIssue?()
        #expect(at() == "Helper.swift:1")
        #expect(wc.editor.jumpBarIssueTitles == ["missing return"])
        // Wraps to the first file.
        wc.jumpToNextIssue(nil)
        #expect(at() == "Model.swift:2")
        wc.editor.onPreviousIssue?()
        #expect(at() == "Helper.swift:1")
        // Picking from the Issues menu goes to the line.
        wc.open(path: model, line: 1)
        wc.editor.onPickIssue?(3)
        #expect(at() == "Model.swift:3")
        wc.session.packageIssues = []
        #expect(wc.editor.jumpBarIssueTitles == nil)
    }

    @Test func assistantJumpBarStartsWithACloseButton() throws {
        let dir = try package("e4")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wc = try window(dir)
        wc.open(path: dir.appendingPathComponent("Sources/Chrome/Model.swift").path, line: nil)
        wc.toggleAssistant(nil)
        let a = try #require(wc.editorArea.tab.assistant)
        let titles = a.jumpBarTitles
        #expect(titles.first == "Close this Editor Pane")
        #expect(titles.dropFirst().first == "Counterparts")   // the mode pop-up
        #expect(!titles.contains("Navigate to Related Items") && !titles.contains("Back"))
        #expect(!wc.editor.jumpBarTitles.contains("Close this Editor Pane") || wc.editor === a)
        a.jumpBar.closeButton?.performClick(nil)
        #expect(wc.editorArea.tab.assistant == nil && wc.activeEditorMode == nil)
    }

    // MARK: E6 — debug bar

    @Test func debugBarOrderAndBranchMenu() async throws {
        let dir = try package("e6", git: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        Self.git(dir, ["branch", "feature"])
        let wc = try window(dir)
        await wc.sourceControl.idle()   // the branch is read in the background
        let d = wc.debugArea
        let bar = try #require(d.debugBarStack)
        let views = bar.arrangedSubviews
        // Left: the breakpoints toggle; right: position, branch, debug-area toggle.
        #expect((views.first as? NSButton)?.toolTip == "Activate or deactivate breakpoints")
        #expect(views.last === d.debugAreaToggle)
        let pos = try #require(views.firstIndex(of: d.positionLabel)), branch = try #require(views.firstIndex(of: d.branchView))
        #expect(pos < branch && branch == views.count - 2)
        #expect(d.branchView.toolTip == "Shows a list of available branches" && d.branchButton.toolTip == "Shows a list of available branches")
        let current = Self.git(dir, ["branch", "--show-current"]).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!d.branchView.isHidden && d.branchLabel.stringValue == current)
        let menu = d.branchMenu()
        #expect(Set(menu.items.map(\.title)) == [current, "feature"])
        #expect(menu.items.first { $0.state == .on }?.title == current)
        // Choosing a branch switches with git switch.
        let feature = try #require(menu.items.first { $0.title == "feature" })
        d.branchChosen(feature)
        await wc.sourceControl.idle()
        #expect(Self.git(dir, ["branch", "--show-current"]).trimmingCharacters(in: .whitespacesAndNewlines) == "feature")
        #expect(d.branchLabel.stringValue == "feature")
        // Refused while the working tree has conflicts.
        let repo = try #require(GitRepository(containing: dir))
        Self.git(dir, ["switch", "-q", current])
        let file = dir.appendingPathComponent("Sources/Chrome/Model.swift")
        try "public struct Model { var a = 1 }\n".write(to: file, atomically: true, encoding: .utf8)
        Self.git(dir, ["-c", "user.name=A", "-c", "user.email=a@x", "commit", "-qam", "main side"])
        Self.git(dir, ["switch", "-q", "feature"])
        try "public struct Model { var a = 2 }\n".write(to: file, atomically: true, encoding: .utf8)
        Self.git(dir, ["-c", "user.name=A", "-c", "user.email=a@x", "commit", "-qam", "feature side"])
        Self.git(dir, ["-c", "user.name=A", "-c", "user.email=a@x", "merge", "-q", current])
        #expect((try? repo.status())?.values.contains(.conflicted) == true)
        #expect(await !wc.switchBranch(current))
        #expect(Self.git(dir, ["branch", "--show-current"]).trimmingCharacters(in: .whitespacesAndNewlines) == "feature")
    }

    // MARK: N6, N7, N8, N12 — bottom bars, headers, empty states, selector tooltips

    @Test func bottomBarsHeadersAndEmptyStatesMatchTheTable() {
        _ = NSApplication.shared
        let nav = NavigatorAreaController()
        _ = nav.view
        #expect(nav.selectorToolTips == ["Show the Project navigator", "Show the Source Control navigator", "Show the Bookmark navigator",
                                         "Show the Find navigator", "Show the Issue navigator", "Show the Test navigator",
                                         "Show the Debug Navigator", "Show the Breakpoints Navigator", "Show the Report navigator"])
        struct Row { var left: String??; var toggles: [String]; var tips: [String]; var on: [Bool]; var empty: [String] }
        let expected: [Row] = [
            Row(left: .some(nil), toggles: ["Recent files", "Files with source-control status"],
                tips: ["Show only recent files", "Show only files with source-control status"], on: [false, false], empty: []),
            Row(left: .some(nil), toggles: [], tips: [], on: [], empty: ["No Repository"]),
            Row(left: .some("More"), toggles: ["Incomplete Items"], tips: ["Show only incomplete items"], on: [false],
                empty: ["No Bookmarks", "Click the '…' button to add bookmarks"]),
            Row(left: nil, toggles: [], tips: [], on: [], empty: []),
            Row(left: nil, toggles: ["Show only latest issues", "Only errors"],
                tips: ["Show only issues from open documents and recently built sources", "Show only errors"], on: [false, false], empty: ["No Issues"]),
            Row(left: .some("Add a new test target or class"), toggles: ["Show Only Included Tests", "Recent Tests"],
                tips: ["Show Only Included Tests", "Show only recent tests and open documents"], on: [false, false],
                empty: ["No Tests", "Click the \u{2295} button to add test targets"]),
            Row(left: nil, toggles: ["Show compressed stack frames", "Show only interesting content", "Show only running blocks"],
                tips: ["Show only stack frames with debug symbols and between libraries", "Show only crashed threads and threads with debug symbols",
                       "Show only running blocks when in Queues view"], on: [true, false, true], empty: ["No Debug Session"]),
            Row(left: .some("Create a breakpoint"), toggles: ["Modified breakpoints", "Enabled breakpoints"],
                tips: ["Show only modified breakpoints", "Show only enabled breakpoints"], on: [false, false], empty: ["No Breakpoints"]),
            Row(left: .some(nil), toggles: ["Recent reports filter"], tips: ["Show only recent reports"], on: [false], empty: ["No Logs"]),
        ]
        for (i, row) in expected.enumerated() {
            nav.select(i)
            let shown = nav.toggleButtons.filter { !$0.isHidden }
            #expect(shown.map { $0.accessibilityLabel() ?? "" } == row.toggles, "navigator \(i)")
            #expect(shown.map { $0.toolTip ?? "" } == row.tips, "navigator \(i)")
            #expect(shown.map { $0.state == .on } == row.on, "navigator \(i)")
            #expect(nav.leftButtonToolTip == row.left, "navigator \(i)")
            #expect(nav.emptyStateLines == row.empty, "navigator \(i)")
            #expect(nav.filter.placeholderString == "Filter")
        }
        // Headers.
        nav.select(8)
        #expect((0..<2).map { nav.reportScope.toolTip(forSegment: $0) } == ["Show Local Reports", "Show Cloud Reports"] && !nav.reportScope.isHidden)
        nav.select(5)
        #expect(!nav.testHeader.isHidden && nav.testPlanPopUp.titleOfSelectedItem == nav.testPlanName)
        #expect((0..<2).map { nav.testModeControl.toolTip(forSegment: $0) } == ["Group by Test Hierarchy", "Group by Tags"])
        #expect(nav.testModeControl.selectedSegment == 0 && nav.testModeControl.accessibilityLabel() == "Mode")
        nav.select(3)
        #expect(nav.findCaseToggle.toolTip == "Case Sensitive" && nav.testHeader.isHidden)
        // Filter options list the toggles.
        nav.select(7)
        #expect(nav.filterOptionTitles == ["Show Only Modified Breakpoints", "Show Only Enabled Breakpoints"])
        nav.select(6)
        #expect(nav.filterOptionTitles.prefix(3) == ["Show Compressed Stack Frames", "Show Only Interesting Content", "Show Only Running Blocks"])
    }

    @Test func togglesFilterTheirNavigators() throws {
        let dir = try package("n6")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wc = try window(dir)
        let model = dir.appendingPathComponent("Sources/Chrome/Model.swift").path
        let helper = dir.appendingPathComponent("Sources/Chrome/Helper.swift").path
        let nav = wc.navigator

        // Bookmarks: done state from the context menu, Incomplete Items.
        wc.open(path: model, line: 2)
        let line = try #require(wc.addLineBookmark())
        wc.open(path: helper, line: nil)
        _ = wc.addFileBookmark()
        nav.select(2)
        let row = try #require(nav.rows(2).flatMap(\.children).first { $0.line == 2 })
        let rowBookmark = try #require(row.bookmark)
        let item = try #require(nav.bookmarkMenuItems(rowBookmark).first)
        #expect(item.title == "Mark as Done")
        _ = item.target?.perform(item.action, with: item)
        #expect(wc.bookmarks.all.first { $0.line == line.line }?.done == true)
        let savedURL = try #require(wc.bookmarks.fileURL)
        let saved = try String(contentsOf: savedURL, encoding: .utf8)
        #expect(saved.contains("\"done\" : true") && saved.components(separatedBy: "\"done\"").count == 2)
        nav.setToggle(2, 0, true)
        #expect(nav.rows(2).flatMap(\.children).allSatisfy { $0.bookmark?.done != true })
        #expect(nav.rows(2).map(\.title) == ["Helper.swift"])
        nav.setToggle(2, 0, false)
        #expect(nav.rows(2).count == 2)

        // Breakpoints: Modified keeps customized ones; Enabled keeps enabled ones.
        wc.session.breakpoints.click(file: model, line: 2)
        wc.session.breakpoints.click(file: helper, line: 2)
        wc.session.breakpoints.edit(file: helper, line: 2) { $0.condition = "x > 1" }
        wc.session.breakpoints.edit(file: model, line: 2) { $0.isEnabled = false }
        nav.select(7)
        nav.setToggle(7, 0, true)
        #expect(nav.breakpointGroups.map(\.title) == ["Helper.swift"])
        nav.setToggle(7, 0, false)
        nav.sourceControlToggle.performClick(nil)   // Enabled breakpoints
        #expect(nav.breakpointFilter.enabledOnly && nav.breakpointGroups.map(\.title) == ["Helper.swift"])
        nav.setToggle(7, 1, false)
        #expect(nav.breakpointGroups.count == 2)

        // Issues: groups carry their file's icon.
        wc.session.packageIssues = [Diagnostic(severity: .error, message: "bad", location: .init(file: model, line: 1))]
        let group = try #require(nav.rows(4).first?.children.first)
        #expect(group.symbol == "chevron.left.forwardslash.chevron.right")
    }

    @Test func debugNavigatorToggles() {
        _ = NSApplication.shared
        let nav = NavigatorAreaController()
        _ = nav.view
        func f(_ id: Int, _ file: String?) -> StackFrame {
            var j: [String: JSON] = ["id": .number(Double(id)), "name": .string("f\(id)"), "line": 1]
            if let file { j["source"] = ["path": .string(file)] }
            return StackFrame(.object(j))
        }
        let frames = [f(0, "/u/a.swift"), f(1, nil), f(2, nil), f(3, "/usr/lib/x.c")]
        let threads = [DebugThread(id: 1, name: "Thread 1"), DebugThread(id: 2, name: "Thread 2")]
        nav.select(6)
        nav.setDebugState(threads: threads, stoppedThread: 1, frames: frames)
        // Compressed (default): the system run folds behind a separator.
        #expect(nav.rows(6).first?.children.count == 3 && nav.rows(6).first?.children[1].isSeparator == true)
        nav.setToggle(6, 0, false)
        #expect(nav.rows(6).first?.children.map(\.title) == ["0 f0", "1 f1", "2 f2", "3 f3"])
        // Interesting content: only the stopped thread.
        #expect(nav.rows(6).count == 2)
        nav.setToggle(6, 1, true)
        #expect(nav.rows(6).count == 1 && nav.rows(6).first?.title.hasPrefix("Thread 1") == true)
        #expect(nav.recentToggle.state == .off && nav.sourceControlToggle.state == .on && nav.thirdToggle.state == .on)
    }

    @Test func testNavigatorModesToggleAndDiamonds() throws {
        let dir = try package("n14")
        defer { try? FileManager.default.removeItem(at: dir) }
        let tests = dir.appendingPathComponent("Tests/ChromeTests")
        try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
        let file = tests.appendingPathComponent("ChromeTests.swift")
        try """
        import Testing

        extension Tag {
            @Tag static var fast: Self
        }

        @Suite(.tags(.model))
        struct ModelTests {
            @Test(.tags(.fast)) func value() {}
            @Test func other() {}
        }

        @Test func loose() {}
        """.write(to: file, atomically: true, encoding: .utf8)
        let found = TestDiscovery.tests(in: try String(contentsOf: file, encoding: .utf8), file: file.path)
        #expect(found.map(\.name) == ["value", "other", "loose"])
        #expect(TestTags.tags(of: found[0], text: try String(contentsOf: file, encoding: .utf8)) == ["model", "fast"])
        _ = NSApplication.shared
        let nav = NavigatorAreaController()
        _ = nav.view
        nav.testPlanName = "Chrome (Autocreated)"
        nav.select(5)
        nav.setTests(found, results: [found[0]: .passed, found[1]: .failed])
        // Hierarchy: diamonds at the right end, not in the icon slot.
        let plan = try #require(nav.rows(5).first)
        #expect(plan.title == "Chrome (Autocreated)" && plan.trailingSymbol == "xmark.diamond.fill")
        let leaves = plan.children.flatMap(\.children).flatMap { $0.children.isEmpty ? [$0] : $0.children }
        #expect(leaves.map(\.title) == ["value()", "other()", "loose()"])
        #expect(leaves.map { $0.trailingSymbol ?? "" } == ["checkmark.diamond.fill", "xmark.diamond.fill", "diamond"])
        #expect(!leaves.contains { $0.symbol.contains("diamond") })
        // Group by Tags: one group per tag, Untagged Tests last.
        nav.testModeControl.selectedSegment = 1
        nav.testModeControl.sendAction(nav.testModeControl.action, to: nav.testModeControl.target)
        #expect(nav.groupTestsByTags)
        let groups = try #require(nav.rows(5).first?.children)
        #expect(groups.map(\.title) == ["fast", "model", "Untagged Tests"])
        #expect(groups[1].children.map(\.title) == ["value()", "other()"] && groups[2].children.map(\.title) == ["loose()"])
        // Recent Tests: tests of open files and of the last run.
        nav.groupTestsByTags = false
        nav.setToggle(5, 1, true)
        #expect(nav.rows(5).first?.detail == "2 Tests, 1 Failing")
        nav.recentFiles = [file.path]
        nav.setToggle(5, 1, false)
        nav.setToggle(5, 1, true)
        #expect(nav.rows(5).first?.detail == "3 Tests, 1 Failing")
        // Show Only Included Tests hides what the plan skips.
        nav.setToggle(5, 1, false)
        nav.skippedTests = ["loose"]
        nav.setToggle(5, 0, true)
        #expect(nav.rows(5).first?.detail == "2 Tests, 1 Failing")
        // Nothing left: the two-line empty state.
        nav.skippedTests = ["ModelTests/value", "ModelTests/other", "loose"]
        #expect(nav.emptyStateLines == ["No Tests", "Click the \u{2295} button to add test targets"])
    }

    // MARK: N13 — Find navigator scope and recent searches

    @Test func findScopeWordAndRecentSearches() {
        _ = NSApplication.shared
        let nav = NavigatorAreaController()
        _ = nav.view
        nav.isWorkspace = true
        nav.rebuildScopeMenu()
        #expect(nav.findScope.title == "In Workspace" && nav.findScope.menu?.items.first?.title == "Workspace")
        nav.isWorkspace = false
        nav.rebuildScopeMenu()
        #expect(nav.findScope.title == "In Project")
        nav.noteRecentSearch("alpha")
        nav.noteRecentSearch("beta")
        nav.noteRecentSearch("alpha")
        #expect(nav.recentSearches == ["alpha", "beta"])
        #expect(nav.findField.searchMenuTemplate != nil)
    }

    // MARK: I1–I5 — inspectors

    @Test func inspectorTabsAndNothingSelected() async throws {
        let dir = try package("i1")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wc = try window(dir)
        let i = wc.inspector
        _ = i.view
        #expect(Array(i.tabToolTips.prefix(3)) == ["Show the File inspector", "Show the History inspector", "Show Quick Help inspector"])
        i.select(0)
        #expect(i.centeredText == "Not Applicable")
        // Outside git: no Working Copy, no history.
        let model = dir.appendingPathComponent("Sources/Chrome/Model.swift")
        wc.open(path: model.path, line: nil)
        i.select(0)
        #expect(i.centeredText.isEmpty && !i.rowValues.map(\.0).contains("Working Copy"))
        i.select(1)
        await i.historyIdle()   // read in the background
        #expect(i.centeredText == "No History")
        // Quick Help with the caret on no symbol.
        i.showQuickHelp(nil)
        i.select(2)
        #expect(i.sectionTitles == ["Quick Help"] && (i.fileControls["Search Documentation"] as? NSButton)?.title == "Search Documentation")
    }

    @Test func fileInspectorSectionsInAWorkingCopy() throws {
        let dir = try package("i3", git: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wc = try window(dir)
        let model = dir.appendingPathComponent("Sources/Chrome/Model.swift")
        wc.open(path: model.path, line: nil)
        let i = wc.inspector
        i.select(0)
        #expect(i.sectionTitles == ["Identity and Type", "On Demand Resource Tags", "Target Membership", "Text Settings"])
        let rows = Dictionary(i.rowValues, uniquingKeysWith: { a, _ in a })
        let root = Self.git(dir, ["rev-parse", "--show-toplevel"]).trimmingCharacters(in: .whitespacesAndNewlines)
        func real(_ p: String?) -> String? { p.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } }
        #expect(real(rows["Working Copy"]) == real(root) && rows["Relative Path"] == "Sources/Chrome/Model.swift", "\(rows) \(root)")
        #expect(i.rowValues.map(\.0).firstIndex(of: "Full Path")! < i.rowValues.map(\.0).firstIndex(of: "Working Copy")!)
        let tags = try #require(i.fileControls["On Demand Resource Tags"] as? NSTokenField)
        #expect(!tags.isEnabled && tags.placeholderString == "Only resources are taggable")
        #expect(rows["Target"] == "Chrome")
        #expect((i.fileControls["Add Target"] as? NSButton)?.toolTip == "Choose which targets include this file")
        #expect((i.fileControls["Remove Target"] as? NSButton)?.toolTip == "Remove this file from selected targets")
        let pencil = try #require(i.fileControls["Edit Target Membership"] as? NSButton)
        #expect(pencil.toolTip == "Edit target membership options" && !pencil.isEnabled)
    }

    @Test func historyInspectorShowsTheFilesCommits() async throws {
        let dir = try package("i4", git: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = dir.appendingPathComponent("Sources/Chrome/Model.swift")
        try "public struct Model {\n    public var value = 2\n}\n".write(to: model, atomically: true, encoding: .utf8)
        Self.git(dir, ["-c", "user.name=Grace Hopper", "-c", "user.email=g@example.com", "commit", "-qam", "Bump the value"])
        try "public func helper() -> Int { 2 }\n".write(to: dir.appendingPathComponent("Sources/Chrome/Helper.swift"), atomically: true, encoding: .utf8)
        Self.git(dir, ["-c", "user.name=Other", "-c", "user.email=o@example.com", "commit", "-qam", "Helper only"])
        let wc = try window(dir)
        wc.open(path: model.path, line: nil)
        let i = wc.inspector
        i.select(1)
        await i.historyIdle()   // the history is read in the background
        #expect(i.centeredText.isEmpty)
        #expect(i.historyRows.map(\.author) == ["Grace Hopper", "Ada Tester"])
        #expect(i.historyRows.map(\.subject) == ["Bump the value", "Initial import"])
        #expect(i.historyRows.allSatisfy { $0.date == "Today" })
        // Selecting a row shows that commit in Code Review against the working copy.
        i.selectHistoryRow(1)
        #expect(wc.activeEditorMode == .codeReview)
        if case .commit(let hash, _) = wc.editor.review.rightSource { #expect(hash == i.historyCommits[1].hash) } else { Issue.record("not a commit source") }
    }

    @Test func targetMembershipEditsTheProject() throws {
        let dir = try tempDir("i3p")
        defer { try? FileManager.default.removeItem(at: dir) }
        var o = ProjectOptions()
        o.productName = "Tour"
        o.organizationIdentifier = "org.ycode.tests"
        o.testing = .xctest
        o.setStorage(.none)
        let url = try ProjectTemplate.app.create(platform: "iOS", options: o, in: dir)
        let wc = try window(url)
        let view = dir.appendingPathComponent("Tour/Tour/ContentView.swift")
        #expect(FileManager.default.fileExists(atPath: view.path))
        wc.open(path: view.path, line: nil)
        let i = wc.inspector
        i.select(0)
        let info = try #require(i.shownInfo)
        #expect(info.memberships.map(\.name) == ["Tour", "TourTests", "TourUITests"])
        #expect(info.memberships.map(\.isMember) == [true, false, false])
        #expect(i.addMembershipMenu().items.map(\.title) == ["TourTests", "TourUITests"])
        // "+": add to TourTests (its Sources phase), saved to disk.
        let tests = info.memberships[1].targetID
        let add = try #require(i.addMembershipMenu().items.first)
        _ = add.target?.perform(add.action, with: add)
        var saved = try PBXProj(contentsOf: url.appendingPathComponent("project.pbxproj"))
        let projDir = saved.projectDirectory(xcodeprojURL: url)
        #expect(saved.targetMemberships(ofFile: view.path, projectDirectory: projDir).map(\.isMember) == [true, true, false])
        #expect(i.shownInfo?.memberships.map(\.isMember) == [true, true, false])
        // "−": remove the selected targets.
        i.toggleMembershipSelection(tests)
        i.toggleMembershipSelection(info.memberships[0].targetID)
        #expect((i.fileControls["Remove Target"] as? NSButton)?.isEnabled == true)
        i.removeMembershipClicked()
        saved = try PBXProj(contentsOf: url.appendingPathComponent("project.pbxproj"))
        #expect(saved.targetMemberships(ofFile: view.path, projectDirectory: projDir).map(\.isMember) == [false, false, false])
        #expect(wc.setTargetMembership(of: view, target: info.memberships[0].targetID, member: true))
    }

    @Test func synchronizedFolderMembershipWritesExceptionSets() throws {
        let text = """
        // !$*UTF8*$!
        {
        \tarchiveVersion = 1;
        \tclasses = {
        \t};
        \tobjectVersion = 77;
        \tobjects = {
        \t\tAA0000000000000000000001 = {isa = PBXProject; mainGroup = AA0000000000000000000002; targets = (AA0000000000000000000004, AA0000000000000000000005, ); };
        \t\tAA0000000000000000000002 = {isa = PBXGroup; children = (AA0000000000000000000003, ); sourceTree = "<group>"; };
        \t\tAA0000000000000000000003 = {isa = PBXFileSystemSynchronizedRootGroup; path = App; sourceTree = "<group>"; };
        \t\tAA0000000000000000000004 = {isa = PBXNativeTarget; buildPhases = (); fileSystemSynchronizedGroups = (AA0000000000000000000003, ); name = App; };
        \t\tAA0000000000000000000005 = {isa = PBXNativeTarget; buildPhases = (); name = Other; };
        \t};
        \trootObject = AA0000000000000000000001;
        }
        """
        var p = try PBXProj(parsing: text)
        let dir = URL(fileURLWithPath: "/tmp/proj")
        let file = "/tmp/proj/App/Views/Main.swift"
        let app = "AA0000000000000000000004", other = "AA0000000000000000000005", group = "AA0000000000000000000003"
        #expect(p.targetMemberships(ofFile: file, projectDirectory: dir).map(\.isMember) == [true, false])
        #expect(p.targetMemberships(ofFile: file, projectDirectory: dir).map(\.isEditable) == [true, false])
        // Removing writes an exception set for the target.
        let r1 = p.setMembership(ofFile: file, target: app, member: false, projectDirectory: dir)
        #expect(r1)
        let set = try #require(p[group]?.references("exceptions").first.flatMap { p[$0] })
        #expect(set.isa == "PBXFileSystemSynchronizedBuildFileExceptionSet" && set.string("target") == app)
        #expect(set.references("membershipExceptions") == ["Views/Main.swift"])
        #expect(p.targetMemberships(ofFile: file, projectDirectory: dir).map(\.isMember) == [false, false])
        // A target without the folder cannot take it from here.
        let r2 = p.setMembership(ofFile: file, target: other, member: true, projectDirectory: dir)
        #expect(!r2)
        // Adding back empties the set, which goes away.
        let r3 = p.setMembership(ofFile: file, target: app, member: true, projectDirectory: dir)
        #expect(r3)
        #expect(p[group]?.references("exceptions").isEmpty == true && p.objects(isa: "PBXFileSystemSynchronizedBuildFileExceptionSet").isEmpty)
        #expect(p.targetMemberships(ofFile: file, projectDirectory: dir).map(\.isMember) == [true, false])
    }

    // MARK: D1, D2 — debug area bars and height

    @Test func debugAreaBarsAndPrintDescription() {
        _ = NSApplication.shared
        let d = DebugAreaController()
        _ = d.view
        #expect(d.variablesBarTitles == ["Variables scope", "Quick Look", "Print Description", "Filter"])
        #expect(d.consoleBarTitles == ["Quick Look", "Metadata Options", "Filter options", "Filter", "Clear Console",
                                       "Show or hide the variables view", "Show or hide the console"])
        #expect(d.printDescriptionButton?.image?.accessibilityDescription == "Print Description")
        var printed: [String] = []
        d.onVariableAction = { action, v in if action == .printDescription { printed.append(v.name) } }
        d.setVariables([Variable(name: "count", value: "3", type: "Int"), Variable(name: "label", value: "\"a\"", type: "String")])
        #expect(d.selectVariable(named: "label"))
        d.printDescriptionButton?.performClick(nil)
        #expect(printed == ["label"])
    }

    @Test func debugAreaOpensAtTheRememberedHeight() throws {
        let dir = try package("d2")
        defer { try? FileManager.default.removeItem(at: dir) }
        let stateURL = dir.appendingPathComponent("ui-state.json")
        _ = NSApplication.shared
        func make() throws -> WorkspaceWindowController {
            let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: dir)), loadDestinations: false,
                                               startLanguageService: false, openFirstFile: false, userStateURL: stateURL)
            wc.applyDefaultLayout()
            return wc
        }
        let wc = try make()
        #expect(wc.debugAreaHeightShown == nil)
        // The first time: 135 points.
        wc.showDebugArea(true)
        #expect(abs((wc.debugAreaHeightShown ?? 0) - 135) <= 1)
        // Resized, hidden, shown again: the remembered height.
        let split = wc.centerSplit.splitView
        split.setPosition(split.bounds.height - 220 - split.dividerThickness, ofDividerAt: 0)
        split.layoutSubtreeIfNeeded()
        #expect(abs((wc.debugAreaHeightShown ?? 0) - 220) <= 1)
        wc.toggleDebugArea(nil)
        #expect(wc.debugAreaHeightShown == nil)
        wc.toggleDebugArea(nil)
        #expect(abs((wc.debugAreaHeightShown ?? 0) - 220) <= 1)
        // A behavior that opens it uses the same height; so does a new window.
        wc.showDebugArea(false)
        let again = try make()
        #expect(abs(again.debugAreaOpeningHeight - 220) <= 1)
        again.showDebugArea(true)
        #expect(abs((again.debugAreaHeightShown ?? 0) - 220) <= 1)
    }
}
