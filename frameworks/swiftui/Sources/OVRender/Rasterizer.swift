// The software rasteriser: display lists to pixels with ThorVG's CPU engine
// (09-open-design.md §5.1; vendored as CThorVG, MIT). It is the reference
// renderer for image tests, the headless back end, and the content source of
// the Vulkan compositor's layers.
//
// Mapping (09 §3.6 lists what ThorVG cannot do):
// - fill / stroke → a Shape with the path (quadratic segments become cubics);
//   colours and gradients → solid fills and Linear/Radial/Conic gradients.
// - glyph runs → one Shape with the outlines of all glyphs (cached per
//   source and glyph), filled with the run's paint. (R13) A run in a solid
//   colour under a translation and uniform scale is drawn once into an image
//   at its device size and sub-pixel phase (1/64 pixel, ThorVG's own
//   precision) and then placed as a Picture at whole pixels: scrolling text
//   (an editor's lines) reuses the images instead of filling thousands of
//   glyph outlines every frame. The images are kept by run content, size,
//   colour and phase (least recently used ones go past 48 MB).
// - images → a Picture loaded from pixels decoded once per `RenderImage`.
// - groups → a Scene with the transform, opacity, blend method, clip shapes
//   (nested scenes when there are several), an alpha mask scene, and scene
//   effects (Gaussian blur, drop shadow).
// Colours are composited in the sRGB transfer space with premultiplied
// 8-bit channels, as ThorVG does.

import CThorVG
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// ThorVG's engine is global; it is initialised once (no worker threads, so
/// rendering is deterministic).
private let thorvgReady: Bool = tvg_engine_init(0) == TVG_RESULT_SUCCESS

/// Rasterises display lists on the CPU. Not thread-safe: use one per thread.
public final class SoftwareRasterizer {
    /// Decoded image pixels (premultiplied ABGR8888 words) per image.
    private final class DecodedImage {
        weak var image: RenderImage?
        let size: PixelSize
        let words: UnsafeMutableBufferPointer<UInt32>
        init(image: RenderImage, size: PixelSize, words: UnsafeMutableBufferPointer<UInt32>) {
            self.image = image
            self.size = size
            self.words = words
        }
        deinit { words.deallocate() }
    }

    private struct GlyphKey: Hashable {
        let source: ObjectIdentifier
        let glyph: UInt32
    }

    /// A glyph run drawn into premultiplied ABGR8888 pixels (R13).
    private final class RunImage {
        let words: UnsafeMutableBufferPointer<UInt32>
        let width: Int, height: Int
        /// The image's top-left corner relative to the whole-pixel part of
        /// the run's device origin.
        let originX: Int, originY: Int
        var lastUse = 0
        init(width: Int, height: Int, originX: Int, originY: Int) {
            self.width = width
            self.height = height
            self.originX = originX
            self.originY = originY
            words = .allocate(capacity: width * height)
            words.initialize(repeating: 0)
        }
        var bytes: Int { width * height * 4 }
        deinit { words.deallocate() }
    }

    private struct RunKey: Hashable {
        let source: ObjectIdentifier
        let size: Int64            // device pixels per em × 64
        let shear: Int32
        let color: UInt32
        let phaseX: Int8, phaseY: Int8 // 1/64 pixel
        let glyphs: [UInt32]
        let offsets: [Int32]       // device positions relative to the first glyph × 64, x then y
    }

    private var images: [ObjectIdentifier: DecodedImage] = [:]
    private var glyphs: [GlyphKey: RenderPath] = [:]
    private var runImages: [RunKey: RunImage] = [:]
    private var runImageBytes = 0
    private var renderCount = 0
    /// The transform from the item being converted to device pixels.
    private var deviceTransform = RenderTransform.identity
    /// Run images drawn and reused, and runs seen for the first time, in
    /// the last call (tests, benchmarks).
    public private(set) var runImageStats = (drawn: 0, reused: 0, firstSeen: 0)
    private var seenRuns: Set<RunKey> = []
    /// The canvas run images are drawn with (reused).
    private var runCanvas: Tvg_Canvas?
    /// R13: whether solid glyph runs go through the run image cache.
    public var cachesGlyphRuns = true
    private var glyphSources: [ObjectIdentifier: GlyphSourceRef] = [:]
    /// Things ThorVG could not render in the last call (reported once each).
    public private(set) var unsupported: Set<String> = []

