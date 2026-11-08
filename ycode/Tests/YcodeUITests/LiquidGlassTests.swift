import AppKit
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

/// `specs/ide/liquid-glass.md` as `liquid-glass-ycode.md` implements it:
/// the toolbar's glass shapes, the floating bars, the debug bar and the
/// Welcome window's geometry (macOS 26 and later; earlier systems keep
/// the earlier look and skip these checks).
@MainActor
@Suite(.serialized) struct LiquidGlassTests {

    /// §2.2: segment widths for the 78 / 75 / 125-point capsules; the
    /// scheme and issue items are their own capsules, the activity view
    /// has none; a fixed space splits New Conversation from the scheme;
    /// Run | Stop ends the navigator's section.
    @Test func toolbarItemsAreGlassShapes() throws {
        guard #available(macOS 26, *) else { return }
        let r32 = WindowChromeR32Tests()
        let dir = try r32.package("glass-toolbar")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wc = try r32.window(dir)
        #expect((0..<2).map { wc.leftPanesControl.width(forSegment: $0) } == [31.5, 31.5])
        #expect((0..<3).map { wc.editorModesControl.width(forSegment: $0) } == [35, 35, 35])
        let items = Dictionary((wc.window?.toolbar?.items ?? []).map { ($0.itemIdentifier.rawValue, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(items["scheme"]?.isBordered == true && items["issues"]?.isBordered == true)
        #expect(items["activity"]?.isBordered == false)
        let run = try #require(items["run"]?.view as? NSSegmentedControl)
        #expect((0..<2).map { run.width(forSegment: $0) } == [30, 30])
        let ids = wc.toolbarDefaultItemIdentifiers(NSToolbar()).map(\.rawValue)
        let conv = try #require(ids.firstIndex(of: "newConversation")), scheme = try #require(ids.firstIndex(of: "scheme"))
        #expect(ids[conv + 1] == NSToolbarItem.Identifier.space.rawValue && conv + 2 == scheme)
        #expect(ids.firstIndex(of: "run")! + 1 == ids.firstIndex(of: NSToolbarItem.Identifier.sidebarTrackingSeparator.rawValue)!)
        // No issues: the capsule's item is hidden, not an overflow.
        #expect(items["issues"]?.isHidden == true && !wc.overflowedToolbarItems.contains("issues"))
    }

    /// §2.3, §3.1: the selector bar, the "+" circle and the filter
    /// capsule; the outline runs under the bars with no header shown and
    /// is clipped below the Find header.
    @Test func navigatorBarsFloatOverTheOutline() throws {
        guard #available(macOS 26, *) else { return }
        let nav = NavigatorInspectorR45Tests().laidOutNavigator()
        nav.view.setFrameSize(NSSize(width: 290, height: 600))
        nav.view.layoutSubtreeIfNeeded()
        let sel = nav.selectorView.frame
        #expect(sel.size == NSSize(width: 278, height: 30) && sel.minX == 6, "\(sel)")
        #expect(!nav.selectorPill.isHidden && nav.selectorPill.frame.size == NavigatorAreaController.selectorPillSize)
        let plus = nav.plusGlass.frame, field = nav.filterGlass.frame
        // Round 4 (editor-area.md F.9, row 110): a 28 × 28 circle at x 7–35,
        // a 240 × 28 capsule at x 42.5–282.5, both 8 above the bottom.
        #expect(plus.size == NSSize(width: 28, height: 28) && abs(plus.minX - 7) <= 0.5 && abs(plus.minY - 8) <= 0.5, "\(plus)")
        #expect(field.height == 28 && abs(field.minY - 8) <= 0.5 && abs(field.minX - 42.5) <= 0.5 && field.width == 240
                && abs(nav.view.bounds.maxX - field.maxX - 7.5) <= 0.5, "\(field)")
        // Under the bars: the outline's scroll view runs from the selector
        // capsule's top (nothing shows above it) to the area's bottom.
        let scroll = nav.scrollView
        let inRoot = scroll.convert(scroll.bounds, to: nav.view)
        #expect(abs(inRoot.maxY - sel.maxY) <= 0.5 && abs(inRoot.minY - field.minY) <= 0.5, "\(inRoot)")
        // The scroll bar's track: 3 below the selector, 11 above the filter
        // capsule. The scroll view insets its scrollers by the content
        // insets and the scroller insets together (council row 167).
        let ci = scroll.contentInsets, si = scroll.scrollerInsets
        #expect(abs(ci.top + si.top - sel.height - 3) <= 0.5 && abs(ci.bottom + si.bottom - field.height - 11) <= 0.5,
                "\(ci) \(si)")
        // The first row sits 7 below the selector capsule.
        let row0 = nav.outlineView.convert(nav.outlineView.rect(ofRow: 0), to: nav.view)
        #expect(nav.outlineView.numberOfRows == 0 || abs(sel.minY - row0.maxY - NavigatorAreaController.firstRowGap) <= 0.5, "\(row0) \(sel)")
        #expect(scroll.contentInsets.top > 0 && scroll.contentInsets.bottom >= nav.filterGlass.frame.height)
        #expect(!nav.scrollClipView.clipsToBounds)
        // The Find navigator's header: clipped below it, the scroll view
        // filling the clip and its inset putting the first row 4 points
        // below the clip's top (metrics.md §2).
        nav.select(3)
        nav.view.layoutSubtreeIfNeeded()
        #expect(nav.scrollClipView.clipsToBounds && abs(scroll.frame.maxY - nav.scrollClipView.bounds.maxY) <= 0.5)
        #expect(abs(scroll.contentInsets.top - (NavigatorAreaController.clipToFirstRow - nav.outlineTopPadding)) <= 0.25)
        nav.select(0)
        nav.view.layoutSubtreeIfNeeded()
        #expect(!nav.scrollClipView.clipsToBounds)
    }

    /// §2.4, §2.5, §2.1, §2.6: the inspector's tab bar, its divider, the
    /// Coding Assistant header and the 36-point debug bar over the editor.
    @Test func inspectorBarDividerAndDebugBar() throws {
        guard #available(macOS 26, *) else { return }
        let r32 = WindowChromeR32Tests()
        let dir = try r32.package("glass-areas")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wc = try r32.window(dir)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        let bar = wc.inspector.tabBarView.frame
        let width = wc.inspector.view.bounds.width
        #expect(bar.height == 30 && abs(bar.minX - 6) <= 0.5 && abs(width - bar.maxX - 6) <= 0.5, "\(bar)")
        #expect(wc.inspector.inspectorItemFlushHeight(in: wc))
        #expect(wc.debugArea.debugBar.frame.height == 36)
        #expect(wc.editorArea.view.additionalSafeAreaInsets.bottom == 36)
    }

    /// §2.10: the recent box, rows and close circle.
    @Test func welcomeGeometry() throws {
        guard #available(macOS 26, *) else { return }
        let td = TestDefaults("glass-welcome")
        defer { td.remove() }
        let w = WelcomeWindowController(recents: RecentProjects(defaults: td.defaults))
        let content = try #require(w.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let h = content.bounds.height
        let box = w.recentsBox.frame
        #expect(box.minX == 60 && box.width == 360 && h - box.maxY == 295 && box.height == 277, "\(box)")
        #expect(w.recentsBox.layer?.cornerRadius == 12 && w.recentsBox.layer?.borderWidth == 0 || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
        #expect(w.table.rowHeight == 47 && w.table.intercellSpacing.height == 0)   // metrics.md §13.4: a 47-point pitch
        #expect(w.tableView(w.table, rowViewForRow: 0) is RecentRowView)
        #expect([w.openButton, w.cloneButton].allSatisfy { $0.bezelStyle == .push && $0.borderShape == .capsule })
    }
}

extension InspectorAreaController {
    /// The inspector runs the window's full height (no inset; §2.1).
    func inspectorItemFlushHeight(in wc: WorkspaceWindowController) -> Bool {
        guard let window = wc.window, let content = window.contentView else { return false }
        let r = view.convert(view.bounds, to: content)
        return abs(r.maxY - content.bounds.maxY) <= 0.5 && abs(r.maxX - content.bounds.maxX) <= 0.5 && wc.inspectorItem.allowsFullHeightLayout
    }
}

/// metrics.md §15: the navigator's "+" circle holds a "+" alone, centred;
/// the filter capsule's options glyph (lines in a circle and a chevron)
/// starts 7.5 in, and the filter text keeps 28 at its leading end.
@MainActor
@Suite(.serialized) struct NavigatorBottomBarGlyphTests {
    /// The ink's x range in `view` (alpha over 0.1), in points, or nil.
    static func inkRange(_ view: NSView) -> ClosedRange<CGFloat>? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / max(view.bounds.width, 1)
        var lo = Int.max, hi = Int.min
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                lo = min(lo, x); hi = max(hi, x)
                break
            }
        }
        guard lo <= hi else { return nil }
        return CGFloat(lo) / scale...CGFloat(hi + 1) / scale
    }

    @Test func plusIsCentredWithNoArrow() throws {
        guard #available(macOS 26, *) else { return }
        let nav = NavigatorInspectorR45Tests().laidOutNavigator()
        nav.view.setFrameSize(NSSize(width: 290, height: 600))
        nav.view.layoutSubtreeIfNeeded()
        let button = nav.addBreakpointButton
        #expect((button.cell as? NSPopUpButtonCell)?.arrowPosition == .noArrow)
        let ink = try #require(Self.inkRange(button))
        let circle = nav.plusGlass.convert(nav.plusGlass.bounds, to: button)
        let left = ink.lowerBound - circle.minX, right = circle.maxX - ink.upperBound
        // A "+" alone: about 10.5 wide, with even gaps (the reference's are 9 and 9.5).
        #expect(ink.upperBound - ink.lowerBound <= 12.5, "\(ink)")
        #expect(abs(left - right) <= 1, "left \(left), right \(right)")
    }

    @Test func optionsGlyphAndTextStartWhereTheReferenceDoes() throws {
        guard #available(macOS 26, *) else { return }
        let nav = NavigatorInspectorR45Tests().laidOutNavigator()
        nav.view.setFrameSize(NSSize(width: 290, height: 600))
        nav.view.layoutSubtreeIfNeeded()
        let options = nav.filterOptions
        let ink = try #require(Self.inkRange(options))
        let capsule = nav.filterGlass.convert(nav.filterGlass.bounds, to: options)
        let start = ink.lowerBound - capsule.minX, end = ink.upperBound - capsule.minX
        #expect(abs(start - 7.5) <= 1, "glyph starts \(start)")
        #expect(abs(end - 27.5) <= 1.5, "glyph ends \(end)")
        let field = try #require(nav.filter as? NavigatorFilterField)
        #expect(field.leadingInset == NavigatorAreaController.filterTextInset)
    }
}
