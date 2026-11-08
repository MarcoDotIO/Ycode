// The Linux device window's toolbar and Settings inspector
// (cross-platform-parity.md §13; device-hub.md §3, §6, §11.3): OpenViews
// views laid out by `DeviceWindowFrame` and `DeviceInspectorContent`, so the
// window matches the macOS device window, rendered to pixels for the SDL
// window (`RemoteDeviceWindow.chromeRenderer`). The SDL window keeps the
// device's live picture and the control capsules; OpenViews has no view for
// a live picture yet.

#if os(Linux) && canImport(SwiftUI) && canImport(OVRender)
import Foundation
import OVRender
import SwiftUI
import YcodeDeviceModel
import YcodeRemoteViewer

@MainActor
enum DeviceChromeRenderer {
    /// A part of the chrome as straight RGBA pixels at the window's density.
    static func render(_ r: DeviceChromeRequest, _ part: DeviceChromeRequest.Part) -> DeviceChromeImage? {
        let rect = part == .toolbar ? r.frame.toolbar : (r.frame.inspector ?? ViewerRect(x: 0, y: 0, width: 0, height: 0))
        guard rect.width > 0, rect.height > 0 else { return nil }
        let size = CGSize(width: rect.width, height: rect.height)
        let content = Group {
            if part == .toolbar { DeviceToolbarView(request: r) } else { DeviceInspectorView(request: r, size: size) }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .environment(\.colorScheme, r.dark ? .dark : .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = CGFloat(max(1, r.pixelDensity))
        renderer.proposedSize = ProposedViewSize(size)
        renderer.isOpaque = true
        guard let png = renderer.pngData, let px = SoftwareRasterizer.decode(png, mime: "png") else { return nil }
        // The parts are opaque: premultiplied and straight pixels agree.
        return DeviceChromeImage(width: px.size.width, height: px.size.height, rgba: px.rgba)
    }
}

extension Color {
    init(chromeHex hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

/// The toolbar band: the device's name and OS, then the capsules.
struct DeviceToolbarView: View {
    let request: DeviceChromeRequest
    typealias P = DeviceChromePalette

    var body: some View {
        let d = request.dark, f = request.frame
        ZStack(alignment: .topLeading) {
            Color(chromeHex: P.toolbar(dark: d))
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: request.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(chromeHex: P.label(dark: d)))
                    .lineLimit(1)
                if !request.subtitle.isEmpty {
                    Text(verbatim: request.subtitle).font(.system(size: 11)).foregroundStyle(Color(chromeHex: P.secondaryLabel(dark: d)))
                        .lineLimit(1)
                }
            }
            .frame(width: CGFloat(f.titleWidth), height: CGFloat(DeviceWindowFrame.toolbarHeight), alignment: .leading)
            .offset(x: CGFloat(DeviceWindowFrame.titleX))
            ForEach(Array(f.capsules.enumerated()), id: \.offset) { pair in
                capsule(pair.element.items, dark: d)
                    .frame(width: CGFloat(pair.element.rect.width), height: CGFloat(pair.element.rect.height))
                    .offset(x: CGFloat(pair.element.rect.x), y: CGFloat(pair.element.rect.y))
            }
        }
        .frame(width: CGFloat(f.width), height: CGFloat(DeviceWindowFrame.toolbarHeight), alignment: .topLeading)
    }

    func capsule(_ items: [DeviceWindowFrame.Item], dark d: Bool) -> some View {
        let selected = request.selectedItems
        return ZStack {
            Capsule(style: .continuous).fill(Color(chromeHex: P.capsule(dark: d)))
            Capsule(style: .continuous).strokeBorder(Color(chromeHex: P.capsuleRim(dark: d)), lineWidth: 0.5)
            HStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { pair in
                    let item = pair.element
                    let on = selected.contains(item), disabled = DeviceChromeRequest.disabledItems.contains(item)
                    ZStack {
                        if on {
                            Capsule(style: .continuous).fill(Color(chromeHex: P.selected(dark: d)))
                                .padding(.vertical, 4)
                                .padding(.horizontal, 2)
                        }
                        if item == .infoTab {
                            // A plain "i" (§11.4).
                            Text(verbatim: "i").font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Color(chromeHex: P.glyph(dark: d)))
                        } else {
                            ChromeGlyph(name: item.symbol, color: Color(chromeHex: P.glyph(dark: d)).opacity(disabled ? 0.35 : 1), size: 16)
                        }
                    }
                    .frame(width: CGFloat(DeviceWindowFrame.segmentWidth), height: CGFloat(DeviceWindowFrame.capsuleHeight))
                }
            }
        }
    }
}

