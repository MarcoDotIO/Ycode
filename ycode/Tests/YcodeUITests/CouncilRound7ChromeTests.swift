import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

/// Council round 7, group D, main-window chrome and state
/// (`specs/ide/fidelity-council.md` rows 186–195; `workspace-window.md`
/// W7.1–W7.6, `navigators.md` round 7, `merge-sheet.md` §16), on the
/// macOS IDE. Windows stay off every display.
@MainActor
@Suite(.serialized) struct CouncilRound7ChromeTests {
    func spin(_ seconds: Double, until done: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    }

    /// A council window with its user data at `state`, off every display.
    func window(_ dir: URL, state: URL, width: CGFloat = 1400) throws -> WorkspaceWindowController {
        _ = NSApplication.shared
        let model = try WorkspaceModel(url: dir.appendingPathComponent("GlassScroll.xcodeproj"))
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: model), loadDestinations: false, startLanguageService: false,
                                           openFirstFile: false, userStateURL: state)
        wc.window?.appearance = NSAppearance(named: .darkAqua)
        wc.window?.isExcludedFromWindowsMenu = true
        wc.window?.setFrame(NSRect(x: -6000, y: -6000, width: width, height: 880), display: false)
        wc.window?.orderBack(nil)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        return wc
    }

    // MARK: Row 186: restore on reopen

    /// X15 → R01: a split with Long.swift on the left (scrolled, a
    /// selection) and Model01.swift on the right, active; the File
    /// inspector shown. A new window on the same user data brings it all
    /// back, and its title follows the active pane.
    @Test func reopenRestoresTheSplitTheActivePaneAndTheInspector() throws {
        let dir = try FidelityCouncilTests().project("r7d-restore")
        let state = dir.appendingPathComponent("ycode-ui-state.json")
        let long = dir.appendingPathComponent("GlassScroll/Long.swift").path
        let model01 = dir.appendingPathComponent("GlassScroll/Models/Model01.swift").path
        do {
            let wc = try window(dir, state: state)
            defer { wc.window?.orderOut(nil); wc.close() }
            wc.open(path: long, line: nil)
            wc.splitEditor(nil)
            wc.open(path: model01, line: nil)
            wc.window?.contentView?.layoutSubtreeIfNeeded()
            let left = wc.editorArea.tab.editors[0]
            left.scroll(toTopLine: 30)
            left.textView.setSelectedRange(NSRange(location: 40, length: 5))
            #expect(left.firstVisibleLine == 30)
            #expect(wc.windowTitle == "GlassScroll \u{2014} Model01.swift")
            let saved = wc.currentEditorLayout
            #expect(saved.panes.map(\.path) == [long, model01] && saved.focused == 1 && saved.sideBySide)
            #expect(saved.panes[0].topLine == 30 && saved.panes[0].selectionStart == 40 && saved.panes[0].selectionLength == 5)
            #expect(abs(saved.fractions[0] - 0.5) < 0.01)
            wc.window?.close()   // File ▸ Close Window saves it
        }
        let file = WorkspaceUserState.load(from: state)
        #expect(file.editorLayout?.panes.map(\.path) == [long, model01])
        #expect(file.inspector == WorkspaceInspectorState(isShown: true, tab: 0))

        let wc = try window(dir, state: state)
        defer { wc.window?.orderOut(nil); wc.close() }
        spin(0.2)
        let t = wc.editorArea.tab
        #expect(t.editors.count == 2 && t.sideBySide && t.focused == 1)
        #expect(t.editors.map { $0.fileURL?.path } == [long, model01])
        #expect(wc.windowTitle == "GlassScroll \u{2014} Model01.swift" && wc.window?.title == wc.windowTitle)
        #expect(!wc.inspectorItem.isCollapsed && wc.inspector.selectedIndex == 0)
        #expect(wc.inspector.file?.path == model01)
        let left = t.editors[0]
        #expect(left.textView.selectedRange() == NSRange(location: 40, length: 5))
        #expect(left.firstVisibleLine == 30, "first line \(left.firstVisibleLine)")
        let widths = t.editors.map { $0.view.frame.width }
        #expect(abs(widths[0] - widths[1]) <= 2, "\(widths)")
        // The navigator selects no row on reopen (navigators.md round 7 §4).
        #expect(wc.navigator.outlineView.selectedRow == -1)
    }

    /// A hidden inspector on its Quick Help tab comes back hidden, on that tab.
    @Test func reopenRestoresAHiddenInspector() throws {
        let dir = try FidelityCouncilTests().project("r7d-restore-hidden")
        let state = dir.appendingPathComponent("ycode-ui-state.json")
        var s = WorkspaceUserState()
        s.inspector = WorkspaceInspectorState(isShown: false, tab: 2)
        s.editorLayout = WorkspaceEditorLayout(panes: [.init(path: dir.appendingPathComponent("GlassScroll/Long.swift").path)])
        s.save(to: state)
        let wc = try window(dir, state: state)
        defer { wc.window?.orderOut(nil); wc.close() }
        #expect(wc.inspectorItem.isCollapsed && wc.inspector.selectedIndex == 2)
        #expect(wc.editorArea.tab.editors.count == 1 && wc.windowTitle == "GlassScroll \u{2014} Long.swift")
    }

    // MARK: Row 187: the navigator's expansion on reopen

    @Test func reopenOpensRowsBelowTheMainGroupsChildrenCollapsed() throws {
        _ = NSApplication.shared
        let root = CouncilRound6ChromeTests.councilTree()
        let saved = ["/tmp/r6/GlassScroll.xcodeproj", "/tmp/r6/GlassScroll", "PLAIN", "SUB"]
        let nav = NavigatorAreaController()
        let win = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 280, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = nav.view
        nav.view.frame = NSRect(x: 0, y: 0, width: 280, height: 600)
        nav.savedProjectExpansion = NavigatorTree.reopenedExpansion(saved, root: root)
        nav.setProjectTree(root)
        nav.view.layoutSubtreeIfNeeded()
        nav.select(0)
        let o = nav.outlineView
        let rows = (0..<o.numberOfRows).compactMap { o.item(atRow: $0) as? OutlineItem }
        let expanded = rows.filter { o.isItemExpanded($0) }.map(\.title)
        #expect(expanded.contains("Plain") && !expanded.contains("Sub") && !expanded.contains("Models"), "\(expanded)")
        #expect(rows.contains { $0.title == "Sub" })
    }
}

