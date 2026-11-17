import AppKit
import Foundation
import Testing
import YcodeAssistant
import YcodeBuild
@testable import YcodeIDECore
import YcodeProject
@testable import YcodeUI

/// Beta 4, B4-PANES (`specs/ide/parity-inventory.md`): the navigators,
/// the inspector, Settings, the editors' bottom bars, the previews canvas,
/// the command palette and the activity view.
@MainActor
@Suite(.serialized) struct Beta4PanesTests {
    func tempDir(_ tag: String) throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-b4-panes-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u.resolvingSymlinksInPath()
    }

    /// An iOS app project made by Ycode's own template.
    func iosApp(in dir: URL, name: String = "Panes") throws -> URL {
        var o = ProjectOptions()
        o.productName = name
        o.organizationIdentifier = "org.ycode.tests"
        o.testing = .none
        o.setStorage(.none)
        return try ProjectTemplate.app.create(platform: "iOS", options: o, in: dir)
    }

    func window(_ url: URL) throws -> WorkspaceWindowController {
        _ = NSApplication.shared
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: url)), loadDestinations: false,
                                           startLanguageService: false, openFirstFile: false, userStateURL: nil)
        wc.window?.setContentSize(NSSize(width: 1400, height: 880))
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        return wc
    }

    func pump(_ s: Double = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    // MARK: P-026 — the Coding Assistant pane keeps the navigator's width

    @Test func codingAssistantKeepsTheLeftWidth() throws {
        let dir = try tempDir("assist")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wc = try window(try iosApp(in: dir))
        // The reference's navigator width (left pane 289.5 pt).
        wc.mainSplit.splitView.setPosition(289.5, ofDividerAt: 0)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        let before = wc.navigator.view.frame.width
        wc.showCodingAssistant(nil)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        let assistant = wc.navigator.view.frame.width
        wc.showNavigator(0)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        let after = wc.navigator.view.frame.width
        #expect(abs(assistant - before) < 0.5 && abs(after - before) < 0.5, "navigator \(before), assistant \(assistant), back \(after)")
        // The pane keeps the navigator's dark fill.
        wc.showCodingAssistant(nil)
        #expect(wc.navigator.darkFill?.isHidden == false)
    }

    @Test func longTranscriptLinesDoNotWidenTheLeftArea() throws {
        let env = try CodingAssistantUITests.Env("b4-wide", ready: [.ollama])
        defer { env.restore() }
        let wc = try env.window()
        wc.window?.setContentSize(NSSize(width: 1400, height: 880))
        wc.mainSplit.splitView.setPosition(289.5, ofDividerAt: 0)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        let before = wc.navigator.view.frame.width
        wc.showCodingAssistant(nil)
        let model = wc.codingAssistantModel
        let id = model.newConversation().id
        let long = Attachment(kind: .file, path: env.dir.appendingPathComponent("Sources/Demo/AVeryLongFileNameThatGoesOnAndOnForTheWholeLine.swift").path,
                              text: "struct Model {}")
        _ = model.send("Explain", attachments: [long, long, long], in: id)
        for _ in 0..<40 { pump() }
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        #expect(abs(wc.navigator.view.frame.width - before) < 0.5, "navigator \(before) → \(wc.navigator.view.frame.width)")
    }

    // MARK: P-035 — the open file's row keeps its band

    @Test func selectionSurvivesAStatusRead() throws {
        let dir = try tempDir("band")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wc = try window(try iosApp(in: dir))
        wc.navigator.select(0)
        let file = try #require(wc.session.model.root.allFiles.first { $0.name == "ContentView.swift" }?.path)
        _ = wc.navigator.selectProjectRows { $0.nodePath == file }
        #expect(wc.navigator.selectedProjectRowKeys().count == 1)
        // The source-control status arrives after the file opened.
        wc.navigator.setFileStatus([file: .modified])
        #expect(wc.navigator.selectedProjectRowKeys().count == 1 && wc.navigator.selectedItem?.nodePath == file)
        wc.navigator.setFileStatus([:])
        #expect(wc.navigator.selectedItem?.nodePath == file)
    }

    // MARK: P-036 — ⌘1–⌘9 on the navigator shown hides it

    @Test func navigatorShortcutToggles() throws {
        let dir = try tempDir("toggle")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wc = try window(try iosApp(in: dir))
        func item(_ tag: Int) -> NSMenuItem {
            let i = NSMenuItem(title: "", action: #selector(WorkspaceWindowController.showNavigator(_:)), keyEquivalent: "")
            i.tag = tag
            return i
        }
        wc.showNavigator(item(4))
        #expect(wc.shownLeftPane == .navigators && wc.navigator.selectedIndex == 4)
        wc.showNavigator(item(4))   // the same one: hides
        #expect(wc.shownLeftPane == nil)
        wc.showNavigator(item(4))   // and shows again
        #expect(wc.shownLeftPane == .navigators && wc.navigator.selectedIndex == 4)
        wc.showNavigator(item(0))   // another one switches
        #expect(wc.shownLeftPane == .navigators && wc.navigator.selectedIndex == 0)
        // The issue capsule (an Int) only shows.
        wc.showNavigator(0)
        #expect(wc.shownLeftPane == .navigators)
    }

    // MARK: P-047 — the Repositories glyphs are grey, not black

    @Test func templateGlyphsTakeTheirTint() throws {
        let image = try #require(NSImage(systemSymbolName: "clock.fill", accessibilityDescription: nil))
        image.isTemplate = true
        let v = NavigatorFlatIconView(image: image)
        v.frame = NSRect(x: 0, y: 0, width: 16, height: 16)
        v.contentTintColor = NSColor(srgbRed: 0xA5 / 255.0, green: 0xA5 / 255.0, blue: 0xA7 / 255.0, alpha: 1)
        v.appearance = NSAppearance(named: .darkAqua)
        let rep = try #require(v.bitmapImageRepForCachingDisplay(in: v.bounds))
        v.cacheDisplay(in: v.bounds, to: rep)
        var inked = 0, black = 0
        for x in 0..<rep.pixelsWide { for y in 0..<rep.pixelsHigh {
            guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.9 else { continue }
            inked += 1
            if c.redComponent < 0.2 && c.greenComponent < 0.2 && c.blueComponent < 0.2 { black += 1 }
        } }
        #expect(inked > 10 && black == 0, "inked \(inked), black \(black)")
    }

    // MARK: P-089 — a folder's own File inspector

    @Test func folderSelectionShowsItsInspector() throws {
        let dir = try tempDir("folder")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wc = try window(try iosApp(in: dir))
        wc.navigator.select(0)
        let file = try #require(wc.session.model.root.allFiles.first { $0.name == "ContentView.swift" }?.path)
        wc.inspector.show(file: URL(fileURLWithPath: file))
        // A folder row (the app's sources).
        let outline = wc.navigator.outline
        let row = try #require((0..<outline.numberOfRows).first { r in
            guard let i = outline.item(atRow: r) as? OutlineItem else { return false }
            return i.nodeKind != .file && i.path == nil && i.nodePath != nil
        })
        let folder = try #require((outline.item(atRow: row) as? OutlineItem)?.nodePath)
        outline.selectRowIndexes([row], byExtendingSelection: false)
        #expect(wc.inspector.shownFile?.path == folder)
        wc.inspector.select(0)
        #expect(!wc.inspector.rowValues.contains { $0.0 == "Type" })
        #expect(wc.inspector.rowValues.contains { $0.0 == "Full Path" && $0.1 == folder })
    }

    // MARK: Decision 5 — no Local | Cloud control in the Report navigator

    @Test func reportNavigatorHasNoCloudControl() throws {
        let dir = try tempDir("reports")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wc = try window(try iosApp(in: dir))
        wc.navigator.select(8)
        func controls(_ v: NSView) -> [NSSegmentedControl] { ((v as? NSSegmentedControl).map { [$0] } ?? []) + v.subviews.flatMap(controls) }
        let labels = controls(wc.navigator.view).filter { !$0.isHiddenOrHasHiddenAncestor }
            .flatMap { c in (0..<c.segmentCount).compactMap { c.label(forSegment: $0) } }
        #expect(!labels.contains("Cloud") && !labels.contains("Local"))
    }

    // MARK: P-138 — Settings drill-in rows push a page

    /// A pane's drill-in row whose label starts with `title`.
    func drillRow(_ pane: SettingsPane, _ title: String) -> SettingsRowView? {
        _ = pane.view
        return pane.cards.flatMap(\.rowViews).compactMap { $0 as? SettingsRowView }.first { $0.label.stringValue.hasPrefix(title) }
    }

    @Test func settingsDrillInPushesAPage() throws {
        _ = NSApplication.shared
        let td = TestDefaults("b4-drill")
        defer { td.remove() }
        let settings = SettingsWindowController(prefs: Preferences(defaults: td.defaults), components: [])
        settings.show(page: "Editing")
        let editing = try #require(settings.pane(TextEditingSettingsPane.self))
        let display = try #require(drillRow(editing, "Display"))
        // An accessibility button, reachable by keyboard.
        #expect(display.isAccessibilityElement() && display.accessibilityRole() == .button && display.accessibilityLabel() == "Display")
        #expect(display.acceptsFirstResponder)
        #expect(display.accessibilityPerformPress())
        // The page is pushed: the window takes its title; no "‹ Editing" link.
        #expect(editing.page == .display && settings.shownTitle == "Display" && settings.window?.title == "Display")
        #expect(!editing.rowTitles.contains { $0.hasPrefix("\u{2039}") })
        // Back returns to Editing (not through the pane history to General).
        settings.goBack()
        #expect(editing.page == .main && settings.selectedPane == "Editing" && settings.shownTitle == "Editing")
        settings.goForward()
        #expect(editing.page == .display && settings.shownTitle == "Display")
        settings.goBack()
        settings.goBack()
        #expect(settings.selectedPane == "General")
        // Behaviors ▸ Build is a page too.
        settings.show(page: "Behaviors")
        let behaviors = try #require(settings.pane(BehaviorsSettingsPane.self))
        let build = try #require(drillRow(behaviors, "Build"))
        #expect(build.accessibilityPerformPress())
        #expect(behaviors.category == "Build" && settings.shownTitle == "Build")
        settings.goBack()
        #expect(behaviors.category == nil && settings.shownTitle == "Behaviors")
    }

    @Test func drillInRowTintsWhilePressed() throws {
        _ = NSApplication.shared
        let td = TestDefaults("b4-press")
        defer { td.remove() }
        let pane = TextEditingSettingsPane(prefs: Preferences(defaults: td.defaults))
        _ = pane.view
        let row = try #require(drillRow(pane, "Completion"))
        #expect(!row.isPressed)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        row.mouseDown(with: down)
        #expect(row.isPressed)
    }

    // MARK: P-139 — the Settings window resizes

    @Test func settingsWindowResizes() throws {
        _ = NSApplication.shared
        let td = TestDefaults("b4-resize")
        defer { td.remove() }
        let settings = SettingsWindowController(prefs: Preferences(defaults: td.defaults), components: [])
        let w = try #require(settings.window)
        #expect(w.styleMask.contains(.resizable) && w.collectionBehavior.contains(.fullScreenNone))
        #expect(w.contentMinSize == NSSize(width: 710, height: 452) && w.contentMaxSize.height >= 900)
        w.setContentSize(NSSize(width: 710, height: 900))
        w.contentView?.layoutSubtreeIfNeeded()
        #expect(w.contentView?.frame.size == NSSize(width: 710, height: 900))
    }

    // MARK: P-140 — Components' first frame has its values

    @Test func componentsFirstFrameHasTheLastValues() throws {
        _ = NSApplication.shared
        let td = TestDefaults("b4-components")
        defer { td.remove() }
        let saved = ComponentsSettingsPane.lastRead
        defer { ComponentsSettingsPane.lastRead = saved }
        let known = ComponentsInventory(sdks: [ComponentsInventory.SDK(canonicalName: "macosx27.1", version: "27.1")])
        ComponentsSettingsPane.lastRead = known
        let pane = ComponentsSettingsPane(prefs: Preferences(defaults: td.defaults))
        _ = pane.view
        // The first build uses the values last read, not an empty inventory.
        #expect(pane.inventory == known)
        pane.loading?.cancel()
    }

    // MARK: P-148, P-202 — accessibility reads of long tables are quick

    /// Walks a view's accessibility tree as a client does (children of
    /// children, each element's role and value), returning the seconds taken.
    func accessibilityWalk(_ root: Any, limit: Int = 20000) -> (seconds: Double, count: Int) {
        let t0 = Date()
        var queue: [Any] = [root], count = 0
        while !queue.isEmpty, count < limit {
            let o = queue.removeFirst() as AnyObject
            count += 1
            _ = o.accessibilityRole?()
            let value = NSSelectorFromString("accessibilityValue")
            if o.responds(to: value) { _ = o.perform(value) }
            if let kids = o.accessibilityChildren?() as? [Any] { queue += kids }
        }
        return (Date().timeIntervalSince(t0), count)
    }

    @Test func shortcutsPaneAnswersAccessibilityQuickly() throws {
        _ = NSApplication.shared
        let td = TestDefaults("b4-shortcuts")
        defer { td.remove() }
        let pane = KeyBindingsSettingsPane(prefs: Preferences(defaults: td.defaults))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 530, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentViewController = pane
        w.contentView?.layoutSubtreeIfNeeded()
        #expect(pane.rows.count > 100)
        let first = accessibilityWalk(pane.view)
        let second = accessibilityWalk(pane.view)
        print("B4 shortcuts walks \(first), \(second), rows \(pane.rows.count)")
        #expect(first.seconds < 3 && second.seconds < 3, "walks \(first), \(second)")
        w.close()
    }

    @Test func commandPaletteAnswersAccessibilityQuickly() throws {
        _ = NSApplication.shared
        let bar = MainMenu.make()
        let dir = try tempDir("palette")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wc = try window(try iosApp(in: dir))
        let c = QuickActionsController(actions: QuickActions.collect(from: bar, controller: wc))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentViewController = c
        w.contentView?.layoutSubtreeIfNeeded()
        #expect(c.shown.count > 50)
        let first = accessibilityWalk(c.view)
        let second = accessibilityWalk(c.view)
        print("B4 palette walks \(first), \(second), rows \(c.shown.count)")
        #expect(first.seconds < 3 && second.seconds < 3, "walks \(first), \(second)")
        w.close()
    }

    // MARK: P-156 — editors' own bottom bars sit above the status bar

    @Test func assetListBarClearsTheStatusBar() throws {
        let dir = try tempDir("assets")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wc = try window(try iosApp(in: dir))
        let assets = try #require(wc.session.model.root.allFiles.first { $0.name == "Assets.xcassets" }?.path)
        wc.open(path: assets, line: nil)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        let editor = try #require(wc.assetEditor)
        let add = editor.addButton
        let inWindow = add.convert(add.bounds, to: nil)
        // The window's status bar (the debug bar) is at the bottom of the
        // editor column; the list's bar is above it, not under it.
        let bar = DebugAreaController.debugBarHeight
        #expect(inWindow.minY >= bar - 0.5, "add button \(inWindow), status bar \(bar)")
        // Not squashed: the bar's controls keep their own heights.
        #expect(inWindow.height >= add.intrinsicContentSize.height - 0.5, "add button \(inWindow)")
        let filter = editor.filterField.convert(editor.filterField.bounds, to: nil)
        #expect(filter.minY >= bar - 0.5 && filter.height >= editor.filterField.intrinsicContentSize.height - 0.5, "filter \(filter)")
    }

    @Test func previewCanvasBarClearsTheStatusBar() throws {
        let dir = try tempDir("canvas-bar")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wc = try window(try iosApp(in: dir))
        let canvas = PreviewCanvasController()
        wc.editorArea.showCanvas(canvas)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        let pop = canvas.devicePopUp.convert(canvas.devicePopUp.bounds, to: nil)
        let bar = DebugAreaController.debugBarHeight
        #expect(pop.minY >= bar - 0.5, "device pop-up \(pop), status bar \(bar)")
    }

    // MARK: P-166 — the preview follows the canvas's appearance

    @Test func previewSchemeFollowsTheCanvas() throws {
        _ = NSApplication.shared
        let c = PreviewCanvasController()
        c.view.appearance = NSAppearance(named: .darkAqua)
        #expect(c.colorScheme == .dark)
        c.view.appearance = NSAppearance(named: .aqua)
        #expect(c.colorScheme == .light)
        c.setColorScheme(.dark)
        #expect(c.colorScheme == .dark)
        c.setColorScheme(nil)
        #expect(c.colorScheme == .light)
        #expect(PreviewCanvasController.buildingSpinnerSide == 18)
    }

    @Test func macPreviewSitsInATitledWindowFrame() throws {
        _ = NSApplication.shared
        let dir = try tempDir("mac-frame")
        defer { try? FileManager.default.removeItem(at: dir) }
        // A 40 × 20 picture.
        let png = dir.appendingPathComponent("p.png")
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try rep.representation(using: .png, properties: [:])?.write(to: png)
        let c = PreviewCanvasController()
        _ = c.view
        c.setNames(["Preview"])
        c.resume()
        #expect(c.previewsMac)
        c.setState(.rendered([PreviewRenderer.Rendered(name: "Preview", png: png), PreviewRenderer.Rendered(name: "Preview", png: png, scheme: .dark)]))
        func frames(_ v: NSView) -> [NSView] { (v is PreviewWindowFrameView ? [v] : []) + v.subviews.flatMap(frames) }
        let frame = try #require(frames(c.view).first as? PreviewWindowFrameView)
        #expect(frame.titleLabel.stringValue == "Ycode Previews" && !frame.titleLabel.stringValue.contains("Xcode"))
    }

    // MARK: P-204 — the title area's accessibility

    @Test func activityViewExposesTitleProgressAndStatus() throws {
        let dir = try tempDir("activity")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wc = try window(try iosApp(in: dir))
        let a = wc.activityView
        a.workspaceName = "Panes"
        a.status = "Building • 39 / 58"
        a.isBusy = true
        let kids = (a.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
        #expect(kids.map { $0.accessibilityRole() } == [.progressIndicator, .staticText, .staticText])
        #expect(kids.compactMap { $0.accessibilityValue() as? String } == ["Building • 39 / 58", "Panes", "Building • 39 / 58"])
        a.isBusy = false
        a.status = ""
        #expect((a.accessibilityChildren() ?? []).count == 1)
    }

    // MARK: P-038 — the filter's text starts after the options glyph

    @Test func filterTextClearsTheOptionsGlyph() throws {
        let dir = try tempDir("filter")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wc = try window(try iosApp(in: dir))
        let field = wc.navigator.filter
        let options = wc.navigator.filterOptions
        let glyphEnd = options.convert(options.bounds, to: field).maxX
        #expect(wc.window?.makeFirstResponder(field) == true)
        let editor = try #require(field.currentEditor() as? NSTextView)
        let r = editor.convert(editor.bounds, to: field)
        #expect(r.minX >= glyphEnd - 0.5, "field editor \(r), glyph ends \(glyphEnd)")
        editor.insertText("abc", replacementRange: NSRange(location: 0, length: 0))
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        let r2 = editor.convert(editor.bounds, to: field)
        #expect(r2.minX >= glyphEnd - 0.5, "field editor \(r2), glyph ends \(glyphEnd)")
        wc.window?.makeFirstResponder(nil)
    }

    // MARK: P-204 — Stop is enabled for accessibility while running

    @Test func stopSegmentEnabledWhileBusy() throws {
        let dir = try tempDir("stop")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wc = try window(try iosApp(in: dir))
        let item = try #require(wc.window?.toolbar?.items.first { $0.itemIdentifier == WorkspaceWindowController.runID })
        let c = try #require(item.view as? NSSegmentedControl)
        // The Run and Stop buttons as accessibility clients read them.
        func buttons() -> [(String, Bool)] {
            var out: [(String, Bool)] = []
            func walk(_ e: Any, _ depth: Int) {
                let o = e as AnyObject
                if (o.accessibilityRole?() as? NSAccessibility.Role) == .button {
                    out.append(((o.accessibilityLabel?() as? String) ?? "", o.isAccessibilityEnabled?() ?? false))
                }
                if depth < 3, let kids = o.accessibilityChildren?() as? [Any] { kids.forEach { walk($0, depth + 1) } }
            }
            walk(c, 0)
            return out
        }
        // While an action runs the window enables Stop, and clients read it so.
        c.setEnabled(true, forSegment: 1)
        #expect(buttons().map(\.0) == ["Run", "Stop"] && buttons().allSatisfy(\.1), "\(buttons())")
        c.setEnabled(false, forSegment: 1)
        #expect(buttons().last?.1 == false)
    }
}
