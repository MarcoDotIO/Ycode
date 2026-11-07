import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

/// Council round 4, group D (`specs/ide/fidelity-council.md` rows 106–114;
/// `editor-area.md` F.5–F.12): main-window motion and chrome.
@MainActor
@Suite(.serialized) struct CouncilRound4MotionTests {
    func spin(_ seconds: Double, until done: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    }

    /// A council window at the capture's size with Long.swift open.
    func longWindow(_ tag: String) throws -> (WorkspaceWindowController, URL) {
        let fc = FidelityCouncilTests()
        let dir = try fc.project("r4-\(tag)")
        let wc = try fc.window(dir)
        if let w = wc.window { w.setFrame(NSRect(x: 40, y: 40, width: 1400, height: 880), display: false) }
        wc.window?.orderBack(nil)
        wc.open(path: dir.appendingPathComponent("GlassScroll/Long.swift").path, line: nil)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        wc.window?.displayIfNeeded()
        return (wc, dir)
    }

    // MARK: Row 106: the inspector's slide

    /// A measurement, not a check (`R4_PROFILE=1`; `R4_SAMPLE=1` loops for
    /// `sample`): the per-frame cost of the slide's layout, drawing and
    /// toolbar fit, and of the bars' blur.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["R4_PROFILE"] != nil))
    func profileInspectorSlideFrames() throws {
        let (wc, _) = try longWindow("profile")
        defer { wc.window?.orderOut(nil) }
        let split = wc.mainSplit.splitView
        let total = split.bounds.width, divider = split.dividerThickness
        let width = wc.inspector.view.frame.width
        wc.inspectorItem.minimumThickness = 1
        // As the slide does: the contents held at their width.
        wc.inspector.beginRigidSlide(width: width)
        defer { wc.inspector.endRigidSlide() }
        func run(_ name: String) {
            var layout = 0.0, display = 0.0, fit = 0.0
            for i in 0...24 {
                let p = CGFloat(i % 13) / 12
                let x = (total - divider - width + (width - 1) * (i < 13 ? p : 1 - p)).rounded()
                let t0 = CACurrentMediaTime()
                split.setPosition(x, ofDividerAt: 1)
                wc.window?.contentView?.layoutSubtreeIfNeeded()
                let t1 = CACurrentMediaTime()
                wc.window?.displayIfNeeded()
                let t2 = CACurrentMediaTime()
                wc.fitToolbar()
                let t3 = CACurrentMediaTime()
                layout += t1 - t0; display += t2 - t1; fit += t3 - t2
            }
            print("R4PROFILE \(name): layout \(Int(layout * 1000 / 25)) display \(Int(display * 1000 / 25)) fit \(Int(fit * 1000 / 25)) ms/frame")
        }
        do {
            let band = wc.editor.bandBackdrop
            let regions = band.regions()
            let t0 = CACurrentMediaTime()
            for _ in 0..<10 {
                for (rect, _) in regions { _ = StructureBlur.image(of: rect, in: band, sources: band.sources(), background: Theme.backgroundColor) }
            }
            let t1 = CACurrentMediaTime()
            for v in band.sources() {
                let r = v.convert(regions[1].rect, from: band).intersection(v.bounds)
                let t2 = CACurrentMediaTime()
                for _ in 0..<10 { if let rep = v.bitmapImageRepForCachingDisplay(in: r) { v.cacheDisplay(in: r, to: rep) } }
                print("R4PROFILE cacheDisplay \(type(of: v)) \(r.size): \(String(format: "%.1f", (CACurrentMediaTime() - t2) * 100)) ms")
            }
            if ProcessInfo.processInfo.environment["R4_SAMPLE_BARS"] != nil { for _ in 0..<4000 { band.display() } }
            let t3 = CACurrentMediaTime()
            for _ in 0..<10 { band.display(); wc.debugArea.bottomBarBackdrop?.display() }
            print("R4PROFILE bars display now: \(String(format: "%.1f", (CACurrentMediaTime() - t3) * 100)) ms per frame")
            print("R4PROFILE blur: \(regions.count) regions, \(String(format: "%.1f", (t1 - t0) * 100)) ms per band redraw; visible \(wc.window?.occlusionState.contains(.visible) == true)")
        }
        if ProcessInfo.processInfo.environment["R4_SAMPLE"] != nil {
            print("R4START pid \(getpid())")
            fflush(stdout)
            for _ in 0..<60 { run("sampling") }
        }
        run("baseline")
        let delegate = wc.editor.textView.textLayoutManager?.delegate
        wc.editor.textView.textLayoutManager?.delegate = nil
        run("no line-break delegate")
        wc.editor.textView.textLayoutManager?.delegate = delegate
        let sources = wc.editor.bandBackdrop.sources
        wc.editor.bandBackdrop.sources = { [] }
        let bottom = wc.debugArea.bottomBarBackdrop?.sources
        wc.debugArea.bottomBarBackdrop?.sources = { [] }
        run("no structure blur")
        wc.editor.bandBackdrop.sources = sources
        if let bottom { wc.debugArea.bottomBarBackdrop?.sources = bottom }
        run("baseline again")
    }