/// Row 188 on macOS: under the merge sheet the issue capsule fades to the
/// glyphs' disabled tone, the rest of the toolbar's views to the text tone.
@MainActor
@Suite struct CouncilRound7CapsuleToneTests {
    @Test func capsuleDimsAtTheGlyphTone() {
        _ = NSApplication.shared
        #expect(ModalParentDimming.tone(of: IssueCapsuleView()) == 0.33)
        #expect(ModalParentDimming.tone(of: NSView()) == ModalParentDimming.textTone)
        // Dark: #FF453A-ish red over the toolbar's #2A2A2A at 0.33 is about the reference's #6F2A27.
        let red = 0x45 * 0.33 + 0x2A * 0.67
        #expect(abs(red - 0x2A) < 12)
    }
}

/// Row 192 on macOS: the project's row shows the Ycode mark, a Swift file
/// the Swift logo (both full colour, not tinted), a folder its glyph.
@MainActor
@Suite struct CouncilRound7NavigatorIconUITests {
    @Test func rowsDrawTheLogosAndTheMark() throws {
        _ = NSApplication.shared
        let root = CouncilRound6ChromeTests.councilTree()
        let nav = NavigatorAreaController()
        let win = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 280, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = nav.view
        nav.view.frame = NSRect(x: 0, y: 0, width: 280, height: 600)
        nav.savedProjectExpansion = ["/tmp/r6/GlassScroll.xcodeproj", "/tmp/r6/GlassScroll"]
        nav.setProjectTree(root)
        nav.view.layoutSubtreeIfNeeded()
        nav.select(0)
        let o = nav.outlineView
        func image(_ title: String) -> NSImage? {
            guard let row = (0..<o.numberOfRows).first(where: { (o.item(atRow: $0) as? OutlineItem)?.nodePath?.hasSuffix("/" + title) == true }),
                  let cell = o.view(atColumn: 0, row: row, makeIfNecessary: true) else { return nil }
            return cell.subviews.compactMap { $0 as? NSImageView }.first?.image
        }
        let mark = try #require(image("GlassScroll.xcodeproj"))
        // Round 9 (rows 208, 213): the mark in a 15-point box; the Swift
        // glyph a single-colour template (the bird) in the 14.5 × 12.5 box.
        #expect(mark.accessibilityDescription == "Ycode project" && !mark.isTemplate && mark.size == NSSize(width: 15, height: 15))
        o.expandItem(nil, expandChildren: true)
        let swift = try #require(image("Long.swift"))
        #expect(swift.accessibilityDescription == "swift" && swift.isTemplate && swift.size == NSSize(width: 14.5, height: 12.5))
    }
}

/// Row 194 on macOS: the Welcome recent row's title and path at the
/// reference's sizes, the council's path whole, Ycode's own icon, the path
/// #B3CEF1 on the selection.
@MainActor
@Suite(.serialized) struct CouncilRound7WelcomeTests {
    @Test func recentRowFitsTheWholePathWithYcodesIcon() throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let base = URL(fileURLWithPath: "/private/tmp/ycode-council-r7-\(UUID().uuidString.prefix(4))/council-r7/xcode/project")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        let proj = base.appendingPathComponent("GlassScroll.xcodeproj")
        try fm.createDirectory(at: proj, withIntermediateDirectories: true)
        let td = TestDefaults("r7-welcome")
        defer { td.remove() }
        let recents = RecentProjects(defaults: td.defaults)
        recents.note(proj)
        let w = WelcomeWindowController(recents: recents)
        defer { w.window?.close() }
        w.window?.contentView?.layoutSubtreeIfNeeded()
        let cell = try #require(w.tableView(w.table, viewFor: nil, row: 0) as? RecentCellView)
        cell.frame = NSRect(x: 0, y: 0, width: w.recentsBox.frame.width, height: 47)
        cell.layoutSubtreeIfNeeded()
        let title = try #require(cell.textField), path = try #require(cell.pathField)
        #expect(title.font?.pointSize == 12.4 && path.font?.pointSize == 10)
        #expect(path.lineBreakMode == .byTruncatingMiddle)
        // The path (54 characters in the capture) fits: about 4.9 points a character.
        let needed = (path.stringValue as NSString).size(withAttributes: [.font: path.font!]).width
        #expect(needed / CGFloat(path.stringValue.count) < 5.1, "\(needed)")
        #expect(needed <= path.frame.width + 0.5 || path.frame.width == 0, "\(needed) in \(path.frame.width)")
        #expect(path.frame.minX == title.frame.minX)
        // Ycode's own icon, not the system's document icon.
        #expect(cell.imageView?.image === ProductIcon.image)
        cell.backgroundStyle = .emphasized
        #expect(path.textColor == RecentCellView.selectedPath)
        cell.backgroundStyle = .normal
        #expect(path.textColor == .secondaryLabelColor)
    }
}

