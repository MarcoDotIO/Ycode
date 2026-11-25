import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

/// Beta 5's navigator items on macOS (B5-NAVIGATOR): the filter (P-037),
/// empty states (P-039), bottom bars (P-040), context menus (P-041), drag
/// (P-042), inline rename and new group rows (P-043). Offscreen.
@MainActor
@Suite(.serialized) struct B5NavigatorTests {
    typealias Ops = ProjectNavigatorOperationsTests

    /// A laid-out navigator with App ▸ Sources ▸ Model, ModelTests, View
    /// (extensions hidden as by default, or not: the titles are compared
    /// without them).
    func navigator() -> NavigatorAreaController {
        let nav = NavigatorInspectorR45Tests().laidOutNavigator()
        nav.setProjectTree(NavigatorNode(name: "App", kind: .container, path: "/tmp/App.xcodeproj", children: [
            NavigatorNode(name: "Sources", kind: .group, path: "/tmp/S", children: [
                NavigatorNode(name: "Model.swift", kind: .file, path: "/tmp/S/Model.swift"),
                NavigatorNode(name: "ModelTests.swift", kind: .file, path: "/tmp/S/ModelTests.swift"),
                NavigatorNode(name: "View.swift", kind: .file, path: "/tmp/S/View.swift"),
            ]),
        ]))
        nav.view.layoutSubtreeIfNeeded()
        return nav
    }

    func shownTitles(_ nav: NavigatorAreaController) -> [String] {
        let o = nav.outlineView
        return (0..<o.numberOfRows).compactMap { (o.item(atRow: $0) as? OutlineItem).map { ($0.title as NSString).deletingPathExtension } }
    }

