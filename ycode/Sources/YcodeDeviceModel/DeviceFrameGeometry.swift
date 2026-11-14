// The device frame Ycode draws around a simulated screen (device-hub.md
// §4.3, "Ycode implementation"): a dark band of even width all round, outer
// corners concentric with the screen's, side buttons as short bars on the
// edges. A watch (watchos.md §3.1, W-8) is its case at its real size round
// the screen (council round 10 rows 249–251: 21 device points at the sides,
// 23.5 at the top and bottom), the Digital Crown 13 out with ridges on its
// outer third and the side button a pill 4 out on its right edge, and the
// Ultra types the Action button on the left; `WatchCaseDrawing` gives the
// case's rim, band and fade to black. Everything
// is in device points; a view scales it. Ycode decision: the band and
// button positions are Ycode's own proportions, except where council round
// 6 measured the reference's drawing (device-hub.md §14.2, row 155): a
// phone's or iPad's band is about 16 points in two tones (black next to the
// screen, mid grey outside), a foldable's cover shows the folded half's edge
// as a grey step on its hinge side, and the cover's buttons are two bars on
// its top edge and one on its right edge. Council round 7 (§15.3, §15.4,
// rows 171–172) measured a classic iPhone's and an iPad's own outlines: a
// body corner of about 83, a band of a light line (about 2), a #2C2C2C
// band (about 4) and black to the screen (18.25 on an iPhone, 60 on an iPad),
// an iPad's screen corner about 19, and each one's buttons on their edges.

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
        /// Drawn flush with the body's edge, over it, as a lighter strip
        /// (an iPad's volume buttons, §15.3), not as a bar under it.
        public var flush = false
        /// Its own corner radii (a watch's crown and side button, council
        /// round 10 row 251); nil: the drawing's usual small bar corners.
        public var radii: CornerRadii?
    }

    /// One tone of the band: from `inset` device points inside the body's
    /// edge to the next ring (the last to the screen), its corners concentric
    /// with the body's.
    public struct BandRing: Equatable, Sendable {
        public var inset: Double
        public var color: UInt32
        public init(inset: Double, color: UInt32) {
            self.inset = inset
            self.color = color
        }
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
    /// The band's tones from the body's edge inwards, the last reaching the
    /// screen (empty: a watch's one tone, or no band).
    public var bandRings: [BandRing] = []
    /// A foldable's cover (closed posture): the folded half's edge seen
    /// behind the cover on the hinge side, drawn under the body.
    public var hingeStep: CGRect?
    public var hingeStepRadii = CornerRadii(all: 0)
    /// A partially open iPhone Duo: the hinge line and the half drawn in
    /// shade (Ycode's flat stand-in for the reference's perspective view).
    public var hinge: FrameSegment?
    public var shadedArea: CGRect?
    /// The height Zoom to Fit fits instead of the silhouette's own (a watch:
    /// `watchFitBox`, council round 9 row 231); nil: the silhouette's.
    public var reservedFitHeight: Double?
    /// A watch's case, drawn as `WatchCaseDrawing` describes (council round
    /// 10 rows 250–251): a soft light rim, a dark band fading to black, the
    /// crown and the side button rim-outlined and dark inside.
    public var drawsWatchCase = false

    /// How far buttons stand out from the body (a watch's side and Action
    /// buttons, an iPad's).
    public static let protrusion: Double = 3
    /// How far a phone's buttons stand out (§14.2: the cover's bars stand
    /// 2.5 and 3 window points out at a scale of 0.531, about 5 device points).
    public static let phoneProtrusion: Double = 5
    /// How far a classic iPhone's buttons stand out (§15.4: 3.5 window
    /// points at 0.740, 4.7 device points).
    public static let classicPhoneProtrusion: Double = 4.7
    /// How far an iPad's top button stands out (§15.3: 2 window points at
    /// 0.516, 4 device points).
    public static let padProtrusion: Double = 4
    /// How far a watch's Digital Crown stands out from the body (council
    /// round 10 row 249: 9 points at Physical Size, 32 at Zoom to Fit, about
    /// 2.1 mm, 13 device points).
    public static let crownProtrusion: Double = 13
    /// How far a watch's side button (and an Ultra's Action button) stands
    /// out (row 251: about 10 points at Zoom to Fit, 4 device points).
    public static let watchButtonProtrusion: Double = 4
    /// How far a watch's buttons reach under the body: past the case's soft
    /// rim, so its glow never shows the button's inner end.
    public static let watchButtonTuck: Double = 6

    /// A watch's case round its screen (row 249): the case at its real size,
    /// 46 × 39 mm for the 46 mm Series 12 at 163 device points per inch
    /// (250 × 295), is the 208 × 248 screen plus about 21 at each side and
    /// 23.5 at the top and bottom. Ycode's specs have no other watch's case
    /// size, so every watch takes the same border.
    public static let watchSideBorder: Double = 21
    public static let watchEndBorder: Double = 23.5

    /// The band's width per family: a classic iPhone's 18.25 (§15.4: 13.5
    /// and 15.5 window points at 0.740 and 0.848), an iPad's 60 (§15.3: 31 and
    /// 36 at 0.516 and 0.591), a watch's at its sides (`watchSideBorder`;
    /// its top and bottom are `watchEndBorder`).
    public static func band(_ family: DeviceFamily) -> Double {
        switch family {
        case .phone: 18.25
        case .pad: 60
        case .vision: 0
        case .watch: watchSideBorder
        }
    }

    /// A foldable's band (§14.2: 8.5 window points at 0.531, about 16).
    public static let foldableBand: Double = 16

    /// The band's width for a device type.
    public static func band(spec: DeviceFrameSpec) -> Double { spec.isFoldable ? foldableBand : band(spec.family) }

    /// The band's black inner part (§14.2: 4.5 of the 8.5 window points at a
    /// scale of 0.531, about 8.5 device points, for a foldable; §15.3–§15.4:
    /// everything inside the light line and the grey band for a classic
    /// iPhone and an iPad); nil: a one-tone band.
    public static func innerBand(_ family: DeviceFamily) -> Double? {
        switch family {
        case .phone, .pad: band(family) - outlineEdge - outlineGrey
        case .vision, .watch: nil
        }
    }

    /// A classic iPhone's and an iPad's band from the body's edge inwards
    /// (§15.3, §15.4): a light line about 2 points wide, a #2C2C2C band
    /// about 4, then black to the screen.
    public static let outlineEdge: Double = 2
    public static let outlineGrey: Double = 4
    /// Their body's corner (§15.3, §15.4: a circular fit of about 83 device
    /// points on both).
    public static let outlineBodyCorner: Double = 83
    /// An iPad's screen corner in its frame (§15.3: 9.8–10.7 window points at
    /// 0.516, about 19 device points).
    public static let padScreenCorner: Double = 19

    /// The band's tones for a device type (outside in).
    public static func bandRings(spec: DeviceFrameSpec) -> [BandRing] {
        switch spec.family {
        case .phone where spec.isFoldable:
            return [BandRing(inset: 0, color: Palette.outer), BandRing(inset: foldableBand - 8.5, color: Palette.inner)]
        case .phone, .pad:
            return [BandRing(inset: 0, color: Palette.edge), BandRing(inset: outlineEdge, color: Palette.greyBand),
                    BandRing(inset: outlineEdge + outlineGrey, color: Palette.inner)]
        case .vision, .watch:
            return []
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
    /// A classic iPhone's and an iPad's band (§15.3, §15.4): the light line
    /// (#565657–#818182 on the iPhone, #626263–#7B7C7B on the iPad), the
    /// #2C2C2C band; an iPad's flush volume buttons a slightly lighter strip.
    public enum Palette {
        public static let inner: UInt32 = 0x000000
        public static let outer: UInt32 = 0x5E5E5E
        public static let step: UInt32 = 0x4B4B4B
        public static let button: UInt32 = 0x5E5E5E
        public static let pressedButton: UInt32 = 0x8C8C8C
        public static let edge: UInt32 = 0x707071
        public static let greyBand: UInt32 = 0x2C2C2C
        public static let flushButton: UInt32 = 0x8A8A8B
    }

    /// The space left round the body for what stands out of it: the
    /// buttons, a watch's crown (the same on every side, so the screen
    /// stays at the drawing's centre; a watch's only at its sides).
    public static func margin(_ family: DeviceFamily) -> Double {
        switch family {
        case .watch: crownProtrusion
        case .phone: phoneProtrusion
        case .pad: padProtrusion
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
        let b = Self.band(spec: spec), m = Self.margin(spec.family)
        let watch = spec.family == .watch
        // The band's width at the sides and at the top and bottom (a watch's
        // case is taller round its screen than it is wide, row 249).
        let bx = watch ? Self.watchSideBorder : b, by = watch ? Self.watchEndBorder : b
        // A watch keeps the crown's room at its sides only (nothing stands
        // out of its top or bottom), so the whole drawing fits wherever its
        // silhouette does.
        let mv = watch ? 0 : m
        let inner = spec.isFoldable && panelIndex == 1
        // A foldable's cover: the folded half's edge on the hinge side (the
        // left of the upright cover, whose small corners are there).
        let cover = spec.isFoldable && panelIndex == 0
        let step = cover ? Self.hingeStepWidth : 0
        let body = CGRect(x: m + step, y: mv, width: screenSize.width + 2 * bx, height: screenSize.height + 2 * by)
        let screen = CGRect(x: m + step + bx, y: mv + by, width: screenSize.width, height: screenSize.height)
        // A classic iPhone and an iPad have their own outline (§15.3, §15.4):
        // a body corner of about 83 (never tighter than the screen's grown by
        // the band), an iPad's screen corner about 19; a foldable keeps its
        // corners concentric with its screen's.
        let outline = !spec.isFoldable && (spec.family == .phone || spec.family == .pad)
        let shownScreenRadii = outline && spec.family == .pad ? CornerRadii(all: Self.padScreenCorner) : screenRadii
        let bodyRadii = outline ? CornerRadii(all: max(Self.outlineBodyCorner, shownScreenRadii.largest + b)) : screenRadii.grown(by: bx)
        var g = DeviceFrameGeometry(size: CGSize(width: body.width + step + 2 * m, height: body.height + 2 * mv), body: body,
                                    bodyRadii: bodyRadii, screen: screen, screenRadii: shownScreenRadii, buttons: [])
        g.innerBand = spec.isFoldable ? 8.5 : Self.innerBand(spec.family)
        g.bandRings = Self.bandRings(spec: spec)
        if cover {
            // From the drawing's left edge to the cover's middle (the rest
            // is under the cover), its outer corners those of the cover's
            // hinge side.
            let inset = Self.hingeStepInset
            g.hingeStep = CGRect(x: m, y: body.minY + inset, width: step + body.width / 2, height: body.height - 2 * inset)
            g.hingeStepRadii = CornerRadii(topLeft: bodyRadii.topLeft, topRight: 0, bottomRight: 0, bottomLeft: bodyRadii.bottomLeft)
        }
        g.buttons = Self.buttons(spec: spec, inner: inner, cover: cover, body: body)
        if watch {
            g.reservedFitHeight = Double(g.outerBox.height) / Self.watchFitShare
            g.drawsWatchCase = true
        }
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
        let m: Double = switch spec.family {
        case .phone: spec.isFoldable ? phoneProtrusion : classicPhoneProtrusion
        case .pad: padProtrusion
        default: protrusion
        }
        let t = m + 2  // a bar tucks 2 points under the body
        let W = body.width, H = body.height
        func left(_ y: Double, _ len: Double) -> CGRect { CGRect(x: body.minX - m, y: body.minY + y * H, width: t, height: len * H) }
        func right(_ y: Double, _ len: Double) -> CGRect { CGRect(x: body.maxX - 2, y: body.minY + y * H, width: t, height: len * H) }
        func top(_ x: Double, _ len: Double) -> CGRect { CGRect(x: body.minX + x * W, y: body.minY - m, width: len * W, height: t) }
        // A flush strip on the right edge, inside the body (an iPad's volume).
        func flushRight(_ y: Double, _ len: Double) -> CGRect {
            CGRect(x: body.maxX - outlineEdge - 0.5, y: body.minY + y * H, width: outlineEdge + 0.5, height: len * H)
        }
        switch spec.family {
        case .vision:
            return []
        case .watch:
            // Row 251: the crown 13 out at 22.5–38.5 % of the body's height,
            // its outer corners about 8; the side button 4 out at 52.5–73.5 %,
            // a pill with rounded ends; an Ultra's Action button the same
            // kind of pill on the left edge (Ycode's place, 30–43 %).
            let c = crownProtrusion, p = watchButtonProtrusion, tuck = watchButtonTuck
            let crownCorner = 8.0, pill = 3.2
            func band(_ from: Double, _ to: Double) -> (y: Double, h: Double) { (body.minY + from * H, (to - from) * H) }
            let cy = band(0.225, 0.385), sy = band(0.525, 0.735), ay = band(0.30, 0.43)
            var out = [Button(kind: .crown, rect: CGRect(x: body.maxX - tuck, y: cy.y, width: c + tuck, height: cy.h),
                              radii: CornerRadii(topLeft: 0, topRight: crownCorner, bottomRight: crownCorner, bottomLeft: 0)),
                       Button(kind: .sideButton, rect: CGRect(x: body.maxX - tuck, y: sy.y, width: p + tuck, height: sy.h),
                              radii: CornerRadii(all: pill))]
            if spec.hasActionButton {
                out.append(Button(kind: .action, rect: CGRect(x: body.minX - p, y: ay.y, width: p + tuck, height: ay.h), radii: CornerRadii(all: pill)))
            }
            return out
        case .pad:
            // §15.3, in a 940 × 1300 body: the top button 91 long ending 84
            // from the right edge, standing 4 out; two volume strips 52 long,
            // 10 apart, from 121 below the top, flush with the right edge.
            let (pw, ph) = (940.0, 1300.0)
            return [Button(kind: .top, rect: top((pw - 84 - 91) / pw, 91 / pw)),
                    Button(kind: .volumeUp, rect: flushRight(121 / ph, 52 / ph), flush: true),
                    Button(kind: .volumeDown, rect: flushRight(183 / ph, 52 / ph), flush: true)]
        case .phone where cover:
            return [Button(kind: .volumeUp, rect: top(227.0 / 498, 65.0 / 498)), Button(kind: .volumeDown, rect: top(308.0 / 498, 65.0 / 498)),
                    Button(kind: .side, rect: right(203.0 / 710, 112.0 / 710))]
        case .phone where inner:
            return [Button(kind: .action, rect: top(0.60, 0.035)),
                    Button(kind: .side, rect: right(0.22, 0.17)),
                    Button(kind: .volumeUp, rect: right(0.46, 0.11)), Button(kind: .volumeDown, rect: right(0.60, 0.11))]
        case .phone:
            // §15.4, in a 911.5-point body: on the left from 159.5 (36.5
            // long), 220 and 299 (65.5 each); on the right from 261.5 (103.5).
            let ph = 911.5
            var out: [Button] = []
            if spec.hasActionButton { out.append(Button(kind: .action, rect: left(159.5 / ph, 36.5 / ph))) }
            out += [Button(kind: .volumeUp, rect: left(220 / ph, 65.5 / ph)), Button(kind: .volumeDown, rect: left(299 / ph, 65.5 / ph)),
                    Button(kind: .side, rect: right(261.5 / ph, 103.5 / ph))]
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
            buttons = buttons.map { Button(kind: $0.kind, rect: Self.turnedOnce($0.rect, height: h), flush: $0.flush, radii: $0.radii?.turned(1)) }
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
    /// and its corner radii (concentric with the body's); nil for a one-tone band.
    public var innerBandRect: (rect: CGRect, radii: CornerRadii)? {
        guard let w = innerBand, body != screen else { return nil }
        let r = screen.insetBy(dx: -w, dy: -w)
        return (r, bodyRadii.grown(by: -Double(r.minX - body.minX)).clamped)
    }

    /// Each band tone's rounded rectangle (the body inset by its `inset`,
    /// corners concentric with the body's) and colour, outside in.
    public var bandRingRects: [(rect: CGRect, radii: CornerRadii, color: UInt32)] {
        guard body != screen else { return [] }
        return bandRings.map { ring in
            (body.insetBy(dx: ring.inset, dy: ring.inset), bodyRadii.grown(by: -ring.inset).clamped, ring.color)
        }
    }

    /// The silhouette's height Zoom to Fit fits (§15.2): the body with the
    /// buttons standing out of its top or bottom edge (the outer box's
    /// height), for a foldable the 1269-point box Device Hub reserves for it
    /// in every posture, for a watch its own box (`watchFitShare`).
    public func fitSilhouetteHeight(foldable: Bool) -> Double {
        foldable ? max(Self.foldableFitBox, Double(outerBox.height)) : max(reservedFitHeight ?? 0, Double(outerBox.height))
    }

    /// The share of the fitted height a watch's silhouette (the body with
    /// the crown and the side button) takes at Zoom to Fit (council round 9
    /// row 231: 638 of §15.2's 673.9 at 1100 × 800 and 732 of 771.9 at
    /// 1400 × 900, 0.947 and 0.948). Like the Duo's 1269-point box, the
    /// reference fits a watch through a box a little taller than the watch,
    /// so the watch, crown included, sits inside the stage with room round it.
    public static let watchFitShare: Double = 0.9475

    /// The box a foldable is fitted through (§15.2: 1269 device points, 1.78
    /// times the Duo's closed body).
    public static let foldableFitBox: Double = 1269

    // MARK: Hit testing

    /// The button at a point (device points), with a few points of slack
    /// around the bar so a thin bar is easy to click.
    public func button(at p: CGPoint, slack: Double = 3) -> ButtonKind? {
        buttons.first { $0.rect.insetBy(dx: -slack, dy: -slack).contains(p) }?.kind
    }

    /// Whether a point is on the frame's band (the body outside the screen).
    public func isOnBand(_ p: CGPoint) -> Bool { body.contains(p) && !screen.contains(p) }
}