    public init() {}

    deinit { if let c = runCanvas { tvg_canvas_destroy(c) } }

    /// Renders `frame` into a new image of `size` pixels.
    public func render(_ frame: RenderFrame, size: PixelSize) -> PixelImage {
        var image = PixelImage(size: size)
        render(frame.displayList, into: &image, scale: frame.scale, background: frame.background, region: nil)
        return image
    }

    /// Renders `list` into `image`. With `region`, only those pixels are
    /// cleared and redrawn; the rest of `image` is kept.
    public func render(_ list: DisplayList, into image: inout PixelImage, scale: Double,
                       background: RenderColor, region: PixelRect?) {
        unsupported = []
        let full = PixelRect(x: 0, y: 0, width: image.size.width, height: image.size.height)
        let area = (region ?? full).intersection(full)
        guard !area.isEmpty else { return }
        clear(&image, area: area, to: background)
        guard thorvgReady, !list.isEmpty else { return }
        let w = UInt32(image.size.width), h = UInt32(image.size.height)
        image.rgba.withUnsafeMutableBytes { raw in
            let words = raw.bindMemory(to: UInt32.self)
            guard let canvas = tvg_swcanvas_create(TVG_ENGINE_OPTION_DEFAULT) else { return }
            defer { tvg_canvas_destroy(canvas) }
            guard tvg_swcanvas_set_target(canvas, words.baseAddress, w, w, h, TVG_COLORSPACE_ABGR8888) == TVG_RESULT_SUCCESS
            else { return }
            if area != full {
                tvg_canvas_set_viewport(canvas, Int32(area.x), Int32(area.y), Int32(area.width), Int32(area.height))
            }
            guard let root = tvg_scene_new() else { return }
            var m = Self.matrix(.scale(scale, scale))
            tvg_paint_set_transform(root, &m)
            renderCount += 1
            runImageStats = (0, 0, 0)
            deviceTransform = .scale(scale, scale)
            for item in list.items { if let p = paint(for: item) { tvg_scene_add(root, p) } }
            tvg_canvas_add(canvas, root)
            tvg_canvas_update(canvas)
            tvg_canvas_draw(canvas, false)
            tvg_canvas_sync(canvas)
        }
        pruneCaches()
    }

    // MARK: - Items

    private func paint(for item: DisplayItem) -> Tvg_Paint? {
        switch item.content {
        case let .fill(path, paint, rule):
            guard let s = shape(path) else { return nil }
            setFill(s, paint)
            tvg_shape_set_fill_rule(s, rule == .evenOdd ? TVG_FILL_RULE_EVEN_ODD : TVG_FILL_RULE_NON_ZERO)
            return s
        case let .stroke(path, paint, stroke):
            guard stroke.lineWidth > 0, let s = shape(path) else { return nil }
            setStroke(s, paint, stroke)
            return s
        case .glyphs(let run):
            return glyphShape(run)
        case let .image(img, rect, interpolation, opacity):
            return picture(img, rect: rect, interpolation: interpolation, opacity: opacity)
        case .group(let g):
            return scene(for: g)
        case .placeholder:
            return nil
        }
    }