/// Row 195 on macOS (`merge-sheet.md` §16.1): the alert's children as the
/// reference exposes them.
@MainActor
@Suite struct CouncilRound7AlertTests {
    @Test func alertChildrenMatchTheReference() throws {
        _ = NSApplication.shared
        let alert = MergeAlertView(branch: "feature", current: "main")
        let win = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView?.addSubview(alert)
        alert.layoutSubtreeIfNeeded()
        #expect(alert.frame.size == NSSize(width: 420, height: 132))
        #expect(alert.accessibilityLabel() == nil)
        let kids = try #require(alert.accessibilityChildren())
        #expect((kids[0] as AnyObject) === alert.statusImage && alert.statusImage.accessibilityLabel() == nil)
        #expect(alert.statusImage.frame.size == NSSize(width: 18, height: 18) && alert.statusImage.frame.minX == 20)
        #expect(alert.statusImage.frame.maxY == 112)   // the alert's bottom left
        #expect(alert.iconView.accessibilityFrame().size == NSSize(width: 66, height: 66))
        #expect(alert.titleField.accessibilityFrame().size == NSSize(width: 296, height: 34))
        #expect(alert.messageField.accessibilityFrame().size == NSSize(width: 296, height: 30))
        for b in [alert.mergeButton, alert.cancelButton] {
            #expect(b.accessibilityLabel() == nil && b.accessibilityTitle() == b.title)
        }
        win.close()
    }
}

/// Row 193 on macOS (W7.5): the Widths row's fields and steppers.
@MainActor
@Suite(.serialized) struct CouncilRound7WidthsTests {
    @Test func widthsAreFieldsWithSteppers() throws {
        let dir = try FidelityCouncilTests().project("r7d-widths")
        let wc = try FidelityCouncilTests().window(dir)
        wc.window?.setFrame(NSRect(x: -6000, y: -6000, width: 1180, height: 880), display: false)
        wc.open(path: dir.appendingPathComponent("GlassScroll/Long.swift").path, line: nil)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        let i = wc.inspector
        let tab = try #require(i.fileControls["Tab Value"] as? NSTextField), indent = try #require(i.fileControls["Indent Value"] as? NSTextField)
        let ts = try #require(i.fileControls["Tab"] as? NSStepper), inds = try #require(i.fileControls["Indent"] as? NSStepper)
        #expect(tab.isEditable && tab.alignment == .right && tab.isBezeled)
        wc.inspector.view.layoutSubtreeIfNeeded()
        #expect((63...65).contains(tab.frame.width) && (64...65).contains(indent.frame.width) && tab.frame.height == 21, "\(tab.frame) \(indent.frame) \(wc.inspector.view.frame)")
        #expect(ts.frame.size == NSSize(width: 19, height: 24) && inds.frame.size == NSSize(width: 19, height: 24))
        let t = { (v: NSView) in v.convert(v.bounds, to: nil) }
        #expect(t(ts).minX == t(tab).maxX && t(indent).minX - t(ts).maxX == 5)
        // Typing a width sets it; nonsense puts the value back.
        let before = Preferences.shared.tabWidth
        defer { Preferences.shared.tabWidth = before }
        tab.stringValue = "7"
        _ = tab.sendAction(tab.action, to: tab.target)
        #expect(Preferences.shared.tabWidth == 7 && ts.integerValue == 7)
        tab.stringValue = "x"
        _ = tab.sendAction(tab.action, to: tab.target)
        #expect(tab.stringValue == "7")
        wc.close()
    }
}

/// Row 189 on macOS: while the language server indexes, the activity view
/// shows a second line under the title.
@MainActor
@Suite(.serialized) struct CouncilRound7SubtitleUITests {
    @Test func indexingShowsTheSubtitle() throws {
        let dir = try FidelityCouncilTests().project("r7d-subtitle")
        let wc = try FidelityCouncilTests().window(dir)
        defer { wc.close() }
        wc.session.isIndexing = true
        #expect(wc.activityView.status == WorkspaceChrome.indexingText)
        wc.session.isIndexing = false
        #expect(wc.activityView.status.isEmpty)
    }
}
