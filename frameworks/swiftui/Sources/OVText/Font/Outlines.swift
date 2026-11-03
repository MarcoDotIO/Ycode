// Glyph outlines (round R5) from the TrueType `glyf`/`loca` tables, written
// from the OpenType specification ("glyf — Glyph Data": simple glyphs with
// on/off-curve points and implied midpoints; composite glyphs with offsets
// and 2×2 transforms). CFF outlines are not read: a CFF-flavoured face
// returns nil and its text is not drawn (09-open-design.md §3.6).

/// One element of a glyph outline, in font design units with y up.
public enum GlyphOutlineElement: Hashable, Sendable {
    case move(x: Double, y: Double)
    case line(x: Double, y: Double)
    case quad(x: Double, y: Double, cx: Double, cy: Double)
    case close
}

extension FontFace {
    /// The outline of `glyph` in design units (nil when the face has none).
    public func outline(of glyph: GlyphID) -> [GlyphOutlineElement]? {
        (self as? OpenTypeFace)?.trueTypeOutline(of: glyph, depth: 0)
    }

    /// Design units per em (1000 for faces without outlines).
    public var designUnitsPerEm: Double {
        (self as? OpenTypeFace).map { Double($0.unitsPerEm) } ?? 1000
    }
}

extension OpenTypeFace {
    private func glyphRange(_ g: GlyphID) -> (Int, Int)? {
        guard let glyf = glyfTable, let loca = locaTable, Int(g) < glyphCount else { return nil }
        let d = bytes
        let i = Int(g)
        let start: Int, end: Int
        if locaLong {
            start = Int(d.u32(loca.offset + 4 * i))
            end = Int(d.u32(loca.offset + 4 * i + 4))
        } else {
            start = Int(d.u16(loca.offset + 2 * i)) * 2
            end = Int(d.u16(loca.offset + 2 * i + 2)) * 2
        }
        guard end > start, end <= glyf.length else { return nil }
        return (glyf.offset + start, end - start)
    }

    func trueTypeOutline(of g: GlyphID, depth: Int) -> [GlyphOutlineElement]? {
        guard depth < 8, let (o, len) = glyphRange(g), len >= 10 else { return nil }
        let d = bytes
        let contours = Int(d.i16(o))
        if contours >= 0 { return simpleOutline(at: o, contours: contours, end: o + len) }
        return compositeOutline(at: o + 10, end: o + len, depth: depth)
    }

    private func simpleOutline(at o: Int, contours n: Int, end: Int) -> [GlyphOutlineElement]? {
        let d = bytes
        var ends: [Int] = []
        for c in 0..<n { ends.append(Int(d.u16(o + 10 + 2 * c))) }
        let pointCount = (ends.last ?? -1) + 1
        guard pointCount > 0, pointCount < 65_536 else { return [] }
        let insLen = Int(d.u16(o + 10 + 2 * n))
        var p = o + 12 + 2 * n + insLen
        var flags = [UInt8]()
        flags.reserveCapacity(pointCount)
        while flags.count < pointCount, p < end {
            let f = d.u8(p)
            p += 1
            flags.append(f)
            if f & 0x08 != 0, p < end {
                let r = Int(d.u8(p))
                p += 1
                for _ in 0..<r where flags.count < pointCount { flags.append(f) }
            }
        }
        guard flags.count == pointCount else { return nil }
        var xs = [Int](repeating: 0, count: pointCount), ys = xs
        var v = 0
        for i in 0..<pointCount {
            let f = flags[i]
            if f & 0x02 != 0 {
                let dx = Int(d.u8(p))
                p += 1
                v += f & 0x10 != 0 ? dx : -dx
            } else if f & 0x10 == 0 {
                v += Int(d.i16(p))
                p += 2
            }
            xs[i] = v
        }
        v = 0
        for i in 0..<pointCount {
            let f = flags[i]
            if f & 0x04 != 0 {
                let dy = Int(d.u8(p))
                p += 1
                v += f & 0x20 != 0 ? dy : -dy
            } else if f & 0x20 == 0 {
                v += Int(d.i16(p))
                p += 2
            }
            ys[i] = v
        }
        guard p <= end + 3 else { return nil }
        var out: [GlyphOutlineElement] = []
        var first = 0
        for last in ends {
            guard last >= first, last < pointCount else { break }
            let pts = (first...last).map { (Double(xs[$0]), Double(ys[$0]), flags[$0] & 0x01 != 0) }
            first = last + 1
            out += contour(pts)
        }
        return out
    }

