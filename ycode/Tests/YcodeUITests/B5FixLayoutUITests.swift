import AppKit
import Foundation
import QuartzCore
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

/// B5-FIX-LAYOUT (beta 5 fix round, council round 12;
/// `specs/ide/window-layout.md` §2.3, §2.4, §4.1, §4.2, §5, §6): the toolbar
/// with the navigator hidden (P-190), the narrow window's minimum and the
/// navigator's collapse (P-024), the toolbar's order in the three recorded
/// states (P-025) and the panels' motion (P-190, P-191). Off every display:
/// no window, menu or alert reaches the screen.
@MainActor
@Suite(.serialized) struct B5FixLayoutUITests {
    static func window(_ tag: String) throws -> WorkspaceWindowController {
        let dir = try CouncilRound8MotionTests.project("b5fl-\(tag)", lines: 120)
        return try CouncilRound8MotionTests.window(dir)
    }

    func layout(_ wc: WorkspaceWindowController) {
        wc.fitToolbar()
        wc.window?.contentView?.superview?.layoutSubtreeIfNeeded()
    }

    func setWidth(_ wc: WorkspaceWindowController, _ w: CGFloat) {
        wc.window?.setFrame(NSRect(x: -6000, y: -6000, width: w, height: 880), display: false)
        layout(wc)
    }

    /// A toolbar item's frame in window coordinates (nil: not shown).
    func frame(_ wc: WorkspaceWindowController, _ id: NSToolbarItem.Identifier) -> NSRect? {
        guard let item = wc.window?.toolbar?.visibleItems?.first(where: { $0.itemIdentifier == id }), let v = item.view, v.window != nil else { return nil }
        return v.convert(v.bounds, to: nil)
    }

    func step(_ slide: PaneSlide, in wc: WorkspaceWindowController, each: (Double) -> Void = { _ in }) {
        let press = slide.clock?.press ?? CACurrentMediaTime()
        var f = 0
        while slide.running, f < 240 {
            f += 1
            slide.advance(to: press + Double(f) / 120)
            wc.window?.contentView?.layoutSubtreeIfNeeded()
            each(Double(f) / 120)
        }
    }

    // MARK: P-190: the toolbar with the navigator hidden (§5.1)

    /// With the navigator hidden the Navigators / Coding Assistant group and
    /// Run | Stop stay in the toolbar: the group where it was, Run | Stop
    /// moved left after it, Back | Forward after them; no "»" at 1400.
    @Test func hiddenNavigatorKeepsTheGroupAndRunStop() throws {
        let wc = try Self.window("hidden")
        defer { wc.window?.orderOut(nil) }
        setWidth(wc, 1400)
        let shownGroup = try #require(frame(wc, WorkspaceWindowController.leftPanesID))
        let shownRun = try #require(frame(wc, WorkspaceWindowController.runID))
        let shownHistory = try #require(frame(wc, WorkspaceWindowController.historyID))
        #expect(wc.toolbarHasNavigatorSection)
        wc.setLeftPane(codingAssistant: false)   // the shown navigators: hides the area (off screen, at once)
        #expect(wc.navigatorItem.isCollapsed)
        layout(wc)
        #expect(!wc.toolbarHasNavigatorSection)
        let group = try #require(frame(wc, WorkspaceWindowController.leftPanesID), "the group left the toolbar")
        let run = try #require(frame(wc, WorkspaceWindowController.runID), "Run | Stop left the toolbar")
        let history = try #require(frame(wc, WorkspaceWindowController.historyID))
        print(String(format: "B5FL hidden: group %.1f–%.1f (shown %.1f–%.1f), run %.1f–%.1f (shown %.1f–%.1f), history %.1f–%.1f (shown %.1f–%.1f), overflow %@",
                     group.minX, group.maxX, shownGroup.minX, shownGroup.maxX, run.minX, run.maxX, shownRun.minX, shownRun.maxX,
                     history.minX, history.maxX, shownHistory.minX, shownHistory.maxX, wc.overflowedToolbarItems.description))
        // The group stays (x 96–171 in the reference).
        #expect(abs(group.minX - shownGroup.minX) <= 1)
        // Run | Stop follows it (reference: 9 points after, x 180–255) and
        // Back | Forward follows Run | Stop (≈ 6 after).
        #expect(run.minX > group.maxX && run.minX - group.maxX <= 16, "\(run.minX - group.maxX)")
        #expect(run.minX < shownRun.minX - 20)
        #expect(history.minX > run.maxX && history.minX - run.maxX <= 16, "\(history.minX - run.maxX)")
        // No "»" at 1400 for it.
        #expect(wc.overflowedToolbarItems.isEmpty, "\(wc.overflowedToolbarItems)")
        // Neither half has a bezel.
        #expect(!wc.leftPanesControl.isSelected(forSegment: 0) && !wc.leftPanesControl.isSelected(forSegment: 1))
        // Clicking the Navigators half shows the navigator (§5.2).
        wc.leftPanesControl.selectedSegment = 0
        wc.setLeftPane(codingAssistant: false, trigger: .click)
        layout(wc)
        #expect(!wc.navigatorItem.isCollapsed && wc.shownLeftPane == .navigators)
        #expect(wc.toolbarHasNavigatorSection)
        let back = try #require(frame(wc, WorkspaceWindowController.runID))
        #expect(abs(back.minX - shownRun.minX) <= 1)
    }