    private func scene(for g: DisplayGroup) -> Tvg_Paint? {
        guard g.opacity > 0, let content = tvg_scene_new() else { return nil }
        let outerTransform = deviceTransform
        deviceTransform = outerTransform.concatenating(g.transform)
        defer { deviceTransform = outerTransform }
        for c in g.children { if let p = paint(for: c) { tvg_scene_add(content, p) } }
        // Clips and the mask are in the group's local coordinates (the
        // children's), so they apply to untransformed wrapper scenes; the
        // transform goes on the outermost scene.
        var node = content
        var wrapped = false
        func wrap() {
            if let outer = tvg_scene_new() {
                tvg_scene_add(outer, node)
                node = outer
            }
        }
        for clip in g.clips {
            guard let s = shape(clip.path) else { continue }
            if let st = clip.stroke {
                setStroke(s, .color(.white), st)
            } else {
                tvg_shape_set_fill_color(s, 255, 255, 255, 255)
                tvg_shape_set_fill_rule(s, clip.fillRule == .evenOdd ? TVG_FILL_RULE_EVEN_ODD : TVG_FILL_RULE_NON_ZERO)
            }
            if wrapped { wrap() }
            if clip.inverse {
                tvg_paint_set_mask_method(node, s, TVG_MASK_METHOD_INVERSE_ALPHA)
            } else if clip.stroke != nil {
                tvg_paint_set_mask_method(node, s, TVG_MASK_METHOD_ALPHA)
            } else {
                tvg_paint_set_clip(node, s)
            }
            wrapped = true
        }
        if let mask = g.mask, let ms = tvg_scene_new() {
            for c in mask.items { if let p = paint(for: c) { tvg_scene_add(ms, p) } }
            if wrapped { wrap() }
            tvg_paint_set_mask_method(node, ms, TVG_MASK_METHOD_ALPHA)
            wrapped = true
        }
        if wrapped && (!g.transform.isIdentity || !g.effects.isEmpty || g.opacity < 1 || g.blendMode != .normal) { wrap() }
        var m = Self.matrix(g.transform)
        tvg_paint_set_transform(node, &m)
        for e in g.effects {
            switch e {
            case .blur(let radius):
                if radius > 0 { tvg_scene_add_effect_gaussian_blur(node, radius / 2, 0, 0, 100) }
            case let .shadow(color, radius, x, y):
                let (r, gg, b, a) = color.rgba8
                let distance = (x * x + y * y).squareRoot()
                // ThorVG measures the shadow direction clockwise from "up".
                var angle = atan2(x, -y) * 180 / .pi
                if angle < 0 { angle += 360 }
                tvg_scene_add_effect_drop_shadow(node, Int32(r), Int32(gg), Int32(b), Int32(a), angle, distance, max(radius / 2, 0.01), 100)
            case .colorMultiply:
                unsupported.insert("colorMultiply effect")
            }
        }
        if g.opacity < 1 { tvg_paint_set_opacity(node, UInt8(max(0, min(255, (g.opacity * 255).rounded())))) }
        if g.blendMode != .normal { tvg_paint_set_blend_method(node, Self.blend(g.blendMode)) }
        return node
    }

    private func picture(_ img: RenderImage, rect: CGRect, interpolation: RenderInterpolation, opacity: Double) -> Tvg_Paint? {
        guard opacity > 0, rect.width > 0, rect.height > 0, let decoded = decode(img), let pic = tvg_picture_new() else { return nil }
        guard tvg_picture_load_raw(pic, decoded.words.baseAddress, UInt32(decoded.size.width), UInt32(decoded.size.height),
                                   TVG_COLORSPACE_ABGR8888, false) == TVG_RESULT_SUCCESS else {
            tvg_paint_rel(pic)
            return nil
        }
        tvg_picture_set_size(pic, Float(rect.width), Float(rect.height))
        tvg_picture_set_filter(pic, interpolation == .none ? TVG_FILTER_METHOD_NEAREST : TVG_FILTER_METHOD_BILINEAR)
        var m = Self.matrix(.translation(rect.minX, rect.minY))
        tvg_paint_set_transform(pic, &m)
        if opacity < 1 { tvg_paint_set_opacity(pic, UInt8((opacity * 255).rounded())) }
        return pic
    }

