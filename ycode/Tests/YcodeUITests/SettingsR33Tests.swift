import AppKit
import Foundation
import Testing
import YcodeBuild
import YcodeProject
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// R33 (`specs/ide/reference-ui-5.md` §9): the Settings panes, their rows
/// and defaults, and that each setting takes effect; plus destination
/// selection by identifier (Ycode's remote simulator).
@MainActor
@Suite(.serialized) struct SettingsR33Tests {
    /// A private Preferences installed as `shared` for `body`.
    func withPrefs(_ tag: String, _ body: (Preferences, URL) throws -> Void) throws {
        let t = TestDefaults("r33-\(tag)")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-r33-\(tag)-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = Preferences(defaults: t.defaults, themesDirectory: dir.appendingPathComponent("Themes"))
        let old = Preferences.shared
        Preferences.shared = p
        defer {
            Preferences.shared = old
            NotificationCenter.default.post(name: Preferences.didChange, object: nil)
            t.remove()
            try? FileManager.default.removeItem(at: dir)
        }
        try body(p, dir.resolvingSymlinksInPath())
    }

    func iosApp(in dir: URL, name: String = "Tour") throws -> URL {
        var o = ProjectOptions()
        o.productName = name
        o.organizationIdentifier = "org.ycode.tests"
        o.testing = .none
        o.setStorage(.none)
        return try ProjectTemplate.app.create(platform: "iOS", options: o, in: dir)
    }

    func sim(_ name: String, _ version: String) -> Destination {
        Destination(name: name, specifier: "platform=iOS Simulator,id=\(name)-\(version)", platform: "iOS", kind: .simulator,
                    osVersion: version, identifier: "\(name)-\(version)")
    }

    // MARK: Destination selection by identifier