    /// A closed contour of quadratic B-splines: consecutive off-curve points
    /// imply an on-curve midpoint.
    private func contour(_ pts: [(Double, Double, Bool)]) -> [GlyphOutlineElement] {
        guard pts.count > 1 else { return [] }
        let n = pts.count
        // Start at an on-curve point, or at the midpoint of the first two.
        var start: (Double, Double)
        var startIndex: Int
        if let i = pts.firstIndex(where: { $0.2 }) {
            start = (pts[i].0, pts[i].1)
            startIndex = i
        } else {
            start = ((pts[0].0 + pts[1].0) / 2, (pts[0].1 + pts[1].1) / 2)
            startIndex = 0
        }
        var out: [GlyphOutlineElement] = [.move(x: start.0, y: start.1)]
        var control: (Double, Double)?
        for k in 1...n {
            let idx = (startIndex + k) % n
            let (x, y, on) = pts[idx]
            if on {
                if let c = control {
                    out.append(.quad(x: x, y: y, cx: c.0, cy: c.1))
                    control = nil
                } else {
                    out.append(.line(x: x, y: y))
                }
            } else if let c = control {
                let mx = (c.0 + x) / 2, my = (c.1 + y) / 2
                out.append(.quad(x: mx, y: my, cx: c.0, cy: c.1))
                control = (x, y)
            } else {
                control = (x, y)
            }
        }
        if let c = control {
            out.append(.quad(x: start.0, y: start.1, cx: c.0, cy: c.1))
        }
        out.append(.close)
        return out
    }

    private func compositeOutline(at start: Int, end: Int, depth: Int) -> [GlyphOutlineElement]? {
        let d = bytes
        var p = start
        var out: [GlyphOutlineElement] = []
        while p + 4 <= end {
            let flags = d.u16(p)
            let glyph = GlyphID(d.u16(p + 2))
            p += 4
            var dx = 0.0, dy = 0.0
            if flags & 0x0001 != 0 {
                if flags & 0x0002 != 0 {
                    dx = Double(d.i16(p))
                    dy = Double(d.i16(p + 2))
                }
                p += 4
            } else {
                if flags & 0x0002 != 0 {
                    dx = Double(Int8(bitPattern: d.u8(p)))
                    dy = Double(Int8(bitPattern: d.u8(p + 1)))
                }
                p += 2
            }
            func f2dot14(_ o: Int) -> Double { Double(d.i16(o)) / 16_384 }
            var a = 1.0, b = 0.0, c = 0.0, e = 1.0
            if flags & 0x0008 != 0 {
                a = f2dot14(p)
                e = a
                p += 2
            } else if flags & 0x0040 != 0 {
                a = f2dot14(p)
                e = f2dot14(p + 2)
                p += 4
            } else if flags & 0x0080 != 0 {
                a = f2dot14(p)
                b = f2dot14(p + 2)
                c = f2dot14(p + 4)
                e = f2dot14(p + 6)
                p += 8
            }
            if let part = trueTypeOutline(of: glyph, depth: depth + 1) {
                func t(_ x: Double, _ y: Double) -> (Double, Double) { (a * x + c * y + dx, b * x + e * y + dy) }
                for el in part {
                    switch el {
                    case let .move(x, y):
                        let q = t(x, y)
                        out.append(.move(x: q.0, y: q.1))
                    case let .line(x, y):
                        let q = t(x, y)
                        out.append(.line(x: q.0, y: q.1))
                    case let .quad(x, y, cx, cy):
                        let q = t(x, y), r = t(cx, cy)
                        out.append(.quad(x: q.0, y: q.1, cx: r.0, cy: r.1))
                    case .close:
                        out.append(.close)
                    }
                }
            }
            if flags & 0x0020 == 0 { break }
        }
        return out
    }
}