    func runLoop(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: Screenshots (`.build-ide/b5-shots/`)

    static let shots = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build-ide/b5-shots")

    func shot(_ wc: WorkspaceWindowController, _ name: String) {
        try? FileManager.default.createDirectory(at: Self.shots, withIntermediateDirectories: true)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        wc.window?.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        // The navigator area alone, on the dark sidebar colour (its glass
        // and material do not draw offscreen).
        let v = wc.navigator.view
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        let image = NSImage(size: v.bounds.size)
        v.cacheDisplay(in: v.bounds, to: rep)
        image.lockFocus()
        NSColor(srgbRed: 0x28 / 255.0, green: 0x28 / 255.0, blue: 0x2A / 255.0, alpha: 1).setFill()
        NSRect(origin: .zero, size: v.bounds.size).fill()
        rep.draw(in: NSRect(origin: .zero, size: v.bounds.size))
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let out = NSBitmapImageRep(data: tiff) else { return }
        try? out.representation(using: .png, properties: [:])?.write(to: Self.shots.appendingPathComponent(name))
    }

    @Test func screenshotsOfTheNavigatorStates() throws {
        let s = try Ops.Sample()
        defer { s.remove() }
        let wc = try s.window()
        wc.window?.appearance = NSAppearance(named: .darkAqua)
        wc.window?.setFrame(NSRect(x: -6000, y: -6000, width: 1400, height: 880), display: true)
        let nav = wc.navigator
        let ops = Ops()
        nav.setFilter("ode")
        shot(wc, "nav5-filter-match.png")
        // The filtered project row keeps its mark.
        #expect(nav.rows(0).first?.rowIcon == .ycodeMark)
        nav.setFilter("nothing-here")
        shot(wc, "nav5-filter-none.png")
        nav.setFilter("")
        nav.select(1)
        shot(wc, "nav5-scm-empty.png")
        nav.select(4)
        shot(wc, "nav5-issues-empty.png")
        nav.select(0)
        ops.select(wc, ids: [Ops.model])
        let file = try #require(ops.row(wc, id: Ops.model))
        nav.beginRename(file)
        shot(wc, "nav5-rename.png")
        nav.commitRename("Model.swift")
        ops.select(wc, ids: [Ops.navGroup])
        _ = wc.newNavigatorGroup(withFolder: false)
        shot(wc, "nav5-new-group.png")
        #expect(FileManager.default.fileExists(atPath: Self.shots.appendingPathComponent("nav5-new-group.png").path))
    }

    // MARK: P-037 — the filter

    @Test func filterEmphasisEmptyStateGlyphAndRecents() {
        let nav = navigator()
        #expect(!nav.filterGlyphIsActive)
        // A match: the row stays; its matched part bold, the rest dimmed.
        nav.setFilter("odel")
        #expect(nav.filterGlyphIsActive)
        let o = nav.outlineView
        let titles = shownTitles(nav)
        #expect(titles == ["App", "Sources", "Model", "ModelTests"])
        let label = (o.view(atColumn: 0, row: 2, makeIfNecessary: true) as? NSTableCellView)?.textField
        let styled = label?.attributedStringValue
        let matchFont = styled?.attribute(.font, at: 1, effectiveRange: nil) as? NSFont
        let restColor = styled?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(styled.map { ($0.string as NSString).deletingPathExtension } == "Model")
        #expect(matchFont.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true)
        #expect(restColor.map { $0.alphaComponent < 0.9 } == true)
        // Nothing left: "No Filter Results" and the inspector's "No Selection".
        nav.setFilter("zzz")
        #expect(nav.emptyStateLines == [NavigatorFilterModel.noResults])
        #expect(nav.filterLeavesNoRows && nav.inspectorPlaceholderIsNoSelection)
        // The field's value is exposed to accessibility.
        #expect(nav.filter.accessibilityValue() as? String == "zzz")
        // The filter ends: a recent filter in the options menu.
        nav.noteRecentFilter()
        #expect(nav.recentFilters == ["zzz"])
        #expect(nav.filterOptionTitles == ["zzz", "-", "Clear Recents"])
        nav.clearRecentFilters(nil)
        #expect(nav.filterOptionTitles == ["Clear Recents"])
        nav.setFilter("")
        #expect(!nav.filterGlyphIsActive && nav.emptyStateLines.isEmpty && !nav.inspectorPlaceholderIsNoSelection)
    }

    @Test func rowsFilterAfterTheSettlePause() {
        let nav = navigator()
        nav.filter.stringValue = "View"
        nav.filterTyped()
        // Not yet: the rows wait for the pause after the last key.
        #expect(nav.filterIsSettling)
        #expect(NavigatorFilterModel.settleDelay <= 0.06)
        let start = Date()
        while nav.filterIsSettling, Date().timeIntervalSince(start) < 3 { runLoop(0.005) }
        let elapsed = Date().timeIntervalSince(start)
        // The rows waited for the pause (the time itself depends on the
        // machine's load; unloaded it is the pause plus a frame).
        print("P-037 rows filtered \(Int(elapsed * 1000)) ms after the last key")
        #expect(!nav.filterIsSettling && elapsed >= NavigatorFilterModel.settleDelay * 0.8)
        #expect(shownTitles(nav) == ["App", "Sources", "View"])
    }

    @Test func optionsMenuOpensUpwardFromTheGlyph() throws {
        let nav = navigator()
        let button = try #require(nav.filterOptions as? NavigatorOptionsButton)
        #expect(button.opensUpward)
        let origin = button.upwardMenuOrigin(height: 100)
        // The menu's top-left corner is 100 points (plus the gap) above the glyph, at its left edge.
        let inWindow = button.convert(origin, to: nil)
        let top = button.convert(NSPoint(x: 0, y: button.isFlipped ? 0 : button.bounds.maxY), to: nil)
        #expect(origin.x == 0 && inWindow.y - top.y >= 100)
    }

    @Test func inspectorReadsNoSelectionWhileTheFilterLeavesNothing() throws {
        let s = try Ops.Sample()
        defer { s.remove() }
        let wc = try s.window()
        wc.navigator.setFilter("nothing-matches-this")
        #expect(wc.inspector.noFileText == "No Selection")
        wc.navigator.setFilter("")
        #expect(wc.inspector.noFileText == "Not Applicable")
    }

    // MARK: Asks from B5-MOTION (P-024) and B5-STATES (P-198)

    @Test func selectorBarCompressesAndUsesTheGlassLens() {
        let nav = navigator()
        let buttons = nav.selectorButtons
        #expect(buttons.allSatisfy { ($0 as? GlassTabButton)?.lens === nav.selectorLens })
        #expect(nav.selectorLens.bar == .navigator)
        // The bar no longer holds the navigator wide: it fits in ≈ 135 points.
        let stack = buttons.first?.superview
        #expect((stack?.fittingSize.width ?? 999) <= 135)
        // Nor does any other row (P-024, B5-FOLLOWUP): the navigator compresses to ≈ 135.
        nav.view.window?.setContentSize(NSSize(width: 150, height: 600))
        nav.view.layoutSubtreeIfNeeded()
        #expect(nav.view.fittingSize.width <= 140)
        #expect(nav.selectorView.frame.maxX <= 150 && (stack?.frame.width ?? 999) <= 150)
        // The lens selects on release.
        nav.selectorLens.select(4)
        #expect(nav.selectedIndex == 4)
    }

    // MARK: P-039 — empty states

    @Test func emptyStateIsSixteenPointMediumRaised() {
        let nav = navigator()
        nav.select(4)   // Issues: "No Issues"
        #expect(nav.emptyStateLines == ["No Issues"])
        let label = nav.view.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "No Issues" }
        let font = label?.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font?.pointSize == 16)
        let weight = (font?.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat
        #expect(weight.map { abs($0 - NSFont.Weight.medium.rawValue) < 0.01 } == true)
        let dark = NSAppearance(named: .darkAqua)!
        var rgb: (CGFloat, CGFloat, CGFloat) = (0, 0, 0)
        dark.performAsCurrentDrawingAppearance {
            let c = NavigatorAreaController.emptyTitleColor.usingColorSpace(.sRGB)!
            rgb = (c.redComponent, c.greenComponent, c.blueComponent)
        }
        #expect(Int(rgb.0 * 255 + 0.5) == 0x9D && Int(rgb.1 * 255 + 0.5) == 0x9F && Int(rgb.2 * 255 + 0.5) == 0xA1)
        // Raised above the outline's centre.
        if let label {
            let clipMid = nav.scrollClipView.convert(NSPoint(x: 0, y: nav.scrollClipView.bounds.midY), to: nil).y
            let labelMid = label.convert(NSPoint(x: 0, y: label.bounds.midY), to: nil).y
            #expect(abs(labelMid - clipMid - CGFloat(NavigatorEmptyStyle.raise)) < 0.6)
        }
        nav.select(1)
        #expect(nav.emptyStateLines == ["No Git Repositories"])
    }