    @Test func choosingTheRemoteSimulatorSelectsItAndIsRemembered() throws {
        try withPrefs("dest") { p, dir in
            var remote = RemoteSimulatorSettings()
            remote.destination = "tester@sim-host"
            remote.dataDirectory = "/data/ycode"
            remote.runtimeRoot = "/data/ycode/runtime"
            remote.simdPath = "/data/ycode/bin/ycode-simd"
            remote.save(p.defaults)
            let proj = try iosApp(in: dir)
            let stateURL = dir.appendingPathComponent("state.json")
            _ = NSApplication.shared
            @MainActor func window() throws -> WorkspaceWindowController {
                WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: proj)), loadDestinations: false,
                                          startLanguageService: false, openFirstFile: false, userStateURL: stateURL)
            }
            let groups = DestinationCatalog.groups(devices: [], simulators: [sim("iPhone 17", "26.4")])
            let wc = try window()
            wc.setDestinationGroups(groups)
            // The two rows share a specifier but not a key.
            #expect(RemoteSimulator.destination.specifier == "generic/platform=iOS Simulator")
            let menu = try #require(wc.destinationPopUp.menu)
            // The primary row (the runtime's default device type) keeps the old identifier.
            let primary = RemoteSimulator(settings: remote).destination
            #expect(primary.name == "iPhone Duo (Ycode)")
            let remoteIndex = try #require(menu.items.firstIndex { $0.title == primary.name })
            let anySimIndex = try #require(menu.items.firstIndex { $0.title.hasPrefix("Any iOS Simulator Device") })
            #expect(menu.items[remoteIndex].representedObject as? String == "ycode-remote-simulator")
            #expect(menu.items[anySimIndex].representedObject as? String == "generic/platform=iOS Simulator")

            wc.destinationPopUp.selectItem(at: remoteIndex)
            wc.destinationChosen(wc.destinationPopUp)
            #expect(wc.session.destination == primary)
            #expect(wc.destinationPopUp.titleOfSelectedItem == primary.name)
            #expect(WorkspaceUserState.load(from: stateURL).destinations[wc.session.scheme ?? ""] == "ycode-remote-simulator")
            // Reopening restores the remote simulator, not the generic one.
            let again = try window()
            again.setDestinationGroups(groups)
            #expect(again.session.destination == primary)

            // The generic row still selects the generic destination.
            let i = try #require(again.destinationPopUp.menu?.items.firstIndex { $0.title.hasPrefix("Any iOS Simulator Device") })
            again.destinationPopUp.selectItem(at: i)
            again.destinationChosen(again.destinationPopUp)
            #expect(again.session.destination?.name == "Any iOS Simulator Device" && again.session.destination?.identifier == nil)
            #expect(WorkspaceUserState.load(from: stateURL).destinations[again.session.scheme ?? ""] == "generic/platform=iOS Simulator")
            let third = try window()
            third.setDestinationGroups(groups)
            #expect(third.session.destination?.name == "Any iOS Simulator Device")
        }
    }

    // MARK: Pane structure (S1–S6)

    @Test func generalPaneRowsAndDefaults() throws {
        let t = TestDefaults("r33-general")
        defer { t.remove() }
        let p = Preferences(defaults: t.defaults)
        #expect(p.restoreWindows == .system && p.navigatorSize == .system)
        #expect(p.bookmarkNavigatorDetail == 3 && p.findNavigatorDetail == 3 && p.issueNavigatorDetail == 3)
        #expect(!p.independentSidebarWidths && !p.autoUnlockFiles && p.fileExtensions == .hide)
        #expect(p.issuePresentation == .inline && p.showLiveIssues && p.stopBuildOnFirstError)
        #expect(p.testParallelizationMac == .automatic && p.testParallelizationSimulator == .automatic && p.reportHistoryLimit == 20)
        let pane = GeneralSettingsPane(prefs: p)
        _ = pane.view
        #expect(pane.rowTitles == [
            "# Starting Points", "Restore open projects and workspaces",
            "# Navigation and Files", "Navigator size", "Bookmark navigator detail", "Find navigator detail", "Issue navigator detail",
            "Window tabs have independent sidebar widths", "Automatically unlock files", "File extensions",
            "# Issues", "Issue presentation", "Predictive Issues", "Stop build on first error",
            "# Test Parallelization", "Testing on Mac", "Testing on Simulator",
            "# Report Navigator", "Local report history",
            "# Settings Import & Export", "Export…",
            "# Reset Ycode", "Reset Settings", "\u{201C}Don\u{2019}t ask me\u{201D} warnings",
        ])
        func items(_ row: String) -> [String] { pane.control(NSPopUpButton.self, inRow: row)?.itemTitles ?? [] }
        #expect(items("Restore open projects and workspaces") == ["Use System Setting", "Always", "Never"])
        #expect(items("Navigator size") == ["Use System Setting", "Small", "Medium", "Large"])
        #expect(items("Find navigator detail") == ["Up to 1 Line", "Up to 2 Lines", "Up to 3 Lines", "Up to 4 Lines", "Up to 5 Lines"])
        #expect(pane.control(NSPopUpButton.self, inRow: "Issue navigator detail")?.titleOfSelectedItem == "Up to 3 Lines")
        #expect(items("File extensions") == ["Hide All", "Show All"])
        #expect(pane.control(NSPopUpButton.self, inRow: "File extensions")?.titleOfSelectedItem == "Hide All")
        #expect(items("Issue presentation") == ["Show Inline", "Show Minimized"])
        #expect(items("Testing on Simulator") == ["Automatic", "Off"])
        #expect(items("Local report history") == ["Up to 10 Reports", "Up to 20 Reports", "Up to 50 Reports", "Up to 100 Reports"])
        #expect(pane.control(NSPopUpButton.self, inRow: "Local report history")?.titleOfSelectedItem == "Up to 20 Reports")
        // The controls write the settings.
        pane.choose("Show Minimized", inRow: "Issue presentation")
        pane.choose("Up to 5 Lines", inRow: "Bookmark navigator detail")
        pane.choose("Up to 50 Reports", inRow: "Local report history")
        pane.toggle("Stop build on first error")
        #expect(p.issuePresentation == .minimized && p.bookmarkNavigatorDetail == 5 && p.reportHistoryLimit == 50 && !p.stopBuildOnFirstError)
        // Reset asks first.
        pane.resetClicked()
        #expect(pane.lastConfirmation == GeneralSettingsPane.resetSettingsMessage)
        _ = try WindowSnapshotTests().render(pane.view, to: "settings-general.png")
    }

    @Test func navigationPaneRowsAndDefaults() throws {
        let t = TestDefaults("r33-navigation")
        defer { t.remove() }
        let p = Preferences(defaults: t.defaults)
        #expect(p.newEditorTabsOpenWith == .startPage && p.newEditorPanesOpenWith == .sameDocument && p.pinEditorTabs == .manually)
        #expect(p.optionClickOnCode == .quickHelp && p.commandClickOnCode == .definition && p.commandControlClickOnCode == .definition)
        #expect(p.navigationDestination == .focusedPane && p.navigationWithOption == .newUnpinnedTab)
        #expect(p.navigationWithOptionShift == .nextPane && p.navigationWithDoubleClick == .sameAsClick)
        #expect(p.useWindowTabsInFullScreen && p.animateOpenQuickly)
        let pane = NavigationSettingsPane(prefs: p)
        _ = pane.view
        #expect(pane.rowTitles == [
            "New Editor Tabs Open With", "New Editor Panes Open With", "Pin Editor Tabs",
            "# Click on Code", "With Option", "With Command", "With Command & Control",
            "# Navigation", "Destination", "With Option", "With Option & Shift", "With Double-click",
            "Use Window Tabs In Full Screen", "Animate Open Quickly With Multiple Editor Panes",
        ])
        #expect(!pane.rowTitles.contains("Activation") && !pane.rowTitles.contains("Navigation Style"))
        #expect(pane.control(NSPopUpButton.self, inRow: "New Editor Tabs Open With")?.titleOfSelectedItem == "Start Page")
        #expect(pane.control(NSPopUpButton.self, inRow: "New Editor Panes Open With")?.titleOfSelectedItem == "Same Document")
        #expect(pane.control(NSPopUpButton.self, inRow: "Pin Editor Tabs")?.itemTitles == ["Manually", "Automatically"])
        #expect(pane.control(NSPopUpButton.self, inRow: "With Command & Control")?.titleOfSelectedItem == "Jumps to Definition")
        #expect(pane.control(NSPopUpButton.self, inRow: "Destination")?.titleOfSelectedItem == "Focused Editor Pane")
        #expect(pane.control(NSPopUpButton.self, inRow: "With Option & Shift")?.titleOfSelectedItem == "Uses Next Editor Pane")
        #expect(pane.control(NSPopUpButton.self, inRow: "With Double-click")?.titleOfSelectedItem == "Same as Click")
        pane.choose("Automatically", inRow: "Pin Editor Tabs")
        pane.choose("Same Document", inRow: "New Editor Tabs Open With")
        #expect(p.pinEditorTabs == .automatically && p.newEditorTabsOpenWith == .sameDocument)
        // Click on Code and navigation routing by modifiers.
        #expect(p.codeClick(for: .option) == .quickHelp && p.codeClick(for: .command) == .definition)
        #expect(p.codeClick(for: [.command, .control]) == .definition && p.codeClick(for: []) == nil && p.codeClick(for: .shift) == nil)
        #expect(p.navigationTarget(modifiers: []) == .focusedPane && p.navigationTarget(modifiers: .option) == .newUnpinnedTab)
        #expect(p.navigationTarget(modifiers: [.option, .shift]) == .nextPane && p.navigationTarget(modifiers: [], clickCount: 2) == .focusedPane)
        p.navigationWithDoubleClick = .newUnpinnedTab
        #expect(p.navigationTarget(modifiers: [], clickCount: 2) == .newUnpinnedTab)
    }

    @Test func editingPagesRowsInSpecOrder() throws {
        let t = TestDefaults("r33-editing")
        defer { t.remove() }
        let p = Preferences(defaults: t.defaults)
        #expect(!p.convertExistingFilesOnSave && p.generateStringCatalogComments)
        #expect(p.showLineNumbers && !p.showFoldingRibbon && p.showCodeStructureHeaders && p.showMarkSeparators && p.showCoverageCounts)
        #expect(p.showEndifConditions && p.scopeGuides == .none && p.reformatColumn == 80 && !p.showReformattingGuide)
        #expect(!p.reformatWhenCompleting && p.dimInactiveCode && p.highlightSelectedSymbol && p.highlightDelay == 0.25)
        #expect(p.editorOverscroll == .medium && p.wrapLines && p.wrappedLineIndent == 4)
        #expect(p.fadeDocCommentDelimiters && p.fadeCommentDelimiters)
        let pane = TextEditingSettingsPane(prefs: p)
        _ = pane.view
        #expect(pane.rowTitles.contains("Convert existing files on save"))
        #expect(pane.rowTitles.suffix(2) == ["# Localized Strings", "Automatically generate string catalog comments"])
        pane.page = .display
        #expect(pane.rowTitles == [
            "Line numbers", "Code folding ribbon", "Code structure headers", "MARK separators", "Code coverage iteration counts",
            "Condition on #endif lines", "Scope guides", "Reformat code at column", "Show reformatting guide",
            "Automatically reformat when completing", "Dim inactive code", "Highlight instances of selected symbol", "Highlighting delay",
            "Editor overscroll", "# Line Wrapping", "Wrap lines to editor width", "Indent wrapped lines",
            "# Documentation Comments", "Fade delimiters", "Fade comment delimiters",
        ])
        // The minimap is Editor ▸ Minimap, not a Display row; the page guide
        // is "Show reformatting guide".
        #expect(!pane.rowTitles.contains("Minimap") && !pane.rowTitles.contains("Page guide at column"))
        #expect(pane.control(NSPopUpButton.self, inRow: "Editor overscroll")?.itemTitles == ["None", "Small", "Medium", "Large"])
        #expect(pane.control(NSPopUpButton.self, inRow: "Editor overscroll")?.titleOfSelectedItem == "Medium")
        #expect(pane.control(NSPopUpButton.self, inRow: "Scope guides")?.itemTitles == ["None"])
        pane.toggle("Show reformatting guide")
        #expect(p.showReformattingGuide && p.showPageGuide)
        _ = try WindowSnapshotTests().render(pane.view, to: "settings-editing-display.png")
    }

    @Test func appearanceAndBehaviorsPanes() throws {
        try withPrefs("appearance") { p, _ in
            let pane = ThemesSettingsPane(prefs: p)
            _ = pane.view
            #expect(pane.appearanceButtons.map(\.title) == ["System", "Light", "Dark"])
            #expect(pane.appearanceButtons.map(\.state) == [.on, .off, .off])
            pane.chooseAppearance(.dark)
            #expect(p.appearance == .dark && pane.appearanceButtons.map(\.state) == [.off, .off, .on])
            #expect(pane.preview.string.contains("struct Greeter"))
            #expect(pane.rowTitles.first == "Theme")
            #expect(Array(pane.rowTitles.dropFirst().prefix(9)) == ["Plain Text", "Comments", "Documentation Comments", "Strings", "Numbers",
                                                                    "Keywords", "Preprocessor Statements", "Attributes", "Type Names"])
            pane.chooseTheme("Ycode Dusk")
            #expect(p.themeName == "Ycode Dusk")
            pane.duplicateClicked()
            pane.segment = .fonts
            #expect(Array(pane.rowTitles.prefix(9)) == ThemesSettingsPane.tokenRows.map(\.title))
            pane.setFont(EditorTheme.FontSpec(name: "", size: 17), for: .comment)
            #expect(p.theme.tokenFonts?["comment"]?.size == 17 && Theme.font(for: .comment)?.pointSize == 17)
            #expect(Theme.font(for: .keyword) == Theme.boldFont && Theme.font(for: .string) == nil)
            // Editor ▸ Font Size (R30) applies on top of a token's own font.
            p.sourceFontSize = p.theme.fontSize + 2
            #expect(Theme.font(for: .comment)?.pointSize == 19 && Theme.font.pointSize == CGFloat(p.theme.fontSize + 2))
            p.sourceFontSize = nil
            pane.setColor(NSColor(srgbRed: 0, green: 0.5, blue: 0, alpha: 1), for: .identifier)
            #expect(p.theme.foreground == "#008000")
            _ = try WindowSnapshotTests().render(pane.view, to: "settings-appearance-fonts.png")

            let b = BehaviorsSettingsPane(prefs: p)
            _ = b.view
            #expect(Preferences.behaviorCategories.suffix(2) == ["Intelligence", "Playgrounds"])
            #expect(b.events(in: "Intelligence").isEmpty)
            #expect(BehaviorsSettingsPane.addableActions().contains("Debugger: Show Current Views"))
            #expect(BehaviorsSettingsPane.addableActions().contains("Notify with bezel or system notification"))
            #expect(p.behavior(.runPauses).actionTitles == ["Navigator: Debug", "Debugger: Show Current Views"])
            #expect(p.behavior(.buildSucceeds).actionTitles == ["Notify with bezel or system notification"])
            b.add("Debugger: Hide Debugger If No Output", to: .runStarts)
            #expect(p.behavior(.runStarts).hideDebugAreaIfNoOutput)
            b.remove("Notify with bezel or system notification", from: .buildSucceeds)
            #expect(!p.behavior(.buildSucceeds).notify)
            b.open(category: "Build")
            b.toggleCollapsed(.buildErrors)
            #expect(b.isCollapsed(.buildErrors) && !b.isCollapsed(.buildFails))
            b.toggleCollapsed(.buildErrors)
            #expect(!b.isCollapsed(.buildErrors))
        }
    }

    @Test func settingsWindowKeepsPaneOrderAndSimulatorsWarmBoot() {
        let t = TestDefaults("r33-window")
        defer { t.remove() }
        let wc = SettingsWindowController(prefs: Preferences(defaults: t.defaults), components: [])
        #expect(SettingsWindowController.paneTitles == ["General", "Appearance", "Accounts", "Coding Assistant", "Behaviors", "Navigation",
                                                        "Notifications", "Editing", "Shortcuts", "Source Control", "Components",
                                                        "Simulators", "Locations"])
        let sims = wc.pane(SimulatorsSettingsPane.self)!
        _ = sims.view
        #expect(sims.rowTitles.contains("Warm boot from snapshot") && sims.rowTitles.contains("Lean boot"))
    }

    // MARK: Settings take effect

    /// A package with a few sources, opened in a window.
    func workspace(_ dir: URL, files: [String: String]) throws -> (WorkspaceWindowController, URL) {
        let src = dir.appendingPathComponent("Sources/T")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"T\", targets: [.target(name: \"T\")])\n"
            .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        for (n, t) in files { try t.write(to: src.appendingPathComponent(n), atomically: true, encoding: .utf8) }
        _ = NSApplication.shared
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: dir)), loadDestinations: false,
                                           startLanguageService: false, openFirstFile: false)
        wc.window?.appearance = NSAppearance(named: .aqua)
        wc.applyDefaultLayout()
        return (wc, src)
    }

    @Test func generalSettingsTakeEffect() throws {
        try withPrefs("general-effect") { p, dir in
            // Restore windows drives the system's keep-windows default for Ycode.
            p.restoreWindows = .always
            #expect(p.defaults.object(forKey: Preferences.keepWindowsKey) as? Bool == true)
            p.restoreWindows = .never
            #expect(p.defaults.object(forKey: Preferences.keepWindowsKey) as? Bool == false)
            p.restoreWindows = .system
            #expect(p.defaults.object(forKey: Preferences.keepWindowsKey) == nil)

            let (wc, src) = try workspace(dir, files: ["A.swift": "let a = 1\nlet b = 2\n"])
            let a = src.appendingPathComponent("A.swift").path
            // Navigator size: row style and font.
            p.navigatorSize = .small
            #expect(wc.navigator.rowSizeStyle == .small && NavigatorAreaController.rowFontSize == 11)
            p.navigatorSize = .large
            #expect(wc.navigator.rowSizeStyle == .large && NavigatorAreaController.rowFontSize == 15)
            // Detail lines: issues, bookmarks and find results.
            @MainActor func leaves(_ items: [OutlineItem]) -> [OutlineItem] { items.flatMap { $0.children.isEmpty ? [$0] : leaves($0.children) } }
            wc.navigator.setIssues([Diagnostic(severity: .error, message: "bad", location: .init(file: a, line: 1))])
            wc.navigator.setBookmarks([Bookmark(file: a, line: 2, label: "let b = 2")])
            #expect(leaves(wc.navigator.rows(4)).map(\.maxLines) == [3] && leaves(wc.navigator.rows(2)).map(\.maxLines) == [3])
            p.issueNavigatorDetail = 1
            p.bookmarkNavigatorDetail = 5
            #expect(leaves(wc.navigator.rows(4)).map(\.maxLines) == [1] && leaves(wc.navigator.rows(2)).map(\.maxLines) == [5])
            p.findNavigatorDetail = 2
            wc.navigator.find("let")
            #expect(!leaves(wc.navigator.rows(3)).isEmpty && leaves(wc.navigator.rows(3)).allSatisfy { $0.maxLines == 2 })
            // Issue presentation reaches the editors.
            wc.open(path: a, line: nil)
            #expect(!wc.editor.showsMinimizedIssues)
            p.issuePresentation = .minimized
            #expect(wc.editor.showsMinimizedIssues)
            // Stop build on first error and the report history reach the session.
            p.stopBuildOnFirstError = false
            #expect(!wc.session.stopOnFirstError)
            p.reportHistoryLimit = 10
            #expect(wc.session.reportHistoryLimit == 10)
            for i in 0..<12 {
                wc.session.recordReport(BuildReport(title: "Build \(i)", date: Date(), succeeded: true, log: [], errorCount: 0, warningCount: 0))
            }
            #expect(wc.session.reports.count == 10 && wc.session.reports.first?.title == "Build 11")
            // Import, export and reset.
            let file = dir.appendingPathComponent("settings.json")
            let general = GeneralSettingsPane(prefs: p)
            try general.exportSettings(to: file)
            let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            #expect(json["format"] as? String == "ycode-settings")
            p.resetSettings()
            #expect(p.issuePresentation == .inline && p.reportHistoryLimit == 20 && p.navigatorSize == .system && p.stopBuildOnFirstError)
            #expect(p.behavior(.buildSucceeds).notify)
            try general.importSettings(from: file)
            #expect(p.issuePresentation == .minimized && p.reportHistoryLimit == 10 && p.navigatorSize == .large && !p.stopBuildOnFirstError)
            #expect(p.issueNavigatorDetail == 1)
            #expect(throws: (any Error).self) { try p.importSettings(Data("{}".utf8)) }
            // "Don't ask me" warnings.
            p.suppressWarning("example")
            #expect(p.isWarningSuppressed("example"))
            p.resetSuppressedWarnings()
            #expect(!p.isWarningSuppressed("example"))
        }
    }

    /// A build that reports an error, then a second one and fails. With
    /// `waitsForCancel` the rest only comes after a long pause, so a build
    /// that stops on its first error is cancelled first (cancelling
    /// finishes it at once).
    final class Cancelled: @unchecked Sendable { var value = false }
    struct ErrorThenWaitEngine: BuildEngine {
        let cancelled: Cancelled
        var waitsForCancel = true
        var name: String { "error-then-wait" }
        func start(_ request: BuildRequest) -> BuildOperation {
            let (s, c) = AsyncStream<BuildEvent>.makeStream()
            let first = Diagnostic(severity: .error, message: "first", location: .init(file: "/x/main.swift", line: 1))
            let second = Diagnostic(severity: .error, message: "second", location: .init(file: "/x/main.swift", line: 2))
            c.yield(.output("CompileSwift normal arm64 /x/main.swift"))
            c.yield(.issue(first))
            let box = cancelled
            let wait = waitsForCancel
            Task {
                if wait { try? await Task.sleep(for: .seconds(30)) }
                guard !box.value else { return }
                c.yield(.issue(second))
                c.yield(.finished(BuildResult(status: .failed, exitCode: 65, issues: [first, second])))
                c.finish()
            }
            return BuildOperation(events: s, cancel: {
                box.value = true
                c.yield(.finished(BuildResult(status: .cancelled, exitCode: -1, issues: [])))
                c.finish()
            })
        }
    }

    @Test func stopBuildOnFirstErrorCancelsTheBuild() async throws {
        _ = NSApplication.shared
        let session = WorkspaceSession(model: try WorkspaceModel(url: try WindowSnapshotTests().samplePackage()))
        let flag = Cancelled()
        session.engine = ErrorThenWaitEngine(cancelled: flag)
        session.stopOnFirstError = true
        let r = await session.build()
        #expect(flag.value && r.status == .failed && r.issues.map(\.message) == ["first"])
        #expect(session.activity == .finished("Build Failed"))
        let off = Cancelled()
        session.engine = ErrorThenWaitEngine(cancelled: off, waitsForCancel: false)
        session.stopOnFirstError = false
        let all = await session.build()
        #expect(!off.value && all.issues.map(\.message) == ["first", "second"])
    }

    @Test func navigationSettingsTakeEffect() throws {
        try withPrefs("navigation-effect") { p, dir in
            let (wc, src) = try workspace(dir, files: ["A.swift": "let a = 1\n", "B.swift": "let b = 2\n", "C.swift": "let c = 3\n"])
            let a = src.appendingPathComponent("A.swift").path, b = src.appendingPathComponent("B.swift").path
            let c = src.appendingPathComponent("C.swift").path
            wc.openFromNavigator(path: a, line: nil, modifiers: [])
            // New tabs: the Start Page by default, else the same document.
            wc.newTab(nil)
            #expect(wc.editorArea.tabs.count == 2 && wc.editor.fileURL == nil && wc.editor.emptyView != nil)
            wc.closeTab(nil)
            p.newEditorTabsOpenWith = .sameDocument
            wc.newTab(nil)
            #expect(wc.editor.fileURL?.path == a)
            wc.closeTab(nil)
            // New panes: the same document by default, else the Start Page.
            wc.splitEditor(nil)
            #expect(wc.editorArea.tab.editors.count == 2 && wc.editor.fileURL?.path == a)
            wc.closeEditor(nil)
            p.newEditorPanesOpenWith = .startPage
            wc.splitEditor(nil)
            #expect(wc.editor.fileURL == nil && wc.editor.emptyView != nil)
            wc.closeEditor(nil)
            #expect(wc.editorArea.tab.editors.count == 1)

            // ⌥-click: a new unpinned tab; ⌥⇧-click: the next pane (made when needed).
            wc.openFromNavigator(path: b, line: nil, modifiers: .option)
            #expect(wc.editorArea.tabs.count == 2 && wc.editor.fileURL?.path == b && !wc.editorArea.tab.isPinned)
            wc.openFromNavigator(path: c, line: nil, modifiers: [.option, .shift])
            #expect(wc.editorArea.tab.editors.count == 2 && wc.editor.fileURL?.path == c && wc.editorArea.tab.editors[0].fileURL?.path == b)
            wc.openFromNavigator(path: a, line: nil, modifiers: [.option, .shift])
            #expect(wc.editorArea.tab.editors.count == 2 && wc.editorArea.tab.editors[0].fileURL?.path == a)
            // A double click is the same as a click (the focused pane).
            let tabs = wc.editorArea.tabs.count
            wc.openFromNavigator(path: c, line: nil, modifiers: [], clickCount: 2)
            #expect(wc.editorArea.tabs.count == tabs && wc.editor.fileURL?.path == c)

            // Pin Editor Tabs: manually by default; automatically on edit.
            wc.editor.textView.insertText("// x\n", replacementRange: NSRange(location: 0, length: 0))
            #expect(!wc.editorArea.tab.isPinned)
            p.pinEditorTabs = .automatically
            wc.editor.textView.insertText("// y\n", replacementRange: NSRange(location: 0, length: 0))
            #expect(wc.editorArea.tab.isPinned)
            wc.editor.textView.undoManager?.removeAllActions()

            // Click on Code: ⌃⌘-click jumps to the definition; when set,
            // Quick Help instead.
            var jumped = 0, helped = 0
            wc.editor.onJumpToDefinition = { _, _ in jumped += 1 }
            wc.editor.onQuickHelp = { _, _, _ in helped += 1 }
            @MainActor func click(_ flags: NSEvent.ModifierFlags) {
                let tv = wc.editor.textView
                let point = tv.convert(NSPoint(x: 20, y: 8), to: nil)
                let e = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: flags, timestamp: 0,
                                           windowNumber: wc.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                tv.mouseDown(with: e)
            }
            click([.command, .control])
            #expect(jumped == 1 && helped == 0)
            p.commandControlClickOnCode = .quickHelp
            click([.command, .control])
            click(.option)
            #expect(jumped == 1 && helped == 2)
        }
    }

    @Test func displayModel() {
        let text = """
        struct A {
            // MARK: - Helpers
            func f() {}
        #if false
            let x = 1
        #else
            let y = 2
        #endif
        #if DEBUG
            let z = 3
        #elseif os(iOS)
            let w = 4
        #endif
        }
        """
        #expect(EditorDisplayModel.markSeparatorLines(in: text) == [2])
        #expect(EditorDisplayModel.endifConditions(in: text) == [8: "false", 13: "DEBUG"])
        #expect(EditorDisplayModel.inactiveLines(in: text) == [5...5])
        #expect(EditorDisplayModel.inactiveLines(in: text, defined: ["DEBUG"]) == [5...5, 12...12])
        #expect(EditorDisplayModel.inactiveLines(in: "#if 0\nint a;\n#elif 1\nint b;\n#else\nint c;\n#endif\n") == [2...2, 6...6])
        #expect(EditorDisplayModel.evaluate("!false && (true || os(iOS))", defined: nil) == true)
        #expect(EditorDisplayModel.evaluate("false && os(iOS)", defined: nil) == false)
        #expect(EditorDisplayModel.evaluate("DEBUG || canImport(UIKit)", defined: nil) == nil)
        #expect(EditorDisplayModel.evaluate("defined(FOO)", defined: ["FOO"]) == true)
        let src = "/// Doc\n// plain\n/* block */\n/** doc block */\nlet a = 1\n"
        let tokens = SourceTokenizer(language: .swift).tokens(in: src)
        let d = EditorDisplayModel.commentDelimiters(tokens, in: src as NSString)
        let ns = src as NSString
        #expect(d.doc.map(ns.substring(with:)) == ["///", "/**", "*/"])
        #expect(d.plain.map(ns.substring(with:)) == ["//", "/*", "*/"])
        let lines = text.components(separatedBy: "\n")
        let regions = [FoldRegion(startLine: 1, endLine: 14, depth: 0), FoldRegion(startLine: 3, endLine: 13, depth: 1)]
        #expect(EditorDisplayModel.structureHeaderLines(regions, topLine: 6) { lines[$0 - 1] } == [1, 3])
        #expect(EditorDisplayModel.structureHeaderLines(regions, topLine: 1) { lines[$0 - 1] }.isEmpty)
    }

    @Test func displaySettingsTakeEffect() throws {
        let body = (1...80).map { "        let v\($0) = \($0)" }.joined(separator: "\n")
        let text = """
        /// A type.
        struct Big {
            // MARK: - Values
            func values() {
        \(body)
            }
        #if false
            let off = 0
        #endif
        }
        """
        try withPrefs("display-effect") { p, dir in
            let (wc, src) = try workspace(dir, files: ["Big.swift": text, "CRLF.swift": "let a = 1\r\nlet b = 2\r\n"])
            wc.open(path: src.appendingPathComponent("Big.swift").path, line: nil)
            let e = wc.editor
            #expect(e.markSeparatorLines == [3])
            #expect(e.endifConditions == [88: "false"])
            #expect(e.inactiveLineRanges == [87...87])
            let ns = e.text as NSString
            let docSlashes = ns.range(of: "///").location, offLet = ns.range(of: "let off").location, plain = ns.range(of: "let v1 ").location
            #expect((e.renderingColor(at: docSlashes)?.alphaComponent ?? 1) < 1)
            #expect((e.renderingColor(at: offLet)?.alphaComponent ?? 1) < 1)
            #expect(e.renderingColor(at: plain) == nil)
            p.showMarkSeparators = false
            p.showEndifConditions = false
            p.dimInactiveCode = false
            p.fadeDocCommentDelimiters = false
            #expect(e.markSeparatorLines.isEmpty && e.endifConditions.isEmpty && e.inactiveLineRanges.isEmpty)
            #expect(e.renderingColor(at: docSlashes) == nil && e.renderingColor(at: offLet) == nil)

            // Overscroll: blank space after the last line (Medium by default).
            let tv = e.textView
            // Headless: lay the whole text out, as scrolling would, and let
            // the view size itself to it.
            let tlm = try #require(tv.textLayoutManager)
            @MainActor func height() -> CGFloat {
                tlm.ensureLayout(for: tlm.documentRange)
                tlm.textViewportLayoutController.layoutViewport()
                return tv.frame.height
            }
            let medium = height()
            p.editorOverscroll = .none
            let none = height()
            p.editorOverscroll = .large
            let large = height()
            let visible = e.scrollView.contentSize.height
            #expect(visible > 0 && medium > none && large > medium)
            #expect(abs((medium - none) - (visible * 0.5).rounded()) <= 1)

            // Code structure headers: scrolled into values(), the struct and
            // the function stay on top.
            tlm.ensureLayout(for: tlm.documentRange)
            let target = tv.lineRect(40)!
            e.scrollView.contentView.scroll(to: NSPoint(x: 0, y: target.minY))
            e.updateStructureHeader()
            #expect(e.structureHeaderLines.map { $0.trimmingCharacters(in: .whitespaces) } == ["struct Big {", "func values() {"])
            p.showCodeStructureHeaders = false
            #expect(e.structureHeaderLines.isEmpty)

            // Convert existing files on save: CRLF becomes LF.
            let crlf = src.appendingPathComponent("CRLF.swift")
            wc.open(path: crlf.path, line: nil)
            wc.editor.textView.insertText("// edit\r\n", replacementRange: NSRange(location: 0, length: 0))
            try wc.editor.save()
            #expect(try String(contentsOf: crlf, encoding: .utf8).contains("\r\n"))
            p.convertExistingFilesOnSave = true
            wc.editor.textView.insertText("// again\n", replacementRange: NSRange(location: 0, length: 0))
            try wc.editor.save()
            #expect(try String(contentsOf: crlf, encoding: .utf8) == "// again\n// edit\nlet a = 1\nlet b = 2\n")
        }
    }
}
