import Foundation
import Testing
@testable import YcodeIDECore

/// Council round 10, group A (`specs/ide/fidelity-council.md` rows 236–247):
/// the shared models both IDEs draw from. Runs on macOS and Linux.
@Suite struct CouncilRound10ChromeTests {
    static func close(_ a: Double, _ b: Double, _ e: Double = 0.01) -> Bool { abs(a - b) <= e }

    // MARK: Row 236: the determinate ring

    @Test func ringFractionFromTheSubtitle() {
        #expect(Self.close(BuildRingProgress.fraction(activity: "Building \u{2022} 36/55") ?? -1, 36.0 / 55))
        #expect(BuildRingProgress.fraction(activity: WorkspaceSession.BuildActivityText.progress(done: 35, total: 36)) == 35.0 / 36)
        #expect(BuildRingProgress.fraction(activity: "Build") == nil)
        #expect(BuildRingProgress.fraction(activity: WorkspaceSession.BuildActivityText.planning) == nil)
        #expect(BuildRingProgress.fraction(activity: "Building \u{2022} 3/0") == nil)
        #expect(Self.close(BuildRingProgress.startFraction * 360, 15))
    }

    /// Each new count is reached by easing over 0.25 s, never backwards;
    /// before the first count the arc is 15°.
    @Test func ringEasesForwardOnly() {
        var p = BuildRingProgress(at: 10)
        #expect(Self.close(p.value(at: 10), BuildRingProgress.startFraction) && p.isSettled(at: 10))
        let moved1 = p.update(activity: "Building \u{2022} 36/55", at: 11)
        #expect(moved1)
        #expect(Self.close(p.value(at: 11), BuildRingProgress.startFraction))
        let mid = p.value(at: 11.125)
        #expect(mid > BuildRingProgress.startFraction && mid < 36.0 / 55)
        // Eased out: past halfway at half time.
        #expect(mid > (BuildRingProgress.startFraction + 36.0 / 55) / 2)
        #expect(Self.close(p.value(at: 11.25), 36.0 / 55) && p.isSettled(at: 11.25))
        var last = 0.0
        for k in 0...25 {
            let v = p.value(at: 11 + Double(k) / 100)
            #expect(v >= last - 1e-12)
            last = v
        }
        // A smaller count, or none, leaves it.
        let moved2 = p.update(activity: "Building \u{2022} 10/55", at: 12)
        #expect(!moved2)
        let moved3 = p.update(activity: "Build", at: 12)
        #expect(!moved3)
        #expect(Self.close(p.target, 36.0 / 55))
        // Mid-ease, a new count starts from where the arc is.
        let moved4 = p.update(activity: "Building \u{2022} 50/55", at: 13)
        #expect(moved4)
        let shown = p.value(at: 13.1)
        let moved5 = p.update(activity: "Building \u{2022} 55/55", at: 13.1)
        #expect(moved5)
        #expect(Self.close(p.value(at: 13.1), shown) && Self.close(p.value(at: 13.35), 1))
    }

    @Test func ringSize() {
        #expect(FileGlyphs.buildRingDiameter == 19 && FileGlyphs.buildRingStroke == 2.5)
        #expect(FileGlyphs.buildRingArc == GlyphColor(0x007AFF, 0x0A84FF) && FileGlyphs.buildRingTrack.light == 0xE6E6E6)
    }

    // MARK: Row 239: the assistant glyph

