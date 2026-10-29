// The device frame Ycode draws around a simulated screen (device-hub.md
// §4.3, "Ycode implementation"): a dark band of even width all round, outer
// corners concentric with the screen's, side buttons as short bars on the
// edges. Everything is in device points; a view scales it. Ycode decision:
// the band and button positions are Ycode's own proportions, not measured
// from any device or picture.

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The iPhone Duo's postures as the display stream names them
/// (display-stream.md §11: `closed`, `halfOpen`, `openFlat`).
public enum DevicePosture: String, Sendable, CaseIterable {
    case closed, halfOpen, openFlat

    /// The pose controls' names (device-hub.md §4.4; foldable.md §4).
    public var title: String {
        switch self {
        case .closed: "Closed"
        case .halfOpen: "Partially Open"
        case .openFlat: "Open"
        }
    }

    /// The hinge angle each pose button moves to.
    public var angle: Int {
        switch self {
        case .closed: 0
        case .halfOpen: 90
        case .openFlat: 180
        }
    }

    /// The pose a commanded angle is (nil: between the presets).
    public static func preset(angle: Int) -> DevicePosture? { allCases.first { $0.angle == angle } }
}

/// A device orientation as the display stream names it, and how far it
/// turns the device clockwise from upright (face up and down count as
/// upright: the picture does not turn).
public enum DeviceOrientation: String, Sendable, CaseIterable {
    case portrait
    case portraitUpsideDown = "portrait-upside-down"
    case landscapeLeft = "landscape-left"
    case landscapeRight = "landscape-right"
    case faceUp = "faceup"
    case faceDown = "facedown"

    public init(streamName: String?) {
        switch streamName {
        case "landscape-left", "landscapeLeft": self = .landscapeLeft
        case "landscape-right", "landscapeRight": self = .landscapeRight
        case "portrait-upside-down", "portraitUpsideDown": self = .portraitUpsideDown
        case "faceup", "faceUp": self = .faceUp
        case "facedown", "faceDown": self = .faceDown
        default: self = .portrait
        }
    }

    /// The Orientation submenu's titles (device-hub.md §4.4, Q13: Ycode decision).
    public var title: String {
        switch self {
        case .portrait: "Portrait"
        case .portraitUpsideDown: "Portrait Upside Down"
        case .landscapeLeft: "Landscape Left"
        case .landscapeRight: "Landscape Right"
        case .faceUp: "Face Up"
        case .faceDown: "Face Down"
        }
    }

    /// The display stream's rotate code (display-stream.md §2, 0x88).
    public var streamCode: UInt8 {
        switch self {
        case .portrait: 1
        case .portraitUpsideDown: 2
        case .landscapeLeft: 3
        case .landscapeRight: 4
        case .faceUp: 5
        case .faceDown: 6
        }
    }

    /// Clockwise quarter turns of the device (landscape left: 3, the top on the left).
    public var clockwiseQuarterTurns: Int {
        switch self {
        case .landscapeLeft: 3
        case .landscapeRight: 1
        case .portraitUpsideDown: 2
        default: 0
        }
    }

    /// Rotate Left / Rotate Right: the next orientation in the cycle
    /// portrait → landscape left → landscape right → portrait (left) or
    /// its reverse (right). Upside down is not offered by the rotate
    /// control (Ycode's guest path refuses it, display-stream.md §11); face
    /// up and down rotate as portrait.
    public func rotated(left: Bool) -> DeviceOrientation {
        switch self {
        case .landscapeLeft: left ? .landscapeRight : .portrait
        case .landscapeRight: left ? .portrait : .landscapeLeft
        default: left ? .landscapeLeft : .landscapeRight
        }
    }
}

/// A rectangle and an axis-aligned segment in device points (origin top left).
public struct FrameSegment: Equatable, Sendable {
    public var from: CGPoint
    public var to: CGPoint
}

public struct DeviceFrameGeometry: Equatable, Sendable {
    public enum ButtonKind: String, Sendable, CaseIterable {
        case action, volumeUp, volumeDown, side, top

        /// The tooltip and accessibility name.
        public var title: String {
            switch self {
            case .action: "Action Button"
            case .volumeUp: "Volume Up"
            case .volumeDown: "Volume Down"
            case .side: "Sleep/Wake"
            case .top: "Top Button"
            }
        }
    }

    public struct Button: Equatable, Sendable {
        public var kind: ButtonKind
        public var rect: CGRect
    }

    /// The whole drawing, buttons included.
    public var size: CGSize
    /// The body (rounded rectangle) and its corner radii.
    public var body: CGRect
    public var bodyRadii: CornerRadii
    /// The screen inside it, with its corner radii as shown.
    public var screen: CGRect
    public var screenRadii: CornerRadii
    public var buttons: [Button]
    /// A partially open iPhone Duo: the hinge line and the half drawn in
    /// shade (Ycode's flat stand-in for the reference's perspective view).
    public var hinge: FrameSegment?
    public var shadedArea: CGRect?

    /// How far buttons stand out from the body.
    public static let protrusion: Double = 3

    /// The band's width per family (Ycode decision).
    public static func band(_ family: DeviceFamily) -> Double {
        switch family {
        case .phone: 12
        case .pad: 20
        case .vision: 0
        }
    }