    /// The toolbar's tracking separators (any identifier).
    func separators(_ wc: WorkspaceWindowController) -> Int {
        (wc.window?.toolbar?.items ?? []).filter { $0 is NSTrackingSeparatorToolbarItem && $0.itemIdentifier != .inspectorTrackingSeparator }.count
    }

    /// Hiding and showing back to back, twice, with the deferred toolbar
    /// update and a window resize in between, in any order: the toolbar
    /// always has exactly one navigator tracking separator when the
    /// navigator is shown and none raises (AppKit refuses a second separator
    /// on the same divider: `NSInternalInconsistencyException`).
    @Test func arrangementSurvivesAnyOrderOfCalls() async throws {
        let wc = try Self.window("order-calls")
        // A second workspace window: toolbars that shared an identifier
        // followed each other's insertions and removals (the full run's
        // "Cannot register more than one NSTrackingSeparatorToolbarItem
        // that tracks the same divider").
        let other = try Self.window("order-calls-other")
        defer { wc.window?.orderOut(nil); other.window?.orderOut(nil) }
        #expect(wc.window?.toolbar?.identifier != other.window?.toolbar?.identifier)
        let w = try #require(wc.window)
        setWidth(wc, 1400)
        #expect(separators(wc) == 1)
        func spinTurn() async { try? await Task.sleep(nanoseconds: 30_000_000) }
        for round in 0..<3 {
            // Twice in a row, same turn.
            wc.setLeftPane(codingAssistant: false)
            wc.setNavigatorToolbarHidden(true)
            wc.setLeftPane(codingAssistant: false)
            wc.setNavigatorToolbarHidden(false)
            wc.scheduleToolbarStateUpdate()
            wc.setLeftPane(codingAssistant: false)
            wc.scheduleToolbarStateUpdate()
            w.setFrame(NSRect(x: -6000, y: -6000, width: 1300 - CGFloat(round * 50), height: 880), display: true)
            wc.setLeftPane(codingAssistant: false)
            wc.syncNavigatorToolbarArrangement()
            wc.scheduleToolbarStateUpdate()
            await spinTurn()
            wc.updateToolbarState()
            w.setFrame(NSRect(x: -6000, y: -6000, width: 1400, height: 880), display: true)
            await spinTurn()
            other.updateToolbarState()
            let shown = !wc.navigatorItem.isCollapsed
            #expect(separators(wc) == (shown ? 1 : 0), "round \(round): \(separators(wc)) separators, shown \(shown)")
            #expect(wc.toolbarHasNavigatorSection == shown, "round \(round)")
            // The other window keeps its own arrangement (navigator shown).
            #expect(separators(other) == 1 && other.toolbarHasNavigatorSection, "round \(round): other \(separators(other))")
        }
        // Shown at the end: one separator; Navigators and Run | Stop shown.
        if wc.navigatorItem.isCollapsed { wc.setLeftPane(codingAssistant: false) }
        await spinTurn()
        #expect(separators(wc) == 1 && wc.toolbarHasNavigatorSection)
        let visible = Set((w.toolbar?.visibleItems ?? []).map(\.itemIdentifier))
        #expect(visible.isSuperset(of: [WorkspaceWindowController.leftPanesID, WorkspaceWindowController.runID]))
    }

    // MARK: P-190: the slide (§6.1)