    @Test func assistantGlyphAtOneX() {
        typealias G = AssistantButtonGlyph
        #expect(G.width == 18 && G.height == 18)
        #expect(G.bubbleStroke(scale: 1) == 1 && G.bubbleStroke(scale: 2) == 1.4)
        // Left, top and right strokes centred on pixel centres of an
        // integral box (half a point in), the corner radius 2.
        var xs: [Double] = [], ys: [Double] = []
        for e in G.bubble {
            if case let .line(x, y) = e { xs.append(x); ys.append(y) }
        }
        #expect(xs.contains(0.5) && xs.contains(17.5) && ys.contains(0.5))
        #expect(G.corner == 2 && G.bodyBottom == 14)
        // The tail's point 4 in from the body's left edge, 3 below its bottom.
        #expect(G.tip.x - 0.5 == 4 && G.tip.y - G.bodyBottom == 3)
        // The plus 8 × 7 with its 1.5 stroke, centred on the body (9, 7).
        if case let .move(x0, y0) = G.plus[0], case let .line(x1, _) = G.plus[1], case let .move(_, v0) = G.plus[2], case let .line(_, v1) = G.plus[3] {
            #expect(Self.close(x1 - x0 + G.plusStroke, 8) && Self.close(v1 - v0 + G.plusStroke, 7) && y0 == 7 && (x0 + x1) / 2 == 9)
        } else {
            Issue.record("plus")
        }
        // Its own linear gradient top to bottom, round 9's stops.
        func hex(_ c: (r: Double, g: Double, b: Double)) -> UInt32 {
            UInt32((c.r * 255).rounded()) << 16 | UInt32((c.g * 255).rounded()) << 8 | UInt32((c.b * 255).rounded())
        }
        #expect(hex(G.plusColor(atY: G.plusInkY.top)) == 0xF46E5A && hex(G.plusColor(atY: G.plusInkY.bottom)) == 0xBF8EA8)
        let mid = hex(G.plusColor(atY: G.plusCenter.y))
        // About round 9's median #E3828D / #DF7C80.
        #expect(abs(Int(mid >> 16) - 0xDA) <= 12 && abs(Int(mid >> 8 & 0xFF) - 0x7E) <= 12, "\(String(mid, radix: 16))")
    }

    // MARK: Row 241: the Welcome window's place

    @Test func welcomeOnTheScreen() {
        // Rounds 4 and 9: a 1512 × 949 visible frame (a 33-point menu bar
        // above it), the 480 × 629 window at x 516, its top 89.5 below.
        let o = WelcomePlacement.origin(width: 480, height: 629, visible: (0, 0, 1512, 949))
        #expect(o.x == 516)
        let topGap = 949 - (o.y + 629)
        #expect(abs(topGap - 89.5) <= 1, "\(topGap)")
        // Round 10's display: 3440 wide, centred.
        let wide = WelcomePlacement.origin(width: 480, height: 629, visible: (0, 0, 3440, 1407))
        #expect(wide.x == 1480)
        // Never above the visible frame, never below it.
        let tall = WelcomePlacement.origin(width: 480, height: 1200, visible: (100, 50, 1512, 949))
        #expect(tall.y >= 50 && tall.y + 1200 >= 949)
        let small = WelcomePlacement.origin(width: 480, height: 629, visible: (200, 300, 1000, 700))
        #expect(small.y + 629 <= 1000 && small.x == 460)
    }

    // MARK: Row 242: Open Quickly's type

    @Test func openQuicklyTypeAndChevron() {
        typealias L = OpenQuicklyLayout
        #expect(L.nameFontSize == 17 && L.nameBaseline == 23)
        #expect(L.breadcrumbFontSize == 15 && L.breadcrumbBaseline == 44.5)
        #expect(L.breadcrumbChevronWidth == 3 && L.breadcrumbChevronHeight == 14 && L.breadcrumbChevronGap == 7)
        #expect(L.breadcrumbGlyphSize == 12 && L.breadcrumbGap == 4)
        let (groups, chevrons) = L.breadcrumbLayout(widths: [73, 73, 40])
        #expect(groups == [0, 90, 180] && chevrons == [80, 170])
        #expect(L.breadcrumb(["GlassScroll", "GlassScroll"]) == "GlassScroll \u{203A} GlassScroll")
    }

    // MARK: Rows 243–246: glyphs

