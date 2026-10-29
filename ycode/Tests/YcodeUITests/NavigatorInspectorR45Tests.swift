import AppKit
import Foundation
import Testing
import YcodeBuild
import YcodeDebug
import YcodeProject
@testable import YcodeUI

/// reference-ui-6.md R45: navigator, inspector and debug-area polish.
@MainActor
@Suite(.serialized) struct NavigatorInspectorR45Tests {
    /// A navigator laid out at 280 × 600 with a small project tree.
    func laidOutNavigator() -> NavigatorAreaController {
        _ = NSApplication.shared
        let nav = NavigatorAreaController()
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = nav.view
        nav.view.frame = NSRect(x: 0, y: 0, width: 280, height: 600)
        let root = NavigatorNode(name: "App", kind: .container, path: "/tmp/App.xcodeproj", children: [
            NavigatorNode(name: "A", kind: .group, path: "/tmp/A", children: [NavigatorNode(name: "a.swift", kind: .file, path: "/tmp/A/a.swift")]),
            NavigatorNode(name: "b.swift", kind: .file, path: "/tmp/b.swift"),
        ])
        nav.setProjectTree(root)
        nav.view.layoutSubtreeIfNeeded()
        return nav
    }

    // MARK: N3 — row metrics

    @Test func rowsAre22PointsAndStartSevenBelowTheSelector() {
        let nav = laidOutNavigator()
        let o = nav.outlineView
        #expect(o.numberOfRows >= 3)
        let r0 = o.convert(o.rect(ofRow: 0), to: nav.view)
        let r1 = o.convert(o.rect(ofRow: 1), to: nav.view)
        #expect(r0.height == 22 && r1.height == 22)
        #expect(abs(r0.minY - r1.minY) == 22, "rows touch: no spacing between them")
        // Unflipped: the first row's top is its maxY.
        let gap = nav.selectorView.frame.minY - r0.maxY
        #expect(abs(gap - 7) <= 0.5, "first row \(gap) points below the selector")
        // The navigator size setting keeps the size style it names.
        #expect(nav.rowSizeStyle == NavigatorAreaController.rowSizeStyle)
    }

    // MARK: N4 — package tree

