import AppKit
import Foundation
import Testing
import YcodeBuild
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// reference-ui-6.md rounds R39 (toolbar layout and activity view, §2–§3)
/// and R41 (Issue navigator grouping and merging, §5.1–§5.2).
@MainActor
@Suite(.serialized) struct ToolbarIssuesR39R41Tests {
    func scratch(_ name: String) -> URL {
        ycodeDir.appendingPathComponent(".build-ide/r39/\(name)-\(UUID().uuidString)")
    }

    func window(_ session: WorkspaceSession) -> WorkspaceWindowController {
        _ = NSApplication.shared
        let wc = WorkspaceWindowController(session: session, loadDestinations: false, startLanguageService: false)
        wc.window?.appearance = NSAppearance(named: .aqua)
        wc.applyDefaultLayout()
        return wc
    }

    // MARK: R41

    /// N1 + N2 acceptance in a project window: one warning reported by the
    /// build and by the language service shows once, under its target and
    /// file, capitalized; the capsule counts it once.
    @Test func issueNavigatorGroupsByTargetAndMergesCopies() throws {
        let dir = scratch("n1")
        defer { try? FileManager.default.removeItem(at: dir) }
        let proj = try writeToolProject(at: dir)
        let session = WorkspaceSession(model: try WorkspaceModel(url: proj))
        let wc = window(session)
        let greeter = proj.deletingLastPathComponent().appendingPathComponent("Tool/Greeter.swift").path
        let build = Diagnostic(severity: .warning, message: "initialization of immutable value 'unused' was never used",
                               location: .init(file: greeter, line: 2, column: 9))
        session.issues = [build]
        session.notify(.issues)
        #expect(session.displayedIssues.map(\.message) == ["Initialization of immutable value 'unused' was never used"])
        // The grouping knows the project's targets.
        let g = session.issueGrouping
        #expect(g.projectName == "Tool" && g.targetOrder == ["Tool"] && g.targetsOfFile(greeter) == ["Tool"])
        #expect(g.targetsOfFile(proj.deletingLastPathComponent().appendingPathComponent("Elsewhere.swift").path).isEmpty)
        let rows = wc.navigator.rows(4)
        #expect(rows.map(\.title) == ["Tool"] && rows.first?.detail == "1 issue")
        #expect(rows.first?.children.map(\.title) == ["Greeter"])
        #expect(rows.first?.children.first?.children.map(\.title) == ["Initialization of immutable value 'unused' was never used"])
        #expect(wc.issueCapsule.warnings == 1 && wc.issueCapsule.errors == 0)
        // §5.2.2: the build's issues stand for the file until it is edited.
        #expect(session.liveIssuesHiddenFiles == [IssueMerge.canonicalPath(greeter)])
        session.noteFileEdited(greeter)
        #expect(session.liveIssuesHiddenFiles.isEmpty)
    }

    /// Package workspaces group by the package's targets (§5.1).
    @Test func packageIssuesGroupByPackageTarget() throws {
        let dir = scratch("n1-pkg")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        for t in ["Sources/Kit", "Sources/Tool", "Tests/KitTests"] {
            try fm.createDirectory(at: dir.appendingPathComponent(t), withIntermediateDirectories: true)
        }
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"Kit\")\n"
            .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let session = WorkspaceSession(model: try WorkspaceModel(url: dir))
        let g = session.issueGrouping
        #expect(g.projectName == dir.lastPathComponent && g.targetOrder == ["Kit", "Tool", "KitTests"])
        #expect(g.targetsOfFile(dir.appendingPathComponent("Tests/KitTests/KitTests.swift").path) == ["KitTests"])
        #expect(g.targetsOfFile(dir.appendingPathComponent("Package.swift").path).isEmpty)
    }

    // MARK: R39

    /// A build engine that plays a fixed list of events.
    struct ScriptedEngine: BuildEngine {
        let events: [BuildEvent]
        var name: String { "scripted" }
        func start(_ request: BuildRequest) -> BuildOperation {
            let (s, c) = AsyncStream<BuildEvent>.makeStream()
            for e in events { c.yield(e) }
            c.yield(.finished(BuildResult(status: .succeeded, exitCode: 0, issues: [])))
            c.finish()
            return BuildOperation(events: s, cancel: {})
        }
    }