    @Test func pictureGlyph() throws {
        #expect(NavigatorRowIcon.ofFile("photo.png") == .image && NavigatorRowIcon.ofFile("photo.heic") == .image)
        #expect(NavigatorRowIcon.image.isGlyph && WorkspaceChrome.iconTint(kind: .file, name: "photo.png") == .blue)
        #expect(FileGlyphs.tint(.blue) == GlyphColor(0x006BEF, 0x2DA7FF))
        #expect(FileGlyphs.navigatorBox(.image) == (14, 12))
        let d = try #require(FileGlyphs.navigatorDrawing(.image))
        let ink = d.inkBox
        #expect(Self.close(ink.minX, 0) && Self.close(ink.maxX, 14) && Self.close(ink.minY, 0) && Self.close(ink.maxY, 12))
        // The frame: a 1-point stroke on half points (whole pixel columns at 1x).
        #expect(d.paths[0].strokeWidth == 1 && !d.paths[0].fills)
        // The sun about 2 across in the upper left third, the hills filled below.
        let sun = GlyphDrawing(width: 14, height: 12, paths: [d.paths[1]]).inkBox
        #expect(sun.maxX < 14.0 / 2 && sun.maxY < 6 && Self.close(sun.maxX - sun.minX, 2.2, 0.3))
        let hills = GlyphDrawing(width: 14, height: 12, paths: [d.paths[2]]).inkBox
        #expect(hills.minY > 6 && hills.minY < 7.5 && d.paths[2].fills)
        #expect(FileGlyphs.jumpBarGlyph(symbol: "photo", role: .file, fileName: "photo.png") == .image)
    }

    @Test func jumpBarMarkdownAndJSON() throws {
        let md = FileGlyphs.jumpBarBook
        #expect(md.width == 13 && md.height == 10.5 && md.paths.allSatisfy { $0.strokeWidth == 1 })
        let ink = md.inkBox
        #expect(Self.close(ink.minX, 0) && Self.close(ink.maxX, 13) && Self.close(ink.maxY - ink.minY, 10, 0.05))
        // The spine on the middle column (x 6.5), the page tops arched.
        guard case let .move(spineX, spineTop) = md.paths[0].elements[0] else { Issue.record("book"); return }
        #expect(spineX == 6.5 && spineTop == 1.5)
        #expect(Self.close(GlyphDrawing(width: 13, height: 10.5, paths: [md.paths[0]]).inkBox.minY, 0, 0.05))
        let json = FileGlyphs.jumpBarJSON
        #expect(json.width == 14 && json.height == 10)
        let jink = json.inkBox
        #expect(Self.close(jink.minX, 0) && Self.close(jink.maxX, 14) && Self.close(jink.minY, 0) && Self.close(jink.maxY, 10))
        let left = GlyphDrawing(width: 14, height: 10, paths: [json.paths[2], json.paths[3]]).inkBox
        let right = GlyphDrawing(width: 14, height: 10, paths: [json.paths[4], json.paths[5]]).inkBox
        #expect(Self.close(left.maxX - left.minX, 3, 0.15) && Self.close(left.maxY - left.minY, 4, 0.15) && Self.close(left.minX, 4, 0.1))
        #expect(Self.close(right.minX, 8, 0.1))
        #expect(FileGlyphs.jumpBarTint(.json) == GlyphColor(0xFF383C, 0xFF4245) && FileGlyphs.tint(.json) == GlyphColor(0xEE2C22, 0xFF695E))
        #expect(FileGlyphs.jumpBarBox(.markdown) == (13, 10.5) && FileGlyphs.jumpBarBox(.json) == (14, 10))
        #expect(FileGlyphs.jumpBarDrawing(.json) == json && FileGlyphs.jumpBarDrawing(.markdown) == md)
    }

    /// The vertical and horizontal straight runs of `d` drawn at `origin`
    /// and `scale`: how many of their stroke centres fall where a stroke of
    /// their pixel width draws whole pixels.
    static func alignedRuns(_ d: GlyphDrawing, origin: (x: Double, y: Double), scale: Double) -> (aligned: Int, total: Int) {
        var aligned = 0, total = 0
        for p in d.paths where p.strokeWidth > 0 {
            let px = Int((p.strokeWidth * scale).rounded()), ideal = px % 2 == 1 ? 0.5 : 0
            var cur = (0.0, 0.0)
            for e in p.elements {
                switch e {
                case let .move(x, y): cur = (x, y)
                case let .line(x, y):
                    if abs(x - cur.0) < 0.01, abs(y - cur.1) > 1 {
                        total += 1
                        var f = ((origin.x + x) * scale - ideal).truncatingRemainder(dividingBy: 1)
                        if f < 0 { f += 1 }
                        if min(f, 1 - f) < 0.01 { aligned += 1 }
                    }
                    if abs(y - cur.1) < 0.01, abs(x - cur.0) > 1 {
                        total += 1
                        var f = ((origin.y + y) * scale - ideal).truncatingRemainder(dividingBy: 1)
                        if f < 0 { f += 1 }
                        if min(f, 1 - f) < 0.01 { aligned += 1 }
                    }
                    cur = (x, y)
                case let .curve(_, _, _, _, x, y): cur = (x, y)
                case .close: break
                }
            }
        }
        return (aligned, total)
    }

