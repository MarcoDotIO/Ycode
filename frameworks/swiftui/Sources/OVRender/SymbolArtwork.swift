// Ycode's own symbol set for `Image(systemName:)` (09-open-design.md §3.6).
// Apple's SF Symbols may not be shipped or copied, so these are original,
// deliberately plain drawings made for Ycode: geometric outlines on a 24 × 24
// grid (stroke width 2, round caps and joins; `.fill` variants filled). The
// names are the common system names, used as interop identifiers so that
// existing code finds a picture. Licence: the repository's (MIT), no
// third-party artwork.
//
// Each symbol also has a box: its size in points at the body text size
// (17 pt), from which layout derives every other size. Where the spec
// measured the reference's box (07 §3, golden-layout.md) that size is used
// so that layout matches; elsewhere the box is the default 20.67 × 20.67.

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// One symbol: drawing operations on the 24 × 24 grid and layout metrics.
public struct SymbolArtwork: Sendable {
    public enum Operation: Sendable {
        case fill(RenderPath, evenOdd: Bool)
        case stroke(RenderPath, width: Double)
        /// Cuts a stroke (or, with no width, an area) out of everything
        /// drawn by the other operations.
        case knockout(RenderPath, width: Double?)
    }

    public let name: String
    public let operations: [Operation]
    /// Size in points at 17 pt, image scale medium.
    public let bodySize: CGSize
    /// Distance from the bottom up to the text baseline at 17 pt.
    public let bodyBaselineOffset: Double

    /// The drawing fitted into `rect` (uniformly scaled, centred), as
    /// display-list contents painted with `paint`.
    public func contents(in rect: CGRect, paint: RenderPaint) -> [DisplayItem.Content] {
        let scale = min(rect.width / 24, rect.height / 24)
        let t = RenderTransform(a: scale, b: 0, c: 0, d: scale, tx: rect.midX - 12 * scale, ty: rect.midY - 12 * scale)
        func stroke(_ w: Double) -> RenderStroke { RenderStroke(lineWidth: w * scale, lineCap: .round, lineJoin: .round) }
        var drawn: [DisplayItem.Content] = []
        var cuts: [RenderClip] = []
        for op in operations {
            switch op {
            case let .fill(p, eo): drawn.append(.fill(p.applying(t), paint, eo ? .evenOdd : .nonZero))
            case let .stroke(p, w): drawn.append(.stroke(p.applying(t), paint, stroke(w)))
            case let .knockout(p, w): cuts.append(RenderClip(path: p.applying(t), inverse: true, stroke: w.map(stroke)))
            }
        }
        guard !cuts.isEmpty else { return drawn }
        let id = DisplayItemID.root.child(name)
        let kids = drawn.enumerated().map { DisplayItem(id: id.child(UInt64($0.offset)), $0.element) }
        return [.group(DisplayGroup(clips: cuts, children: kids))]
    }

    /// A visible stand-in for names the set lacks: a rounded square with a
    /// question mark.
    public static func placeholder(name: String) -> SymbolArtwork {
        var q = RenderPath()
        q.move(to: P(9.5, 9.5))
        q.cubic(to: P(12, 7), control1: P(9.5, 8), control2: P(10.6, 7))
        q.cubic(to: P(14.5, 9.5), control1: P(13.4, 7), control2: P(14.5, 8))
        q.cubic(to: P(12, 13), control1: P(14.5, 11.3), control2: P(12, 11.5))
        q.line(to: P(12, 14))
        return SymbolArtwork(name: name, operations: [
            .stroke(Shapes.roundedRect(3, 3, 18, 18, 3), width: 1.5),
            .stroke(q, width: 1.5),
            .fill(Shapes.circle(12, 17, 1.1), evenOdd: false),
        ], bodySize: CGSize(width: 62.0 / 3, height: 62.0 / 3), bodyBaselineOffset: 11.0 / 3)
    }
}

private func P(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }

/// Path helpers on the 24 × 24 grid.
enum Shapes {
    static func circle(_ cx: Double, _ cy: Double, _ r: Double) -> RenderPath {
        let k = 0.552_284_75 * r
        var p = RenderPath()
        p.move(to: P(cx + r, cy))
        p.cubic(to: P(cx, cy + r), control1: P(cx + r, cy + k), control2: P(cx + k, cy + r))
        p.cubic(to: P(cx - r, cy), control1: P(cx - k, cy + r), control2: P(cx - r, cy + k))
        p.cubic(to: P(cx, cy - r), control1: P(cx - r, cy - k), control2: P(cx - k, cy - r))
        p.cubic(to: P(cx + r, cy), control1: P(cx + k, cy - r), control2: P(cx + r, cy - k))
        p.close()
        return p
    }

    static func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> RenderPath {
        RenderPath(rect: CGRect(x: x, y: y, width: w, height: h))
    }

