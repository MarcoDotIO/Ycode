// Where a portable viewer draws the device (display-stream.md §13.2): the
// device's frame (DeviceFrameGeometry, in device points) scaled into the
// window. Fit scales the drawing to the window less a margin; Point
// Accurate shows one device point per window unit; Pixel Accurate one
// device pixel per output pixel (on a 1× output, the device's scale times
// larger than Point Accurate).

import Foundation
import YcodeDeviceModel

public enum ViewerScaleMode: String, Sendable, CaseIterable {
    case fit, point, pixel

    public init?(argument: String) {
        switch argument {
        case "fit": self = .fit
        case "point", "1:1", "points": self = .point
        case "pixel", "pixels": self = .pixel
        default: return nil
        }
    }
}

public struct ViewerRect: Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { (self.x, self.y, self.width, self.height) = (x, y, width, height) }
    public func contains(_ px: Double, _ py: Double) -> Bool { px >= x && py >= y && px <= x + width && py <= y + height }
}

public struct ViewerLayout: Equatable, Sendable {
    /// Window units per device point.
    public var scale: Double
    /// The drawing's origin in the window.
    public var originX: Double, originY: Double
    public var geometry: DeviceFrameGeometry

    /// Space reserved under the device for the control row (window units).
    public static let controlBar: Double = DeviceControlsLayout.height + DeviceControlsLayout.bottomMargin
    public static let margin: Double = 12

    /// The layout of `geometry` in a window of `windowWidth` × `windowHeight`
    /// units. `pixelDensity`: output pixels per window unit; `deviceScale`:
    /// the panel's pixels per point.
    public init(geometry: DeviceFrameGeometry, mode: ViewerScaleMode, windowWidth: Double, windowHeight: Double,
                pixelDensity: Double = 1, deviceScale: Double = 3, controls: Bool = true) {
        self.geometry = geometry
        let gw = Double(geometry.size.width), gh = Double(geometry.size.height)
        let availW = max(1, windowWidth - 2 * Self.margin)
        let availH = max(1, windowHeight - 2 * Self.margin - (controls ? Self.controlBar : 0))
        switch mode {
        case .fit: scale = max(0.05, min(availW / gw, availH / gh))
        case .point: scale = 1
        case .pixel: scale = deviceScale / max(pixelDensity, 0.1)
        }
        // Centred; a drawing larger than the window starts at the margin.
        originX = max(Self.margin, (windowWidth - gw * scale) / 2)
        originY = max(Self.margin, (windowHeight - (controls ? Self.controlBar : 0) - gh * scale) / 2)
        // The screen picture starts on a whole output pixel, so that at Pixel
        // Accurate it is drawn 1:1 (uikit-feel-ycode.md §8.4).
        self.pixelDensity = max(pixelDensity, 0.1)
        let sx = originX + Double(geometry.screen.minX) * scale, sy = originY + Double(geometry.screen.minY) * scale
        originX += (sx * self.pixelDensity).rounded() / self.pixelDensity - sx
        originY += (sy * self.pixelDensity).rounded() / self.pixelDensity - sy
    }

    /// Output pixels per window unit.
    public var pixelDensity: Double

    /// Whether a stream image of `imageWidth` × `imageHeight` pixels (as
    /// shown, after any turn) fills the screen with one image pixel per
    /// output pixel: the front end then draws it unfiltered.
    public func showsPixelsOneToOne(imageWidth: Int, imageHeight: Int) -> Bool {
        let s = screen
        return abs(s.width * pixelDensity - Double(imageWidth)) < 0.01 && abs(s.height * pixelDensity - Double(imageHeight)) < 0.01
            && abs((s.x * pixelDensity).rounded() - s.x * pixelDensity) < 0.01 && abs((s.y * pixelDensity).rounded() - s.y * pixelDensity) < 0.01
    }

    /// The window size that shows the drawing in this mode with nothing cut off.
    public static func windowSize(geometry: DeviceFrameGeometry, scale: Double, controls: Bool = true) -> (width: Double, height: Double) {
        (Double(geometry.size.width) * scale + 2 * margin,
         Double(geometry.size.height) * scale + 2 * margin + (controls ? controlBar : 0))
    }

    /// A rectangle of the drawing (device points) in window units.
    public func window(_ r: CGRect) -> ViewerRect {
        ViewerRect(x: originX + Double(r.minX) * scale, y: originY + Double(r.minY) * scale,
                   width: Double(r.width) * scale, height: Double(r.height) * scale)
    }

    /// The screen picture in window units.
    public var screen: ViewerRect { window(geometry.screen) }

    /// A window point → the screen picture's view points (TouchMapper's input).
    public func screenPoint(_ wx: Double, _ wy: Double) -> ViewPoint {
        let s = screen
        return ViewPoint(x: wx - s.x, y: wy - s.y)
    }

    /// A window point → a point of the drawing (device points).
    public func drawingPoint(_ wx: Double, _ wy: Double) -> CGPoint {
        CGPoint(x: (wx - originX) / scale, y: (wy - originY) / scale)
    }

    /// The frame button under a window point.
    public func button(atWindow wx: Double, _ wy: Double) -> DeviceFrameGeometry.ButtonKind? {
        geometry.button(at: drawingPoint(wx, wy))
    }

    /// The outline of a rounded rectangle (window units) as a polygon,
    /// corners top-left, top-right, bottom-right, bottom-left, `steps`
    /// segments per corner: what the front end fills.
    public static func roundedPolygon(_ r: ViewerRect, radii: CornerRadii, scale: Double, steps: Int = 10) -> [(Double, Double)] {
        let maxR = min(r.width, r.height) / 2
        func rad(_ v: Double) -> Double { min(max(0, v * scale), maxR) }
        let corners: [(cx: Double, cy: Double, r: Double, start: Double)] = [
            (r.x + rad(radii.topLeft), r.y + rad(radii.topLeft), rad(radii.topLeft), Double.pi),
            (r.x + r.width - rad(radii.topRight), r.y + rad(radii.topRight), rad(radii.topRight), 1.5 * Double.pi),
            (r.x + r.width - rad(radii.bottomRight), r.y + r.height - rad(radii.bottomRight), rad(radii.bottomRight), 0),
            (r.x + rad(radii.bottomLeft), r.y + r.height - rad(radii.bottomLeft), rad(radii.bottomLeft), 0.5 * Double.pi),
        ]
        var out: [(Double, Double)] = []
        for c in corners {
            if c.r <= 0 { out.append((c.cx, c.cy)); continue }
            for i in 0...steps {
                let a = c.start + Double(i) / Double(steps) * Double.pi / 2
                out.append((c.cx + cos(a) * c.r, c.cy + sin(a) * c.r))
            }
        }
        return out
    }
}
