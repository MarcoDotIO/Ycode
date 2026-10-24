import AppKit
import Foundation
import Testing
import YcodeBuild
import YcodeProject
@testable import YcodeUI

/// R31 (`specs/ide/reference-ui-5.md` §3, §4.3, §5.1): launch and the
/// Welcome window, Open Recent, the window title, the idle activity text,
/// the default run destination and the project navigator's first view.
@MainActor
@Suite(.serialized) struct LaunchWelcomeR31Tests {
    func tempDir(_ tag: String) throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-r31-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u.resolvingSymlinksInPath()
    }

    /// An iOS app project ("Tour") made by Ycode's own template.
    func iosApp(in dir: URL, name: String = "Tour") throws -> URL {
        var o = ProjectOptions()
        o.productName = name
        o.organizationIdentifier = "org.ycode.tests"
        o.testing = .none
        o.setStorage(.none)
        return try ProjectTemplate.app.create(platform: "iOS", options: o, in: dir)
    }

    func window(_ url: URL, userState: URL? = nil) throws -> WorkspaceWindowController {
        _ = NSApplication.shared
        return WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: url)), loadDestinations: false,
                                         startLanguageService: false, openFirstFile: false, userStateURL: userState)
    }

    func sim(_ name: String, _ version: String, platform: String = "iOS") -> Destination {
        Destination(name: name, specifier: "platform=\(platform) Simulator,id=\(name)-\(version)", platform: platform, kind: .simulator,
                    osVersion: version, identifier: "\(name)-\(version)")
    }

    // MARK: L1, L2 — Welcome window

    @Test func launchWithoutDocumentsShowsWelcomeNotAnOpenPanel() {
        #expect(LaunchAction.decide(arguments: [], openDocumentCount: 0) == .welcome)
        #expect(LaunchAction.decide(arguments: ["-ApplePersistenceIgnoreState", "YES"], openDocumentCount: 0) == .welcome)
        #expect(LaunchAction.decide(arguments: ["/p/App.xcodeproj"], openDocumentCount: 0) == .open(["/p/App.xcodeproj"]))
        #expect(LaunchAction.decide(arguments: [], openDocumentCount: 1) == .none)
    }

    @Test func welcomeWindowLayout() throws {
        _ = NSApplication.shared
        let td = TestDefaults("r31-welcome")
        defer { td.remove() }
        let w = WelcomeWindowController(recents: RecentProjects(defaults: td.defaults))
        let win = try #require(w.window)
        #expect(win.frame.size == WelcomeWindowController.size)
        #expect(WelcomeWindowController.size == NSSize(width: 480, height: 632))
        #expect(win.title == "Welcome to Ycode" && win.titleVisibility == .hidden)
        #expect(w.nameLabel.stringValue == "Ycode" && w.versionLabel.stringValue.hasPrefix("Version "))
        #expect([w.openButton.title, w.cloneButton.title, w.newProjectButton.itemTitles.first] == ["Open…", "Clone…", "New Project"])
        #expect(w.newProjectButton.pullsDown)
        #expect(Array(w.newProjectButton.itemTitles.dropFirst()) == NewProjectPicker.rows.map(\.title))
        #expect(w.table.accessibilityLabel() == "Recent Projects")
        #expect(!w.nameLabel.stringValue.contains("Xcode"))
    }

    @Test func welcomeShortcutAndAction() throws {
        let c = try #require(CommandTable.command(titled: "Welcome to Ycode"))
        #expect(c.key == "1" && c.modifiers == [.command, .shift] && c.action == "showWelcomeWindow:")
        #expect(AppDelegate.instancesRespond(to: NSSelectorFromString(c.action)))
        _ = NSApplication.shared
        let app = AppDelegate()
        let w1 = app.showWelcomeWindow(nil)
        w1.close()
        let w2 = app.showWelcomeWindow(nil)  // ⇧⌘1 brings it back
        #expect(w1 === w2 && w2.window?.isVisible == true)
        w2.close()
    }

    @Test func welcomeListsRecentsAndOpensTheSelectedRow() throws {
        _ = NSApplication.shared
        let dir = try tempDir("welcome-list")
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try iosApp(in: dir, name: "Alpha"), b = try iosApp(in: dir, name: "Beta")
        let td = TestDefaults("r31-welcome-list")
        defer { td.remove() }
        let recents = RecentProjects(defaults: td.defaults)
        recents.note(a)
        recents.note(b)
        let w = WelcomeWindowController(recents: recents)
        #expect(w.entries.map(\.path) == [b.path, a.path])  // newest first, the same as Open Recent
        #expect(w.table.numberOfRows == 2 && w.table.selectedRow == 0)
        let cell = try #require(w.tableView(w.table, viewFor: nil, row: 0) as? NSTableCellView)
        #expect(cell.textField?.stringValue == "Beta" && cell.textField?.toolTip == "Beta")
        var opened: [URL] = []
        w.openWorkspace = { url, done in opened.append(url); done(true) }
        w.showWindow(nil)
        w.openSelected(nil)
        #expect(opened.map(\.path) == [b.path])
        #expect(w.window?.isVisible == false)  // opening from the Welcome window closes it
        // Clear Menu also empties the Welcome list.
        recents.clear()
        #expect(w.entries.isEmpty && w.table.numberOfRows == 0)
    }

    // MARK: L3 — Open Recent

    @Test func recentProjectsOrderLimitPersistenceAndMissingFiles() throws {
        let dir = try tempDir("recents")
        defer { try? FileManager.default.removeItem(at: dir) }
        let td = TestDefaults("r31-recents")
        defer { td.remove() }
        let r = RecentProjects(defaults: td.defaults)
        var urls: [URL] = []
        for i in 0..<12 {
            let u = dir.appendingPathComponent("P\(i).xcodeproj")
            try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
            urls.append(u)
            r.note(u)
        }
        #expect(r.urls.count == RecentProjects.limit)
        #expect(r.urls.first?.path == urls[11].path)
        r.note(urls[5])
        #expect(r.urls.first?.path == urls[5].path && r.urls.filter { $0.path == urls[5].path }.count == 1)
        // Survives "relaunch" (a new list on the same defaults).
        #expect(RecentProjects(defaults: td.defaults).urls.map(\.path) == r.urls.map(\.path))
        // A package is recorded by its folder; a missing entry is dropped.
        let pkg = dir.appendingPathComponent("Pkg")
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try "".write(to: pkg.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        r.note(pkg.appendingPathComponent("Package.swift"))
        #expect(r.urls.first?.path == pkg.path)
        try FileManager.default.removeItem(at: urls[5])
        #expect(!r.urls.map(\.path).contains(urls[5].path))
        r.clear()
        #expect(r.urls.isEmpty)
    }

    @Test func openRecentTitlesAndMenu() throws {
        let one = URL(fileURLWithPath: "/Volumes/Data/a/ObsApp.xcodeproj")
        let two = URL(fileURLWithPath: "/Volumes/Data/b-copy/ObsApp.xcodeproj")
        let pkg = URL(fileURLWithPath: "/Volumes/Data/Obs")
        #expect(RecentProjects.menuTitles([one, two, pkg]) == ["ObsApp.xcodeproj \u{2014}  a", "ObsApp.xcodeproj \u{2014}  b-copy", "Obs"])
        #expect(RecentProjects.displayName(one) == "ObsApp" && RecentProjects.displayName(pkg) == "Obs")
        #expect(RecentProjects.folderText(URL(fileURLWithPath: "/Volumes/MARCUS-PROJECTS/_inbox/App.xcodeproj")) == "MARCUS-PROJECTS/_inbox")

        // The menu: entries, a separator, Clear Menu.
        let menu = NSMenu()
        RecentProjectsMenuDelegate.fill(menu, with: [one, pkg])
        #expect(menu.items.map(\.title) == ["ObsApp.xcodeproj", "Obs", "", "Clear Menu"])
        #expect(menu.items[0].representedObject as? URL == one && menu.items[0].action == #selector(AppDelegate.openRecentProject(_:)))
        RecentProjectsMenuDelegate.fill(menu, with: [])
        #expect(menu.items.map(\.title) == ["Clear Menu"])

        // File ▸ Open Recent is a submenu filled from the list (not a disabled item).
        _ = NSApplication.shared
        let bar = MainMenu.make()
        let file = try #require(bar.item(withTitle: "File")?.submenu)
        let recent = try #require(file.item(withTitle: "Open Recent"))
        #expect(recent.submenu?.delegate === RecentProjectsMenuDelegate.shared)
        #expect(file.index(of: recent) == (file.indexOfItem(withTitle: "Open…") + 1))
    }

    // MARK: L4, T4, L5, L8 — window title, idle activity, frame, Start Page

    @Test func windowTitleIdleActivityFrameAndStartPage() throws {
        let dir = try tempDir("title")
        defer { try? FileManager.default.removeItem(at: dir) }
        let proj = try iosApp(in: dir)
        let wc = try window(proj)
        #expect(wc.window?.title == "Tour \u{2014} Tour.xcodeproj")
        #expect(wc.window?.frame.size == WorkspaceWindowController.defaultSize)  // toolbar included
        #expect(wc.activityView.status.isEmpty)  // no "Ready" while idle
        // The Start Page sits below the jump bar ("No Selection").
        wc.applyDefaultLayout()
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        let empty = try #require(wc.editor.emptyView)
        #expect(empty.frame.maxY <= wc.editor.jumpBar.frame.minY + 0.5 || empty.frame.minY >= wc.editor.jumpBar.frame.maxY - 0.5)
        #expect(empty.frame.height < wc.editor.view.bounds.height)

        let file = try #require(wc.session.model.root.allFiles.first { $0.name == "ContentView.swift" }?.path)
        wc.open(path: file, line: nil)
        #expect(wc.window?.title == "Tour \u{2014} ContentView.swift")
        #expect(WorkspaceWindowController.windowTitle(workspace: "Obs", document: "Package.swift") == "Obs \u{2014} Package.swift")
    }

    // MARK: T1 — default destination

    @Test func defaultDestinationRule() {
        let sims = [sim("iPad Air", "26.4"), sim("iPhone 17 Pro", "26.4"), sim("iPhone 17", "26.4"), sim("iPhone 18", "27.0"),
                    sim("Apple Vision Pro", "27.0", platform: "visionOS"), sim("iPhone 15", "17.5")]
        #expect(DestinationCatalog.simulatorsInMenuOrder(sims.filter { $0.platform == "iOS" }).map(\.name)
                == ["iPhone 18", "iPhone 17", "iPhone 17 Pro", "iPad Air", "iPhone 15"])
        #expect(DestinationCatalog.defaultDestination(platform: "macOS", deploymentTarget: "15.0", simulators: sims) == .myMac)
        #expect(DestinationCatalog.defaultDestination(platform: nil, deploymentTarget: nil, simulators: sims) == .myMac)
        #expect(DestinationCatalog.defaultDestination(platform: "iOS", deploymentTarget: "18.0", simulators: sims).name == "iPhone 18")
        // Below the deployment target: skipped.
        #expect(DestinationCatalog.defaultDestination(platform: "iOS", deploymentTarget: "27.1", simulators: sims).name
                == "Any iOS Simulator Device")
        let generic = DestinationCatalog.defaultDestination(platform: "iOS", deploymentTarget: "18.0", simulators: [])
        #expect(generic.specifier == "generic/platform=iOS Simulator" && generic.kind == .generic)
        #expect(DestinationCatalog.compareVersions("26.10", "26.4") == .orderedDescending)
    }

    @Test func iosAppDefaultsToASimulatorAndRemembersTheChoicePerScheme() throws {
        let dir = try tempDir("dest")
        defer { try? FileManager.default.removeItem(at: dir) }
        let proj = try iosApp(in: dir)
        let stateURL = dir.appendingPathComponent("state.json")
        let wc = try window(proj, userState: stateURL)
        let p = wc.productPlatform
        #expect(p.platform == "iOS" && p.deploymentTarget == "18.0")
        // Before the simulators are listed: the generic simulator, never My Mac.
        #expect(wc.session.destination?.name == "Any iOS Simulator Device")
        #expect(wc.session.model.buildRequest(scheme: wc.session.scheme, destination: wc.session.destination, action: .build).destination
                == "generic/platform=iOS Simulator")
        let groups = DestinationCatalog.groups(devices: [], simulators: [sim("iPhone 17", "26.4"), sim("iPad Air", "26.4"), sim("iPhone 16", "18.2")])
        wc.setDestinationGroups(groups)
        #expect(wc.session.destination?.name == "iPhone 17")
        #expect(wc.destinationTitle.hasPrefix("iPhone 17"))

        // An explicit choice is remembered for the scheme in user data.
        let ipad = try #require(wc.session.model.destinations.first { $0.name == "iPad Air" })
        wc.session.destination = ipad
        wc.rememberDestination()
        #expect(WorkspaceUserState.load(from: stateURL).destinations[wc.session.scheme ?? ""] == ipad.identifier)
        let again = try window(proj, userState: stateURL)
        again.setDestinationGroups(groups)
        #expect(again.session.destination?.name == "iPad Air")
    }

    @Test func macAndPackageWorkspacesDefaultToMyMac() throws {
        let wc = try window(try WindowSnapshotTests().samplePackage())
        #expect(wc.session.destination == .myMac)
        let dir = try tempDir("mac")
        defer { try? FileManager.default.removeItem(at: dir) }
        var o = ProjectOptions()
        o.productName = "Tool"
        o.organizationIdentifier = "org.ycode.tests"
        let tool = try ProjectTemplate.commandLineTool.create(platform: "macOS", options: o, in: dir)
        let mac = try window(tool)
        mac.setDestinationGroups(DestinationCatalog.groups(devices: [], simulators: [sim("iPhone 17", "26.4")]))
        #expect(mac.session.destination == .myMac)
    }

    // MARK: N1–N4 — project navigator first view

    @Test func navigatorFirstView() throws {
        let dir = try tempDir("nav")
        defer { try? FileManager.default.removeItem(at: dir) }
        let proj = try iosApp(in: dir)
        let stateURL = dir.appendingPathComponent("state.json")
        let wc = try window(proj, userState: stateURL)
        wc.navigator.select(0)
        let root = try #require(wc.navigator.rows(0).first)
        // N1: no Products group.
        #expect(root.title == "Tour" && !root.children.map(\.title).contains("Products"))
        #expect(!wc.session.model.root.children.map(\.name).contains("Products"))
        // N2: file names without extensions (Hide All is the factory default).
        let td = TestDefaults("r31-prefs")
        defer { td.remove() }
        #expect(Preferences(defaults: td.defaults).fileExtensions == .hide)
        #expect(Preferences.FileExtensions.allCases.map(\.rawValue) == ["Hide All", "Show All"])
        func titles(_ items: [OutlineItem]) -> [String] { items.flatMap { [$0.title] + titles($0.children) } }
        let all = titles([root])
        #expect(all.contains("ContentView") && !all.contains { $0.hasSuffix(".swift") })
        // N4: the root and its first group are expanded at first open.
        let first = try #require(root.children.first { $0.nodeKind != .file })
        #expect(wc.navigator.projectExpansion == [root.expansionKey, first.expansionKey].compactMap { $0 })
        // N3: letters on file rows only.
        let file = try #require(wc.session.model.root.allFiles.first { $0.name == "ContentView.swift" }?.path)
        wc.navigator.setFileStatus([file: .modified, proj.path: .modified, proj.deletingLastPathComponent().appendingPathComponent("Tour").path: .modified])
        func find(_ items: [OutlineItem], _ t: String) -> OutlineItem? {
            for i in items { if i.title == t { return i }; if let f = find(i.children, t) { return f } }
            return nil
        }
        #expect(find([root], "ContentView")?.badge == "M")
        #expect(root.badge == nil && first.badge == nil)
    }

    @Test func navigatorExpansionAndRecentFilesSurviveReopening() throws {
        let dir = try tempDir("state")
        defer { try? FileManager.default.removeItem(at: dir) }
        let proj = try iosApp(in: dir)
        let stateURL = dir.appendingPathComponent("state.json")
        let wc = try window(proj, userState: stateURL)
        wc.navigator.select(0)
        let file = try #require(wc.session.model.root.allFiles.first { $0.name == "ContentView.swift" }?.path)
        wc.open(path: file, line: nil)
        // Collapse the first group: the expansion is saved.
        wc.navigator.onProjectExpansionChange?([try #require(wc.navigator.rows(0).first?.expansionKey)])
        let saved = WorkspaceUserState.load(from: stateURL)
        #expect(saved.recentFiles == [file])
        #expect(saved.expandedRows?.count == 1)

        let again = try window(proj, userState: stateURL)
        again.navigator.select(0)
        #expect(again.navigator.recentFiles == [file])  // the Start Page's Recent Files (L9)
        #expect(again.navigator.projectExpansion == saved.expandedRows)
    }

    @Test func packageRootOrder() throws {
        let dir = try tempDir("pkg")
        defer { try? FileManager.default.removeItem(at: dir) }
        for f in ["Alpha", "Sources/P", "Tests/PTests", "Docs"] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(f), withIntermediateDirectories: true)
        }
        for f in ["Package.swift", "README.md", "Sources/P/P.swift"] {
            try "".write(to: dir.appendingPathComponent(f), atomically: true, encoding: .utf8)
        }
        #expect(NavigatorTree.package(at: dir).children.map(\.name) == ["Package.swift", "Sources", "Tests", "Alpha", "Docs", "README.md"])
    }

    @Test func userStateFileLocation() {
        let p = URL(fileURLWithPath: "/w/App.xcodeproj"), k = URL(fileURLWithPath: "/w/Pkg")
        #expect(WorkspaceUserState.fileURL(container: p, isPackage: false, user: "me").path
                == "/w/App.xcodeproj/xcuserdata/me.xcuserdatad/ycode-ui-state.json")
        #expect(WorkspaceUserState.fileURL(container: k, isPackage: true, user: "me").path
                == "/w/Pkg/.swiftpm/xcode/xcuserdata/me.xcuserdatad/ycode-ui-state.json")
        var s = WorkspaceUserState()
        for i in 0..<25 { s.noteRecentFile("/f\(i)") }
        s.noteRecentFile("/f10")
        #expect(s.recentFiles.count == WorkspaceUserState.recentFileLimit && s.recentFiles.last == "/f10")
    }
}
