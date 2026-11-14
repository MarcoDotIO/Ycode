import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

/// Council round 10, group A, on the macOS IDE (`specs/ide/fidelity-council.md`
/// rows 236–247): the determinate build ring and the title icon's place,
/// the assistant button's hover and 1x glyph, the merge sheet's path, the
/// Welcome window's place, Open Quickly's type, the glyphs on the pixel
/// grid, the dark navigator and the jump bar's leading items. Windows stay
/// off every display and none is ordered in. With `YCODE_B10_SHOTS=<dir>`
/// the tests save pictures.
@MainActor
@Suite(.serialized) struct CouncilRound10ChromeUITests {
    let r5 = CouncilRound5ChromeTests()

    static func shot(_ w: NSWindow?, _ name: String) {
        guard let w, let dir = ProcessInfo.processInfo.environment["YCODE_B10_SHOTS"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        UISpacingProbeTests.shot(w, URL(fileURLWithPath: dir).appendingPathComponent(name))
    }

    /// A view drawn alone into an sRGB bitmap at `scale` pixels per point,
    /// whole points from its origin (its window's colour space set to
    /// sRGB, so colours read back as drawn).
    static func bitmap(_ v: NSView, scale: CGFloat = 1, dark: Bool = false) -> NSBitmapImageRep? {
        v.window?.colorSpace = .sRGB
        let rect = NSRect(x: v.bounds.minX, y: v.bounds.minY, width: ceil(v.bounds.width), height: ceil(v.bounds.height))
        guard let base = v.bitmapImageRepForCachingDisplay(in: rect),
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(rect.width * scale), pixelsHigh: Int(rect.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: base.colorSpaceName, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = rect.size
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance { v.cacheDisplay(in: rect, to: rep) }
        return rep
    }

    /// Saves a view's own picture.
    static func viewShot(_ v: NSView, _ name: String, scale: CGFloat = 2, dark: Bool = false) {
        guard let dir = ProcessInfo.processInfo.environment["YCODE_B10_SHOTS"], let rep = bitmap(v, scale: scale, dark: dark) else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }

    static func hex(_ c: NSColor?) -> UInt32 {
        guard let c = c?.usingColorSpace(.sRGB) else { return 0xFFFF_FFFF }
        return UInt32((c.redComponent * 255).rounded()) << 16 | UInt32((c.greenComponent * 255).rounded()) << 8 | UInt32((c.blueComponent * 255).rounded())
    }

    static func distance(_ a: UInt32, _ b: UInt32) -> Int {
        [16, 8, 0].map { abs(Int(a >> UInt32($0) & 0xFF) - Int(b >> UInt32($0) & 0xFF)) }.max() ?? 0
    }

    static func alpha(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> CGFloat {
        guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh else { return 0 }
        return rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
    }

    /// The ink of a bitmap: its box, and how many pixels hold any ink and
    /// full ink.
    static func ink(_ rep: NSBitmapImageRep, threshold: CGFloat = 0.1) -> (minX: Int, minY: Int, maxX: Int, maxY: Int, count: Int, full: Int) {
        var b = (minX: Int.max, minY: Int.max, maxX: -1, maxY: -1, count: 0, full: 0)
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let a = alpha(rep, x, y)
                guard a > threshold else { continue }
                b.count += 1
                if a > 0.95 { b.full += 1 }
                b.minX = min(b.minX, x); b.maxX = max(b.maxX, x); b.minY = min(b.minY, y); b.maxY = max(b.maxY, y)
            }
        }
        return b
    }

    /// A host window for a view, off every display, never ordered in.
    static func host(_ v: NSView, size: NSSize, dark: Bool) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: size.width, height: size.height), styleMask: [.borderless],
                         backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        w.contentView = root
        v.frame.origin = NSPoint(x: ((size.width - v.frame.width) / 2).rounded(), y: ((size.height - v.frame.height) / 2).rounded())
        root.addSubview(v)
        return w
    }

    /// A path icon's neighbourhood in its bar at 1x, the bar's background
    /// left out (only the icon's own ink keeps alpha).
    static func inkRegion(of icon: JumpBarIconView, in bar: JumpBar) -> NSBitmapImageRep? {
        icon.window?.colorSpace = .sRGB
        let f = bar.convert(icon.frame, from: icon.superview).insetBy(dx: -2, dy: -2)
        // Drawn alone through the bar's coordinates: the icon's view over
        // the region, its drawing outside its bounds included.
        let holder = NSView(frame: NSRect(origin: .zero, size: NSSize(width: ceil(f.width) + 1, height: ceil(f.height) + 1)))
        let copy = JumpBarIconView(glyph: icon.image ?? NSImage(), symbol: icon.symbol, role: icon.role)
        copy.glyphIcon = icon.glyphIcon
        copy.tint = icon.tint
        let local = bar.convert(icon.frame, from: icon.superview)
        copy.frame = NSRect(x: local.minX - f.minX.rounded(.down), y: local.minY - f.minY.rounded(.down), width: local.width, height: local.height)
        holder.addSubview(copy)
        let w = Self.host(holder, size: holder.frame.size, dark: false)
        defer { w.orderOut(nil) }
        w.colorSpace = .sRGB
        return bitmap(holder, scale: 1)
    }

    // MARK: Rows 236–237: the determinate ring at a fixed centre

    @Test func buildRingFillsToTheCount() throws {
        let (wc, _) = try r5.longWindow("r10-ring")
        defer { wc.window?.orderOut(nil) }
        wc.window?.colorSpace = .sRGB
        let a = wc.activityView
        let ring = a.spinner
        var clock = 100.0
        ring.now = { clock }
        a.layoutSubtreeIfNeeded()
        let restY = a.icon.frame.midY
        a.status = "Build"
        a.isBusy = true
        a.layoutSubtreeIfNeeded()
        ring.layoutSubtreeIfNeeded()
        // 15° from the top before the first count, the ring where the mark was.
        #expect(abs(ring.arc.strokeEnd - CGFloat(BuildRingProgress.startFraction)) < 0.001)
        #expect(abs(ring.frame.midY - restY) < 0.01 && ring.arc.lineCap == .round)
        clock = 101
        a.status = WorkspaceSession.BuildActivityText.progress(done: 36, total: 55)
        a.layoutSubtreeIfNeeded()
        #expect(abs(ring.arc.strokeEnd - 36.0 / 55) < 0.001)
        let fill = try #require(ring.arc.animation(forKey: "fill") as? CABasicAnimation)
        #expect(fill.duration == 0.25 && abs((fill.fromValue as? Double ?? -1) - BuildRingProgress.startFraction) < 0.001)
        // Row 237: the subtitle moves the title, not the ring.
        #expect(abs(ring.frame.midY - restY) < 0.01)
        // Never backwards.
        clock = 102
        a.status = WorkspaceSession.BuildActivityText.progress(done: 10, total: 55)
        #expect(abs(ring.arc.strokeEnd - 36.0 / 55) < 0.001)
        // Drawn: 19 × 19 of ink, the arc blue at 3 o'clock, the track at 9.
        ring.arc.removeAllAnimations()
        let rep = try #require(Self.bitmap(ring, scale: 2))
        let ink = Self.ink(rep, threshold: 0.3)
        let w = Double(ink.maxX - ink.minX + 1) / 2, h = Double(ink.maxY - ink.minY + 1) / 2
        print("R10A 236 ring ink \(w) × \(h)")
        #expect(abs(w - 19) <= 0.5 && abs(h - 19) <= 0.5)
        let cx = Double(ink.minX + ink.maxX + 1) / 2, cy = Double(ink.minY + ink.maxY + 1) / 2
        let r = (19.0 - 2.5) / 2 * 2
        func colour(_ x: Double, _ y: Double) -> UInt32 { Self.hex(rep.colorAt(x: Int(x), y: Int(y))) }
        let east = colour(cx + r, cy), west = colour(cx - r, cy), south = colour(cx, cy + r)
        print("R10A 236 east \(String(east, radix: 16)) south \(String(south, radix: 16)) west \(String(west, radix: 16))")
        #expect(Self.distance(east, 0x007AFF) <= 2 && Self.distance(south, 0x007AFF) <= 2 && Self.distance(west, 0xE6E6E6) <= 2)
        Self.shot(wc.window, "mac-r10-236-ring-window.png")
        Self.viewShot(a, "mac-r10-236-237-title-ring.png")
        a.isBusy = false
        a.status = ""
        Self.viewShot(a, "mac-r10-237-title-mark.png")
    }

    // MARK: Row 238: the assistant button's hover

    @Test(arguments: [false, true]) func assistantHoverHoweverThePointerArrives(dark: Bool) throws {
        let button = AssistantToolbarButton()
        button.frame = NSRect(x: 0, y: 0, width: 36, height: 36)
        var pointer: NSPoint?
        button.pointerLocation = { pointer }
        let w = Self.host(button, size: NSSize(width: 60, height: 60), dark: dark)
        defer { w.orderOut(nil) }
        let inside = button.convert(NSPoint(x: 18, y: 18), to: nil), outside = NSPoint(x: 2, y: 2)
        // The tracking area takes moves too, in any window state.
        button.updateTrackingAreas()
        let options = try #require(button.trackingAreas.first { $0.owner === button }?.options)
        #expect(options.contains(.mouseMoved) && options.contains(.activeAlways) && options.contains(.mouseEnteredAndExited))
        // A posted mouse-moved event.
        let move = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: inside, modifierFlags: [], timestamp: 0,
                                                   windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        button.mouseMoved(with: move)
        #expect(button.isHovered)
        button.pointerMoved(toWindowPoint: outside)
        #expect(!button.isHovered)
        // Already inside when the window becomes key or the areas are rebuilt.
        pointer = inside
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: w)
        #expect(button.isHovered)
        pointer = outside
        button.updateTrackingAreas()
        #expect(!button.isHovered)
        pointer = inside
        button.removeFromSuperview()
        w.contentView?.addSubview(button)
        #expect(button.isHovered)
        // Drawn: light #FBFBFB → #F2F2F2 (an overlay), dark unchanged.
        #expect(abs(button.overlayOpacity - AssistantButtonGlyph.hoverOverlayOpacity(dark: dark)) < 0.001)
        Self.viewShot(button, "mac-r10-238-hover-\(dark ? "dark" : "light").png", dark: dark)
    }

    // MARK: Row 239: the assistant glyph at 1x

    @Test(arguments: [false, true]) func assistantGlyphOnWholePixels(dark: Bool) throws {
        typealias G = AssistantButtonGlyph
        let button = AssistantToolbarButton()
        button.frame = NSRect(x: 0, y: 0, width: 36, height: 36)
        let w = Self.host(button, size: NSSize(width: 36, height: 36), dark: dark)
        defer { w.orderOut(nil) }
        button.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let rep = try #require(Self.bitmap(button, scale: 1, dark: dark))
        let ink = Self.ink(rep, threshold: 0.25)
        print("R10A 239 1x ink x \(ink.minX)–\(ink.maxX) y \(ink.minY)–\(ink.maxY) (\(dark ? "dark" : "light"))")
        // 18 × 18 with the tail, from (9, 9) in the 36-point circle.
        #expect(ink.minX == 9 && ink.maxX == 26 && ink.minY == 9 && ink.maxY == 26)
        // The left, right and top sides each one full pixel column or row.
        func fullRun(column x: Int) -> Int { (9...27).filter { Self.alpha(rep, x, $0) > 0.95 }.count }
        func fullRun(row y: Int) -> Int { (9...27).filter { Self.alpha(rep, $0, y) > 0.95 }.count }
        #expect(fullRun(column: 9) >= 8 && fullRun(column: 26) >= 8 && fullRun(row: 9) >= 10,
                "\(fullRun(column: 9)) \(fullRun(column: 26)) \(fullRun(row: 9))")
        #expect((9...27).allSatisfy { Self.alpha(rep, 8, $0) < 0.15 && Self.alpha(rep, 27, $0) < 0.15 })
        // The plus inside the body, not touching the outline, in its linear colours.
        let plus = (x: 9 + Int(G.plusCenter.x), y: 9 + Int(G.plusCenter.y))
        let top = Self.hex(rep.colorAt(x: plus.x, y: 9 + 4)), bottom = Self.hex(rep.colorAt(x: plus.x, y: 9 + 9))
        print("R10A 239 plus top \(String(top, radix: 16)) bottom \(String(bottom, radix: 16))")
        #expect(Self.distance(top, 0xF06F60) <= 24 && Self.distance(bottom, 0xC88BA0) <= 24)
        #expect(Self.alpha(rep, plus.x, 9 + 1) < 0.3 && Self.alpha(rep, plus.x, 9 + 12) < 0.3)
        // The right side's sector median (light, both scales) near #F375C3.
        if !dark {
            for scale in [1.0, 2.0] {
                let r = try #require(Self.bitmap(button, scale: scale))
                var reds: [Int] = [], greens: [Int] = [], blues: [Int] = []
                for y in 0..<r.pixelsHigh {
                    for x in 0..<r.pixelsWide {
                        guard Self.alpha(r, x, y) > 0.95 else { continue }
                        let gx = Double(x) / scale - 9 + 0.5 / scale, gy = Double(y) / scale - 9 + 0.5 / scale
                        // The outline only, between 60° and 120° clockwise from the top.
                        guard gx > 15, case let a = G.degrees(atX: gx, y: gy), a > 60, a < 120 else { continue }
                        let c = Self.hex(r.colorAt(x: x, y: y))
                        reds.append(Int(c >> 16)); greens.append(Int(c >> 8 & 0xFF)); blues.append(Int(c & 0xFF))
                    }
                }
                func median(_ v: [Int]) -> Int { v.sorted()[v.count / 2] }
                try #require(!reds.isEmpty)
                let m = UInt32(median(reds)) << 16 | UInt32(median(greens)) << 8 | UInt32(median(blues))
                print("R10A 239 right sector median at \(scale)x: #\(String(m, radix: 16)) of \(reds.count)")
                #expect(Self.distance(m, 0xF375C3) <= 12)
            }
        }
        Self.viewShot(button, "mac-r10-239-glyph-1x-\(dark ? "dark" : "light").png", scale: 1, dark: dark)
        Self.viewShot(button, "mac-r10-239-glyph-4x-\(dark ? "dark" : "light").png", scale: 4, dark: dark)
    }

    // MARK: Row 241: the Welcome window's place

    @Test func welcomeOnTheScreen() throws {
        _ = NSApplication.shared
        let td = TestDefaults("r10-welcome")
        defer { td.remove() }
        let w = WelcomeWindowController(recents: RecentProjects(defaults: td.defaults))
        let visible = NSRect(x: 0, y: 0, width: 1512, height: 949)
        w.visibleFrameOverride = visible
        w.placeOnScreen()
        let f = try #require(w.window?.frame)
        let o = WelcomePlacement.origin(width: Double(f.width), height: Double(f.height), visible: (0, 0, 1512, 949))
        #expect(f.minX == CGFloat(o.x) && f.minY == CGFloat(o.y))
        #expect(abs(f.midX - visible.midX) <= 0.5)
        let above = visible.maxY - f.maxY, below = f.minY - visible.minY
        print("R10A 241 Welcome \(f.size) above \(above) below \(below)")
        #expect(abs(above / (above + below) - 0.28) < 0.01)
        #expect(w.window?.isVisible != true)
    }

    // MARK: Row 242: Open Quickly's type and chevron

    @Test func openQuicklyRowType() throws {
        let file = FuzzyMatch.Candidate(title: "Long.swift", detail: "GlassScroll", path: "/tmp/GlassScroll/Long.swift", line: nil, kind: .file,
                                        symbolKind: nil, groupPath: ["GlassScroll", "GlassScroll"])
        let oq = OpenQuicklyController(candidates: [file])
        let w = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 640, height: 130), styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = oq.view
        oq.onResize = { h in w.setContentSize(NSSize(width: 640, height: h)) }
        defer { w.orderOut(nil) }
        oq.search("long")
        oq.view.layoutSubtreeIfNeeded()
        oq.table.layoutSubtreeIfNeeded()
        let cell = try #require(oq.rowCells.first)
        cell.layoutSubtreeIfNeeded()
        typealias L = OpenQuicklyLayout
        let font = try #require(cell.name.font)
        #expect(font.pointSize == 17 && font.fontDescriptor.symbolicTraits.contains(.bold))
        let nameBaseline = cell.name.frame.minY + cell.name.firstBaselineOffsetFromTop
        print("R10A 242 name baseline \(nameBaseline), cap top \(nameBaseline - font.capHeight)")
        #expect(abs(nameBaseline - 23) <= 0.5)
        #expect(cell.breadcrumb.groups == ["GlassScroll", "GlassScroll"] && cell.detail.alphaValue == 0)
        let (xs, chevrons) = cell.breadcrumb.layout
        let groupWidth = xs[1] - chevrons[0] - L.breadcrumbChevronWidth - L.breadcrumbChevronGap
        print("R10A 242 breadcrumb groups at \(xs), chevron at \(chevrons), gap \(groupWidth)")
        #expect(chevrons.count == 1 && abs(groupWidth) < 0.01)
        let gw = ("GlassScroll" as NSString).size(withAttributes: [.font: OpenQuicklyBreadcrumbView.font]).width
        print("R10A 242 \"GlassScroll\" at 15 points: \(gw) wide")
        #expect(abs(gw - 73) <= 4)
        // The chevron drawn: 3 wide, 14 tall at 1x.
        let rep = try #require(Self.bitmap(cell.breadcrumb, scale: 1))
        let cx = Int(chevrons[0])
        var rows = Set<Int>(), cols = Set<Int>()
        for y in 0..<rep.pixelsHigh {
            for x in max(0, cx - 1)...(cx + 4) where Self.alpha(rep, x, y) > 0.25 { rows.insert(y); cols.insert(x) }
        }
        print("R10A 242 chevron ink \(cols.count) × \(rows.count), rows \(rows.min() ?? -1)–\(rows.max() ?? -1)")
        #expect(abs(rows.count - 14) <= 1 && cols.count <= 4)
        // The project's mark 12 × 12, 4 before the path.
        #expect(cell.projectGlyph.frame.size == NSSize(width: 12, height: 12))
        #expect(abs(cell.breadcrumb.frame.minX - cell.projectGlyph.frame.maxX - 4) < 0.01)
        Self.viewShot(cell, "mac-r10-242-open-quickly-row.png")
    }

    // MARK: Rows 243–245: navigator glyphs at 1x, the dark background

    func navigatorWindow(_ tag: String) throws -> (WorkspaceWindowController, NSOutlineView) {
        let (wc, _) = try r5.longWindow("r10-\(tag)")
        let tree = CouncilRound9GlyphUITests.tree()
        tree.children[0].children.append(NavigatorNode(name: "photo.png", kind: .file, path: "/tmp/r9/GlassScroll/photo.png"))
        wc.navigator.setProjectTree(tree)
        let o = wc.navigator.outlineView
        o.expandItem(nil, expandChildren: true)
        o.layoutSubtreeIfNeeded()
        return (wc, o)
    }

    func iconView(_ o: NSOutlineView, _ name: String) throws -> NavigatorFlatIconView {
        let r = try #require((0..<o.numberOfRows).first { r in
            (o.item(atRow: r) as? OutlineItem).flatMap { $0.nodePath }.map { ($0 as NSString).lastPathComponent == name } == true
        })
        let cell = try #require(o.view(atColumn: 0, row: r, makeIfNecessary: true) as? NavigatorCellView)
        return try #require(cell.imageView as? NavigatorFlatIconView)
    }

    @Test(arguments: [false, true]) func pictureAndPythonOnWholePixels(dark: Bool) throws {
        let (wc, o) = try navigatorWindow("glyphs-\(dark)")
        defer { wc.window?.orderOut(nil) }
        wc.window?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        // Row 243: Ycode's picture, 14 × 12, its sides whole columns at full colour.
        let picture = try iconView(o, "photo.png")
        #expect(picture.glyph == .image && picture.image?.size == NSSize(width: 14, height: 12))
        let rep = try #require(Self.bitmap(picture, scale: 1, dark: dark))
        let ink = Self.ink(rep, threshold: 0.25)
        print("R10A 243 picture ink \(ink.maxX - ink.minX + 1) × \(ink.maxY - ink.minY + 1), full \(ink.full) (\(dark ? "dark" : "light"))")
        #expect(ink.maxX - ink.minX + 1 == 14 && ink.maxY - ink.minY + 1 == 12)
        let left = (ink.minY...ink.maxY).filter { Self.alpha(rep, ink.minX, $0) > 0.95 }.count
        let right = (ink.minY...ink.maxY).filter { Self.alpha(rep, ink.maxX, $0) > 0.95 }.count
        #expect(left >= 8 && right >= 8, "\(left) \(right)")
        // Its tint at full coverage.
        let full = (ink.minY...ink.maxY).first { Self.alpha(rep, ink.minX, $0) > 0.99 }.map { Self.hex(rep.colorAt(x: ink.minX, y: $0)) }
        #expect(full.map { Self.distance($0, dark ? 0x2DA7FF : 0x006BEF) <= 3 } == true, "\(String(full ?? 0, radix: 16))")
        // Row 244: Python at 1x, about 80 ink pixels with at least 10 full.
        let python = try iconView(o, "convert.py")
        let p = try #require(Self.bitmap(python, scale: 1, dark: dark))
        let pink = Self.ink(p, threshold: 0.1)
        print("R10A 244 python 1x ink \(pink.maxX - pink.minX + 1) × \(pink.maxY - pink.minY + 1): \(pink.count) pixels, \(pink.full) full")
        #expect(pink.full >= 10 && pink.count <= 100)
        if dark {
            let fullColour = (0..<p.pixelsHigh).flatMap { y in (0..<p.pixelsWide).map { (x: $0, y: y) } }
                .first { Self.alpha(p, $0.x, $0.y) > 0.99 }.map { Self.hex(p.colorAt(x: $0.x, y: $0.y)) }
            #expect(fullColour.map { Self.distance($0, 0xFFF62A) <= 3 } == true)
        }
        Self.viewShot(picture, "mac-r10-243-picture-\(dark ? "dark" : "light")-1x.png", scale: 1, dark: dark)
        Self.viewShot(picture, "mac-r10-243-picture-\(dark ? "dark" : "light")-8x.png", scale: 8, dark: dark)
        Self.viewShot(python, "mac-r10-244-python-\(dark ? "dark" : "light")-8x.png", scale: 8, dark: dark)
    }

    @Test func darkNavigatorBackground() throws {
        let (wc, _) = try navigatorWindow("dark-fill")
        defer { wc.window?.orderOut(nil) }
        let fill = try #require(wc.navigator.darkFill)
        wc.window?.appearance = NSAppearance(named: .darkAqua)
        #expect(Self.hex(fill.fillColor) == 0x28282A)
        let rep = try #require(Self.bitmap(fill, scale: 1, dark: true))
        let c = Self.hex(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2))
        print("R10A 245 navigator dark fill #\(String(c, radix: 16))")
        #expect(Self.distance(c, 0x28282A) <= 1)
        wc.window?.appearance = NSAppearance(named: .aqua)
        #expect(fill.fillColor == nil)
        // Under everything else in the navigator.
        #expect(fill.superview?.subviews.first === fill)
    }

    // MARK: Rows 246–247: the jump bar

    @Test func jumpBarLeadingItemsAndChevrons() throws {
        let (wc, _) = try r5.longWindow("r10-jump")
        defer { wc.window?.orderOut(nil) }
        let bar = wc.editor.jumpBar
        bar.layoutSubtreeIfNeeded()
        let grid = try #require(bar.relatedItemsButton as? JumpBarGridButton)
        let gf = bar.convert(grid.frame, from: grid.superview)
        let divider = try #require(bar.pathDivider)
        let df = bar.convert(divider.frame, from: divider.superview)
        let first = try #require(bar.pathInk.first)
        print("R10A 247 grid \(gf.minX)–\(gf.maxX), divider \(df.minX) (\(df.width) × \(df.height)), path from \(first.minX)")
        #expect(abs(gf.minX - 13) < 0.01 && gf.width == 13 && gf.height == 13)
        #expect(abs(df.minX - 35) < 0.01 && df.width == 1 && df.height == 12)
        #expect(abs(first.minX - 49) <= 0.5)
        // The grid's four squares on whole pixels at 1x.
        let g = try #require(Self.bitmap(grid, scale: 1))
        let gi = Self.ink(g, threshold: 0.25)
        #expect(gi.maxX - gi.minX + 1 == 13 && gi.maxY - gi.minY + 1 == 13 && gi.full >= 30, "\(gi)")
        // The divider's colour.
        let d = try #require(Self.bitmap(divider, scale: 1))
        #expect(Self.hex(d.colorAt(x: 0, y: 6)) == 0xE6E6E6)
        // Chevrons 3 × 10.
        let chevron = try #require(bar.stack.arrangedSubviews.first { $0 is JumpBarChevronView })
        let c = try #require(Self.bitmap(chevron, scale: 2))
        let ci = Self.ink(c, threshold: 0.3)
        let cw = Double(ci.maxX - ci.minX + 1) / 2, ch = Double(ci.maxY - ci.minY + 1) / 2
        print("R10A 247 chevron ink \(cw) × \(ch)")
        #expect(abs(cw - 3) <= 0.5 && abs(ch - 10) <= 0.5)
        Self.viewShot(bar, "mac-r10-247-jump-bar.png")
        Self.viewShot(bar, "mac-r10-247-jump-bar-dark.png", dark: true)
    }

    @Test func jumpBarMarkdownAndJSONGlyphs() throws {
        let (wc, dir) = try r5.longWindow("r10-jump-glyphs")
        defer { wc.window?.orderOut(nil) }
        let notes = dir.appendingPathComponent("GlassScroll/NOTES.md")
        try "# Notes\n".write(to: notes, atomically: true, encoding: .utf8)
        wc.open(path: notes.path, line: nil)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        let md = try #require(wc.editor.jumpBar.pathState.parts.last?.icon)
        #expect(md.glyphIcon == .markdown && abs(md.inkWidth - 13) < 0.01)
        // At 1x the outer sides and the spine each one full column (drawn
        // by the bar, where the glyph's ink may pass its slot).
        let bar = wc.editor.jumpBar
        bar.layoutSubtreeIfNeeded()
        let rep = try #require(Self.inkRegion(of: md, in: bar))
        let ink = Self.ink(rep, threshold: 0.25)
        let fullColumns = (ink.minX...ink.maxX).filter { x in (ink.minY...ink.maxY).filter { Self.alpha(rep, x, $0) > 0.95 }.count >= 5 }
        print("R10A 246 markdown ink \(ink.maxX - ink.minX + 1) × \(ink.maxY - ink.minY + 1), full columns \(fullColumns.map { $0 - ink.minX })")
        #expect(ink.maxX - ink.minX + 1 == 13 && fullColumns.map { $0 - ink.minX } == [0, 6, 12])
        Self.viewShot(wc.editor.jumpBar, "mac-r10-246-jump-bar-markdown.png")
        let json = dir.appendingPathComponent("GlassScroll/palette.json")
        try "{}\n".write(to: json, atomically: true, encoding: .utf8)
        wc.open(path: json.path, line: nil)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        let j = try #require(wc.editor.jumpBar.pathState.parts.last?.icon)
        #expect(j.glyphIcon == .json && abs(j.inkWidth - 14) < 0.01)
        let jbar = wc.editor.jumpBar
        jbar.layoutSubtreeIfNeeded()
        let jr = try #require(Self.inkRegion(of: j, in: jbar))
        let ji = Self.ink(jr, threshold: 0.25)
        let red = (0..<jr.pixelsHigh).flatMap { y in (0..<jr.pixelsWide).map { (x: $0, y: y) } }
            .first { Self.alpha(jr, $0.x, $0.y) > 0.99 }.map { Self.hex(jr.colorAt(x: $0.x, y: $0.y)) }
        print("R10A 246 json ink \(ji.maxX - ji.minX + 1) × \(ji.maxY - ji.minY + 1), full \(ji.full), red #\(String(red ?? 0, radix: 16))")
        #expect(ji.maxX - ji.minX + 1 == 14 && ji.maxY - ji.minY + 1 == 10 && red.map { Self.distance($0, 0xFF383C) <= 1 } == true)
        Self.viewShot(wc.editor.jumpBar, "mac-r10-246-jump-bar-json.png")
    }

    // MARK: Row 240: the merge sheet's path

    @Test func mergeSheetPathShowsYcodesMark() async throws {
        let repo = try MergeSheetUITests.Repo("r10-path")
        defer { repo.cleanUp() }
        let wc = try await repo.window()
        defer { wc.window?.orderOut(nil) }
        let sheet = try await MergeSheetUITests().openSheet(wc)
        let bar = sheet.jumpBar
        bar.layoutSubtreeIfNeeded()
        let rep = try #require(Self.bitmap(bar, scale: 1))
        // The project's slot from x 82, 13 wide, centred on the bar's 36.
        var purple = 0, accent = 0
        for y in 11..<25 {
            for x in 82..<95 {
                let c = Self.hex(rep.colorAt(x: x, y: y))
                let (r, g, b) = (Int(c >> 16), Int(c >> 8 & 0xFF), Int(c & 0xFF))
                if r < 0x60, b < 0x70, r > g, b > g { purple += 1 }
                if Self.distance(c, 0x007AFF) <= 30 || Self.distance(c, 0x0A84FF) <= 30 { accent += 1 }
            }
        }
        print("R10A 240 merge path project slot: \(purple) field pixels, \(accent) accent pixels")
        #expect(purple >= 40 && accent == 0)
        Self.viewShot(bar, "mac-r10-240-merge-path.png")
        Self.shot(wc.window, "mac-r10-240-merge-window.png")
        sheet.cancel(nil)
    }
}