    /// The frame for `spec`'s panel `panelIndex`, the device turned
    /// `clockwiseQuarterTurns`, in `posture` (a foldable), with or without
    /// the bezel (View ▸ Show / Hide Bezels). Without the bezel (or for
    /// visionOS) the drawing is the screen alone with its rounded corners.
    public init(spec: DeviceFrameSpec, panelIndex: Int = 0, clockwiseQuarterTurns: Int = 0,
                posture: DevicePosture? = nil, bezels: Bool = true) {
        let panel = spec.panels[min(max(panelIndex, 0), spec.panels.count - 1)]
        let screenSize = panel.uprightPointSize
        let screenRadii = panel.uprightCornerRadii
        let turns = ((clockwiseQuarterTurns % 4) + 4) % 4
        guard bezels, spec.hasFrame else {
            var g = DeviceFrameGeometry(size: screenSize, body: CGRect(origin: .zero, size: screenSize), bodyRadii: screenRadii,
                                        screen: CGRect(origin: .zero, size: screenSize), screenRadii: screenRadii, buttons: [])
            g.turn(turns)
            self = g
            return
        }
        let b = Self.band(spec.family), m = Self.protrusion
        let body = CGRect(x: m, y: m, width: screenSize.width + 2 * b, height: screenSize.height + 2 * b)
        let screen = CGRect(x: m + b, y: m + b, width: screenSize.width, height: screenSize.height)
        var g = DeviceFrameGeometry(size: CGSize(width: body.width + 2 * m, height: body.height + 2 * m), body: body,
                                    bodyRadii: screenRadii.grown(by: b), screen: screen, screenRadii: screenRadii, buttons: [])
        let inner = spec.isFoldable && panelIndex == 1
        g.buttons = Self.buttons(spec: spec, inner: inner, body: body)
        if inner, posture == .halfOpen {
            g.hinge = FrameSegment(from: CGPoint(x: body.midX, y: body.minY), to: CGPoint(x: body.midX, y: body.maxY))
            g.shadedArea = CGRect(x: screen.minX, y: screen.minY, width: screen.width / 2, height: screen.height)
        }
        g.turn(turns)
        self = g
    }

    private init(size: CGSize, body: CGRect, bodyRadii: CornerRadii, screen: CGRect, screenRadii: CornerRadii, buttons: [Button]) {
        self.size = size
        self.body = body
        self.bodyRadii = bodyRadii
        self.screen = screen
        self.screenRadii = screenRadii
        self.buttons = buttons
    }

    /// The buttons of an upright body (Ycode decision: a phone has the
    /// action button and volume on its left edge and the side button on its
    /// right; an iPad its top button on the top edge near the right corner
    /// and volume on the right edge near the top; an open iPhone Duo keeps
    /// the cover's side button and volume on its right edge and the action
    /// button on its top edge).
    static func buttons(spec: DeviceFrameSpec, inner: Bool, body: CGRect) -> [Button] {
        let m = protrusion, t = protrusion + 2  // a bar tucks 2 points under the body
        let W = body.width, H = body.height
        func left(_ y: Double, _ len: Double) -> CGRect { CGRect(x: body.minX - m, y: body.minY + y * H, width: t, height: len * H) }
        func right(_ y: Double, _ len: Double) -> CGRect { CGRect(x: body.maxX - 2, y: body.minY + y * H, width: t, height: len * H) }
        func top(_ x: Double, _ len: Double) -> CGRect { CGRect(x: body.minX + x * W, y: body.minY - m, width: len * W, height: t) }
        switch spec.family {
        case .vision:
            return []
        case .pad:
            return [Button(kind: .top, rect: top(0.80, 0.07)),
                    Button(kind: .volumeUp, rect: right(0.07, 0.055)), Button(kind: .volumeDown, rect: right(0.14, 0.055))]
        case .phone where inner:
            return [Button(kind: .action, rect: top(0.60, 0.035)),
                    Button(kind: .side, rect: right(0.22, 0.17)),
                    Button(kind: .volumeUp, rect: right(0.46, 0.11)), Button(kind: .volumeDown, rect: right(0.60, 0.11))]
        case .phone:
            var out: [Button] = []
            if spec.hasActionButton { out.append(Button(kind: .action, rect: left(0.165, 0.045))) }
            out += [Button(kind: .volumeUp, rect: left(0.245, 0.085)), Button(kind: .volumeDown, rect: left(0.355, 0.085)),
                    Button(kind: .side, rect: right(0.27, 0.12))]
            return out
        }
    }

    // MARK: Turning

    /// A rectangle of a `w` × `h` drawing turned clockwise by one quarter.
    static func turnedOnce(_ r: CGRect, height h: Double) -> CGRect {
        CGRect(x: h - r.minY - r.height, y: r.minX, width: r.height, height: r.width)
    }

    mutating func turn(_ quarterTurns: Int) {
        for _ in 0..<quarterTurns {
            let h = size.height
            body = Self.turnedOnce(body, height: h)
            screen = Self.turnedOnce(screen, height: h)
            shadedArea = shadedArea.map { Self.turnedOnce($0, height: h) }
            buttons = buttons.map { Button(kind: $0.kind, rect: Self.turnedOnce($0.rect, height: h)) }
            hinge = hinge.map { s in
                FrameSegment(from: CGPoint(x: h - s.from.y, y: s.from.x), to: CGPoint(x: h - s.to.y, y: s.to.x))
            }
            bodyRadii = bodyRadii.turned(1)
            screenRadii = screenRadii.turned(1)
            size = CGSize(width: size.height, height: size.width)
        }
    }

    // MARK: Hit testing

    /// The button at a point (device points), with a few points of slack
    /// around the bar so a thin bar is easy to click.
    public func button(at p: CGPoint, slack: Double = 3) -> ButtonKind? {
        buttons.first { $0.rect.insetBy(dx: -slack, dy: -slack).contains(p) }?.kind
    }

    /// Whether a point is on the frame's band (the body outside the screen).
    public func isOnBand(_ p: CGPoint) -> Bool { body.contains(p) && !screen.contains(p) }
}
