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

// Helpers of the T-IMG suite (10-plan.md §3.2): headless rendering, pixel
// probes with a tolerance, golden PNG comparison. Set OV_RENDER_OUT to a
// directory to keep every rendered image there; set OV_UPDATE_GOLDENS=1 to
// rewrite the golden PNGs instead of comparing.

enum R5 {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    static var fixtures: URL { directory.appendingPathComponent("Fixtures") }
    static var goldens: URL { directory.appendingPathComponent("Goldens") }

    static func fixture(_ name: String) -> Data { (try? Data(contentsOf: fixtures.appendingPathComponent(name))) ?? Data() }

    @MainActor
    static func render<V: View>(_ view: V, width: CGFloat, height: CGFloat, scale: CGFloat = 2, dark: Bool = false,
                                name: String? = nil) -> PixelImage {
        let img = HeadlessRenderer.render(view, size: CGSize(width: width, height: height), scale: scale,
                                          colorScheme: dark ? .dark : .light)
        if let name { save(img, name) }
        return img
    }

    static func save(_ img: PixelImage, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["OV_RENDER_OUT"] else { return }
        try? PNGCodec.encode(img).write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
    }

    /// The pixel at (x, y) in points (sampled at the pixel containing the
    /// point's centre), straight RGBA.
    static func probe(_ img: PixelImage, _ x: Double, _ y: Double, scale: Double = 2) -> (Int, Int, Int, Int) {
        let px = min(img.size.width - 1, max(0, Int(x * scale))), py = min(img.size.height - 1, max(0, Int(y * scale)))
        let (r, g, b, a) = img.pixel(x: px, y: py)
        if a == 0 { return (0, 0, 0, 0) }
        func un(_ v: UInt8) -> Int { min(255, (Int(v) * 255 + Int(a) / 2) / Int(a)) }
        return (un(r), un(g), un(b), Int(a))
    }

    static func hex(_ s: String) -> (Int, Int, Int, Int) {
        let v = UInt32(s.dropFirst(), radix: 16) ?? 0
        if s.count == 7 { return (Int(v >> 16 & 0xff), Int(v >> 8 & 0xff), Int(v & 0xff), 255) }
        return (Int(v >> 24 & 0xff), Int(v >> 16 & 0xff), Int(v >> 8 & 0xff), Int(v & 0xff))
    }

    /// True when every channel is within `tolerance`.
    static func near(_ a: (Int, Int, Int, Int), _ b: (Int, Int, Int, Int), _ tolerance: Int = 2) -> Bool {
        abs(a.0 - b.0) <= tolerance && abs(a.1 - b.1) <= tolerance && abs(a.2 - b.2) <= tolerance && abs(a.3 - b.3) <= tolerance
    }

    /// Pixels in a point rectangle whose colour differs from `background`
    /// by more than `tolerance` in some channel.
    static func inkCount(_ img: PixelImage, in rect: CGRect, background: (Int, Int, Int, Int), tolerance: Int = 8, scale: Double = 2) -> Int {
        var n = 0
        let x0 = max(0, Int(rect.minX * scale)), x1 = min(img.size.width, Int(rect.maxX * scale))
        let y0 = max(0, Int(rect.minY * scale)), y1 = min(img.size.height, Int(rect.maxY * scale))
        guard x0 < x1, y0 < y1 else { return 0 }
        for y in y0..<y1 {
            for x in x0..<x1 where !near(probe(img, (Double(x) + 0.5) / scale, (Double(y) + 0.5) / scale, scale: scale), background, tolerance) {
                n += 1
            }
        }
        return n
    }