    private func glyphShape(_ run: RenderGlyphRun) -> Tvg_Paint? {
        if cachesGlyphRuns, let p = cachedRunPicture(run) { return p }
        let src = run.source.source
        let s = run.size / src.unitsPerEm
        var all = RenderPath()
        let key = ObjectIdentifier(src)
        glyphSources[key] = run.source
        for (g, p) in zip(run.glyphs, run.positions) {
            let gk = GlyphKey(source: key, glyph: g)
            let outline: RenderPath
            if let cached = glyphs[gk] { outline = cached } else {
                outline = src.outline(of: g) ?? RenderPath()
                glyphs[gk] = outline
            }
            if outline.isEmpty { continue }
            // Design units (y up) → item coordinates (y down) at the origin.
            let t = RenderTransform(a: s, b: 0, c: -run.shear * s, d: -s, tx: p.x, ty: p.y)
            all.elements.append(contentsOf: outline.applying(t).elements)
        }
        guard !all.isEmpty, let shape = shape(all) else { return nil }
        setFill(shape, run.paint)
        return shape
    }

    private func outline(_ src: any GlyphOutlineSource, _ key: ObjectIdentifier, _ g: UInt32) -> RenderPath {
        let gk = GlyphKey(source: key, glyph: g)
        if let cached = glyphs[gk] { return cached }
        let o = src.outline(of: g) ?? RenderPath()
        glyphs[gk] = o
        return o
    }

