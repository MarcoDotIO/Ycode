import Foundation
import OVRender
import Testing
#if OPENVIEWS_RENAMED
@testable import OpenViewsCore
@testable import OpenViews
#else
@testable import SwiftUICore
@testable import SwiftUI
#endif

// T-IMG pixel probes (10-plan.md §3.2): each case renders a small view
// headlessly at scale 2 on white (black in dark mode) and samples pixels at
// points. Colours are the 07 §4 values; tolerance ±2 per channel unless a
// case says otherwise (anti-aliasing, JPEG, gradients ±3–10).

private let white = (255, 255, 255, 255)
private let black = (0, 0, 0, 255)

@MainActor
private func pinned<V: View>(_ v: V, _ w: CGFloat = 40, _ h: CGFloat = 40) -> some View {
    ZStack(alignment: .topLeading) { v }.frame(width: w, height: h, alignment: .topLeading)
}

@MainActor
private func draw<V: View>(_ v: V, _ w: CGFloat, _ h: CGFloat, dark: Bool = false, _ name: String) -> PixelImage {
    R5.render(pinned(v, w, h), width: w, height: h, dark: dark, name: name)
}

@MainActor
private func draw<V: View>(_ v: V, _ name: String) -> PixelImage { draw(v, 40, 40, name) }

@MainActor
private func draw<V: View>(_ v: V, dark: Bool, _ name: String) -> PixelImage { draw(v, 40, 40, dark: dark, name) }

@Suite("T-IMG pixel probes: colours and shapes")
@MainActor
struct ShapeProbeTests {
    @Test("Color fills exactly its frame (light and dark values of 07 §4)") func colorFill() {
        let img = draw(Color.red.frame(width: 20, height: 20), "probe.color")
        #expect(R5.probe(img, 10, 10) == R5.hex("#FF383C"))
        #expect(R5.probe(img, 19.75, 10) == R5.hex("#FF383C"))
        #expect(R5.probe(img, 20.25, 10) == white)
        let dark = draw(Color.red.frame(width: 20, height: 20), dark: true, "probe.color.dark")
        #expect(R5.probe(dark, 10, 10) == R5.hex("#FF4245"))
        #expect(R5.probe(dark, 30, 30) == black)
    }

    @Test("Shapes: circle, rounded rectangle, capsule, ellipse, custom shape") func shapes() {
        let c = draw(Circle().fill(Color.blue).frame(width: 40, height: 40), "probe.circle")
        #expect(R5.probe(c, 20, 20) == R5.hex("#0088FF"))
        #expect(R5.probe(c, 1, 1) == white)
        #expect(R5.probe(c, 20, 0.5).3 == 255)
        let rr = draw(RoundedRectangle(cornerRadius: 10).fill(Color.green).frame(width: 40, height: 40), "probe.roundedRect")
        #expect(R5.probe(rr, 0.5, 0.5) == white)
        #expect(R5.probe(rr, 20, 0.5) == R5.hex("#34C759"))
        #expect(R5.probe(rr, 0.5, 20) == R5.hex("#34C759"))
        let cap = draw(Capsule().fill(Color.black).frame(width: 40, height: 20), "probe.capsule")
        #expect(R5.probe(cap, 1, 1) == white)
        #expect(R5.probe(cap, 20, 10) == black)
        #expect(R5.probe(cap, 10, 1) == black)
        let tri = draw(Triangle().fill(Color.black).frame(width: 40, height: 40), "probe.triangle")
        #expect(R5.probe(tri, 20, 2) == black)
        #expect(R5.probe(tri, 5, 5) == white)
        #expect(R5.probe(tri, 2, 39) == black)
        // A shape used as a view fills with the foreground style (primary).
        let fg = draw(Rectangle().frame(width: 10, height: 10), "probe.foreground")
        #expect(R5.probe(fg, 5, 5) == black)
        let styled = draw(Rectangle().frame(width: 10, height: 10).foregroundStyle(Color.red), "probe.foregroundStyle")
        #expect(R5.probe(styled, 5, 5) == R5.hex("#FF383C"))
    }

