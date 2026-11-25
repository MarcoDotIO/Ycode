import AppKit
import CYcodeTestOffscreen
import Foundation
import Testing
import YcodeBuild
import YcodeDeviceUI
@testable import YcodeIDECore
import YcodeLanguage
@testable import YcodeUI
import YcodeWorkspace

private let worktree = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

/// The beta 5 fix round's popovers on macOS (B5-FIX-POPOVERS, council
/// round 12): the destination chooser's initial highlight (P-113,
/// `popovers.md` §2.7), Quick Help's 417-point popover, declaration box and
/// module help (P-083, §4.1–§4.2), Quick Actions' two-line rows (P-086,
/// §5.1) and Ycode's own tooltips (P-197, `control-states.md` §8, §8.1).
/// Every window stays off the displays (the offscreen guard); pictures go to
/// `.build-ide/b5-shots/`.
@MainActor
@Suite(.serialized) struct B5FixPopoversUITests {
    func tempDir(_ tag: String) throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-b5fix-popovers-\(tag)-\(UUID().uuidString)")
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

    /// The view drawn offscreen over `fill` (the material AppKit draws
    /// behind it on screen: Quick Help's #414141, the capsule's #3F3D3D).
    func shot(_ v: NSView, _ name: String, fill: NSColor = NSColor(srgbRed: 0x41 / 255.0, green: 0x41 / 255.0, blue: 0x41 / 255.0, alpha: 1)) {
        let dir = worktree.appendingPathComponent(".build-ide/b5-shots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: out) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        let r = NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
        fill.setFill()
        r.fill()
        rep.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        try? out.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("macos-b5fix-\(name).png"))
    }

    func moved(_ w: NSWindow, at p: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: .mouseMoved, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
    }

    // MARK: P-113

