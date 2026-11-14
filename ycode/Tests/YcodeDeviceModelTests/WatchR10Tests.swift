// Council round 10, group B (specs/ide/fidelity-council.md "Round 10", rows
// 249–252; watchos.md §11.3; device-hub.md §4.2–§4.4, §15.2): the shared
// rules both IDEs draw the watch with. The case at its real size (the 46 mm
// Series 12's 46 × 39 mm: the screen plus 21 device points at the sides and
// 23.5 at the top and bottom), the crown 13 out; the case's soft rim, band
// and fade to black; the crown's and side button's shapes and places; the
// capsule's Digital Crown first, in Ycode's own press glyphs.

import Foundation
import Testing
@testable import YcodeDeviceModel

@Suite struct WatchR10Tests {
    // MARK: Row 249

    @Test func theCaseIsItsRealSize() throws {
        let g = DeviceFrameGeometry(spec: .appleWatchSeries12_46mm)
        #expect(g.body.size == CGSize(width: 250, height: 295))
        #expect(g.screen.minX - g.body.minX == 21 && g.screen.minY - g.body.minY == 23.5)
        #expect(g.screen.midX == g.body.midX && g.screen.midY == g.body.midY)
        // 163 device points an inch: 39 × 46 mm.
        let mm = (w: Double(g.body.width) / 163 * 25.4, h: Double(g.body.height) / 163 * 25.4)
        #expect(abs(mm.w - 39) < 0.3 && abs(mm.h - 46) < 0.3, "\(mm)")
        // The crown 13 out (about 2.1 mm).
        let crown = try #require(g.buttons.first { $0.kind == .crown }).rect
        #expect(crown.maxX - g.body.maxX == 13 && g.outerBox.size == CGSize(width: 263, height: 295))
        // Physical Size on the round's display (109 points per inch): 167 × 197, 176 with the crown.
        let p = DeviceZoom.physical(panel: DeviceFrameSpec.appleWatchSeries12_46mm.panels[0], displayPointsPerInch: 109)
        #expect(abs(250 * p - 167.2) < 0.2 && abs(295 * p - 197.3) < 0.2 && abs(263 * p - 175.9) < 0.2)
        // Zoom to Fit keeps the body 731 tall at 1400 × 900 and 639 at 1100 × 800 (row 231's share).
        for (area, ref) in [(WatchHubR9Tests.area1400, 731.0), (WatchHubR9Tests.area1100, 639.0)] {
            let s = DeviceZoom.hubFit(geometry: g, foldable: false, in: area)
            #expect(abs(295 * s - ref) <= 1.5, "\(area): \(295 * s)")
            // Height-bound; the whole drawing inside the area.
            #expect(Double(g.size.width) * s <= Double(area.width) && Double(g.size.height) * s <= Double(area.height))
            print(String(format: "R10B row 249 fit %.0f: body %.1f × %.1f, crown %.1f out", Double(area.width), 250 * s, 295 * s, 13 * s))
        }
        // Every watch: the same border round its own screen; the bare screen without the bezel.
        for spec in DeviceFrameSpec.watches {
            let w = DeviceFrameGeometry(spec: spec)
            #expect(w.body.width == w.screen.width + 42 && w.body.height == w.screen.height + 47, "\(spec.typeID)")
            #expect(w.drawsWatchCase && !DeviceFrameGeometry(spec: spec, bezels: false).drawsWatchCase)
        }
        #expect(!DeviceFrameGeometry(spec: .iPhone18Pro).drawsWatchCase && !DeviceFrameGeometry(spec: .iPadA16).drawsWatchCase)
    }

    // MARK: Row 250

