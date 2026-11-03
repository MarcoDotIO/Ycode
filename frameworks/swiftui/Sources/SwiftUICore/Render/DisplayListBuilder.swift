import Foundation
import OVRender
import OVText
import Synchronization

// Lowering the laid-out view graph to a display list (09-open-design.md
// §3.5, round R5). The walk mirrors `presentedLayers()` (R6): every layout
// node is placed at its presented frame, render effects use their presented
// values, removed views that are still transitioning out are drawn where
// they were. A node contributes its own drawing (`LayoutNode.draw`, below
// its children), then its children (a background before its base); effects
// wrap the result in a group. Groups that only translate are dissolved, so
// the list stays flat where nothing needs isolation.
//
// Item IDs come from view identity: the view-graph node that created the
// layout node (stable while the view lives) and the node's index among the
// nodes it created, then the item's index in the node's drawing.

/// A node's own drawing, in its coordinates, for its placed size.
package typealias NodeDraw = (inout DrawRecorder, CGSize) -> Void

/// Collects the items of one node's drawing.
package struct DrawRecorder {
    package var items: [DisplayItem] = []
    package let id: DisplayItemID
    /// Text measurement and symbols of the layout pass.
    package let textMeasurer: (any TextMeasurer)?
    package let symbols: (any SymbolProvider)?
    /// True when the root is mirrored for right-to-left layout: text and
    /// images undo the mirroring around their own centre.
    package let mirrored: Bool
    private var counter: UInt64 = 0

    package init(id: DisplayItemID, textMeasurer: (any TextMeasurer)? = nil, symbols: (any SymbolProvider)? = nil, mirrored: Bool = false) {
        self.id = id
        self.textMeasurer = textMeasurer
        self.symbols = symbols
        self.mirrored = mirrored
    }

    package mutating func nextID() -> DisplayItemID {
        counter += 1
        return id.child(counter)
    }

    package mutating func add(_ content: DisplayItem.Content) {
        items.append(DisplayItem(id: nextID(), content))
    }

    /// Adds items that must not be mirrored (text, images) in a group that
    /// flips them back about the centre of `width`.
    package mutating func addUnmirrored(width: CGFloat, _ contents: [DisplayItem.Content]) {
        guard mirrored else {
            for c in contents { add(c) }
            return
        }
        var kids: [DisplayItem] = []
        for c in contents { kids.append(DisplayItem(id: nextID(), c)) }
        let flip = RenderTransform(a: -1, b: 0, c: 0, d: 1, tx: Double(width), ty: 0)
        add(.group(DisplayGroup(transform: flip, children: kids)))
    }
}

/// How a layout node changes the rendering of its children.
package enum NodeRenderEffect {
    /// Clips to a shape in the node's bounds.
    case clip((CGSize) -> Path, eoFill: Bool)
    /// The node's second child is an alpha mask for its first.
    case mask
    case blend(RenderBlendMode)
    /// Composites the children as one layer (opacity and blending apply to
    /// the group); `drawingGroup` also asks the compositor for a layer.
    case compositingGroup(isLayer: Bool)
    case shadow(RenderColor, radius: Double, x: Double, y: Double)
    case blur(radius: Double)
    case colorMultiply(RenderColor)
    case hidden
}

extension ViewGraph {
    /// The display list of the last layout pass, with every animation at
    /// its presented value.
    package func displayList() -> DisplayList {
        var items: [DisplayItem] = []
        let mirror = layoutResult?.mirrorWidth
        let measurer = layout?.textMeasurer ?? TypesetTextMeasurer.shared
        let symbols = layout?.symbols ?? OpenSymbolProvider.shared
        var b = DisplayListBuilder(mirrored: mirror != nil, textMeasurer: measurer, symbols: symbols)
        if let root = layoutResult?.root { b.emit(root, into: &items, parentID: .root, childIndex: 0) }
        for g in ghosts where g.node.isAlive && (g.parent?.isAlive ?? false) {
            beginLowering()
            let nodes = g.node.lower()
            let engine = LayoutEngine(environment: environment, textMeasurer: measurer, symbols: symbols)
            for (i, (n, p)) in zip(nodes, g.placements).enumerated() {
                engine.prepare(n)
                n.place(at: p.origin, size: n.sizeThatFits(p.proposal), proposal: p.proposal, parentTransform: p.parent)
                var ghostItems: [DisplayItem] = []
                b.emit(n, into: &ghostItems, parentID: DisplayItemID.root.child("ghost"), childIndex: i)
                let t = p.parent
                let g = DisplayGroup(transform: RenderTransform(a: Double(t.a), b: Double(t.b), c: Double(t.c), d: Double(t.d),
                                                                tx: Double(t.tx), ty: Double(t.ty)), children: ghostItems)
                items.append(DisplayItem(id: DisplayItemID.root.child("ghost").child(UInt64(i)), .group(g)))
            }
        }
        if let w = mirror {
            let flip = RenderTransform(a: -1, b: 0, c: 0, d: 1, tx: Double(w), ty: 0)
            return DisplayList([DisplayItem(id: DisplayItemID.root.child("rtl"), .group(DisplayGroup(transform: flip, children: items)))])
        }
        return DisplayList(items)
    }
}