    @Test("Circle in a non-square frame is centred on the shorter side") func circleInRect() {
        let img = draw(Circle().fill(Color.black).frame(width: 40, height: 20), "probe.circleRect")
        #expect(R5.probe(img, 20, 10) == black)
        #expect(R5.probe(img, 5, 10) == white)
        #expect(R5.probe(img, 11, 10) == black)
    }

    @Test("Strokes are centred on the outline; strokeBorder stays inside") func strokes() {
        let s = draw(Rectangle().stroke(Color.black, lineWidth: 4).frame(width: 30, height: 30).padding(5), "probe.stroke")
        #expect(R5.probe(s, 3.5, 20) == black)    // 2 pt outside the edge at x = 5
        #expect(R5.probe(s, 6.5, 20) == black)    // 2 pt inside
        #expect(R5.probe(s, 2.5, 20) == white)
        #expect(R5.probe(s, 7.5, 20) == white)
        let b = draw(Rectangle().strokeBorder(Color.black, lineWidth: 4).frame(width: 30, height: 30).padding(5), "probe.strokeBorder")
        #expect(R5.probe(b, 4.5, 20) == white)
        #expect(R5.probe(b, 5.5, 20) == black)
        #expect(R5.probe(b, 8.5, 20) == black)
        #expect(R5.probe(b, 9.5, 20) == white)
        let dashed = draw(Rectangle().stroke(Color.black, style: StrokeStyle(lineWidth: 2, dash: [5, 5])).frame(width: 30, height: 30).padding(5),
                          "probe.dash")
        #expect(R5.probe(dashed, 7.5, 5) == black)   // first dash from the top-left corner
        #expect(R5.probe(dashed, 12.5, 5) == white)  // gap
    }

    @Test("trim draws part of the outline") func trim() {
        let img = draw(Rectangle().trim(from: 0, to: 0.25).stroke(Color.black, lineWidth: 2).frame(width: 30, height: 30).padding(5), "probe.trim")
        #expect(R5.probe(img, 20, 5) == black)   // top edge (the first quarter)
        #expect(R5.probe(img, 35, 20) == white)  // right edge not drawn
    }
}

@Suite("T-IMG pixel probes: gradients")
@MainActor
struct GradientProbeTests {
    @Test("Linear gradient: ends and middle (interpolated in sRGB)") func linear() {
        let img = draw(LinearGradient(colors: [.black, .white], startPoint: .leading, endPoint: .trailing).frame(width: 100, height: 10),
                       100, 10, "probe.linear")
        #expect(R5.near(R5.probe(img, 0.25, 5), (0, 0, 0, 255), 3))
        #expect(R5.near(R5.probe(img, 99.75, 5), (255, 255, 255, 255), 3))
        let mid = R5.probe(img, 50, 5)
        #expect(abs(mid.0 - 128) <= 3 && mid.0 == mid.1 && mid.1 == mid.2)
        let quarter = R5.probe(img, 25, 5)
        #expect(abs(quarter.0 - 64) <= 3)
    }

    @Test("Radial gradient: centre and outside the end radius") func radial() {
        let img = draw(RadialGradient(colors: [.white, .black], center: .center, startRadius: 0, endRadius: 20).frame(width: 40, height: 40),
                       "probe.radial")
        #expect(R5.near(R5.probe(img, 20, 20), white, 6))
        #expect(R5.near(R5.probe(img, 1, 1), black, 3))
        let half = R5.probe(img, 30, 20)
        #expect(abs(half.0 - 128) <= 8)
    }