    /// ⌘0 twice: the first swaps to the coding assistant in place in one
    /// frame (§6.3: no slide, the area keeps its width), the second slides
    /// the area out over 240 ms ease-in-out; the toolbar switches at the
    /// start of the hide. A click on the Navigators half slides it back in
    /// and the toolbar switches back at the end.
    @Test func secondCommandZeroAndTheToggleSlide() throws {
        let wc = try Self.window("slide")
        defer { wc.window?.orderOut(nil) }
        PaneSlide.offscreen = true
        defer { PaneSlide.offscreen = false }
        setWidth(wc, 1400)
        let width = wc.navigator.view.frame.width
        wc.showCodingAssistant(nil)
        #expect(!wc.isNavigatorSliding && wc.shownLeftPane == .codingAssistant)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        #expect(abs(wc.navigator.view.frame.width - width) <= 1, "the swap kept \(wc.navigator.view.frame.width) of \(width)")
        // The second ⌘0.
        wc.showCodingAssistant(nil)
        #expect(wc.isNavigatorSliding)
        #expect(wc.navigatorSlide.clock?.curve == Motion.navigator(show: false, trigger: .key))
        #expect(!wc.toolbarHasNavigatorSection, "the toolbar switches at the start of a hide")
        var mid: CGFloat?
        step(wc.navigatorSlide, in: wc) { t in
            let c = Motion.navigator(show: false)
            if mid == nil, t >= c.delay + c.duration / 2 { mid = wc.navigatorItem.viewController.view.frame.width }
        }
        #expect(wc.navigatorItem.isCollapsed)
        // Ease-in-out: about half the travel at the middle.
        #expect(mid.map { $0 > width * 0.3 && $0 < width * 0.7 } == true, "\(String(describing: mid))")
        // The toggle's click slides it in; the toolbar keeps the hidden
        // arrangement until the end.
        wc.setLeftPane(codingAssistant: false, trigger: .click)
        #expect(wc.isNavigatorSliding)
        #expect(wc.navigatorSlide.clock?.curve == Motion.navigator(show: true, trigger: .click))
        #expect(!wc.toolbarHasNavigatorSection)
        var sectionDuring = false
        step(wc.navigatorSlide, in: wc) { _ in if wc.isNavigatorSliding, wc.toolbarHasNavigatorSection { sectionDuring = true } }
        #expect(!sectionDuring)
        #expect(!wc.navigatorItem.isCollapsed && wc.shownLeftPane == .navigators && wc.toolbarHasNavigatorSection)
        #expect(abs(wc.navigator.view.frame.width - width) <= 1)
    }

    // MARK: P-191: the debug area (§6.2)

    @Test func debugAreaMovesLinearly() throws {
        let wc = try Self.window("debug")
        defer { wc.window?.orderOut(nil) }
        PaneSlide.offscreen = true
        defer { PaneSlide.offscreen = false }
        wc.toggleDebugArea(nil)
        let slide = wc.debugAreaSlide
        let c = Motion.debugArea(show: true)
        #expect(slide.clock?.curve == c && abs(c.duration - 0.25) < 0.001 && c.bezier == .linear)
        var heights: [CGFloat] = []
        step(slide, in: wc) { _ in heights.append(wc.debugItem.isCollapsed ? 0 : wc.debugArea.view.frame.height) }
        // The first moving frame opens the pane at its bar's height (as before
        // this round); from then on the edge moves at constant speed.
        let moving = Array(zip(heights, heights.dropFirst()).map { $1 - $0 }.filter { $0 > 0 }.dropFirst())
        print("B5FL debug steps: \(moving.map { String(format: "%.0f", $0) }.joined(separator: " "))")
        // Constant speed: every step within a point of the median (rounding).
        let inner = Array(moving.dropFirst().dropLast())
        let median = inner.sorted()[inner.count / 2]
        #expect(inner.allSatisfy { abs($0 - median) <= 1.01 }, "\(moving)")
    }

    // MARK: P-024: the minimum and the live drag (§4.1, §4.2)

