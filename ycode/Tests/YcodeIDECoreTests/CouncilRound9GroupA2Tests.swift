import Foundation
import Testing
@testable import YcodeIDECore

/// Council round 9, group A2, in the models both IDEs share
/// (`specs/ide/fidelity-council.md` rows 214–219): the assistant button's
/// glyph, gradient and hover; Open Quickly's layout, breadcrumb and
/// colours; the jump bar's collapse to initials with the issue stepper's
/// room; the active chevron; the overflow gap; the merge sheet's dark
/// segment.
@Suite struct CouncilRound9GroupA2Tests {
    typealias G = AssistantButtonGlyph
    typealias L = JumpBarPathLayout

    // MARK: Row 214: the assistant button

    /// 18 × 18 with the tail at the lower left (round 10, row 239), in a
    /// 36-point circle; the plus 8 across through its own centre.
    @Test func assistantGlyphGeometry() {
        #expect(G.diameter == 36 && G.width == 18 && G.height == 18 && G.plusSpan == 8)
        var xs: [Double] = [], ys: [Double] = []
        for e in G.bubble {
            switch e {
            case let .move(x, y), let .line(x, y), let .quad(x, y, _, _), let .curve(x, y, _, _, _, _): xs.append(x); ys.append(y)
            case .close: break
            }
        }
        let h = G.bubbleStroke / 2
        // The outline with its stroke fills the box's width; the tail's
        // point is inside its 18 points of height.
        #expect(abs((xs.min() ?? 0) - h) < 0.01 && abs((xs.max() ?? 0) + h - 18) < 0.01)
        #expect(abs((ys.min() ?? 0) - h) < 0.01 && (ys.max() ?? 0) + h <= 18)
        // The lowest point (the tail's tip) is in the left third.
        let tip = zip(xs, ys).max { $0.1 < $1.1 }
        #expect((tip?.0 ?? 99) < 6, "\(String(describing: tip))")
        if case let .move(x0, y0) = G.plus[0], case let .line(x1, y1) = G.plus[1] {
            #expect(x1 - x0 + G.plusStroke == 8 && y0 == y1 && abs((x0 + x1) / 2 - G.plusCenter.x) < 0.01)
        } else {
            Issue.record("plus")
        }
    }

    static func hex(_ c: (r: Double, g: Double, b: Double)) -> UInt32 {
        UInt32((c.r * 255).rounded()) << 16 | UInt32((c.g * 255).rounded()) << 8 | UInt32((c.b * 255).rounded())
    }

