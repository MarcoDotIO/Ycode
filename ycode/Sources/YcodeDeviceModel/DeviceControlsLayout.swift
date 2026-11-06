// The device windows' floating control capsules (device-hub.md §4.4 and
// §11.1, council round 3 checklist row 65), shared by the macOS canvas and
// the Linux device window: which controls each device has, in which
// capsule, and where the capsules and the device go in the canvas.
//
//   iPhone, iPad      [Home · Screenshot · Record] [Rotate]
//   iPhone Duo        [Home · Screenshot · Record] [Rotate │ Closed · Partially Open · Open]
//   Apple Watch       [Screenshot · Record]                     (Q2, watchos.md §11.3)
//   visionOS          [Home · Screenshot · Record] [Reset Camera]  (§4.4: "interaction modes and Reset Camera")
//
// Measured (§11.1): capsules 36.5 tall, the first glyph's centre 20 from a
// capsule's left edge and the last 20 from its right edge, glyphs on a
// 34-point pitch (so three controls make 108), a 1-point divider after
// Rotate that adds 3.5 (Rotate and the three poses make 145.5), 7.5
// between the capsules, the pair centred on the canvas with its bottom 8
// above the window's bottom edge. The device is centred in the space
// between the top of the canvas and the capsules' top.

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public enum DeviceControlsLayout {
    public static let height: Double = 36.5
    /// Distance between neighbouring glyph centres.
    public static let pitch: Double = 34
    /// From a capsule's edge to the centre of its first (or last) glyph.
    public static let edge: Double = 20
    /// Between the two capsules.
    public static let gap: Double = 7.5
    /// From the capsules' bottom to the window's bottom edge.
    public static let bottomMargin: Double = 8
    /// The width the divider after Rotate adds (the pitch from Rotate to the first pose is 37.5).
    public static let dividerExtra: Double = 3.5
    /// The width of one control's hit area.
    public static let buttonWidth: Double = 34

    /// What a device's capsules hold.
    public struct Device: Equatable, Sendable {
        public var showsHome: Bool
        public var rotates: Bool
        public var foldable: Bool
        public var spatial: Bool
        public init(showsHome: Bool = true, rotates: Bool = true, foldable: Bool = false, spatial: Bool = false) {
            self.showsHome = showsHome
            self.rotates = rotates
            self.foldable = foldable
            self.spatial = spatial
        }

        /// From the device's frame specification (and the stream's hello for a Vision Pro).
        public init(spec: DeviceFrameSpec, foldable: Bool? = nil, spatial: Bool? = nil) {
            let vision = spatial ?? (spec.family == .vision)
            self.init(showsHome: spec.family != .watch, rotates: spec.rotates && !vision,
                      foldable: foldable ?? spec.isFoldable, spatial: vision)
        }
    }

    /// The controls by capsule, left to right.
    public static func groups(_ d: Device) -> [[DeviceCommand]] {
        var out: [[DeviceCommand]] = [(d.showsHome ? [.home] : []) + [.screenshot, .recordScreen]]
        var second: [DeviceCommand] = []
        if d.spatial { second = [.resetCamera] } else if d.rotates { second = [.rotateLeft] }
        if d.foldable { second += [.poseClosed, .posePartiallyOpen, .poseOpen] }
        if !second.isEmpty { out.append(second) }
        return out
    }

    /// A divider follows this control (Rotate before the poses).
    public static func hasDivider(after c: DeviceCommand, in group: [DeviceCommand]) -> Bool {
        (c == .rotateLeft || c == .resetCamera) && group.contains(.poseClosed)
    }

    /// A capsule's width.
    public static func width(of group: [DeviceCommand]) -> Double {
        guard !group.isEmpty else { return 0 }
        let dividers = group.filter { hasDivider(after: $0, in: group) }.count
        return 2 * edge + pitch * Double(group.count - 1) + dividerExtra * Double(dividers)
    }

    /// The centres of a capsule's glyphs, from its left edge.
    public static func glyphCentres(of group: [DeviceCommand]) -> [Double] {
        var x = edge
        var out: [Double] = []
        for c in group {
            out.append(x)
            x += pitch + (hasDivider(after: c, in: group) ? dividerExtra : 0)
        }
        return out
    }

    /// The divider's centre in a capsule (nil: none).
    public static func dividerCentre(of group: [DeviceCommand]) -> Double? {
        guard let i = group.firstIndex(where: { hasDivider(after: $0, in: group) }) else { return nil }
        let c = glyphCentres(of: group)
        return (c[i] + c[i + 1]) / 2
    }

    /// The whole row's width.
    public static func totalWidth(_ groups: [[DeviceCommand]]) -> Double {
        groups.map(width(of:)).reduce(0, +) + gap * Double(max(0, groups.count - 1))
    }

    /// The capsules' rectangles in a canvas `width` × `height` (origin top
    /// left, y down): centred on the canvas, bottom `bottomMargin` above
    /// its bottom edge.
    public static func capsuleRects(_ groups: [[DeviceCommand]], canvasWidth width: Double, canvasHeight height: Double) -> [CGRect] {
        var x = (width - totalWidth(groups)) / 2
        let y = height - bottomMargin - self.height
        return groups.map { g in
            defer { x += self.width(of: g) + gap }
            return CGRect(x: x, y: y, width: self.width(of: g), height: self.height)
        }
    }

    /// Each control's rectangle in the canvas (its capsule's full height,
    /// `buttonWidth` wide around its glyph centre).
    public static func controlRects(_ groups: [[DeviceCommand]], canvasWidth width: Double, canvasHeight height: Double) -> [(DeviceCommand, CGRect)] {
        var out: [(DeviceCommand, CGRect)] = []
        for (g, r) in zip(groups, capsuleRects(groups, canvasWidth: width, canvasHeight: height)) {
            for (c, cx) in zip(g, glyphCentres(of: g)) {
                out.append((c, CGRect(x: Double(r.minX) + cx - buttonWidth / 2, y: Double(r.minY), width: buttonWidth, height: self.height)))
            }
        }
        return out
    }

    /// The space the device is centred in: from `top` (the toolbar's bottom
    /// or the canvas's top) to the capsules' top (§11.2).
    public static func deviceArea(canvasWidth width: Double, canvasHeight height: Double, top: Double) -> CGRect {
        let bottom = height - bottomMargin - self.height
        return CGRect(x: 0, y: top, width: width, height: max(1, bottom - top))
    }

    /// The device's rectangle at `scale`, centred in `area` both ways.
    public static func deviceRect(device: CGSize, scale: Double, in area: CGRect) -> CGRect {
        let w = Double(device.width) * scale, h = Double(device.height) * scale
        return CGRect(x: Double(area.midX) - w / 2, y: Double(area.midY) - h / 2, width: w, height: h)
    }
}