    static func roundedRect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double) -> RenderPath {
        let k = 0.447_715_25 * r
        var p = RenderPath()
        p.move(to: P(x + r, y))
        p.line(to: P(x + w - r, y))
        p.cubic(to: P(x + w, y + r), control1: P(x + w - k, y), control2: P(x + w, y + k))
        p.line(to: P(x + w, y + h - r))
        p.cubic(to: P(x + w - r, y + h), control1: P(x + w, y + h - k), control2: P(x + w - k, y + h))
        p.line(to: P(x + r, y + h))
        p.cubic(to: P(x, y + h - r), control1: P(x + k, y + h), control2: P(x, y + h - k))
        p.line(to: P(x, y + r))
        p.cubic(to: P(x + r, y), control1: P(x, y + k), control2: P(x + k, y))
        p.close()
        return p
    }

    static func poly(_ pts: [(Double, Double)], closed: Bool = false) -> RenderPath {
        var p = RenderPath()
        for (i, q) in pts.enumerated() {
            if i == 0 { p.move(to: P(q.0, q.1)) } else { p.line(to: P(q.0, q.1)) }
        }
        if closed { p.close() }
        return p
    }

    static func join(_ paths: [RenderPath]) -> RenderPath { RenderPath(paths.flatMap(\.elements)) }

    /// A five-pointed star centred at (12, 12.4).
    static func star() -> RenderPath {
        var pts: [(Double, Double)] = []
        for i in 0..<10 {
            let r = i % 2 == 0 ? 10.0 : 4.3
            let a = -Double.pi / 2 + Double(i) * .pi / 5
            pts.append((12 + r * cos(a), 12.6 + r * sin(a)))
        }
        return poly(pts, closed: true)
    }

    static func heart() -> RenderPath {
        var p = RenderPath()
        p.move(to: P(12, 20.5))
        p.cubic(to: P(2.5, 9), control1: P(7, 17), control2: P(2.5, 13.5))
        p.cubic(to: P(7.2, 4), control1: P(2.5, 6), control2: P(4.6, 4))
        p.cubic(to: P(12, 7), control1: P(9.4, 4), control2: P(11, 5.3))
        p.cubic(to: P(16.8, 4), control1: P(13, 5.3), control2: P(14.6, 4))
        p.cubic(to: P(21.5, 9), control1: P(19.4, 4), control2: P(21.5, 6))
        p.cubic(to: P(12, 20.5), control1: P(21.5, 13.5), control2: P(17, 17))
        p.close()
        return p
    }

    static func gear(teeth: Int = 8) -> RenderPath {
        var pts: [(Double, Double)] = []
        let n = teeth * 4
        for i in 0..<n {
            let a = Double(i) / Double(n) * 2 * .pi - .pi / Double(n)
            let r = (i % 4 == 0 || i % 4 == 1) ? 10.5 : 8
            pts.append((12 + r * cos(a), 12 + r * sin(a)))
        }
        return poly(pts, closed: true)
    }

    /// A claw hammer (R13, for bezel sizes): drawn upright — the head
    /// across the top (the striking face on the left, the claw curving down
    /// on the right), the handle tapering down — then turned 45° so that the
    /// handle points to the lower left. One closed outline.
    static func hammer() -> RenderPath {
        var p = RenderPath()
        // Striking face (a block a little taller than the head).
        p.move(to: P(3.2, 2.2))
        p.line(to: P(7.6, 2.2))
        p.line(to: P(7.6, 3.4))
        // Top of the head to the claw.
        p.line(to: P(14.6, 3.4))
        // The claw: a curved prong down to a point.
        p.cubic(to: P(20.8, 9.6), control1: P(18.2, 3.4), control2: P(20.6, 5.8))
        p.cubic(to: P(16.4, 6.6), control1: P(19.4, 7.6), control2: P(17.8, 6.6))
        // Under the head to the handle's neck.
        p.line(to: P(13.4, 6.6))
        // The handle, tapering, with a rounded end.
        p.line(to: P(13.0, 20.4))
        p.cubic(to: P(10.6, 20.4), control1: P(13.0, 21.8), control2: P(10.6, 21.8))
        p.line(to: P(10.2, 6.6))
        // Under the head back to the face.
        p.line(to: P(7.6, 6.6))
        p.line(to: P(7.6, 7.8))
        p.line(to: P(3.2, 7.8))
        p.close()
        let c = cos(Double.pi / 4), s = sin(Double.pi / 4), k = 0.84
        // Scale about the drawing's centre (12, 12), turn 45° clockwise.
        let t = RenderTransform(a: k * c, b: k * s, c: -k * s, d: k * c,
                                tx: 12 - k * (c * 12 - s * 12), ty: 12 - k * (s * 12 + c * 12))
        return p.applying(t)
    }

    static func cloud() -> RenderPath {
        var p = RenderPath()
        p.move(to: P(7, 19))
        p.cubic(to: P(7, 11), control1: P(2, 19), control2: P(2, 11))
        p.cubic(to: P(16, 9), control1: P(8, 5.5), control2: P(14.5, 5))
        p.cubic(to: P(18, 19), control1: P(22.5, 9), control2: P(23, 19))
        p.close()
        return p
    }
}

/// A gear outline with `teeth` teeth between radii `inner` and `outer`.
private func gearPath(cx: Double, cy: Double, outer: Double, inner: Double, teeth: Int) -> RenderPath {
    var pts: [(Double, Double)] = []
    let n = teeth * 4
    for i in 0..<n {
        let a = Double(i) / Double(n) * 2 * .pi - .pi / Double(n)
        let r = (i % 4 == 0 || i % 4 == 1) ? outer : inner
        pts.append((cx + r * cos(a), cy + r * sin(a)))
    }
    return Shapes.poly(pts, closed: true)
}

extension SymbolArtwork {
    private static let third = 1.0 / 3

    private static func make(_ name: String, _ w: Double = 62.0 / 3, _ h: Double = 62.0 / 3, baseline: Double = 11.0 / 3,
                             _ ops: [Operation]) -> SymbolArtwork {
        SymbolArtwork(name: name, operations: ops, bodySize: CGSize(width: w, height: h), bodyBaselineOffset: baseline)
    }

    private static func make(_ name: String, _ ops: [Operation]) -> SymbolArtwork {
        make(name, 62.0 / 3, 62.0 / 3, baseline: 11.0 / 3, ops)
    }

    private static func s(_ p: RenderPath, _ w: Double = 2) -> Operation { .stroke(p, width: w) }
    private static func f(_ p: RenderPath, eo: Bool = false) -> Operation { .fill(p, evenOdd: eo) }