    /// The run as a Picture of its cached image (nil: draw it as a shape).
    private func cachedRunPicture(_ run: RenderGlyphRun) -> Tvg_Paint? {
        let t = deviceTransform
        guard case .color(let color) = run.paint, t.b == 0, t.c == 0, t.a > 0, abs(t.a - t.d) < 1e-9,
              let p0 = run.positions.first, !run.glyphs.isEmpty, run.glyphs.count <= 1024 else { return nil }
        let scale = t.a
        let src = run.source.source
        let srcKey = ObjectIdentifier(src)
        glyphSources[srcKey] = run.source
        let device = t.apply(p0)
        let whole = CGPoint(x: device.x.rounded(.down), y: device.y.rounded(.down))
        let phaseX = Int8(((device.x - whole.x) * 64).rounded(.down)), phaseY = Int8(((device.y - whole.y) * 64).rounded(.down))
        var offsets: [Int32] = []
        offsets.reserveCapacity(run.positions.count * 2)
        for p in run.positions {
            offsets.append(Int32(((p.x - p0.x) * scale * 64).rounded()))
            offsets.append(Int32(((p.y - p0.y) * scale * 64).rounded()))
        }
        let (r, g, b, a) = color.rgba8
        let key = RunKey(source: srcKey, size: Int64((run.size * scale * 64).rounded()), shear: Int32((run.shear * 1024).rounded()),
                         color: UInt32(r) << 24 | UInt32(g) << 16 | UInt32(b) << 8 | UInt32(a), phaseX: phaseX, phaseY: phaseY,
                         glyphs: run.glyphs, offsets: offsets)
        let image: RunImage
        if let cached = runImages[key] {
            image = cached
            runImageStats.reused += 1
        } else if !seenRuns.contains(key) {
            // First sighting: drawn as a shape (a page jump shows only new
            // lines; drawing them into images would cost more than it
            // saves). Seen again in a later call, it gets its image.
            seenRuns.insert(key)
            if seenRuns.count > 50_000 { seenRuns.removeAll(keepingCapacity: true) }
            runImageStats.firstSeen += 1
            return nil
        } else {
            // The outlines exactly as the shape path draws them (item
            // coordinates under the device transform), moved by whole
            // pixels into the image, so that the coverage is the same.
            let s = run.size / src.unitsPerEm
            var all = RenderPath()
            for (gl, p) in zip(run.glyphs, run.positions) {
                let o = outline(src, srcKey, gl)
                if o.isEmpty { continue }
                all.elements.append(contentsOf: o.applying(RenderTransform(a: s, b: 0, c: -run.shear * s, d: -s, tx: p.x, ty: p.y)).elements)
            }
            guard !all.isEmpty else { return nil }
            let bounds = t.boundingBox(of: all.controlBounds)
            guard bounds.width.isFinite, bounds.height.isFinite else { return nil }
            let ox = Int((bounds.minX - whole.x).rounded(.down)) - 1, oy = Int((bounds.minY - whole.y).rounded(.down)) - 1
            let w = Int((bounds.maxX - whole.x).rounded(.up)) - ox + 1, h = Int((bounds.maxY - whole.y).rounded(.up)) - oy + 1
            guard w > 0, h > 0, w * h <= 4096 * 512 else { return nil }
            image = RunImage(width: w, height: h, originX: ox, originY: oy)
            if runCanvas == nil { runCanvas = tvg_swcanvas_create(TVG_ENGINE_OPTION_DEFAULT) }
            guard let canvas = runCanvas else { return nil }
            defer { tvg_canvas_remove(canvas, nil) }
            guard tvg_swcanvas_set_target(canvas, image.words.baseAddress, UInt32(w), UInt32(w), UInt32(h),
                                          TVG_COLORSPACE_ABGR8888) == TVG_RESULT_SUCCESS,
                  let shape = shape(all) else { return nil }
            var m = Self.matrix(RenderTransform.translation(-(whole.x + Double(ox)), -(whole.y + Double(oy))).concatenating(t))
            tvg_paint_set_transform(shape, &m)
            tvg_shape_set_fill_color(shape, r, g, b, a)
            tvg_canvas_add(canvas, shape)
            tvg_canvas_update(canvas)
            tvg_canvas_draw(canvas, false)
            tvg_canvas_sync(canvas)
            runImages[key] = image
            runImageBytes += image.bytes
            runImageStats.drawn += 1
        }
        image.lastUse = renderCount
        guard let pic = tvg_picture_new() else { return nil }
        guard tvg_picture_load_raw(pic, image.words.baseAddress, UInt32(image.width), UInt32(image.height),
                                   TVG_COLORSPACE_ABGR8888, false) == TVG_RESULT_SUCCESS else {
            tvg_paint_rel(pic)
            return nil
        }
        // In the item's coordinates: device (whole + origin) maps back
        // through the device transform's inverse.
        tvg_picture_set_size(pic, Float(Double(image.width) / scale), Float(Double(image.height) / scale))
        tvg_picture_set_filter(pic, TVG_FILTER_METHOD_NEAREST)
        let lx = p0.x + (whole.x + Double(image.originX) - device.x) / scale
        let ly = p0.y + (whole.y + Double(image.originY) - device.y) / scale
        var m = Self.matrix(.translation(lx, ly))
        tvg_paint_set_transform(pic, &m)
        return pic
    }

    // MARK: - Paths and paints

