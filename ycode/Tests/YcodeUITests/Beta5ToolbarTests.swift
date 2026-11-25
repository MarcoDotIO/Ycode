import AppKit
import Foundation
import Testing
import YcodeBuild
@testable import YcodeIDECore
@testable import YcodeUI

/// B5-TOOLBAR (beta 5): the toolbar at narrow widths (P-025), Run's
/// press-and-hold menu (P-028), the title area while building (P-029) and
/// Stop's enabled state (P-204). Offscreen: the windows never reach a
/// display and no menu is opened.
@MainActor
@Suite(.serialized) struct Beta5ToolbarTests {
    let r39 = ToolbarIssuesR39R41Tests()

    func window(_ tag: String) throws -> (WorkspaceWindowController, WorkspaceSession, URL) {
        let dir = r39.scratch("b5-toolbar-\(tag)")
        let session = WorkspaceSession(model: try WorkspaceModel(url: try writeToolProject(at: dir)))
        let wc = r39.window(session)
        return (wc, session, dir)
    }

    func pump(_ s: Double = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    func setWidth(_ wc: WorkspaceWindowController, _ w: CGFloat) {
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: w, height: 880), display: false)
        wc.fitToolbar()
        wc.window?.contentView?.superview?.layoutSubtreeIfNeeded()
    }

    func visible(_ wc: WorkspaceWindowController) -> [String] {
        (wc.window?.toolbar?.visibleItems ?? []).map(\.itemIdentifier.rawValue).filter { ToolbarOverflow.Item(rawValue: $0) != nil }
    }

    // MARK: P-025 — which items stay

    /// As the window narrows the right group goes into "»" before the title
    /// area and Back | Forward, and Navigators and Run | Stop stay longest
    /// (`ToolbarOverflow.rank`). At about 817 points the reference keeps
    /// Navigators, Run | Stop, Back | Forward and the title.
    @Test func narrowToolbarKeepsTheTitleAndHistory() throws {
        let (wc, _, dir) = try window("narrow")
        defer { try? FileManager.default.removeItem(at: dir); wc.window?.orderOut(nil) }
        wc.issueCapsule.errors = 1
        wc.activityView.status = "Build Succeeded \u{2022} Today at 1:17 PM"
        var seen: [Int: [String]] = [:]
        for w in [1400, 1100, 1000, 900, 825, 817, 760, 700] {
            setWidth(wc, CGFloat(w))
            let out = wc.overflowedToolbarItems
            seen[w] = out
            print("B5 toolbar \(w): visible \(visible(wc)) overflow \(out) fit \(wc.toolbarFit)")
            // The ranks hold: nothing of higher rank is out while something
            // of lower rank is in. Navigators and Run | Stop follow the
            // navigator's width below 850 (P-024, `window-layout.md` §4),
            // not the ranks.
            let section: Set<String> = wc.navigator.view.frame.width < 289 ? ["leftPanes", "run"] : []
            let outRanks = out.filter { !section.contains($0) }.compactMap(ToolbarOverflow.Item.init(rawValue:)).map(ToolbarOverflow.rank)
            let inRanks = visible(wc).filter { !section.contains($0) }.compactMap(ToolbarOverflow.Item.init(rawValue:)).map(ToolbarOverflow.rank)
            if let maxOut = outRanks.max(), let minIn = inRanks.min() {
                #expect(maxOut <= minIn, "at \(w): out \(out), visible \(visible(wc))")
            }
            #expect(visible(wc).last == "inspectorToggle")
        }
        // Council round 12 (`window-layout.md` §2.4): at 817 with both
        // side areas hidden "»" holds Editor Options and Editor Mode (and
        // the reference's cloud notices, not in Ycode); Navigators, Run |
        // Stop, Back | Forward and the title stay.
        wc.setLeftPane(codingAssistant: false)
        wc.inspectorItem.isCollapsed = true
        setWidth(wc, 817)
        #expect(Set(wc.overflowedToolbarItems) == ["editorOptions", "editorModes"], "\(wc.overflowedToolbarItems)")
        #expect(Set(visible(wc)).isSuperset(of: ["leftPanes", "run", "history", "activity", "addEditor"]), "\(visible(wc))")
        _ = seen
        // Wide again: everything back.
        setWidth(wc, 1600)
        #expect(wc.overflowedToolbarItems.isEmpty)
    }

    /// At every width from 1400 down to 700 the AppKit toolbar's "»" holds
    /// a leading part of `ToolbarOverflow.leavingOrder` (the order the
    /// Linux shell takes items in): never an item while one that leaves
    /// before it is still shown. (Several can leave at one width.)
    @Test func itemsLeaveInTheSharedOrder() throws {
        let (wc, _, dir) = try window("order")
        defer { try? FileManager.default.removeItem(at: dir); wc.window?.orderOut(nil) }
        wc.issueCapsule.errors = 1
        let order = ToolbarOverflow.leavingOrder.map(\.rawValue)
        var w: CGFloat = 1400
        var widths = 0
        while w >= 700 {
            setWidth(wc, w)
            // Navigators and Run | Stop follow the navigator's width below
            // 850 (P-024), not the shared order.
            let section: Set<String> = wc.navigator.view.frame.width < 289 ? ["leftPanes", "run"] : []
            let out = Set(wc.overflowedToolbarItems).subtracting(section)
            let order = order.filter { !section.contains($0) }
            let prefix = Set(order.prefix(out.count))
            #expect(out == prefix, "at \(w): out \(out.sorted()), expected \(prefix.sorted())")
            if !out.isEmpty { widths += 1 }
            w -= 10
        }
        #expect(widths > 0)
    }

    /// Every item's "»" entry has its glyph (not the scheme's); items with a
    /// menu, segments or counts open a sub-menu (Navigators, Run,
    /// Back/Forward, Scheme, Issues, Add Editor, Editor Options, Editor
    /// Mode; `window-layout.md` §2.1).
    @Test func overflowEntriesHaveGlyphsAndSubmenus() throws {
        let (wc, _, dir) = try window("menu")
        defer { try? FileManager.default.removeItem(at: dir); wc.window?.orderOut(nil) }
        wc.issueCapsule.warnings = 2
        setWidth(wc, 760)
        wc.updateOverflowMenuForms()
        for item in wc.window?.toolbar?.items ?? [] {
            guard let i = ToolbarOverflow.Item(rawValue: item.itemIdentifier.rawValue), i != .inspectorToggle else { continue }
            let form = try #require(item.menuFormRepresentation, "\(i)")
            let entry = ToolbarOverflow.entry(i)
            // Every entry has its toolbar glyph but the scheme's (as the reference's).
            #expect((form.image != nil) == (i != .scheme), "\(i) glyph \(form.image != nil)")
            #expect((form.submenu != nil) == entry.hasSubmenu, "\(i): submenu \(form.submenu?.items.map(\.title) ?? [])")
            #expect(form.title == entry.title)
            print("B5 overflow entry \(i): \(form.title) \(form.submenu?.items.map(\.title) ?? [])")
        }
        let modes = try #require(wc.window?.toolbar?.items.first { $0.itemIdentifier.rawValue == "editorModes" }?.menuFormRepresentation)
        #expect(modes.submenu?.items.map(\.title) == ["Canvas", "Assistant", "Code Review"])
        #expect(modes.submenu?.items.allSatisfy { $0.image != nil } == true)
        let run = try #require(wc.window?.toolbar?.items.first { $0.itemIdentifier.rawValue == "run" }?.menuFormRepresentation)
        #expect(run.submenu?.items.filter { !$0.isSeparatorItem }.map(\.title) == ["Run", "Test", "Profile", "Analyze", "Stop"])
        let scheme = try #require(wc.window?.toolbar?.items.first { $0.itemIdentifier.rawValue == "scheme" }?.menuFormRepresentation)
        #expect(scheme.submenu?.items.first?.title == wc.schemePopUp.titleOfSelectedItem)
        #expect(scheme.submenu?.items.first?.state == .on)
        let issues = try #require(wc.window?.toolbar?.items.first { $0.itemIdentifier.rawValue == "issues" }?.menuFormRepresentation)
        #expect(issues.submenu?.items.map(\.title) == ["2 Warnings"], "\(issues.submenu?.items.map(\.title) ?? [])")
        #expect(issues.submenu?.items.first?.action == #selector(WorkspaceWindowController.overflowShowIssues(_:)))
        // The title area's entry is disabled (no action), as the reference's.
        let activity = try #require(wc.window?.toolbar?.items.first { $0.itemIdentifier.rawValue == "activity" }?.menuFormRepresentation)
        #expect(activity.title == "Window Title/Activity" && activity.action == nil)
    }

    // MARK: P-028 — Run's press-and-hold menu

    @Test func runSegmentHoldsTheRunMenu() throws {
        let (wc, _, dir) = try window("run")
        defer { try? FileManager.default.removeItem(at: dir); wc.window?.orderOut(nil) }
        let c = try #require(wc.runStopControl)
        let menu = try #require(c.menu(forSegment: 0))
        #expect(menu.items.map(\.title) == ["Run", "Test", "Profile", "Analyze"])
        #expect(menu.items.map { $0.action.map(NSStringFromSelector) } == RunButtonMenu.rows.map(\.selector))
        #expect(menu.items.allSatisfy { $0.image != nil && $0.target === wc && $0.keyEquivalent.isEmpty })
        #expect(!c.showsMenuIndicator(forSegment: 0))
        #expect(c.menu(forSegment: 1) == nil)
        // A click still runs: the segment keeps the control's action.
        #expect(c.action == #selector(WorkspaceWindowController.runStopChosen(_:)) && c.trackingMode == .momentary)
        // The rows are validated as the Product menu's.
        for item in menu.items { _ = wc.validateMenuItem(item) }
        #expect(RunButtonMenu.holdDelay > 0.3 && RunButtonMenu.holdDelay < 0.45)
    }

    // MARK: P-204 — Stop as accessibility clients read it

    /// Walks the window's accessibility tree from its root (the toolbar
    /// included) to the Run and Stop buttons.
    func runStopButtons(_ wc: WorkspaceWindowController) -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        func walk(_ e: Any, _ depth: Int) {
            let o = e as AnyObject
            let role = o.accessibilityRole?() as? NSAccessibility.Role
            let label = (o.accessibilityLabel?() as? String) ?? (o.accessibilityTitle?() as? String) ?? ""
            if role == .button, ["Run", "Stop"].contains(label) { out.append((label, o.isAccessibilityEnabled?() ?? false)) }
            if depth < 12, let kids = o.accessibilityChildren?() as? [Any] { kids.forEach { walk($0, depth + 1) } }
        }
        if let c = wc.runStopControl { walk(c, 0) }
        return out
    }

    @Test func stopReadsEnabledWhileAnActionRuns() throws {
        let (wc, session, dir) = try window("stop")
        defer { try? FileManager.default.removeItem(at: dir); wc.window?.orderOut(nil) }
        session.noteToolActivity(.running("Running Tool"))
        pump()
        wc.window?.toolbar?.validateVisibleItems()
        pump()
        let busy = runStopButtons(wc)
        print("B5 P-204 busy: \(busy)")
        #expect(busy.map(\.0) == ["Run", "Stop"] && busy.allSatisfy(\.1), "\(busy)")
        session.noteToolActivity(.idle)
        pump()
        wc.window?.toolbar?.validateVisibleItems()
        let idle = runStopButtons(wc)
        #expect(idle.first?.1 == true && idle.last?.1 == false, "\(idle)")
    }

    // MARK: P-029 — the subtitle keeps the room there is

    /// The fit gives the subtitle the widest cap that fits, to 2 points,
    /// not the coarser step below it.
    @Test func subtitleTakesTheRoomLeft() throws {
        let (wc, _, dir) = try window("subtitle")
        defer { try? FileManager.default.removeItem(at: dir); wc.window?.orderOut(nil) }
        wc.activityView.status = "Build Failed \u{2022} Today at 6:39 PM"
        var checked = 0
        for w in stride(from: 1200, through: 900, by: -20) {
            setWidth(wc, CGFloat(w))
            guard let cap = wc.toolbarFit.activityWidth, cap > ToolbarFit.activityMinimum,
                  cap < wc.activityView.naturalWidth - 3 else { continue }
            // Where the content section forces items into "»" (council round
            // 12) the cap is measured before they leave and can be a few
            // points short (B5-FIX-LAYOUT's candidate); P-029's precision is
            // checked where the room alone decides.
            guard ToolbarOverflow.forcedOut(content: wc.toolbarContentWidth).isEmpty else { continue }
            // 3 points more no longer fits.
            var wider = wc.toolbarFit
            wider.activityWidth = cap + 3
            wc.apply(wider)
            // Two passes, as the fit judges: AppKit moves an item into "»"
            // only on the pass after the one that ran out of room.
            let frame = wc.window?.contentView?.superview
            frame?.layoutSubtreeIfNeeded()
            frame?.needsLayout = true
            frame?.layoutSubtreeIfNeeded()
            let fits = wider.accepts(overflowed: wc.overflowedToolbarItems)
            print("B5 P-029 \(w): cap \(cap) shown \"\(wc.activityView.shownStatus)\" +3 fits \(fits)")
            #expect(!fits, "at \(w) the cap \(cap) leaves room")
            wc.fitToolbar()
            checked += 1
        }
        #expect(checked > 0)
    }

    /// The fits stay ordered as the window narrows: never less given up.
    @Test func fitsStayMonotone() throws {
        let (wc, _, dir) = try window("monotone")
        defer { try? FileManager.default.removeItem(at: dir); wc.window?.orderOut(nil) }
        wc.activityView.status = "Build Succeeded \u{2022} Today at 1:17 PM"
        var last: ToolbarFit?
        for w in stride(from: 1500, through: 800, by: -25) {
            setWidth(wc, CGFloat(w))
            let f = wc.toolbarFit
            if let last { #expect(Self.tightness(f) >= Self.tightness(last), "at \(w): \(f) after \(last)") }
            last = f
        }
    }

    static func tightness(_ f: ToolbarFit) -> Double {
        // Items the content section forces into "»" (council round 12) give
        // the subtitle its room back: they count above any cap.
        (f.schemeGlyphsOnly ? 1_000_000 : 0) + (f.editorModesInOverflow ? 100_000 : 0) + Double(f.forcedOverflow.count) * 20_000
            + (f.activityWidth.map { 10_000 - $0 } ?? 0)
    }

    /// The phase 2 defect: with the build report open the scheme capsule
    /// kept its glyphs only. Opening the report (the Report navigator and
    /// the log in the editor) at 1400 leaves the titles.
    @Test func schemeKeepsItsTitlesWithTheBuildReportOpen() async throws {
        let (wc, session, dir) = try window("report")
        defer { try? FileManager.default.removeItem(at: dir); wc.window?.orderOut(nil) }
        setWidth(wc, 1400)
        #expect(!wc.schemeShowsGlyphsOnly)
        let title = wc.schemePopUp.titleOfSelectedItem
        session.recordReport(BuildReport(title: "Build", date: Date(), succeeded: false, log: ["error: x"], errorCount: 1, warningCount: 0))
        session.noteToolActivity(.finished("Build Failed"))
        wc.issueCapsule.errors = 1
        pump(0.2)
        wc.openReportPage(0, "Log")
        pump(0.2)
        wc.fitToolbar()
        print("B5 phase2 report: glyphs \(wc.schemeShowsGlyphsOnly) title \(wc.schemePopUp.titleOfSelectedItem ?? "-") fit \(wc.toolbarFit) status \(wc.activityView.status)")
        #expect(!wc.schemeShowsGlyphsOnly, "\(wc.toolbarFit)")
        #expect(wc.schemePopUp.titleOfSelectedItem == title)
    }
}
