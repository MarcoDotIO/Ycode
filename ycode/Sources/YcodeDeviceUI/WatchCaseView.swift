// A watch's case on macOS (council round 10 rows 250 and 251; the profile is
// `WatchCaseDrawing`, which the Linux device window shades too): the crown,
// the side button and an Ultra's Action button under the body, each with a
// soft rim and dark inside (the crown's ridges on its outer third), then the
// body's rim, band and fade to black. Each profile is filled as nested
// rounded rectangles about half a view point apart, outside in, so the
// colour steps are finer than a display pixel at 2x and the glow's opacity
// compounds to the profile's (`WatchCaseDrawing.nestedAlphas`).

#if os(macOS)
import AppKit
import YcodeDeviceModel

@MainActor
final class WatchCaseView: NSView {
    var geometry: DeviceFrameGeometry? { didSet { if geometry != oldValue { needsDisplay = true } } }
    var scale: CGFloat = 1 { didSet { if scale != oldValue { needsDisplay = true } } }
    var pressed: DeviceFrameGeometry.ButtonKind? { didSet { if pressed != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let g = geometry, g.drawsWatchCase, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let s = scale
        func r(_ rect: CGRect) -> CGRect { CGRect(x: rect.minX * s, y: rect.minY * s, width: rect.width * s, height: rect.height * s) }
        for b in g.buttons {
            var stops = WatchCaseDrawing.buttonStops
            if b.kind == pressed, let last = stops.indices.last { stops[last].color = WatchCaseDrawing.pressedInside }
            Self.fill(ctx, r(b.rect), radii: (b.radii ?? CornerRadii(all: 1.5)).scaled(by: s), stops: stops, scale: s)
            if b.kind == .crown {
                ctx.setStrokeColor(Self.color(WatchCaseDrawing.ridge, alpha: 1))
                ctx.setLineWidth(max(0.5, WatchCaseDrawing.ridgeWidth * s))
                for seg in WatchCaseDrawing.ridges(crown: b.rect) {
                    ctx.move(to: CGPoint(x: seg.from.x * s, y: seg.from.y * s))
                    ctx.addLine(to: CGPoint(x: seg.to.x * s, y: seg.to.y * s))
                }
                ctx.strokePath()
            }
        }
        Self.fill(ctx, r(g.body), radii: g.bodyRadii.scaled(by: s), stops: WatchCaseDrawing.caseStops, scale: s)
    }

    /// The profile `stops` (device points) inside `rect` (view points) at
    /// `scale` view points a device point: nested fills about half a view
    /// point apart, each in its strip's colour, the last to the centre.
    static func fill(_ ctx: CGContext, _ rect: CGRect, radii: CornerRadii, stops: [WatchCaseDrawing.Stop], scale s: CGFloat) {
        guard let end = stops.last?.inset, s > 0 else { return }
        let step = 0.5 / Double(s)
        let n = max(1, Int((end / step).rounded(.up)))
        var insets = (0..<n).map { Double($0) * end / Double(n) }
        insets.append(end)
        let mids = insets.indices.map { k in k + 1 < insets.count ? (insets[k] + insets[k + 1]) / 2 : end }
        let colours = mids.map { WatchCaseDrawing.colour(stops, at: $0) }
        let alphas = WatchCaseDrawing.nestedAlphas(colours.map(\.a))
        for (k, inset) in insets.enumerated() where alphas[k] > 0 {
            let c = colours[k], d = CGFloat(inset) * s
            let inner = rect.insetBy(dx: d, dy: d)
            guard inner.width > 0, inner.height > 0 else { break }
            ctx.setFillColor(CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: alphas[k]))
            ctx.addPath(DeviceFrameView.path(inner, radii: radii.grown(by: -Double(d)).clamped))
            ctx.fillPath()
        }
    }

    static func color(_ hex: UInt32, alpha: Double) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
#endif