    /// The angular gradient runs clockwise from the top through the
    /// measured stops, in both appearances, and wraps at 360°.
    @Test func assistantGradientStops() {
        let light: [(Double, UInt32)] = [(0, 0xFD6848), (45, 0xFC5168), (90, 0xF27CCA), (135, 0xBE99EF), (180, 0x80AADC), (225, 0x6FB1D6),
                                         (270, 0xE5956F), (315, 0xFD8039), (360, 0xFD6848)]
        let dark: [(Double, UInt32)] = [(0, 0xFD6043), (45, 0xFB4A53), (90, 0xF070BB), (135, 0xBE96EE), (180, 0x78A5D7), (225, 0x6AAED1),
                                        (270, 0xDF8F5E), (315, 0xF97533)]
        for (a, v) in light { #expect(Self.hex(G.color(atDegrees: a, dark: false)) == v, "\(a)") }
        for (a, v) in dark { #expect(Self.hex(G.color(atDegrees: a, dark: true)) == v, "\(a)") }
        // Between stops: linear (22.5° is the mean of 0° and 45°).
        let mid = G.color(atDegrees: 22.5, dark: false)
        #expect(abs(mid.r * 255 - (0xFD + 0xFC) / 2.0) < 0.6 && abs(mid.g * 255 - (0x68 + 0x51) / 2.0) < 0.6)
        #expect(Self.hex(G.color(atDegrees: -45, dark: false)) == 0xFD8039)
        // Angles: the top is 0°, the right 90°, the bottom 180°, the left 270° (y down).
        let (cx, cy) = G.center
        #expect(abs(G.degrees(atX: cx, y: cy - 5) - 0) < 0.01 && abs(G.degrees(atX: cx + 5, y: cy) - 90) < 0.01)
        #expect(abs(G.degrees(atX: cx, y: cy + 5) - 180) < 0.01 && abs(G.degrees(atX: cx - 5, y: cy) - 270) < 0.01)
    }

    /// The capsule at rest #FBFBFB / #454545; hovered #F2F2F2 in light, no
    /// change in dark; the overlay that makes #F2F2F2 from #FBFBFB.
    @Test func assistantHover() {
        #expect(G.capsule(dark: false, hovered: false) == 0xFBFBFB && G.capsule(dark: false, hovered: true) == 0xF2F2F2)
        #expect(G.capsule(dark: true, hovered: false) == 0x454545 && G.capsule(dark: true, hovered: true) == 0x454545)
        let o = G.hoverOverlayOpacity(dark: false)
        #expect(abs(Double(0xFB) * (1 - o) - Double(0xF2)) < 0.01 && G.hoverOverlayOpacity(dark: true) == 0)
        #expect(G.pressedOverlayOpacity(dark: false) > o)
    }

    // MARK: Row 215: Open Quickly

    typealias Q = OpenQuicklyLayout

    /// 640 wide, top 200; the field's band 54; rows 620 × 56, 10 in and 10
    /// below the separator; 130 tall for one result; the name level with
    /// the query (66 and 66.5 from the panel's left); the glyph 13 into
    /// the row (x 403 in a panel at 380).
    @Test func openQuicklyGeometry() {
        #expect(Q.width == 640 && Q.top == 200 && Q.headerHeight == 54 && Q.separatorInset == 20)
        #expect(Q.rowWidth == 620 && Q.rowHeight == 56 && Q.rowCornerRadius == 22 && Q.rowsTop == 64)
        #expect(Q.height(results: 1) == 130 && Q.height(results: 0) == 54)
        #expect(Q.height(results: 30) == Q.height(results: Q.maximumVisibleRows))
        #expect(Q.rowInset + Q.nameX == 66 && Q.queryX == 66.5)
        #expect(380 + Q.rowInset + Q.glyphX == 403 && Q.glyphSize.width == 24.5 && Q.glyphSize.height == 20.5)
        #expect(Q.magnifierSize == 21 && Q.magnifierX == 21.5 && Q.queryFontSize == 22)
        #expect(Q.cornerRadius == 32)
    }

    @Test func openQuicklyColoursAndText() {
        #expect(Q.selection(dark: false) == 0x0064E1 && Q.selection(dark: true) == 0x0059D1)
        #expect(Q.separator(dark: false) == 0xE4E4E4 && Q.separator(dark: true) == 0x525252)
        #expect(Q.magnifier(dark: false) == 0x7D7D7D && Q.query(dark: false) == 0x262626)
        // White at 0.75 on #0064E1 is the reference's #BFD8F8.
        let o = Q.selectedExtensionOpacity
        func over(_ bg: Double) -> Int { Int((bg + (255 - bg) * o).rounded()) }
        #expect(over(0x00) == 0xBF && abs(over(0x64) - 0xD8) <= 1 && abs(over(0xE1) - 0xF8) <= 1)
        #expect(Q.splitExtension("Long.swift") == ("Long", ".swift") && Q.splitExtension("Makefile") == ("Makefile", ""))
        #expect(Q.splitExtension(".gitignore") == (".gitignore", ""))
        #expect(Q.breadcrumb(["GlassScroll", "GlassScroll"]) == "GlassScroll \u{203A} GlassScroll")
    }

    /// The candidates carry the project's name and the groups above each file.
    @Test func openQuicklyGroupPaths() {
        let file = NavigatorNode(name: "Long.swift", kind: .file, path: "/p/GlassScroll/Long.swift")
        let deep = NavigatorNode(name: "Model01.swift", kind: .file, path: "/p/GlassScroll/Models/Model01.swift")
        let models = NavigatorNode(name: "Models", kind: .folder, path: "/p/GlassScroll/Models", children: [deep])
        let group = NavigatorNode(name: "GlassScroll", kind: .folder, path: "/p/GlassScroll", children: [file, models])
        let root = NavigatorNode(name: "GlassScroll.xcodeproj", kind: .container, path: "/p/GlassScroll.xcodeproj", children: [group])
        let c = FuzzyMatch.candidates(in: root).filter { $0.kind == .file }
        #expect(c.first { $0.title == "Long.swift" }?.groupPath == ["GlassScroll", "GlassScroll"])
        #expect(c.first { $0.title == "Model01.swift" }?.groupPath == ["GlassScroll", "GlassScroll", "Models"])
    }

    // MARK: Row 216: the jump bar's collapse

    /// The round 7 widths (I.5): the project 13 + "GlassScroll" 57, the
    /// group 12.5 + 57, the file 12.5 + "Long" 24.5; "No Selection" 65.5;
    /// initials "G" 6.5 and "L" 5.5.
    static let long = [L.Part(icon: 13, title: 57, initial: 6.5), L.Part(icon: 12.5, title: 57, initial: 6.5),
                       L.Part(icon: 12.5, title: 24.5, initial: 5.5)]
    static let deep = [L.Part(icon: 13, title: 57, initial: 6.5), L.Part(icon: 12.5, title: 57, initial: 6.5),
                       L.Part(icon: 12.5, title: 41, initial: 6.0), L.Part(icon: 12.5, title: 43, initial: 8.5)]
    /// The issue stepper's room (G.8: 40 wide, its end 14.5 inside the
    /// pane, the path 10.5 before it, against the 23 without it).
    static let stepperRoom = 40 + 14.5 + L.stepperGap - L.trailingInset

    /// 1250 with the stepper (round 9, X07): the group's icon alone, the
    /// project "G" with its fade, "Long" and "No Selection" whole.
    @Test func at1250TheProjectIsAnInitial() {
        let f = L.fit(parts: Self.long, last: 65.5, room: 255 - Self.stepperRoom)
        let project = f.titles[0] ?? 0
        #expect(f.titles[1] == nil && f.titles[2] == 24.5 && f.last == 65.5, "\(f)")
        // "Gl" at most, fading (the reference's "G": its room is a few points
        // less than this estimate of the stepper's).
        #expect(project >= 6.5 + L.initialFade - 0.01 && project < 16, "\(f)")
    }

    /// 1250, deep path (X08): the project and groups icons only, the file
    /// "M" with its fade, "No Selection" whole.
    @Test func at1250TheDeepFileIsAnInitial() {
        let f = L.fit(parts: Self.deep, last: 65.5, room: 254 - Self.stepperRoom)
        let file = f.titles[3] ?? 0
        #expect(f.titles[0] == nil && f.titles[1] == nil && f.titles[2] == nil && f.last == 65.5, "\(f)")
        #expect(file >= 8.5 + L.initialFade - 0.01 && file < 16, "\(f)")
    }

    /// 1180 (X09): the left pane's file its icon alone once its initial
    /// does not fit (the reference's room, a few points under this
    /// estimate), "No Selection" whole; the right (deep) pane's "No
    /// Selection" cut, never gone.
    @Test func at1180TheLastItemIsCutLast() {
        let left = L.fit(parts: Self.long, last: 65.5, room: 220 - Self.stepperRoom - 4)
        #expect(left.titles.allSatisfy { $0 == nil } && left.last == 65.5, "\(left)")
        let right = L.fit(parts: Self.deep, last: 65.5, room: 220 - Self.stepperRoom)
        #expect(right.titles.allSatisfy { $0 == nil }, "\(right)")
        #expect(right.last.map { $0 < 65.5 && $0 >= L.minimumCut } == true, "\(right)")
    }

    /// A title is cut down to its initial and a little fade, then goes; with
    /// no initial known, round 7's 9 points; never below a one-letter title.
    @Test func cutsStopAtTheInitial() {
        #expect(L.Part(icon: 13, title: 57, initial: 8.5).minimumCut == 11)
        #expect(L.Part(icon: 13, title: 57).minimumCut == L.minimumCut)
        #expect(L.Part(icon: 13, title: 6, initial: 6).minimumCut == 6)
        // Without the stepper the round 7 states hold (the 1100 file cut too).
        let x07 = L.fit(parts: Self.long, last: 65.5, room: 255)
        #expect(x07.titles[0] == 57 && x07.titles[1] == nil, "\(x07)")
        let at1100 = L.fit(parts: Self.long, last: 65.5, room: 179)
        #expect(at1100.titles[0] == nil && at1100.titles[1] == nil && at1100.last == 65.5 && (at1100.titles[2] ?? 0) >= 8, "\(at1100)")
    }

    // MARK: Row 217: the chevron before "No Selection"

    @Test func activeChevronColourAndGap() {
        #expect(L.chevronColor(dark: false, active: true) == 0x808080 && L.chevronColor(dark: true, active: true) == 0xDEDEDE)
        #expect(L.chevronColor(dark: false, active: false) == nil)
        // A name, 7, the 3-wide chevron, 8.5, "No Selection".
        let after = L.chevronToTitle - (L.chevronInk(active: true) - L.chevronWidth)
        #expect(L.titleToChevron == 7 && after == 8.5)
        #expect(WorkspaceChrome.jumpBarNoSymbol == "No Selection")
    }

    // MARK: Row 218: the gap before the overflow capsule

    @Test func overflowGap() {
        #expect(WorkspaceChrome.overflowCapsuleGap == 5)
    }

    // MARK: Row 219: the merge sheet's view control in dark

    @Test func darkSegmentIsDimmedWithWhiteText() {
        #expect(MergeSheetPalette.dark.segmentPill == 0x335273 && MergeSheetPalette.dark.segmentLabel == 0xFFFFFF)
        #expect(MergeSheetPalette.light.segmentPill == 0xD1E7FF && MergeSheetPalette.light.segmentLabel == 0x007AFF)
    }
}