    private func shape(_ path: RenderPath) -> Tvg_Paint? {
        guard !path.isEmpty, let s = tvg_shape_new() else { return nil }
        var cmds: [Tvg_Path_Command] = []
        var pts: [Tvg_Point] = []
        cmds.reserveCapacity(path.elements.count)
        pts.reserveCapacity(path.elements.count * 3)
        var current = CGPoint.zero, start = CGPoint.zero
        func pt(_ p: CGPoint) -> Tvg_Point { Tvg_Point(x: Float(p.x), y: Float(p.y)) }
        for e in path.elements {
            switch e {
            case .move(let p):
                cmds.append(Tvg_Path_Command(TVG_PATH_COMMAND_MOVE_TO))
                pts.append(pt(p))
                current = p
                start = p
            case .line(let p):
                cmds.append(Tvg_Path_Command(TVG_PATH_COMMAND_LINE_TO))
                pts.append(pt(p))
                current = p
            case let .quad(p, c):
                let c1 = CGPoint(x: current.x + 2 / 3 * (c.x - current.x), y: current.y + 2 / 3 * (c.y - current.y))
                let c2 = CGPoint(x: p.x + 2 / 3 * (c.x - p.x), y: p.y + 2 / 3 * (c.y - p.y))
                cmds.append(Tvg_Path_Command(TVG_PATH_COMMAND_CUBIC_TO))
                pts.append(contentsOf: [pt(c1), pt(c2), pt(p)])
                current = p
            case let .cubic(p, c1, c2):
                cmds.append(Tvg_Path_Command(TVG_PATH_COMMAND_CUBIC_TO))
                pts.append(contentsOf: [pt(c1), pt(c2), pt(p)])
                current = p
            case .close:
                cmds.append(Tvg_Path_Command(TVG_PATH_COMMAND_CLOSE))
                current = start
            }
        }
        tvg_shape_append_path(s, cmds, UInt32(cmds.count), pts, UInt32(pts.count))
        return s
    }

    private func setFill(_ s: Tvg_Paint, _ paint: RenderPaint) {
        if case .color(let c) = paint {
            let (r, g, b, a) = c.rgba8
            tvg_shape_set_fill_color(s, r, g, b, a)
        } else if let grad = gradient(paint) {
            tvg_shape_set_gradient(s, grad)
        }
    }

    private func setStroke(_ s: Tvg_Paint, _ paint: RenderPaint, _ st: RenderStroke) {
        tvg_shape_set_fill_color(s, 0, 0, 0, 0)
        tvg_shape_set_stroke_width(s, Float(st.lineWidth))
        if case .color(let c) = paint {
            let (r, g, b, a) = c.rgba8
            tvg_shape_set_stroke_color(s, r, g, b, a)
        } else if let grad = gradient(paint) {
            tvg_shape_set_stroke_gradient(s, grad)
        }
        tvg_shape_set_stroke_cap(s, st.lineCap == .round ? TVG_STROKE_CAP_ROUND : st.lineCap == .square ? TVG_STROKE_CAP_SQUARE : TVG_STROKE_CAP_BUTT)
        tvg_shape_set_stroke_join(s, st.lineJoin == .round ? TVG_STROKE_JOIN_ROUND : st.lineJoin == .bevel ? TVG_STROKE_JOIN_BEVEL : TVG_STROKE_JOIN_MITER)
        tvg_shape_set_stroke_miterlimit(s, Float(max(1, st.miterLimit)))
        let dash = st.dash.filter { $0 >= 0 }.map { Float($0) }
        if !dash.isEmpty, dash.contains(where: { $0 > 0 }) {
            tvg_shape_set_stroke_dash(s, dash, UInt32(dash.count), Float(st.dashPhase))
        }
    }

    private func gradient(_ paint: RenderPaint) -> Tvg_Gradient? {
        func stops(_ s: [RenderGradientStop]) -> [Tvg_Color_Stop] {
            s.map { st in
                let (r, g, b, a) = st.color.rgba8
                return Tvg_Color_Stop(offset: Float(max(0, min(1, st.location))), r: r, g: g, b: b, a: a)
            }
        }
        func spread(_ sp: RenderSpread) -> Tvg_Stroke_Fill {
            switch sp {
            case .pad: return TVG_STROKE_FILL_PAD
            case .repeat: return TVG_STROKE_FILL_REPEAT
            case .reflect: return TVG_STROKE_FILL_REFLECT
            }
        }
        switch paint {
        case .color:
            return nil
        case let .linearGradient(s, a, b, sp):
            guard let g = tvg_linear_gradient_new() else { return nil }
            tvg_linear_gradient_set(g, Float(a.x), Float(a.y), Float(b.x), Float(b.y))
            let cs = stops(s)
            tvg_gradient_set_color_stops(g, cs, UInt32(cs.count))
            tvg_gradient_set_spread(g, spread(sp))
            return g
        case let .radialGradient(s, c, r0, r1, sp):
            guard let g = tvg_radial_gradient_new() else { return nil }
            // ThorVG's radial gradient runs from the focal radius (0) to the
            // outer radius (1); SwiftUI's start radius maps to the focal one.
            tvg_radial_gradient_set(g, Float(c.x), Float(c.y), Float(max(r1, 0.0001)), Float(c.x), Float(c.y), Float(max(0, min(r0, r1))))
            let cs = stops(s)
            tvg_gradient_set_color_stops(g, cs, UInt32(cs.count))
            tvg_gradient_set_spread(g, spread(sp))
            return g
        case let .conicGradient(s, c, a0, a1):
            guard let g = tvg_conic_gradient_new() else { return nil }
            tvg_conic_gradient_set(g, Float(c.x), Float(c.y), Float(a0 * 180 / .pi))
            let cs = stops(Self.conicStops(s, sweep: a1 - a0))
            tvg_gradient_set_color_stops(g, cs, UInt32(cs.count))
            return g
        }
    }