/// The Settings inspector: the cards and the note under them.
struct DeviceInspectorView: View {
    let request: DeviceChromeRequest
    let size: CGSize
    typealias P = DeviceChromePalette
    typealias C = DeviceInspectorContent

    var body: some View {
        let d = request.dark, content = request.inspector
        let rects = content.cardRects(width: Double(size.width))
        ZStack(alignment: .topLeading) {
            Color(chromeHex: P.inspector(dark: d))
            ForEach(Array(zip(content.cards, rects).enumerated()), id: \.offset) { pair in
                card(pair.element.0, dark: d)
                    .frame(width: CGFloat(pair.element.1.width), height: CGFloat(pair.element.1.height))
                    .offset(x: CGFloat(pair.element.1.x), y: CGFloat(pair.element.1.y))
            }
            if let note = content.note {
                let top = (rects.last.map { $0.y + $0.height + C.cardGap } ?? C.cardTop + 4)
                Text(verbatim: note).font(.system(size: 11)).foregroundStyle(Color(chromeHex: P.secondaryLabel(dark: d)))
                    .multilineTextAlignment(rects.isEmpty ? .center : .leading)
                    .frame(width: size.width - CGFloat(2 * C.cardInset) - 8, alignment: rects.isEmpty ? .center : .leading)
                    .offset(x: CGFloat(C.cardInset) + 4, y: CGFloat(top))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    func card(_ rows: [C.Row], dark d: Bool) -> some View {
        let sep = P.separator(dark: d)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: CGFloat(C.cardRadius), style: .continuous).fill(Color(chromeHex: P.card(dark: d)))
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { pair in
                    if pair.offset > 0 {
                        Rectangle().fill(Color(chromeHex: sep.hex, opacity: sep.alpha)).frame(height: CGFloat(C.separator))
                            .padding(.leading, CGFloat(C.labelX))
                    }
                    row(pair.element, dark: d)
                }
            }
        }
    }

    func row(_ r: C.Row, dark d: Bool) -> some View {
        let ink = Color(chromeHex: P.label(dark: d)).opacity(r.enabled ? 1 : 0.45)
        return ZStack(alignment: .leading) {
            ChromeGlyph(name: r.symbol, color: ink, size: 13)
                .offset(x: CGFloat(C.symbolX))
            Text(verbatim: r.label).font(.system(size: 13)).foregroundStyle(ink).lineLimit(1)
                .offset(x: CGFloat(C.labelX))
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                control(r.control, dark: d).opacity(r.enabled ? 1 : 0.45)
            }
            .padding(.trailing, CGFloat(C.trailing))
        }
        .frame(height: CGFloat(C.rowHeight))
    }

    @ViewBuilder
    func control(_ c: C.Control, dark d: Bool) -> some View {
        let ink = Color(chromeHex: P.label(dark: d)), secondary = Color(chromeHex: P.secondaryLabel(dark: d))
        switch c {
        case .popUp(let value):
            HStack(spacing: 5) {
                Text(verbatim: value).font(.system(size: 13)).foregroundStyle(secondary).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(secondary)
            }
        case .slider(let v):
            ZStack(alignment: .leading) {
                Capsule().fill(secondary.opacity(0.35)).frame(width: 108, height: 4)
                Capsule().fill(Color(chromeHex: 0x007AFF)).frame(width: 108 * CGFloat(v), height: 4)
                Circle().fill(Color.white).frame(width: 16, height: 16).shadow(color: .black.opacity(0.25), radius: 1, x: 0, y: 0.5)
                    .offset(x: 108 * CGFloat(v) - 8)
            }
            .frame(width: 108, height: 16)
        case .toggle(let on):
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule().fill(on ? Color(chromeHex: 0x34C759) : secondary.opacity(0.35)).frame(width: 32, height: 18)
                Circle().fill(Color.white).frame(width: 15, height: 15).padding(.horizontal, 1.5)
            }
            .frame(width: 32, height: 18)
            .foregroundStyle(ink)
        }
    }
}