    /// T4 (§3.1, §3.2): "Build", then "Building • Planning deferred
    /// tasks", then "Building • n/m"; the spinner replaces the icon while
    /// it runs; long subtitles truncate in the middle.
    @Test func activityViewShowsBuildProgressWithSpinner() async throws {
        let dir = scratch("t4")
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = WorkspaceSession(model: try WorkspaceModel(url: try writeToolProject(at: dir)))
        let wc = window(session)
        var seen: [String] = []
        var spinning: [Bool] = []
        session.observe { change in
            guard change == .activity, case .building(let s) = session.activity else { return }
            seen.append(s)
            spinning.append(wc.activityView.showsSpinner)
        }
        session.engine = ScriptedEngine(events: [.planning, .activity("Compile main.swift"), .progress(done: 0, total: 3),
                                                 .activity("Compile Greeter.swift"), .progress(done: 2, total: 3), .progress(done: 3, total: 4)])
        let result = await session.build(.build)
        #expect(result.status == .succeeded)
        #expect(seen == ["Build", "Building \u{2022} Planning deferred tasks", "Building \u{2022} 0/3", "Building \u{2022} 2/3", "Building \u{2022} 3/4"])
        #expect(spinning.dropFirst().allSatisfy { $0 })
        #expect(!wc.activityView.showsSpinner && wc.activityView.status.hasPrefix("Build Succeeded \u{2022} Today at "))
        // Middle truncation.
        let long = "Finished running MyApp on iPhone 18 Pro Max"
        let short = ActivityView.truncatedStatus(long, width: 120)
        #expect(short.contains("\u{2026}") && short.first == "F" && short.hasSuffix("x"))
        #expect(ActivityView.truncatedStatus("Build", width: 120) == "Build")
    }