    @Test("Angular gradient sweeps clockwise from the positive x axis") func angular() {
        let img = draw(AngularGradient(colors: [.red, .yellow, .green, .blue, .red], center: .center).frame(width: 40, height: 40),
                       "probe.angular")
        #expect(R5.near(R5.probe(img, 38, 21), R5.hex("#FF383C"), 30))
        #expect(R5.near(R5.probe(img, 20, 38), R5.hex("#FFCC00"), 30))
        #expect(R5.near(R5.probe(img, 2, 20), R5.hex("#34C759"), 30))
        #expect(R5.near(R5.probe(img, 20, 2), R5.hex("#0088FF"), 30))
    }
}

@Suite("T-IMG pixel probes: compositing, clipping, transforms")
@MainActor
struct CompositingProbeTests {
    @Test("Opacity: colour opacity and the opacity modifier over white") func opacity() {
        let a = draw(Color.black.opacity(0.5).frame(width: 20, height: 20), "probe.colorOpacity")
        #expect(R5.near(R5.probe(a, 10, 10), (128, 128, 128, 255), 2))
        let b = draw(Color.black.frame(width: 20, height: 20).opacity(0.25), "probe.opacity")
        #expect(R5.near(R5.probe(b, 10, 10), (191, 191, 191, 255), 2))
        let hidden = draw(Color.black.frame(width: 20, height: 20).hidden(), "probe.hidden")
        #expect(R5.probe(hidden, 10, 10) == white)
    }

    @Test("Blend mode multiply") func multiply() {
        let img = draw(ZStack {
            Color.yellow.frame(width: 20, height: 20)
            Color(red: 0.5, green: 0.5, blue: 1).frame(width: 20, height: 20).blendMode(.multiply)
        }, "probe.multiply")
        // #FFCC00 × (128, 128, 255) → (128, 102, 0)
        #expect(R5.near(R5.probe(img, 10, 10), (128, 102, 0, 255), 3))
    }

    @Test("Background draws below, overlay above; border inside the frame") func layers() {
        let img = draw(Color.red.frame(width: 20, height: 20).background(Color.blue.frame(width: 30, height: 30))
                       .overlay(Color.green.frame(width: 6, height: 6)).padding(5), "probe.layers")
        #expect(R5.probe(img, 2, 2) == R5.hex("#0088FF"))   // background around the base
        #expect(R5.probe(img, 7, 7) == R5.hex("#FF383C"))    // base above the background
        #expect(R5.probe(img, 15, 15) == R5.hex("#34C759"))  // overlay centred on top
        let b = draw(Color.white.frame(width: 20, height: 20).border(Color.black, width: 2), "probe.border")
        #expect(R5.probe(b, 1, 10) == black)
        #expect(R5.probe(b, 3, 10) == white)
    }

    @Test("Clipping: clipShape, clipped, cornerRadius") func clipping() {
        let c = draw(Color.black.frame(width: 40, height: 40).clipShape(Circle()), "probe.clipShape")
        #expect(R5.probe(c, 2, 2) == white)
        #expect(R5.probe(c, 20, 20) == black)
        let clipped = draw(Color.black.frame(width: 60, height: 10).frame(width: 20, height: 10).clipped(), "probe.clipped")
        #expect(R5.probe(clipped, 10, 5) == black)
        #expect(R5.probe(clipped, 25, 5) == white)
        let unclipped = draw(Color.black.frame(width: 60, height: 10).frame(width: 20, height: 10).offset(x: 20), "probe.unclipped")
        #expect(R5.probe(unclipped, 0.5, 5) == black)
        let corner = draw(Color.black.frame(width: 40, height: 40).cornerRadius(10), "probe.cornerRadius")
        #expect(R5.probe(corner, 1, 1) == white)
        #expect(R5.probe(corner, 20, 1) == black)
    }