/// A symbol: OpenViews' own artwork where it has the name, else Ycode's
/// drawing of it (the toolbar's magnifiers, keyboard and resize glyphs and
/// the Settings rows' symbols, which OpenViews does not draw yet).
struct ChromeGlyph: View {
    let name: String
    let color: Color
    let size: CGFloat

    static let openViewsNames: Set<String> = ["ellipsis", "slider.horizontal.3", "doc.text", "iphone", "cpu", "gearshape", "chevron.up.chevron.down"]

    var body: some View {
        if Self.openViewsNames.contains(name) {
            Image(systemName: name).font(.system(size: size * 0.85)).foregroundStyle(color)
        } else {
            Canvas { ctx, sz in Self.draw(name, in: &ctx, size: sz, color: color) }
                .frame(width: size, height: size)
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func draw(_ name: String, in ctx: inout GraphicsContext, size: CGSize, color: Color) {
        let s = min(size.width, size.height), lw = max(1, s / 11)
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        func stroke(_ p: Path, _ w: CGFloat = lw) { ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round)) }
        func fill(_ p: Path) { ctx.fill(p, with: .color(color)) }
        func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path { Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)) }
        func line(_ a: CGPoint, _ b: CGPoint) -> Path { var p = Path(); p.move(to: a); p.addLine(to: b); return p }
        func rect(_ r: CGRect, _ radius: CGFloat) -> Path { Path(roundedRect: r, cornerRadius: radius) }
        let r = s * 0.4
        switch name {
        case DeviceWindowFrame.zoomToFitSymbol:
            // The macOS window's drawing (DeviceControlGlyphs.zoomToFit, row 156), at the size it takes there.
            drawShared(DeviceControlGlyphs.zoomToFit, in: &ctx, centre: c, scale: s / 16, color: color)
        case "minus.magnifyingglass", "plus.magnifyingglass", "1.magnifyingglass":
            // A lens with a handle, and its mark inside.
            let lc = CGPoint(x: c.x - s * 0.08, y: c.y - s * 0.08), lr = s * 0.3
            stroke(circle(lc.x, lc.y, lr))
            stroke(line(CGPoint(x: lc.x + lr * 0.72, y: lc.y + lr * 0.72), CGPoint(x: c.x + s * 0.42, y: c.y + s * 0.42)), lw * 1.4)
            let m = lr * 0.5
            switch name {
            case "minus.magnifyingglass": stroke(line(CGPoint(x: lc.x - m, y: lc.y), CGPoint(x: lc.x + m, y: lc.y)))
            case "plus.magnifyingglass":
                stroke(line(CGPoint(x: lc.x - m, y: lc.y), CGPoint(x: lc.x + m, y: lc.y)))
                stroke(line(CGPoint(x: lc.x, y: lc.y - m), CGPoint(x: lc.x, y: lc.y + m)))
            case "1.magnifyingglass":
                var p = Path()
                p.move(to: CGPoint(x: lc.x - m * 0.4, y: lc.y - m * 0.6))
                p.addLine(to: CGPoint(x: lc.x + m * 0.1, y: lc.y - m))
                p.addLine(to: CGPoint(x: lc.x + m * 0.1, y: lc.y + m))
                stroke(p, lw * 0.9)
            default: break
            }
        case "keyboard":
            stroke(rect(CGRect(x: c.x - s * 0.45, y: c.y - s * 0.28, width: s * 0.9, height: s * 0.56), s * 0.1))
            for row in 0..<2 { for col in 0..<4 { fill(circle(c.x - s * 0.27 + CGFloat(col) * s * 0.18, c.y - s * 0.1 + CGFloat(row) * s * 0.15, s * 0.04)) } }
            stroke(line(CGPoint(x: c.x - s * 0.2, y: c.y + s * 0.17), CGPoint(x: c.x + s * 0.2, y: c.y + s * 0.17)), lw * 0.8)
        case "rectangle.inset.filled":
            stroke(rect(CGRect(x: c.x - s * 0.42, y: c.y - s * 0.32, width: s * 0.84, height: s * 0.64), s * 0.1))
            fill(rect(CGRect(x: c.x - s * 0.26, y: c.y - s * 0.16, width: s * 0.52, height: s * 0.32), s * 0.04))
        case "circle.lefthalf.filled", "circle.righthalf.filled":
            stroke(circle(c.x, c.y, r))
            var p = Path()
            let left = name == "circle.lefthalf.filled"
            p.addArc(center: c, radius: r, startAngle: .degrees(left ? 90 : -90), endAngle: .degrees(left ? 270 : 90), clockwise: false)
            p.closeSubpath()
            fill(p)
        case "circle.dotted.and.circle":
            stroke(circle(c.x, c.y, r * 0.55))
            for i in 0..<12 { let a = Double(i) / 12 * 2 * .pi; fill(circle(c.x + r * CGFloat(cos(a)), c.y + r * CGFloat(sin(a)), lw * 0.5)) }
        case "drop":
            var p = Path()
            p.move(to: CGPoint(x: c.x, y: c.y - r))
            p.addCurve(to: CGPoint(x: c.x, y: c.y + r), control1: CGPoint(x: c.x + r * 1.2, y: c.y + r * 0.1), control2: CGPoint(x: c.x + r * 0.9, y: c.y + r))
            p.addCurve(to: CGPoint(x: c.x, y: c.y - r), control1: CGPoint(x: c.x - r * 0.9, y: c.y + r), control2: CGPoint(x: c.x - r * 1.2, y: c.y + r * 0.1))
            stroke(p)
        case "camera.filters":
            for (dx, dy) in [(0.0, -0.18), (-0.16, 0.1), (0.16, 0.1)] { stroke(circle(c.x + s * CGFloat(dx), c.y + s * CGFloat(dy), s * 0.22), lw * 0.9) }
        case "textformat.size":
            var big = Path()
            big.move(to: CGPoint(x: c.x - s * 0.05, y: c.y + r))
            big.addLine(to: CGPoint(x: c.x + s * 0.17, y: c.y - r))
            big.addLine(to: CGPoint(x: c.x + s * 0.4, y: c.y + r))
            stroke(big)
            var small = Path()
            small.move(to: CGPoint(x: c.x - s * 0.42, y: c.y + r))
            small.addLine(to: CGPoint(x: c.x - s * 0.27, y: c.y - r * 0.2))
            small.addLine(to: CGPoint(x: c.x - s * 0.12, y: c.y + r))
            stroke(small, lw * 0.8)
        case "square.dashed", "square.on.square.intersection.dashed":
            let box = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
            ctx.stroke(rect(box, s * 0.08), with: .color(color), style: StrokeStyle(lineWidth: lw, dash: [s * 0.12, s * 0.1]))
            if name != "square.dashed" { stroke(rect(box.offsetBy(dx: s * 0.15, dy: s * 0.15).insetBy(dx: s * 0.1, dy: s * 0.1), s * 0.06), lw * 0.8) }
        case "speaker.wave.2", "speaker.wave.2.bubble", "hifispeaker":
            if name == "hifispeaker" {
                stroke(rect(CGRect(x: c.x - s * 0.28, y: c.y - r, width: s * 0.56, height: 2 * r), s * 0.08))
                stroke(circle(c.x, c.y + r * 0.35, s * 0.13))
                fill(circle(c.x, c.y - r * 0.5, s * 0.05))
            } else {
                var p = Path()
                p.move(to: CGPoint(x: c.x - s * 0.42, y: c.y - s * 0.12))
                p.addLine(to: CGPoint(x: c.x - s * 0.28, y: c.y - s * 0.12))
                p.addLine(to: CGPoint(x: c.x - s * 0.08, y: c.y - s * 0.3))
                p.addLine(to: CGPoint(x: c.x - s * 0.08, y: c.y + s * 0.3))
                p.addLine(to: CGPoint(x: c.x - s * 0.28, y: c.y + s * 0.12))
                p.addLine(to: CGPoint(x: c.x - s * 0.42, y: c.y + s * 0.12))
                p.closeSubpath()
                stroke(p, lw * 0.9)
                for k in [0.18, 0.32] {
                    var a = Path()
                    a.addArc(center: CGPoint(x: c.x - s * 0.08, y: c.y), radius: s * CGFloat(k), startAngle: .degrees(-40), endAngle: .degrees(40), clockwise: false)
                    stroke(a, lw * 0.9)
                }
            }
        case "location":
            var p = Path()
            p.move(to: CGPoint(x: c.x + r, y: c.y - r))
            p.addLine(to: CGPoint(x: c.x - r, y: c.y - s * 0.02))
            p.addLine(to: CGPoint(x: c.x - s * 0.02, y: c.y + s * 0.02))
            p.addLine(to: CGPoint(x: c.x + s * 0.02, y: c.y + r))
            p.closeSubpath()
            stroke(p)
        case "mic":
            stroke(rect(CGRect(x: c.x - s * 0.12, y: c.y - r, width: s * 0.24, height: s * 0.5), s * 0.12))
            var a = Path()
            a.addArc(center: CGPoint(x: c.x, y: c.y - s * 0.02), radius: s * 0.24, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
            stroke(a, lw * 0.9)
            stroke(line(CGPoint(x: c.x, y: c.y + s * 0.22), CGPoint(x: c.x, y: c.y + r)), lw * 0.9)
        default:
            stroke(circle(c.x, c.y, r))
        }
    }

    /// A shared glyph (`DeviceControlGlyphs`, the shapes the macOS window
    /// draws) centred at `centre`, `scale` points per glyph point.
    static func drawShared(_ g: DeviceControlGlyphs.Glyph, in ctx: inout GraphicsContext, centre c: CGPoint, scale k: CGFloat, color: Color) {
        func pt(_ p: DeviceControlGlyphs.Point) -> CGPoint { CGPoint(x: c.x + CGFloat(p.x) * k, y: c.y + CGFloat(p.y) * k) }
        func path(_ shape: DeviceControlGlyphs.Shape) -> Path {
            var p = Path()
            switch shape {
            case .roundedRect(let x, let y, let w, let h, let r):
                p = Path(roundedRect: CGRect(x: c.x + CGFloat(x) * k, y: c.y + CGFloat(y) * k, width: CGFloat(w) * k, height: CGFloat(h) * k),
                         cornerRadius: CGFloat(r) * k)
            case .arc(let centre, let r, let from, let to):
                let pts = DeviceControlGlyphs.arcPoints(centre: centre, radius: r, from: from, to: to, steps: 32)
                for (i, q) in pts.enumerated() { if i == 0 { p.move(to: pt(q)) } else { p.addLine(to: pt(q)) } }
            case .polygon(let pts), .polyline(let pts):
                for (i, q) in pts.enumerated() { if i == 0 { p.move(to: pt(q)) } else { p.addLine(to: pt(q)) } }
                if case .polygon = shape { p.closeSubpath() }
            case .disc(let centre, let r):
                p = Path(ellipseIn: CGRect(x: c.x + CGFloat(centre.x - r) * k, y: c.y + CGFloat(centre.y - r) * k, width: CGFloat(2 * r) * k, height: CGFloat(2 * r) * k))
            }
            return p
        }
        for shape in g.strokes {
            ctx.stroke(path(shape), with: .color(color), style: StrokeStyle(lineWidth: CGFloat(g.lineWidth) * k, lineCap: .round, lineJoin: .round))
        }
        for shape in g.solids { ctx.fill(path(shape), with: .color(color)) }
    }
}
#endif
