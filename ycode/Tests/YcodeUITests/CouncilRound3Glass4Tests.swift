import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Council round 3, main-window rows 68–82 (`specs/ide/fidelity-council.md`
/// "Round 3"; `liquid-glass.md` §9, `editor-area.md` E.1–E.7, `metrics.md`
/// §16, `navigators.md` round 3).
@MainActor
@Suite(.serialized) struct CouncilRound3Glass4Tests {
    let fc = FidelityCouncilTests()

    /// A window on the council's GlassScroll project, 1400 × 880.
    func window(_ name: String) throws -> (WorkspaceWindowController, URL) {
        let dir = try fc.project("g4-\(name)")
        let wc = try fc.window(dir)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 880), display: false)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        return (wc, dir)
    }

    /// The green channel (0–255) of `rep` at a point from the top left.
    static func green(_ rep: NSBitmapImageRep, x: CGFloat, y: CGFloat) -> Int {
        let sx = CGFloat(rep.pixelsWide) / rep.size.width, sy = CGFloat(rep.pixelsHigh) / rep.size.height
        guard let c = rep.colorAt(x: Int(x * sx), y: Int(y * sy))?.usingColorSpace(.sRGB) else { return -1 }
        return Int((c.greenComponent * 255).rounded())
    }

    // MARK: Row 72: image selection

    @Test func imageSelectionSwapsInOneFrameWithoutLoading() throws {
        let (wc, dir) = try window("image")
        defer { wc.window?.close() }
        wc.open(path: dir.appendingPathComponent("GlassScroll/Long.swift").path, line: nil)
        let stripes = dir.appendingPathComponent("GlassScroll/Stripes.png").path
        wc.open(path: stripes, line: nil)
        // In the same pass: the viewer with its image, no "Loading…", the
        // jump bar and the image's inspector.
        let viewer = try #require(wc.imageViewer)
        #expect(viewer.isReady && viewer.imageView.image != nil && !viewer.imageView.isHidden)
        #expect(viewer.loadingLabel.isHidden)
        #expect(wc.editor.auxiliaryFile?.path == stripes && wc.editor.jumpBarTitles.contains("Stripes"))
        #expect(wc.inspector.imageProperties?.pixelWidth == 80)
        #expect(ImageViewerLayout.loadingDelay == 0.45)
    }

    @Test func largeImageDecodesOffTheMainThread() async throws {
        let (wc, dir) = try window("image-large")
        defer { wc.window?.close() }
        let long = dir.appendingPathComponent("GlassScroll/Long.swift")
        wc.open(path: long.path, line: nil)
        // A file over the synchronous limit decodes off the main thread.
        let c = ImageViewerController(url: dir.appendingPathComponent("GlassScroll/Stripes.png"), synchronousLimit: 0)
        #expect(!c.isReady)
        _ = c.view
        #expect(c.loadingLabel.isHidden)   // not before the delay
        await c.loaded()
        #expect(c.isReady && c.loadingLabel.isHidden && c.imageView.image != nil)
    }

    // MARK: Row 73: open-document request

    @Test func openRequestForTheOpenFileChangesNothing() throws {
        let (wc, dir) = try window("openreq")
        defer { wc.window?.close() }
        let stripes = dir.appendingPathComponent("GlassScroll/Stripes.png")
        wc.open(path: stripes.path, line: nil)
        let viewer = try #require(wc.imageViewer)
        let titles = wc.editor.jumpBarTitles
        // The same file through a symbolic link to its folder (as /tmp is /private/tmp).
        let link = dir.appendingPathComponent("linked")
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir.appendingPathComponent("GlassScroll"))
        let viaLink = link.appendingPathComponent("Stripes.png")
        #expect(!wc.handleOpenRequest(viaLink))
        #expect(wc.imageViewer === viewer && wc.editor.jumpBarTitles == titles)
        // Another file named through the link opens under the project's own path.
        #expect(wc.handleOpenRequest(link.appendingPathComponent("Long.swift")))
        #expect(wc.editor.fileURL?.path == dir.appendingPathComponent("GlassScroll/Long.swift").path)
        #expect(wc.editor.jumpBarTitles.filter { $0 == "GlassScroll" }.count == 2, "\(wc.editor.jumpBarTitles)")
        #expect(wc.session.model.root.projectPath(forOpening: viaLink) == stripes.path)
    }

    // MARK: Row 70: flick

    @Test func flickBounceMatchesRoundThree() {
        // 48 points past the end of a flick crossing at about 2470 pt/s,
        // peaking about 67 ms after the crossing; at rest about 600 ms after it.
        let v = 2470.0
        #expect(abs(TopBounce.peak(velocity: v) - 48) < 1)
        #expect(abs(TopBounce.peakTime - 0.067) < 0.001)
        let d = TopBounce.duration(velocity: v)
        #expect(d > 0.5 && d < 0.7, "\(d)")
        // A bounce that takes over already past the top keeps going down from there.
        #expect(TopBounce.overscroll(from: 20, velocity: v, at: 0) == 20)
        #expect(TopBounce.overscroll(from: 20, velocity: v, at: 0.03) > 20)
        #expect(TopBounce.isAtRest(from: 20, velocity: v, at: 1.2))
    }

    /// The first event of a gesture moves the text (no hold).
    @Test func gestureMovesTheTextOnItsFirstEvent() throws {
        let (wc, dir) = try window("flick")
        defer { wc.window?.close() }
        wc.open(path: dir.appendingPathComponent("GlassScroll/Long.swift").path, line: nil)
        let scroll = try #require(wc.editor.scrollView as? EditorScrollView)
        let clip = scroll.contentView
        wc.window?.orderBack(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        clip.scroll(to: NSPoint(x: 0, y: EditorTopBounce.top(of: scroll) + 600))
        scroll.reflectScrolledClipView(clip)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let before = clip.bounds.minY
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 40, wheel2: 0, wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: 40)
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 40)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: 1)
        let ev = try #require(NSEvent(cgEvent: cg))
        scroll.scrollWheel(with: ev)
        #expect(abs((before - clip.bounds.minY) - 40) < 0.5, "moved \(before - clip.bounds.minY)")
    }

    // MARK: Row 68: structure behind the bars

    /// A file of red bands (string literals of full blocks) three lines
    /// tall with three blank lines between.
    func bandsText() -> String {
        var s = ""
        for _ in 0..<40 {
            for _ in 0..<3 { s += "let s = \"" + String(repeating: "\u{2588}", count: 60) + "\"\n" }
            s += "\n\n\n"
        }
        return s
    }

    @Test func jumpBarShowsTheBandsBeneathIt() throws {
        let g = CouncilRound2Glass3Tests()
        let (wc, e) = try g.editor(bandsText(), name: "Bands.swift")
        defer { wc.window?.close() }
        let clip = e.scrollView.contentView
        // Rows of the jump bar band, per scroll offset: the bands show
        // through at the jump bar's share, and keep their shape.
        func column(at offset: CGFloat) throws -> [Int] {
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: -e.scrollView.contentInsets.top + offset))
            e.scrollView.reflectScrolledClipView(clip)
            e.view.layoutSubtreeIfNeeded()
            let rep = try #require(e.view.bitmapImageRepForCachingDisplay(in: e.view.bounds))
            e.view.cacheDisplay(in: e.view.bounds, to: rep)
            let top = e.view.safeAreaInsets.top
            // x inside the blocks (the code column + 12 columns).
            return stride(from: top + 2, to: top + JumpBar.height - 2, by: 2).map { Self.green(rep, x: 51 + 8 * 60, y: $0) }
        }
        var spreads: [Int] = []
        for offset in stride(from: CGFloat(0), through: 100, by: 20) {
            let col = try column(at: offset)
            #expect(col.allSatisfy { $0 >= 200 }, "too dark: \(col)")   // a veil, not the text
            spreads.append((col.max() ?? 0) - (col.min() ?? 0))
        }
        // A flat tint has no spread; the bands' shape shows as one.
        #expect((spreads.max() ?? 0) >= 6, "\(spreads)")
    }

    @Test func barSharesAndKernel() {
        #expect(BarBlur.sigma == 6 && BarBlur.toolbarBandShare == 0.18 && BarBlur.jumpBarShare == 0.085 && BarBlur.bottomBarShare == 0.12)
        let k = GaussianKernel.weights(sigma: 6)
        #expect(k.count == 37 && abs(k.reduce(0, +) - 1) < 1e-9)
        // A 15-point black band blurred at σ 6 keeps a peak in its middle.
        let band = (0..<80).map { $0 >= 30 && $0 < 45 ? 0.0 : 1.0 }
        let b = GaussianKernel.blur(band, sigma: 6)
        #expect(b[37] < 0.6 && b[10] > 0.99 && b[70] > 0.99)
        // Through the jump bar, black shows as 8.5 % darkness.
        #expect(abs(BarBlur.shown(content: 0, share: BarBlur.jumpBarShare) - 0.915) < 1e-9)
    }

    // MARK: Rows 75, 76: text layout

    /// "// " and a 110-block band: every block one cell, whatever face
    /// draws it (E.7 item 2). Where the band breaks is round 4's rule
    /// (F.1, `CouncilRound4EditorTests`): "//" alone, then the run.
    @Test func blockRunTakesOneCellPerBlock() throws {
        let band = "// " + String(repeating: "\u{2588}", count: 110)
        let g = CouncilRound2Glass3Tests()
        let (wc, e) = try g.editor("import Foundation\n\n" + band + "\nlet x = 1\n", name: "Bands.swift")
        defer { wc.window?.close() }
        let tlm = try #require(e.textView.textLayoutManager)
        tlm.ensureLayout(for: tlm.documentRange)
        var rows: [(NSRange, CGFloat)] = []
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: [.ensuresLayout]) { f in
            let start = tlm.offset(from: tlm.documentRange.location, to: f.rangeInElement.location)
            if start == 19 { rows = f.textLineFragments.map { ($0.characterRange, $0.typographicBounds.width) } }
            return true
        }
        #expect(rows.count == 3, "\(rows)")
        #expect(rows.first?.0.length == 3)
        // Every block advances one cell, fallback faces included.
        let blocks = rows.dropFirst()
        let total: CGFloat = blocks.map(\.1).reduce(0, +)
        // (the last row's range holds the line's end too)
        let cells = CGFloat(blocks.map(\.0.length).reduce(0, +) - 1)
        #expect(cells == 110 && abs(total - cells * Theme.advance) < 1, "\(total)")
    }

    /// The editor starts with the scroll bar style as it will settle, so
    /// its first layout wraps like every later one (E.7 item 3).
    @Test func firstLayoutUsesTheSettledScrollerStyle() throws {
        EditorScrollerStyle.noteSettled(.legacy)
        #expect(UserDefaults.standard.integer(forKey: EditorScrollerStyle.defaultsKey) == NSScroller.Style.legacy.rawValue)
        #expect(EditorScrollerStyle.initial == NSScroller.preferredScrollerStyle)
        // With a lane, the container still ends 10 before the minimap.
        let (wc, dir) = try window("lane")
        defer { wc.window?.close() }
        let e = wc.editor
        e.scrollView.scrollerStyle = .legacy
        wc.open(path: dir.appendingPathComponent("GlassScroll/Long.swift").path, line: nil)
        e.view.layoutSubtreeIfNeeded()
        let tc = try #require(e.textView.textContainer)
        let end = e.view.convert(NSPoint(x: e.textView.textContainerOrigin.x + tc.size.width, y: 0), from: e.textView).x
        #expect(abs(e.minimap.frame.minX - end - 10) < 0.5, "end \(end), minimap \(e.minimap.frame)")
        #expect(e.scrollerLaneWidth > 0)
    }

    // MARK: Row 79: the File inspector's rhythm

    /// Ink tops of the File inspector's labels relative to Name's, as
    /// metrics.md §16.2 measures them (text tops, a bold heading's cap
    /// sits like a regular label's).
    static func inspectorTops(_ wc: WorkspaceWindowController) -> [String: CGFloat] {
        let root = wc.inspector.view
        root.layoutSubtreeIfNeeded()
        var out: [String: CGFloat] = [:]
        func walk(_ v: NSView) {
            if let t = v as? NSTextField, !t.isEditable, !t.isHidden, t.window != nil {
                let r = t.convert(t.bounds, to: nil)
                let top = root.window!.contentView!.bounds.height - r.maxY
                let key = t.stringValue
                // The first one wins (labels appear once each).
                if out[key] == nil, let f = t.font {
                    // Ink top: the label's frame top plus its ascender less the cap height.
                    out[key] = top + (t.frame.height - (f.ascender - f.descender)) / 2 + (f.ascender - f.capHeight)
                }
            }
            v.subviews.forEach(walk)
        }
        walk(root)
        return out
    }

    /// The bottom of the Full Path value's text, from the window's top.
    static func pathBottom(_ wc: WorkspaceWindowController) -> CGFloat {
        let root = wc.inspector.view
        var out = CGFloat.nan
        func walk(_ v: NSView) {
            if let t = v as? NSTextField, t.stringValue.contains("Long.swift"), t.stringValue.contains("/") {
                let r = t.convert(t.bounds, to: nil)
                out = root.window!.contentView!.bounds.height - r.minY
            }
            v.subviews.forEach(walk)
        }
        walk(root)
        return out
    }

    @Test func fileInspectorRhythm() throws {
        // Outside any git working copy, as the council's project was (no
        // Working Copy rows).
        let built = try fc.project("g4-inspector")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("g4-inspector-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: built, to: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wc = try fc.window(dir)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 880), display: false)
        defer { wc.window?.close() }
        wc.open(path: dir.appendingPathComponent("GlassScroll/Long.swift").path, line: nil)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        let t = Self.inspectorTops(wc)
        let name = try #require(t["Name"])
        let rel = { (k: String) -> CGFloat in (t[k] ?? .nan) - name }
        // The reference (metrics.md §16.2), relative to Name at 117.
        let reference: [(String, CGFloat)] = [("Identity and Type", -27), ("Type", 23.5), ("Location", 51.5), ("Long.swift", 71),
                                              ("Full Path", 89)]
        for (k, v) in reference { #expect(abs(rel(k) - v) <= 1, "\(k): \(rel(k)) against \(v)") }
        // The path's length differs between projects: the tags heading 4
        // closer to the path's last line than before (26.4 → 22.4), and
        // Target Membership 67 below the tags heading (was 55; 267 → 334).
        let tags = rel("On Demand Resource Tags"), path = Self.pathBottom(wc) - name
        #expect(abs(tags - path - 22.4) <= 1, "\(tags - path)")
        #expect(abs(rel("Target Membership") - tags - 67) <= 1, "\(rel("Target Membership") - tags)")
    }

    // MARK: Row 69: the selector capsule

    @Test func selectorCapsuleBlursTheRowsAndDrawsBlackGlyphs() throws {
        guard #available(macOS 26, *) else { return }
        let (wc, _) = try window("selector")
        defer { wc.window?.close() }
        let nav = wc.navigator
        nav.select(0)
        nav.view.layoutSubtreeIfNeeded()
        // The glyphs: the primary label colour (black in light).
        #expect(nav.selectorButtons.allSatisfy { $0.contentTintColor == .labelColor })
        // An opaque backdrop under the glass, in the capsule's frame, drawn
        // from the outline beneath.
        let backdrop = nav.selectorBackdrop
        #expect(backdrop.superview === nav.selectorGlass.superview && backdrop.frame == nav.selectorGlass.frame)
        let siblings = backdrop.superview?.subviews ?? []
        #expect((siblings.firstIndex(of: backdrop) ?? 0) < (siblings.firstIndex(of: nav.selectorGlass) ?? 0))
        #expect(backdrop.sources().first === nav.scrollView)
        // Rows scrolled under it show as smudges: no pixel near black, and
        // the fill over a blank stretch is about #E8–#F6 before the glass.
        let clip = nav.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY + 60))
        nav.scrollView.reflectScrolledClipView(clip)
        let rep = try #require(backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds))
        backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
        var darkest = 255
        for x in stride(from: CGFloat(20), to: backdrop.bounds.width - 20, by: 3) {
            for y in stride(from: CGFloat(4), to: backdrop.bounds.height - 4, by: 2) { darkest = min(darkest, Self.green(rep, x: x, y: y)) }
        }
        #expect(darkest > 150, "a legible stroke: \(darkest)")
        #expect(BarBlur.selectorShare < 0.5 && BarBlur.selectorFill > 0)
    }

    // MARK: Rows 71, 81: split panes

    @Test func splitPanesHaveTheirOwnJumpBarsAndFocus() throws {
        let (wc, dir) = try window("split")
        defer { wc.window?.close() }
        wc.open(path: dir.appendingPathComponent("GlassScroll/Long.swift").path, line: nil)
        let first = wc.editor
        #expect(first.jumpBar.isActivePane && first.jumpBar.paneCloseButton == nil)
        wc.split(sideBySide: true)
        let second = wc.editor
        #expect(second !== first)
        // Row 81: the new pane takes keyboard focus (the navigator's band
        // turns grey).
        #expect(wc.window?.firstResponder === second.textView)
        // Row 71: a close button in each pane; the focused pane's path in
        // colour, the other's grey.
        #expect(first.jumpBar.paneCloseButton != nil && second.jumpBar.paneCloseButton != nil)
        #expect(second.jumpBar.isActivePane && !first.jumpBar.isActivePane)
        let labels = { (e: SourceEditorController) in e.jumpBar.stack.arrangedSubviews.compactMap { $0 as? FadingTruncationLabel } }
        #expect(labels(first).allSatisfy { $0.textColor == .secondaryLabelColor })
        #expect(labels(second).allSatisfy { $0.textColor == .labelColor })
        // The middle component gives way first; the file keeps its name.
        let mids = labels(second)
        #expect(mids.count >= 3)
        if mids.count >= 3 {
            #expect(mids[1].contentCompressionResistancePriority(for: .horizontal) < mids[0].contentCompressionResistancePriority(for: .horizontal))
            #expect(mids[1].contentCompressionResistancePriority(for: .horizontal) < mids[mids.count - 1].contentCompressionResistancePriority(for: .horizontal))
        }
        // Focus back on the first pane swaps the colours.
        wc.editorArea.focus(first)
        #expect(first.jumpBar.isActivePane && !second.jumpBar.isActivePane)
        // The close button closes its pane.
        second.jumpBar.paneCloseButton?.performClick(nil)
        #expect(wc.editorArea.tab.editors.count == 1 && first.jumpBar.paneCloseButton == nil)
    }

    @Test func fadingLabelFadesWhenCut() {
        let l = FadingTruncationLabel(labelWithString: "GlassScrollGroup")
        l.font = .systemFont(ofSize: 11)
        l.frame = NSRect(x: 0, y: 0, width: 30, height: 14)
        l.layout()
        #expect(l.isTruncated && l.layer?.mask is CAGradientLayer)
        l.frame.size.width = 400
        l.layout()
        #expect(!l.isTruncated && l.layer?.mask == nil)
        #expect(JumpBar.truncationFade == 4)
    }

    // MARK: Row 78: the jump bar's text

    @Test func jumpBarPathSitsOnTheBandCentre() throws {
        let (wc, dir) = try window("jumpbar")
        defer { wc.window?.close() }
        wc.open(path: dir.appendingPathComponent("GlassScroll/Long.swift").path, line: nil)
        let bar = wc.editor.jumpBar
        bar.layoutSubtreeIfNeeded()
        // The band's centre less 0.5 (metrics.md §16.1): the band is the
        // bar above its separator; the stack centres 2.75 above the bar's
        // centre.
        let barCentre = bar.bounds.midY, stackCentre = bar.stack.frame.midY
        #expect(abs((stackCentre - barCentre) - 2.75) < 0.3, "\(stackCentre - barCentre)")
        #expect(JumpBar.pathRaise == -2.75)
    }

    // MARK: Row 74: the empty editor

    @Test func emptyEditorHasNoMinimapOrLane() throws {
        let (wc, dir) = try window("empty")
        defer { wc.window?.close() }
        let e = wc.editor
        if e.fileURL != nil { wc.closeDocument(nil) }
        #expect(e.showsNoDocument)
        #expect(e.minimap.isHidden && !e.scrollView.hasVerticalScroller)
        wc.open(path: dir.appendingPathComponent("GlassScroll/Long.swift").path, line: nil)
        #expect(!e.showsNoDocument && !e.minimap.isHidden && e.scrollView.hasVerticalScroller)
        wc.closeDocument(nil)
        #expect(e.minimap.isHidden && !e.scrollView.hasVerticalScroller)
    }

    // MARK: Row 77: the minimap's floor

    @Test func minimapNeverNarrowerThanTheFloor() {
        // Measured from the separator to the scroll lane (3 into the scroll
        // bar): 131 at 850, 67 at 424, 63 at 274, about 139 at 1110.
        func measured(_ w: Double) -> Double { EditorMetrics.minimapWidth(editorWidth: w) + EditorMetrics.minimapSeparator + 3 }
        #expect(measured(850) == 131 && measured(424) == 67 && measured(274) == 63 && measured(1110) == 139)
        #expect(EditorMetrics.minimapWidth(editorWidth: 0) == 0)
    }

    // MARK: Row 80: the Welcome icon

    @Test func welcomeIconIs98AndSits15AboveTheName() throws {
        guard #available(macOS 26, *) else { return }
        _ = NSApplication.shared
        let td = TestDefaults("g4-welcome")
        defer { td.remove() }
        let w = WelcomeWindowController(recents: RecentProjects(defaults: td.defaults))
        defer { w.window?.close() }
        let content = try #require(w.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let icon = w.iconView.frame
        let margin = icon.width * CGFloat(ProductIconGeometry.fieldMin / ProductIconGeometry.side)
        let drawn = icon.width - 2 * margin
        #expect(abs(drawn - 98) < 0.5, "\(drawn)")
        // From the window's top: the drawn icon's bottom, and the name's cap top.
        let top = content.bounds.height
        let iconBottom = top - icon.minY - margin
        let nameBaseline = top - (w.nameLabel.frame.minY + w.nameLabel.baselineOffsetFromBottom)
        let capTop = nameBaseline - (w.nameLabel.font?.capHeight ?? 13)
        #expect(abs((capTop - iconBottom) - 15.5) < 1, "\(capTop - iconBottom)")
        #expect(abs((capTop - (iconBottom - drawn)) - 113.5) < 1)
    }

    // MARK: Row 82: the Repositories view

    @Test func repositoriesViewOpensOnlyBranches() throws {
        let tree = SourceControlNavigatorModel.repositoriesTree(
            repository: "Conflict", branch: "main", branches: [.init(name: "main", isCurrent: true), .init(name: "feature", isCurrent: false)],
            recents: ["feature"], tags: [], stashes: [], remotes: [], remoteBranches: [])
        let repo = try #require(tree.first)
        #expect(repo.detail == "main" && repo.symbol == RepositoriesViewStyle.repositorySymbol)
        #expect(repo.children.map(\.symbol) == ["square.stack.3d.up.fill", "clock", "tag.fill", "tray", "globe"])
        #expect(repo.children.allSatisfy { $0.alwaysExpandable && $0.tint != nil })
        #expect(repo.children[0].children.allSatisfy { $0.detail == nil })
        #expect(repo.children.map { SourceControlNavigatorModel.expandsInitially($0) } == [true, false, false, false, false])
        #expect(SourceControlNavigatorModel.expandsInitially(repo))
        // The filter alone across the bar.
        #expect(NavigatorBars.specs[1].left == .none)
        // In the window: the control spans the navigator 9 from each side.
        let (wc, _) = try window("repositories")
        defer { wc.window?.close() }
        let nav = wc.navigator
        nav.select(1)
        // From the Changes tree, as the mode control switches.
        nav.setSourceControlRoots(SourceControlNavigatorModel.changesTree(repository: "Conflict", branch: "main", changes: [],
                                                                          root: URL(fileURLWithPath: "/r")))
        nav.setSourceControlRoots(tree)
        nav.view.layoutSubtreeIfNeeded()
        let control = nav.sourceControlMode
        #expect(abs(control.frame.minX - 9) < 0.5 && abs(nav.view.bounds.width - control.frame.maxX - 9) < 0.5, "\(control.frame)")
        #expect(control.segmentDistribution == .fillEqually)
        // Only the repository and Branches are open: the branch rows show,
        // Recents' "feature" does not repeat under Recents.
        let shown = (0..<nav.outline.numberOfRows).compactMap { (nav.outline.item(atRow: $0) as? OutlineItem)?.title }
        #expect(shown == ["Conflict", "Branches", "feature", "main", "Recents", "Tags", "Stashes", "Remotes"], "\(shown)")
        // A refresh keeps what was opened.
        nav.outline.expandItem(repo.children[2])
        nav.setSourceControlRoots(tree)
        #expect(nav.outline.isItemExpanded(repo.children[2]) && !nav.outline.isItemExpanded(repo.children[1]))
    }
}