    @Test("Mask: the mask's alpha shows the content") func mask() {
        let img = draw(Color.black.frame(width: 40, height: 40).mask { Circle() }, "probe.mask")
        #expect(R5.probe(img, 2, 2) == white)
        #expect(R5.probe(img, 20, 20) == black)
        let half = draw(Color.black.frame(width: 40, height: 40).mask { Color.black.opacity(0.5) }, "probe.mask.half")
        #expect(R5.near(R5.probe(half, 20, 20), (128, 128, 128, 255), 2))
    }

    @Test("Transforms: offset, rotationEffect, scaleEffect") func transforms() {
        let o = draw(Color.black.frame(width: 10, height: 10).offset(x: 20, y: 10), "probe.offset")
        #expect(R5.probe(o, 5, 5) == white)
        #expect(R5.probe(o, 25, 15) == black)
        let r = draw(Color.black.frame(width: 30, height: 6).rotationEffect(.degrees(90)).frame(width: 40, height: 40), "probe.rotation")
        #expect(R5.probe(r, 20, 8) == black)   // vertical after rotation
        #expect(R5.probe(r, 8, 20) == white)
        let s = draw(Color.black.frame(width: 10, height: 10).scaleEffect(2).frame(width: 40, height: 40), "probe.scale")
        #expect(R5.probe(s, 12, 20) == black)  // 20 × 20 around the centre
        #expect(R5.probe(s, 8, 20) == white)
    }

    @Test("Shadow darkens below the view; blur spreads it") func effects() {
        let s = draw(Color.white.frame(width: 20, height: 20).shadow(color: .black, radius: 2, x: 0, y: 6).padding(10), "probe.shadow")
        #expect(R5.probe(s, 20, 20) == white)
        #expect(R5.probe(s, 20, 34).0 < 200)
        let b = draw(Color.black.frame(width: 20, height: 20).blur(radius: 6).padding(10), "probe.blur")
        let edge = R5.probe(b, 9, 20)
        #expect(edge.0 > 20 && edge.0 < 235)
    }

    @Test("colorMultiply multiplies shape colours") func colorMultiply() {
        let img = draw(Color.white.frame(width: 20, height: 20).colorMultiply(Color(red: 1, green: 0, blue: 0)), "probe.colorMultiply")
        #expect(R5.probe(img, 10, 10) == (255, 0, 0, 255))
    }
}

@Suite("T-IMG pixel probes: images, text, symbols, canvas")
@MainActor
struct ContentProbeTests {
    @Test("PNG image: natural size, resizable, nearest-neighbour sampling") func png() {
        let natural = draw(Image(R5.quadrantsPNG, scale: 1), "probe.png.natural")
        #expect(R5.probe(natural, 1, 1) == (255, 0, 0, 255))
        #expect(R5.probe(natural, 9, 1) == white)  // 8 × 6 points
        let img = draw(Image(R5.quadrantsPNG).resizable().interpolation(.none).frame(width: 40, height: 30), "probe.png")
        #expect(R5.probe(img, 10, 7) == (255, 0, 0, 255))
        #expect(R5.probe(img, 30, 7) == (0, 255, 0, 255))
        #expect(R5.probe(img, 10, 22) == (0, 0, 255, 255))
        #expect(R5.probe(img, 30, 22) == (255, 255, 0, 255))
    }

    @Test("JPEG image decodes (within JPEG tolerance)") func jpeg() {
        let img = draw(Image(R5.quadrantsJPEG).resizable().frame(width: 40, height: 30), "probe.jpeg")
        #expect(R5.near(R5.probe(img, 8, 6), (255, 0, 0, 255), 12))
        #expect(R5.near(R5.probe(img, 32, 24), (255, 255, 0, 255), 12))
    }

    @Test("Template rendering fills the image's alpha with the foreground style") func template() {
        let img = ImageAssets.image(from: R5.fixture("halfalpha.png"))!
        let t = draw(Image(img).resizable().renderingMode(.template).interpolation(.none).frame(width: 40, height: 40)
                     .foregroundStyle(Color.blue), "probe.template")
        #expect(R5.probe(t, 10, 20) == R5.hex("#0088FF"))
        #expect(R5.probe(t, 30, 20) == white)
    }

