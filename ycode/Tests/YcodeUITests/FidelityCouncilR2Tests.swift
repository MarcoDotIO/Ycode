import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The rows B2-GLASS left open in `specs/ide/fidelity-council.md` (beta 2):
/// the default theme's font size (row 4), the inspector's width, the
/// editor's bottom bar (row 13).
@MainActor
@Suite(.serialized) struct FidelityCouncilR2Tests {
    /// A private Preferences, with its own themes folder, installed as
    /// `shared` for `body`.
    func withPreferences(_ tag: String, _ body: (Preferences, URL) throws -> Void) throws {
        let t = TestDefaults("fc2-\(tag)")
        let themes = ycodeDir.appendingPathComponent(".build-ide/fc2-themes-\(tag)-\(UUID().uuidString)")
        let old = Preferences.shared
        let p = Preferences(defaults: t.defaults, themesDirectory: themes)
        Preferences.shared = p
        defer {
            Preferences.shared = old
            NotificationCenter.default.post(name: Preferences.didChange, object: nil)
            t.remove()
            try? FileManager.default.removeItem(at: themes)
        }
        try body(p, themes)
    }

    /// The size field in the Fonts segment's row `title`.
    func sizeField(_ pane: ThemesSettingsPane, _ title: String) -> String? {
        pane.control(ClosureField.self, inRow: title)?.stringValue
    }

    // MARK: Row 4: "Ycode Default" is 13 points

    @Test func defaultThemeShowsThirteenPointsInSettings() throws {
        try withPreferences("default") { p, _ in
            #expect(p.themeName == "Ycode Default" && p.theme.fontSize == 13)
            #expect(Theme.font.pointSize == 13)
            let pane = ThemesSettingsPane(prefs: p)
            pane.segment = .fonts
            _ = pane.view
            #expect(sizeField(pane, "Plain Text") == "13")
            #expect(pane.font(for: .identifier).size == 13)
            // Every token row without a font of its own follows it.
            #expect(sizeField(pane, "Comments") == "13" && sizeField(pane, "Keywords") == "13")
            // A duplicate of the default starts at 13.
            let copy = try p.duplicate(p.theme)
            #expect(copy.fontSize == 13)
        }
    }

    @Test func userThemesKeepTheirOwnSize() throws {
        try withPreferences("user") { p, themes in
            // A theme saved before beta 2, duplicated from the 12-point default.
            var mine = EditorTheme.builtIns[0]
            mine.name = "Mine"
            mine.fontSize = 12
            try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
            try mine.write(to: themes.appendingPathComponent(mine.fileName))
            // A file that claims the built-in's name does not replace it.
            var impostor = EditorTheme.builtIns[0]
            impostor.fontSize = 11
            try impostor.write(to: themes.appendingPathComponent("Ycode Default copy.ycodetheme"))

            #expect(p.theme.name == "Ycode Default" && p.theme.fontSize == 13)
            let pane = ThemesSettingsPane(prefs: p)
            pane.segment = .fonts
            _ = pane.view
            #expect(sizeField(pane, "Plain Text") == "13")
            pane.chooseTheme("Mine")
            #expect(p.theme.fontSize == 12 && Theme.font.pointSize == 12)
            #expect(sizeField(pane, "Plain Text") == "12")
            // Editing it keeps the edit, and the default stays 13.
            pane.setFont(EditorTheme.FontSpec(name: "", size: 15), for: .identifier)
            #expect(try EditorTheme.read(themes.appendingPathComponent("Mine.ycodetheme")).fontSize == 15)
            pane.chooseTheme("Ycode Default")
            #expect(p.theme.fontSize == 13 && sizeField(pane, "Plain Text") == "13")
        }
    }

    // MARK: The inspector is 260 wide

    @Test func inspectorWidthIsTheReferences() {
        #expect(WorkspaceChrome.inspectorWidth == 260)
        #expect(WorkspaceWindowController.inspectorWidth == 260)
        // The editor between them: 1400 − 290 − 260.
        #expect(WorkspaceChrome.windowWidth - WorkspaceChrome.navigatorWidth - WorkspaceChrome.inspectorWidth == 850)
        #expect(EditorMetrics.minimapWidth(editorWidth: 850) == 127)
    }