@MainActor
package struct DisplayListBuilder {
    let mirrored: Bool
    let textMeasurer: any TextMeasurer
    let symbols: any SymbolProvider

    package init(mirrored: Bool, textMeasurer: any TextMeasurer, symbols: any SymbolProvider) {
        self.mirrored = mirrored
        self.textMeasurer = textMeasurer
        self.symbols = symbols
    }

    static func itemID(_ n: LayoutNode, parent: DisplayItemID, childIndex: Int) -> DisplayItemID {
        if let creator = n.creator {
            let raw = UInt64(UInt(bitPattern: ObjectIdentifier(creator).hashValue))
            return DisplayItemID(raw).child(UInt64(n.creatorIndex))
        }
        return parent.child(UInt64(childIndex))
    }

    package mutating func emit(_ n: LayoutNode, into out: inout [DisplayItem], parentID: DisplayItemID, childIndex: Int) {
        guard let origin = n.placedLocalOrigin, let placedSize = n.placedSize else { return }
        if n.renderEffects.contains(where: { if case .hidden = $0 { return true } else { return false } }) { return }
        var local = CGRect(origin: origin, size: placedSize)
        if let creator = n.creator as? ViewNode, let f = creator.presentedFrame(index: n.creatorIndex) { local = f }
        let size = local.size
        let id = Self.itemID(n, parent: parentID, childIndex: childIndex)

        var opacity = 1.0
        var childTransform: RenderTransform?
        switch n.presentation {
        case .opacity(let f)?:
            opacity = f()
        case .transform(let f)?:
            childTransform = f(size).render
        case nil:
            if let ct = n.behavior.childTransform(size: size) { childTransform = ct.render }
            if let o = n.behavior as? OpacityBehavior { opacity = o.opacity }
        }

        var content: [DisplayItem] = []
        if let draw = n.draw {
            var rec = DrawRecorder(id: id, textMeasurer: textMeasurer, symbols: symbols, mirrored: mirrored)
            draw(&rec, size)
            content = rec.items
        }

        let isMask = n.renderEffects.contains { if case .mask = $0 { return true } else { return false } }
        var order = Array(n.children.indices)
        if let sec = n.behavior as? SecondaryLayerBehavior, sec.isBackground, order.count == 2 { order = [1, 0] }
        var kids: [DisplayItem] = []
        var maskItems: [DisplayItem] = []
        for i in order {
            if isMask && i == 1 {
                emit(n.children[i], into: &maskItems, parentID: id, childIndex: i)
            } else {
                emit(n.children[i], into: &kids, parentID: id, childIndex: i)
            }
        }
        if let ct = childTransform, !ct.isIdentity, !kids.isEmpty {
            if ct.b == 0 && ct.c == 0 && ct.a == 1 && ct.d == 1 {
                kids = kids.map { $0.translated(ct.tx, ct.ty) }
            } else {
                kids = [DisplayItem(id: id.child("transform"), .group(DisplayGroup(transform: ct, children: kids)))]
            }
        }
        content += kids

        var g = DisplayGroup(opacity: opacity, children: content)
        if n.behavior is ClipBehavior { g.clips.append(RenderClip(path: RenderPath(rect: CGRect(origin: .zero, size: size)))) }
        if isMask { g.mask = DisplayList(maskItems) }
        for e in n.renderEffects {
            switch e {
            case let .clip(shape, eo):
                g.clips.append(RenderClip(path: shape(size).renderPath, fillRule: eo ? .evenOdd : .nonZero))
            case .mask, .hidden:
                break
            case .blend(let m):
                g.blendMode = m
            case .compositingGroup(let layer):
                g.isLayer = g.isLayer || layer
            case let .shadow(c, r, x, y):
                g.effects.append(.shadow(color: c, radius: r, x: x, y: y))
            case .blur(let r):
                g.effects.append(.blur(radius: r))
            case .colorMultiply(let c):
                g.children = g.children.map { $0.multiplyingColors(by: c) }
            }
        }
        if g.opacity <= 0 && g.effects.isEmpty { return }
        let dx = Double(local.minX), dy = Double(local.minY)
        if g.isPlain {
            out.append(contentsOf: g.children.map { $0.translated(dx, dy) })
        } else {
            g.transform = .translation(dx, dy)
            out.append(DisplayItem(id: id, .group(g)))
        }
    }
}

extension AffineTransform2D {
    package var render: RenderTransform {
        RenderTransform(a: Double(a), b: Double(b), c: Double(c), d: Double(d), tx: Double(tx), ty: Double(ty))
    }
}