    /// The keyframe tables of F.5 against the slide's curve: hide starts
    /// within 48 ms, show at about 120, each about 220 ms of ease-in-out.
    @Test func inspectorSlideFollowsTheRound4Tables() {
        let hide: [(Double, Double)] = [(86, 0.18), (109, 0.21), (141, 0.41), (154, 0.48), (174, 0.65), (193, 0.76), (209, 0.90), (222, 0.92), (249, 1)]
        let show: [(Double, Double)] = [(154, 0.12), (167, 0.24), (190, 0.29), (216, 0.44), (231, 0.55), (257, 0.75), (269, 0.79), (294, 0.83), (308, 0.97), (334, 1)]
        for (table, isShow) in [(hide, false), (show, true)] {
            var squares = 0.0
            for (ms, p) in table {
                let d = EditorMetrics.inspectorSlideProgress(elapsed: ms / 1000, show: isShow) - p
                squares += d * d
                #expect(abs(d) < 0.15, "\(isShow ? "show" : "hide") \(ms) ms: \(d)")
            }
            #expect((squares / Double(table.count)).squareRoot() < 0.075, "\(isShow ? "show" : "hide")")
        }
        #expect(EditorMetrics.inspectorSlideDelay(show: false) <= 0.048 && abs(EditorMetrics.inspectorSlideDelay(show: true) - 0.12) <= 0.005)
        #expect(abs(EditorMetrics.inspectorSlideMotion(show: false) - 0.22) <= 0.01 && abs(EditorMetrics.inspectorSlideMotion(show: true) - 0.22) <= 0.01)
    }

    /// The slide's frames do the slide's own layout and nothing else: the
    /// bars hold their blurred image (no render of the text per frame),
    /// the toolbar is neither fitted nor updated per frame; one render and
    /// one fit follow the end. The frames follow the ease-in-out timing.
    @Test func inspectorSlideFramesHoldTheBarsBlur() throws {
        let (wc, _) = try longWindow("slide")
        defer { wc.window?.orderOut(nil) }
        let band = wc.editor.bandBackdrop
        let bottom = try #require(wc.debugArea.bottomBarBackdrop)
        band.display()
        bottom.display()
        #expect(band.renderCount >= 1 && bottom.renderCount >= 1)
        for hide in [true, false] {
            let bandRenders = band.renderCount, bottomRenders = bottom.renderCount
            wc.toggleInspector(nil)
            #expect(wc.isInspectorSliding && EditorBlurMotion.isHolding)
            let state = wc.inspectorSlide
            let step = try #require(state.onFrame)
            var frames: [CGFloat] = []
            var heldRenders = true, fitDuring = false
            state.onFrame = { p in
                step(p)
                // The window's drawing of this frame (the test window is
                // not on screen, so it is asked for).
                band.display()
                bottom.display()
                frames.append(p)
                if p < 1 {
                    heldRenders = heldRenders && band.renderCount == bandRenders && bottom.renderCount == bottomRenders
                    // A fit asked for mid-slide waits for the end.
                    let runs = wc.toolbarControls.fitRuns
                    wc.fitToolbar()
                    fitDuring = fitDuring || wc.toolbarControls.fitRuns != runs
                }
            }
            spin(2) { !wc.isInspectorSliding }
            let name = hide ? "hide" : "show"
            #expect(!wc.isInspectorSliding && !EditorBlurMotion.isHolding, "\(name)")
            // (How many frames come depends on the machine's load.)
            #expect(frames.count >= 2 && frames.contains { $0 > 0 && $0 < 1 }, "\(name): \(frames)")
            #expect(heldRenders, "\(name): rendered during the slide")
            #expect(!fitDuring, "\(name): fitted during the slide")
            // The last frame renders each bar once.
            #expect(frames.last == 1 && band.renderCount == bandRenders + 1 && bottom.renderCount == bottomRenders + 1, "\(name)")
        }
    }