    /// Golden comparison: per-channel difference ≤ `tolerance` everywhere
    /// except at most `allowedFraction` of the pixels (anti-aliased edges
    /// may differ by a few levels between CPUs). Returns a description of
    /// the mismatch, or nil.
    static func compareGolden(_ img: PixelImage, _ name: String, tolerance: Int = 3, allowedFraction: Double = 0.002) -> String? {
        let url = goldens.appendingPathComponent(name + ".png")
        if ProcessInfo.processInfo.environment["OV_UPDATE_GOLDENS"] == "1" {
            try? FileManager.default.createDirectory(at: goldens, withIntermediateDirectories: true)
            try? PNGCodec.encode(img).write(to: url)
            return nil
        }
        guard let data = try? Data(contentsOf: url), let golden = PNGCodec.decode(data) else { return "missing golden \(name).png" }
        guard golden.size == img.size else { return "size \(img.size) vs golden \(golden.size)" }
        var bad = 0, worst = 0
        for i in stride(from: 0, to: img.rgba.count, by: 1) {
            let d = abs(Int(img.rgba[i]) - Int(golden.rgba[i]))
            worst = max(worst, d)
            if d > tolerance { bad += 1 }
        }
        let fraction = Double(bad) / Double(img.rgba.count)
        if fraction > allowedFraction {
            save(img, name + ".actual")
            return "\(bad) channel values differ by more than \(tolerance) (\(String(format: "%.4f", fraction * 100)) %), worst \(worst)"
        }
        return nil
    }
}

/// A shape of our own for tests: a triangle.
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.closeSubpath()
        }
    }
}

/// The sample scenes of T-IMG (10-plan.md §3.2), also the golden scenes.
@MainActor
enum SampleScenes {
    /// Shapes: rectangle, rounded rectangle, circle, capsule, ellipse,
    /// triangle (a custom shape), strokes.
    static var shapes: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Rectangle().fill(Color.red).frame(width: 40, height: 40)
                RoundedRectangle(cornerRadius: 10).fill(Color.green).frame(width: 40, height: 40)
                Circle().fill(Color.blue).frame(width: 40, height: 40)
                Capsule().fill(Color.orange).frame(width: 60, height: 30)
            }
            HStack(spacing: 8) {
                Ellipse().stroke(Color.purple, lineWidth: 4).frame(width: 60, height: 36)
                Triangle().fill(Color.teal).frame(width: 40, height: 40)
                Circle().strokeBorder(Color.pink, style: StrokeStyle(lineWidth: 3, dash: [6, 3])).frame(width: 40, height: 40)
                RoundedRectangle(cornerRadius: 6, style: .circular).stroke(Color.black, lineWidth: 2).frame(width: 40, height: 30)
            }
        }
    }

    static var gradients: some View {
        VStack(spacing: 8) {
            LinearGradient(colors: [.red, .blue], startPoint: .leading, endPoint: .trailing).frame(width: 200, height: 30)
            HStack(spacing: 8) {
                Circle().fill(RadialGradient(colors: [.white, .black], center: .center, startRadius: 0, endRadius: 30))
                    .frame(width: 60, height: 60)
                Rectangle().fill(AngularGradient(colors: [.red, .yellow, .green, .blue, .red], center: .center))
                    .frame(width: 60, height: 60)
                Capsule().fill(.linearGradient(colors: [.mint, .indigo], startPoint: .top, endPoint: .bottom))
                    .frame(width: 60, height: 60)
            }
        }
    }

    /// The done-criterion scene: shapes, gradients, an image, text and
    /// clipping.
    static var composite: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(red: 0.95, green: 0.95, blue: 1), Color(red: 0.8, green: 0.85, blue: 1)],
                           startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(R5.quadrantsPNG, scale: 0.125).resizable().interpolation(.none).frame(width: 64, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("OpenViews").font(.headline)
                        Text("Rendering v1").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 12) {
                    Circle().fill(Color.red).frame(width: 30, height: 30).overlay(Circle().stroke(Color.black, lineWidth: 2))
                    Image(systemName: "star.fill").foregroundStyle(Color.yellow)
                    Image(systemName: "heart.fill").foregroundStyle(Color.pink)
                    Text("Clip").padding(6).background(Color.green.opacity(0.4), in: Capsule())
                }
                Rectangle().fill(AngularGradient(colors: [.red, .yellow, .green, .blue, .purple, .red], center: .center))
                    .frame(width: 180, height: 40)
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.4), radius: 4, x: 0, y: 2)
            }
            .padding(12)
        }
    }

    @MainActor static var quadrantsImage: RenderImage { R5.quadrantsPNG }
}

extension R5 {
    static let quadrantsPNG: RenderImage = ImageAssets.image(from: fixture("quadrants.png"))!
    static let quadrantsJPEG: RenderImage = ImageAssets.image(from: fixture("quadrants.jpg"))!
}
