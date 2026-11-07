import Foundation
import Testing
@testable import YcodeDeviceModel

/// The second capsule's glyphs (device-hub.md §13.1, council round 5 rows
/// 131–132), shared by the macOS and Linux device windows.
struct DeviceControlGlyphsTests {
    typealias G = DeviceControlGlyphs

    /// Row 132: Rotate is a square with an arrow at two opposite corners,
    /// about 19 × 21.5: one over the top-left corner pointing right, one
    /// under the bottom-right corner pointing left.
    @Test func rotateHasTwoOppositeArrows() {
        let g = G.rotate
        let box = G.inkBox(g)
        #expect(abs((box.maxX - box.minX) - 19) <= 1 && abs((box.maxY - box.minY) - 21.5) <= 1, "\(box)")
        let heads = g.solids.compactMap { s -> [G.Point]? in if case .polygon(let p) = s { p } else { nil } }
        #expect(heads.count == 2)
        // The tips: one above the square pointing right (its tip right of
        // its base), one below pointing left.
        let top = heads.first { $0[0].y < 0 }, bottom = heads.first { $0[0].y > 0 }
        #expect((top?[0].y ?? 0) < -5.5 && (top?[0].x ?? 0) > (top.map { ($0[1].x + $0[2].x) / 2 } ?? 0))
        #expect((bottom?[0].y ?? 0) > 5.5 && (bottom?[0].x ?? 0) < (bottom.map { ($0[1].x + $0[2].x) / 2 } ?? 0))
        // The two arrows are the same shape turned half a turn.
        if let t = top, let b = bottom {
            for (p, q) in zip(t, b) { #expect(abs(p.x + q.x) < 0.001 && abs(p.y + q.y) < 0.001) }
        }
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