    // MARK: Row 107: narrowing the window

    /// The programmatic resize to 1100 × 880 (F.6) relays the content out
    /// in one call; the call's own work is timed (`R4_PROFILE=1`).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["R4_PROFILE"] != nil))
    func profileNarrowing() throws {
        let (wc, _) = try longWindow("narrow")
        defer { wc.window?.orderOut(nil) }
        let w = try #require(wc.window)
        for i in 0..<(ProcessInfo.processInfo.environment["R4_SAMPLE"] != nil ? 300 : 4) {
            let wide = i % 2 == 1
            let t0 = CACurrentMediaTime()
            w.setFrame(NSRect(x: 40, y: 40, width: wide ? 1400 : 1100, height: 880), display: true)
            let t1 = CACurrentMediaTime()
            print("R4PROFILE resize to \(wide ? 1400 : 1100): \(Int((t1 - t0) * 1000)) ms, fits \(wc.toolbarControls.fitRuns)")
        }
    }

    // MARK: Row 109: image selection

    @Test func largeImageSwitchesAtOnceThenDrawsWhenDecoded() async throws {
        let (wc, dir) = try longWindow("image")
        defer { wc.window?.orderOut(nil) }
        // Over the pixel limit: decoded off the main thread.
        let big = dir.appendingPathComponent("GlassScroll/Big.png")
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2100, pixelsHigh: 2000, bitsPerSample: 8, samplesPerPixel: 3,
                                                hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try #require(rep.representation(using: .png, properties: [:])).write(to: big)
        #expect(!ImageViewerLayout.decodesQuickly(big))
        #expect(ImageViewerLayout.decodesQuickly(dir.appendingPathComponent("GlassScroll/Stripes.png")))
        wc.open(path: big.path, line: nil)
        // In the same pass: the image editor, empty, with its button; the
        // jump bar names the file; the inspector reads "--".
        let viewer = try #require(wc.imageViewer)
        #expect(wc.editor.auxiliaryFile?.path == big.path && wc.editor.jumpBarTitles.contains("Big"))
        #expect(!viewer.isReady && viewer.imageView.isHidden && viewer.loadingLabel.isHidden && !viewer.previewButton.isHidden)
        #expect(wc.inspector.imageProperties == nil)
        await viewer.loaded()
        #expect(viewer.isReady && !viewer.imageView.isHidden && viewer.loadingLabel.isHidden)
        #expect(wc.inspector.imageProperties?.pixelWidth == 2100)
    }

    // MARK: Row 110: the bottom bars

    @Test func breakpointsToggleIsAFilledAccentTag() throws {
        let (wc, _) = try longWindow("tag")
        defer { wc.window?.orderOut(nil) }
        let b = try #require(wc.debugArea.breakpointsToggle)
        #expect(wc.session.breakpoints.isActive)
        #expect(b.image?.size == NSSize(width: 17.5, height: 11.5) && b.image?.isTemplate == true)
        #expect(b.contentTintColor == .controlAccentColor && b.state == .on)
        // Its ink: filled (the middle of the tag is inked), pointed at the right.
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 35, pixelsHigh: 23, bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = BreakpointsToggleGlyph.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        BreakpointsToggleGlyph.image(active: true).draw(in: NSRect(origin: .zero, size: BreakpointsToggleGlyph.size))
        NSGraphicsContext.restoreGraphicsState()
        func alpha(_ x: Int, _ y: Int) -> CGFloat { rep.colorAt(x: x, y: y)?.alphaComponent ?? 0 }
        #expect(alpha(17, 11) > 0.9 && alpha(2, 11) > 0.9, "filled")
        #expect(alpha(33, 2) < 0.1 && alpha(33, 20) < 0.1 && alpha(30, 11) > 0.5, "pointed at the right")
        // At x 304–321.5 with the editor at 290 (F.9).
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        let inEditor = wc.editorArea.view.convert(b.bounds, from: b)
        #expect(abs(inEditor.minX - 14) <= 1 && abs(inEditor.width - 17.5) <= 0.5, "\(inEditor)")
        wc.toggleBreakpointsActive(nil)
        #expect(b.contentTintColor == .secondaryLabelColor && b.state == .off)
        wc.toggleBreakpointsActive(nil)
        #expect(b.contentTintColor == .controlAccentColor)
    }

