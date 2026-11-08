// The device frame Ycode draws around a simulated screen (device-hub.md
// §4.3, "Ycode implementation"): a dark band of even width all round, outer
// corners concentric with the screen's, side buttons as short bars on the
// edges. A watch (watchos.md §3.1, W-8) has a wider band, the Digital Crown
// as a short ridged cylinder and the side button as a long flat bar on its
// right edge, and the Ultra types the Action button on the left. Everything
// is in device points; a view scales it. Ycode decision: the band and
// button positions are Ycode's own proportions, except where council round
// 6 measured the reference's drawing (device-hub.md §14.2, row 155): a
// phone's or iPad's band is about 16 points in two tones (black next to the
// screen, mid grey outside), a foldable's cover shows the folded half's edge
// as a grey step on its hinge side, and the cover's buttons are two bars on
// its top edge and one on its right edge.

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
        /// A watch's Digital Crown and its side button (watchos.md §3.2).
        case crown, sideButton

        /// The tooltip and accessibility name.
        public var title: String {
            switch self {
            case .action: "Action Button"
            case .volumeUp: "Volume Up"
            case .volumeDown: "Volume Down"
            case .side: "Sleep/Wake"
            case .top: "Top Button"
            case .crown: "Digital Crown"
            case .sideButton: "Side Button"
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
    /// The band's black inner part next to the screen (device points); the
    /// rest of the band, outside it, is mid grey. Nil: one tone (a watch,
    /// or no band).
    public var innerBand: Double?
    /// A foldable's cover (closed posture): the folded half's edge seen
    /// behind the cover on the hinge side, drawn under the body.
    public var hingeStep: CGRect?
    public var hingeStepRadii = CornerRadii(all: 0)
    /// A partially open iPhone Duo: the hinge line and the half drawn in
    /// shade (Ycode's flat stand-in for the reference's perspective view).
    public var hinge: FrameSegment?
    public var shadedArea: CGRect?

    /// How far buttons stand out from the body (a watch's side and Action
    /// buttons, an iPad's).
    public static let protrusion: Double = 3
    /// How far a phone's buttons stand out (§14.2: the cover's bars stand
    /// 2.5 and 3 window points out at a scale of 0.531, about 5 device points).
    public static let phoneProtrusion: Double = 5
    /// How far a watch's Digital Crown stands out from the body.
    public static let crownProtrusion: Double = 8

    /// The band's width per family (Ycode decision).
    public static func band(_ family: DeviceFamily) -> Double {
        switch family {
        case .phone: 16
        case .pad: 20
        case .vision: 0
        case .watch: 16
        }
    }

    /// The band's black inner part (§14.2: 4.5 of the 8.5 window points at a
    /// scale of 0.531, about 8.5 device points); nil: a one-tone band.
    public static func innerBand(_ family: DeviceFamily) -> Double? {
        switch family {
        case .phone, .pad: 8.5
        case .vision, .watch: nil
        }
    }

    /// The hinge-side step of a foldable's cover (§14.2): it stands this far
    /// out of the cover's band (the band's 7.5 points of grey plus this make
    /// the reference's 10 window points of grey at 0.531), and stops this far
    /// short of the cover's top and bottom edges.
    public static let hingeStepWidth: Double = 11.5
    public static let hingeStepInset: Double = 10

    /// The band's colours (sRGB): black next to the screen, mid grey outside
    /// it (§14.2: #505050–#6F6F6F), the hinge-side step a darker grey
    /// (#444344–#575755), the buttons the band's grey.
    public enum Palette {
        public static let inner: UInt32 = 0x000000
        public static let outer: UInt32 = 0x5E5E5E
        public static let step: UInt32 = 0x4B4B4B
        public static let button: UInt32 = 0x5E5E5E
        public static let pressedButton: UInt32 = 0x8C8C8C
    }

    /// The space left round the body for what stands out of it: the
    /// buttons, a watch's crown (the same on every side, so the screen
    /// stays at the drawing's centre).
    public static func margin(_ family: DeviceFamily) -> Double {
        switch family {
        case .watch: crownProtrusion
        case .phone: phoneProtrusion
        default: protrusion
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
        let b = Self.band(spec.family), m = Self.margin(spec.family)
        let inner = spec.isFoldable && panelIndex == 1
        // A foldable's cover: the folded half's edge on the hinge side (the
        // left of the upright cover, whose small corners are there).
        let cover = spec.isFoldable && panelIndex == 0
        let step = cover ? Self.hingeStepWidth : 0
        let body = CGRect(x: m + step, y: m, width: screenSize.width + 2 * b, height: screenSize.height + 2 * b)
        let screen = CGRect(x: m + step + b, y: m + b, width: screenSize.width, height: screenSize.height)
        let bodyRadii = screenRadii.grown(by: b)
        var g = DeviceFrameGeometry(size: CGSize(width: body.width + step + 2 * m, height: body.height + 2 * m), body: body,
                                    bodyRadii: bodyRadii, screen: screen, screenRadii: screenRadii, buttons: [])
        g.innerBand = Self.innerBand(spec.family)
        if cover {
            // From the drawing's left edge to the cover's middle (the rest
            // is under the cover), its outer corners those of the cover's
            // hinge side.
            let inset = Self.hingeStepInset
            g.hingeStep = CGRect(x: m, y: body.minY + inset, width: step + body.width / 2, height: body.height - 2 * inset)
            g.hingeStepRadii = CornerRadii(topLeft: bodyRadii.topLeft, topRight: 0, bottomRight: 0, bottomLeft: bodyRadii.bottomLeft)
        }
        g.buttons = Self.buttons(spec: spec, inner: inner, cover: cover, body: body)
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
    /// right; a foldable's cover, as council round 6 measured it (§14.2),
    /// two bars on its top edge right of the middle (Volume Up, Volume Down:
    /// 65 long, 16 apart, from 227 of the 498-point body) and the side button
    /// on its right edge (112 long, from 203 of 710) and nothing on its hinge
    /// side; an iPad its top button on the top edge near the right corner
    /// and volume on the right edge near the top; an open iPhone Duo keeps
    /// the cover's side button and volume on its right edge and the action
    /// button on its top edge; a watch has the crown in the upper part of
    /// its right edge, the side button below it, and an Ultra the Action
    /// button on its left edge).
    static func buttons(spec: DeviceFrameSpec, inner: Bool, cover: Bool = false, body: CGRect) -> [Button] {
        let m = spec.family == .phone ? phoneProtrusion : protrusion, t = m + 2  // a bar tucks 2 points under the body
        let W = body.width, H = body.height
        func left(_ y: Double, _ len: Double) -> CGRect { CGRect(x: body.minX - m, y: body.minY + y * H, width: t, height: len * H) }
        func right(_ y: Double, _ len: Double) -> CGRect { CGRect(x: body.maxX - 2, y: body.minY + y * H, width: t, height: len * H) }
        func top(_ x: Double, _ len: Double) -> CGRect { CGRect(x: body.minX + x * W, y: body.minY - m, width: len * W, height: t) }
        switch spec.family {
        case .vision:
            return []
        case .watch:
            let c = crownProtrusion
            var out = [Button(kind: .crown, rect: CGRect(x: body.maxX - 2, y: body.minY + 0.22 * H, width: c + 2, height: 0.15 * H)),
                       Button(kind: .sideButton, rect: right(0.47, 0.24))]
            if spec.hasActionButton { out.append(Button(kind: .action, rect: left(0.30, 0.13))) }
            return out
        case .pad:
            return [Button(kind: .top, rect: top(0.80, 0.07)),
                    Button(kind: .volumeUp, rect: right(0.07, 0.055)), Button(kind: .volumeDown, rect: right(0.14, 0.055))]
        case .phone where cover:
            return [Button(kind: .volumeUp, rect: top(227.0 / 498, 65.0 / 498)), Button(kind: .volumeDown, rect: top(308.0 / 498, 65.0 / 498)),
                    Button(kind: .side, rect: right(203.0 / 710, 112.0 / 710))]
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
            hingeStep = hingeStep.map { Self.turnedOnce($0, height: h) }
            hingeStepRadii = hingeStepRadii.turned(1)
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

    // MARK: Outline

    /// The frame's outer box: the body, the hinge-side step and the buttons
    /// (what council round 6 measured as the frame, 274 × 379.5 window
    /// points for the Duo's cover; §14.2).
    public var outerBox: CGRect {
        var r = body
        if let s = hingeStep { r = r.union(s) }
        for b in buttons { r = r.union(b.rect) }
        return r
    }

    /// The black inner part of the band (the screen grown by `innerBand`)
    /// and its corner radii; nil for a one-tone band.
    public var innerBandRect: (rect: CGRect, radii: CornerRadii)? {
        guard let w = innerBand, body != screen else { return nil }
        return (screen.insetBy(dx: -w, dy: -w), screenRadii.grown(by: w))
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
