import Foundation
import OVRender
import Testing

@Suite struct RasterSmokeTests {
    @Test func rectCircleGradient() throws {
        var circle = RenderPath()
        let k = 0.5522847498 * 20
        circle.move(to: CGPoint(x: 70, y: 50))
        circle.cubic(to: CGPoint(x: 50, y: 70), control1: CGPoint(x: 70, y: 50 + k), control2: CGPoint(x: 50 + k, y: 70))
        circle.cubic(to: CGPoint(x: 30, y: 50), control1: CGPoint(x: 50 - k, y: 70), control2: CGPoint(x: 30, y: 50 + k))
        circle.cubic(to: CGPoint(x: 50, y: 30), control1: CGPoint(x: 30, y: 50 - k), control2: CGPoint(x: 50 - k, y: 30))
        circle.cubic(to: CGPoint(x: 70, y: 50), control1: CGPoint(x: 50 + k, y: 30), control2: CGPoint(x: 70, y: 50 - k))
        circle.close()
        let list = DisplayList([
            DisplayItem(id: .root.child(1), .fill(RenderPath(rect: CGRect(x: 0, y: 0, width: 50, height: 50)), .color(RenderColor(red: 1, green: 0, blue: 0)), .nonZero)),
            DisplayItem(id: .root.child(2), .fill(circle, .linearGradient(stops: [RenderGradientStop(color: .white, location: 0), RenderGradientStop(color: RenderColor(red: 0, green: 0, blue: 1), location: 1)], start: CGPoint(x: 30, y: 30), end: CGPoint(x: 70, y: 70), spread: .pad), .nonZero)),
            DisplayItem(id: .root.child(3), .group(DisplayGroup(transform: .translation(60, 0), opacity: 0.5, clips: [RenderClip(path: RenderPath(rect: CGRect(x: 0, y: 0, width: 10, height: 10)))], children: [
                DisplayItem(id: .root.child(4), .fill(RenderPath(rect: CGRect(x: 0, y: 0, width: 30, height: 30)), .color(RenderColor(red: 0, green: 1, blue: 0)), .nonZero)),
            ]))),
        ])
        let r = SoftwareRasterizer()
        let img = r.render(RenderFrame(displayList: list, scale: 2, background: .white), size: PixelSize(width: 200, height: 200))
        #expect(img.pixel(x: 10, y: 10) == (255, 0, 0, 255))
        #expect(img.pixel(x: 190, y: 190) == (255, 255, 255, 255))
        // Clipped group at 60…70 × 0…10 points, half-transparent green over white.
        let g = img.pixel(x: 130, y: 10)
        #expect(g.3 == 255 && g.1 == 255 && abs(Int(g.0) - 128) <= 2)
        #expect(img.pixel(x: 150, y: 10) == (255, 255, 255, 255))
        let png = PNGCodec.encode(img)
        if let dir = ProcessInfo.processInfo.environment["OV_RENDER_OUT"] {
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("smoke.png"))
        }
        let back = try #require(PNGCodec.decode(png))
        #expect(back == img)
    }
}