    @Test func navigatorBottomBarSizesAndGlyphColour() throws {
        guard #available(macOS 26, *) else { return }
        let nav = NavigatorInspectorR45Tests().laidOutNavigator()
        nav.view.setFrameSize(NSSize(width: 290, height: 880))
        nav.view.layoutSubtreeIfNeeded()
        let plus = nav.plusGlass.frame, filter = nav.filterGlass.frame
        // F.9 in window points from the top: the circle x 7–35, y 844–872;
        // the capsule x 42.5–282.5, y 844–872.
        #expect(abs(plus.minX - 7) <= 0.5 && abs(plus.maxX - 35) <= 0.5 && abs(880 - plus.maxY - 844) <= 0.5 && abs(880 - plus.minY - 872) <= 0.5, "\(plus)")
        #expect(abs(filter.minX - 42.5) <= 0.5 && abs(filter.maxX - 282.5) <= 0.5 && filter.height == 28, "\(filter)")
        var dark = "", light = ""
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { dark = EditorTheme.hex(NavigatorBarColors.optionsGlyph) }
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { light = EditorTheme.hex(NavigatorBarColors.optionsGlyph) }
        #expect(dark.uppercased() == "#ABABAC", "\(dark)")
        #expect(nav.filterOptions.contentTintColor === NavigatorBarColors.optionsGlyph)
        _ = light
    }

    // MARK: Row 111: empty states

    @Test func emptyInspectorAndJumpBar() throws {
        let (wc, _) = try longWindow("empty")
        defer { wc.window?.orderOut(nil) }
        #expect(InspectorAreaController.placeholderFontSize == 17)
        wc.inspector.show(file: nil)
        #expect(wc.inspector.centeredText == "Not Applicable")
        wc.navigator.select(1)
        wc.sourceControl.setMode(.repositories)
        #expect(wc.navigator.showsRepositoriesView && wc.inspector.centeredText == "No Selection")
        wc.sourceControl.setMode(.changes)
        #expect(wc.inspector.centeredText == "Not Applicable")
        wc.sourceControl.setMode(.repositories)
        wc.navigator.select(0)
        #expect(wc.inspector.centeredText == "Not Applicable")
        // The empty jump bar: grid button, a divider, "No Selection" in the
        // bar's text colour from 47.5 in.
        let bar = wc.editor.jumpBar
        bar.setPath([])
        bar.layoutSubtreeIfNeeded()
        let views = bar.stack.arrangedSubviews
        let label = try #require(views.last as? NSTextField)
        #expect(label.stringValue == "No Selection" && label.textColor == bar.pathTextColor)
        #expect(views.count >= 3 && (views[views.count - 2] as? NSBox)?.boxType == .separator)
        let textStart = bar.convert(label.frame, from: label.superview).minX + 2
        #expect(abs(textStart - JumpBar.emptyTextStart) <= 1.5, "No Selection starts at \(textStart)")
    }

    // MARK: Row 112: the Welcome window

    @Test func welcomeSitsEightLowerAndShowsThePlainPath() throws {
        _ = NSApplication.shared
        let td = TestDefaults("r4-welcome")
        defer { td.remove() }
        let w = WelcomeWindowController(recents: RecentProjects(defaults: td.defaults))
        let frame = try #require(w.window?.frame)
        let probe = NSWindow(contentRect: try #require(w.window?.contentRect(forFrameRect: frame)), styleMask: try #require(w.window?.styleMask),
                             backing: .buffered, defer: true)
        probe.center()
        #expect(abs(probe.frame.minY - frame.minY - 8) <= 0.5 && abs(probe.frame.minX - frame.minX) <= 0.5, "\(frame) against \(probe.frame)")
        #expect(RecentProjects.folderText(URL(fileURLWithPath: "/private/tmp/council/project/App.xcodeproj")) == "/private/tmp/council/project")
        #expect(RecentProjects.folderText(URL(fileURLWithPath: "/Volumes/example/Samples/App.xcodeproj")) == "example/Samples")
    }

    // MARK: Row 114: the Changes | Repositories control