    /// The set, by name.
    public static let all: [String: SymbolArtwork] = {
        typealias S = Shapes
        let c = S.circle(12, 12, 9)
        let checkmark = S.poly([(7, 12.5), (10.5, 16), (17, 8.5)])
        let plus = S.join([S.poly([(12, 6), (12, 18)]), S.poly([(6, 12), (18, 12)])])
        let xmark = S.join([S.poly([(7, 7), (17, 17)]), S.poly([(17, 7), (7, 17)])])
        let minus = S.poly([(6, 12), (18, 12)])
        var body = RenderPath()
        body.move(to: CGPoint(x: 5, y: 20))
        body.cubic(to: CGPoint(x: 19, y: 20), control1: CGPoint(x: 5, y: 13), control2: CGPoint(x: 19, y: 13))
        let folder = S.poly([(3, 6.5), (3, 18.5), (21, 18.5), (21, 8.5), (11.5, 8.5), (9.5, 6), (3, 6)], closed: true)
        let doc = S.poly([(6, 3), (14, 3), (19, 8), (19, 21), (6, 21)], closed: true)
        let playTri = S.poly([(8, 5), (19, 12), (8, 19)], closed: true)
        let tri = S.poly([(12, 3.5), (21.5, 20), (2.5, 20)], closed: true)
        let house = S.poly([(3.5, 11), (12, 4), (20.5, 11), (20.5, 20), (3.5, 20)], closed: true)
        var bell = RenderPath()
        bell.move(to: CGPoint(x: 5, y: 17))
        bell.line(to: CGPoint(x: 6.5, y: 15))
        bell.line(to: CGPoint(x: 6.5, y: 10))
        bell.cubic(to: CGPoint(x: 17.5, y: 10), control1: CGPoint(x: 6.5, y: 2.5), control2: CGPoint(x: 17.5, y: 2.5))
        bell.line(to: CGPoint(x: 17.5, y: 15))
        bell.line(to: CGPoint(x: 19, y: 17))
        bell.close()
        let share = S.join([S.poly([(8, 9), (5, 9), (5, 21), (19, 21), (19, 9), (16, 9)]), S.poly([(12, 3), (12, 15)]), S.poly([(8.5, 6.5), (12, 3), (15.5, 6.5)])])
        let download = S.join([S.poly([(8, 9), (5, 9), (5, 21), (19, 21), (19, 9), (16, 9)]), S.poly([(12, 3), (12, 15)]), S.poly([(8.5, 11.5), (12, 15), (15.5, 11.5)])])
        let lens = S.join([S.circle(10.5, 10.5, 6), S.poly([(15, 15), (20.5, 20.5)])])
        var sparkle = RenderPath()
        func spark(_ cx: Double, _ cy: Double, _ r: Double) {
            sparkle.move(to: CGPoint(x: cx, y: cy - r))
            sparkle.quad(to: CGPoint(x: cx + r, y: cy), control: CGPoint(x: cx + r * 0.15, y: cy - r * 0.15))
            sparkle.quad(to: CGPoint(x: cx, y: cy + r), control: CGPoint(x: cx + r * 0.15, y: cy + r * 0.15))
            sparkle.quad(to: CGPoint(x: cx - r, y: cy), control: CGPoint(x: cx - r * 0.15, y: cy + r * 0.15))
            sparkle.quad(to: CGPoint(x: cx, y: cy - r), control: CGPoint(x: cx - r * 0.15, y: cy - r * 0.15))
            sparkle.close()
        }
        spark(10, 13, 7)
        spark(18, 6, 3.5)
        spark(18.5, 18.5, 2.5)
        var moon = RenderPath()
        moon.move(to: CGPoint(x: 15, y: 3.5))
        moon.cubic(to: CGPoint(x: 20.5, y: 15.5), control1: CGPoint(x: 12, y: 9), control2: CGPoint(x: 15, y: 16))
        moon.cubic(to: CGPoint(x: 15, y: 3.5), control1: CGPoint(x: 15, y: 25), control2: CGPoint(x: -1, y: 15))
        moon.close()
        var sun = [S.circle(12, 12, 4)]
        for i in 0..<8 {
            let a = Double(i) * .pi / 4
            sun.append(S.poly([(12 + 7 * cos(a), 12 + 7 * sin(a)), (12 + 9.5 * cos(a), 12 + 9.5 * sin(a))]))
        }
        var arcCW = RenderPath()
        arcCW.move(to: CGPoint(x: 19, y: 12))
        arcCW.cubic(to: CGPoint(x: 12, y: 19), control1: CGPoint(x: 19, y: 16), control2: CGPoint(x: 16, y: 19))
        arcCW.cubic(to: CGPoint(x: 5, y: 12), control1: CGPoint(x: 8, y: 19), control2: CGPoint(x: 5, y: 16))
        arcCW.cubic(to: CGPoint(x: 12, y: 5), control1: CGPoint(x: 5, y: 8), control2: CGPoint(x: 8, y: 5))
        arcCW.cubic(to: CGPoint(x: 18, y: 8.5), control1: CGPoint(x: 14.6, y: 5), control2: CGPoint(x: 16.8, y: 6.4))

        var bubble = RenderPath()
        bubble.move(to: CGPoint(x: 7, y: 4))
        bubble.line(to: CGPoint(x: 17, y: 4))
        bubble.cubic(to: CGPoint(x: 21, y: 8), control1: CGPoint(x: 19.2, y: 4), control2: CGPoint(x: 21, y: 5.8))
        bubble.line(to: CGPoint(x: 21, y: 13))
        bubble.cubic(to: CGPoint(x: 17, y: 17), control1: CGPoint(x: 21, y: 15.2), control2: CGPoint(x: 19.2, y: 17))
        bubble.line(to: CGPoint(x: 11, y: 17))
        bubble.line(to: CGPoint(x: 6.5, y: 20.5))
        bubble.line(to: CGPoint(x: 6.5, y: 17))
        bubble.cubic(to: CGPoint(x: 3, y: 13), control1: CGPoint(x: 4.6, y: 16.8), control2: CGPoint(x: 3, y: 15.2))
        bubble.line(to: CGPoint(x: 3, y: 8))
        bubble.cubic(to: CGPoint(x: 7, y: 4), control1: CGPoint(x: 3, y: 5.8), control2: CGPoint(x: 4.8, y: 4))
        bubble.close()
        var branch = RenderPath()
        branch.move(to: CGPoint(x: 8, y: 15))
        branch.cubic(to: CGPoint(x: 16.5, y: 3.8), control1: CGPoint(x: 8, y: 9), control2: CGPoint(x: 16.5, y: 10))
        let bookmark = S.poly([(6, 3), (18, 3), (18, 21), (12, 16.5), (6, 21)], closed: true)
        let tag = S.poly([(3, 3), (12, 3), (21, 12), (12, 21), (3, 12)], closed: true)
        var eye = RenderPath()
        eye.move(to: CGPoint(x: 2, y: 12))
        eye.cubic(to: CGPoint(x: 22, y: 12), control1: CGPoint(x: 6, y: 4.5), control2: CGPoint(x: 18, y: 4.5))
        eye.cubic(to: CGPoint(x: 2, y: 12), control1: CGPoint(x: 18, y: 19.5), control2: CGPoint(x: 6, y: 19.5))
        eye.close()

        let list: [SymbolArtwork] = [
            make("star", 22, 62 * third, baseline: 11 * third, [s(S.star())]),
            make("star.fill", 22, 62 * third, baseline: 11 * third, [f(S.star())]),
            make("heart", 62 * third, 18, [s(S.heart())]),
            make("heart.fill", 62 * third, 18, [f(S.heart())]),
            make("trash", 19, 64 * third, [s(S.join([S.poly([(4, 6.5), (20, 6.5)]), S.poly([(9, 6.5), (9, 3.5), (15, 3.5), (15, 6.5)]),
                                                    S.poly([(6, 6.5), (7, 21), (17, 21), (18, 6.5)]), S.poly([(10, 10), (10, 17)]), S.poly([(14, 10), (14, 17)])]))]),
            make("trash.fill", 19, 64 * third, [f(S.poly([(6, 7.5), (7, 21), (17, 21), (18, 7.5)], closed: true)), s(S.join([S.poly([(4, 5.5), (20, 5.5)]), S.poly([(9, 5.5), (9, 3), (15, 3), (15, 5.5)])]))]),
            make("gear", 22, 22, [f(S.join([S.gear(), S.circle(12, 12, 3.5)]), eo: true)]),
            make("gearshape", 22, 22, [f(S.join([S.gear(), S.circle(12, 12, 3.5)]), eo: true)]),
            make("gearshape.fill", 22, 22, [f(S.join([S.gear(), S.circle(12, 12, 3.5)]), eo: true)]),
            make("person", [s(S.join([S.circle(12, 8, 3.6), body]))]),
            make("person.fill", [f(S.circle(12, 8, 4)), f(S.join([body, S.poly([(19, 20), (5, 20)])]))]),
            make("person.crop.circle", 59 * third, 59 * third, [s(c), s(S.circle(12, 9.5, 3)),
                                                                 s({ var p = RenderPath(); p.move(to: CGPoint(x: 6.5, y: 18)); p.cubic(to: CGPoint(x: 17.5, y: 18), control1: CGPoint(x: 8, y: 13.5), control2: CGPoint(x: 16, y: 13.5)); return p }())]),
            make("person.crop.circle.fill", 59 * third, 59 * third, [f(S.join([S.circle(12, 12, 10), S.circle(12, 9.5, 3.2)]), eo: true)]),
            make("plus", [s(plus)]),
            make("minus", [s(minus)]),
            make("xmark", [s(xmark)]),
            make("checkmark", [s(checkmark)]),
            make("plus.circle", [s(c), s(S.join([S.poly([(12, 8), (12, 16)]), S.poly([(8, 12), (16, 12)])]))]),
            make("plus.circle.fill", [f(S.circle(12, 12, 10)), .knockout(S.join([S.poly([(12, 7.5), (12, 16.5)]), S.poly([(7.5, 12), (16.5, 12)])]), width: 2)]),
            make("minus.circle", [s(c), s(S.poly([(8, 12), (16, 12)]))]),
            make("xmark.circle", [s(c), s(S.join([S.poly([(9, 9), (15, 15)]), S.poly([(15, 9), (9, 15)])]))]),
            make("xmark.circle.fill", [f(S.circle(12, 12, 10)), .knockout(S.join([S.poly([(9, 9), (15, 15)]), S.poly([(15, 9), (9, 15)])]), width: 2)]),
            make("checkmark.circle", [s(c), s(S.poly([(8, 12.5), (11, 15.5), (16, 9.5)]))]),
            make("checkmark.circle.fill", [f(S.circle(12, 12, 10)), .knockout(S.poly([(8, 12.5), (11, 15.5), (16, 9.5)]), width: 2)]),
            make("info.circle", [s(c), s(S.poly([(12, 11), (12, 17)])), f(S.circle(12, 7.6, 1.2))]),
            make("questionmark.circle", [s(c), s({ var q = RenderPath(); q.move(to: CGPoint(x: 9.5, y: 9.5)); q.cubic(to: CGPoint(x: 14.5, y: 9.5), control1: CGPoint(x: 9.5, y: 6), control2: CGPoint(x: 14.5, y: 6)); q.cubic(to: CGPoint(x: 12, y: 13.5), control1: CGPoint(x: 14.5, y: 12), control2: CGPoint(x: 12, y: 12)); q.line(to: CGPoint(x: 12, y: 14)); return q }()), f(S.circle(12, 17, 1.1))]),
            make("exclamationmark.triangle", [s(tri), s(S.poly([(12, 9), (12, 14)])), f(S.circle(12, 17, 1.1))]),
            make("exclamationmark.triangle.fill", [f(tri), .knockout(S.poly([(12, 9.5), (12, 13.5)]), width: 2), .knockout(S.circle(12, 16.8, 1.2), width: nil)]),
            make("chevron.left", [s(S.poly([(15, 5), (8, 12), (15, 19)]))]),
            make("chevron.right", [s(S.poly([(9, 5), (16, 12), (9, 19)]))]),
            make("chevron.up", [s(S.poly([(5, 15), (12, 8), (19, 15)]))]),
            make("chevron.down", [s(S.poly([(5, 9), (12, 16), (19, 9)]))]),
            make("arrow.left", [s(S.join([S.poly([(20, 12), (4, 12)]), S.poly([(10, 6), (4, 12), (10, 18)])]))]),
            make("arrow.right", [s(S.join([S.poly([(4, 12), (20, 12)]), S.poly([(14, 6), (20, 12), (14, 18)])]))]),
            make("arrow.up", [s(S.join([S.poly([(12, 20), (12, 4)]), S.poly([(6, 10), (12, 4), (18, 10)])]))]),
            make("arrow.down", [s(S.join([S.poly([(12, 4), (12, 20)]), S.poly([(6, 14), (12, 20), (18, 14)])]))]),
            make("arrow.clockwise", [s(arcCW), s(S.poly([(18.5, 3.5), (18.5, 8.5), (13.5, 8.5)]))]),
            make("folder", [s(folder)]),
            make("folder.fill", [f(folder)]),
            make("doc", [s(doc)]),
            make("doc.fill", [f(doc)]),
            make("doc.text", [s(doc), s(S.join([S.poly([(9, 11), (16, 11)]), S.poly([(9, 14.5), (16, 14.5)]), S.poly([(9, 18), (13, 18)])]), 1.5)]),
            make("play", [s(playTri)]),
            make("play.fill", [f(playTri)]),
            make("pause", [s(S.join([S.rect(7, 5, 3, 14), S.rect(14, 5, 3, 14)]))]),
            make("pause.fill", [f(S.join([S.rect(6.5, 5, 4, 14), S.rect(13.5, 5, 4, 14)]))]),
            make("stop", [s(S.roundedRect(5, 5, 14, 14, 2))]),
            make("stop.fill", [f(S.roundedRect(5, 5, 14, 14, 2))]),
            make("magnifyingglass", [s(lens)]),
            make("square.and.arrow.up", 19, 68 * third, [s(share)]),
            make("square.and.arrow.down", 19, 68 * third, [s(download)]),
            make("house", [s(house)]),
            make("house.fill", [f(house)]),
            make("bell", [s(bell), s(S.poly([(10, 20), (14, 20)]))]),
            make("bell.fill", [f(bell), s(S.poly([(10, 20), (14, 20)]))]),
            make("cloud", [s(S.cloud())]),
            make("cloud.fill", [f(S.cloud())]),
            make("cloud.sun.rain.fill", 76 * third, 79 * third, [f(S.circle(16, 7, 3.5)), f(S.cloud()), s(S.join([S.poly([(8, 21), (7, 23)]), S.poly([(12, 21), (11, 23)]), S.poly([(16, 21), (15, 23)])]), 1.5)]),
            make("sun.max", [s(S.join(sun))]),
            make("moon", [s(moon)]),
            make("moon.fill", [f(moon)]),
            make("iphone", 53 * third, 61 * third, [s(S.roundedRect(6.5, 2.5, 11, 19, 2.5)), s(S.poly([(10.5, 5), (13.5, 5)]), 1.5)]),
            make("rectangle.portrait.and.arrow.right", 70 * third, 62 * third, [s(S.poly([(13, 7), (13, 3.5), (3.5, 3.5), (3.5, 20.5), (13, 20.5), (13, 17)])), s(S.join([S.poly([(9, 12), (21, 12)]), S.poly([(17, 8), (21, 12), (17, 16)])]))]),
            make("hammer", 66 * third, 66 * third, [s(S.hammer(), 1.6)]),
            make("hammer.fill", 66 * third, 66 * third, [f(S.hammer())]),
            make("sparkles", [f(sparkle)]),
            make("ellipsis", [f(S.join([S.circle(6, 12, 1.6), S.circle(12, 12, 1.6), S.circle(18, 12, 1.6)]))]),
            make("line.3.horizontal", [s(S.join([S.poly([(4, 7), (20, 7)]), S.poly([(4, 12), (20, 12)]), S.poly([(4, 17), (20, 17)])]))]),
            make("sidebar.left", [s(S.roundedRect(3, 4.5, 18, 15, 2.5)), s(S.poly([(9, 4.5), (9, 19.5)]))]),
            make("circle", [s(c)]),
            make("circle.fill", [f(S.circle(12, 12, 10))]),
            make("square", [s(S.roundedRect(3.5, 3.5, 17, 17, 2.5))]),
            make("square.fill", [f(S.roundedRect(3, 3, 18, 18, 3))]),
            // R13 (names the Linux IDE shell uses; Ycode's own drawings).
            // Code: two angle brackets with a slash between them.
            make("chevron.left.forwardslash.chevron.right", 72 * third, 54 * third,
                 [s(S.join([S.poly([(7, 7), (2.5, 12), (7, 17)]), S.poly([(17, 7), (21.5, 12), (17, 17)]),
                            S.poly([(13.5, 5), (10.5, 19)])]))]),
            // A folder with a small gear on its lower right corner.
            make("folder.badge.gearshape", 72 * third, 60 * third,
                 [s(S.poly([(2.5, 6.5), (2.5, 18.5), (12.5, 18.5)])),
                  s(S.poly([(2.5, 6), (9, 6), (11, 8.5), (20.5, 8.5), (20.5, 12)])),
                  f(S.join([gearPath(cx: 18, cy: 18, outer: 5.2, inner: 4, teeth: 6), S.circle(18, 18, 1.7)]), eo: true)]),
            // Three stacked layers seen at an angle.
            make("square.stack.3d.up", 60 * third, 66 * third,
                 [s(S.poly([(12, 3), (21, 7.5), (12, 12), (3, 7.5)], closed: true)),
                  s(S.poly([(3, 12), (12, 16.5), (21, 12)])),
                  s(S.poly([(3, 16.5), (12, 21), (21, 16.5)]))]),
            make("square.stack.3d.up.fill", 60 * third, 66 * third,
                 [f(S.poly([(12, 3), (21, 7.5), (12, 12), (3, 7.5)], closed: true)),
                  s(S.poly([(3, 12), (12, 16.5), (21, 12)])),
                  s(S.poly([(3, 16.5), (12, 21), (21, 16.5)]))]),
            // The window outline with the divider on the right.
            make("sidebar.right", [s(S.roundedRect(3, 4.5, 18, 15, 2.5)), s(S.poly([(15, 4.5), (15, 19.5)]))]),
            make("sidebar.leading", [s(S.roundedRect(3, 4.5, 18, 15, 2.5)), s(S.poly([(9, 4.5), (9, 19.5)]))]),
            make("sidebar.trailing", [s(S.roundedRect(3, 4.5, 18, 15, 2.5)), s(S.poly([(15, 4.5), (15, 19.5)]))]),
            // Two gears: a large one at the upper left and a small one at
            // the lower right.
            make("gearshape.2", 70 * third, 66 * third,
                 [f(S.join([gearPath(cx: 9.5, cy: 9.5, outer: 8, inner: 6.2, teeth: 8), S.circle(9.5, 9.5, 2.6)]), eo: true),
                  f(S.join([gearPath(cx: 17.5, cy: 17.5, outer: 5, inner: 3.9, teeth: 6), S.circle(17.5, 17.5, 1.6)]), eo: true)]),
            make("gearshape.2.fill", 70 * third, 66 * third,
                 [f(S.join([gearPath(cx: 9.5, cy: 9.5, outer: 8, inner: 6.2, teeth: 8), S.circle(9.5, 9.5, 2.6)]), eo: true),
                  f(S.join([gearPath(cx: 17.5, cy: 17.5, outer: 5, inner: 3.9, teeth: 6), S.circle(17.5, 17.5, 1.6)]), eo: true)]),
            // A rounded frame with three bulleted lines.
            make("list.bullet.rectangle", 70 * third, 56 * third,
                 [s(S.roundedRect(2.5, 4, 19, 16, 2.5), 1.75),
                  f(S.join([S.circle(7, 8.5, 1.1), S.circle(7, 12, 1.1), S.circle(7, 15.5, 1.1)])),
                  s(S.join([S.poly([(10, 8.5), (18, 8.5)]), S.poly([(10, 12), (18, 12)]), S.poly([(10, 15.5), (18, 15.5)])]), 1.5)]),
            make("list.bullet", [f(S.join([S.circle(5, 7, 1.4), S.circle(5, 12, 1.4), S.circle(5, 17, 1.4)])),
                                 s(S.join([S.poly([(9, 7), (20, 7)]), S.poly([(9, 12), (20, 12)]), S.poly([(9, 17), (20, 17)])]))]),
            // A table: a frame with a header row and a column divider.
            make("tablecells", [s(S.roundedRect(3, 4.5, 18, 15, 2), 1.75),
                                s(S.join([S.poly([(3, 9.5), (21, 9.5)]), S.poly([(3, 14.5), (21, 14.5)]), S.poly([(12, 4.5), (12, 19.5)])]), 1.5)]),
            // LINUX-UI-PARITY (the workspace window's toolbar, selector
            // bars, jump bar, debug bar and inspector; Ycode's own drawings).
            // A speech bubble: a rounded frame with a tail at the lower left.
            make("text.bubble", [s(bubble), s(S.join([S.poly([(8, 9), (16, 9)]), S.poly([(8, 12.5), (13.5, 12.5)])]), 1.5)]),
            make("plus.bubble", [s(bubble), s(S.join([S.poly([(12, 7), (12, 14.5)]), S.poly([(8.25, 10.75), (15.75, 10.75)])]), 1.75)]),
            // A rectangle in front of another, a plus in the front one.
            make("plus.rectangle.on.rectangle", 72 * third, 60 * third,
                 [s(S.poly([(7, 6.5), (7, 3.5), (21, 3.5), (21, 14.5), (18, 14.5)]), 1.75), s(S.roundedRect(3, 8, 14.5, 12, 2), 1.75),
                  s(S.join([S.poly([(10.25, 11), (10.25, 17)]), S.poly([(7.25, 14), (13.25, 14)])]), 1.5)]),
            // A window with its right half filled (the canvas).
            make("rectangle.righthalf.inset.filled", 70 * third, 56 * third,
                 [s(S.roundedRect(2.5, 4.5, 19, 15, 2.5), 1.75), f(S.roundedRect(12.5, 7, 6.5, 10, 1))]),
            make("rectangle.split.2x1", 70 * third, 56 * third,
                 [s(S.roundedRect(2.5, 4.5, 19, 15, 2.5), 1.75), s(S.poly([(12, 4.5), (12, 19.5)]), 1.75)]),
            make("rectangle.bottomthird.inset.filled", 70 * third, 56 * third,
                 [s(S.roundedRect(2.5, 4.5, 19, 15, 2.5), 1.75), f(S.roundedRect(5, 13.5, 14, 3.5, 1))]),
            make("rectangle.on.rectangle", [s(S.poly([(7, 6.5), (7, 3.5), (21, 3.5), (21, 14.5), (18, 14.5)]), 1.75),
                                            s(S.roundedRect(3, 8, 14.5, 12, 2), 1.75)]),
            // Two arrows: right on top, left below.
            make("arrow.left.arrow.right", [s(S.join([S.poly([(4, 8), (20, 8)]), S.poly([(16, 4), (20, 8), (16, 12)]),
                                                      S.poly([(20, 16), (4, 16)]), S.poly([(8, 12), (4, 16), (8, 20)])]), 1.75)]),
            // A stem with a branch curving off to the upper right.
            make("arrow.triangle.branch", [s(S.join([S.poly([(8, 21), (8, 4)]), S.poly([(5, 7), (8, 4), (11, 7)]), branch,
                                                     S.poly([(13.5, 6.5), (16.5, 3.5), (19.5, 6.5)])]), 1.75)]),
            make("bookmark", [s(bookmark, 1.75)]),
            make("bookmark.fill", [f(bookmark)]),
            // A diamond with a check mark.
            make("checkmark.diamond", [s(S.poly([(12, 2.5), (21.5, 12), (12, 21.5), (2.5, 12)], closed: true), 1.75),
                                       s(S.poly([(8.5, 12), (11, 14.5), (15.5, 9.5)]), 1.75)]),
            // A dial: a circle, dots on its upper arc and a needle.
            make("gauge.with.dots.needle.33percent", [s(c, 1.75), s(S.poly([(12, 13), (8, 9)]), 1.75), f(S.circle(12, 13, 1.6)),
                                                      f(S.join([S.circle(6.5, 13, 0.9), S.circle(8, 8, 0.9), S.circle(12, 6, 0.9),
                                                                S.circle(16, 8, 0.9), S.circle(17.5, 13, 0.9)]))]),
            // A luggage tag with its hole.
            make("tag", [s(tag, 1.75), f(S.circle(7.5, 7.5, 1.4))]),
            make("tag.fill", [f(S.join([tag, S.circle(7.5, 7.5, 1.4)]), eo: true)]),
            make("clock", [s(c, 1.75), s(S.poly([(12, 7), (12, 12), (15.5, 14)]), 1.75)]),
            // A box seen from above a corner.
            make("shippingbox", [s(S.poly([(12, 3), (20.5, 7.5), (20.5, 16.5), (12, 21), (3.5, 16.5), (3.5, 7.5)], closed: true), 1.75),
                                 s(S.join([S.poly([(3.5, 7.5), (12, 12), (20.5, 7.5)]), S.poly([(12, 12), (12, 21)]),
                                           S.poly([(7.75, 5.25), (16.25, 9.75)])]), 1.5)]),
            make("shippingbox.fill", [f(S.poly([(12, 3), (20.5, 7.5), (20.5, 16.5), (12, 21), (3.5, 16.5), (3.5, 7.5)], closed: true))]),
            // A monitor on a stand.
            make("desktopcomputer", 70 * third, 60 * third,
                 [f(S.join([S.roundedRect(2, 3.5, 20, 13, 1.5), S.rect(10.5, 16, 3, 3), S.roundedRect(7, 19, 10, 1.8, 0.9)]))]),
            make("square.grid.2x2", [s(S.join([S.roundedRect(3.5, 3.5, 7, 7, 1.5), S.roundedRect(13.5, 3.5, 7, 7, 1.5),
                                               S.roundedRect(3.5, 13.5, 7, 7, 1.5), S.roundedRect(13.5, 13.5, 7, 7, 1.5)]), 1.5)]),
            make("eye", [s(eye, 1.75), s(S.circle(12, 12, 3), 1.75)]),
            make("line.3.horizontal.decrease", [s(S.join([S.poly([(3.5, 7), (20.5, 7)]), S.poly([(7, 12), (17, 12)]),
                                                          S.poly([(10, 17), (14, 17)])]))]),
            make("line.3.horizontal.decrease.circle", [s(c, 1.75), s(S.join([S.poly([(7.5, 9), (16.5, 9)]), S.poly([(9.5, 12.5), (14.5, 12.5)]),
                                                                            S.poly([(11, 16), (13, 16)])]), 1.75)]),
            make("chevron.up.chevron.down", 15, 62 * third, [s(S.join([S.poly([(8, 9), (12, 5), (16, 9)]), S.poly([(8, 15), (12, 19), (16, 15)])]))]),
            make("arrow.right.circle.fill", [f(S.circle(12, 12, 10)),
                                             .knockout(S.join([S.poly([(7, 12), (16.5, 12)]), S.poly([(13, 8), (17, 12), (13, 16)])]), width: 2)]),
            make("c.square", [s(S.roundedRect(3.5, 3.5, 17, 17, 3), 1.75),
                              s({ var q = RenderPath(); q.move(to: CGPoint(x: 15, y: 9)); q.cubic(to: CGPoint(x: 15, y: 15), control1: CGPoint(x: 12, y: 6), control2: CGPoint(x: 7, y: 9)); q.cubic(to: CGPoint(x: 15, y: 15), control1: CGPoint(x: 7, y: 15), control2: CGPoint(x: 12, y: 18)); return q }(), 1.75)]),
            make("text.magnifyingglass", [s(S.join([S.poly([(3, 6), (15, 6)]), S.poly([(3, 10), (9, 10)]), S.poly([(3, 14), (7, 14)])]), 1.5),
                                          s(S.join([S.circle(15, 14, 4.5), S.poly([(18.3, 17.3), (21.5, 20.5)])]), 1.75)]),
            // A rounded square drawn as dashes (an app with no icon).
            make("app.dashed", [s(S.join([S.poly([(8, 3.5), (10.5, 3.5)]), S.poly([(13.5, 3.5), (16, 3.5)]), S.poly([(8, 20.5), (10.5, 20.5)]),
                                          S.poly([(13.5, 20.5), (16, 20.5)]), S.poly([(3.5, 8), (3.5, 10.5)]), S.poly([(3.5, 13.5), (3.5, 16)]),
                                          S.poly([(20.5, 8), (20.5, 10.5)]), S.poly([(20.5, 13.5), (20.5, 16)])]), 1.75),
                                 s(S.join([S.poly([(3.5, 5.5), (3.5, 3.5), (5.5, 3.5)]), S.poly([(18.5, 3.5), (20.5, 3.5), (20.5, 5.5)]),
                                           S.poly([(20.5, 18.5), (20.5, 20.5), (18.5, 20.5)]), S.poly([(5.5, 20.5), (3.5, 20.5), (3.5, 18.5)])]), 1.75)]),
            make("plusminus.circle", [s(c, 1.75), s(S.join([S.poly([(12, 6.5), (12, 11.5)]), S.poly([(9.5, 9), (14.5, 9)]),
                                                            S.poly([(9.5, 15.5), (14.5, 15.5)])]), 1.5)]),
            make("xmark.octagon", [s(S.poly([(8.3, 3), (15.7, 3), (21, 8.3), (21, 15.7), (15.7, 21), (8.3, 21), (3, 15.7), (3, 8.3)], closed: true), 1.75),
                                   s(S.join([S.poly([(9, 9), (15, 15)]), S.poly([(15, 9), (9, 15)])]), 1.75)]),
            make("checklist", [s(S.join([S.poly([(3, 6.5), (5, 8.5), (8.5, 4.5)]), S.poly([(3, 15.5), (5, 17.5), (8.5, 13.5)]),
                                         S.poly([(11.5, 7), (21, 7)]), S.poly([(11.5, 16), (21, 16)])]), 1.75)]),
            make("hammer.circle", [s(c, 1.75), f(S.hammer().applying(RenderTransform(a: 0.55, b: 0, c: 0, d: 0.55, tx: 5.4, ty: 5.4)))]),
            // Ycode's editors (asset and String Catalogs, the Attributes
            // inspector): a picture (frame, hill, sun), a picture on a
            // second frame, a closed book with a character (the sliders are
            // the debugger's set below).
            make("photo", [s(S.roundedRect(3, 5, 18, 14, 2.5), 1.75), s(S.poly([(4, 17.5), (9.5, 11.5), (13, 15), (15.5, 12.5), (20, 17)]), 1.5),
                           f(S.circle(15.5, 9, 1.6))]),
            make("photo.on.rectangle", [s(S.poly([(6, 3.5), (19, 3.5), (21, 3.5), (21, 15)]), 1.5), s(S.roundedRect(3, 7, 15, 13, 2.5), 1.75),
                                        s(S.poly([(4, 18.5), (8.5, 13.5), (11.5, 16.5), (13.5, 14.5), (17, 18)]), 1.5), f(S.circle(13.5, 10.5, 1.4))]),
            make("character.book.closed", [s(S.roundedRect(5, 3, 14, 18, 2), 1.75), s(S.poly([(8, 3), (8, 21)]), 1.5),
                                           s(S.join([S.poly([(10.5, 15), (13, 8), (15.5, 15)]), S.poly([(11.4, 12.5), (14.6, 12.5)])]), 1.5)]),
        ] + projectTemplateSymbols + debuggerSymbols + sourceControlSymbols + navigatorSymbols + interfaceBuilderSymbols
        var d: [String: SymbolArtwork] = [:]
        for a in list { d[a.name] = a }
        return d
    }()