    @Test("Named images from a registered asset") func named() {
        ImageAssets.register(name: "r5.quadrants", data: R5.fixture("quadrants.png"), scale: 0.5)
        let img = draw(Image("r5.quadrants").interpolation(.none), "probe.named")
        #expect(R5.probe(img, 3, 3) == (255, 0, 0, 255))   // 16 × 12 points at scale 0.5
        #expect(R5.probe(img, 12, 9) == (255, 255, 0, 255))
        #expect(R5.probe(img, 17, 3) == white)
    }

    @Test("Text draws glyphs inside its frame, in its colour") func text() {
        let img = draw(Text("Hello").foregroundColor(.red), 80, 30, "probe.text")
        let size = TypesetTextMeasurer.shared.measure(Text("Hello").resolve(in: EnvironmentValues()), proposal: .unspecified).size
        let frame = CGRect(origin: .zero, size: size)
        #expect(R5.inkCount(img, in: frame, background: white) > 40)
        #expect(R5.inkCount(img, in: CGRect(x: size.width + 2, y: 0, width: 30, height: 30), background: white) == 0)
        // Some pixels are clearly red.
        var red = false
        for x in stride(from: 0.25, to: Double(size.width), by: 0.5) {
            for y in stride(from: 0.25, to: Double(size.height), by: 0.5) {
                let p = R5.probe(img, x, y)
                if p.0 > 200 && p.1 < 120 && p.2 < 120 { red = true }
            }
        }
        #expect(red)
    }

    @Test("Symbols: our own artwork at the body size; missing names") func symbols() {
        let star = draw(Image(systemName: "star.fill"), "probe.symbol")
        #expect(R5.inkCount(star, in: CGRect(x: 0, y: 0, width: 22, height: 20.67), background: white) > 100)
        #expect(R5.inkCount(star, in: CGRect(x: 23, y: 0, width: 17, height: 40), background: white) == 0)
        // A name the set lacks shows a visible placeholder of the default box.
        let missing = draw(Image(systemName: "doesnotexist.symbol"), "probe.symbol.missing")
        #expect(R5.inkCount(missing, in: CGRect(x: 0, y: 0, width: 21, height: 21), background: white) > 20)
        let m = OpenSymbolProvider.shared.symbol(named: "doesnotexist.symbol", font: TextFont(size: 17))
        #expect(m?.size == CGSize(width: 62.0 / 3, height: 62.0 / 3))
        // Reference parity: unknown names lay out 0 × 0 (07 §3).
        #expect(OpenSymbolProvider(missingSymbolsLayOutEmpty: true).symbol(named: "doesnotexist.symbol", font: TextFont(size: 17)) == nil)
        let tinted = draw(Image(systemName: "circle.fill").foregroundStyle(Color.red), "probe.symbol.tint")
        #expect(R5.probe(tinted, 10.33, 10.33) == R5.hex("#FF383C"))
    }

    @Test("Symbol sizes: body, imageScale, font, other symbols (07 §3, golden)") func symbolSizes() {
        let p = OpenSymbolProvider.shared
        let body = TextFont(size: 17)
        #expect(p.symbol(named: "star.fill", font: body)?.size == CGSize(width: 22, height: 62.0 / 3))
        #expect(p.symbol(named: "star.fill", font: body)?.naturalSize == CGSize(width: 56.0 / 3, height: 18))
        #expect(p.symbol(named: "rectangle.portrait.and.arrow.right", font: body)?.size == CGSize(width: 70.0 / 3, height: 62.0 / 3))
        #expect(p.symbol(named: "heart", font: body)?.size == CGSize(width: 62.0 / 3, height: 18))
        let large = Image.Scale.large.factors, small = Image.Scale.small.factors
        #expect(abs(22 * large.0 - 28) < 0.01 && abs(62.0 / 3 * large.1 - 80.0 / 3) < 0.01)
        #expect(abs(22 * small.0 - 53.0 / 3) < 0.01 && abs(62.0 / 3 * small.1 - 49.0 / 3) < 0.01)
    }