    @Test func changesRepositoriesControlIsSixteenTall() throws {
        let (wc, _) = try longWindow("scm-control")
        defer { wc.window?.orderOut(nil) }
        wc.navigator.select(1)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        let c = wc.navigator.sourceControlMode
        #expect(c.frame.height == 16 && c.font?.pointSize == 10, "\(c.frame)")
        // "Changes" was 49.5 wide in ink at 11 points; at 10 it is 45.
        func width(_ size: CGFloat) -> CGFloat { ("Changes" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size)]).width }
        #expect(abs(49.5 * width(10) / width(11) - 45) <= 1)
    }

    // MARK: Row 113: each group's expanded state comes back with the workspace

    /// The council project with a plain group "Plain" (Zeta.swift, Sub with
    /// Inner.swift, alpha.swift, Beta.swift; `navigators.md` round 2).
    func plainProject(_ tag: String) throws -> URL {
        let dir = try FidelityCouncilTests().project("r4-\(tag)")
        let plain = dir.appendingPathComponent("Plain")
        try FileManager.default.createDirectory(at: plain.appendingPathComponent("Sub"), withIntermediateDirectories: true)
        for f in ["Zeta.swift", "Sub/Inner.swift", "alpha.swift", "Beta.swift"] {
            try "// \(f)\n".write(to: plain.appendingPathComponent(f), atomically: true, encoding: .utf8)
        }
        var pbx = FidelityCouncilTests.pbxproj
        let files = """
        \t\t1A0000000000000000000001 /* Zeta.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Zeta.swift; sourceTree = "<group>"; };
        \t\t1A0000000000000000000002 /* Inner.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Inner.swift; sourceTree = "<group>"; };
        \t\t1A0000000000000000000003 /* alpha.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = alpha.swift; sourceTree = "<group>"; };
        \t\t1A0000000000000000000004 /* Beta.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Beta.swift; sourceTree = "<group>"; };
        \t\t1B0000000000000000000001 /* Plain */ = {isa = PBXGroup; children = (1A0000000000000000000001, 1B0000000000000000000002, 1A0000000000000000000003, 1A0000000000000000000004, ); path = Plain; sourceTree = "<group>"; };
        \t\t1B0000000000000000000002 /* Sub */ = {isa = PBXGroup; children = (1A0000000000000000000002, ); path = Sub; sourceTree = "<group>"; };

        """
        pbx = pbx.replacingOccurrences(of: "\tobjects = {\n", with: "\tobjects = {\n" + files)
        pbx = pbx.replacingOccurrences(of: "children = (0D0000000000000000000010 /* GlassScroll */, ", with: "children = (0D0000000000000000000010 /* GlassScroll */, 1B0000000000000000000001 /* Plain */, ")
        try pbx.write(to: dir.appendingPathComponent("GlassScroll.xcodeproj/project.pbxproj"), atomically: true, encoding: .utf8)
        return dir
    }

    func stateWindow(_ dir: URL, state: URL) throws -> WorkspaceWindowController {
        let model = try WorkspaceModel(url: dir.appendingPathComponent("GlassScroll.xcodeproj"))
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: model), loadDestinations: false, startLanguageService: false, userStateURL: state)
        wc.applyDefaultLayout()
        wc.window?.orderBack(nil)
        return wc
    }

    func titles(_ nav: NavigatorAreaController) -> [String] {
        (0..<nav.outlineView.numberOfRows).compactMap { (nav.outlineView.item(atRow: $0) as? OutlineItem)?.title }
    }

    @Test func groupExpansionComesBackWithTheWorkspace() throws {
        let dir = try plainProject("expansion")
        let state = dir.appendingPathComponent("ui-state.json")
        let first = try stateWindow(dir, state: state)
        let nav = first.navigator
        let plain = try #require((0..<nav.outlineView.numberOfRows).compactMap { nav.outlineView.item(atRow: $0) as? OutlineItem }.first { $0.title == "Plain" })
        #expect(!nav.outlineView.isItemExpanded(plain))
        nav.outlineView.expandItem(plain)
        first.open(path: dir.appendingPathComponent("GlassScroll/Long.swift").path, line: nil)
        // Other navigators and back, then the window closes.
        nav.select(1)
        nav.select(0)
        let before = titles(nav)
        #expect(before.contains("Zeta") && before.contains("Beta"), "\(before)")
        first.close()
        let second = try stateWindow(dir, state: state)
        defer { second.close() }
        let after = titles(second.navigator)
        #expect(after == before, "after \(after), before \(before)")
    }
}