    /// The IDE's debug bar and debug area (B2-DEBUG): Step Over, Step Into,
    /// Step Out, and the variables-view half of the debug area. Plain
    /// outlines on the same grid.
    private static let debuggerSymbols: [SymbolArtwork] = {
        typealias S = Shapes
        let w = 1.75
        func lines(_ l: [[(Double, Double)]]) -> RenderPath { S.join(l.map { S.poly($0) }) }
        // An arc over a point, landing to its right.
        var over = RenderPath()
        over.move(to: CGPoint(x: 4, y: 15))
        over.cubic(to: CGPoint(x: 17, y: 12), control1: CGPoint(x: 4, y: 5), control2: CGPoint(x: 17, y: 4))
        return [
            make("arrow.turn.down.right", [s(over, w), s(lines([[(13.5, 9), (17, 12.5), (20.5, 9)]]), w), f(S.circle(4, 19.5, 1.6))]),
            make("arrow.down.to.line", [s(lines([[(12, 3), (12, 15)], [(7.5, 10.5), (12, 15), (16.5, 10.5)], [(5, 20), (19, 20)]]), w)]),
            make("arrow.up.to.line", [s(lines([[(12, 21), (12, 9)], [(7.5, 13.5), (12, 9), (16.5, 13.5)], [(5, 4), (19, 4)]]), w)]),
            // A window with its left half filled (the variables view).
            make("rectangle.lefthalf.inset.filled", 70 * third, 56 * third,
                 [s(S.roundedRect(2.5, 4.5, 19, 15, 2.5), w), f(S.roundedRect(5, 7, 6.5, 10, 1))]),
            // The Debug and Breakpoint navigators' bottom-bar toggles.
            make("arrow.down.right.and.arrow.up.left", [s(lines([[(4, 4), (10, 10)], [(5.5, 10), (10, 10), (10, 5.5)],
                                                                [(20, 20), (14, 14)], [(18.5, 14), (14, 14), (14, 18.5)]]), w)]),
            make("star.circle", [s(S.circle(12, 12, 9), w), s(S.star().applying(RenderTransform(a: 0.5, b: 0, c: 0, d: 0.5, tx: 6, ty: 5.7)), 1.5)]),
            make("play.circle", [s(S.circle(12, 12, 9), w), s(S.poly([(10, 8), (16, 12), (10, 16)], closed: true), 1.5)]),
            make("slider.horizontal.3", [s(lines([[(3, 6), (21, 6)], [(3, 12), (21, 12)], [(3, 18), (21, 18)]]), w),
                                         f(S.circle(8, 6, 2.2)), f(S.circle(15, 12, 2.2)), f(S.circle(10, 18, 2.2))]),
        ]
    }()

