import Foundation
import Testing
@testable import YcodeDeviceModel

/// The second capsule's glyphs (device-hub.md §13.1, council round 5 rows
/// 131–132), shared by the macOS and Linux device windows.
struct DeviceControlGlyphsTests {
    typealias G = DeviceControlGlyphs

    /// Rows 132 and 175: Rotate is a square with a small hooked arrow at
    /// two opposite corners, the top right and the bottom left (§15.6),
    /// about 20 × 17.5 (round 5 measured 19 × 21.5 for its own description).
    @Test func rotateHasTwoOppositeArrows() {
        let g = G.rotate
        let box = G.inkBox(g)
        #expect(abs((box.maxX - box.minX) - 20) <= 1 && abs((box.maxY - box.minY) - 17.5) <= 1, "\(box)")
        let heads = g.solids.compactMap { s -> [G.Point]? in if case .polygon(let p) = s { p } else { nil } }
        #expect(heads.count == 2)
        // The hooks: one at the top-right corner pointing down (its tip
        // below its base), one at the bottom-left pointing up.
        let tr = heads.first { $0[0].x > 0 }, bl = heads.first { $0[0].x < 0 }
        let h = G.rotateHalfSide
        #expect((tr?[0].x ?? 0) > h && (tr?[0].y ?? 0) > (tr.map { ($0[1].y + $0[2].y) / 2 } ?? 0))
        #expect((bl?[0].x ?? 0) < -h && (bl?[0].y ?? 0) < (bl.map { ($0[1].y + $0[2].y) / 2 } ?? 0))
        // The arcs are centred on those corners.
        let arcs = g.strokes.compactMap { s -> G.Point? in if case .arc(let c, _, _, _) = s { c } else { nil } }
        #expect(arcs == [G.Point(h, -h), G.Point(-h, h)])
        // The two arrows are the same shape turned half a turn.
        if let t = tr, let b = bl {
            for (p, q) in zip(t, b) { #expect(abs(p.x + q.x) < 0.001 && abs(p.y + q.y) < 0.001) }
        }
    }

    /// Row 175: Home is a 3 × 3 grid of rounded squares (not circles).
    @Test func homeIsAGridOfRoundedSquares() {
        let g = G.home
        #expect(g.solids.count == 9)
        for s in g.solids {
            guard case .roundedRect(_, _, let w, let h, let r) = s else { Issue.record("\(s)"); continue }
            #expect(w == h && r > 0 && r < w / 2)
        }
        let box = G.inkBox(g)
        #expect(abs((box.maxX - box.minX) - 12.5) <= 1 && abs((box.maxY - box.minY) - 12.5) <= 1, "\(box)")
    }

    /// Row 175: the half-open posture is a flat sheet (no spine line) whose
    /// top and bottom edges curve slightly.
    @Test func halfOpenIsAFlatSheetWithCurvedEdges() {
        let g = G.posture(.halfOpen)
        #expect(g.strokes.count == 1)
        guard case .polygon(let pts) = g.strokes[0] else { Issue.record("not a polygon"); return }
        // The top edge is lower at the middle than at the ends, smoothly.
        let top = pts.prefix(pts.count / 2)
        #expect(top.count > 4 && top.first!.y < top[top.count / 2].y && top.last!.y < top[top.count / 2].y)
    }

    /// Row 174: the toolbar's layout glyph (an outline window with a top bar
    /// and a right panel) and the compact-window arrows on the rising
    /// diagonal, pointing in.
    @Test func toolbarGlyphs() {
        let l = G.layout
        #expect(l.solids.isEmpty && l.fills.isEmpty && l.strokes.count == 3)
        if case .roundedRect = l.strokes[0] {} else { Issue.record("outline first") }
        let c = G.compactWindow
        let shafts = c.strokes.compactMap { s -> [G.Point]? in if case .polyline(let p) = s, p.count == 2 { p } else { nil } }
        #expect(shafts.count == 2)
        for s in shafts {
            // From a corner on the rising diagonal (x and y of opposite signs) toward the centre.
            #expect(s[0].x * s[0].y < 0 && hypot(s[1].x, s[1].y) < hypot(s[0].x, s[0].y))
        }
        #expect(Set(shafts.map { $0[0].x > 0 }) == [true, false])
    }

    /// Row 131: the postures' sizes and colours.
    @Test func posturesSizesAndColours() {
        let sizes = G.Posture.allCases.map { G.inkBox(G.posture($0)) }.map { ($0.maxX - $0.minX, $0.maxY - $0.minY) }
        #expect(abs(sizes[0].0 - 10.5) <= 0.5 && abs(sizes[0].1 - 13.5) <= 0.5, "closed \(sizes[0])")
        #expect(abs(sizes[1].0 - 16) <= 0.5 && abs(sizes[1].1 - 13.5) <= 0.5, "half open \(sizes[1])")
        #expect(abs(sizes[2].0 - 17) <= 0.5 && abs(sizes[2].1 - 13.5) <= 0.5, "flat \(sizes[2])")
        #expect(G.postureColours(current: true, dark: true) == (0x007AFF, 0x2D4B6D))
        #expect(G.postureColours(current: false, dark: true) == (0xFFFFFF, 0x6C6C6D))
        #expect(G.postureColours(current: true, dark: false) == (0x007AFF, 0xBFDDFE))
        #expect(G.postureColours(current: false, dark: false) == (0x000000, 0xBEBEBE))
        // Every fill is convex (the Linux window fills fans).
        for p in G.Posture.allCases {
            for case .polygon(let pts) in G.posture(p).fills {
                var sign = 0.0
                for i in pts.indices {
                    let a = pts[i], b = pts[(i + 1) % pts.count], c = pts[(i + 2) % pts.count]
                    let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
                    if abs(cross) > 1e-9 { #expect(sign == 0 || (sign > 0) == (cross > 0), "\(p) concave at \(i)"); sign = cross }
                }
            }
        }
    }

    /// Row 131: a foldable's second capsule is Rotate │ three postures, 146
    /// wide (145.5), the centres on §11.1's pitch, the divider at 434 in the
    /// 1100 × 800 window's 820.5-wide canvas.
    @Test func foldableCapsuleLayout() {
        let groups = DeviceControlsLayout.groups(.init(foldable: true))
        #expect(groups.count == 2 && groups[1] == [.rotateLeft, .poseClosed, .posePartiallyOpen, .poseOpen])
        #expect(DeviceControlsLayout.width(of: groups[1]) == 145.5)
        let rects = DeviceControlsLayout.capsuleRects(groups, canvasWidth: 820.5, canvasHeight: 800)
        let x = Double(rects[1].minX)
        let centres = DeviceControlsLayout.glyphCentres(of: groups[1]).map { x + $0 }
        #expect(abs(centres[0] - 415.5) <= 1 && abs(centres[1] - 452.75) <= 1 && abs(centres[3] - 520.5) <= 1, "\(centres)")
        #expect(abs(x + (DeviceControlsLayout.dividerCentre(of: groups[1]) ?? 0) - 434) <= 1)
        // A name lookup finds the foldable for a simctl device type.
        #expect(DeviceFrameSpec.named(name: "iPhone Duo")?.isFoldable == true && DeviceFrameSpec.named(name: "iphone duo") != nil)
    }
}