    /// T6 (§2.1), T7 (§2.5), T9 (§2.3): accessibility titles, the
    /// state-dependent toggle titles, and the issue capsule's buttons.
    @Test func toolbarTitlesAndIssueCapsuleButtons() throws {
        let dir = scratch("t6")
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = WorkspaceSession(model: try WorkspaceModel(url: try writeToolProject(at: dir)))
        let wc = window(session)
        let ids = wc.toolbarDefaultItemIdentifiers(NSToolbar()).map(\.rawValue)
        #expect(!ids.contains("account") && ids.last == "inspectorToggle")
        // liquid-glass.md §2.2: Show Inspector sits at the far right of the
        // inspector's section (a flexible space before it).
        #expect(Array(ids.suffix(6)) == ["addEditor", "editorOptions", "editorModes", "NSToolbarInspectorTrackingSeparatorItemIdentifier",
                                         "NSToolbarFlexibleSpaceItem", "inspectorToggle"])
        let add = try #require(wc.toolbar(NSToolbar(), itemForItemIdentifier: .init("addEditor"), willBeInsertedIntoToolbar: false))
        let opts = try #require(wc.toolbar(NSToolbar(), itemForItemIdentifier: .init("editorOptions"), willBeInsertedIntoToolbar: false))
        #expect(add.label == "Add Editor" && add.toolTip == "Add Editor Tabs or Editor Panes")
        #expect(opts.label == "Editor Options" && opts.toolTip == "Adjust Editor Options")
        #expect(wc.schemePopUp.accessibilityTitle() == "Active Scheme" && wc.destinationPopUp.accessibilityTitle() == "Active Run Destination")
        // T7: the inspector toggle and the debug-area toggle follow their state.
        #expect(wc.inspectorToggleItemTitle == "Hide Inspector")
        wc.inspectorItem.isCollapsed = true
        #expect(wc.inspectorToggleItemTitle == "Show Inspector")
        let toggle = try #require(wc.debugArea.debugAreaToggle)
        #expect(toggle.toolTip == "show debug area" && toggle.accessibilityTitle() == "show debug area")
        wc.showDebugArea(true)
        #expect(toggle.toolTip == "hide debug area" && toggle.accessibilityTitle() == "hide debug area")
        // T9: an errors and an issues button; zero counts left out; each
        // opens the Issue navigator.
        let cap = wc.issueCapsule
        cap.errors = 0; cap.warnings = 2
        #expect(cap.buttons.map { $0.accessibilityTitle() ?? "" } == ["Errors", "Issues", "Test Failures"])
        #expect(cap.buttons.map(\.isHidden) == [true, false, true] && cap.buttons[1].title == "2")
        wc.navigator.select(0)
        cap.buttons[1].performClick(nil)
        #expect(wc.navigator.selectedIndex == 4 && wc.shownLeftPane == .navigators)
    }

    /// T2 (§2.4.1): the destination pop-up shows the name only and is as
    /// wide as that title; the version is in the open menu's rows.
    @Test func destinationPopUpShowsTheNameOnly() throws {
        let dir = scratch("t2")
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = WorkspaceSession(model: try WorkspaceModel(url: try writeToolProject(at: dir)))
        let wc = window(session)
        let sim = Destination(name: "iPhone 18 Pro", specifier: "platform=iOS Simulator,id=S1", platform: "iOS", kind: .simulator,
                              osVersion: "27.0", identifier: "S1")
        let wide = Destination(name: "iPad Pro 13-inch (M5) with a long name", specifier: "platform=iOS Simulator,id=S2", platform: "iOS",
                               kind: .simulator, osVersion: "27.0", identifier: "S2")
        wc.setDestinationGroups(DestinationCatalog.groups(devices: [], simulators: [sim, wide]))
        session.destination = sim
        wc.rebuildDestinationMenu()
        let popUp = wc.destinationPopUp
        #expect(wc.destinationTitle == "iPhone 18 Pro")
        let row = try #require(popUp.selectedItem)
        #expect(row.attributedTitle == nil)
        let width = popUp.intrinsicContentSize.width
        #expect(width < 160)
        let probe = NSPopUpButton(frame: .zero, pullsDown: false)
        probe.isBordered = false
        probe.controlSize = .small
        probe.addItem(withTitle: wide.name)
        #expect(width < probe.intrinsicContentSize.width)
        // While open, the rows carry their versions; closed, the names.
        let menu = try #require(popUp.menu)
        menu.delegate?.menuNeedsUpdate?(menu)
        #expect(row.attributedTitle?.string == "iPhone 18 Pro\t27.0")
        menu.delegate?.menuDidClose?(menu)
        #expect(row.attributedTitle == nil && popUp.titleOfSelectedItem == "iPhone 18 Pro")
    }

    /// T1 (§2.2): the right group never overflows. With a long scheme
    /// name, the issue capsule and a finished build, the editor modes fold
    /// first, then the scheme name shortens, then the subtitle; Show
    /// Inspector stays at the far right; a wider window undoes it.
    /// With the full-height inspector of liquid-glass.md §2.1 the editor's
    /// section is the window less both side areas: down to 1250 points
    /// everything fits; narrower, only the low-priority items (Back |
    /// Forward, the activity view, New Conversation) overflow, as §2.2
    /// allows once every step is taken.
    @Test func toolbarRightGroupNeverOverflows() throws {
        let dir = scratch("t1")
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = WorkspaceSession(model: try WorkspaceModel(url: try writeToolProject(at: dir)))
        let wc = window(session)
        let sim = Destination(name: "iPhone 18 Pro Max", specifier: "platform=iOS Simulator,id=S1", platform: "iOS", kind: .simulator,
                              osVersion: "27.0", identifier: "S1")
        wc.setDestinationGroups(DestinationCatalog.groups(devices: [], simulators: [sim]))
        session.destination = sim
        wc.rebuildDestinationMenu()
        wc.schemePopUp.removeAllItems()
        wc.schemePopUp.addItem(withTitle: "A Rather Long Scheme Name For Testing")
        wc.issueCapsule.errors = 1
        wc.issueCapsule.warnings = 2
        wc.activityView.status = "Build Succeeded \u{2022} Today at 1:17 PM"
        let window = try #require(wc.window)
        var fits: [Int: ToolbarFit] = [:]
        for w in [1600, 1400, 1250, 1150, 1050, 2000] {
            window.setFrame(NSRect(x: 0, y: 0, width: CGFloat(w), height: 900), display: false)
            wc.fitToolbar()
            if w >= 1250 {
                #expect(wc.overflowedToolbarItems.isEmpty, "overflow at \(w): \(wc.overflowedToolbarItems)")
            } else {
                #expect(Set(wc.overflowedToolbarItems).isSubset(of: ["history", "activity", "newConversation"]), "overflow at \(w): \(wc.overflowedToolbarItems)")
            }
            let visible = (window.toolbar?.visibleItems ?? []).map(\.itemIdentifier.rawValue)
            #expect(visible.last == "inspectorToggle")
            #expect(Set(["addEditor", "editorOptions", "editorModes", "scheme", "issues"]).isSubset(of: Set(visible)))
            fits[w] = wc.toolbarFit
        }
        #expect(fits[2000] == ToolbarFit())
        #expect(fits[1050]?.editorModesCollapsed == true && fits[1050]?.schemeWidth != nil)
        // Monotone: a narrower window never has less collapsed.
        let order = [1600, 1400, 1250, 1150, 1050].compactMap { fits[$0] }
        let steps = ToolbarFit.steps(schemeNatural: wc.schemeNaturalWidth, activityNatural: wc.activityView.naturalWidth)
        let ranks = order.compactMap { steps.firstIndex(of: $0) }
        #expect(ranks.count == order.count && ranks == ranks.sorted())
        // The collapsed pull-down lists the three modes.
        let pull = wc.toolbarControls.editorModesPullDown
        #expect(pull.itemTitles.dropFirst() == ["Canvas", "Assistant", "Code Review"])
    }

    @Test func toolbarFitSteps() {
        let steps = ToolbarFit.steps(schemeNatural: 200, activityNatural: 150)
        #expect(steps.first == ToolbarFit() && steps[1] == ToolbarFit(editorModesCollapsed: true))
        let schemeCaps = steps.compactMap(\.schemeWidth)
        #expect(!schemeCaps.isEmpty && schemeCaps.first! < 200 && schemeCaps.last == ToolbarFit.schemeMinimum)
        #expect(schemeCaps == schemeCaps.sorted(by: >))
        #expect(steps.last?.activityWidth == ToolbarFit.activityMinimum && steps.last?.schemeWidth == ToolbarFit.schemeMinimum)
        // Activity caps only after the scheme reached its minimum.
        #expect(steps.filter { $0.activityWidth != nil }.allSatisfy { $0.schemeWidth == ToolbarFit.schemeMinimum })
        #expect(ToolbarFit.steps(schemeNatural: 40, activityNatural: 60) == [ToolbarFit(), ToolbarFit(editorModesCollapsed: true)])
    }
}