    // MARK: Row 13: the editor's bottom bar

    @Test func bottomBarSeparatorIsTheMeasuredGrey() {
        var light = "", dark = ""
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            let c = EditorBottomBarBackdrop.separatorColor.usingColorSpace(.sRGB)!
            let a = c.alphaComponent
            let v = Int(((c.redComponent * a + (1 - a)) * 255).rounded())
            light = String(format: "#%02X%02X%02X", v, v, v)
        }
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            dark = EditorTheme.hex(EditorBottomBarBackdrop.separatorColor)
        }
        #expect(light == "#D7D7D7")
        #expect(!dark.isEmpty)
    }

    // MARK: Row 5: the editor under the toolbar band

    /// A rect's top, measured down from the window content's top edge.
    func top(_ v: NSView, in content: NSView) -> (top: CGFloat, bottom: CGFloat) {
        let r = v.convert(v.bounds, to: content)
        return content.isFlipped ? (r.minY, r.maxY) : (content.bounds.maxY - r.maxY, content.bounds.maxY - r.minY)
    }

    @Test func editorRunsUnderTheToolbarBand() throws {
        guard #available(macOS 26, *) else { return }
        let fc = FidelityCouncilTests()
        let dir = try fc.project("r2-band")
        let wc = try fc.window(dir)
        wc.open(path: dir.appendingPathComponent("GlassScroll/Long.swift").path, line: nil)
        let content = try #require(wc.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let band = CGFloat(WorkspaceChrome.toolbarHeight)
        let e = wc.editor
        // The split starts below the toolbar; the editor area reaches the
        // window's top, its safe area the toolbar's bottom.
        #expect(abs(top(wc.centerSplit.view, in: content).top - band) <= 0.5)
        #expect(abs(wc.editorOverhang - band) <= 0.5, "\(wc.editorOverhang)")
        #expect(abs(top(wc.editorArea.view, in: content).top) <= 0.5)
        #expect(abs(e.view.safeAreaInsets.top - band) <= 0.5, "\(e.view.safeAreaInsets)")
        // The text and the band's veil run from the window's top; the jump
        // bar keeps y 52–84; the first line rests below it.
        #expect(abs(top(e.scrollView, in: content).top) <= 0.5)
        let backdrop = top(e.bandBackdrop, in: content)
        #expect(abs(backdrop.top) <= 0.5 && abs(backdrop.bottom - band - JumpBar.height) <= 0.5, "\(backdrop)")
        // One backdrop from the window's top to the jump bar's separator; it
        // shows the content's shape (liquid-glass.md §9.1 replaced the flat
        // material, row 68).
        #expect(e.bandBackdrop.showsStructure && e.bandBackdrop.regions().count == 2)
        let jump = top(e.jumpBar, in: content)
        #expect(abs(jump.top - band) <= 0.5 && abs(jump.bottom - band - JumpBar.height) <= 0.5, "\(jump)")
        #expect(abs(e.scrollView.contentInsets.top - band - JumpBar.height) <= 0.5)
        #expect(abs(e.scrollView.contentView.bounds.minY + e.scrollView.contentInsets.top) <= 0.5)
        // Nothing between the editor and the column clips it.
        var v: NSView? = wc.editorArea.view.superview
        while let x = v, !(x is CenterColumnView) {
            #expect(!x.clipsToBounds, "\(type(of: x)) clips")
            v = x.superview
        }
    }

    @Test func debugAreaKeepsItsHeightWithTheEditorUnderTheToolbar() throws {
        guard #available(macOS 26, *) else { return }
        let fc = FidelityCouncilTests()
        let dir = try fc.project("r2-debug")
        let wc = try fc.window(dir)
        wc.open(path: dir.appendingPathComponent("GlassScroll/Long.swift").path, line: nil)
        let content = try #require(wc.window?.contentView)
        wc.showDebugArea(true)
        content.layoutSubtreeIfNeeded()
        #expect(abs((wc.debugAreaHeightShown ?? 0) - CGFloat(WorkspaceChrome.debugAreaHeight)) <= 0.5, "\(wc.debugAreaHeightShown ?? -1)")
        let split = wc.centerSplit.splitView
        for h in [220.0, 300, 90] as [CGFloat] {
            split.setPosition(split.bounds.height - h - split.dividerThickness, ofDividerAt: 0)
            split.layoutSubtreeIfNeeded()
            #expect(abs((wc.debugAreaHeightShown ?? 0) - h) <= 0.5, "\(h): \(wc.debugAreaHeightShown ?? -1)")
            // The editor still reaches the window's top, and the debug bar
            // sits on the debug area.
            #expect(abs(wc.editorOverhang - CGFloat(WorkspaceChrome.toolbarHeight)) <= 0.5)
            let bar = top(wc.debugArea.debugBar, in: content), area = top(wc.debugArea.view, in: content)
            #expect(abs(area.top - bar.bottom - split.dividerThickness) <= 0.5, "\(bar) \(area)")
        }
        // The window grows: the debug area keeps its height.
        if let w = wc.window {
            w.setFrame(NSRect(origin: w.frame.origin, size: NSSize(width: w.frame.width, height: w.frame.height + 40)), display: false)
            content.layoutSubtreeIfNeeded()
            #expect(abs((wc.debugAreaHeightShown ?? 0) - 90) <= 0.5, "\(wc.debugAreaHeightShown ?? -1)")
        }
    }

    @Test func bottomBarIsTheEditorsVeil() throws {
        guard #available(macOS 26, *) else { return }
        _ = NSApplication.shared
        let d = DebugAreaController()
        _ = d.view
        let backdrop = try #require(d.bottomBarBackdrop)
        #expect(backdrop.superview === d.debugBar && backdrop.frame.size == d.debugBar.frame.size || d.debugBar.frame.isEmpty)
        // The content's shape at 12 % (liquid-glass.md §8.3, §9.1).
        #expect(backdrop.showsStructure && backdrop.regions().map(\.share) == [CGFloat(BarBlur.bottomBarShare)])
    }

    // MARK: Council round 2, defect 2: the first line keeps its inset

    /// The first line's top below the editor's top edge, and where it should be.
    func firstLineTop(_ e: SourceEditorController) -> (actual: CGFloat, expected: CGFloat) {
        e.view.layoutSubtreeIfNeeded()
        let clip = e.scrollView.contentView
        let origin = e.textView.textContainerOrigin
        let lineTop = e.view.convert(NSPoint(x: 0, y: origin.y), from: e.textView)
        let top = e.view.isFlipped ? lineTop.y : e.view.bounds.maxY - lineTop.y
        _ = clip
        return (top, e.view.safeAreaInsets.top + JumpBar.height + CGFloat(EditorMetrics.firstLineInset))
    }

    func expectFirstLine(_ wc: WorkspaceWindowController, _ step: String, sourceLocation: SourceLocation = #_sourceLocation) {
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        for e in wc.editorArea.tab.editors where e.fileURL != nil {
            let t = firstLineTop(e)
            #expect(abs(t.actual - t.expected) <= 0.5, "\(step): first line at \(t.actual), expected \(t.expected)", sourceLocation: sourceLocation)
            #expect(abs(e.scrollView.contentView.bounds.minY + e.scrollView.contentInsets.top) <= 0.5,
                    "\(step): clip at \(e.scrollView.contentView.bounds.minY), inset \(e.scrollView.contentInsets.top)", sourceLocation: sourceLocation)
        }
    }

    /// Runs the run loop until `done` or `seconds` pass (the inspector's slide).
    func spin(_ seconds: Double, until done: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    @Test func firstLineKeepsItsInsetThroughTogglesSplitsAndResizes() throws {
        let fc = FidelityCouncilTests()
        let dir = try fc.project("r2-inset")
        let wc = try fc.window(dir)
        wc.window?.orderBack(nil)
        defer { wc.window?.orderOut(nil) }
        wc.open(path: dir.appendingPathComponent("GlassScroll/Long.swift").path, line: nil)
        expectFirstLine(wc, "opened")
        // The end of a live resize (the window's, or the inspector's slide)
        // scrolled the caret's line under the jump bar.
        wc.editor.textView.viewWillStartLiveResize()
        wc.editor.textView.viewDidEndLiveResize()
        expectFirstLine(wc, "live resize ended")
        wc.toggleInspector(nil)
        spin(1) { !wc.isInspectorSliding }
        expectFirstLine(wc, "inspector hidden")
        wc.toggleInspector(nil)
        spin(1) { !wc.isInspectorSliding }
        expectFirstLine(wc, "inspector shown")
        wc.toggleNavigator(nil)
        spin(0.3)
        expectFirstLine(wc, "navigator hidden")
        wc.toggleNavigator(nil)
        spin(0.3)
        expectFirstLine(wc, "navigator shown")
        wc.splitEditor(nil)
        spin(0.2)
        expectFirstLine(wc, "split")
        if let w = wc.window {
            for size in [NSSize(width: 1100, height: 700), NSSize(width: 1500, height: 950), NSSize(width: 1400, height: 900)] {
                w.setFrame(NSRect(origin: w.frame.origin, size: size), display: true)
                spin(0.1)
                expectFirstLine(wc, "resized to \(size)")
            }
        }
        wc.toggleInspector(nil)
        spin(1) { !wc.isInspectorSliding }
        expectFirstLine(wc, "split, inspector hidden")
    }

    // MARK: Council round 2: line-based wheel scrolling is 1:1

    func wheel(_ dy: Int32, continuous: Bool) -> NSEvent {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0)!
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: continuous ? 1 : 0)
        return NSEvent(cgEvent: cg)!
    }

    @Test func lineWheelScrollingMovesOneToOne() throws {
        let fc = FidelityCouncilTests()
        let dir = try fc.project("r2-wheel")
        let wc = try fc.window(dir)
        wc.open(path: dir.appendingPathComponent("GlassScroll/Long.swift").path, line: nil)
        let e = wc.editor
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        let clip = e.scrollView.contentView
        let y0 = clip.bounds.minY
        let ev = wheel(-30, continuous: false)
        #expect(!ev.hasPreciseScrollingDeltas && ev.phase.isEmpty)
        for _ in 0..<20 { e.scrollView.scrollWheel(with: ev) }
        #expect(abs(clip.bounds.minY - y0 - 600) <= 1, "moved \(clip.bounds.minY - y0)")
        // Over the minimap and the sticky header too.
        let y1 = clip.bounds.minY
        for _ in 0..<5 { e.minimap.scrollWheel(with: wheel(30, continuous: false)) }
        #expect(abs(clip.bounds.minY - y1 + 150) <= 1, "moved \(clip.bounds.minY - y1)")
        #expect(EditorScrollView.pointDelta(of: wheel(-30, continuous: true)) == nil)
    }

    // MARK: Council round 2: full blocks take a whole column

    @Test func fullBlocksTakeTheEditorsAdvance() throws {
        let fc = FidelityCouncilTests()
        let dir = try fc.project("r2-blocks")
        let blocks = String(repeating: "\u{2588}", count: 34)
        let file = dir.appendingPathComponent("GlassScroll/Bands.swift")
        try "// \(blocks)\nlet s = \"\(blocks)\"\n\(blocks)\n\u{2500}\u{2502}\u{2591}\u{25A0}\n".write(to: file, atomically: true, encoding: .utf8)
        let wc = try fc.window(dir)
        wc.open(path: file.path, line: nil)
        let e = wc.editor
        let storage = try #require(e.textView.textStorage)
        let text = storage.string as NSString
        let advance = Theme.advance
        #expect(abs(advance - 8) < 0.01)
        // Each line's blocks measure 34 advances, in the comment, the string and plain text.
        var location = 0
        for _ in 0..<3 {
            let r = text.range(of: blocks, options: [], range: NSRange(location: location, length: text.length - location))
            try #require(r.location != NSNotFound)
            let width = storage.attributedSubstring(from: r).size().width
            #expect(abs(width - 34 * advance) < 0.5, "\(width) for 34 blocks")
            location = NSMaxRange(r)
        }
        // Box drawing, shades and squares too.
        let mixed = text.range(of: "\u{2500}\u{2502}\u{2591}\u{25A0}")
        #expect(abs(storage.attributedSubstring(from: mixed).size().width - 4 * advance) < 0.5)
    }

    // MARK: Round 2: navigator rows (rows 12, 20, 38, 39, 47)

    @Test func navigatorRowsSelectionLabelsGroupsAndAccessibility() throws {
        let fc = FidelityCouncilTests()
        let dir = try fc.project("r2-rows")
        let wc = try fc.window(dir)
        wc.showWindow(nil)
        defer { wc.window?.orderOut(nil) }
        let o = wc.navigator.outlineView
        wc.open(path: dir.appendingPathComponent("GlassScroll/Long.swift").path, line: nil)
        o.layoutSubtreeIfNeeded()
        let row = o.selectedRow
        try #require(row >= 0)
        let rv = try #require(o.rowView(atRow: row, makeIfNecessary: true) as? NavigatorRowView)
        // The band: 22 tall, inset 10, corners 8.
        let band = NavigatorRowView.bandRect(in: rv.bounds)
        #expect(band.height == 22 && band.minX == rv.bounds.minX + 10 && abs(rv.bounds.maxX - band.maxX - 10) < 0.01)
        // Focused: accent band, white label and icon; unfocused: the label colour.
        rv.isEmphasized = true
        let cell = try #require(o.view(atColumn: 0, row: row, makeIfNecessary: true) as? NavigatorCellView)
        cell.backgroundStyle = rv.interiorBackgroundStyle
        #expect(cell.textField?.textColor == .alternateSelectedControlTextColor && cell.imageView?.contentTintColor == .alternateSelectedControlTextColor)
        cell.backgroundStyle = .normal
        var hex = ""
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { hex = EditorTheme.hex(cell.textField?.textColor ?? .black) }
        #expect(hex == "#3B3B3C")
        #expect(cell.textField?.font?.fontDescriptor.symbolicTraits.contains(.bold) == false)
        // Every row is an accessibility row titled with its name.
        for r in 0..<o.numberOfRows {
            let v = o.rowView(atRow: r, makeIfNecessary: true)
            #expect(v?.accessibilityTitle()?.isEmpty == false, "row \(r)")
        }
        #expect((0..<o.numberOfRows).contains { o.rowView(atRow: $0, makeIfNecessary: true)?.accessibilityTitle().map { $0 == "Stripes" || $0 == "Stripes.png" } == true })
        // Plain groups grey, synchronized folders blue.
        #expect(WorkspaceChrome.iconTint(kind: .group, name: "Plain") == .grey)
        #expect(WorkspaceChrome.symbol(kind: .group, name: "Plain", path: nil) == "folder.fill")
        // After a click the outline keeps focus and the band stays.
        wc.window?.makeFirstResponder(o)
        wc.openFromNavigator(path: dir.appendingPathComponent("GlassScroll/ContentView.swift").path, line: nil, modifiers: [])
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        #expect(wc.window?.firstResponder === o)
        #expect(o.selectedRow >= 0 && (o.item(atRow: o.selectedRow) as? OutlineItem)?.path?.hasSuffix("ContentView.swift") == true)
    }

    // MARK: Round 2: toolbar toggles and unavailable buttons (row 37)

    @Test func toolbarTogglesAreGreyAndUnavailableButtonsDim() throws {
        let fc = FidelityCouncilTests()
        let dir = try fc.project("r2-toolbar")
        let wc = try fc.window(dir)
        wc.updateToolbarState()
        for c in [wc.toolbarControls.leftPanes, wc.toolbarControls.editorModes] {
            #expect(c.selectedSegmentBezelColor == WorkspaceWindowController.togglePillColor)
        }
        let items = Dictionary((wc.window?.toolbar?.items ?? []).map { ($0.itemIdentifier, $0) }) { a, _ in a }
        let run = try #require(items[WorkspaceWindowController.runID]?.view as? NSSegmentedControl)
        let history = try #require(items[WorkspaceWindowController.historyID]?.view as? NSSegmentedControl)
        #expect(run.isEnabled(forSegment: 0) && !run.isEnabled(forSegment: 1))
        #expect(!history.isEnabled(forSegment: 0) && !history.isEnabled(forSegment: 1))
        wc.open(path: dir.appendingPathComponent("GlassScroll/Long.swift").path, line: nil)
        wc.open(path: dir.appendingPathComponent("GlassScroll/ContentView.swift").path, line: nil)
        #expect(history.isEnabled(forSegment: 0) && !history.isEnabled(forSegment: 1))
        wc.goBack(nil)
        #expect(history.isEnabled(forSegment: 1))
    }

    // MARK: Round 2: the inspector slide's timing (row 9)

    @Test func inspectorSlideFollowsTheRound2Timing() {
        #expect(EditorMetrics.inspectorSlideProgress(elapsed: 0.04, show: false) == 0)
        #expect(EditorMetrics.inspectorSlideProgress(elapsed: 0.11, show: true) == 0)
        // The measured hide progress (ms from the press), within the ease-in-out fit's error.
        let hide: [(Double, Double)] = [(81, 0.08), (111, 0.20), (144, 0.44), (180, 0.68), (214, 0.87), (240, 0.97), (264, 1)]
        var squares = 0.0
        for (ms, p) in hide {
            let d = EditorMetrics.inspectorSlideProgress(elapsed: ms / 1000, show: false) - p
            squares += d * d
            #expect(abs(d) < 0.12, "\(ms) ms")
        }
        #expect((squares / Double(hide.count)).squareRoot() < 0.07)
        // Round 4's fits (editor-area.md F.5): 43 + 226 and 118 + 217 ms.
        #expect(abs(EditorMetrics.inspectorSlideTotal(show: false) - 0.269) < 0.001)
        #expect(abs(EditorMetrics.inspectorSlideTotal(show: true) - 0.335) < 0.001)
    }

    // MARK: Round 2: inspector (rows 41–43) and the status bar for images (row 44)

    @Test func inspectorHeadingsRulesAndImageRows() throws {
        let fc = FidelityCouncilTests()
        let dir = try fc.project("r2-inspector")
        let wc = try fc.window(dir)
        wc.open(path: dir.appendingPathComponent("GlassScroll/Long.swift").path, line: nil)
        let i = wc.inspector
        // Rules after Type, Full Path and Line Endings.
        #expect(i.innerRuleCount == 3)
        var hex = ""
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { hex = EditorTheme.hex(InspectorStyle.headingColor) }
        #expect(hex == "#858587")
        // "Alpha Channel" fits the key column.
        let fitted = InspectorStyle.fitted("Alpha Channel", font: .systemFont(ofSize: 11), width: InspectorAreaController.keyColumnWidth)
        #expect(fitted.size().width <= InspectorAreaController.keyColumnWidth - 4 + 0.5)
        // An image: Resolution "--" when the file records none, a Tags
        // field, Localize… across the value area, no Line and Col.
        var props = ImageFileProperties(pixelWidth: 800, pixelHeight: 1800, dpi: 72, colorSpace: "RGB", hasAlpha: false)
        props.recordsResolution = false
        #expect(props.rows.first { $0.0 == "Resolution" }?.1 == "--")
        #expect(props.rows.first { $0.0 == "Dimensions" }?.1 == "800 \u{00D7} 1800 pixels")
        wc.open(path: dir.appendingPathComponent("GlassScroll/Stripes.png").path, line: nil)
        let tags = try #require(i.fileControls["On Demand Resource Tags"] as? NSTokenField)
        #expect(tags.isEnabled && tags.placeholderString == "Tags")
        #expect(wc.debugArea.positionLabel.stringValue.isEmpty)
    }
}