    @Test func destinationChooserOpensOnTheCheckedRow() throws {
        let dir = try tempDir("destination")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wc = try window(try iosApp(in: dir))
        defer { wc.close() }
        let sim = Destination(name: "iPhone 17", specifier: "platform=iOS Simulator,id=A", platform: "iOS", kind: .simulator, osVersion: "27.1",
                              identifier: "A")
        wc.setDestinationGroups([DestinationGroup(title: "Simulators", destinations: [sim])])
        wc.session.destination = sim
        wc.rebuildDestinationMenu()
        let c = wc.showDestinationChooser()
        #expect(c.list.current?.title == "iPhone 17" && c.list.current?.isChecked == true)
        let titles = c.list.rows.map(\.title)
        let s = try #require(titles.firstIndex(of: "Simulators"))
        let runtime = try #require(titles.firstIndex(of: WorkspaceWindowController.getRuntimeTitle))
        #expect(runtime > s && (titles.firstIndex(of: "Build") ?? .max) > runtime, "Ycode's rows close the Simulators section")
        c.view.appearance = NSAppearance(named: .darkAqua)
        shot(c.view, "destination-chooser", fill: NSColor(srgbRed: 0x44 / 255.0, green: 0x44 / 255.0, blue: 0x46 / 255.0, alpha: 1))
        // The pointer resting over Ycode's rows does not move the highlight;
        // once it moves, hover does.
        let rows = c.rowsView
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 415, height: 400), styleMask: [.borderless], backing: .buffered, defer: true)
        host.isReleasedWhenClosed = false
        defer { host.close() }
        if rows.window == nil { host.contentView = rows }
        let w = try #require(rows.window)
        let y = CGFloat(c.list.rowFrame(runtime, bodyWidth: 415).midY)
        let at = rows.convert(NSPoint(x: 100, y: y), to: nil)
        rows.pointerGate = ChooserPointerGate(origin: w.convertPoint(toScreen: at))
        rows.mouseMoved(with: moved(w, at: at))
        #expect(rows.list.current?.title == "iPhone 17", "the highlight stays on the checked row")
        rows.mouseMoved(with: moved(w, at: NSPoint(x: at.x + 3, y: at.y)))
        #expect(rows.list.current?.title == WorkspaceWindowController.getRuntimeTitle)
    }

    @Test func noCurrentDestinationHighlightsADestination() throws {
        let dir = try tempDir("default")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wc = try window(try iosApp(in: dir))
        defer { wc.close() }
        wc.session.destination = nil
        wc.rebuildDestinationMenu()
        let c = wc.showDestinationChooser()
        let current = try #require(c.list.current)
        // The capsule's row when it names one (checked), else the first destination; never a command.
        #expect(current.kind == .choice, "\(c.list.rows.map { "\($0.title) \($0.isChecked)" }) popup \(String(describing: wc.destinationPopUp.selectedItem?.representedObject))")
    }

    // MARK: P-083

    @Test func quickHelpPopoverIs417WithABorderlessTwoLineDeclaration() throws {
        let doc = QuickHelpDocument(hover: "```swift\nnonisolated let name: String\n```", file: "/tmp/Showcase.swift")
        let c = QuickHelpPopover.content(doc)
        #expect(c.preferredContentSize.width == 417)
        let box = try #require(c.view.b5fixDescendants.compactMap { $0 as? QuickHelpDeclarationBox }.first)
        box.superview?.layoutSubtreeIfNeeded()
        #expect(box.fittingSize == NSSize(width: 385, height: 50) || box.frame.size == NSSize(width: 385, height: 50))
        #expect(box.lines == ["nonisolated", "let name: String"])
        #expect(box.layer?.borderWidth ?? 0 == 0)
        let link = try #require(c.view.b5fixDescendants.compactMap { $0 as? QuickHelpFileLink }.first)
        #expect(link.title == "Showcase.swift" && link.image != nil)
        // About the reference's 417 × 132 for this symbol.
        #expect(abs(c.preferredContentSize.height - 132) <= 20, "height \(c.preferredContentSize.height)")
        c.view.appearance = NSAppearance(named: .darkAqua)
        shot(c.view, "quickhelp-name")
    }

    @Test func moduleQuickHelpForAnImport() async throws {
        let dir = try tempDir("module")
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = try iosApp(in: dir)
        // The module's own catalog, with this test's own text.
        let catalog = dir.appendingPathComponent("Gadgets.docc")
        try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)
        try "# ``Gadgets``\n\nTiny contraptions for tests.\n\n## Overview\n\nGadgets builds contraptions from levers.\n\nEach one is tested.\n"
            .write(to: catalog.appendingPathComponent("Gadgets.md"), atomically: true, encoding: .utf8)
        let wc = try window(project)
        defer { wc.close() }
        let file = try #require(wc.session.model.root.allFiles.first { $0.name == "ContentView.swift" }?.path)
        wc.open(path: file, line: nil)
        pump(0.2)
        let lines = wc.editor.text.components(separatedBy: "\n")
        let n = try #require(lines.firstIndex { $0.hasPrefix("import ") })
        let module = String(lines[n].dropFirst("import ".count))
        let doc = try #require(wc.moduleQuickHelp(at: Position(line: n, character: 9)))
        #expect(doc.isModule && doc.title == module && doc.declaration.isEmpty && !doc.showsFileLink && doc.showsDocumentationLink)
        #expect(wc.moduleQuickHelp(at: Position(line: n, character: 2)) == nil, "the keyword")
        // ⌥-click's path: the popover opens (never nothing), without the language server.
        let title = await wc.showQuickHelp(url: URL(fileURLWithPath: file), at: Position(line: n, character: 9), anchor: NSRect(x: 40, y: 40, width: 8, height: 16))
        #expect(title == module)
        // The catalog's module: title, abstract, hairline, Overview, the link at the bottom right.
        let gadgets = ModuleQuickHelp.document(module: "Gadgets", roots: [dir])
        let c = QuickHelpPopover.content(gadgets)
        #expect(c.preferredContentSize.width == 417)
        let ids = c.view.b5fixDescendants.compactMap { $0.accessibilityIdentifier() }.filter { $0.hasPrefix("quickhelp.") }
        #expect(ids.contains("quickhelp.hairline") && ids.contains("quickhelp.heading") && ids.contains("quickhelp.documentation"))
        #expect(!ids.contains("quickhelp.declaration") && !ids.contains("quickhelp.file"))
        let texts = c.view.b5fixDescendants.compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(texts.contains("Tiny contraptions for tests.") && texts.contains("Overview") && texts.contains("Gadgets builds contraptions from levers."))
        c.view.appearance = NSAppearance(named: .darkAqua)
        shot(c.view, "quickhelp-module")
    }

    // MARK: P-086

    @Test func quickActionsRowsAreTwoLines() throws {
        guard #available(macOS 26, *) else { return }
        let dir = try tempDir("qa")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wc = try window(try iosApp(in: dir))
        defer { wc.close() }
        let qa = try #require(wc.showQuickActions(nil))
        #expect(qa.hairline.isHidden && qa.scroller.isHidden, "empty until typed")
        qa.setQuery("build")
        let e = qa.rowsView.entries
        #expect(e.first?.displayTitle == "Build" && e.first?.subtitle == "Product" && e.first?.symbol == "hammer",
                "\(e.prefix(6).map { "\($0.displayTitle) | \($0.subtitle)" })")
        #expect(qa.shown.first?.title == "Build" && qa.rowsView.selected == 0)
        #expect(!qa.hairline.isHidden && qa.hairline.frame.minY == 55 && qa.scroller.frame.minY == 66)
        #expect(qa.rowsView.frame.height == CGFloat(e.count) * 56)
        #expect(qa.panelHeight == CGFloat(QuickActionRowMetrics.panelHeight(count: e.count)) && qa.panelHeight <= 495)
        let firstNotPrefix = e.firstIndex { !$0.displayTitle.lowercased().hasPrefix("build") } ?? e.count
        #expect(e[firstNotPrefix...].allSatisfy { !$0.displayTitle.lowercased().hasPrefix("build") }, "prefix matches first")
        // "Build Documentation": the match semibold, the rest regular, 17 pt.
        let doc = try #require(e.first { $0.displayTitle == "Build Documentation" })
        let t = QuickActionRowsView.title(doc, query: "build", lit: false, dark: true)
        let matched = try #require(t.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let rest = try #require(t.attribute(.font, at: 8, effectiveRange: nil) as? NSFont)
        #expect(matched.pointSize == 17 && rest.pointSize == 17 && matched != rest)
        qa.view.appearance = NSAppearance(named: .darkAqua)
        shot(qa.view, "quick-actions-first", fill: NSColor(srgbRed: 0x3F / 255.0, green: 0x3D / 255.0, blue: 0x3D / 255.0, alpha: 1))
        qa.move(1)
        #expect(qa.rowsView.selected == 1 && qa.selected == 1)
        shot(qa.view, "quick-actions-build", fill: NSColor(srgbRed: 0x3F / 255.0, green: 0x3D / 255.0, blue: 0x3D / 255.0, alpha: 1))
        qa.onCancel?()
        pump()
    }

    // MARK: P-197

    @Test func tooltipsHoldFadeAndSwap() throws {
        let dir = try tempDir("tooltips")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wc = try window(try iosApp(in: dir))
        defer { wc.close() }
        let w = try #require(wc.window)
        let frame = try #require(w.contentView?.superview)
        let runStop = try #require(frame.b5fixDescendants.compactMap { $0 as? NSSegmentedControl }
            .first { $0.segmentCount == 2 && $0.toolTip(forSegment: 0) == WorkspaceWindowController.runStopToolTips[0] })
        let p = ToolTipPresenter()
        var clock = 0.0
        p.now = { clock }
        func point(_ seg: Int) -> NSPoint {
            let x = runStop.bounds.width * (seg == 0 ? 0.25 : 0.75)
            return runStop.convert(NSPoint(x: x, y: runStop.bounds.midY), to: nil)
        }
        let runHit = try #require(ToolTipPresenter.toolTip(in: w, at: point(0)), "the Run segment's tooltip from a hit test")
        #expect(runHit.text == WorkspaceWindowController.runStopToolTips[0])
        #expect(ToolTipPresenter.toolTip(in: w, at: point(1))?.text == WorkspaceWindowController.runStopToolTips[1])
        // 1.56 s, then one frame.
        p.pointerMoved(in: w, at: point(0), time: 0)
        clock = 1.5; p.tick(at: clock)
        #expect(p.shownText == nil)
        clock = 1.56; p.tick(at: clock)
        #expect(p.shownText == runHit.text && p.shownOpacity == 1)
        // Straight onto Stop: Run's stays 350 ms, then Stop's replaces it.
        clock = 2; p.pointerMoved(in: w, at: point(1), time: clock)
        clock = 2.3; p.tick(at: clock)
        #expect(p.shownText == runHit.text)
        clock = 2.35; p.tick(at: clock)
        #expect(p.shownText == WorkspaceWindowController.runStopToolTips[1] && p.shownOpacity == 1)
        // Away to a place with no tooltip: held, then a linear fade.
        let editorPoint = wc.editor.textView.convert(NSPoint(x: 200, y: 200), to: nil)
        #expect(ToolTipPresenter.toolTip(in: w, at: editorPoint) == nil)
        clock = 3; p.pointerMoved(in: w, at: editorPoint, time: clock)
        clock = 3.3; p.tick(at: clock)
        #expect(p.shownOpacity == 1)
        clock = 3.58; p.tick(at: clock)
        #expect(abs(p.shownOpacity - 0.5) < 0.01)
        clock = 3.81; p.tick(at: clock)
        #expect(p.shownText == nil)
        // A click removes one at once.
        clock = 4; p.pointerMoved(in: w, at: point(0), time: clock)
        clock = 6; p.tick(at: clock)
        #expect(p.shownText != nil)
        p.dismiss(time: 6.1)
        #expect(p.shownText == nil)
        // Never on the owner's screen: the window is kept off the displays.
        #expect(!p.mayShow)
        #expect(!NSApp.windows.contains { $0 is ToolTipPanel && $0.isVisible })
    }
    // MARK: P-197: one tooltip only

    /// Hovers every view of `w` that has a tooltip (each segment of a
    /// segmented control too) through `p`, and checks that what the
    /// presenter handled has no tooltip left for AppKit to show, that the
    /// presenter still has the text, and that accessibility still reads it
    /// as help. Returns how many controls were handled.
    func expectOnlyYcodeTooltips(in w: NSWindow, presenter p: ToolTipPresenter) -> Int {
        guard let frame = w.contentView?.superview ?? w.contentView else { return 0 }
        var handled = 0
        var t = 0.0
        for v in [frame] + frame.b5fixDescendants where !v.isHiddenOrHasHiddenAncestor && v.bounds.width > 2 && v.bounds.height > 2 {
            if let seg = v as? NSSegmentedControl {
                for i in 0..<seg.segmentCount {
                    guard let original = ToolTipPresenter.text(of: seg, segment: i) else { continue }
                    let x = seg.bounds.width * (CGFloat(i) + 0.5) / CGFloat(seg.segmentCount)
                    let at = seg.convert(NSPoint(x: x, y: seg.bounds.midY), to: nil)
                    guard ToolTipPresenter.toolTip(in: w, at: at)?.control == ToolTipControl(view: ObjectIdentifier(seg), part: i) else { continue }
                    t += 10
                    p.pointerMoved(in: w, at: at, time: t)
                    let left = seg.toolTip(forSegment: i) ?? ""
                    #expect(left.isEmpty, "segment \(i) of \(seg) still has its AppKit tooltip \(left)")
                    #expect(ToolTipPresenter.text(of: seg, segment: i) == original)
                    let elements = ToolTipPresenter.segmentElements(seg)
                    if i < elements.count {
                        #expect((elements[i] as AnyObject).accessibilityHelp?() == original, "segment \(i) help")
                    }
                    handled += 1
                }
                continue
            }
            guard let original = v.toolTip, !original.isEmpty else { continue }
            let at = v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil)
            guard ToolTipPresenter.toolTip(in: w, at: at)?.control.view == ObjectIdentifier(v) else { continue }
            t += 10
            p.pointerMoved(in: w, at: at, time: t)
            #expect((v.toolTip ?? "").isEmpty, "\(type(of: v)) still has its AppKit tooltip \(v.toolTip ?? "")")
            #expect(ToolTipPresenter.text(of: v) == original)
            #expect(v.accessibilityHelp() == original, "\(type(of: v)) help \(v.accessibilityHelp() ?? "nil")")
            handled += 1
        }
        p.dismiss(time: t + 1)
        return handled
    }

    @Test func handledControlsKeepNoAppKitTooltip() throws {
        let dir = try tempDir("one-tooltip")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wc = try window(try iosApp(in: dir))
        defer { wc.close() }
        let w = try #require(wc.window)
        let p = ToolTipPresenter()
        var clock = 0.0
        p.now = { clock }
        clock = 0
        // The toolbar and the IDE's controls.
        let n = expectOnlyYcodeTooltips(in: w, presenter: p)
        #expect(n >= 5, "only \(n) controls handled")
        // Run │ Stop: both segments given up, and still shown by Ycode.
        let frame = try #require(w.contentView?.superview)
        let runStop = try #require(frame.b5fixDescendants.compactMap { $0 as? NSSegmentedControl }
            .first { ToolTipPresenter.text(of: $0, segment: 0) == WorkspaceWindowController.runStopToolTips[0] })
        #expect((runStop.toolTip(forSegment: 0) ?? "").isEmpty && (runStop.toolTip(forSegment: 1) ?? "").isEmpty)
        let at = runStop.convert(NSPoint(x: runStop.bounds.width / 4, y: runStop.bounds.midY), to: nil)
        clock = 1000
        p.pointerMoved(in: w, at: at, time: clock)
        clock = 1001.56
        p.tick(at: clock)
        #expect(p.shownText == WorkspaceWindowController.runStopToolTips[0])
        // Text set again later (a toggle's new wording) is taken over on the next hover; nil still means none.
        let inspector = try #require(frame.b5fixDescendants.first { ToolTipPresenter.text(of: $0) != nil && !($0 is NSSegmentedControl) })
        inspector.toolTip = "Changed"
        let iat = inspector.convert(NSPoint(x: inspector.bounds.midX, y: inspector.bounds.midY), to: nil)
        if ToolTipPresenter.toolTip(in: w, at: iat)?.control.view == ObjectIdentifier(inspector) {
            p.pointerMoved(in: w, at: iat, time: 2000)
            #expect(inspector.toolTip == "" && ToolTipPresenter.text(of: inspector) == "Changed" && inspector.accessibilityHelp() == "Changed")
        }
        inspector.toolTip = nil
        #expect(ToolTipPresenter.text(of: inspector) == nil)
    }

    @Test func deviceCanvasControlsKeepNoAppKitTooltip() throws {
        _ = NSApplication.shared
        let row = DeviceControlsRow(frame: NSRect(x: 0, y: 0, width: 400, height: 37))
        row.configure(.init(canRotate: true, enabled: true, showsHome: true))
        let w = NSWindow(contentRect: NSRect(x: -9000, y: -9000, width: 420, height: 60), styleMask: [.borderless], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        defer { w.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 60))
        w.contentView = root
        root.addSubview(row)
        row.frame = NSRect(x: 10, y: 10, width: 400, height: 37)
        root.layoutSubtreeIfNeeded()
        let p = ToolTipPresenter()
        p.now = { 0 }
        let n = expectOnlyYcodeTooltips(in: w, presenter: p)
        #expect(n >= 2, "only \(n) canvas controls handled")
    }
}

extension NSView {
    /// Every view under this one.
    var b5fixDescendants: [NSView] { subviews + subviews.flatMap(\.b5fixDescendants) }
}