    /// What the IDE's New Project templates show (BETA-POLISH): plain
    /// outlines on the same grid.
    private static let projectTemplateSymbols: [SymbolArtwork] = {
        typealias S = Shapes
        let w = 1.75
        func lines(_ l: [[(Double, Double)]]) -> RenderPath { S.join(l.map { S.poly($0) }) }
        let tv = S.roundedRect(3, 5, 18, 12, 2)
        let console = S.roundedRect(3, 4, 18, 16, 3)
        let prompt = lines([[(7, 9), (10.5, 12), (7, 15)], [(12.5, 15.5), (17, 15.5)]])
        let cube = S.poly([(12, 3), (20, 7.5), (20, 16.5), (12, 21), (4, 16.5), (4, 7.5)], closed: true)
        let cubeEdges = lines([[(4, 7.5), (12, 12), (20, 7.5)], [(12, 12), (12, 21)]])
        let chip = S.roundedRect(6, 6, 12, 12, 2)
        let pins = lines([[(9.5, 3), (9.5, 6)], [(14.5, 3), (14.5, 6)], [(9.5, 18), (9.5, 21)], [(14.5, 18), (14.5, 21)],
                          [(3, 9.5), (6, 9.5)], [(3, 14.5), (6, 14.5)], [(18, 9.5), (21, 9.5)], [(18, 14.5), (21, 14.5)]])
        func sparkle(_ x: Double, _ y: Double, _ r: Double) -> RenderPath {
            S.poly([(x, y - r), (x + r / 3, y - r / 3), (x + r, y), (x + r / 3, y + r / 3), (x, y + r), (x - r / 3, y + r / 3), (x - r, y), (x - r / 3, y - r / 3)], closed: true)
        }
        var doc = RenderPath()
        doc.move(to: CGPoint(x: 6, y: 3))
        doc.line(to: CGPoint(x: 14, y: 3))
        doc.line(to: CGPoint(x: 19, y: 8))
        doc.line(to: CGPoint(x: 19, y: 21))
        doc.line(to: CGPoint(x: 6, y: 21))
        doc.close()
        var smile = RenderPath()
        smile.move(to: CGPoint(x: 8, y: 14))
        smile.cubic(to: CGPoint(x: 16, y: 14), control1: CGPoint(x: 9.5, y: 18), control2: CGPoint(x: 14.5, y: 18))
        var meridian = RenderPath()
        meridian.move(to: CGPoint(x: 12, y: 3))
        meridian.cubic(to: CGPoint(x: 12, y: 21), control1: CGPoint(x: 6, y: 8), control2: CGPoint(x: 6, y: 16))
        meridian.cubic(to: CGPoint(x: 12, y: 3), control1: CGPoint(x: 18, y: 16), control2: CGPoint(x: 18, y: 8))
        return [
            make("app.badge", [s(S.roundedRect(3, 5, 16, 16, 4), w), f(S.circle(19, 5, 3))]),
            make("archivebox", [s(S.roundedRect(3, 4, 18, 5, 1), w), s(S.poly([(4.5, 9), (4.5, 20), (19.5, 20), (19.5, 9)]), w), s(S.poly([(9.5, 13), (14.5, 13)]), w)]),
            make("building.columns", [s(S.poly([(12, 3), (21, 8.5), (3, 8.5)], closed: true), w),
                                      s(lines([[(6, 11), (6, 18)], [(10, 11), (10, 18)], [(14, 11), (14, 18)], [(18, 11), (18, 18)], [(3, 21), (21, 21)]]), w)]),
            make("camera.viewfinder", [s(lines([[(3, 8), (3, 3), (8, 3)], [(16, 3), (21, 3), (21, 8)], [(21, 16), (21, 21), (16, 21)], [(8, 21), (3, 21), (3, 16)]]), w),
                                       s(S.roundedRect(7, 8.5, 10, 7.5, 1.5), w), s(S.circle(12, 12.2, 1.8), 1.25)]),
            make("cpu", [s(chip, w), s(S.roundedRect(10, 10, 4, 4, 0.5), 1.25), s(pins, w)]),
            make("cpu.fill", [f(chip), s(pins, w)]),
            make("cube", [s(cube, w), s(cubeEdges, w)]),
            make("cube.transparent", [s(cube, 1.5), s(cubeEdges, 1), s(lines([[(4, 16.5), (12, 12), (20, 16.5)], [(12, 12), (12, 3)]]), 1)]),
            make("doc.richtext", [s(doc, w), s(lines([[(9, 16), (11.5, 10), (14, 16)], [(10, 14), (13, 14)]]), 1.25), s(S.poly([(9, 18.5), (16, 18.5)]), 1.25)]),
            make("face.smiling", [s(S.circle(12, 12, 9), w), f(S.circle(9, 10, 1.2)), f(S.circle(15, 10, 1.2)), s(smile, w)]),
            make("gamecontroller", [s(S.roundedRect(2.5, 7, 19, 11, 5.5), w), s(lines([[(8, 10), (8, 15)], [(5.5, 12.5), (10.5, 12.5)]]), w),
                                    f(S.circle(15, 14, 1.2)), f(S.circle(18, 11.5, 1.2))]),
            make("globe", [s(S.circle(12, 12, 9), w), s(meridian, 1.25), s(lines([[(3, 12), (21, 12)]]), 1.25)]),
            make("macwindow", [s(S.roundedRect(3, 4, 18, 16, 2), w), s(S.poly([(3, 9), (21, 9)]), w), f(S.circle(5.8, 6.5, 0.8)), f(S.circle(8.4, 6.5, 0.8))]),
            make("message", [s(S.poly([(7, 4), (17, 4), (21, 8), (21, 13), (17, 17), (11, 17), (6.5, 21), (7, 17), (3, 13), (3, 8)], closed: true), w)]),
            make("mountain.2", [s(S.poly([(2, 19), (9, 7), (13.5, 14.5), (16, 11), (22, 19)], closed: true), w)]),
            make("number", [s(lines([[(9.5, 4), (7.5, 20)], [(16.5, 4), (14.5, 20)], [(4.5, 9.5), (20, 9.5)], [(4, 14.5), (19.5, 14.5)]]), w)]),
            make("play.rectangle", [s(S.roundedRect(3, 5, 18, 14, 3), w), s(S.poly([(10, 9), (15.5, 12), (10, 15)], closed: true), w)]),
            make("point.3.connected.trianglepath.dotted", [s(S.circle(12, 5, 2.5), w), s(S.circle(5, 18.5, 2.5), w), s(S.circle(19, 18.5, 2.5), w),
                                                           s(lines([[(10.5, 7.5), (9.8, 8.7)], [(8.6, 10.8), (7.9, 12)], [(6.7, 14.2), (6.2, 16)],
                                                                    [(13.5, 7.5), (14.2, 8.7)], [(15.4, 10.8), (16.1, 12)], [(17.3, 14.2), (17.8, 16)],
                                                                    [(8, 18.5), (10, 18.5)], [(14, 18.5), (16, 18.5)]]), 1.5)]),
            make("shippingbox.and.arrow.backward", [s(S.poly([(10, 3), (19, 7), (19, 16), (10, 20), (6, 18.2)]), w), s(S.poly([(10, 11), (19, 7)]), w), s(S.poly([(10, 11), (10, 20)]), w),
                                                    s(lines([[(9, 12.5), (2, 12.5)], [(5, 9.5), (2, 12.5), (5, 15.5)]]), w)]),
            make("sparkles.tv", [s(tv, w), s(S.poly([(8, 20), (16, 20)]), w), f(sparkle(12, 11, 3.5))]),
            make("terminal", [s(console, w), s(prompt, w)]),
            make("terminal.fill", [f(console), .knockout(prompt, width: w)]),
            make("timer", [s(S.circle(12, 13.5, 8), w), s(lines([[(9.5, 2.5), (14.5, 2.5)], [(12, 2.5), (12, 5.5)], [(12, 13.5), (15.5, 9.5)]]), w)]),
            make("tv", [s(tv, w), s(S.poly([(8, 20), (16, 20)]), w)]),
            make("waveform", [s(lines([[(3, 11), (3, 13)], [(7, 8), (7, 16)], [(11, 4), (11, 20)], [(15, 7), (15, 17)], [(19, 10), (19, 14)]]), 2)]),
        ]
    }()
}