    @Test func minimumFollowsTheInspector() throws {
        let wc = try Self.window("minimum")
        defer { wc.window?.orderOut(nil) }
        let w = try #require(wc.window)
        #expect(w.minSize.width == 503)
        wc.inspectorItem.isCollapsed = true
        wc.updateToolbarState()   // as the toggle's own path does (observers wait for the next turn)
        #expect(w.minSize.width == 410, "\(w.minSize.width)")
        wc.setLeftPane(codingAssistant: false)
        // At the minimum the toolbar keeps its floor's items.
        setWidth(wc, w.minSize.width)
        print("B5FL minimum (both hidden): \(w.frame.width), editor \(wc.editorArea.view.frame.width), overflow \(wc.overflowedToolbarItems)")
        let visible = Set((w.toolbar?.visibleItems ?? []).map(\.itemIdentifier))
        #expect(visible.isSuperset(of: [WorkspaceWindowController.leftPanesID, WorkspaceWindowController.runID,
                                        WorkspaceWindowController.inspectorToggleID]), "\(visible)")
        wc.inspectorItem.isCollapsed = false
        wc.updateToolbarState()
        #expect(w.minSize.width == 503)
    }

    /// A live drag: only the editor narrows until it reaches 300; then the
    /// navigator collapses whole (never narrower than 290 while shown) and
    /// stays hidden when the window widens.
    @Test func liveDragCollapsesTheNavigator() throws {
        for inspectorShown in [false, true] {
            let wc = try Self.window("drag-\(inspectorShown)")
            defer { wc.window?.orderOut(nil) }
            let w = try #require(wc.window)
            if !inspectorShown { wc.inspectorItem.isCollapsed = true; wc.updateToolbarState() }
            setWidth(wc, 1400)
            wc.noteLiveResizeStart()
            let nav = wc.navigator.view.frame.width
            let collapse = NarrowWindowLayout.navigatorCollapseWidth(navigator: Double(nav), inspector: inspectorShown ? Double(wc.inspector.view.frame.width) : nil)
            var collapsedAt: CGFloat?
            var width: CGFloat = 1000
            while width >= w.minSize.width {
                setWidth(wc, width)
                wc.narrowWindowDidResize(live: true)
                w.contentView?.layoutSubtreeIfNeeded()
                if wc.navigatorItem.isCollapsed {
                    collapsedAt = collapsedAt ?? width
                } else {
                    #expect(abs(wc.navigator.view.frame.width - nav) <= 1, "at \(width) the navigator shrank to \(wc.navigator.view.frame.width)")
                }
                #expect(wc.editorArea.view.frame.width >= 299, "at \(width): editor \(wc.editorArea.view.frame.width)")
                width -= 5
            }
            print("B5FL drag (inspector \(inspectorShown)): collapsed at \(collapsedAt ?? -1) (rule \(collapse)), minimum \(w.frame.width), inspector \(wc.inspectorItem.isCollapsed ? 0 : wc.inspector.view.frame.width)")
            #expect(collapsedAt.map { abs(Double($0) - collapse) <= 5 } == true)
            #expect(w.minSize.width == (inspectorShown ? 503 : 410))
            if inspectorShown {
                // At the last width (the minimum, to 5 points) the inspector
                // has given up its room down to ≈ 201.5 beside a 300-point editor.
                #expect(wc.inspector.view.frame.width >= 201 && abs(wc.inspector.view.frame.width - (w.frame.width - 301)) <= 2, "\(wc.inspector.view.frame.width)")
            }
            setWidth(wc, 1400)
            #expect(wc.navigatorItem.isCollapsed)
        }
    }

    // MARK: P-025: the order in the three states (§2, §2.3)

    /// The width at which each item first leaves, from 1400 down in 5-point
    /// steps, with both areas shown, the inspector hidden, and both hidden;
    /// against the spec's tables (each good to 25 points).
    @Test func overflowThresholdsFollowTheTables() throws {
        // Each item's first width out of the toolbar must fall in its range
        // (b5-obs and round 12 (a): the recorded width ± 25; round 12 (b):
        // the widths it was out at and in at).
        struct State { var name: String; var navigator: Bool; var inspector: Bool; var ranges: [String: ClosedRange<Double>] }
        func around(_ w: Double) -> ClosedRange<Double> { (w - 25)...(w + 25) }
        let states = [
            State(name: "both shown", navigator: true, inspector: true,
                  ranges: ["editorModes": around(1150), "editorOptions": around(1075), "addEditor": around(1050), "issues": around(1000),
                           "scheme": around(950), "newConversation": around(875)]),
            State(name: "inspector hidden", navigator: true, inspector: false,
                  ranges: ["editorModes": around(937), "editorOptions": around(900), "addEditor": around(850), "issues": around(800),
                           "scheme": around(750), "newConversation": around(650)]),
            State(name: "both hidden", navigator: false, inspector: false,
                  ranges: ["editorModes": 900...1095, "editorOptions": 817...895, "addEditor": 700...812, "issues": 700...812,
                           "scheme": 700...812, "newConversation": 503...695]),
        ]
        var report: [String] = []
        for s in states {
            let wc = try Self.window("order-\(s.name.replacingOccurrences(of: " ", with: "-"))")
            defer { wc.window?.orderOut(nil) }
            wc.issueCapsule.errors = 1
            wc.activityView.status = "Build Succeeded \u{2022} Today at 4:41 AM"
            if !s.navigator { wc.setLeftPane(codingAssistant: false) }
            if !s.inspector { wc.inspectorItem.isCollapsed = true; wc.updateToolbarState() }
            var first: [String: CGFloat] = [:]
            var w: CGFloat = 1400
            // With the navigator shown, down to where a live drag collapses
            // it (a frame set below that clips, §4 rule 3).
            let floor = s.navigator ? NarrowWindowLayout.navigatorCollapseWidth(inspector: s.inspector ? 260 : nil)
                                    : NarrowWindowLayout.minimumWindowWidth(inspectorShown: s.inspector)
            while Double(w) >= floor {
                setWidth(wc, w)
                for id in wc.overflowedToolbarItems where first[id] == nil { first[id] = w }
                if ProcessInfo.processInfo.environment["B5FL_DIAG"] != nil, [1150, 1145, 1140, 960, 950, 945, 745, 740].contains(Int(w)) {
                    print("B5FL diag \(s.name) \(Int(w)): content \(wc.toolbarContentWidth) fit \(wc.toolbarFit) activity \(wc.activityView.frame.width) reserve \(wc.activityView.reservedWidth) out \(wc.overflowedToolbarItems)")
                }
                w -= 5
            }
            let keys = s.ranges.keys.sorted { s.ranges[$0]!.upperBound > s.ranges[$1]!.upperBound }
            report.append("\(s.name): " + keys.map { k in "\(k) \(first[k].map { String(Int($0)) } ?? "-") (\(Int(s.ranges[k]!.lowerBound))–\(Int(s.ranges[k]!.upperBound)))" }
                .joined(separator: ", ") + "; others \(first.filter { s.ranges[$0.key] == nil }.map { "\($0.key) \(Int($0.value))" })")
            for k in keys {
                let r = s.ranges[k]!
                // Out of reach above the collapse point: only checked when the range is.
                guard r.lowerBound >= floor else { continue }
                #expect(first[k].map { r.contains(Double($0)) } == true, "\(s.name): \(k) first out at \(first[k].map { "\($0)" } ?? "never"), range \(r)")
            }
            let order = ["editorModes", "editorOptions", "addEditor", "issues", "scheme", "newConversation"]
            let seen = order.compactMap { first[$0] }
            #expect(zip(seen, seen.dropFirst()).allSatisfy { $0 >= $1 }, "\(s.name): \(first)")
            if !s.navigator {
                #expect(first["leftPanes"] == nil && first["run"] == nil, "\(s.name): \(first)")
            }
        }
        print("B5FL thresholds:\n" + report.joined(separator: "\n"))
    }

    // MARK: Stills (B5_SHOTS=1): .build-ide/b5-shots/mac-fixlayout-*.png

    @Test(.enabled(if: ProcessInfo.processInfo.environment["B5_SHOTS"] != nil))
    func stills() throws {
        let wc = try Self.window("shots")
        defer { wc.window?.orderOut(nil) }
        let w = try #require(wc.window)
        w.appearance = NSAppearance(named: .darkAqua)
        PaneSlide.offscreen = true
        defer { PaneSlide.offscreen = false }
        wc.issueCapsule.errors = 1
        wc.activityView.status = "Build Succeeded \u{2022} Today at 4:41 AM"
        let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build-ide/b5-shots")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        func shot(_ name: String) {
            guard let v = w.contentView?.superview ?? w.contentView else { return }
            v.layoutSubtreeIfNeeded()
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            let url = out.appendingPathComponent("mac-fixlayout-\(name).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print("B5FL shot \(url.path)")
        }
        setWidth(wc, 1400)
        shot("shown-1400")
        wc.setLeftPane(codingAssistant: false, trigger: .click)
        let c = Motion.navigator(show: false, trigger: .click)
        var midShot = false
        step(wc.navigatorSlide, in: wc) { t in
            if !midShot, t >= c.delay + c.duration / 2 { midShot = true; shot("hide-mid") }
        }
        layout(wc)
        shot("hidden-1400")
        wc.toggleDebugArea(nil)
        let d = Motion.debugArea(show: true)
        var debugShot = false
        step(wc.debugAreaSlide, in: wc) { t in
            if !debugShot, t >= d.delay + d.duration / 2 { debugShot = true; shot("debug-mid") }
        }
        wc.debugItem.isCollapsed = true
        wc.inspectorItem.isCollapsed = true
        for width in [1100.0, 900, 817, 700, 503, 410] as [CGFloat] {
            setWidth(wc, width)
            shot("both-hidden-\(Int(width))")
        }
    }
}
