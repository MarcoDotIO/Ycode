// Damage between two display lists (09-open-design.md §3.5): items are
// matched by ID; an item that appeared, disappeared or changed contributes
// its old and new bounds. A group whose own attributes changed (transform,
// opacity, clip, mask, effects, blend) is damaged as a whole; otherwise
// its children are compared one by one.

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public enum DisplayListDiff {
    /// The rectangles (points, root coordinates) that differ between `old`
    /// and `new`; empty when the lists draw the same thing.
    public static func damage(from old: DisplayList, to new: DisplayList) -> [CGRect] {
        var out: [CGRect] = []
        diff(old.items, new.items, transform: .identity, clip: nil, into: &out)
        return merge(out)
    }

    /// Damage in pixels for a surface of `size` at `scale`, merged into at
    /// most a few rectangles.
    public static func pixelDamage(from old: DisplayList, to new: DisplayList, scale: Double, size: PixelSize) -> [PixelRect] {
        let full = PixelRect(x: 0, y: 0, width: size.width, height: size.height)
        let rects = damage(from: old, to: new).map { PixelRect.covering($0.insetBy(dx: -1, dy: -1), scale: scale).intersection(full) }
            .filter { !$0.isEmpty }
        guard !rects.isEmpty else { return [] }
        // A union is cheaper to redraw than many small rectangles.
        return [rects.dropFirst().reduce(rects[0]) { $0.union($1) }]
    }

    private static func diff(_ a: [DisplayItem], _ b: [DisplayItem], transform t: RenderTransform, clip: CGRect?, into out: inout [CGRect]) {
        var oldByID: [DisplayItemID: (Int, DisplayItem)] = [:]
        for (i, item) in a.enumerated() { oldByID[item.id] = (i, item) }
        var matchedOld = Set<DisplayItemID>()
        var lastOldIndex = -1
        for item in b {
            guard let (oi, old) = oldByID[item.id] else {
                add(bounds(item, t), clip, &out)
                continue
            }
            matchedOld.insert(item.id)
            // A reordered item changes what it covers.
            let reordered = oi < lastOldIndex
            lastOldIndex = max(lastOldIndex, oi)
            if reordered {
                add(bounds(old, t), clip, &out)
                add(bounds(item, t), clip, &out)
                continue
            }
            if old == item { continue }
            if case .group(let og) = old.content, case .group(let ng) = item.content, sameAttributes(og, ng) {
                let inner = t.concatenating(ng.transform)
                diff(og.children, ng.children, transform: inner, clip: clipRect(ng, t, clip), into: &out)
            } else {
                add(bounds(old, t), clip, &out)
                add(bounds(item, t), clip, &out)
            }
        }
        for item in a where !matchedOld.contains(item.id) { add(bounds(item, t), clip, &out) }
    }

    private static func sameAttributes(_ a: DisplayGroup, _ b: DisplayGroup) -> Bool {
        a.transform == b.transform && a.opacity == b.opacity && a.blendMode == b.blendMode && a.clips == b.clips
            && a.mask == b.mask && a.effects == b.effects && a.isLayer == b.isLayer
    }

    private static func clipRect(_ g: DisplayGroup, _ t: RenderTransform, _ outer: CGRect?) -> CGRect? {
        var r = outer
        let inner = t.concatenating(g.transform)
        for c in g.clips where !c.inverse && c.stroke == nil {
            let b = inner.boundingBox(of: c.path.controlBounds)
            r = r.map { $0.intersection(b) } ?? b
        }
        return r
    }

    private static func add(_ r: CGRect, _ clip: CGRect?, _ out: inout [CGRect]) {
        var r = r
        if let c = clip { r = r.intersection(c) }
        if !r.isNull && !r.isEmpty { out.append(r) }
    }

    /// Bounds of an item in root coordinates (a superset: control points,
    /// stroke widths, effect spread).
    public static func bounds(_ item: DisplayItem, _ t: RenderTransform) -> CGRect {
        switch item.content {
        case let .fill(path, _, _):
            return t.boundingBox(of: path.controlBounds)
        case let .stroke(path, _, s):
            let w = s.lineWidth * (s.lineJoin == .miter ? max(1, s.miterLimit) : 1)
            return t.boundingBox(of: path.controlBounds.insetBy(dx: -w, dy: -w))
        case .glyphs(let run):
            guard let first = run.positions.first else { return .null }
            var r = CGRect(origin: first, size: .zero)
            for p in run.positions { r = r.union(CGRect(origin: p, size: .zero)) }
            // Glyphs reach about one em around their origins.
            let em = run.size * (1 + abs(run.shear))
            return t.boundingBox(of: r.insetBy(dx: -em, dy: -em))
        case let .image(_, rect, _, _):
            return t.boundingBox(of: rect)
        case .group(let g):
            let inner = t.concatenating(g.transform)
            var r = CGRect.null
            for c in g.children { r = r.union(bounds(c, inner)) }
            for c in g.clips where !c.inverse && c.stroke == nil { r = r.intersection(inner.boundingBox(of: c.path.controlBounds)) }
            var spread = 0.0
            for e in g.effects {
                switch e {
                case .blur(let radius): spread = max(spread, radius * 1.5)
                case let .shadow(_, radius, x, y): spread = max(spread, radius * 1.5 + max(abs(x), abs(y)))
                case .colorMultiply: break
                }
            }
            if spread > 0, !r.isNull {
                let s = spread * max(abs(inner.a) + abs(inner.c), abs(inner.b) + abs(inner.d))
                r = r.insetBy(dx: -s, dy: -s)
            }
            return r
        case let .placeholder(rect, _):
            return t.boundingBox(of: rect)
        }
    }

    private static func merge(_ rects: [CGRect]) -> [CGRect] {
        var out: [CGRect] = []
        for r in rects {
            if let i = out.firstIndex(where: { $0.intersects(r) }) {
                out[i] = out[i].union(r)
            } else {
                out.append(r)
            }
        }
        return out
    }
}