    /// Maps stops of a sweep shorter than a full turn onto ThorVG's full
    /// turn. Ycode's choice for the uncovered part: the end colour up to the
    /// middle of the gap, the start colour after it.
    static func conicStops(_ s: [RenderGradientStop], sweep: Double) -> [RenderGradientStop] {
        let turn = 2 * Double.pi
        guard sweep > 0, sweep < turn - 1e-9, let first = s.first, let last = s.last else { return s }
        let f = sweep / turn
        var out = s.map { RenderGradientStop(color: $0.color, location: $0.location * f) }
        let mid = f + (1 - f) / 2
        out.append(RenderGradientStop(color: last.color, location: mid))
        out.append(RenderGradientStop(color: first.color, location: min(1, mid + 1e-4)))
        out.append(RenderGradientStop(color: first.color, location: 1))
        return out
    }

    static func blend(_ b: RenderBlendMode) -> Tvg_Blend_Method {
        switch b {
        case .normal: return TVG_BLEND_METHOD_NORMAL
        case .multiply: return TVG_BLEND_METHOD_MULTIPLY
        case .screen: return TVG_BLEND_METHOD_SCREEN
        case .overlay: return TVG_BLEND_METHOD_OVERLAY
        case .darken: return TVG_BLEND_METHOD_DARKEN
        case .lighten: return TVG_BLEND_METHOD_LIGHTEN
        case .colorDodge: return TVG_BLEND_METHOD_COLORDODGE
        case .colorBurn: return TVG_BLEND_METHOD_COLORBURN
        case .softLight: return TVG_BLEND_METHOD_SOFTLIGHT
        case .hardLight: return TVG_BLEND_METHOD_HARDLIGHT
        case .difference: return TVG_BLEND_METHOD_DIFFERENCE
        case .exclusion: return TVG_BLEND_METHOD_EXCLUSION
        case .hue: return TVG_BLEND_METHOD_HUE
        case .saturation: return TVG_BLEND_METHOD_SATURATION
        case .color: return TVG_BLEND_METHOD_COLOR
        case .luminosity: return TVG_BLEND_METHOD_LUMINOSITY
        case .plusLighter: return TVG_BLEND_METHOD_ADD
        }
    }

    static func matrix(_ t: RenderTransform) -> Tvg_Matrix {
        Tvg_Matrix(e11: Float(t.a), e12: Float(t.c), e13: Float(t.tx),
                   e21: Float(t.b), e22: Float(t.d), e23: Float(t.ty),
                   e31: 0, e32: 0, e33: 1)
    }

    // MARK: - Images