    @Test("Canvas: fills, strokes, transforms, clips, layers") func canvas() {
        let img = draw(Canvas { ctx, _ in
            ctx.fill(Path(CGRect(x: 0, y: 0, width: 10, height: 10)), with: .color(.black))
            var c = ctx
            c.translateBy(x: 20, y: 0)
            c.fill(Path(ellipseIn: CGRect(x: 0, y: 0, width: 10, height: 10)), with: .color(.red))
            ctx.stroke(Path { p in
                p.move(to: CGPoint(x: 0, y: 20))
                p.addLine(to: CGPoint(x: 40, y: 20))
            }, with: .color(.blue), lineWidth: 2)
            var clipped = ctx
            clipped.clip(to: Path(CGRect(x: 0, y: 30, width: 5, height: 10)))
            clipped.fill(Path(CGRect(x: 0, y: 30, width: 20, height: 10)), with: .color(.black))
            ctx.drawLayer { layer in
                layer.opacity = 0.5
                layer.fill(Path(CGRect(x: 30, y: 30, width: 10, height: 10)), with: .color(.black))
            }
        }.frame(width: 40, height: 40), "probe.canvas")
        #expect(R5.probe(img, 5, 5) == black)
        #expect(R5.probe(img, 25, 5) == R5.hex("#FF383C"))
        #expect(R5.probe(img, 20, 20) == R5.hex("#0088FF"))
        #expect(R5.probe(img, 2, 35) == black)
        #expect(R5.probe(img, 8, 35) == white)
        #expect(R5.near(R5.probe(img, 35, 35), (128, 128, 128, 255), 2))
    }

    @Test("ImageRenderer: PNG of the view at its ideal size and scale") func imageRenderer() throws {
        let r = ImageRenderer(content: Color.red.frame(width: 30, height: 20))
        r.scale = 2
        let png = try #require(r.pngData)
        let img = try #require(PNGCodec.decode(png))
        #expect(img.size == PixelSize(width: 60, height: 40))
        #expect(R5.probe(img, 15, 10) == R5.hex("#FF383C"))
    }

    @Test("Right-to-left: positions mirror, text is not mirrored") func rtl() {
        let v = HStack(spacing: 0) {
            Color.red.frame(width: 10, height: 10)
            Color.blue.frame(width: 10, height: 10)
        }
        let img = HeadlessRenderer.render(pinned(v), size: CGSize(width: 40, height: 40), scale: 2) { $0.layoutDirection = .rightToLeft }
        R5.save(img, "probe.rtl")
        #expect(R5.probe(img, 35, 5) == R5.hex("#FF383C"))   // first child at the trailing (right) edge
        #expect(R5.probe(img, 25, 5) == R5.hex("#0088FF"))
        let ltr = R5.render(pinned(Text("ab")), width: 40, height: 40)
        let rtl = HeadlessRenderer.render(pinned(Text("ab")), size: CGSize(width: 40, height: 40), scale: 2) { $0.layoutDirection = .rightToLeft }
        // The same glyphs at the right edge: the ink pattern is translated, not flipped.
        let w = TypesetTextMeasurer.shared.measure(Text("ab").resolve(in: EnvironmentValues()), proposal: .unspecified).size.width
        let shift = Int(((40 - w) * 2).rounded())
        var same = 0, total = 0
        for y in 0..<40 {
            for x in 0..<Int((w * 2).rounded()) {
                let a = ltr.pixel(x: x, y: y), b = rtl.pixel(x: x + shift, y: y)
                total += 1
                if abs(Int(a.0) - Int(b.0)) <= 8 { same += 1 }
            }
        }
        #expect(Double(same) / Double(total) > 0.97)
    }
}