    @Test func theCaseHasASoftRimABandAndAFadeToBlack() {
        typealias D = WatchCaseDrawing
        func c(_ inset: Double) -> (r: Double, g: Double, b: Double, a: Double) { D.colour(D.caseStops, at: inset) }
        func grey(_ inset: Double) -> Double { c(inset).r * 255 }
        // The glow rises from nothing at the outer edge to the core.
        #expect(c(0).a == 0 && c(1.4).a > 0.3 && c(1.4).a < 0.7 && c(2.8).a == 1)
        // The core about 1.6 wide, centred about 3.6 in, #5B–#5E.
        #expect((0x5B...0x5E).contains(Int(grey(3.6).rounded())) && grey(2.8) == grey(4.4))
        // Down within about 0.8 to the flat #1F1F1F band, about 4.4 wide.
        #expect(Int(grey(5.2).rounded()) == 0x1F && Int(grey(9.6).rounded()) == 0x1F && Int(grey(7.4).rounded()) == 0x1F)
        // The fade to black over about 2.8; black from about 12.4 (13 device points: about 32 pt at Zoom to Fit) to the screen.
        #expect(grey(11) > 0 && grey(11) < 0x1F && grey(12.4) == 0 && grey(30) == 0 && c(30).a == 1)
        let total = D.caseStops.last!.inset
        #expect(total >= 12 && total <= 13.5)
        // Grey throughout (the same in light and dark).
        for inset in stride(from: 0.0, through: 14, by: 0.2) { #expect(c(inset).r == c(inset).g && c(inset).g == c(inset).b) }
        // Nested fills compound to the profile's opacity.
        let targets = [0.1, 0.3, 0.6, 1, 1]
        let alphas = D.nestedAlphas(targets)
        var shown: [Double] = []
        var below = 0.0
        for a in alphas { below = a + below * (1 - a); shown.append(below) }
        for (s, t) in zip(shown, targets) { #expect(abs(s - t) < 1e-9) }
        // Outlines of one shape pair up point by point at any inset, even where a corner runs out.
        let r = CGRect(x: 0, y: 0, width: 10, height: 40), radii = CornerRadii(topLeft: 0, topRight: 3.2, bottomRight: 3.2, bottomLeft: 0)
        #expect(D.outline(r, radii: radii, inset: 0).count == D.outline(r, radii: radii, inset: 4).count)
    }

    // MARK: Row 251

    @Test func theCrownAndTheSideButton() throws {
        let g = DeviceFrameGeometry(spec: .appleWatchSeries12_46mm)
        #expect(g.buttons.map(\.kind) == [.crown, .sideButton])
        let H = Double(g.body.height), top = Double(g.body.minY)
        let crown = try #require(g.buttons.first { $0.kind == .crown })
        let side = try #require(g.buttons.first { $0.kind == .sideButton })
        // The crown: 13 out, at 22.5–38.5 % of the body (about 47 tall), its outer corners 8, its inner end under the body.
        #expect(abs((Double(crown.rect.minY) - top) / H - 0.225) < 1e-9 && abs((Double(crown.rect.maxY) - top) / H - 0.385) < 1e-9)
        #expect(abs(Double(crown.rect.height) - 47.2) < 0.1 && crown.rect.minX < g.body.maxX - 2.8)
        #expect(crown.radii == CornerRadii(topLeft: 0, topRight: 8, bottomRight: 8, bottomLeft: 0))
        // The side button: 4 out, at 52.5–73.5 %, about 62 tall, a pill.
        #expect(side.rect.maxX - g.body.maxX == 4)
        #expect(abs((Double(side.rect.minY) - top) / H - 0.525) < 1e-9 && abs((Double(side.rect.maxY) - top) / H - 0.735) < 1e-9)
        let pill = try #require(side.radii)
        #expect(pill.topRight >= 3 && pill.bottomRight >= 3)
        // Rim-outlined, dark inside (#11–#18).
        let inside = WatchCaseDrawing.colour(WatchCaseDrawing.buttonStops, at: 3)
        #expect((0x11...0x18).contains(Int((inside.r * 255).rounded())) && inside.a == 1)
        #expect(Int((WatchCaseDrawing.colour(WatchCaseDrawing.buttonStops, at: 1.1).r * 255).rounded()) == 0x5C)
        // Ridges 3 apart on the crown's outer third only, clear of its rounded corners.
        let ridges = WatchCaseDrawing.ridges(crown: crown.rect)
        #expect(ridges.count == 9)
        for (a, b) in zip(ridges, ridges.dropFirst()) { #expect(abs(b.from.y - a.from.y - 3) < 1e-9) }
        for r in ridges {
            #expect(r.from.x >= crown.rect.maxX - 5.6 && r.to.x <= crown.rect.maxX && r.from.y == r.to.y)
            #expect(r.from.y >= crown.rect.minY + 8 && r.from.y <= crown.rect.maxY - 8)
        }
        // An Ultra's Action button: a pill 4 out of the left edge.
        let ultra = DeviceFrameGeometry(spec: try #require(DeviceFrameSpec.named(typeID: "apple-watch-ultra-4-49mm")))
        let action = try #require(ultra.buttons.first { $0.kind == .action })
        #expect(ultra.body.minX - action.rect.minX == 4 && action.radii != nil)
    }

    // MARK: Row 252

    @Test func theCapsuleHasTheCrownFirstInItsOwnPressGlyphs() throws {
        #expect(DeviceControlsLayout.watchGroup == [.digitalCrown, .sideButton, .screenshot, .recordScreen])
        #expect(DeviceControlsLayout.groups(.init(spec: .appleWatchSeries12_46mm)) == [DeviceControlsLayout.watchGroup])
        for g in [DeviceControlGlyphs.digitalCrown, DeviceControlGlyphs.sideButton] {
            #expect(g.size.width == 17 && g.size.height == 15)
            let ink = DeviceControlGlyphs.inkBox(g)
            #expect(abs(ink.maxX - ink.minX - 17) < 0.3 && abs(ink.maxY - ink.minY - 15) < 0.3, "\(ink)")
            #expect(abs(ink.minX + ink.maxX) < 0.3 && abs(ink.minY + ink.maxY) < 0.3, "centred: \(ink)")
            // An arrow pointing left, level with the part's middle: its tip the head's left-most point.
            guard case .polygon(let head) = try #require(g.solids.last) else {
                Issue.record("an arrowhead expected")
                continue
            }
            let tip = try #require(head.min { $0.x < $1.x })
            #expect(tip.y == 0 && head.allSatisfy { $0.x >= tip.x })
        }
        // The crown: a short upright cylinder with upright ridges, the arrow's tip just right of it.
        let crown = DeviceControlGlyphs.digitalCrown
        guard case .roundedRect(let cx, _, let cw, let ch, _) = try #require(crown.strokes.first),
              case .polygon(let head) = try #require(crown.solids.last) else { Issue.record("shapes expected"); return }
        #expect(ch > cw && cw < 8)
        let ridges = crown.solids.dropLast()
        #expect(ridges.count == 2)
        for r in ridges {
            guard case .roundedRect(let x, _, let w, let h, _) = r else { Issue.record("a ridge"); continue }
            #expect(h > 3 * w && x > cx && x + w < cx + cw)
        }
        let tip = head.map(\.x).min()!
        #expect(tip > cx + cw && tip - (cx + cw) < 2.5)
        // The side button: the case's right edge as a bracket (an arc bulging right), the arrow pointing into its middle.
        let side = DeviceControlGlyphs.sideButton
        guard case .arc(let c, let r, let from, let to) = try #require(side.strokes.first),
              case .polygon(let sideHead) = try #require(side.solids.last) else { Issue.record("shapes expected"); return }
        #expect(from < 0 && to > 0 && abs(from + to) < 1e-9 && c.y == 0)
        let rightMost = c.x + r
        let sideTip = sideHead.map(\.x).min()!
        #expect(sideTip > rightMost && sideTip - rightMost < 2.5)
        // Tall and narrow: much taller than it is deep.
        #expect(2 * r * sin(to) > 3 * (r - r * cos(to)))
    }
}