// MARK: - Text

/// Glyph outlines of an OVText face for the rasteriser.
final class FaceGlyphSource: GlyphOutlineSource, @unchecked Sendable {
    let face: any FontFace
    let unitsPerEm: Double
    init(_ face: any FontFace) {
        self.face = face
        unitsPerEm = face.designUnitsPerEm
    }
    func outline(of glyph: UInt32) -> RenderPath? {
        guard let els = face.outline(of: glyph), !els.isEmpty else { return nil }
        return RenderPath(els.map { e in
            switch e {
            case let .move(x, y): return .move(CGPoint(x: x, y: y))
            case let .line(x, y): return .line(CGPoint(x: x, y: y))
            case let .quad(x, y, cx, cy): return .quad(CGPoint(x: x, y: y), control: CGPoint(x: cx, y: cy))
            case .close: return .close
            }
        })
    }

    private static let cache = Mutex<[ObjectIdentifier: FaceGlyphSource]>([:])
    static func source(for face: any FontFace) -> FaceGlyphSource {
        cache.withLock { c in
            if let s = c[ObjectIdentifier(face)] { return s }
            let s = FaceGlyphSource(face)
            c[ObjectIdentifier(face)] = s
            return s
        }
    }
}

/// The drawing of a text: one glyph run per stretch of clusters that share
/// face, size, baseline offset and colour.
package func textDraw(_ text: ResolvedText, environment: EnvironmentValues) -> NodeDraw {
    { rec, size in
        guard let tm = rec.textMeasurer as? TypesetTextMeasurer, !text.string.isEmpty else { return }
        let (layout, lines) = tm.placedLayout(text, size: size)
        let bounds = CGRect(origin: .zero, size: size)
        let defaultPaint = environment.foregroundPaint(bounds: bounds, level: 0) ?? .color(.black)
        struct Key: Equatable {
            let face: ObjectIdentifier, size: Double, offset: Double, color: Color.Resolved?, italic: Bool
        }
        var contents: [DisplayItem.Content] = []
        var current: (key: Key, face: any FontFace, glyphs: [UInt32], positions: [CGPoint])?
        func flush() {
            guard let c = current, !c.glyphs.isEmpty else { return }
            let paint = c.key.color.map { RenderPaint.color($0.renderColor) } ?? defaultPaint
            contents.append(.glyphs(RenderGlyphRun(source: GlyphSourceRef(FaceGlyphSource.source(for: c.face)), size: c.key.size,
                                                   glyphs: c.glyphs, positions: c.positions, paint: paint,
                                                   shear: c.key.italic ? 0.2 : 0)))
            current = nil
        }
        func put(glyph: UInt32, face: any FontFace, run: ResolvedText.Run, x: Double, baseline: Double) {
            let fontSize = Double(run.font.size) * layout.scale
            let italic = run.font.isItalic && !face.traits.isItalic
            let key = Key(face: ObjectIdentifier(face), size: fontSize, offset: Double(run.baselineOffset), color: run.color, italic: italic)
            if current?.key != key {
                flush()
                current = (key, face, [], [])
            }
            current?.glyphs.append(glyph)
            current?.positions.append(CGPoint(x: x, y: baseline - Double(run.baselineOffset)))
        }
        func ellipsis(run: ResolvedText.Run, x: inout Double, baseline: Double) {
            let face = (rec.textMeasurer as? TypesetTextMeasurer).map { $0.fonts.face(for: run.font) }
            guard let face, let g = face.glyph(for: "\u{2026}") else { return }
            let s = Double(run.font.size) * layout.scale
            put(glyph: g, face: face, run: run, x: x, baseline: baseline)
            x += face.advance(of: g, size: s)
        }
        for pl in lines {
            var x = Double(pl.origin.x)
            let baseline = Double(pl.origin.y)
            let line = pl.line
            let lastRun = line.range.isEmpty ? text.runs.last : text.runs[min(layout.clusters[line.range.upperBound - 1].run, text.runs.count - 1)]
            if case .before = line.ellipsis, let r = text.runs.first { ellipsis(run: r, x: &x, baseline: baseline) }
            for (k, idx) in line.visualOrder.enumerated() {
                if case .inMiddle(let at) = line.ellipsis, k == at, let r = lastRun { ellipsis(run: r, x: &x, baseline: baseline) }
                let c = layout.clusters[idx]
                let run = text.runs[min(c.run, text.runs.count - 1)]
                if !c.character.isWhitespace { put(glyph: c.glyph, face: c.face, run: run, x: x, baseline: baseline) }
                x += c.advance + c.kernAfter
            }
            if case .after = line.ellipsis, let r = lastRun { ellipsis(run: r, x: &x, baseline: baseline) }
        }
        flush()
        rec.addUnmirrored(width: size.width, contents)
    }
}