    @Test func packageOpensWithSourcesAndTestsExpanded() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("r45-pkg-\(UUID().uuidString)/Pkg")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        for sub in ["Sources/Pkg", "Sources/Tool", "Tests/PkgTests"] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        try "// swift-tools-version: 6.0".write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "".write(to: dir.appendingPathComponent("Sources/Pkg/Pkg.swift"), atomically: true, encoding: .utf8)
        try "".write(to: dir.appendingPathComponent("Tests/PkgTests/T.swift"), atomically: true, encoding: .utf8)
        try "".write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let root = NavigatorTree.package(at: dir)
        let keys = NavigatorTree.initiallyExpanded(root)
        #expect(keys == [root.expansionKey, dir.appendingPathComponent("Sources").path, dir.appendingPathComponent("Tests").path])
        // In the navigator: Sources and Tests open, their children closed.
        let nav = laidOutNavigator()
        nav.setProjectTree(root)
        let o = nav.outlineView
        let rows = (0..<o.numberOfRows).compactMap { o.item(atRow: $0) as? OutlineItem }
        #expect(rows.map { ($0.title as NSString).deletingPathExtension } == ["Pkg", "Package", "Sources", "Pkg", "Tool", "Tests", "PkgTests", "README"])
        let expanded = rows.filter { o.isItemExpanded($0) }.map(\.title)
        #expect(expanded == ["Pkg", "Sources", "Tests"])
        // A project keeps its first group expanded.
        let proj = NavigatorNode(name: "App", kind: .container, path: "/tmp/App.xcodeproj", children: [
            NavigatorNode(name: "Sources", kind: .group, path: "/tmp/S", objectID: "G1", children: []),
            NavigatorNode(name: "Tests", kind: .group, path: "/tmp/T", objectID: "G2", children: []),
        ])
        #expect(NavigatorTree.initiallyExpanded(proj) == ["/tmp/App.xcodeproj", "G1"])
    }

    // MARK: N5 — Test navigator rows

    @Test func testNavigatorRootCountsAndResultGlyphs() throws {
        let text = """
        import Testing
        struct ModelTests {
            @Test func a() {}
            @Test func b() {}
        }
        @Test func loose() {}
        """
        let found = TestDiscovery.tests(in: text, file: "/tmp/AuditPkgTests/ModelTests.swift")
        #expect(found.count == 3)
        let nav = laidOutNavigator()
        nav.workspaceName = "AuditPkg"
        nav.isPackage = true
        nav.testPlanName = "AuditPkg (Autocreated)"
        nav.select(5)
        nav.setTests(found, results: [:])
        let root = try #require(nav.rows(5).first)
        // The root is the package, not the plan; the plan stays in the pop-up.
        #expect(root.title == "AuditPkg" && root.detail == "3 Tests" && root.symbol == "shippingbox")
        #expect(nav.testPlanPopUp.titleOfSelectedItem == "AuditPkg (Autocreated)")
        let target = try #require(root.children.first)
        #expect(target.detail == "3 Tests")
        let suite = try #require(target.children.first { $0.title == "ModelTests" })
        #expect(suite.detail == "2 Tests")
        // No result yet: no glyph on any row.
        func all(_ i: OutlineItem) -> [OutlineItem] { [i] + i.children.flatMap(all) }
        #expect(all(root).allSatisfy { $0.trailingSymbol == nil })
        // One passed: it and its parents show passed; the rest nothing.
        nav.setTests(found, results: [found[0]: .passed])
        let r2 = try #require(nav.rows(5).first)
        let s2 = try #require(r2.children.first?.children.first { $0.title == "ModelTests" })
        #expect(r2.trailingSymbol == "checkmark.diamond.fill" && s2.trailingSymbol == "checkmark.diamond.fill")
        #expect(s2.children.map { $0.trailingSymbol ?? "" } == ["checkmark.diamond.fill", ""])
        // A failure anywhere below makes the parent failed.
        nav.setTests(found, results: [found[0]: .passed, found[2]: .failed])
        #expect(nav.rows(5).first?.trailingSymbol == "xmark.diamond.fill")
        #expect(NavigatorAreaController.testCountText(1) == "1 Test")
        #expect(NavigatorAreaController.aggregateTestStatus([nil, .skipped]) == .skipped)
        // The header pop-up: bordered, 194 wide.
        nav.view.layoutSubtreeIfNeeded()
        #expect(nav.testPlanPopUp.isBordered && nav.testPlanPopUp.frame.width == 194)
    }

    // MARK: N6 — Find navigator header

    @Test func findHeaderIsAPathWithoutArrowsAndThePlaceholderIsTheKind() {
        let nav = laidOutNavigator()
        nav.select(3)
        for p in [nav.findMode, nav.findStyle, nav.findMatch] {
            #expect((p.cell as? NSPopUpButtonCell)?.arrowPosition == NSPopUpButton.ArrowPosition.noArrow)
        }
        #expect([nav.findMode, nav.findStyle, nav.findMatch].map { $0.titleOfSelectedItem ?? "" } == ["Find", "Text", "Containing"])
        #expect(nav.findField.placeholderString == "Text")
        nav.findStyle.selectItem(at: 2)
        nav.findStyle.sendAction(nav.findStyle.action, to: nav.findStyle.target)
        #expect(nav.findField.placeholderString == "Regular Expression")
        var o = nav.findOptionsValue
        o.regularExpression = false
        nav.findOptionsValue = o
        #expect(nav.findField.placeholderString == "Text")
    }

    // MARK: N7, N8 — filter fields and selector titles

    @Test func filterOptionsAndTogglesSitInsideTheField() throws {
        let nav = laidOutNavigator()
        for i in 0..<9 {
            nav.select(i)
            nav.view.layoutSubtreeIfNeeded()
            let field = try #require(nav.filter as? NavigatorFilterField)
            #expect((field.cell as? NSSearchFieldCell)?.searchButtonCell == nil, "no magnifier")
            let f = field.frame
            let options = nav.filterOptions.alignmentRect(forFrame: nav.filterOptions.frame)
            #expect(f.contains(options), "navigator \(i): options \(options) inside \(f)")
            #expect(options.minX - f.minX <= 4, "navigator \(i): at the leading end")
            let text = field.rectForSearchText(whenCentered: false).offsetBy(dx: f.minX, dy: f.minY)
            #expect(text.minX >= options.maxX - 0.5, "navigator \(i): text after the options")
            let shown = nav.toggleButtons.filter { !$0.isHidden }
            #expect(shown.count == NavigatorBars.specs[i].toggles.count)
            for b in shown {
                let r = b.convert(b.bounds, to: nav.view)
                #expect(f.insetBy(dx: -0.5, dy: -0.5).contains(r), "navigator \(i): toggle \(r) inside \(f)")
                #expect(text.maxX <= r.minX + 0.5, "navigator \(i): text before the toggles")
            }
            if let last = shown.last {
                #expect(f.maxX - last.convert(last.bounds, to: nav.view).maxX <= 6, "navigator \(i): toggles at the trailing end")
            }
            #expect(nav.filterOptions.item(at: 0)?.image === NavigatorFilterField.optionsGlyph)
        }
    }

    @Test func selectorTabsKeepTheirTitles() {
        let nav = laidOutNavigator()
        for i in 0..<9 {
            nav.select(i)
            #expect(nav.selectorButtons.map { $0.accessibilityTitle() ?? "" } == CommandTable.navigators, "with \(i) selected")
            #expect(nav.selectorButtons[i].state == .on && nav.selectorButtons[i].alternateImage != nil)
        }
    }

    // MARK: I1–I3 — inspectors

    func inspector(_ info: FileInspectorInfo) -> InspectorAreaController {
        _ = NSApplication.shared
        let i = InspectorAreaController()
        i.view.frame = NSRect(x: 0, y: 0, width: 260, height: 700)
        i.fileInfo = { _ in info }
        return i
    }

    func descendants(_ v: NSView) -> [NSView] { v.subviews + v.subviews.flatMap(descendants) }

    @Test func fileInspectorRulesLocationAndMembershipTable() throws {
        let file = URL(fileURLWithPath: "/tmp/r45/App/Model.swift")
        let targets = [TargetMembership(targetID: "T1", name: "App", isMember: true, isEditable: true),
                       TargetMembership(targetID: "T2", name: "AppTests", isMember: false, isEditable: true)]
        // A file reference (not in a synchronized folder).
        let i = inspector(FileInspectorInfo(memberships: targets))
        i.show(file: file)
        i.select(0)
        #expect(i.sectionTitles == ["Identity and Type", "On Demand Resource Tags", "Target Membership", "Text Settings"])
        #expect(i.sectionRuleCount == 3, "a rule between each two sections")
        let location = try #require(i.fileControls["Location"] as? NSPopUpButton)
        let choose = try #require(i.fileControls["Choose Location"] as? NSButton)
        #expect(location.isEnabled && choose.isEnabled && !choose.isHidden)
        // The membership table: bordered, the rows and the three buttons inside.
        let table = try #require(i.fileControls["Target Membership Table"])
        #expect((table.layer?.borderWidth ?? 0) > 0)
        let inside = descendants(table)
        let add = try #require(i.fileControls["Add Target"] as? NSButton)
        let remove = try #require(i.fileControls["Remove Target"] as? NSButton)
        let pencil = try #require(i.fileControls["Edit Target Membership"] as? NSButton)
        #expect([add, remove, pencil].allSatisfy { b in inside.contains { $0 === b } })
        #expect(add.isEnabled && add.toolTip == "Choose which targets include this file")
        #expect(remove.toolTip == "Remove this file from selected targets")
        #expect(pencil.toolTip == "Edit target membership options" && !pencil.isEnabled)
        let labels = inside.compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(labels.contains("App") && labels.contains("Default") && !labels.contains("AppTests"))
        // The buttons sit on the table's bottom edge.
        i.view.layoutSubtreeIfNeeded()
        let bottom = add.convert(add.bounds, to: table)
        #expect(table.isFlipped ? table.bounds.maxY - bottom.maxY < 8 : bottom.minY < 8, "\(bottom) in \(table.bounds)")
        // "+" stays enabled when every target has the file; its menu says so.
        let all = inspector(FileInspectorInfo(memberships: targets.map { var t = $0; t.isMember = true; return t }))
        all.show(file: file)
        all.select(0)
        #expect((all.fileControls["Add Target"] as? NSButton)?.isEnabled == true)
        #expect(all.addMembershipMenu().items.map(\.title) == ["No Other Targets"])

        // In a synchronized folder: the location is a disabled pop-up, no folder button.
        let synced = inspector(FileInspectorInfo(memberships: targets, inSynchronizedFolder: true))
        synced.show(file: file)
        synced.select(0)
        #expect((synced.fileControls["Location"] as? NSPopUpButton)?.isEnabled == false)
        #expect((synced.fileControls["Choose Location"] as? NSButton)?.isHidden == true)

        // A package's file: Identity and Type and Text Settings only.
        let pkg = inspector(FileInspectorInfo(memberships: [targets[0]], isPackageFile: true))
        pkg.show(file: file)
        pkg.select(0)
        #expect(pkg.sectionTitles == ["Identity and Type", "Text Settings"] && pkg.sectionRuleCount == 1)
    }

    @Test func windowReportsSynchronizedFoldersAndPackageFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("r45-i1-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: dir) }
        let proj = dir.appendingPathComponent("App.xcodeproj")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("App"), withIntermediateDirectories: true)
        try "".write(to: dir.appendingPathComponent("App/Main.swift"), atomically: true, encoding: .utf8)
        try "".write(to: dir.appendingPathComponent("Loose.swift"), atomically: true, encoding: .utf8)
        try """
        // !$*UTF8*$!
        {
        \tarchiveVersion = 1;
        \tclasses = {
        \t};
        \tobjectVersion = 77;
        \tobjects = {
        \t\tAA0000000000000000000001 = {isa = PBXProject; mainGroup = AA0000000000000000000002; targets = (AA0000000000000000000004, ); };
        \t\tAA0000000000000000000002 = {isa = PBXGroup; children = (AA0000000000000000000003, AA0000000000000000000006, ); sourceTree = "<group>"; };
        \t\tAA0000000000000000000003 = {isa = PBXFileSystemSynchronizedRootGroup; path = App; sourceTree = "<group>"; };
        \t\tAA0000000000000000000006 = {isa = PBXFileReference; path = Loose.swift; sourceTree = "<group>"; };
        \t\tAA0000000000000000000004 = {isa = PBXNativeTarget; buildPhases = (); fileSystemSynchronizedGroups = (AA0000000000000000000003, ); name = App; };
        \t};
        \trootObject = AA0000000000000000000001;
        }
        """.write(to: proj.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
        let wc = try WindowChromeR32Tests().window(proj)
        let synced = wc.fileInspectorInfo(dir.appendingPathComponent("App/Main.swift"))
        #expect(synced.inSynchronizedFolder && !synced.isPackageFile)
        #expect(!wc.fileInspectorInfo(dir.appendingPathComponent("Loose.swift")).inSynchronizedFolder)
        let pkg = try WindowChromeR32Tests().package("r45")
        defer { try? FileManager.default.removeItem(at: pkg) }
        let pwc = try WindowChromeR32Tests().window(pkg)
        let pinfo = pwc.fileInspectorInfo(pkg.appendingPathComponent("Sources/Chrome/Model.swift"))
        #expect(pinfo.isPackageFile && !pinfo.inSynchronizedFolder)
    }

    @Test func historyRowsAndQuickHelpPlaceholder() async throws {
        let i = inspector(FileInspectorInfo())
        let file = URL(fileURLWithPath: "/tmp/r45/Model.swift")
        let commit = GitRepository.Commit(hash: "0123456789abcdef0123456789abcdef01234567", authorName: "Grace Hopper", authorEmail: "g@example.com",
                                          date: Date(), subject: "Bump the value", body: "", branches: [], tags: [], signature: "N")
        i.historyProvider = { _ in [commit] }
        i.show(file: file)
        i.select(1)
        await i.historyIdle()   // read in the background
        #expect(i.historyRows.map(\.hash) == ["0123456"])
        let row = try #require(i.historyRowViews.first)
        let left = row.left.arrangedSubviews.compactMap { $0 as? NSTextField }
        let right = row.right.arrangedSubviews.compactMap { $0 as? NSTextField }
        #expect(left.map(\.stringValue) == ["Grace Hopper", "Bump the value"])
        #expect(left[0].font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(right.map(\.stringValue) == ["0123456", "Today"])
        i.view.layoutSubtreeIfNeeded()
        let l = row.left.convert(row.left.bounds, to: i.view), r = row.right.convert(row.right.bounds, to: i.view)
        #expect(l.maxX <= r.minX && r.maxX > i.view.bounds.width - 24)

        // Quick Help with nothing at the caret: centered, then a rule.
        i.showQuickHelp(nil)
        i.select(2)
        i.view.layoutSubtreeIfNeeded()
        let none = try #require(i.fileControls["No Quick Help"])
        let search = try #require(i.fileControls["Search Documentation"])
        for v in [none, search] {
            let f = v.convert(v.bounds, to: i.view)
            #expect(abs(f.midX - i.view.bounds.midX) <= 1, "\(f) centered in \(i.view.bounds)")
        }
        #expect(i.sectionRuleCount == 1)
    }

    // MARK: D1 — debug area

    @Test func consoleHasNoKindPopUpAndAnInputLineOnlyWhileDebugging() {
        _ = NSApplication.shared
        let d = DebugAreaController()
        _ = d.view
        #expect(!d.consoleBarTitles.contains("Filter options"))
        #expect(d.consoleBarStack?.arrangedSubviews.contains { $0 is NSPopUpButton } == false)
        // Idle: a plain transcript; the command line comes with a session.
        #expect(!d.isConsoleInputShown)
        d.setDebugging(true)
        #expect(d.isConsoleInputShown)
        d.setDebugging(false)
        #expect(!d.isConsoleInputShown)
        // The output toggles still filter the console.
        d.debuggerOutputToggle.state = .off
        d.debuggerOutputToggle.sendAction(d.debuggerOutputToggle.action, to: d.debuggerOutputToggle.target)
        #expect(d.consoleFilter == .target)
        #expect(DebugPresentation.sessionEndedLine(code: 9, reason: "killed") == "Debug session ended with code 9: killed")
        #expect(DebugPresentation.killedLine == "Debug session ended with code 9: killed")
    }

    // MARK: W5, W6 — Welcome window

    @Test func welcomeGeometry() throws {
        _ = NSApplication.shared
        let td = TestDefaults("r45-welcome")
        defer { td.remove() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("r45-w5-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pkg = dir.appendingPathComponent("Pkg")
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try "".write(to: pkg.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let recents = RecentProjects(defaults: td.defaults)
        recents.note(pkg)
        let w = WelcomeWindowController(recents: recents)
        let win = try #require(w.window)
        let content = try #require(win.contentView)
        content.layoutSubtreeIfNeeded()
        #expect(win.frame.size == NSSize(width: 480, height: 632))
        let h = content.bounds.height
        // No traffic lights; a round 36 × 36 close button at (20, 20).
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            #expect(win.standardWindowButton(b)?.isHidden ?? true)
        }
        let close = w.closeButton.frame
        #expect(close.size == NSSize(width: 36, height: 36) && close.minX == 20 && h - close.maxY == 20, "\(close)")
        // Round: a circular glass button with the Liquid Glass design
        // (liquid-glass-ycode.md §4), a drawn circle before it.
        if #available(macOS 26, *) {
            #expect(w.closeButton.bezelStyle == .glass && w.closeButton.borderShape == .circle && w.closeButton.isBordered)
        } else {
            #expect(w.closeButton.layer?.cornerRadius == 18)
        }
        #expect(w.closeButton.accessibilityTitle() == "Close")
        // The buttons row: 107, 107, 130 wide, 36 tall, 8 apart, centered, top at 242.
        let frames = [w.openButton, w.cloneButton, w.newProjectButton].map { b in
            b.alignmentRect(forFrame: b.convert(b.bounds, to: content))
        }
        #expect(frames.map { $0.width.rounded() } == [107, 107, 130], "\(frames)")
        #expect(frames.allSatisfy { $0.height.rounded() == 36 }, "\(frames)")
        #expect((frames[1].minX - frames[0].maxX).rounded() == 8 && (frames[2].minX - frames[1].maxX).rounded() == 8)
        #expect(abs((frames[0].minX + frames[2].maxX) / 2 - content.bounds.midX) <= 0.5)
        #expect(frames.allSatisfy { abs(h - $0.maxY - 242) <= 0.5 }, "\(frames.map { h - $0.maxY })")
        // The recent list: a rounded inset box, no heading, no fixed scroller.
        #expect((w.recentsBox.layer?.cornerRadius ?? 0) > 0)
        #expect(w.recentsScroll.autohidesScrollers && w.recentsScroll.scrollerStyle == .overlay)
        let labels = content.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(!labels.contains("Recent Projects") && w.table.accessibilityLabel() == "Recent Projects")
        // A package row has the package glyph.
        let cell = try #require(w.tableView(w.table, viewFor: nil, row: 0) as? NSTableCellView)
        #expect(cell.imageView?.image?.accessibilityDescription == "Package")
        #expect(WelcomeWindowController.isPackage(pkg) && !WelcomeWindowController.isPackage(dir.appendingPathComponent("A.xcodeproj")))
    }

    @Test func newProjectAppCreatesAnUntitledMultiplatformProject() throws {
        _ = NSApplication.shared
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("r45-w6-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let td = TestDefaults("r45-w6")
        defer { td.remove() }
        let w = WelcomeWindowController(recents: RecentProjects(defaults: td.defaults))
        w.untitledProjectsLocation = base
        var opened: [UntitledAppProject.Created] = []
        w.openUntitled = { c, done in opened.append(c); done(true) }
        // App: no sheet; the project is made and opened at once.
        let app = try #require(w.newProjectButton.menu?.items.first { $0.title == "App" })
        #expect(w.newProjectChosen(app) == nil)
        let created = try #require(opened.first)
        let root = base.appendingPathComponent("Untitled Project")
        #expect(created.project.path == root.appendingPathComponent("MyApp.xcodeproj").path)
        #expect(created.entryFile.path == root.appendingPathComponent("MyApp/MyApp.swift").path)
        for f in ["MyApp/MyApp.swift", "MyApp/ContentView.swift", "MyApp/Assets.xcassets/Contents.json"] {
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(f).path), "\(f)")
        }
        let view = try String(contentsOf: root.appendingPathComponent("MyApp/ContentView.swift"), encoding: .utf8)
        #expect(view.contains("struct ContentView: View") && view.contains("#Preview"))
        #expect(try String(contentsOf: created.entryFile, encoding: .utf8).contains("@main"))
        // A second App goes next to it.
        _ = w.createUntitledApp()
        #expect(opened.last?.project.path == base.appendingPathComponent("Untitled Project 2/MyApp.xcodeproj").path)

        // The project: one app target in a synchronized folder, multiplatform settings.
        let proj = try PBXProj(contentsOf: created.project.appendingPathComponent("project.pbxproj"))
        #expect(proj.targets.map { $0.string("name") } == ["MyApp"])
        let folder = try #require(proj.objects.values.first { $0.isa == "PBXFileSystemSynchronizedRootGroup" })
        #expect(folder.string("path") == "MyApp" && proj.targets[0].references("fileSystemSynchronizedGroups") == [folder.id])
        let settings = try #require(proj.buildConfigurations(listID: proj.targets[0].string("buildConfigurationList")).first?.attributes["buildSettings"]?.dictionary)
        #expect(settings["SDKROOT"]?.string == "auto")
        #expect(Set((settings["SUPPORTED_PLATFORMS"]?.string ?? "").split(separator: " ")) == ["iphoneos", "iphonesimulator", "macosx", "xros", "xrsimulator"])
        #expect(settings["TARGETED_DEVICE_FAMILY"]?.string == "1,2,7")
        for k in ["IPHONEOS_DEPLOYMENT_TARGET", "MACOSX_DEPLOYMENT_TARGET", "XROS_DEPLOYMENT_TARGET"] { #expect(settings[k]?.string == "27.0", "\(k)") }
        #expect(settings["PRODUCT_BUNDLE_IDENTIFIER"]?.string == "com.example.MyApp" && settings["DEVELOPMENT_TEAM"] == nil)

        // The window: MyApp.swift in the editor, the inspector hidden.
        let wc = try WindowChromeR32Tests().window(created.project)
        #expect(wc.session.scheme == "MyApp")
        wc.showUntitledProject(entryFile: created.entryFile)
        #expect(wc.editor.fileURL?.standardizedFileURL.path == created.entryFile.standardizedFileURL.path)
        #expect(wc.inspectorItem.isCollapsed)
        if wc.session.model.destinations.contains(where: { $0.kind == .mac }) { #expect(wc.session.destination?.kind == .mac) }
        // The navigator lists the synchronized folder's files.
        let tree = wc.navigator.rows(0).first
        #expect(tree?.children.first?.title == "MyApp")
        // The other rows keep the sheet.
        let tool = try #require(w.newProjectButton.menu?.items.first { $0.title == "Command Line Tool" })
        let sheet = w.newProjectChosen(tool)
        #expect(sheet != nil)
    }

    // MARK: T10 — no notices slot

    @Test func toolbarHasNoNoticesPlaceholder() throws {
        let dir = try WindowChromeR32Tests().package("r45-t10")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wc = try WindowChromeR32Tests().window(dir)
        let ids = wc.toolbarDefaultItemIdentifiers(NSToolbar())
        let items = ids.filter { !WorkspaceWindowController.toolbarSpacers.contains($0) }.map(\.rawValue)
        // §2.1 items 1–7 and 9–11 (item 9's two pull-downs are two toolbar
        // items); item 8 (the notices button) is left out.
        #expect(items.count == 11, "\(items)")
        #expect(!items.contains { $0.localizedCaseInsensitiveContains("notice") || $0.localizedCaseInsensitiveContains("cloud") })
        #expect(wc.toolbarAllowedItemIdentifiers(NSToolbar()).filter { !WorkspaceWindowController.toolbarSpacers.contains($0) }.count == 11)
    }
}
