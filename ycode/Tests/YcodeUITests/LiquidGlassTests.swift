import AppKit
import Testing
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
        let h = nav.view.bounds.height
        let sel = nav.selectorView.frame
        #expect(sel.size == NSSize(width: 278, height: 30) && sel.minX == 6, "\(sel)")
        #expect(!nav.selectorPill.isHidden && nav.selectorPill.frame.size == NavigatorAreaController.selectorPillSize)
        let plus = nav.plusGlass.frame, field = nav.filterGlass.frame
        #expect(plus.size == NavigatorAreaController.plusSize && abs(plus.minX - 6) <= 0.5, "\(plus)")
        #expect(field.height == 30 && abs(field.minY - 7) <= 0.5 && abs(field.minX - plus.maxX - 6) <= 0.5 && abs(nav.view.bounds.maxX - field.maxX - 6) <= 0.5, "\(field)")
        // Under the bars: the outline's scroll view spans the area's height.
        let scroll = nav.scrollView
        let inRoot = scroll.convert(scroll.bounds, to: nav.view)
        #expect(abs(inRoot.maxY - h) <= 0.5 && abs(inRoot.minY) <= 0.5, "\(inRoot)")
        #expect(scroll.contentInsets.top > 0 && scroll.contentInsets.bottom >= nav.filterGlass.frame.maxY)
        #expect(!nav.scrollClipView.clipsToBounds)
        // The Find navigator's header: clipped below it.
        nav.select(3)
        nav.view.layoutSubtreeIfNeeded()
        #expect(nav.scrollClipView.clipsToBounds && scroll.contentInsets.top == 0)
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
        #expect(w.table.rowHeight == 48)
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