    /// Rows 243, 244, 246: wherever a glyph lands, its straight runs are
    /// moved onto whole pixels; at 1x Python's 1.5-point stroke draws one
    /// pixel, at 2x three.
    @Test func pixelAlignment() throws {
        let picture = try #require(FileGlyphs.navigatorDrawing(.image))
        for origin in [(55.75, 300.25), (56.0, 301.0), (10.3, 7.6)] {
            let a = FileGlyphs.pixelAligned(picture, origin: origin, scale: 1)
            let r = Self.alignedRuns(a, origin: origin, scale: 1)
            #expect(r.total == 4 && r.aligned == 4, "\(origin) \(r)")
            // Moved by less than half a pixel.
            #expect(abs(a.inkBox.minX - picture.inkBox.minX) <= 0.5 && abs(a.inkBox.minY - picture.inkBox.minY) <= 0.5)
        }
        let python = try #require(FileGlyphs.navigatorDrawing(.logo("python")))
        #expect(python.paths.allSatisfy { $0.strokeWidth == 1.5 })
        let p1 = FileGlyphs.pixelAligned(python, origin: (55.75, 196.75), scale: 1)
        #expect(p1.paths.allSatisfy { $0.strokeWidth == 1 })
        let r1 = Self.alignedRuns(p1, origin: (55.75, 196.75), scale: 1)
        print("R10A 244 python straight runs on whole pixels at 1x: \(r1.aligned) of \(r1.total)")
        #expect(r1.total > 0 && r1.aligned == r1.total)
        let p2 = FileGlyphs.pixelAligned(python, origin: (55.75, 196.75), scale: 2)
        #expect(p2.paths.allSatisfy { $0.strokeWidth == 1.5 })
        // The jump bar's book and JSON at a fractional place.
        for d in [FileGlyphs.jumpBarBook, FileGlyphs.jumpBarJSON] {
            let a = FileGlyphs.pixelAligned(d, origin: (528.25, 60.5), scale: 1)
            let r = Self.alignedRuns(a, origin: (528.25, 60.5), scale: 1)
            #expect(r.aligned == r.total && r.total >= 2, "\(r)")
        }
    }

    // MARK: Row 245: the dark navigator

    @Test func navigatorDarkBackground() {
        #expect(WorkspaceChrome.navigatorDarkBackground == 0x28282A)
    }

    // MARK: Row 247: the jump bar's leading items and chevrons

    @Test func jumpBarLeadingItems() {
        typealias L = JumpBarLeading
        #expect(L.gridX == 13 && L.gridSide == 13 && L.dividerX == 35 && L.dividerHeight == 12 && L.pathX == 49)
        #expect(L.gridX + L.gridSide < L.dividerX && L.dividerX + L.dividerWidth < L.pathX)
        let ink = L.grid.inkBox
        #expect(Self.close(ink.minX, 0) && Self.close(ink.maxX, 13) && Self.close(ink.minY, 0) && Self.close(ink.maxY, 13))
        #expect(L.grid.paths.count == 4 && L.grid.paths.allSatisfy { $0.strokeWidth == 1 && !$0.fills })
        // Each square 6 × 6 of ink with a point between two.
        let first = GlyphDrawing(width: 13, height: 13, paths: [L.grid.paths[0]]).inkBox
        #expect(Self.close(first.maxX - first.minX, 6) && Self.close(L.grid.paths.count == 4 ? GlyphDrawing(width: 13, height: 13, paths: [L.grid.paths[1]]).inkBox.minX : 0, 7))
        #expect(L.dividerColor(dark: false) == 0xE6E6E6 && L.dividerColor(dark: true) == 0x3C3C3C)
        typealias P = JumpBarPathLayout
        #expect(P.chevronInkHeight == 10 && P.chevronStroke == 1.25 && P.chevronInk(active: true) == 3)
        #expect(P.chevronColor(dark: false, active: true) == 0x808080 && P.chevronColor(dark: true, active: true) == 0xDEDEDE)
    }
}
