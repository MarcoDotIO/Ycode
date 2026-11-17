import AppKit
import Foundation
import Testing
import YcodeAssistant
@testable import YcodeIDECore
import YcodeProject
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// B4-POLISH (1.0.0-beta.4, council round 11): the find bar's Escape and
/// gutter (P-003), the Coding Assistant pane's width (P-026), the selection
/// band across navigator switches (P-035), the Settings window's width
/// (P-139), the canvas beside editors that can't preview, and the title
/// area while paused. Windows stay off every display (the offscreen guard).
@MainActor
@Suite(.serialized) struct B4PolishTests {
    static let shots = ycodeDir.appendingPathComponent(".build-ide/b4-polish-shots")

    func tempDir(_ tag: String) throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-b4-polish-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u.resolvingSymlinksInPath()
    }

    /// An iOS app project made by Ycode's own template.
    func iosApp(in dir: URL, name: String = "Polish") throws -> URL {
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
        wc.window?.appearance = NSAppearance(named: .darkAqua)
        wc.applyDefaultLayout()
        wc.window?.setFrame(NSRect(x: -6000, y: -6000, width: 1400, height: 880), display: true)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        return wc
    }

    func pump(_ s: Double = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    func shot(_ wc: WorkspaceWindowController, _ name: String) {
        try? FileManager.default.createDirectory(at: Self.shots, withIntermediateDirectories: true)
        guard let v = wc.window?.contentView?.superview, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: Self.shots.appendingPathComponent(name))
    }

    /// What the window shows now: its layers' current contents (no new
    /// drawing), unlike `cacheDisplay`.
    func layerShot(_ wc: WorkspaceWindowController, _ name: String) {
        try? FileManager.default.createDirectory(at: Self.shots, withIntermediateDirectories: true)
        guard let v = wc.window?.contentView, let layer = v.layer else { print("PROBE no layer"); return }
        let scale = wc.window?.backingScaleFactor ?? 2
        let w = Int(v.bounds.width * scale), h = Int(v.bounds.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        guard let img = ctx.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: Self.shots.appendingPathComponent(name))
    }

    // MARK: P-003 — the find bar: Escape, and the gutter beside it

    /// Escape in the find field closes the bar and gives the editor the
    /// keyboard; while the bar is open the text and the gutter's numbers
    /// move down together.
    @Test func findBarEscapeAndGutter() throws {
        let dir = try tempDir("find")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wc = try window(try iosApp(in: dir))
        let file = try #require(wc.session.model.root.allFiles.first { $0.name == "ContentView.swift" }?.path)
        wc.open(path: file, line: nil)
        wc.window?.orderFront(nil)
        for _ in 0..<6 { pump() }
        let ed = wc.editor
        // Line 1's number and line 1's text, in window coordinates (y up),
        // and the scroll position the gutter last drew at.
        func line1() -> (number: CGFloat?, text: CGFloat, drawn: CGFloat?, now: CGFloat) {
            let n = ed.gutter.visibleLines().first { $0.line == 1 }.map { ed.gutter.convert($0.rect, to: nil).maxY }
            let t = ed.textView.convert(NSRect(x: 0, y: ed.textView.textContainerOrigin.y, width: 1, height: 1), to: nil).maxY
            return (n, t, ed.gutter.drawnScrollTop, ed.scrollView.contentView.bounds.minY)
        }
        let closed = line1()
        shot(wc, "mac-find-1-closed.png")
        // ⌘F: the bar, its field with the keyboard.
        let find = NSMenuItem(title: "Find…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        find.tag = 1
        wc.performFindPanelAction(find)
        for _ in 0..<6 { pump() }
        let open = line1()
        shot(wc, "mac-find-2-open.png")
        let barHeight = ed.findBar.frame.height
        print("POLISH P-003 bar \(barHeight) pt; line 1 number/text closed \(closed.number ?? -1)/\(closed.text), open \(open.number ?? -1)/\(open.text); drawn at \(open.drawn ?? -1), scroll \(open.now)")
        #expect(ed.isShowingFindBar)
        let n0 = try #require(closed.number), n1 = try #require(open.number)
        // Text and number moved by the same amount (the bar's height).
        #expect(abs((closed.text - open.text) - (n0 - n1)) < 0.5 && abs(closed.text - open.text - barHeight) < 1.5)
        // The gutter drew at the text's new position.
        #expect(open.drawn == open.now)
        // Escape in the field: the bar closes, the editor has the keyboard.
        let fieldEditor = try #require(wc.window?.fieldEditor(true, for: ed.findBar.queryField) as? NSTextView)
        #expect(wc.window?.firstResponder === fieldEditor)
        fieldEditor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        for _ in 0..<4 { pump() }
        shot(wc, "mac-find-3-escape.png")
        #expect(!ed.isShowingFindBar && ed.findBar.isHidden)
        #expect(wc.window?.firstResponder === ed.textView)
        let after = line1()
        #expect(after.number.map { abs($0 - n0) < 0.5 } == true && abs(after.text - closed.text) < 0.5 && after.drawn == after.now)
        // With Replace shown, Escape in the replacement field closes it too.
        ed.showFindBar(replace: true)
        for _ in 0..<4 { pump() }
        wc.window?.makeFirstResponder(ed.findBar.replaceField)
        let replaceEditor = try #require(wc.window?.firstResponder as? NSTextView)
        replaceEditor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(!ed.isShowingFindBar && wc.window?.firstResponder === ed.textView)
    }

    // MARK: P-026 — ⌘0 keeps the left area at the navigator's width

    /// Whatever the pane holds (here a control that cannot be narrower
    /// than 425 points, as the council's pane was), showing it keeps the
    /// navigator's 289.5 points, and ⌘1 keeps them too.
    @Test func codingAssistantNeverWidensTheLeftArea() throws {
        let env = try CodingAssistantUITests.Env("polish-wide", ready: [])
        defer { env.restore() }
        let wc = try env.window()
        wc.window?.setFrame(NSRect(x: -6000, y: -6000, width: 1400, height: 880), display: true)
        wc.window?.orderFront(nil)
        wc.mainSplit.splitView.setPosition(289.5, ofDividerAt: 0)
        for _ in 0..<4 { pump() }
        let before = wc.navigator.view.frame.width
        // As it is: the pane fills the area, its labels wrapped.
        wc.showCodingAssistant(nil)
        for _ in 0..<6 { pump() }
        #expect(abs(wc.codingAssistant.view.frame.width - before) < 0.5 && abs(wc.navigator.view.frame.width - before) < 0.5,
                "pane \(wc.codingAssistant.view.frame.width) in \(wc.navigator.view.frame.width)")
        wc.showNavigator(0)
        for _ in 0..<4 { pump() }
        // A button (the default compression resistance) and a control that
        // cannot be narrower.
        let button = NSButton(title: String(repeating: "Button ", count: 20), target: nil, action: nil)
        button.translatesAutoresizingMaskIntoConstraints = false
        let wide = NSButton(title: String(repeating: "Wide ", count: 24), target: nil, action: nil)
        wide.translatesAutoresizingMaskIntoConstraints = false
        wide.setContentCompressionResistancePriority(.required, for: .horizontal)
        let pane = wc.codingAssistant.view
        pane.addSubview(wide)
        pane.addSubview(button)
        NSLayoutConstraint.activate([wide.leadingAnchor.constraint(equalTo: pane.leadingAnchor), wide.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
                                     wide.topAnchor.constraint(equalTo: pane.topAnchor, constant: 60),
                                     button.leadingAnchor.constraint(equalTo: pane.leadingAnchor), button.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
                                     button.topAnchor.constraint(equalTo: pane.topAnchor, constant: 90)])
        #expect(wide.intrinsicContentSize.width > 425)
        let cmd0 = NSMenuItem(title: "", action: #selector(WorkspaceWindowController.showCodingAssistant(_:)), keyEquivalent: "0")
        wc.showCodingAssistant(cmd0)
        for _ in 0..<6 { pump() }
        let assistant = wc.navigator.view.frame.width
        let editor = wc.editorArea.view.frame.width
        shot(wc, "mac-p026-cmd0-after.png")
        let cmd1 = NSMenuItem(title: "", action: #selector(WorkspaceWindowController.showNavigator(_:)), keyEquivalent: "1")
        cmd1.tag = 0
        wc.showNavigator(cmd1)
        for _ in 0..<6 { pump() }
        let back = wc.navigator.view.frame.width
        print("POLISH P-026 left \(before) → ⌘0 \(assistant) (editor \(editor)) → ⌘1 \(back)")
        #expect(abs(assistant - before) < 0.5 && abs(back - before) < 0.5, "left \(before) → ⌘0 \(assistant) → ⌘1 \(back)")
    }

    // MARK: P-035 — the band survives a trip through the other navigators

    @Test func selectionBandSurvivesNavigatorSwitches() throws {
        let dir = try tempDir("band")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wc = try window(try iosApp(in: dir))
        wc.window?.orderFront(nil)
        let file = try #require(wc.session.model.root.allFiles.first { $0.name == "ContentView.swift" }?.path)
        // Opened from the Project navigator: its row selected, then opened.
        _ = wc.navigator.selectProjectRows { $0.nodePath == file }
        wc.open(path: file, line: nil)
        for _ in 0..<4 { pump() }
        #expect(wc.navigator.selectedItem?.nodePath == file)
        shot(wc, "mac-p035-1-opened.png")
        func item(_ tag: Int) -> NSMenuItem {
            let i = NSMenuItem(title: "", action: #selector(WorkspaceWindowController.showNavigator(_:)), keyEquivalent: "\(tag + 1)")
            i.tag = tag
            return i
        }
        for tag in 1...4 {
            wc.showNavigator(item(tag))
            for _ in 0..<2 { pump() }
            #expect(wc.navigator.selectedIndex == tag)
        }
        wc.showNavigator(item(0))
        for _ in 0..<4 { pump() }
        shot(wc, "mac-p035-2-after-cmd2-5-cmd1.png")
        let rows = wc.navigator.selectedProjectRowKeys()
        print("POLISH P-035 after ⌘2–⌘5, ⌘1: selected \(rows)")
        #expect(wc.navigator.selectedIndex == 0 && rows.count == 1 && wc.navigator.selectedItem?.nodePath == file)
        // The row draws its band (the outline's selection, highlighted).
        let row = wc.navigator.outline.selectedRow
        #expect(row >= 0 && wc.navigator.outline.rowView(atRow: row, makeIfNecessary: false)?.isSelected == true)
    }

    // MARK: P-139 — the Settings window widens

    @Test func settingsWindowWidens() throws {
        _ = NSApplication.shared
        let td = TestDefaults("b4-polish-settings")
        defer { td.remove() }
        let settings = SettingsWindowController(prefs: Preferences(defaults: td.defaults), components: [])
        let w = try #require(settings.window)
        #expect(w.contentMinSize == NSSize(width: 710, height: 452))
        #expect(w.contentMaxSize.width >= 900 && w.contentMaxSize.height >= 900)
        w.setFrame(NSRect(x: -6000, y: -6000, width: 710, height: 452), display: false)
        w.setContentSize(NSSize(width: 900, height: 760))
        w.contentView?.layoutSubtreeIfNeeded()
        let size = try #require(w.contentView?.frame.size)
        print("POLISH P-139 Settings content \(size.width) × \(size.height)")
        #expect(size == NSSize(width: 900, height: 760))
        // Every pane lays out to the width: its cards end at the detail's
        // inset from the right edge.
        var short: [String] = []
        for (i, title) in SettingsWindowController.tabTitles.enumerated() {
            settings.select(i, recording: false)
            w.contentView?.layoutSubtreeIfNeeded()
            let pane = settings.tabs.view
            func cards(_ v: NSView) -> [NSView] { v.subviews.flatMap { ($0 is SettingsCardView ? [$0] : []) + cards($0) } }
            for c in cards(pane) where !c.isHiddenOrHasHiddenAncestor {
                let r = c.convert(c.bounds, to: pane)
                if r.maxX < pane.bounds.width - SettingsMetrics.cardInset - 1 { short.append("\(title) \(Int(r.maxX))/\(Int(pane.bounds.width))") }
            }
            if ["General", "Appearance", "Editing", "Accounts"].contains(title) {
                if let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? FileManager.default.createDirectory(at: Self.shots, withIntermediateDirectories: true)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: Self.shots.appendingPathComponent("mac-p139-900x760-\(title.replacingOccurrences(of: " ", with: "-")).png"))
                }
            }
        }
        print("POLISH P-139 short cards: \(short)")
        #expect(short.isEmpty, "cards that don't follow the width: \(short)")
    }

    // MARK: The canvas beside editors that can't preview

    @Test func canvasLeavesForTheProjectEditor() throws {
        let dir = try tempDir("canvas")
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = try iosApp(in: dir)
        let wc = try window(project)
        wc.window?.orderFront(nil)
        let file = try #require(wc.session.model.root.allFiles.first { $0.name == "ContentView.swift" }?.path)
        wc.open(path: file, line: nil)
        for _ in 0..<4 { pump() }
        #expect(wc.canvas != nil && wc.editorArea.canvas != nil)
        let withCanvas = wc.editor.view.frame.width
        shot(wc, "mac-canvas-1-source.png")
        // The project's row: the project editor, with no canvas beside it.
        let proj = try #require(wc.session.model.projects.keys.first)
        wc.open(path: proj, line: nil)
        for _ in 0..<4 { pump() }
        shot(wc, "mac-canvas-2-project-editor.png")
        let projectWidth = wc.editor.view.frame.width
        print("POLISH canvas: source editor \(withCanvas) pt beside the canvas; project editor \(projectWidth) pt, canvas \(wc.canvas == nil ? "hidden" : "shown")")
        #expect(wc.projectEditor != nil)
        #expect(wc.canvas == nil && wc.editorArea.canvas == nil && wc.isCanvasModeOn)
        #expect(projectWidth > withCanvas + 100)
        // A previewable file again: the canvas is back.
        wc.open(path: file, line: nil)
        for _ in 0..<4 { pump() }
        shot(wc, "mac-canvas-3-source-again.png")
        #expect(wc.canvas != nil && wc.editorArea.canvas != nil)
        // Another editor that can't preview (a property list) shows none either.
        if let plist = wc.session.model.root.allFiles.first(where: { $0.name.hasSuffix(".plist") })?.path {
            wc.open(path: plist, line: nil)
            #expect(wc.canvas == nil)
        }
    }

    // MARK: The title area while paused

    @Test func pausedTitleAreaHasNoSpinner() throws {
        let dir = try tempDir("paused")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wc = try window(try iosApp(in: dir))
        wc.window?.orderFront(nil)
        let activity = wc.activityView
        wc.session.noteToolActivity(.running("Running Polish"))
        for _ in 0..<2 { pump() }
        #expect(activity.showsSpinner)
        shot(wc, "mac-paused-1-running.png")
        wc.session.noteToolActivity(.paused("Paused Polish"))
        for _ in 0..<2 { pump() }
        shot(wc, "mac-paused-2-paused.png")
        print("POLISH paused: spinner \(activity.showsSpinner), status \"\(activity.status)\"")
        #expect(!activity.showsSpinner && activity.isBusy && activity.status == "Paused Polish")
        let roles = (activity.accessibilityChildren() ?? []).compactMap { ($0 as? NSAccessibilityElement)?.accessibilityRole() }
        #expect(!roles.contains(.progressIndicator))
        // Continue: running again, the ring is back.
        wc.session.noteToolActivity(.running("Running Polish"))
        #expect(activity.showsSpinner)
        wc.session.noteToolActivity(.finished("Finished running Polish"))
        #expect(!activity.showsSpinner)
    }
}