    // MARK: P-040 — bottom bars

    @Test func bottomBarsCarryTheActionButtonAndTheProjectPlusMenu() throws {
        let s = try Ops.Sample()
        defer { s.remove() }
        let wc = try s.window()
        let nav = wc.navigator
        nav.select(0)
        nav.rebuildAddMenu()
        #expect(nav.addMenuTitles == ["New Empty File", "New File from Template…", "", "Add Files to \u{201C}Nav\u{201D}…"])
        for i in [1, 5, 8] {
            nav.select(i)
            #expect(nav.leftButtonToolTip == .some("More"), "navigator \(i)")
        }
        nav.select(3)
        nav.rebuildScopeMenu()
        #expect(nav.findScope.title == "In Workspace")
    }

    // MARK: P-041 — context menus

    @Test func contextMenusFollowTheRowKindAndLeaveTheSelection() throws {
        let s = try Ops.Sample()
        defer { s.remove() }
        let wc = try s.window()
        let nav = wc.navigator
        let ops = Ops()
        ops.select(wc, ids: [Ops.model])
        let project = try #require(nav.rows(0).first)
        // The project row: groups, sorting, Migrate to String Catalog, no Delete.
        let pm = nav.projectContextMenu(for: project)
        let pt = pm.items.filter { !$0.isSeparatorItem }.map(\.title)
        #expect(!pt.contains("Delete") && !pt.contains("Rename"))
        #expect(pt.contains("New Group") && pt.contains("Sort by Name") && pt.contains("Migrate to String Catalog…"))
        #expect(pm.minimumWidth == 240)
        // A right click outside the selection does not select the row, but
        // the menu's commands act on it.
        #expect(nav.selectedProjectRows.map(\.objectID) == [project.objectID])
        #expect(nav.navigatorOutline.selectedRowIndexes.count == 1
            && (nav.navigatorOutline.item(atRow: nav.navigatorOutline.selectedRow) as? OutlineItem)?.objectID == Ops.model)
        nav.endContextMenu()
        runLoop(0.05)
        #expect(nav.selectedProjectRows.map(\.objectID) == [Ops.model])
        // A group row adds Open in New Tabs.
        let group = try #require(ops.row(wc, id: Ops.navGroup))
        let gt = nav.projectContextMenu(for: group).items.map(\.title)
        #expect(gt.contains("Open in New Tabs") && gt.contains("Delete") && !gt.contains("New Group"))
        nav.endContextMenu()
        runLoop(0.05)
        // Source Control is a submenu.
        let file = try #require(ops.row(wc, id: Ops.model))
        let fm = nav.projectContextMenu(for: file)
        #expect(fm.item(withTitle: "Source Control")?.submenu?.items.map(\.title).contains("Commit…") == true)
        #expect(fm.item(withTitle: "Open in New Window")?.isEnabled == false)
        nav.endContextMenu()
    }

    // MARK: P-042 — drag

    @Test func dragShowsTheInsertionLineAndATranslucentImage() throws {
        let s = try Ops.Sample()
        defer { s.remove() }
        let wc = try s.window()
        let nav = wc.navigator
        #expect(nav.navigatorOutline.draggingDestinationFeedbackStyle == .regular)
        let file = try #require(Ops().row(wc, id: Ops.model))
        let parts = nav.dragImageComponents(for: file)
        #expect(parts.map(\.key) == [.icon, .label])
        #expect(NavigatorAreaController.dragImageAlpha < 1)
    }

    // MARK: P-199 — selecting a file

    func mouse(_ type: NSEvent.EventType, clicks: Int, mods: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                           context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    @Test func aPlainClickOpensOnThePressAndTheReleaseDoesNotReopen() throws {
        #expect(NavigatorAreaController.opensOnPress(mouse(.leftMouseDown, clicks: 1)))
        #expect(!NavigatorAreaController.opensOnPress(mouse(.leftMouseDown, clicks: 2)))
        #expect(!NavigatorAreaController.opensOnPress(mouse(.leftMouseDown, clicks: 1, mods: .option)))
        #expect(!NavigatorAreaController.opensOnPress(mouse(.leftMouseUp, clicks: 1)))
        let s = try Ops.Sample()
        defer { s.remove() }
        let wc = try s.window()
        let nav = wc.navigator
        let path = s.path("Nav/Model.swift")
        var opened: [String] = []
        let original = nav.onOpen
        nav.onOpen = { p, l in opened.append(p); original?(p, l) }
        nav.openOnPress(path, line: nil)
        #expect(opened == [path] && nav.fileOpenedOnPress == path)
        #expect(wc.editor.fileURL?.path == path)
        // The release of the same press opens nothing more.
        #expect(nav.pressOpened(path) && nav.fileOpenedOnPress == nil)
        #expect(!nav.pressOpened(path))
        nav.onOpen = original
    }

    /// The work a file selection does before the editor shows it (P-199:
    /// a file shows in ≈ 0.2 s). A short file opens well inside a frame
    /// budget; a 400-line one is printed with the syntax pass's share (the
    /// editor's synchronous parser pass, see docs/beta5/b5-navigator.md).
    @Test func openingASelectedFileIsQuick() throws {
        let s = try Ops.Sample()
        defer { s.remove() }
        let wc = try s.window()
        var long = ""
        for i in 0..<400 { long += "func f\(i)() -> Int { let x = \(i); return x * 2 }\n" }
        try long.write(toFile: s.path("Nav/Helpers.swift"), atomically: true, encoding: .utf8)
        func timed(_ p: String) -> Double {
            let t0 = ProcessInfo.processInfo.systemUptime
            wc.openFromNavigator(path: s.path(p), line: nil, modifiers: [])
            wc.window?.contentView?.layoutSubtreeIfNeeded()
            wc.window?.displayIfNeeded()
            return (ProcessInfo.processInfo.systemUptime - t0) * 1000
        }
        _ = timed("Nav/main.swift")   // warm
        let small = [timed("Nav/Model.swift"), timed("Nav/main.swift"), timed("Nav/Model.swift")]
        let large = timed("Nav/Helpers.swift")
        _ = timed("Nav/Model.swift")
        let t0 = ProcessInfo.processInfo.systemUptime
        wc.editor.textView.string = long
        wc.editor.resetSyntax()
        let syntax = (ProcessInfo.processInfo.systemUptime - t0) * 1000
        print("P-199 open+layout+display ms: small \(small.map { Int($0) }), 400 lines \(Int(large)) (syntax pass \(Int(syntax)))")
        #expect(small.min()! < 100)
    }

    // MARK: P-043 — inline rename and new groups

    @Test func renameFieldIsBorderlessAndNewGroupsShowAnOpenTriangle() throws {
        let s = try Ops.Sample()
        defer { s.remove() }
        let wc = try s.window()
        let nav = wc.navigator
        let ops = Ops()
        ops.select(wc, ids: [Ops.model])
        let file = try #require(ops.row(wc, id: Ops.model))
        nav.beginRename(file)
        let r = nav.navigatorOutline.row(forItem: file)
        let field = (nav.navigatorOutline.view(atColumn: 0, row: r, makeIfNecessary: false) as? NSTableCellView)?.textField
        #expect(field?.isBordered == false && field?.isBezeled == false && field?.focusRingType == NSFocusRingType.none)
        nav.commitRename("Model.swift")
        // A new empty group: an open disclosure triangle.
        ops.select(wc, ids: [Ops.navGroup])
        _ = wc.newNavigatorGroup(withFolder: false)
        let o = nav.navigatorOutline
        let newRow = (0..<o.numberOfRows).compactMap { o.item(atRow: $0) as? OutlineItem }.first { $0.title.hasPrefix("New Group") }
        #expect(newRow != nil)
        if let newRow {
            #expect(o.isExpandable(newRow) && o.isItemExpanded(newRow))
        }
    }
}