    private func decode(_ img: RenderImage) -> DecodedImage? {
        let key = ObjectIdentifier(img)
        if let d = images[key], d.image === img { return d }
        guard let px = Self.decodePixels(img) else { return nil }
        let words = UnsafeMutableBufferPointer<UInt32>.allocate(capacity: px.size.width * px.size.height)
        px.rgba.withUnsafeBytes { src in
            UnsafeMutableRawBufferPointer(words).copyMemory(from: src)
        }
        let d = DecodedImage(image: img, size: px.size, words: words)
        images[key] = d
        return d
    }

    /// The pixels of an image (premultiplied RGBA8); PNG and JPEG are decoded
    /// by ThorVG's loaders (lodepng and jpgd).
    public static func decodePixels(_ img: RenderImage) -> PixelImage? {
        switch img.source {
        case .pixels(let p): return p
        case .png(let data): return decode(data, mime: "png")
        case .jpeg(let data): return decode(data, mime: "jpg")
        }
    }

    /// Decodes PNG or JPEG bytes to premultiplied RGBA8.
    public static func decode(_ data: Data, mime: String) -> PixelImage? {
        guard thorvgReady, let pic = tvg_picture_new() else { return nil }
        let ok = data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return false }
            return tvg_picture_load_data(pic, base, UInt32(raw.count), mime, nil, true) == TVG_RESULT_SUCCESS
        }
        var w: Float = 0, h: Float = 0
        guard ok, tvg_picture_get_size(pic, &w, &h) == TVG_RESULT_SUCCESS, w >= 1, h >= 1 else {
            tvg_paint_rel(pic)
            return nil
        }
        let size = PixelSize(width: Int(w), height: Int(h))
        var out = PixelImage(size: size)
        out.rgba.withUnsafeMutableBytes { raw in
            let words = raw.bindMemory(to: UInt32.self)
            guard let canvas = tvg_swcanvas_create(TVG_ENGINE_OPTION_DEFAULT) else {
                tvg_paint_rel(pic)
                return
            }
            defer { tvg_canvas_destroy(canvas) }
            tvg_swcanvas_set_target(canvas, words.baseAddress, UInt32(size.width), UInt32(size.width), UInt32(size.height), TVG_COLORSPACE_ABGR8888)
            tvg_picture_set_filter(pic, TVG_FILTER_METHOD_NEAREST)
            tvg_canvas_add(canvas, pic)
            tvg_canvas_update(canvas)
            tvg_canvas_draw(canvas, true)
            tvg_canvas_sync(canvas)
        }
        return out
    }

    private func pruneCaches() {
        images = images.filter { $0.value.image != nil }
        // Run images: the least recently used go past 48 MB (the images of
        // this call are kept: ThorVG has read them by now).
        let limit = 48 << 20
        if runImageBytes > limit {
            let byAge = runImages.sorted { $0.value.lastUse < $1.value.lastUse }
            for (k, v) in byAge where runImageBytes > limit * 3 / 4 && v.lastUse < renderCount {
                runImages[k] = nil
                runImageBytes -= v.bytes
            }
        }
        if glyphs.count > 20_000 {
            glyphs.removeAll(keepingCapacity: true)
            glyphSources.removeAll()
        }
    }

    private func clear(_ image: inout PixelImage, area: PixelRect, to color: RenderColor) {
        let (r, g, b, a) = color.rgba8
        let pr = UInt8((Int(r) * Int(a) + 127) / 255), pg = UInt8((Int(g) * Int(a) + 127) / 255), pb = UInt8((Int(b) * Int(a) + 127) / 255)
        let w = image.size.width
        // One 32-bit word per pixel (R, G, B, A in memory order).
        var word: UInt32 = 0
        withUnsafeMutableBytes(of: &word) { $0[0] = pr; $0[1] = pg; $0[2] = pb; $0[3] = a }
        image.rgba.withUnsafeMutableBytes { raw in
            let px = raw.bindMemory(to: UInt32.self)
            for y in area.y..<area.maxY {
                let start = y * w + area.x
                UnsafeMutableBufferPointer(rebasing: px[start..<(start + area.width)]).update(repeating: word)
            }
        }
    }
}
