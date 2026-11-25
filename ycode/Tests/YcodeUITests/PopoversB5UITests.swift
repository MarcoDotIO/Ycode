import AppKit
import CYcodeTestOffscreen
import Foundation
import Testing
import YcodeBuild
@testable import YcodeIDECore
@testable import YcodeUI
import YcodeWorkspace

private let worktree = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

/// Beta 5's popovers on macOS (B5-POPOVERS, `specs/ide/popovers.md`): the
/// scheme and destination choosers as popovers opened on mouse-down
/// (P-111, P-113, P-195), the New Scheme sheet (P-112), Quick Help above
/// the symbol (P-083), the Jump to Line and Quick Actions capsules (P-086),
/// Quick New Project (P-180), Product ▸ Destination's rows (P-014) and
/// the workspace's active look behind them (P-031). Every window stays
/// off the displays (the offscreen guard); screenshots go to
/// `.build-ide/b5-shots/` through the guard's capture.
@MainActor
@Suite(.serialized) struct PopoversB5UITests {
    func tempDir(_ tag: String) throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-b5-popovers-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u.resolvingSymlinksInPath()
    }

    func iosApp(in dir: URL, name: String = "Parity") throws -> URL {
        var o = ProjectOptions()
        o.productName = name
        o.organizationIdentifier = "org.ycode.tests"
        o.testing = .none
        o.setStorage(.none)
        return try ProjectTemplate.app.create(platform: "iOS", options: o, in: dir)
    }

    /// A workspace window on screen as far as AppKit knows (the guard keeps
    /// it off every display), 1400 × 880 like the capture's.
    func window(_ url: URL) throws -> WorkspaceWindowController {
        try #require(YcodeOffscreenIsActive(), "the offscreen guard is not installed")
        _ = NSApplication.shared
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: url)), loadDestinations: false,
                                           startLanguageService: false, openFirstFile: false, userStateURL: nil)
        wc.window?.setContentSize(NSSize(width: 1400, height: 880))
        wc.showWindow(nil)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        pump()
        return wc
    }

    func pump(_ s: Double = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    func shot(_ w: NSWindow?, _ name: String) {
        guard let w else { return }
        let dir = worktree.appendingPathComponent(".build-ide/b5-shots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        w.displayIfNeeded()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l\(w.windowNumber)", dir.appendingPathComponent("macos-\(name).png").path]
        let url = dir.appendingPathComponent("macos-\(name).png")
        YcodeOffscreenOpaqueDuringCapture(w) {
            try? p.run()
            p.waitUntilExit()
        }
        // Without screen-capture access the window is drawn offscreen
        // instead (its frame view: the popover's or panel's material as
        // AppKit draws it into a bitmap).
        guard !FileManager.default.fileExists(atPath: url.path), let v = w.contentView?.superview ?? w.contentView,
              let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// A left mouse-down on a view's centre.
    func mouseDown(on v: NSView) -> NSEvent {
        let p = v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil)
        return NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: v.window?.windowNumber ?? 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }

    // MARK: P-111, P-195: the scheme chooser

    @Test func schemeChooserIsAPopoverOpenedOnMouseDown() throws {
        let dir = try tempDir("scheme")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wc = try window(try iosApp(in: dir))
        defer { wc.close() }
        wc.schemePopUp.mouseDown(with: mouseDown(on: wc.schemePopUp))
        let popover = try #require(AnchoredPopover.shown)
        #expect(popover.isShown && !popover.animates, "one frame in, no menu")
        #expect(popover.behavior == .transient, "a click outside closes it")
        let c = try #require(popover.contentViewController as? ChooserPopoverController)
        #expect(c.list.rows.map(\.title) == ["Parity", "", "Edit Scheme…", "New Scheme…", "Manage Schemes…"])
        #expect(c.list.highlighted == 0 && c.list.rows[0].isChecked)
        #expect(popover.contentSize == NSSize(width: 213, height: 163))
        #expect(c.field.placeholderString == "Filter" && c.field.focusRingType == .none)
        #expect(wc.schemePopUp.isHighlighted, "the half stays pressed while open")
        // Anchored to the scheme half over the capsule's full height (the
        // system centres it there; where it lands on screen cannot be read
        // here: the guard parks the popover's window on its own).
        let pw = try #require(c.view.window)
        let host = try #require(wc.schemePopUp.superview)
        #expect(popover.positioningRect == NSRect(x: wc.schemePopUp.frame.minX, y: host.bounds.minY, width: wc.schemePopUp.frame.width,
                                                  height: host.bounds.height))
        #expect(pw.parent === wc.window || pw.parent == nil)
        #expect(!pw.canBecomeMain, "the workspace stays the main window (P-031)")
        shot(pw, "scheme-chooser")
        // Down moves the highlight; Escape closes in one frame.
        _ = c.control(c.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:)))
        #expect(c.list.current?.title == "Edit Scheme…")
        _ = c.control(c.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        pump()
        #expect(!popover.isShown && !wc.schemePopUp.isHighlighted)
        // Choose Scheme (⌃0) opens the same popover.
        wc.chooseScheme(nil)
        #expect(AnchoredPopover.shown?.isShown == true && AnchoredPopover.shown !== popover)
        AnchoredPopover.shown?.performClose(nil)
        pump()
    }

    // MARK: P-112: New Scheme

    @Test func newSchemeSheetWritesAndSelectsTheScheme() throws {
        let dir = try tempDir("newscheme")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wc = try window(try iosApp(in: dir))
        defer { wc.close() }
        let c = wc.showSchemeChooser()
        let i = try #require(c.list.rows.firstIndex { $0.title == "New Scheme…" })
        c.choose(i)
        pump(0.2)
        let sheet = try #require(wc.window?.attachedSheet?.contentViewController as? NewSchemeSheetController,
                                 "sheet \(String(describing: wc.window?.attachedSheet)) sheets \(wc.window?.sheets ?? []) presented \(wc.contentViewController?.presentedViewControllers ?? [])")
        #expect(sheet.view.frame.size == NSSize(width: 493, height: 122))
        #expect(sheet.okButton.frame == NSRect(x: 389, y: 82, width: 84, height: 23))
        #expect(sheet.okButton.keyEquivalent == "\r" || sheet.view.window?.defaultButtonCell === sheet.okButton.cell,
                 "OK is the default button: \(Array(sheet.okButton.keyEquivalent.unicodeScalars))")
        #expect(sheet.cancelButton.frame == NSRect(x: 293, y: 82, width: 84, height: 23) && sheet.cancelButton.keyEquivalent == "\u{1b}")
        #expect(sheet.targetPopUp.titleOfSelectedItem == "Parity" && sheet.nameField.stringValue == "Parity")
        // Centred on the window both ways (§3, §7).
        let s = try #require(wc.window?.attachedSheet), w = try #require(wc.window)
        #expect(abs(s.frame.midX - w.frame.midX) <= 2)
        shot(s, "new-scheme")
        sheet.choose(target: 0, name: "Parity Release")
        let made = try #require(sheet.create())
        pump(0.2)
        #expect(made.isShared && FileManager.default.fileExists(atPath: made.url!.path))
        #expect(wc.session.scheme == "Parity Release" && wc.session.model.schemeNames.contains("Parity"))
        #expect(wc.schemePopUp.titleOfSelectedItem == "Parity Release")
    }

    // MARK: P-113: the destination chooser

    @Test func destinationChooserExpandsIncompatibleInPlace() throws {
        let dir = try tempDir("destination")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wc = try window(try iosApp(in: dir))
        defer { wc.close() }
        let sim = Destination(name: "iPhone 17", specifier: "platform=iOS Simulator,id=A", platform: "iOS", kind: .simulator, osVersion: "27.1",
                              identifier: "A")
        let watch = Destination(name: "Watch 11", specifier: "platform=watchOS Simulator,id=B", platform: "watchOS", kind: .simulator,
                                osVersion: "27.1", identifier: "B")
        wc.setDestinationGroups([DestinationGroup(title: "Simulators", destinations: [sim, watch])])
        wc.session.destination = sim
        wc.rebuildDestinationMenu()
        wc.destinationPopUp.mouseDown(with: mouseDown(on: wc.destinationPopUp))
        let popover = try #require(AnchoredPopover.shown)
        let c = try #require(popover.contentViewController as? ChooserPopoverController)
        #expect(c.bodyWidth == 415)
        #expect(c.list.rows.first?.title == "Recent" && c.list.rows[1].title == "iPhone 17" && c.list.rows[1].trailing == "27.1")
        #expect(c.list.rows.filter { $0.title == "iPhone 17" }.count == 1, "listed once")
        let inc = try #require(c.list.rows.firstIndex { $0.title == "Incompatible" })
        #expect(c.list.rows[inc].isEnabled)
        let before = popover.contentSize.height
        shot(c.view.window, "destination-chooser")
        // Down to Incompatible, then Right: it expands in place, in one frame.
        c.rowsView.list.highlighted = inc
        _ = c.control(c.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveRight(_:)))
        #expect(c.expanded && c.list.rows[inc].kind == .disclosure(expanded: true))
        #expect(c.list.rows[inc + 1].title.hasPrefix("Watch 11") && c.list.rows.last?.title == "Manage Devices…")
        #expect(c.preferredContentSize.height > before, "grows downward")
        shot(c.view.window, "destination-incompatible")
        // Choosing an incompatible destination switches to it.
        c.choose(inc + 1)
        pump()
        #expect(wc.session.destination?.identifier == "B" && !popover.isShown)
    }

    // MARK: P-083: Quick Help above the symbol

    @Test func quickHelpOpensAboveTheSymbolCentred() throws {
        let dir = try tempDir("quickhelp")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try iosApp(in: dir)
        let wc = try window(url)
        defer { wc.close() }
        let file = try #require(wc.session.model.root.allFiles.first { $0.name == "ContentView.swift" }?.path)
        wc.open(path: file, line: nil)
        pump(0.2)
        let tv = wc.editor.textView
        #expect(AnchoredPopover.rectEdge(.above, flipped: tv.isFlipped) == (tv.isFlipped ? .minY : .maxY))
        let ns = tv.string as NSString
        let at = ns.range(of: "ContentView").location
        try #require(at != NSNotFound)
        let caret = try #require((tv as? SourceTextView)?.segmentRects(NSRange(location: at + 3, length: 0)).first)
        let symbol = QuickHelpPopover.symbolRect(in: tv, near: caret)
        #expect(symbol.width > caret.width + 20, "the whole word, not the caret")
        let anchor = QuickHelpPopover.anchor(symbol: symbol, flipped: tv.isFlipped)
        #expect(anchor.minY == symbol.minY - 3 && anchor.midX == symbol.midX)
        let doc = QuickHelpDocument(hover: "```swift\nstruct ContentView\n```\n---\nA view.", file: file)
        let c = QuickHelpPopover.show(doc, at: caret, in: tv)
        let popover = try #require(AnchoredPopover.shown)
        #expect(popover.isShown && popover.contentViewController === c)
        #expect(c.preferredContentSize.width == CGFloat(PopoverMetrics.quickHelpBodyWidth))
        let pw = try #require(c.view.window)
        // Anchored to the whole word raised by 3, on the edge above it (the
        // system centres it there).
        #expect(popover.positioningRect == anchor)
        shot(pw, "quick-help")
        popover.performClose(nil)
        pump()
    }

    // MARK: P-086, P-031, P-195: the capsules

    @available(macOS 26, *)
    func panel(of c: NSViewController) -> GlassPanel? { c.view.window as? GlassPanel ?? c.view.superview?.window as? GlassPanel }

    @Test func jumpToLineAndQuickActionsAreCapsulesUnderTheToolbar() throws {
        guard #available(macOS 26, *) else { return }
        let dir = try tempDir("capsules")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wc = try window(try iosApp(in: dir))
        defer { wc.close() }
        let file = try #require(wc.session.model.root.allFiles.first { $0.name == "ContentView.swift" }?.path)
        wc.open(path: file, line: nil)
        pump(0.2)
        let w = try #require(wc.window)
        let toolbarBottom = w.contentView!.bounds.height - w.contentLayoutRect.height
        // Jump to Line: 640 × 55, centred, 17 under the toolbar.
        let jump = wc.showJumpToLinePanel()
        let jp = try #require(panel(of: jump))
        #expect(jp.frame.size == NSSize(width: 640, height: 55))
        #expect(abs(jp.frame.midX - w.frame.midX) <= 1)
        #expect(abs((w.frame.maxY - jp.frame.maxY) - (toolbarBottom + 17)) <= 1)
        #expect(!jp.canBecomeMain && jp.parent === w, "a child panel: the workspace keeps its active look")
        #expect(w.attachedSheet == nil, "not a sheet: nothing dims")
        #expect(jump.field.placeholderString == "Line Number" && jump.field.focusRingType == .none && !jump.field.isBordered)
        shot(jp, "jump-to-line")
        jump.setQuery("3")
        jump.submit()
        pump()
        #expect(!jp.isVisible, "Return jumps and closes in one frame")
        #expect(wc.editor.caretPosition.line == 2)
        // Escape fades it out (120–165 ms).
        let again = wc.showJumpToLinePanel()
        let ap = try #require(panel(of: again))
        again.onCancel?()
        pump(0.05)
        #expect(ap.isVisible, "still fading")
        pump(0.4)
        #expect(!ap.isVisible)
        // Quick Actions: 560 × 55, 3 under the toolbar, empty until typed.
        let qa = try #require(wc.showQuickActions(nil))
        let qp = try #require(panel(of: qa))
        #expect(qp.frame.size == NSSize(width: 560, height: 55) && qa.shown.isEmpty)
        #expect(abs((w.frame.maxY - qp.frame.maxY) - (toolbarBottom + 3)) <= 1)
        #expect(qa.field.placeholderString == "Quick Actions")
        shot(qp, "quick-actions")
        let top = qp.frame.maxY
        qa.setQuery("build")
        #expect(qa.shown.first?.title == "Build" && qp.frame.height > 55 && qp.frame.maxY == top, "grows downward")
        shot(qp, "quick-actions-build")
        qa.onCancel?()
        pump()
        #expect(!qp.isVisible, "Escape: one frame")
    }

    // MARK: P-180: Quick New Project

    @Test func quickNewProjectIsAnInWindowPanel() throws {
        guard #available(macOS 26, *) else { return }
        let dir = try tempDir("qnp")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wc = try window(try iosApp(in: dir))
        defer { wc.close() }
        let c = wc.showQuickNewProject()
        let p = try #require(panel(of: c))
        #expect(p.frame.size == NSSize(width: 640, height: 355))
        #expect(c.shown.map(\.title) == NewProjectPicker.rows.map(\.title) && c.shown.map(\.detail) == NewProjectPicker.rows.map(\.subtitle))
        #expect(wc.window?.attachedSheet == nil)
        shot(p, "quick-new-project")
        c.move(1)
        #expect(c.selected == 1)
        c.setQuery("template")
        #expect(c.shown.first?.title == "Choose Template…")
        c.onCancel?()
        pump()
        #expect(!p.isVisible)
    }

    // MARK: P-014: Product ▸ Destination

    @Test func productDestinationRows() throws {
        let dir = try tempDir("menu")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wc = try window(try iosApp(in: dir))
        defer { wc.close() }
        let watch = Destination(name: "Watch 11", specifier: "platform=watchOS Simulator,id=B", platform: "watchOS", kind: .simulator,
                                osVersion: "27.1", identifier: "B")
        wc.setDestinationGroups([DestinationGroup(title: "Simulators", destinations: [watch])])
        let product = try #require(MainMenu.make().items.first { $0.title == "Product" }?.submenu)
        let m = try #require(product.items.first { $0.title == "Destination" }?.submenu)
        DynamicMenus.fillDestinationMenu(m, model: wc.destinationMenuModel(), current: wc.session.destination, target: wc)
        let shown = m.items.filter { !$0.isHidden }
        #expect(!shown.contains { $0.isSectionHeader && $0.title == "Simulators" }, "no empty heading")
        #expect(shown.contains { $0.title == "Any iOS Device (arm64)" })
        let inc = try #require(m.items.first { $0.title == "Incompatible" }?.submenu)
        let row = try #require(inc.items.first)
        #expect(row.isEnabled && row.title.hasPrefix("Watch 11") && row.title.hasSuffix("27.1"))
        wc.selectDestinationRow(row)
        #expect(wc.session.destination?.identifier == "B", "choosing an incompatible destination switches to it")
    }
}
